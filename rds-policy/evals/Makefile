.PHONY: setup preflight eval eval-repeat eval-view lint clean \
	setup-openshell eval-openshell eval-openshell-recorded package-openshell-results \
	check-openshell check-openshell-sandbox openshell-provider openshell-create \
	openshell-upload openshell-eval openshell-wait openshell-status \
	openshell-collect openshell-view openshell-teardown openshell-run \
	openshell-finish openshell-e2e help

REPO_ROOT := $(abspath ../..)
-include .env
PROMPTFOO_PYTHON ?= $(REPO_ROOT)/.venv/bin/python
export PROMPTFOO_PYTHON

# OpenShell settings normally come from .env (see .env.example).
OPENSHELL ?= openshell
OPENSHELL_GATEWAY ?=
OPENSHELL_SANDBOX ?=
OPENSHELL_PROVIDER ?= rds-vertex
VERTEX_AI_REGION ?= global
PROMPTFOO_EVAL_ARGS ?=
PROMPTFOO_CONCURRENCY ?= 3
OSH := $(OPENSHELL) -g "$(OPENSHELL_GATEWAY)"
# `sandbox upload <repo> /tmp` lands the checkout at /tmp/<repo dir name>.
OPENSHELL_WORKDIR := /tmp/$(notdir $(REPO_ROOT))/rds-policy/evals
RESULTS_NAME := $(if $(strip $(OPENSHELL_SANDBOX)),$(OPENSHELL_SANDBOX),latest)
OPENSHELL_RESULTS_DIR ?= $(CURDIR)/results/$(RESULTS_NAME)
SANDBOX_RESULTS_DIR := /sandbox/rds-eval-results

# Reports the detached eval's state from inside the sandbox.
define SANDBOX_STATE
dir=$(SANDBOX_RESULTS_DIR); if [ -f "$$dir/exit-code" ]; then echo "finished:$$(cat "$$dir/exit-code")"; elif [ -f "$$dir/pid" ] && kill -0 "$$(cat "$$dir/pid")" 2>/dev/null; then echo running; else echo missing; fi
endef

setup: ## Install pinned eval dependencies (promptfoo + claude-agent-sdk)
	npm ci
	cd ../.. && uv sync

preflight: ## Verify Vertex prerequisites before an eval run
	@missing=""; \
	[ -n "$$ANTHROPIC_VERTEX_PROJECT_ID" ] || missing="$$missing ANTHROPIC_VERTEX_PROJECT_ID"; \
	[ -n "$$CLOUD_ML_REGION" ] || missing="$$missing CLOUD_ML_REGION"; \
	if [ -n "$$missing" ]; then \
	  echo "preflight: unset Vertex var(s):$$missing" >&2; \
	  echo "  Agent (Opus 4.8) and the default Sonnet 5 grader both go direct to Vertex; set project + region (e.g. CLOUD_ML_REGION=global) or the grader config interpolates to empty." >&2; \
	  exit 1; \
	fi; \
	adc="$${GOOGLE_APPLICATION_CREDENTIALS:-$$HOME/.config/gcloud/application_default_credentials.json}"; \
	if [ -z "$$GOOGLE_VERTEX_AI_TOKEN" ] && [ ! -f "$$adc" ]; then \
	  echo "preflight: warning — no ADC at $$adc (run 'gcloud auth application-default login' or set GOOGLE_APPLICATION_CREDENTIALS)." >&2; \
	fi; \
	echo "preflight: Vertex project/region set; the grading project needs claude-sonnet-5 access + Anthropic data sharing, or Vertex returns 403."

eval: preflight ## Run all evals (single pass)
	npx promptfoo eval --no-cache

eval-repeat: preflight ## Run all evals 3x to measure variance
	npx promptfoo eval --no-cache --repeat 3

eval-view: ## View eval results in browser
	npx promptfoo view

lint: ## Lint Python assertion files
	cd ../.. && uv run ruff check rds-policy/evals/assertions/

clean: ## Clear eval cache
	npx promptfoo cache clear

# ---- Targets below run inside the sandbox (started by openshell-eval) ----

# The image ships Python 3.13 and no uv; the project needs 3.14, so install both under /tmp.
setup-openshell:
	python3 -m pip install --user uv
	PATH="$$HOME/.local/bin:$$PATH" uv python install 3.14 --install-dir /tmp/uv-python
	PATH="$$HOME/.local/bin:$$PATH" UV_PYTHON_INSTALL_DIR=/tmp/uv-python UV_PYTHON_DOWNLOADS=never $(MAKE) setup

