#!/usr/bin/env bash
# END OF COURSE ONLY. Removes Lab 04, dependencies first.
# Order: service (scaled to 0) -> task definitions -> cluster -> security group -> IAM -> log group.
# Run this AFTER scripts/cleanup/lab-06-cleanup.sh and scripts/cleanup/lab-05-cleanup.sh,
# and BEFORE scripts/cleanup/lab-02-cleanup.sh.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-04.env"

cat <<'WARN'
============================================================
  This deletes the USMS enrolment service, its ECS cluster,
  its security group, both ECS IAM roles and its log group.

  Lab 05, Lab 06 and a later storage lab all depend on parts
  of it. None of this is reversible.
  Run this AFTER lab-06-cleanup.sh and lab-05-cleanup.sh,
  and BEFORE lab-02-cleanup.sh.
============================================================
WARN

read -r -p 'Type exactly: DELETE USMS ECS  > ' answer
[ "$answer" = "DELETE USMS ECS" ] || { echo "aborted"; exit 1; }

say() { printf '\n-- %s\n' "$1"; }

say "service: scale to zero first, then delete"
aws ecs update-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" \
  --desired-count 0 >/dev/null || true
aws ecs wait services-stable --cluster "$USMS_ECS_CLUSTER" \
  --services "$USMS_ENROLMENT_SERVICE" || sleep 20
aws ecs delete-service --cluster "$USMS_ECS_CLUSTER" --service "$USMS_ENROLMENT_SERVICE" \
  --force >/dev/null || true

say "task definition revisions"
for arn in $(aws ecs list-task-definitions --family-prefix "$USMS_ENROLMENT_TASK_FAMILY" \
               --query 'taskDefinitionArns[]' --output text); do
  aws ecs deregister-task-definition --task-definition "$arn" >/dev/null || true
done

say "cluster"
aws ecs delete-cluster --cluster "$USMS_ECS_CLUSTER" >/dev/null || true

say "security group (nothing may still reference it)"
[ -n "${USMS_ENROLMENT_SG:-}" ] && \
  aws ec2 delete-security-group --group-id "$USMS_ENROLMENT_SG" || true

say "IAM: detach before delete"
aws iam detach-role-policy --role-name "$USMS_ECS_EXEC_ROLE" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${USMS_POLICY_ECS_EXEC}" || true
aws iam detach-role-policy --role-name "$USMS_ECS_TASK_ROLE" \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/USMSStudentDataReadWrite" || true
aws iam delete-role --role-name "$USMS_ECS_EXEC_ROLE" || true
aws iam delete-role --role-name "$USMS_ECS_TASK_ROLE" || true
aws iam delete-policy \
  --policy-arn "arn:aws:iam::${ACCOUNT_ID}:policy/${USMS_POLICY_ECS_EXEC}" || true

say "log group"
[ -n "${USMS_LOG_GROUP_ENROLMENT:-}" ] && \
  aws logs delete-log-group --log-group-name "$USMS_LOG_GROUP_ENROLMENT" || true

echo; echo "Lab 04 teardown complete. lab-03-cleanup.sh and lab-02-cleanup.sh may now run, in that order."
