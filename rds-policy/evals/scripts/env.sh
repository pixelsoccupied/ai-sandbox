# shellcheck shell=bash
# shellcheck disable=SC2034  # these are read by the scripts that source this file
# Shared settings for the scripts next to this file. Sourced, not run.
#
# Values already in the environment win; .env next to the Makefile fills in the
# rest (see .env.example). OPENSHELL_GATEWAY is exported because the openshell
# CLI reads the gateway from it, which is why no command here passes -g.

evals_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
repo_root=$(cd "$evals_dir/../.." && pwd)

env_file="$evals_dir/.env"
if [ -f "$env_file" ]; then
  lineno=0
  # `|| [ -n "$line" ]` also reads a last line with no newline after it.
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}                    # tolerate CRLF files
    line=${line#"${line%%[![:space:]]*}"} # ignore indentation
    case $line in '' | '#'*) continue ;; esac
    case $line in *=*) ;; *)
      echo "$env_file line $lineno: expected NAME=value" >&2
      exit 1
      ;;
    esac
    key=${line%%=*}
    value=${line#*=}
    key=${key//[[:space:]]/}                 # tolerate "NAME = value"
    value=${value#"${value%%[![:space:]]*}"} # ... on the value side too
    case $key in '' | [0-9]* | *[!A-Za-z0-9_]*)
      echo "$env_file line $lineno: '$key' is not a variable name" >&2
      exit 1
      ;;
    esac
    [ -n "${!key:-}" ] || export "$key=$value"
  done <"$env_file"
fi

: "${OPENSHELL_GATEWAY:=}"
: "${OPENSHELL_SANDBOX:=}"
: "${OPENSHELL_PROVIDER:=rds-vertex}"
: "${VERTEX_AI_PROJECT_ID:=}"
: "${VERTEX_AI_REGION:=global}"
: "${PROMPTFOO_EVAL_ARGS:=}"
: "${PROMPTFOO_CONCURRENCY:=3}"
export OPENSHELL_GATEWAY

# `sandbox upload <repo> /tmp` lands the checkout at /tmp/<repo dir name>.
workdir="/tmp/$(basename "$repo_root")/rds-policy/evals"
sandbox_results=/sandbox/rds-eval-results

[ -n "$OPENSHELL_GATEWAY" ] || {
  echo "set OPENSHELL_GATEWAY (see .env.example)" >&2
  exit 1
}

# Printed by the eval's state check inside the sandbox: finished:<exit>, running, or missing.
# shellcheck disable=SC2016
state_cmd='d=${SANDBOX_RESULTS_DIR:-/sandbox/rds-eval-results}; if [ -f "$d/exit-code" ]; then echo "finished:$(cat "$d/exit-code")"; elif [ -f "$d/pid" ] && kill -0 "$(cat "$d/pid")" 2>/dev/null; then echo running; else echo missing; fi'
