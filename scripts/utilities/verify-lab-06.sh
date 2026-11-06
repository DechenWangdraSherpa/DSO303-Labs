#!/usr/bin/env bash
# Verify every Lab 06 artefact exists and is configured correctly.
# Read-only: this script inspects and changes nothing. Safe to run at any time.
# Exit 0 if every check passes, 1 otherwise.
#
# EXPECTED: PASS=42  FAIL=0
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-03.env"  2>/dev/null || true
source "$REPO_ROOT/configs/lab-04.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-05.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-06.env" 2>/dev/null || true

# Defaults so that set -u cannot abort the script before it has told you anything.
: "${USMS_PRIVATE_SUBNET_A:=none}"
: "${USMS_PRIVATE_SUBNET_B:=none}"
: "${USMS_ECS_CLUSTER:=usms-ecs-cluster}"
: "${USMS_ENROLMENT_SERVICE:=usms-enrolment-svc}"
: "${USMS_ECS_DESIRED_BASELINE:=2}"
: "${USMS_TG_NAME:=usms-enrolment-tg}"
: "${USMS_SCALABLE_DIMENSION:=ecs:service:DesiredCount}"
: "${USMS_POLICY_CPU_TT:=usms-enrolment-cpu-target-tracking}"
: "${USMS_POLICY_REQ_TT:=usms-enrolment-requests-target-tracking}"
: "${USMS_POLICY_STEP_OUT:=usms-enrolment-queue-step-out}"
: "${USMS_ALARM_QUEUE_HIGH:=usms-enrolment-queue-high}"
: "${USMS_METRIC_NAMESPACE:=USMS/Enrolment}"
: "${USMS_METRIC_NAME:=EnrolmentQueueDepth}"
: "${USMS_SCHEDULED_OUT:=usms-enrolment-morning-scale-out}"
: "${USMS_SCHEDULED_IN:=usms-enrolment-evening-scale-in}"
: "${USMS_SCALE_MIN:=2}"
: "${USMS_SCALE_MAX:=10}"

