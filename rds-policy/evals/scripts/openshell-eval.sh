#!/usr/bin/env bash
# Host-side lifecycle for running the eval in an OpenShell sandbox.
#
# Usage: scripts/openshell-eval.sh <command>   (or `make openshell-<command>`)
#   provider   one-time: register local gcloud ADC as the gateway-held Vertex provider
#   e2e        fresh sandbox: run, wait, collect, delete (results/<name>)
#   run        create + upload + start (detached); then `status`, then `finish`
#   status     is the detached eval running? tails its log
#   finish     collect + teardown, and point results/latest at the run
#   create | upload | start | wait | collect | teardown   the individual steps
#
# Settings come from the environment, then from .env next to the Makefile (see
# .env.example). The steps that run inside the sandbox are Makefile targets:
# setup-openshell, eval-openshell-recorded, package-openshell-results.
set -euo pipefail

evals_dir=$(cd "$(dirname "$0")/.." && pwd)
repo_root=$(cd "$evals_dir/../.." && pwd)

# .env fills in whatever the environment did not set.
if [ -f "$evals_dir/.env" ]; then
  while IFS='=' read -r key value; do
    case $key in '' | \#*) continue ;; esac
    # shellcheck disable=SC2163
    [ -n "${!key:-}" ] || export "$key=$value"
  done <"$evals_dir/.env"
fi
: "${OPENSHELL:=openshell}"
: "${OPENSHELL_GATEWAY:=}"
: "${OPENSHELL_SANDBOX:=}"
: "${OPENSHELL_PROVIDER:=rds-vertex}"
: "${VERTEX_AI_PROJECT_ID:=}"
: "${VERTEX_AI_REGION:=global}"
: "${PROMPTFOO_EVAL_ARGS:=}"
: "${PROMPTFOO_CONCURRENCY:=3}"
# `sandbox upload <repo> /tmp` lands the checkout at /tmp/<repo dir name>.
workdir="/tmp/$(basename "$repo_root")/rds-policy/evals"
sandbox_results=/sandbox/rds-eval-results

die() {
  echo "openshell-eval: $*" >&2
  exit 1
}
osh() { "$OPENSHELL" -g "$OPENSHELL_GATEWAY" "$@"; }
# Run a command inside the sandbox; the snippets below read SANDBOX_RESULTS_DIR.
remote() { osh sandbox exec --name "$OPENSHELL_SANDBOX" --no-tty --env SANDBOX_RESULTS_DIR="$sandbox_results" "$@"; }

need_gateway() {
  command -v "$OPENSHELL" >/dev/null || die "openshell CLI not found"
  [ -n "$OPENSHELL_GATEWAY" ] || die "set OPENSHELL_GATEWAY (see .env.example)"
  osh gateway info >/dev/null
}
need_sandbox() {
  need_gateway
  [ -n "$OPENSHELL_SANDBOX" ] || die "set OPENSHELL_SANDBOX"
  [ "${#OPENSHELL_SANDBOX}" -le 19 ] || die "OPENSHELL_SANDBOX must be at most 19 characters"
}

# Shell run inside the sandbox to report the detached job's state.
# shellcheck disable=SC2016
state_sh='if [ -f "$SANDBOX_RESULTS_DIR/exit-code" ]; then echo "finished:$(cat "$SANDBOX_RESULTS_DIR/exit-code")"; elif [ -f "$SANDBOX_RESULTS_DIR/pid" ] && kill -0 "$(cat "$SANDBOX_RESULTS_DIR/pid")" 2>/dev/null; then echo running; else echo missing; fi'

cmd_provider() {
  need_gateway
  [ -n "$VERTEX_AI_PROJECT_ID" ] || die "set VERTEX_AI_PROJECT_ID (see .env.example)"
  osh provider create --name "$OPENSHELL_PROVIDER" --type google-vertex-ai --from-gcloud-adc \
    --config VERTEX_AI_PROJECT_ID="$VERTEX_AI_PROJECT_ID" --config VERTEX_AI_REGION="$VERTEX_AI_REGION"
}

