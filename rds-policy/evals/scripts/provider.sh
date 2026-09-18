#!/usr/bin/env bash
# One-time: store the local gcloud ADC on the gateway as a Vertex provider.
# Sandboxes attach it by name and only ever see a placeholder token.
set -euo pipefail
# shellcheck source=scripts/env.sh
. "$(dirname "$0")/env.sh"

[ -n "$VERTEX_AI_PROJECT_ID" ] || {
  echo "set VERTEX_AI_PROJECT_ID (see .env.example)" >&2
  exit 1
}

openshell provider create --name "$OPENSHELL_PROVIDER" --type google-vertex-ai --from-gcloud-adc \
  --config VERTEX_AI_PROJECT_ID="$VERTEX_AI_PROJECT_ID" --config VERTEX_AI_REGION="$VERTEX_AI_REGION"
