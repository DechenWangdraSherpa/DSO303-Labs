#!/usr/bin/env bash
# Verify every Lab 03 artefact exists and is configured correctly.
# Exit 1 if anything is missing. Read-only; safe to run at any time.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
source "$REPO_ROOT/configs/course.env"
source "$REPO_ROOT/configs/lab-01.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-02.env" 2>/dev/null || true
source "$REPO_ROOT/configs/lab-03.env" 2>/dev/null || true

: "${USMS_VPC_ID:=none}"
: "${USMS_PUBLIC_SUBNET_A:=none}"
: "${USMS_PRIVATE_SUBNET_A:=none}"
: "${USMS_APP_SG:=none}"
: "${USMS_DB_SG:=none}"
: "${USMS_INSTANCE_PROFILE:=none}"
: "${USMS_WEB_INSTANCE:=none}"
: "${USMS_DB_INSTANCE:=none}"
: "${USMS_WEB_DATA_VOLUME:=none}"
: "${USMS_WEB_EIP_ALLOC:=none}"
: "${USMS_WEB_AMI:=none}"

PASS=0; FAIL=0
check() {
  if eval "$2" >/dev/null 2>&1; then printf "  ok   %s\n" "$1"; PASS=$((PASS+1))
  else printf "  FAIL %s\n" "$1"; FAIL=$((FAIL+1)); fi
}

# Helper: one instance field, by instance id.
q() { aws ec2 describe-instances --instance-ids "$1" \
        --query "Reservations[0].Instances[0].$2" --output text; }

echo "== Environment =="
check "Floci container running" \
  "test \"\$(docker container inspect $FLOCI_CONTAINER_NAME --format '{{.State.Running}}')\" = true"
check "Storage mode is NOT memory" \
  "docker container inspect $FLOCI_CONTAINER_NAME --format '{{range .Config.Env}}{{println .}}{{end}}' | grep -qE '^FLOCI_STORAGE_MODE=(hybrid|persistent|wal)$'"
check "AWS CLI reaches Floci" "aws sts get-caller-identity"
check "Account is 000000000000" \
  "test \"\$(aws sts get-caller-identity --query Account --output text)\" = 000000000000"

echo "== Lab 01 and Lab 02 dependencies =="
check "usms-vpc still exists"      "aws ec2 describe-vpcs --vpc-ids $USMS_VPC_ID"
check "usms-public-subnet-a exists" "aws ec2 describe-subnets --subnet-ids $USMS_PUBLIC_SUBNET_A"
check "usms-ec2-app-profile exists" \
  "aws iam get-instance-profile --instance-profile-name $USMS_INSTANCE_PROFILE"

echo "== Lab 03 key pair =="
check "key pair usms-app-key exists" "aws ec2 describe-key-pairs --key-names usms-app-key"
check "private key file present"     "test -f outputs/usms-app-key.pem"
check "private key is chmod 600" \
  "test \"\$(stat -c '%a' outputs/usms-app-key.pem 2>/dev/null || stat -f '%Lp' outputs/usms-app-key.pem)\" = 600"

echo "== Lab 03 web tier =="
check "usms-web-01 exists"           "aws ec2 describe-instances --instance-ids $USMS_WEB_INSTANCE"
check "usms-web-01 is running"       "test \"\$(q $USMS_WEB_INSTANCE State.Name)\" = running"
check "usms-web-01 is t3.micro"      "test \"\$(q $USMS_WEB_INSTANCE InstanceType)\" = t3.micro"
check "usms-web-01 is in usms-public-subnet-a" \
  "test \"\$(q $USMS_WEB_INSTANCE SubnetId)\" = $USMS_PUBLIC_SUBNET_A"
check "usms-web-01 carries usms-app-sg" \
  "test \"\$(q $USMS_WEB_INSTANCE 'SecurityGroups[0].GroupId')\" = $USMS_APP_SG"
