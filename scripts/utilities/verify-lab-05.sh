#!/usr/bin/env bash
# Verify every Lab 05 artefact exists and is configured correctly.
# Read-only: this script inspects and changes nothing. Safe to run at any time.
# Exit 0 if every check passes, 1 otherwise.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-03.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-05.env" 2>/dev/null || true

# Defaults so that set -u cannot abort the script before it has told you anything.
: "${USMS_VPC_ID:=none}"
: "${USMS_PUBLIC_SUBNET_A:=none}"
: "${USMS_PUBLIC_SUBNET_B:=none}"
: "${USMS_PRIVATE_SUBNET_A:=none}"
: "${USMS_PRIVATE_SUBNET_B:=none}"
: "${USMS_APP_SG:=none}"
: "${USMS_ENROLMENT_SG:=none}"
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_ENROLMENT_CONTAINER:=enrolment-api}"
: "${USMS_ALB_NAME:=usms-enrolment-alb}"
: "${USMS_ALB_SG:=none}"
: "${USMS_TG_NAME:=usms-enrolment-tg}"
: "${USMS_TG_ARN:=none}"
: "${USMS_ALB_LISTENER_ARN:=}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

# One field from the load balancer, the target group, a target group attribute, or the service.
lbq()    { aws elbv2 describe-load-balancers --names "$USMS_ALB_NAME" \
             --query "LoadBalancers[0].$1" --output text; }
tgq()    { aws elbv2 describe-target-groups --names "$USMS_TG_NAME" \
             --query "TargetGroups[0].$1" --output text; }
tgattr() { aws elbv2 describe-target-group-attributes --target-group-arn "$(tgq TargetGroupArn)" \
             --query "Attributes[?Key=='$1'].Value | [0]" --output text; }