cmd_create() {
  need_sandbox
  osh provider get "$OPENSHELL_PROVIDER" >/dev/null 2>&1 ||
    die "provider '$OPENSHELL_PROVIDER' not found on gateway '$OPENSHELL_GATEWAY'; run 'make openshell-provider'"
  # CLAUDE_CODE_SKIP_VERTEX_AUTH: the agent sends the provider's placeholder token
  # instead of minting its own; the sandbox proxy swaps in the real credential.
  osh sandbox create --name "$OPENSHELL_SANDBOX" --provider "$OPENSHELL_PROVIDER" \
    --policy "$evals_dir/openshell-policy.yaml" \
    --env HOME=/tmp --env CLAUDE_CODE_USE_VERTEX=1 --env CLAUDE_CODE_SKIP_VERTEX_AUTH=1 \
    --no-tty --detach -- sleep infinity
}

cmd_upload() {
  need_sandbox
  osh sandbox upload "$OPENSHELL_SANDBOX" "$repo_root" /tmp
}

# Attached exec streams are cut by the route's idle timeout, so the job is
# detached and polled; the pid file lets wait/status tell running from dead.
cmd_start() {
  need_sandbox
  # shellcheck disable=SC2016
  remote --workdir "$workdir" \
    --env PROMPTFOO_EVAL_ARGS="$PROMPTFOO_EVAL_ARGS" --env PROMPTFOO_CONCURRENCY="$PROMPTFOO_CONCURRENCY" \
    -- sh -lc 'mkdir -p "$SANDBOX_RESULTS_DIR"; nohup make eval-openshell-recorded >/dev/null 2>&1 </dev/null & echo $! >"$SANDBOX_RESULTS_DIR/pid"; echo "eval started (pid $!)"'
}

cmd_status() {
  need_sandbox
  # shellcheck disable=SC2016
  remote -- sh -c "$state_sh"'; [ ! -f "$SANDBOX_RESULTS_DIR/eval.log" ] || tail -n 30 "$SANDBOX_RESULTS_DIR/eval.log"'
}

cmd_wait() {
  need_sandbox
  local misses=0 state
  while :; do
    state=$(remote -- sh -c "$state_sh" 2>/dev/null || true)
    case $state in
      running)
        misses=0
        printf '.'
        sleep 15
        ;;
      finished:*)
        printf '\nEval finished with exit %s\n' "${state#finished:}"
        return "${state#finished:}"
        ;;
      *)
        misses=$((misses + 1))
        [ "$misses" -lt 10 ] || die "no eval status from $OPENSHELL_SANDBOX after $misses polls (last: '$state')"
        printf '?'
        sleep 15
        ;;
    esac
  done
}

cmd_collect() {
  need_sandbox
  remote --workdir "$workdir" -- make package-openshell-results
  mkdir -p "$evals_dir/results/$OPENSHELL_SANDBOX"
  osh sandbox download "$OPENSHELL_SANDBOX" "$sandbox_results" "$evals_dir/results/$OPENSHELL_SANDBOX"
}

cmd_teardown() {
  need_sandbox
  osh sandbox delete "$OPENSHELL_SANDBOX"
}

cmd_run() {
  cmd_create && cmd_upload && cmd_start &&
    echo "Eval running in $OPENSHELL_SANDBOX. Check 'make openshell-status', then 'make openshell-finish'."
}

cmd_finish() {
  cmd_collect && cmd_teardown && ln -sfn "$OPENSHELL_SANDBOX" "$evals_dir/results/latest"
}

cmd_e2e() {
  need_gateway
  [ -n "$OPENSHELL_SANDBOX" ] || OPENSHELL_SANDBOX="rds-$(date +%m%d-%H%M%S)"
  if ! cmd_run; then
    cmd_teardown >/dev/null 2>&1 || true
    exit 1
  fi
  local eval_status=0
  cmd_wait || eval_status=$?
  cmd_finish || die "results not collected; sandbox $OPENSHELL_SANDBOX kept. Retry: make openshell-finish OPENSHELL_SANDBOX=$OPENSHELL_SANDBOX"
  echo "Results: $evals_dir/results/$OPENSHELL_SANDBOX"
  exit "$eval_status"
}

case ${1:-} in
  provider | e2e | run | status | finish | create | upload | start | wait | collect | teardown) "cmd_$1" ;;
  *)
    echo "usage: $0 <provider|e2e|run|status|finish|create|upload|start|wait|collect|teardown>" >&2
    exit 2
    ;;
esac
