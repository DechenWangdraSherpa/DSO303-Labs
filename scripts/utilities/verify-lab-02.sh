#!/usr/bin/env bash
# Verify every Lab 02 artefact exists and is configured correctly.
# Exit 1 if anything is missing. Safe to run at any time; read-only.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true

: "${USMS_VPC_ID:=none}"
: "${USMS_IGW_ID:=none}"
: "${USMS_PUBLIC_SUBNET_A:=none}"
: "${USMS_PRIVATE_SUBNET_A:=none}"
: "${USMS_PUBLIC_RT:=none}"
: "${USMS_PRIVATE_RT:=none}"
: "${USMS_APP_SG:=none}"
: "${USMS_DB_SG:=none}"
: "${USMS_PRIVATE_NACL:=none}"
: "${USMS_S3_ENDPOINT:=none}"

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

echo "== Lab 01 dependencies still present =="
check "role usms-developer-role"      "aws iam get-role --role-name usms-developer-role"
check "instance profile usms-ec2-app-profile" \
  "aws iam get-instance-profile --instance-profile-name usms-ec2-app-profile"

echo "== Lab 02 resources =="
check "usms-vpc exists"               "aws ec2 describe-vpcs --vpc-ids $USMS_VPC_ID"
check "vpc CIDR is 10.0.0.0/16" \
  "test \"\$(aws ec2 describe-vpcs --vpc-ids $USMS_VPC_ID --query 'Vpcs[0].CidrBlock' --output text)\" = 10.0.0.0/16"
check "vpc DNS hostnames enabled" \
  "test \"\$(aws ec2 describe-vpc-attribute --vpc-id $USMS_VPC_ID --attribute enableDnsHostnames --query 'EnableDnsHostnames.Value' --output text)\" = True"

check "usms-igw exists"               "aws ec2 describe-internet-gateways --internet-gateway-ids $USMS_IGW_ID"
check "usms-igw ATTACHED to usms-vpc" \
  "test \"\$(aws ec2 describe-internet-gateways --internet-gateway-ids $USMS_IGW_ID --query 'InternetGateways[0].Attachments[0].VpcId' --output text)\" = $USMS_VPC_ID"

check "public subnet a exists"        "aws ec2 describe-subnets --subnet-ids $USMS_PUBLIC_SUBNET_A"
check "public subnet a auto-assigns public IP" \
  "test \"\$(aws ec2 describe-subnets --subnet-ids $USMS_PUBLIC_SUBNET_A --query 'Subnets[0].MapPublicIpOnLaunch' --output text)\" = True"
check "private subnet a exists"       "aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_A"
check "private subnet a does NOT auto-assign public IP" \
  "test \"\$(aws ec2 describe-subnets --subnet-ids $USMS_PRIVATE_SUBNET_A --query 'Subnets[0].MapPublicIpOnLaunch' --output text)\" = False"

check "public rt has a default route to an igw" \
  "aws ec2 describe-route-tables --route-table-ids $USMS_PUBLIC_RT --query 'RouteTables[0].Routes[].GatewayId' --output text | grep -q '^igw-\|	igw-'"
check "public subnet a is associated with usms-public-rt" \
  "test \"\$(aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=$USMS_PUBLIC_SUBNET_A --query 'RouteTables[0].RouteTableId' --output text)\" = $USMS_PUBLIC_RT"
check "private subnet a is associated with usms-private-rt" \
  "test \"\$(aws ec2 describe-route-tables --filters Name=association.subnet-id,Values=$USMS_PRIVATE_SUBNET_A --query 'RouteTables[0].RouteTableId' --output text)\" = $USMS_PRIVATE_RT"
check "private rt has NO route to an internet gateway" \
  "! aws ec2 describe-route-tables --route-table-ids $USMS_PRIVATE_RT --query 'RouteTables[0].Routes[].GatewayId' --output text | grep -q 'igw-'"

check "usms-app-sg exists"            "aws ec2 describe-security-groups --group-ids $USMS_APP_SG"
check "usms-app-sg allows tcp 80"     \
  "aws ec2 describe-security-groups --group-ids $USMS_APP_SG --query 'SecurityGroups[0].IpPermissions[].FromPort' --output text | grep -qw 80"
check "usms-db-sg exists"             "aws ec2 describe-security-groups --group-ids $USMS_DB_SG"
check "usms-db-sg is sourced from usms-app-sg (not a CIDR)" \
  "test \"\$(aws ec2 describe-security-groups --group-ids $USMS_DB_SG --query 'SecurityGroups[0].IpPermissions[0].UserIdGroupPairs[0].GroupId' --output text)\" = $USMS_APP_SG"

check "usms-private-nacl exists"      "aws ec2 describe-network-acls --network-acl-ids $USMS_PRIVATE_NACL"
check "usms-private-nacl is attached to the private subnet" \
  "test \"\$(aws ec2 describe-network-acls --filters Name=association.subnet-id,Values=$USMS_PRIVATE_SUBNET_A --query 'NetworkAcls[0].NetworkAclId' --output text)\" = $USMS_PRIVATE_NACL"
check "usms-private-nacl is not the default ACL" \
  "test \"\$(aws ec2 describe-network-acls --network-acl-ids $USMS_PRIVATE_NACL --query 'NetworkAcls[0].IsDefault' --output text)\" = False"

check "usms-s3-endpoint exists"       "aws ec2 describe-vpc-endpoints --vpc-endpoint-ids $USMS_S3_ENDPOINT"

echo "== Tagging =="
check "every Lab 02 resource carries Project=USMS" \
  "test \"\$(aws ec2 describe-tags --filters Name=tag:Project,Values=USMS Name=key,Values=Name --query 'length(Tags)' --output text)\" -ge 10"

echo "== Files and Git hygiene =="
check "configs/lab-02.env exists"     "test -f configs/lab-02.env"
check "configs/lab-02.env has no empty values" \
  "! grep -qE 'export [A-Z_]+=$|=None$' configs/lab-02.env"
check "policies/usms-db-sg-ingress.json is valid JSON" \
  "python3 -m json.tool policies/usms-db-sg-ingress.json"
check "no secret is tracked by git" \
  "! git ls-files outputs/ | grep -v '^outputs/\.gitkeep$' | grep -q ."
check ".gitignore uses outputs/* not outputs/" "grep -q '^outputs/\*' .gitignore"

echo; echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
