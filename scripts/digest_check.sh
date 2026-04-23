#!/usr/bin/env bash
set -euo pipefail

remote_digest() {
  local image_ref="$1"
  local attempt digest
  for attempt in 1 2 3; do
    digest="$(docker buildx imagetools inspect --format '{{json .Manifest}}' "$image_ref" 2>/dev/null \
      | jq -r '.digest // empty')"
    [ -n "$digest" ] && { echo "$digest"; return 0; }
    [ "$attempt" -lt 3 ] && sleep 5
  done
  return 1
}

local_digest() {
  local image_ref="$1"
  docker image inspect "$image_ref" \
    --format '{{index .RepoDigests 0}}' 2>/dev/null \
    | grep -oE 'sha256:[a-f0-9]+' || echo ""
}