svcq()   { aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" \
             --services "$USMS_ENROLMENT_SERVICE" --query "services[0].$1" --output text; }
sgsrc()  { aws ec2 describe-security-groups --group-ids "$1" \
             --query 'SecurityGroups[0].IpPermissions[].UserIdGroupPairs[].GroupId' --output text; }
az()     { aws ec2 describe-subnets --subnet-ids "$1" \
             --query 'Subnets[0].AvailabilityZone' --output text 2>/dev/null; }

# Listeners and rules have no names, so walk down from the load balancer.
LARN="${USMS_ALB_LISTENER_ARN}"
if [ -z "$LARN" ] || [ "$LARN" = "None" ]; then
  LARN=$(aws elbv2 describe-listeners --load-balancer-arn "$(lbq LoadBalancerArn)" \
           --query 'Listeners[?Port==`80`].ListenerArn | [0]' --output text 2>/dev/null || echo none)
fi

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "Account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Lab 02 to 04 dependencies =="
check "usms-vpc exists" "aws ec2 describe-vpcs --vpc-ids $USMS_VPC_ID"
check "usms-public-subnet-a exists" "aws ec2 describe-subnets --subnet-ids $USMS_PUBLIC_SUBNET_A"
check "usms-public-subnet-b exists" "aws ec2 describe-subnets --subnet-ids $USMS_PUBLIC_SUBNET_B"
check "the two public subnets are in TWO different AZs" \
  "test -n \"\$(az $USMS_PUBLIC_SUBNET_A)\" && test \"\$(az $USMS_PUBLIC_SUBNET_A)\" != \"\$(az $USMS_PUBLIC_SUBNET_B)\""
check "usms-app-sg still exists" "aws ec2 describe-security-groups --group-ids $USMS_APP_SG"
check "cluster $USMS_ECS_CLUSTER is ACTIVE" \
  "test \"\$(aws ecs describe-clusters --clusters $USMS_ECS_CLUSTER --query 'clusters[0].status' --output text)\" = ACTIVE"
check "service $USMS_ENROLMENT_SERVICE is ACTIVE" "test \"\$(svcq status)\" = ACTIVE"

echo "== Lab 05 security groups =="
check "usms-alb-sg exists" "aws ec2 describe-security-groups --group-ids $USMS_ALB_SG"
check "usms-alb-sg admits tcp/80 from 0.0.0.0/0" \
  "aws ec2 describe-security-groups --group-ids $USMS_ALB_SG --query 'SecurityGroups[0].IpPermissions[?FromPort==\`80\`].IpRanges[].CidrIp' --output text | grep -q '0.0.0.0/0'"
check "usms-enrolment-sg admits tcp/80 from usms-alb-sg" \
  "sgsrc $USMS_ENROLMENT_SG | grep -qw $USMS_ALB_SG"
check "cutover done: usms-enrolment-sg no longer admits usms-app-sg" \
  "! sgsrc $USMS_ENROLMENT_SG | grep -qw $USMS_APP_SG"

echo "== Lab 05 load balancer =="
check "load balancer $USMS_ALB_NAME exists" "aws elbv2 describe-load-balancers --names $USMS_ALB_NAME"
check "load balancer state is active"        "test \"\$(lbq 'State.Code')\" = active"
check "scheme is internet-facing"            "test \"\$(lbq Scheme)\" = internet-facing"
check "type is application"                  "test \"\$(lbq Type)\" = application"
check "spans TWO availability zones"         "test \"\$(lbq 'length(AvailabilityZones)')\" = 2"
check "carries usms-alb-sg" \
  "aws elbv2 describe-load-balancers --names $USMS_ALB_NAME --query 'LoadBalancers[0].SecurityGroups' --output text | grep -qw $USMS_ALB_SG"

echo "== Lab 05 target group =="
check "target group $USMS_TG_NAME exists" "aws elbv2 describe-target-groups --names $USMS_TG_NAME"
check "target type is ip (mandatory for awsvpc)" "test \"\$(tgq TargetType)\" = ip"
check "protocol HTTP on port 80" \
  "test \"\$(tgq Protocol)\" = HTTP && test \"\$(tgq Port)\" = 80"
check "target group lives in usms-vpc" "test \"\$(tgq VpcId)\" = $USMS_VPC_ID"
check "health check is GET / with matcher 200" \
  "test \"\$(tgq HealthCheckPath)\" = / && test \"\$(tgq 'Matcher.HttpCode')\" = 200"
check "deregistration delay is 30 seconds" \
  "test \"\$(tgattr deregistration_delay.timeout_seconds)\" = 30"

echo "== Lab 05 listener and rule =="
check "a listener exists on port 80" "test \"\$LARN\" != none && test -n \"\$LARN\""
check "listener default action forwards to $USMS_TG_NAME" \
  "aws elbv2 describe-listeners --listener-arns \"\$LARN\" --query 'Listeners[0].DefaultActions[0].TargetGroupArn' --output text | grep -q ':targetgroup/$USMS_TG_NAME/'"
check "at least one non-default rule exists" \
  "test \"\$(aws elbv2 describe-rules --listener-arn \"\$LARN\" --query 'length(Rules[?IsDefault==\`false\`])' --output text)\" -ge 1"
check "the non-default rule returns a fixed-response 200" \
  "aws elbv2 describe-rules --listener-arn \"\$LARN\" --query 'Rules[?IsDefault==\`false\`].Actions[0].FixedResponseConfig.StatusCode' --output text | grep -q 200"

echo "== Lab 05 service wiring =="
check "service has exactly ONE loadBalancers entry" "test \"\$(svcq 'length(loadBalancers)')\" = 1"
check "it names $USMS_TG_NAME" \
  "svcq 'loadBalancers[0].targetGroupArn' | grep -q ':targetgroup/$USMS_TG_NAME/'"
check "containerName is $USMS_ENROLMENT_CONTAINER" \
  "test \"\$(svcq 'loadBalancers[0].containerName')\" = $USMS_ENROLMENT_CONTAINER"
check "containerPort is 80" "test \"\$(svcq 'loadBalancers[0].containerPort')\" = 80"
check "healthCheckGracePeriodSeconds is set (not None, not 0)" \
  "test \"\$(svcq healthCheckGracePeriodSeconds)\" != None && test \"\$(svcq healthCheckGracePeriodSeconds)\" -gt 0"
check "service still spans two private subnets" \
  "test \"\$(svcq 'length(networkConfiguration.awsvpcConfiguration.subnets)')\" = 2"
check "service still assigns NO public IP" \
  "test \"\$(svcq 'networkConfiguration.awsvpcConfiguration.assignPublicIp')\" = DISABLED"
check "exactly ONE deployment (nothing stuck mid-roll)" \
  "test \"\$(svcq 'length(deployments)')\" = 1"

echo "== Files and Git hygiene =="
check "configs/lab-05.env exists" "test -f configs/lab-05.env"
check "configs/lab-05.env has no empty values" \
  "! grep -qE 'export [A-Z_]+=\$|=None\$' configs/lab-05.env"
check "policies/usms-alb-sg-ingress.json is valid JSON" \
  "python3 -m json.tool policies/usms-alb-sg-ingress.json"
check "policies/usms-enrolment-sg-ingress-alb.json is valid JSON" \
  "python3 -m json.tool policies/usms-enrolment-sg-ingress-alb.json"
check "templates/lab-05-listener-default-actions.json is valid JSON" \
  "python3 -m json.tool templates/lab-05-listener-default-actions.json"
check "templates/lab-05-rule-conditions.json is valid JSON" \
  "python3 -m json.tool templates/lab-05-rule-conditions.json"
check "templates/lab-05-rule-actions.json is valid JSON" \
  "python3 -m json.tool templates/lab-05-rule-actions.json"
check "templates/lab-05-service-load-balancers.json is valid JSON" \
  "python3 -m json.tool templates/lab-05-service-load-balancers.json"
check "no Lab 05 document contains an unexpanded variable" \
  "! grep -q '[\$]' templates/lab-05-listener-default-actions.json templates/lab-05-service-load-balancers.json policies/usms-enrolment-sg-ingress-alb.json"
# Changed from the lab text: this repo deliberately tracks outputs/.gitkeep (the .gitignore
# uses outputs/* + !outputs/.gitkeep), so allow that one placeholder and fail on anything else.
check "no secret is tracked by git" "! git ls-files outputs/ | grep -v '^outputs/.gitkeep\$' | grep -q ."

echo; echo "PASS=$PASS  FAIL=$FAIL"

if [ "$FAIL" -ne 0 ]; then
  cat <<'REMEDY'

A failure under "== Environment ==" is the real problem, and most failures below it are
a consequence. Fix that block first:
  ./scripts/utilities/floci-storage-check.sh

A failure under "== Lab 02 to 04 dependencies ==" means an earlier lab's resource is
gone. Run verify-lab-02.sh, verify-lab-03.sh and verify-lab-04.sh before re-reading
anything here. Remember that verify-lab-04.sh is EXPECTED to report exactly one
failure after Step 13, on the usms-app-sg source check.
REMEDY
fi

[ "$FAIL" -eq 0 ]
