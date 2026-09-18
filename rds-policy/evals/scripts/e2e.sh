#!/usr/bin/env bash
# One command for a whole run: deploy, wait, collect, undeploy.
# Names the sandbox rds-<MMDD-HHMMSS> unless OPENSHELL_SANDBOX is set.
set -euo pipefail
here=$(dirname "$0")
# shellcheck source=scripts/env.sh
. "$here/env.sh"

export OPENSHELL_SANDBOX=${OPENSHELL_SANDBOX:-rds-$(date +%m%d-%H%M%S)}

"$here/deploy.sh" || {
  "$here/undeploy.sh" >/dev/null 2>&1 || true
  exit 1
}

# Keep the eval's exit code, but collect and delete either way.
status=0
"$here/wait.sh" || status=$?

"$here/collect.sh" || {
  echo "results not collected; $OPENSHELL_SANDBOX kept. Retry: OPENSHELL_SANDBOX=$OPENSHELL_SANDBOX scripts/collect.sh" >&2
  exit 1
}
"$here/undeploy.sh"
exit "$status"
