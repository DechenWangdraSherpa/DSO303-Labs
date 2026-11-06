#!/usr/bin/env bash
# Verify every Lab 08 artefact. Exit 1 if anything is missing.
# Works from any directory. Checks CONFIGURATION, not just existence.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-07.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-08.env" 2>/dev/null || true
NS=usms

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}
kget() { kubectl get "$1" "$2" -n "$NS" -o jsonpath="$3" 2>/dev/null; }

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "kubectl reaches an API server" "kubectl version --request-timeout=10s"

echo "== Lab 07 dependencies =="
check "namespace usms exists" "kubectl get namespace $NS"
check "usms-enrolment has at least 2 ready replicas" \
  "test \"\$(kget deploy usms-enrolment '{.status.readyReplicas}')\" -ge 2"
check "usms-enrolment declares a cpu request (the HPA's denominator)" \
  "kget deploy usms-enrolment '{.spec.template.spec.containers[0].resources.requests.cpu}' | grep -q 'm'"
check "cluster carries the _lb_ports_ tag (expect FAIL on Path B)" \
  "aws eks describe-cluster --name usms-eks-cluster --query 'cluster.tags._lb_ports_' --output text | grep -q 8081"

echo "== Lab 08: autoscaling =="
check "HorizontalPodAutoscaler usms-enrolment-hpa exists" "kubectl get hpa usms-enrolment-hpa -n $NS"
check "HPA is autoscaling/v2 with a behavior block" \
  "test -n \"\$(kget hpa usms-enrolment-hpa '{.spec.behavior.scaleDown.stabilizationWindowSeconds}')\""
check "HPA targets Deployment usms-enrolment" \
  "test \"\$(kget hpa usms-enrolment-hpa '{.spec.scaleTargetRef.name}')\" = usms-enrolment"
check "HPA minReplicas is 2" "test \"\$(kget hpa usms-enrolment-hpa '{.spec.minReplicas}')\" = 2"
check "HPA maxReplicas is 8" "test \"\$(kget hpa usms-enrolment-hpa '{.spec.maxReplicas}')\" = 8"
check "HPA cpu target is 50" \
  "test \"\$(kget hpa usms-enrolment-hpa '{.spec.metrics[0].resource.target.averageUtilization}')\" = 50"
check "HPA scale-in stabilisation window is 300s" \
  "test \"\$(kget hpa usms-enrolment-hpa '{.spec.behavior.scaleDown.stabilizationWindowSeconds}')\" = 300"

echo "== Lab 08: disruption budgets =="
check "PodDisruptionBudget usms-gateway-pdb exists" "kubectl get pdb usms-gateway-pdb -n $NS"
check "usms-gateway-pdb uses minAvailable 1" \
  "test \"\$(kget pdb usms-gateway-pdb '{.spec.minAvailable}')\" = 1"
check "usms-enrolment-pdb uses maxUnavailable 1" \
  "test \"\$(kget pdb usms-enrolment-pdb '{.spec.maxUnavailable}')\" = 1"

echo "== Lab 08: exposure ladder =="
check "usms-results-np is a NodePort Service" \
  "test \"\$(kget svc usms-results-np '{.spec.type}')\" = NodePort"
check "usms-results-np is pinned to node port 30080" \
  "test \"\$(kget svc usms-results-np '{.spec.ports[0].nodePort}')\" = 30080"
check "usms-results-np selects the same pods as usms-results" \
  "test \"\$(kget svc usms-results-np '{.spec.selector.app}')\" = usms-results"
check "usms-gateway is now type LoadBalancer" \
  "test \"\$(kget svc usms-gateway '{.spec.type}')\" = LoadBalancer"
check "usms-gateway kept a nodePort (each rung keeps the one below)" \
  "test -n \"\$(kget svc usms-gateway '{.spec.ports[0].nodePort}')\""
check "Ingress usms-portal-ingress exists" "kubectl get ingress usms-portal-ingress -n $NS"
check "Ingress declares three paths" \
  "test \"\$(kget ingress usms-portal-ingress '{.spec.rules[0].http.paths[*].path}' | wc -w)\" -eq 3"
check "Ingress carries the ALB target-type annotation" \
  "kget ingress usms-portal-ingress '{.metadata.annotations}' | grep -q 'target-type'"

echo "== Lab 08: data plane (expect FAIL on Path B) =="
check "node group maxSize was raised to 6" \
  "test \"\$(aws eks describe-nodegroup --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes --query 'nodegroup.scalingConfig.maxSize' --output text)\" = 6"

echo "== Files and Git hygiene =="
check "configs/lab-08.env exists" "test -f configs/lab-08.env"
check "configs/lab-08.env records the HPA bounds" \
  "grep -qE '^export USMS_HPA_MIN=[0-9]+' configs/lab-08.env"
check "six or more Lab 08 manifests present" \
  "test \"\$(ls manifests/lab-08/*.yaml 2>/dev/null | wc -l)\" -ge 6"
check "every Lab 08 manifest passes a client-side dry run" \
  "kubectl apply --dry-run=client -f manifests/lab-08/"
check "hpa-watch.sh is executable" "test -x scripts/utilities/hpa-watch.sh"
check "no secret is tracked by git" "! git ls-files | grep '^outputs/' | grep -qv '^outputs/.gitkeep$'"
check ".gitignore uses outputs/* not outputs/" "grep -q '^outputs/\*' .gitignore"

echo; echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
