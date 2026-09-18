#!/usr/bin/env bash
# Block until the detached eval finishes, then exit with the eval's own code.
set -euo pipefail
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"

[ -n "$OPENSHELL_SANDBOX" ] || {
  echo "set OPENSHELL_SANDBOX (e.g. OPENSHELL_SANDBOX=rds-test)" >&2
  exit 1
}

# A poll can come back empty when the gateway blips, so allow a few misses
# before giving up rather than treating one bad answer as a dead eval.
misses=0
while :; do
  state=$(openshell sandbox exec --name "$OPENSHELL_SANDBOX" --no-tty -- sh -c "$state_cmd" 2>/dev/null || true)
  case $state in
    running)
      misses=0
      printf '.'
      sleep 15
      ;;
    finished:*)
      printf '\nEval finished with exit %s\n' "${state#finished:}"
      exit "${state#finished:}"
      ;;
    *)
      misses=$((misses + 1))
      [ "$misses" -lt 10 ] || {
        echo "no eval status from $OPENSHELL_SANDBOX after $misses polls (last: '$state')" >&2
        exit 1
      }
      printf '?'
      sleep 15
      ;;
  esac
done
