#!/usr/bin/env bash
# Print the HPA and its target Deployment once every 10 seconds. Read-only.
# Usage: ./scripts/utilities/hpa-watch.sh [iterations]
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
NS=usms
N="${1:-60}"

printf "%-9s %-14s %-10s %-8s %-8s\n" "TIME" "CPU/TARGET" "REPLICAS" "READY" "PODS"
for i in $(seq 1 "$N"); do
  T=$(date -u +%H:%M:%S)
  H=$(kubectl get hpa usms-enrolment-hpa -n "$NS" \
        -o jsonpath='{.status.currentMetrics[0].resource.current.averageUtilization}' 2>/dev/null)
  TGT=$(kubectl get hpa usms-enrolment-hpa -n "$NS" \
        -o jsonpath='{.spec.metrics[0].resource.target.averageUtilization}' 2>/dev/null)
  D=$(kubectl get deploy usms-enrolment -n "$NS" -o jsonpath='{.spec.replicas}' 2>/dev/null)
  R=$(kubectl get deploy usms-enrolment -n "$NS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  P=$(kubectl get pods -n "$NS" -l app=usms-enrolment --no-headers 2>/dev/null | wc -l | tr -d ' ')
  printf "%-9s %-14s %-10s %-8s %-8s\n" "$T" "${H:-unknown}%/${TGT:-?}%" "${D:-?}" "${R:-0}" "$P"
  sleep 10
done
