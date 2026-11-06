#!/usr/bin/env bash
# Decide which EKS support path this build gives us. Read-only. Never exits non-zero.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"

echo "== Floci =="
docker container inspect "$FLOCI_CONTAINER_NAME" \
  --format 'running={{.State.Running}}' 2>/dev/null || echo "running=NO-SUCH-CONTAINER"

echo
echo "== Does the eks API answer at all? =="
if aws eks list-clusters --output text >/dev/null 2>&1; then
  echo "eks list-clusters      : OK"
  EKS_API=yes
else
  echo "eks list-clusters      : FAILED"
  EKS_API=no
fi

echo
echo "== Local tooling =="
for t in kubectl k3d docker python3; do
  if command -v "$t" >/dev/null 2>&1; then
    printf "  %-8s : %s\n" "$t" "$(command -v "$t")"
  else
    printf "  %-8s : MISSING\n" "$t"
  fi
done

echo
echo "== Verdict =="
if [ "$EKS_API" = yes ] && command -v kubectl >/dev/null 2>&1; then
  echo "PATH A  - use aws eks throughout"
elif command -v k3d >/dev/null 2>&1 && command -v kubectl >/dev/null 2>&1; then
  echo "PATH B  - create the cluster with k3d (Step 8B); IAM steps still apply"
else
  echo "PATH C  - manifests and reasoning only (Section 7.4)"
fi