# The attached provider injects a placeholder in GOOGLE_VERTEX_AI_TOKEN and the
# sandbox proxy swaps in the real short-lived credential on requests to Vertex.
# Claude Code sends it as its bearer token (Google auth skipped via
# CLAUDE_CODE_SKIP_VERTEX_AUTH, set at create); the judge switches to the HTTP
# provider in graders/vertex-brokered.yaml, which does the same.
# Drop PROMPTFOO_CONCURRENCY to 1 if a run reports policy_denied with
# "ambiguous shared socket ownership" (seen once, on the old ADC refresh path).
eval-openshell: preflight
	mkdir -p "$(SANDBOX_RESULTS_DIR)"
	ANTHROPIC_AUTH_TOKEN="$$GOOGLE_VERTEX_AI_TOKEN" PROMPTFOO_GRADING_PROVIDER=file://graders/vertex-brokered.yaml PROMPTFOO_DISABLE_TELEMETRY=1 \
		npx promptfoo eval --no-cache --max-concurrency $(PROMPTFOO_CONCURRENCY) --output "$(SANDBOX_RESULTS_DIR)/promptfoo.json" $(PROMPTFOO_EVAL_ARGS)

# Detached job: install, run, record the exit code for openshell-wait/status.
eval-openshell-recorded:
	@mkdir -p "$(SANDBOX_RESULTS_DIR)"; \
	{ $(MAKE) setup-openshell && $(MAKE) eval-openshell; } >"$(SANDBOX_RESULTS_DIR)/eval.log" 2>&1; \
	printf '%s\n' "$$?" >"$(SANDBOX_RESULTS_DIR)/exit-code"

package-openshell-results:
	@mkdir -p "$(SANDBOX_RESULTS_DIR)"
	@[ ! -d /tmp/.promptfoo ] || cp -R /tmp/.promptfoo "$(SANDBOX_RESULTS_DIR)/promptfoo-state"
	@for path in /tmp/rds-merge-*; do [ ! -e "$$path" ] || cp -R "$$path" "$(SANDBOX_RESULTS_DIR)/"; done

# ---- Host-side lifecycle (needs the openshell CLI and a registered gateway) ----

check-openshell:
	@command -v "$(OPENSHELL)" >/dev/null || { echo "openshell CLI not found" >&2; exit 1; }
	@[ -n "$(OPENSHELL_GATEWAY)" ] || { echo "set OPENSHELL_GATEWAY (see .env.example)" >&2; exit 1; }
	@$(OSH) gateway info >/dev/null

check-openshell-sandbox: check-openshell
	@[ -n "$(OPENSHELL_SANDBOX)" ] || { echo "set OPENSHELL_SANDBOX" >&2; exit 1; }
	@name='$(OPENSHELL_SANDBOX)'; [ "$${#name}" -le 19 ] || { echo "OPENSHELL_SANDBOX must be at most 19 characters" >&2; exit 1; }

openshell-provider: check-openshell ## One-time: register local gcloud ADC as a gateway-held Vertex provider
	@[ -n "$(VERTEX_AI_PROJECT_ID)" ] || { echo "set VERTEX_AI_PROJECT_ID (see .env.example)" >&2; exit 1; }
	$(OSH) provider create \
		--name "$(OPENSHELL_PROVIDER)" \
		--type google-vertex-ai \
		--from-gcloud-adc \
		--config VERTEX_AI_PROJECT_ID="$(VERTEX_AI_PROJECT_ID)" \
		--config VERTEX_AI_REGION="$(VERTEX_AI_REGION)"

openshell-create: check-openshell-sandbox
	@$(OSH) provider get "$(OPENSHELL_PROVIDER)" >/dev/null 2>&1 || { echo "provider '$(OPENSHELL_PROVIDER)' not found on gateway '$(OPENSHELL_GATEWAY)'; run 'make openshell-provider'" >&2; exit 1; }
	$(OSH) sandbox create \
		--name "$(OPENSHELL_SANDBOX)" \
		--provider "$(OPENSHELL_PROVIDER)" \
		--policy "$(CURDIR)/openshell-policy.yaml" \
		--env HOME=/tmp \
		--env CLAUDE_CODE_USE_VERTEX=1 \
		--env CLAUDE_CODE_SKIP_VERTEX_AUTH=1 \
		--no-tty --detach -- sleep infinity

openshell-upload: check-openshell-sandbox
	$(OSH) sandbox upload "$(OPENSHELL_SANDBOX)" "$(REPO_ROOT)" /tmp

