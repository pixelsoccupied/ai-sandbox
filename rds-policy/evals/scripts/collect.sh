#!/usr/bin/env bash
# Download the finished eval's results into results/<sandbox>/.
set -euo pipefail
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"
[ -n "$OPENSHELL_SANDBOX" ] || {
  echo "set OPENSHELL_SANDBOX (e.g. OPENSHELL_SANDBOX=rds-test)" >&2
  exit 1
}

openshell sandbox exec --name "$OPENSHELL_SANDBOX" --no-tty --workdir "$workdir" -- make package-openshell-results

mkdir -p "$evals_dir/results/$OPENSHELL_SANDBOX"
openshell sandbox download "$OPENSHELL_SANDBOX" "$sandbox_results" "$evals_dir/results/$OPENSHELL_SANDBOX"
ln -sfn "$OPENSHELL_SANDBOX" "$evals_dir/results/latest"

echo "Results: $evals_dir/results/$OPENSHELL_SANDBOX"
