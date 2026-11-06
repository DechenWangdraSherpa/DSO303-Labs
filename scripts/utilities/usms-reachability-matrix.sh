#!/usr/bin/env bash
# USMS reachability matrix.
#
# For every security group in the VPC, computes which OTHER groups may open a
# connection to it, on what, and whether the internet may. The verdict is derived
# ONLY from rules -- never from a group's name, its tags, or its description.
#
# Read-only. Always exits 0: this is a report, not a test.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/lab-02.env"  2>/dev/null || true

VPC="${1:-${USMS_VPC_ID:-}}"
[ -n "$VPC" ] && [ "$VPC" != "none" ] || { echo "usage: $0 [vpc-id]" >&2; exit 2; }

aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" --output json \
  > /tmp/usms-matrix-sg-$$.json
aws ec2 describe-instances --filters "Name=vpc-id,Values=$VPC" --output json \
  > /tmp/usms-matrix-ec2-$$.json

python3 - "/tmp/usms-matrix-sg-$$.json" "/tmp/usms-matrix-ec2-$$.json" << 'PY'
import json, sys

groups = json.load(open(sys.argv[1]))["SecurityGroups"]
res    = json.load(open(sys.argv[2]))["Reservations"]

name = {g["GroupId"]: g.get("GroupName", g["GroupId"]) for g in groups}

def port_str(p):
    lo, hi = p.get("FromPort"), p.get("ToPort")
    if lo is None:
        return "all"
    return str(lo) if lo == hi else f"{lo}-{hi}"

def proto_str(p):
    v = p.get("IpProtocol", "-1")
    return "all" if v == "-1" else v

print("== USMS reachability matrix ==")
print()
print("WHO MAY OPEN A CONNECTION TO WHAT  (ingress, computed from rules only)")
print()

lonely = []
for g in sorted(groups, key=lambda x: x.get("GroupName", "")):
    gid, gname = g["GroupId"], g.get("GroupName", g["GroupId"])
    perms = g.get("IpPermissions", [])
    if not perms:
        print(f"  -> {gname}")
        print("       (nothing. no ingress rule exists)")
        print()
        continue

    controls = 0
    print(f"  -> {gname}")
    for p in perms:
        for r in p.get("UserIdGroupPairs", []):
            src = name.get(r.get("GroupId"), r.get("GroupId"))
            print(f"       {proto_str(p)}/{port_str(p):<9} <- group {src}")
            controls += 1
        for r in p.get("IpRanges", []):
            c = r.get("CidrIp")
            flag = "   <-- THE INTERNET" if c == "0.0.0.0/0" else ""
            print(f"       {proto_str(p)}/{port_str(p):<9} <- cidr  {c}{flag}")
            controls += 1
        for r in p.get("PrefixListIds", []):
            print(f"       {proto_str(p)}/{port_str(p):<9} <- prefix list {r.get('PrefixListId')}")
            controls += 1
    if controls == 1:
        lonely.append(gname)
    print()

print("WHAT EACH GROUP MAY INITIATE  (egress)")
print()
for g in sorted(groups, key=lambda x: x.get("GroupName", "")):
    gname = g.get("GroupName", g["GroupId"])
    egr = g.get("IpPermissionsEgress", [])
    if not egr:
        print(f"  {gname:<22} nothing")
        continue
    parts = []
    for p in egr:
        dests = [name.get(r.get("GroupId"), r.get("GroupId")) for r in p.get("UserIdGroupPairs", [])]
        dests += [r.get("CidrIp") for r in p.get("IpRanges", [])]
        dests += [r.get("PrefixListId") for r in p.get("PrefixListIds", [])]
        parts.append(f"{proto_str(p)}/{port_str(p)} -> {', '.join(d for d in dests if d)}")
    print(f"  {gname:<22} {' ; '.join(parts)}")

print()
print("INSTANCES, AND WHETHER THE INTERNET HAS AN ADDRESS TO SEND TO")
print()
for r in res:
    for i in r.get("Instances", []):
        if i.get("State", {}).get("Name") == "terminated":
            continue
        tags = {t["Key"]: t["Value"] for t in i.get("Tags", [])}
        pub = i.get("PublicIpAddress")
        sgs = ",".join(name.get(s["GroupId"], s["GroupId"]) for s in i.get("SecurityGroups", []))
        print(f"  {tags.get('Name', i['InstanceId']):<16} "
              f"private={i.get('PrivateIpAddress','-'):<12} "
              f"public={pub or 'NONE':<16} groups={sgs}")

print()
if lonely:
    print("SINGLE POINT OF CONTROL - these groups are protected by exactly ONE ingress rule:")
    for g in lonely:
        print(f"    {g}")
    print("    One mistake in one rule is the whole of the protection. Say so in your report.")
else:
    print("no group is protected by exactly one ingress rule")
PY

rm -f /tmp/usms-matrix-sg-$$.json /tmp/usms-matrix-ec2-$$.json