# Attached exec streams are cut by the route's idle timeout, so the job is
# detached and polled; the pid file lets wait/status tell running from dead.
openshell-eval: check-openshell-sandbox
	$(OSH) sandbox exec --name "$(OPENSHELL_SANDBOX)" --no-tty --workdir "$(OPENSHELL_WORKDIR)" \
		--env PROMPTFOO_EVAL_ARGS="$(PROMPTFOO_EVAL_ARGS)" \
		--env PROMPTFOO_CONCURRENCY="$(PROMPTFOO_CONCURRENCY)" \
		-- sh -lc 'mkdir -p $(SANDBOX_RESULTS_DIR); nohup make eval-openshell-recorded >/dev/null 2>&1 </dev/null & echo $$! >$(SANDBOX_RESULTS_DIR)/pid; echo "eval started (pid $$!)"'

openshell-wait: check-openshell-sandbox
	@misses=0; \
	while :; do \
	  state="$$($(OSH) sandbox exec --name "$(OPENSHELL_SANDBOX)" --no-tty -- sh -c '$(SANDBOX_STATE)' 2>/dev/null)"; \
	  case "$$state" in \
	    running) misses=0; printf '.'; sleep 15 ;; \
	    finished:*) code="$${state#finished:}"; printf '\nEval finished with exit %s\n' "$$code"; exit "$$code" ;; \
	    *) misses=$$((misses+1)); \
	       [ "$$misses" -lt 10 ] || { printf '\nNo eval status from %s after %s polls (last: "%s")\n' "$(OPENSHELL_SANDBOX)" "$$misses" "$$state" >&2; exit 1; }; \
	       printf '?'; sleep 15 ;; \
	  esac; \
	done

openshell-status: check-openshell-sandbox ## Is the detached eval running? Tails its log
	$(OSH) sandbox exec --name "$(OPENSHELL_SANDBOX)" --no-tty \
		-- sh -c '$(SANDBOX_STATE); [ ! -f $(SANDBOX_RESULTS_DIR)/eval.log ] || tail -n 30 $(SANDBOX_RESULTS_DIR)/eval.log'

openshell-collect: check-openshell-sandbox
	$(OSH) sandbox exec --name "$(OPENSHELL_SANDBOX)" --no-tty --workdir "$(OPENSHELL_WORKDIR)" \
		-- make package-openshell-results
	mkdir -p "$(OPENSHELL_RESULTS_DIR)"
	$(OSH) sandbox download "$(OPENSHELL_SANDBOX)" "$(SANDBOX_RESULTS_DIR)" "$(OPENSHELL_RESULTS_DIR)"

openshell-view: ## View downloaded results with the preserved Promptfoo database
	@test -f "$(OPENSHELL_RESULTS_DIR)/promptfoo-state/promptfoo.db" || { echo "no downloaded Promptfoo database in $(OPENSHELL_RESULTS_DIR)" >&2; exit 1; }
	PROMPTFOO_CONFIG_DIR="$(OPENSHELL_RESULTS_DIR)/promptfoo-state" npx promptfoo view

openshell-teardown: check-openshell-sandbox
	$(OSH) sandbox delete "$(OPENSHELL_SANDBOX)"

openshell-run: openshell-create openshell-upload openshell-eval ## Create a sandbox and start the eval in it (detached)
	@echo "Eval running in $(OPENSHELL_SANDBOX). Check 'make openshell-status', then 'make openshell-finish'."

openshell-finish: openshell-collect openshell-teardown ## Download results, then delete the sandbox
	@ln -sfn "$(OPENSHELL_SANDBOX)" "$(CURDIR)/results/latest"

openshell-e2e: check-openshell ## Fresh sandbox: run, wait, collect, delete (results/<name>)
	@name='$(OPENSHELL_SANDBOX)'; [ -n "$$name" ] || name="rds-$$(date +%m%d-%H%M%S)"; \
	$(MAKE) --no-print-directory openshell-run OPENSHELL_SANDBOX="$$name" \
	  || { $(MAKE) --no-print-directory openshell-teardown OPENSHELL_SANDBOX="$$name" >/dev/null 2>&1; exit 1; }; \
	$(MAKE) --no-print-directory openshell-wait OPENSHELL_SANDBOX="$$name"; eval_status=$$?; \
	$(MAKE) --no-print-directory openshell-finish OPENSHELL_SANDBOX="$$name" \
	  || { echo "Results not collected; sandbox $$name kept. Retry: make openshell-finish OPENSHELL_SANDBOX=$$name" >&2; exit 1; }; \
	echo "Results: $(CURDIR)/results/$$name"; \
	exit "$$eval_status"

help: ## Show this help
	@grep -E '^[a-zA-Z0-9_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "\033[36m%-28s\033[0m %s\n", $$1, $$2}'
