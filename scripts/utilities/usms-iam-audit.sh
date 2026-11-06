#!/usr/bin/env bash
# USMS IAM audit. Reports findings; changes nothing.
#
# Four checks per role:
#   1. wildcard actions             Action: "*" or "<service>:*"
#   2. wildcard resources           Resource: "*" on a mutating action
#   3. unscoped iam:PassRole        the privilege-escalation path
#   4. unconditioned service trust  the confused deputy
#
# Read-only. Exit 0 if there are no HIGH findings, 1 otherwise.
set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"
# shellcheck disable=SC1090
source "$REPO_ROOT/configs/course.env" 2>/dev/null || true

INVENTORY="${1:-outputs/lab-09-identity-inventory.json}"

if [ ! -f "$INVENTORY" ]; then
  echo "no inventory at $INVENTORY - run Lab 09 Step 4 part 2 first" >&2
  exit 2
fi

python3 - "$INVENTORY" << 'PY'
import json, sys

MUTATING = ("Create", "Delete", "Put", "Update", "Modify", "Attach", "Detach",
            "Write", "Terminate", "Run", "Revoke", "Authorize", "Set", "Remove")

def as_list(x):
    if x is None:
        return []
    return x if isinstance(x, list) else [x]

def statements(doc):
    if not doc:
        return []
    if isinstance(doc, str):
        try:
            doc = json.loads(doc)
        except Exception:
            return []
    return as_list(doc.get("Statement"))

def is_mutating(action):
    if action == "*":
        return True
    verb = action.split(":", 1)[-1]
    return any(verb.startswith(p) for p in MUTATING)

roles = json.load(open(sys.argv[1]))
high = med = 0
lines = []

for r in roles:
    name = r["role"]
    findings = []

    # ---- checks 1 to 3, over every attached and inline policy ----
    docs = [(p["name"], p.get("document")) for p in r.get("attachedPolicies", [])]
    docs += [(p["name"], p.get("document")) for p in r.get("inlinePolicies", [])]

    for pname, doc in docs:
        for st in statements(doc):
            if st.get("Effect") != "Allow":
                continue
            actions = as_list(st.get("Action"))
            resources = as_list(st.get("Resource"))
            has_cond = bool(st.get("Condition"))

            for a in actions:
                if a == "*":
                    findings.append(("HIGH", f"{pname}: Action \"*\" - unbounded"))
                elif a.endswith(":*"):
                    findings.append(("MED", f"{pname}: service wildcard {a}"))

                if a.lower() == "iam:passrole" or a == "*":
                    if "*" in resources and not has_cond:
                        findings.append(
                            ("HIGH", f"{pname}: iam:PassRole on Resource \"*\" with no Condition"))
                    elif "*" in resources:
                        findings.append(
                            ("MED", f"{pname}: iam:PassRole on Resource \"*\", conditioned"))

                if "*" in resources and is_mutating(a) and a != "*":
                    findings.append(("MED", f"{pname}: {a} on Resource \"*\""))

    # ---- check 4, the trust policy ----
    for st in statements(r.get("trustPolicy")):
        princ = st.get("Principal") or {}
        svc = as_list(princ.get("Service"))
        aws_p = as_list(princ.get("AWS"))
        if "*" in aws_p:
            findings.append(("HIGH", "trust policy: Principal AWS \"*\" - anyone may assume"))
        if svc and not st.get("Condition"):
            findings.append(
                ("HIGH", f"trust policy: service principal {','.join(svc)} with NO Condition "
                         "(confused deputy)"))

    # ---- report ----
    boundary = r.get("permissionsBoundary")
    lines.append(f"{name}")
    lines.append(f"    permissions boundary : {boundary or 'NONE'}")
    if not boundary:
        findings.append(("MED", "no permissions boundary"))

    if not findings:
        lines.append("    ok   no findings")
    else:
        seen = set()
        for sev, text in findings:
            if (sev, text) in seen:
                continue
            seen.add((sev, text))
            lines.append(f"    {sev:<4} {text}")
            if sev == "HIGH":
                high += 1
            else:
                med += 1
    lines.append("")

print("== USMS IAM audit ==")
print()
print("\n".join(lines))
print(f"HIGH={high}  MED={med}  roles={len(roles)}")
sys.exit(1 if high else 0)
PY
