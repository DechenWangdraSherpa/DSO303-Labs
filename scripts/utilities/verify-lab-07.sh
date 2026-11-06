#!/usr/bin/env bash
# Verify every Lab 07 artefact. Exit 1 if anything is missing.
# Works from any directory. Never assumes a shell variable is already set.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-02.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-07.env" 2>/dev/null || true

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "Account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Earlier-lab dependencies still present =="
check "Lab 01 role usms-developer-role" "aws iam get-role --role-name usms-developer-role"
check "Lab 01 policy USMSStudentDataReadWrite" \
  "test -n \"\$(aws iam list-policies --scope Local --query \"Policies[?PolicyName=='USMSStudentDataReadWrite'].Arn | [0]\" --output text)\""
check "Lab 02 usms-vpc" "aws ec2 describe-vpcs --vpc-ids ${USMS_VPC_ID:-vpc-none}"
check "Lab 02 private subnet b exists (two AZs needed)" \
  "aws ec2 describe-subnets --subnet-ids ${USMS_PRIVATE_SUBNET_B:-subnet-none}"

echo "== Lab 07 IAM and EC2 =="
check "role usms-eks-cluster-role" "aws iam get-role --role-name usms-eks-cluster-role"
check "cluster role trusts eks.amazonaws.com" \
  "test \"\$(aws iam get-role --role-name usms-eks-cluster-role --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text)\" = eks.amazonaws.com"
check "role usms-eks-node-role" "aws iam get-role --role-name usms-eks-node-role"
check "node role trusts ec2.amazonaws.com" \
  "test \"\$(aws iam get-role --role-name usms-eks-node-role --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text)\" = ec2.amazonaws.com"
check "node role carries Lab 01's USMSStudentDataReadWrite" \
  "aws iam list-attached-role-policies --role-name usms-eks-node-role --query 'AttachedPolicies[].PolicyName' --output text | grep -qw USMSStudentDataReadWrite"
check "usms-eks-cluster-sg is in usms-vpc" \
  "test \"\$(aws ec2 describe-security-groups --filters Name=group-name,Values=usms-eks-cluster-sg --query 'SecurityGroups[0].VpcId' --output text)\" = ${USMS_VPC_ID:-vpc-none}"

echo "== Lab 07 EKS (expect 3 failures on support Path B) =="
check "cluster usms-eks-cluster is ACTIVE" \
  "test \"\$(aws eks describe-cluster --name usms-eks-cluster --query 'cluster.status' --output text)\" = ACTIVE"
check "cluster carries the _lb_ports_ tag" \
  "aws eks describe-cluster --name usms-eks-cluster --query 'cluster.tags._lb_ports_' --output text | grep -q '8081'"
check "nodegroup usms-eks-nodes is ACTIVE" \
  "test \"\$(aws eks describe-nodegroup --cluster-name usms-eks-cluster --nodegroup-name usms-eks-nodes --query 'nodegroup.status' --output text)\" = ACTIVE"

echo "== Kubernetes =="
check "kubectl reaches an API server" "kubectl version --request-timeout=10s"
check "namespace usms exists" "kubectl get namespace usms"
check "usms-enrolment has 2 ready replicas" \
  "test \"\$(kubectl get deploy usms-enrolment -n usms -o jsonpath='{.status.readyReplicas}')\" = 2"
check "usms-results has 2 ready replicas" \
  "test \"\$(kubectl get deploy usms-results -n usms -o jsonpath='{.status.readyReplicas}')\" = 2"
check "usms-gateway has 1 ready replica" \
  "test \"\$(kubectl get deploy usms-gateway -n usms -o jsonpath='{.status.readyReplicas}')\" = 1"
check "service usms-enrolment has at least 2 endpoints" \
  "test \"\$(kubectl get endpoints usms-enrolment -n usms -o jsonpath='{.subsets[0].addresses}' | grep -o 'ip' | wc -l)\" -ge 2"
check "usms-enrolment declares a cpu request (Lab 08 needs it)" \
  "kubectl get deploy usms-enrolment -n usms -o jsonpath='{.spec.template.spec.containers[0].resources.requests.cpu}' | grep -q 'm'"

echo "== Files and Git hygiene =="
check "configs/lab-07.env exists" "test -f configs/lab-07.env"
check "configs/lab-07.env has no empty values" \
  "! grep -qE 'export [A-Z_0-9]+=$' configs/lab-07.env"
check "five or more manifests present" \
  "test \"\$(ls manifests/lab-07/*.yaml 2>/dev/null | wc -l)\" -ge 5"
check "all four Lab 07 policy documents are valid JSON" \
  "for f in policies/trust-eks-cluster.json policies/trust-eks-node.json policies/usms-eks-cluster-policy.json policies/usms-eks-node-policy.json; do python3 -m json.tool \$f >/dev/null || exit 1; done"
check "no secret is tracked by git" "! git ls-files | grep '^outputs/' | grep -qv '^outputs/.gitkeep$'"
check ".gitignore uses outputs/* not outputs/" "grep -q '^outputs/\*' .gitignore"

echo; echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
