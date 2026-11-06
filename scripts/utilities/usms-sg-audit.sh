#!/usr/bin/env bash
# USMS security group audit. Reports findings; changes nothing.
#
# Four questions per group:
#   1. who can reach me            ingress: group-referenced, CIDR, or 0.0.0.0/0
#   2. what can I reach            egress: written, or the default allow-all
#   3. group or address            a CIDR source that could have been a group
#   4. attached to anything        groups with no network interfaces
#
# Read-only. Exit 0 if there are no HIGH findings, 1 otherwise.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/lab-02.env"  2>/dev/null || true

VPC="${1:-${USMS_VPC_ID:-}}"
if [ -z "$VPC" ] || [ "$VPC" = "none" ]; then
  echo "usage: $0 [vpc-id]   (or set USMS_VPC_ID in configs/lab-02.env)" >&2
  exit 2
fi

# One JSON document with every group in the VPC, plus how many interfaces each one is on.
aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" --output json \
  > /tmp/usms-sg-audit-$$.json || { echo "cannot read security groups" >&2; exit 2; }

for g in $(python3 -c "
import json;print(' '.join(s['GroupId'] for s in json.load(open('/tmp/usms-sg-audit-$$.json'))['SecurityGroups']))
"); do
  n=$(aws ec2 describe-network-interfaces --filters "Name=group-id,Values=$g" \
        --query 'length(NetworkInterfaces)' --output text 2>/dev/null || echo 0)
  echo "$g $n"
done > /tmp/usms-sg-enis-$$.txt

python3 - "/tmp/usms-sg-audit-$$.json" "/tmp/usms-sg-enis-$$.txt" << 'PY'
import json, sys

groups = json.load(open(sys.argv[1]))["SecurityGroups"]
enis = {}
for line in open(sys.argv[2]):
    parts = line.split()
    if len(parts) == 2:
        try:
            enis[parts[0]] = int(parts[1])
        except ValueError:
            enis[parts[0]] = 0

by_id = {g["GroupId"]: g.get("GroupName", g["GroupId"]) for g in groups}

def render(perms):
    """One readable line per rule."""
    out = []
    for p in perms:
        proto = p.get("IpProtocol", "-1")
        proto = "all" if proto == "-1" else proto
        lo, hi = p.get("FromPort"), p.get("ToPort")
        port = "all" if lo is None else (str(lo) if lo == hi else f"{lo}-{hi}")
        dests = []
        for r in p.get("IpRanges", []):
            dests.append(r.get("CidrIp"))
        for r in p.get("Ipv6Ranges", []):
            dests.append(r.get("CidrIpv6"))
        for r in p.get("UserIdGroupPairs", []):
            gid = r.get("GroupId")
            dests.append(f"sg:{by_id.get(gid, gid)}")
        for r in p.get("PrefixListIds", []):
            dests.append(f"pl:{r.get('PrefixListId')}")
        out.append((proto, port, dests or ["<none>"]))
    return out

high = med = low = 0
print("== USMS security group audit ==")
print()

for g in sorted(groups, key=lambda x: x.get("GroupName", "")):
    name = g.get("GroupName", g["GroupId"])
    gid = g["GroupId"]
    n = enis.get(gid, 0)
    findings = []

    print(f"{name}  ({gid})   interfaces: {n}")

    print("    ingress:")
    ing = render(g.get("IpPermissions", []))
    if not ing:
        print("        (none - nothing may reach anything wearing this group)")
    for proto, port, dests in ing:
        print(f"        {proto}/{port:<9} from {', '.join(dests)}")
        for d in dests:
            if d in ("0.0.0.0/0", "::/0"):
                findings.append(("HIGH", f"ingress {proto}/{port} from {d}"))
            elif d and d.startswith("10.") and d.endswith("/16"):
                findings.append(("MED", f"ingress {proto}/{port} from a whole VPC range ({d}) "
                                        "- could this be a group reference?"))

    print("    egress:")
    egr = g.get("IpPermissionsEgress", [])
    eg = render(egr)
    if not eg:
        print("        (none - nothing wearing this group may initiate anything)")
    for proto, port, dests in eg:
        print(f"        {proto}/{port:<9} to   {', '.join(dests)}")
    # the default rule, exactly as AWS writes it
    default_egress = any(
        p.get("IpProtocol") == "-1"
        and any(r.get("CidrIp") == "0.0.0.0/0" for r in p.get("IpRanges", []))
        for p in egr)
    if default_egress:
        findings.append(("MED", "egress is the DEFAULT allow-all rule - nobody wrote this"))

    if n == 0:
        findings.append(("LOW", "attached to no network interface"))

    for sev, text in findings:
        print(f"    {sev:<4} {text}")
        if sev == "HIGH":
            high += 1
        elif sev == "MED":
            med += 1
        else:
            low += 1
    print()

print(f"HIGH={high}  MED={med}  LOW={low}  groups={len(groups)}")
sys.exit(1 if high else 0)
PY

rm -f /tmp/usms-sg-audit-$$.json /tmp/usms-sg-enis-$$.txt
