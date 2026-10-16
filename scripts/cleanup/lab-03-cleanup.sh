#!/usr/bin/env bash
# END OF COURSE ONLY. Terminates Lab 03 compute, dependencies first.
# Run this BEFORE scripts/cleanup/lab-02-cleanup.sh - a VPC with running
# instances in it cannot be deleted.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-03.env"

cat <<'WARN'
============================================================
  This TERMINATES usms-web-01 and usms-db-01, releases the
  Elastic IP, deletes the data volume, deregisters the AMI
  and deletes the key pair. None of it is reversible.
  Run this BEFORE lab-02-cleanup.sh.
============================================================
WARN

read -r -p 'Type exactly: DELETE USMS COMPUTE  > ' answer
[ "$answer" = "DELETE USMS COMPUTE" ] || { echo "aborted"; exit 1; }

say() { printf '\n-- %s\n' "$1"; }

say "disassociate and release the Elastic IP"
if [ "${USMS_WEB_EIP_ALLOC:-None}" != "None" ]; then
  assoc=$(aws ec2 describe-addresses --allocation-ids "$USMS_WEB_EIP_ALLOC" \
            --query 'Addresses[0].AssociationId' --output text)
  [ "$assoc" != "None" ] && aws ec2 disassociate-address --association-id "$assoc" || true
  aws ec2 release-address --allocation-id "$USMS_WEB_EIP_ALLOC" || true
fi

say "detach and delete the data volume"
if [ "${USMS_WEB_DATA_VOLUME:-None}" != "None" ]; then
  aws ec2 detach-volume --volume-id "$USMS_WEB_DATA_VOLUME" || true
  aws ec2 wait volume-available --volume-ids "$USMS_WEB_DATA_VOLUME" || sleep 10
  aws ec2 delete-volume --volume-id "$USMS_WEB_DATA_VOLUME" || true
fi

say "terminate instances"
ids=""
for i in "${USMS_WEB_INSTANCE:-None}" "${USMS_DB_INSTANCE:-None}"; do
  [ "$i" != "None" ] && ids="$ids $i"
done
if [ -n "$ids" ]; then
  # shellcheck disable=SC2086
  aws ec2 terminate-instances --instance-ids $ids || true
  # shellcheck disable=SC2086
  aws ec2 wait instance-terminated --instance-ids $ids || sleep 20
fi

say "deregister the golden AMI"
[ "${USMS_WEB_AMI:-None}" != "None" ] && \
  aws ec2 deregister-image --image-id "$USMS_WEB_AMI" || true

say "delete the key pair, and the private key on disk"
aws ec2 delete-key-pair --key-name "${USMS_KEY_PAIR:-usms-app-key}" || true
rm -f outputs/usms-app-key.pem

echo; echo "Lab 03 teardown complete. You may now run lab-02-cleanup.sh."