check "usms-web-01 has an instance profile" \
  "test \"\$(q $USMS_WEB_INSTANCE 'IamInstanceProfile.Arn')\" != None"
check "that profile is usms-ec2-app-profile" \
  "q $USMS_WEB_INSTANCE 'IamInstanceProfile.Arn' | grep -q $USMS_INSTANCE_PROFILE"
check "usms-web-01 has user data stored" \
  "test -n \"\$(aws ec2 describe-instance-attribute --instance-id $USMS_WEB_INSTANCE --attribute userData --query 'UserData.Value' --output text)\""
check "usms-web-01 has a public address" \
  "test \"\$(q $USMS_WEB_INSTANCE PublicIpAddress)\" != None"
check "an Elastic IP is associated with usms-web-01" \
  "test \"\$(aws ec2 describe-addresses --allocation-ids $USMS_WEB_EIP_ALLOC --query 'Addresses[0].InstanceId' --output text)\" = $USMS_WEB_INSTANCE"

echo "== Lab 03 storage =="
check "usms-web-data-vol exists"     "aws ec2 describe-volumes --volume-ids $USMS_WEB_DATA_VOLUME"
check "data volume is attached to usms-web-01" \
  "test \"\$(aws ec2 describe-volumes --volume-ids $USMS_WEB_DATA_VOLUME --query 'Volumes[0].Attachments[0].InstanceId' --output text)\" = $USMS_WEB_INSTANCE"
check "data volume survives termination (DeleteOnTermination is False)" \
  "test \"\$(aws ec2 describe-volumes --volume-ids $USMS_WEB_DATA_VOLUME --query 'Volumes[0].Attachments[0].DeleteOnTermination' --output text)\" = False"
check "data volume is in the same AZ as the instance" \
  "test \"\$(aws ec2 describe-volumes --volume-ids $USMS_WEB_DATA_VOLUME --query 'Volumes[0].AvailabilityZone' --output text)\" = \"\$(q $USMS_WEB_INSTANCE 'Placement.AvailabilityZone')\""

echo "== Lab 03 data tier =="
check "usms-db-01 exists"            "aws ec2 describe-instances --instance-ids $USMS_DB_INSTANCE"
check "usms-db-01 is in usms-private-subnet-a" \
  "test \"\$(q $USMS_DB_INSTANCE SubnetId)\" = $USMS_PRIVATE_SUBNET_A"
check "usms-db-01 carries usms-db-sg" \
  "test \"\$(q $USMS_DB_INSTANCE 'SecurityGroups[0].GroupId')\" = $USMS_DB_SG"
check "usms-db-01 has NO public address" \
  "test \"\$(q $USMS_DB_INSTANCE PublicIpAddress)\" = None"
check "usms-db-01 has NO instance profile" \
  "test \"\$(q $USMS_DB_INSTANCE 'IamInstanceProfile.Arn')\" = None"

echo "== Lab 03 image =="
check "usms-web-golden AMI exists"   "aws ec2 describe-images --image-ids $USMS_WEB_AMI"

echo "== Tagging =="
check "at least two instances tagged Project=USMS" \
  "test \"\$(aws ec2 describe-instances --filters Name=tag:Project,Values=USMS --query 'length(Reservations[].Instances[])' --output text)\" -ge 2"

echo "== Files and Git hygiene =="
check "configs/lab-03.env exists"    "test -f configs/lab-03.env"
check "configs/lab-03.env has no empty values" \
  "! grep -qE 'export [A-Z_]+=$|=None$' configs/lab-03.env"
check "user-data.sh exists and parses" "bash -n labs/lab-03-ec2/user-data.sh"
check "run-instances request is valid JSON" \
  "python3 -m json.tool templates/lab-03-run-instances.json"
check "the private key is NOT tracked by git" \
  "! git ls-files | grep -q 'usms-app-key.pem'"

echo; echo "PASS=$PASS  FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
