#!/usr/bin/env bash
# Delete the sandbox. Run collect.sh first; deleting discards the results.
set -euo pipefail
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"
[ -n "$OPENSHELL_SANDBOX" ] || {
  echo "set OPENSHELL_SANDBOX (e.g. OPENSHELL_SANDBOX=rds-test)" >&2
  exit 1
}

openshell sandbox delete "$OPENSHELL_SANDBOX"
