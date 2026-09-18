#!/usr/bin/env bash
# Is the eval still running? Prints its state and the tail of its log.
set -euo pipefail
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"
[ -n "$OPENSHELL_SANDBOX" ] || {
  echo "set OPENSHELL_SANDBOX (e.g. OPENSHELL_SANDBOX=rds-test)" >&2
  exit 1
}

# shellcheck disable=SC2016
openshell sandbox exec --name "$OPENSHELL_SANDBOX" --no-tty \
  -- sh -c "$state_cmd"'; [ ! -f "$SANDBOX_RESULTS_DIR/eval.log" ] || tail -n 30 "$SANDBOX_RESULTS_DIR/eval.log"'
