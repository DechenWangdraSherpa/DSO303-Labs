#!/usr/bin/env bash
# Print exactly which identity and endpoint the AWS CLI is currently using,
# and refuse to stay quiet if it is not Floci.
set -Eeuo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$REPO_ROOT/configs/course.env"

echo "AWS_PROFILE         = ${AWS_PROFILE:-<unset>}"
echo "AWS_ENDPOINT_URL    = ${AWS_ENDPOINT_URL:-<unset, using profile>}"
echo "configured endpoint = $(aws configure get endpoint_url || echo '<none>')"
echo "configured region   = $(aws configure get region || echo '<none>')"
echo "---"
aws sts get-caller-identity --output table

acct="$(aws sts get-caller-identity --query Account --output text)"
if [ "$acct" = "$ACCOUNT_ID" ]; then
  printf '\033[1;32m[ok] Account %s — this is Floci, not real AWS.\033[0m\n' "$acct"
else
  printf '\033[1;31m[DANGER] Account %s is NOT the Floci account (%s).\033[0m\n' "$acct" "$ACCOUNT_ID"
  printf '\033[1;31mYou may be pointed at REAL AWS. Stop and re-check your profile.\033[0m\n'
  exit 1
fi
