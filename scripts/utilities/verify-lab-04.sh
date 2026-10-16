#!/usr/bin/env bash
# Verify every Lab 04 artefact exists and is configured correctly.
# Exit 1 if anything is missing. Read-only; safe to run at any time.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-03.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true

: "${USMS_APP_SG:=none}"
: "${USMS_PRIVATE_SUBNET_A:=none}"
: "${USMS_PRIVATE_SUBNET_B:=none}"
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_ENROLMENT_TASK_FAMILY:=usms-enrolment}"
: "${USMS_ECS_DESIRED_BASELINE:=2}"
: "${USMS_ENROLMENT_SG:=none}"
: "${USMS_ECS_EXEC_ROLE:=usms-ecs-exec-role}"
: "${USMS_ECS_TASK_ROLE:=usms-ecs-task-role}"
: "${USMS_LOG_GROUP_ENROLMENT:=/usms/ecs/enrolment}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

# svc <jmespath>  -> one field from the ECS service
svc() { aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" \
          --services "$USMS_ENROLMENT_SERVICE" --query "services[0].$1" --output text; }

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "Account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Lab 01 to 03 dependencies =="
check "usms-app-sg still exists"        "aws ec2 describe-security-groups --group-ids $USMS_APP_SG"
check "usms-private-subnet-a exists"    "aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_A"
check "usms-private-subnet-b exists"    "aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_B"
check "private rt still has NO igw route" \
  "! aws ec2 describe-route-tables --route-table-ids ${USMS_PRIVATE_RT:-none} --query 'RouteTables[0].Routes[].GatewayId' --output text | grep -q 'igw-'"
check "USMSStudentDataReadWrite policy exists" \
  "aws iam get-policy --policy-arn arn:aws:iam::${ACCOUNT_ID}:policy/USMSStudentDataReadWrite"

echo "== Lab 04 IAM =="
check "usms-ecs-exec-role exists"       "aws iam get-role --role-name $USMS_ECS_EXEC_ROLE"
check "usms-ecs-task-role exists"       "aws iam get-role --role-name $USMS_ECS_TASK_ROLE"
check "exec role trusts ecs-tasks.amazonaws.com" \
  "aws iam get-role --role-name $USMS_ECS_EXEC_ROLE --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text | grep -q '^ecs-tasks.amazonaws.com$'"
check "task role trusts ecs-tasks.amazonaws.com" \
  "aws iam get-role --role-name $USMS_ECS_TASK_ROLE --query 'Role.AssumeRolePolicyDocument.Statement[0].Principal.Service' --output text | grep -q '^ecs-tasks.amazonaws.com$'"
check "exec role carries USMSECSTaskExecution" \
  "aws iam list-attached-role-policies --role-name $USMS_ECS_EXEC_ROLE --query 'AttachedPolicies[].PolicyName' --output text | grep -q USMSECSTaskExecution"
check "task role REUSES Lab 01's USMSStudentDataReadWrite" \
  "aws iam list-attached-role-policies --role-name $USMS_ECS_TASK_ROLE --query 'AttachedPolicies[].PolicyName' --output text | grep -q USMSStudentDataReadWrite"

echo "== Lab 04 logging =="
check "log group $USMS_LOG_GROUP_ENROLMENT exists" \
  "aws logs describe-log-groups --log-group-name-prefix $USMS_LOG_GROUP_ENROLMENT --query 'length(logGroups)' --output text | grep -q '^1$'"
check "log group has a retention policy set" \
  "test \"\$(aws logs describe-log-groups --log-group-name-prefix $USMS_LOG_GROUP_ENROLMENT --query 'logGroups[0].retentionInDays' --output text)\" != None"

echo "== Lab 04 ECS =="
check "cluster $USMS_ECS_CLUSTER is ACTIVE" \
  "test \"\$(aws ecs describe-clusters --clusters $USMS_ECS_CLUSTER --query 'clusters[0].status' --output text)\" = ACTIVE"
check "task definition family $USMS_ENROLMENT_TASK_FAMILY is registered" \
  "aws ecs describe-task-definition --task-definition $USMS_ENROLMENT_TASK_FAMILY"
check "task definition uses awsvpc network mode" \
  "test \"\$(aws ecs describe-task-definition --task-definition $USMS_ENROLMENT_TASK_FAMILY --query 'taskDefinition.networkMode' --output text)\" = awsvpc"
check "task definition is FARGATE compatible" \
  "aws ecs describe-task-definition --task-definition $USMS_ENROLMENT_TASK_FAMILY --query 'taskDefinition.requiresCompatibilities' --output text | grep -q FARGATE"
check "exec role and task role are DIFFERENT" \
  "test \"\$(aws ecs describe-task-definition --task-definition $USMS_ENROLMENT_TASK_FAMILY --query 'taskDefinition.executionRoleArn' --output text)\" != \"\$(aws ecs describe-task-definition --task-definition $USMS_ENROLMENT_TASK_FAMILY --query 'taskDefinition.taskRoleArn' --output text)\""
check "service $USMS_ENROLMENT_SERVICE is ACTIVE" "test \"\$(svc status)\" = ACTIVE"
check "service launch type is FARGATE"            "test \"\$(svc launchType)\" = FARGATE"
check "service spans TWO subnets" \
  "test \"\$(aws ecs describe-services --cluster $USMS_ECS_CLUSTER --services $USMS_ENROLMENT_SERVICE --query 'length(services[0].networkConfiguration.awsvpcConfiguration.subnets)' --output text)\" = 2"
check "service does NOT assign a public IP" \
  "test \"\$(svc 'networkConfiguration.awsvpcConfiguration.assignPublicIp')\" = DISABLED"
check "service carries usms-enrolment-sg" \
  "svc 'networkConfiguration.awsvpcConfiguration.securityGroups[0]' | grep -q $USMS_ENROLMENT_SG"
check "service desiredCount is 2 (one task per Availability Zone)" \
  "test \"\$(svc desiredCount)\" = $USMS_ECS_DESIRED_BASELINE"

echo "== Lab 04 networking =="
check "usms-enrolment-sg exists"  "aws ec2 describe-security-groups --group-ids $USMS_ENROLMENT_SG"
check "usms-enrolment-sg is sourced from usms-app-sg (not a CIDR)" \
  "test \"\$(aws ec2 describe-security-groups --group-ids $USMS_ENROLMENT_SG --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[0].GroupId' --output text)\" = $USMS_APP_SG"
check "usms-enrolment-sg admits NOTHING from 0.0.0.0/0" \
  "! aws ec2 describe-security-groups --group-ids $USMS_ENROLMENT_SG --query 'SecurityGroups[0].IpPermissions[].IpRanges[].CidrIp' --output text | grep -q '0.0.0.0/0'"

echo "== Files and Git hygiene =="
check "configs/lab-04.env exists"        "test -f configs/lab-04.env"
check "configs/lab-04.env has no empty values" \
  "! grep -qE 'export [A-Z_]+=$|=None$' configs/lab-04.env"
check "task definition document is valid JSON" \
  "python3 -m json.tool templates/lab-04-taskdef.json"
check "trust policy is valid JSON" \
  "python3 -m json.tool policies/trust-ecs-tasks.json"
check "execution policy is valid JSON" \
  "python3 -m json.tool policies/usms-ecs-task-execution-policy.json"
check "no task definition document contains an unexpanded variable" \
  "! grep -q '[$]' templates/lab-04-taskdef.json"
check "no secret is tracked by git" "! git ls-files | grep '^outputs/' | grep -qv '^outputs/[.]gitkeep'"

echo; echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
