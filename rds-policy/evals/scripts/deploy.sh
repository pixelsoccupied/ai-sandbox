#!/usr/bin/env bash
# Create the sandbox, upload the checkout, and start the eval detached.
# Then: status.sh, collect.sh, undeploy.sh.
set -euo pipefail
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"
[ -n "$OPENSHELL_SANDBOX" ] || {
  echo "set OPENSHELL_SANDBOX (e.g. OPENSHELL_SANDBOX=rds-test)" >&2
  exit 1
}
[ "${#OPENSHELL_SANDBOX}" -le 19 ] || {
  echo "OPENSHELL_SANDBOX must be at most 19 characters" >&2
  exit 1
}

openshell provider get "$OPENSHELL_PROVIDER" >/dev/null 2>&1 || {
  echo "provider '$OPENSHELL_PROVIDER' not on gateway '$OPENSHELL_GATEWAY'; run scripts/provider.sh" >&2
  exit 1
}

# Env set at create is visible to every later exec, so the commands below do not
# repeat it. CLAUDE_CODE_SKIP_VERTEX_AUTH makes the agent send the provider's
# placeholder token; the sandbox proxy swaps in the real credential.
openshell sandbox create --name "$OPENSHELL_SANDBOX" --provider "$OPENSHELL_PROVIDER" \
  --policy "$evals_dir/openshell-policy.yaml" \
  --env HOME=/tmp --env CLAUDE_CODE_USE_VERTEX=1 --env CLAUDE_CODE_SKIP_VERTEX_AUTH=1 \
  --env SANDBOX_RESULTS_DIR="$sandbox_results" \
  --no-tty --detach -- sleep infinity

openshell sandbox upload "$OPENSHELL_SANDBOX" "$repo_root" /tmp

# Detached, because an attached exec stream is cut by the route's idle timeout
# after about a minute of silence. The pid file is what status.sh checks.
# shellcheck disable=SC2016
openshell sandbox exec --name "$OPENSHELL_SANDBOX" --no-tty --workdir "$workdir" \
  --env PROMPTFOO_EVAL_ARGS="$PROMPTFOO_EVAL_ARGS" --env PROMPTFOO_CONCURRENCY="$PROMPTFOO_CONCURRENCY" \
  -- sh -lc 'mkdir -p "$SANDBOX_RESULTS_DIR"; nohup make eval-openshell-recorded >/dev/null 2>&1 </dev/null & echo $! >"$SANDBOX_RESULTS_DIR/pid"; echo "eval started (pid $!)"'

echo "Deployed $OPENSHELL_SANDBOX. Next: scripts/status.sh, then collect.sh and undeploy.sh."
