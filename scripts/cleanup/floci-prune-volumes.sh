#!/usr/bin/env bash
# DESTRUCTIVE. Removes dangling Docker volumes labelled floci=true.
# Your bind-mounted state in $FLOCI_HOST_DATA_DIR is NOT touched.
#   dry run : ./scripts/cleanup/floci-prune-volumes.sh
#   delete  : ./scripts/cleanup/floci-prune-volumes.sh --yes
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"
CONFIRM="${1:-}"

vols="$(docker volume ls -q --filter label=floci=true --filter dangling=true || true)"
if [ -z "$vols" ]; then
  printf '\033[1;32m[ok]\033[0m No dangling floci volumes.\n'; exit 0
fi

count="$(printf '%s\n' "$vols" | wc -l | tr -d ' ')"
printf '\033[1;33m[!]\033[0m %s dangling volume(s) labelled floci=true:\n' "$count"
printf '%s\n' "$vols" | sed 's/^/    /'

if [ "$CONFIRM" != "--yes" ]; then
  printf '\nDry run. Re-run with --yes to delete these.\n'
  printf 'Your lab state in %s is unaffected either way.\n' "$FLOCI_HOST_DATA_DIR"
  exit 0
fi

printf '%s\n' "$vols" | xargs -r docker volume rm
printf '\033[1;32m[ok]\033[0m Removed %s volume(s).\n' "$count"