# The resource ID is derived, never trusted from the env file, for the reason Step 14 gives.
RID="${USMS_SCALABLE_RESOURCE_ID:-}"
if [ -z "$RID" ] || [ "$RID" = "None" ]; then
  SVC_ARN=$(aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" \
              --services "$USMS_ENROLMENT_SERVICE" \
              --query 'services[0].serviceArn' --output text 2>/dev/null || echo "")
  RID="${SVC_ARN##*:}"
fi
[ -n "$RID" ] || RID="service/${USMS_ECS_CLUSTER}/${USMS_ENROLMENT_SERVICE}"
EXPECTED_RID="service/${USMS_ECS_CLUSTER}/${USMS_ENROLMENT_SERVICE}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

# tgt <jmespath>            -> one field from the scalable target
tgt()  { aws application-autoscaling describe-scalable-targets --service-namespace ecs \
           --resource-ids "$RID" --query "ScalableTargets[0].$1" --output text; }
# pol <policy-name> <jmespath> -> one field from a scaling policy
pol()  { aws application-autoscaling describe-scaling-policies --service-namespace ecs \
           --resource-id "$RID" --policy-names "$1" --query "ScalingPolicies[0].$2" --output text; }
# sch <action-name> <jmespath> -> one field from a scheduled action
sch()  { aws application-autoscaling describe-scheduled-actions --service-namespace ecs \
           --resource-id "$RID" --scheduled-action-names "$1" \
           --query "ScheduledActions[0].$2" --output text; }
# svcq <jmespath>           -> one field from the ECS service
svcq() { aws ecs describe-services --cluster "$USMS_ECS_CLUSTER" \
           --services "$USMS_ENROLMENT_SERVICE" --query "services[0].$1" --output text; }
# alm <jmespath>            -> one field from the custom alarm
alm()  { aws cloudwatch describe-alarms --alarm-names "$USMS_ALARM_QUEUE_HIGH" \
           --query "MetricAlarms[0].$1" --output text; }

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "Account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Lab 02 to 05 dependencies =="
check "usms-private-subnet-a exists" "aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_A"
check "usms-private-subnet-b exists" "aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_B"
check "cluster $USMS_ECS_CLUSTER is ACTIVE" \
  "test \"\$(aws ecs describe-clusters --clusters $USMS_ECS_CLUSTER --query 'clusters[0].status' --output text)\" = ACTIVE"
check "service $USMS_ENROLMENT_SERVICE is ACTIVE" "test \"\$(svcq status)\" = ACTIVE"
check "service still has exactly ONE loadBalancers entry" \
  "test \"\$(svcq 'length(loadBalancers)')\" = 1"
check "target group $USMS_TG_NAME still has target type ip" \
  "test \"\$(aws elbv2 describe-target-groups --names $USMS_TG_NAME --query 'TargetGroups[0].TargetType' --output text)\" = ip"

echo "== Lab 06 scalable target =="
check "exactly ONE scalable target in the ecs namespace" \
  "test \"\$(aws application-autoscaling describe-scalable-targets --service-namespace ecs --query 'length(ScalableTargets)' --output text)\" = 1"
check "the resource ID is $EXPECTED_RID" "test \"\$(tgt ResourceId)\" = \"$EXPECTED_RID\""
check "the scalable dimension is ecs:service:DesiredCount" \
  "test \"\$(tgt ScalableDimension)\" = ecs:service:DesiredCount"
check "MinCapacity is the Lab 04 baseline of $USMS_ECS_DESIRED_BASELINE" \
  "test \"\$(tgt MinCapacity)\" = $USMS_ECS_DESIRED_BASELINE"
check "MaxCapacity is 10" "test \"\$(tgt MaxCapacity)\" = 10"
check "NO suspension switch was left true" \
  "test \"\$(tgt 'SuspendedState.*' | grep -ci true)\" = 0"

echo "== Lab 06 scaling policies =="
check "CPU target tracking policy $USMS_POLICY_CPU_TT exists" \
  "pol $USMS_POLICY_CPU_TT PolicyName | grep -qx $USMS_POLICY_CPU_TT"
check "its policy type is TargetTrackingScaling" \
  "test \"\$(pol $USMS_POLICY_CPU_TT PolicyType)\" = TargetTrackingScaling"
check "its predefined metric is ECSServiceAverageCPUUtilization" \
  "test \"\$(pol $USMS_POLICY_CPU_TT 'TargetTrackingScalingPolicyConfiguration.PredefinedMetricSpecification.PredefinedMetricType')\" = ECSServiceAverageCPUUtilization"
check "its target value is 50" \
  "test \"\$(pol $USMS_POLICY_CPU_TT 'TargetTrackingScalingPolicyConfiguration.TargetValue' | cut -d. -f1)\" = 50"
check "scale-out cooldown 60 and scale-in cooldown 300 (deliberately asymmetric)" \
  "test \"\$(pol $USMS_POLICY_CPU_TT 'TargetTrackingScalingPolicyConfiguration.ScaleOutCooldown')\" = 60 && test \"\$(pol $USMS_POLICY_CPU_TT 'TargetTrackingScalingPolicyConfiguration.ScaleInCooldown')\" = 300"
check "step scaling policy $USMS_POLICY_STEP_OUT exists with type StepScaling" \
  "test \"\$(pol $USMS_POLICY_STEP_OUT PolicyType)\" = StepScaling"
check "the step policy has 2+ adjustments and an OPEN-ENDED top interval" \
  "test \"\$(pol $USMS_POLICY_STEP_OUT 'length(StepScalingPolicyConfiguration.StepAdjustments)')\" -ge 2 && test \"\$(pol $USMS_POLICY_STEP_OUT 'StepScalingPolicyConfiguration.StepAdjustments[-1].MetricIntervalUpperBound')\" = None"

echo "== Lab 06 alarms =="
check "custom alarm $USMS_ALARM_QUEUE_HIGH exists" "alm AlarmName | grep -qx $USMS_ALARM_QUEUE_HIGH"
check "it watches $USMS_METRIC_NAMESPACE $USMS_METRIC_NAME" \
  "test \"\$(alm Namespace)\" = '$USMS_METRIC_NAMESPACE' && test \"\$(alm MetricName)\" = '$USMS_METRIC_NAME'"
check "it INVOKES the step policy (the link you made yourself)" \
  "alm 'AlarmActions[]' | grep -q 'policyName/$USMS_POLICY_STEP_OUT'"
check "target tracking created 2+ managed alarms for you" \
  "test \"\$(aws cloudwatch describe-alarms --alarm-name-prefix 'TargetTracking-$RID' --query 'length(MetricAlarms)' --output text)\" -ge 2"

echo "== Lab 06 scheduled actions =="
check "morning action $USMS_SCHEDULED_OUT exists" \
  "sch $USMS_SCHEDULED_OUT ScheduledActionName | grep -qx $USMS_SCHEDULED_OUT"
check "evening action $USMS_SCHEDULED_IN exists" \
  "sch $USMS_SCHEDULED_IN ScheduledActionName | grep -qx $USMS_SCHEDULED_IN"
check "the morning action raises the floor ABOVE the evening action's" \
  "test \"\$(sch $USMS_SCHEDULED_OUT 'ScalableTargetAction.MinCapacity')\" -gt \"\$(sch $USMS_SCHEDULED_IN 'ScalableTargetAction.MinCapacity')\""

echo "== Lab 06 service state =="
check "desiredCount is INSIDE the scalable target's bounds" \
  "test \"\$(svcq desiredCount)\" -ge \"\$(tgt MinCapacity)\" && test \"\$(svcq desiredCount)\" -le \"\$(tgt MaxCapacity)\""
check "desiredCount is back at the baseline of $USMS_ECS_DESIRED_BASELINE" \
  "test \"\$(svcq desiredCount)\" = $USMS_ECS_DESIRED_BASELINE"
check "exactly ONE deployment (nothing stuck mid-roll)" \
  "test \"\$(svcq 'length(deployments)')\" = 1"

echo "== Lab 06 custom metric =="
check "the $USMS_METRIC_NAMESPACE namespace has at least one metric" \
  "test \"\$(aws cloudwatch list-metrics --namespace '$USMS_METRIC_NAMESPACE' --query 'length(Metrics)' --output text)\" -ge 1"

echo "== Files and Git hygiene =="
check "configs/lab-06.env exists" "test -f configs/lab-06.env"
check "configs/lab-06.env has no empty values and no None" \
  "! grep -qE 'export [A-Z_]+=\$|=None\$' configs/lab-06.env"
check "target tracking (cpu) document is valid JSON" \
  "python3 -m json.tool templates/lab-06-target-tracking-cpu.json"
check "target tracking (requests) document is valid JSON, or absent" \
  "! test -f templates/lab-06-target-tracking-requests.json || python3 -m json.tool templates/lab-06-target-tracking-requests.json"
check "step scaling document is valid JSON" \
  "python3 -m json.tool templates/lab-06-step-scaling-out.json"
check "suspended-state document is valid JSON and does NOT suspend scale-out" \
  "python3 -c \"import json,sys;d=json.load(open('templates/lab-06-suspended-state.json'));sys.exit(0 if d.get('DynamicScalingOutSuspended') is False else 1)\""
check "no Lab 06 document contains an unexpanded variable" \
  "! grep -l '[\$]' templates/lab-06-*.json"
# Changed from the lab text: this repo deliberately tracks outputs/.gitkeep (the .gitignore
# uses outputs/* + !outputs/.gitkeep), so allow that one placeholder and fail on anything else.
check "no secret is tracked by git" "! git ls-files outputs/ | grep -v '^outputs/.gitkeep\$' | grep -q ."

echo; echo "PASS=$PASS  FAIL=$FAIL"

if [ "$FAIL" -ne 0 ]; then
  cat <<'REMEDY'

A failure under "== Environment ==" is the real problem, and most failures below it are
a consequence. Fix that block first:
  ./scripts/utilities/floci-storage-check.sh

A failure under "== Lab 02 to 05 dependencies ==" means an earlier lab's resource is
gone or has been changed. Run verify-lab-04.sh and verify-lab-05.sh before re-reading
anything here. Remember that verify-lab-04.sh is EXPECTED to report exactly one
failure, on the usms-app-sg source check, unless you did Lab 05's Exercise 2.

Two failures are worth reading twice because they are silent in production:
  "NO suspension switch was left true"  -- a suspended target does not scale and does
                                           not say so. Step 13 part 3 clears it.
  "desiredCount is back at the baseline" -- a Step 11 or Step 12 experiment was not
                                           undone. Push the metric down FIRST, then set
                                           the count; see Step 12 part 6.
REMEDY
fi

[ "$FAIL" -eq 0 ]
