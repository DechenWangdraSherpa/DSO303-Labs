#!/usr/bin/env bash
# END OF COURSE ONLY. Deletes the entire Lab 02 network, dependencies first.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-02.env"

cat <<'WARN'
============================================================
  This deletes the ENTIRE USMS VPC and everything in it.
  Labs 03, 04, 05 and 06 all depend on it.
  Terminate all EC2 instances (Lab 03) BEFORE running this.
============================================================
WARN

read -r -p 'Type exactly: DELETE USMS NETWORK  > ' answer
[ "$answer" = "DELETE USMS NETWORK" ] || { echo "aborted"; exit 1; }

say() { printf '\n-- %s\n' "$1"; }

say "NAT gateway"
if [ "${USMS_NAT_GW:-None}" != "None" ]; then
  aws ec2 delete-nat-gateway --nat-gateway-id "$USMS_NAT_GW" || true
  aws ec2 wait nat-gateway-deleted --nat-gateway-ids "$USMS_NAT_GW" || sleep 20
fi

say "Elastic IP"
[ "${USMS_NAT_EIP_ALLOC:-None}" != "None" ] && \
  aws ec2 release-address --allocation-id "$USMS_NAT_EIP_ALLOC" || true

say "VPC endpoint"
[ "${USMS_S3_ENDPOINT:-None}" != "None" ] && \
  aws ec2 delete-vpc-endpoints --vpc-endpoint-ids "$USMS_S3_ENDPOINT" || true

say "route table associations"
for rt in "$USMS_PUBLIC_RT" "$USMS_PRIVATE_RT"; do
  [ "$rt" = "None" ] && continue
  for assoc in $(aws ec2 describe-route-tables --route-table-ids "$rt" \
                   --query 'RouteTables[0].Associations[?!Main].RouteTableAssociationId' \
                   --output text); do
    aws ec2 disassociate-route-table --association-id "$assoc" || true
  done
  aws ec2 delete-route-table --route-table-id "$rt" || true
done

say "network ACL"
[ "${USMS_PRIVATE_NACL:-None}" != "None" ] && \
  aws ec2 delete-network-acl --network-acl-id "$USMS_PRIVATE_NACL" || true

say "security groups (db first: app is referenced by it)"
[ "${USMS_DB_SG:-None}"  != "None" ] && aws ec2 delete-security-group --group-id "$USMS_DB_SG"  || true
[ "${USMS_APP_SG:-None}" != "None" ] && aws ec2 delete-security-group --group-id "$USMS_APP_SG" || true

say "subnets"
for s in "$USMS_PUBLIC_SUBNET_A" "$USMS_PUBLIC_SUBNET_B" \
         "$USMS_PRIVATE_SUBNET_A" "$USMS_PRIVATE_SUBNET_B"; do
  [ "$s" = "None" ] && continue
  aws ec2 delete-subnet --subnet-id "$s" || true
done

say "internet gateway"
if [ "${USMS_IGW_ID:-None}" != "None" ]; then
  aws ec2 detach-internet-gateway --internet-gateway-id "$USMS_IGW_ID" --vpc-id "$USMS_VPC_ID" || true
  aws ec2 delete-internet-gateway --internet-gateway-id "$USMS_IGW_ID" || true
fi

say "VPC"
aws ec2 delete-vpc --vpc-id "$USMS_VPC_ID" || true

echo; echo "Lab 02 teardown complete."
