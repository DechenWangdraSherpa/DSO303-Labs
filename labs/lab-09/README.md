# Lab 9 – Securing USMS with IAM Roles and Security Groups

**Name:** Dechen Wangdra Sherpa
**Student Number:** 02230281
**Course:** DSO303 – Cloud Native Design Patterns
**Lab:** Lab 9 – Security Review: IAM and Security Groups

---

## 1. Aim / Objective

This lab adds no new tier. It reviews what Labs 01 to 06 built, on the two independent axes of access control, and repairs what the review finds.

**Identity (who can call what).** Inventory every role, and write an audit script that computes findings from policy documents rather than names. Then fix what it finds:
- a read-only transcripts policy and a role that carries it;
- confused-deputy conditions on `usms-ecs-task-role`'s trust policy;
- a deploy role whose `iam:PassRole` is scoped to named roles and one service;
- a permissions boundary;
- a session policy, with its effective permissions worked out by hand;
- a zero-downtime rotation of `usms-dev-01`'s access key;
- IMDSv2 on the web instance.

**Network (what can reach what).** Write an audit script for security groups. Then:
- replace the default allow-all egress on three groups with written rules;
- move SSH on the web tier from "the whole VPC" to a bastion group;
- compute a reachability matrix;
- prove that the database is unreachable from the internet, by several independent controls.

Finally, prove the posture survives a Floci restart, that the five earlier verification scripts report exactly what they did before, and save everything to `configs/lab-09.env`.

## 2. Introduction

An API call is decided by IAM, and it fails with an error that names an action. A packet is decided by routing, security groups and NACLs, and it fails with a timeout. A request needs a "yes" from both, and neither knows the other exists.

IAM evaluates in a fixed order:
1. An explicit Deny anywhere wins.
2. A Service Control Policy must allow the action (not modelled here).
3. A permissions boundary must allow it.
4. A session policy must allow it.
5. Then an identity or resource policy must allow it.

Boundaries and session policies only subtract.

Floci enforces neither IAM nor security groups. Every proof in this lab is therefore a proof about a **document**: I read it back and check that it says what I meant. For any claim about what *cannot* happen, that is also what I would do on a real account, because a negative cannot be tested exhaustively. The guide's other rule mattered just as much: a write that does not read back did not happen.

## 3. Use Case

USMS holds student transcripts. The enrolment API only ever reads them, but Lab 01 gave the same read-write policy to three roles. The ECS task role could be assumed by the ECS service on behalf of anyone. There was no deployment identity: everything ran as root. One developer had a ten-week-old access key. And every security group still had the allow-all egress rule nobody wrote.

None of that broke anything; it just meant that a single bug in the enrolment API would have had a much larger blast radius than it needed. This lab narrows that radius without changing what USMS does. The task definition, service, load balancer and scaling from Labs 04 to 06 are all untouched, and Step 18 proves it with the earlier labs' own scripts.

## 4. System Architecture / Design

```
  IAM  (decides API calls)                       NETWORK  (decides packets)
  ----------------------------------------       ----------------------------------------------
  usms-ecs-task-role                             usms-alb-sg     in  80,443 <- 0.0.0.0/0
    trust  ecs-tasks + SourceAccount              (accepted)     out 80     -> sg:usms-enrolment-sg   NEW
           + SourceArn conditions        NEW     usms-enrolment-sg in 80   <- sg:usms-alb-sg
    perms  USMSStudentDataReadWrite (kept)                       out 443   -> pl-63a5400a, 0.0.0.0/0  NEW
  usms-transcripts-reader-role           NEW     usms-db-sg      in  5432   <- sg:usms-app-sg
    same scoped trust                                            out 443    -> 0.0.0.0/0               NEW
    perms  USMSStudentDataReadOnly       NEW     usms-app-sg     in  80,443 <- 0.0.0.0/0   (open finding)
           Get + List, Deny every write                          in  22     <- sg:usms-bastion-sg      NEW
  usms-deploy-role                       NEW                       (10.0.0.0/16 rule removed)
    trust  user/usms-admin-01                    usms-bastion-sg NEW in 22 <- 203.0.113.10/32
    perms  USMSDeployBase                        usms-web-01     IMDSv2 required  (NOT APPLIED: unsupported)
      iam:PassRole -> 3 named roles, ecs-tasks only
      Deny PassRole to ec2                       usms-db-01: no public IP, no auto-assign, NAT route only,
    boundary USMSPermissionsBoundary                         one-group SG, custom NACL  (5 controls)
      (created; NOT stored by Floci)
  usms-dev-01   one access key, created today    NEW
```

Key design choices:
- **Audit before changing, identity before network.** Both audits are read-only scripts that compute findings from rules and documents, never from names. They are re-runnable, so the "after" picture is the same tool run again.
- **Add, don't replace, where a later lab depends on it.** `usms-ecs-task-role` keeps `USMSStudentDataReadWrite` because Lab 10 needs it. The read-only split is a *new* policy on a *new* role.
- **Keep the undo next to the change.**
  - The task role's original trust policy was saved to `outputs/lab-09-ecs-task-role-trust-before.json` before the rewrite.
  - `policies/usms-egress-allow-all.json` was written before the first revoke.
- **Authorise first, revoke second.** Every rule replacement adds the new rule before removing the old one, with the same cutover discipline as Lab 05.
- **Groups, not addresses.** The ALB's egress and the web tier's SSH rule name a security group, so they stay correct when tasks scale or get new addresses.

## 5. Implementation Procedure

### Step 1–2: Environment and a baseline of five earlier verification scripts

![Floci up, whoami and the seventeen values part a](<../../screenshots/Lab-09/01-environment-and-baseline_a.png>)
![Seventeen values and the five-script baseline part b](<../../screenshots/Lab-09/01-environment-and-baseline_b.png>)
*Floci is up and `whoami.sh` confirms account `000000000000`. All seventeen values are non-empty: account, `us-east-1`, `usms-dev-01`, `usms-admin-01`, the three roles, `usms-ec2-app-profile`, bucket `usms-student-data`, `vpc-6ffa2a93`, the four groups (`usms-app-sg sg-39a66c2dc43f3eef3`, `usms-db-sg sg-4f8d774f5eb6acdd8`, `usms-enrolment-sg sg-ed703590b42f25128`, `usms-alb-sg sg-948367004bbccafb6`), `vpce-ababcd9bbeb227091`, and both instances. The baseline in `outputs/lab-09-pre-verify.txt` reads `lab-02 PASS=33 FAIL=0`, `lab-03 36/0`, `lab-04 37/1`, `lab-05 47/2` and `lab-06 39/3`. Lab 04's single failure is exactly the documented one the guide accepts (`usms-enrolment-sg is sourced from usms-app-sg (not a CIDR)`). Lab 05's and 06's failures are the Floci limitations recorded in those labs.*

In my `configs/lab-01.env`, the three role variables hold full ARNs, not names, so I printed them with `${VAR##*/}` and used that wherever the guide needs a name.

### Step 3: What this build supports

![IAM read, write and evaluate probes part a](<../../screenshots/Lab-09/02-support-probe_a.png>)
![Probe script continued part b](<../../screenshots/Lab-09/02-support-probe_b.png>)
![Probe results part c](<../../screenshots/Lab-09/02-support-probe_c.png>)
*Every IAM read and write call is `SUPPORTED`, including `put-role-permissions-boundary`, and **`simulate-principal-policy` is `SUPPORTED`**. Only `get-account-authorization-details`, `accessanalyzer list-analyzers` and `get-credential-report` are `not available`. All EC2 rule and metadata calls answer the probe. A skeleton probe only proves the CLI knows the operation, which mattered later.*

That puts me on **Path A**. In Step 9 I confirmed that the simulator really reads the documents.

### Step 4: Inventory every identity

![Roles, users and access keys part a](<../../screenshots/Lab-09/03-identity-inventory_a.png>)
![Customer managed policies part b](<../../screenshots/Lab-09/03-identity-inventory_b.png>)
*There are eight roles: the guide's five, plus `usms-eks-cluster-role` and `usms-eks-node-role` from Lab 07 and Lab 06's `AWSServiceRoleForEcsApplicationAutoscaling`. There are four users, and only `usms-dev-01` has an access key (1). Among the customer managed policies, `USMSStudentDataReadWrite` has **3** attachments.*

![Machine-readable inventory script part c](<../../screenshots/Lab-09/03-identity-inventory_c.png>)
![Inventory written, eight roles, no boundary part d](<../../screenshots/Lab-09/03-identity-inventory_d.png>)
*`outputs/lab-09-identity-inventory.json` is `valid JSON` with `8 roles inventoried`. Every role shows `boundary=-`: no role in the account has a permissions boundary.*

![Two trust policies side by side part e](<../../screenshots/Lab-09/03-identity-inventory_e.png>)
*Your turn. `usms-developer-role` trusts `{"AWS": "arn:aws:iam::000000000000:user/usms-dev-01"}`, while `usms-ec2-app-role` trusts `{"Service": "ec2.amazonaws.com"}`. The first can only be obtained by one named user calling `AssumeRole` with their own key. The second goes to any instance launched with its profile, and can be fetched by any code on that instance, so who effectively holds it depends on who may `RunInstances` with `PassRole`, and on SSRF.*

### Step 5: The IAM audit script

![IAM audit findings part a](<../../screenshots/Lab-09/04-iam-audit-findings_a.png>)
![IAM audit findings continued part b](<../../screenshots/Lab-09/04-iam-audit-findings_b.png>)
![Audit summary and exit code part c](<../../screenshots/Lab-09/04-iam-audit-findings_c.png>)
*`syntax OK`. The four checks find a HIGH confused-deputy finding (`service principal ... with NO Condition`) on every service-trusted role: lambda, eks, ecs-exec, ecs-task, the service-linked role, ec2-app and eks-node. They also find `... on Resource "*"` MEDs in `USMSDeveloperBase` and the two EKS policies, and `MED no permissions boundary` everywhere. The total is **`HIGH=7 MED=30 roles=8`**, with `exit code: 1`.*

The counts are higher than the guide's `HIGH=4 MED=5` because of the three extra roles and because my Lab 01 developer policy is broader. The shape is what matters: the same HIGH on every service-trusted role is a systematic mistake made by a convention.

### Step 6: The transcripts policy, and the verb that should not be there

![Policy document, carriers and head-bucket part a](<../../screenshots/Lab-09/05-transcripts-policy-read_a.png>)
![Who carries it and the missing bucket part b](<../../screenshots/Lab-09/05-transcripts-policy-read_b.png>)
*`USMSStudentDataReadWrite` v1 has three statements:*
- *`ListTheBucketItself` allows `s3:ListBucket` and `s3:GetBucketLocation` on the bucket ARN.*
- *`ReadWriteObjectsInsideTheBucket` allows `s3:GetObject`, `s3:PutObject` **and** `s3:DeleteObject` on `/*`.*
- *`NeverDeleteTheBucket` is an explicit Deny on `s3:DeleteBucket`.*

*It is carried by `usms-ec2-app-role`, `usms-ecs-task-role` and `usms-eks-node-role`. `head-bucket` returns `404 Not Found` (exit 254): the bucket does not exist yet, which is correct, because Lab 10 creates it.*

**Your turn.** To show a transcript, the enrolment API needs `s3:GetObject`, plus `s3:ListBucket`, so that a missing key returns `404` rather than `403`. The upload workflow needs the same two plus `s3:PutObject`. The difference is exactly `s3:PutObject`. My Lab 01 policy also grants `s3:DeleteObject`, which neither workload needs: a second finding the guide did not expect.

### Step 7: The read-only policy, its role, and the confused-deputy fix

![Read-only policy and scoped trust document part a](<../../screenshots/Lab-09/06-readonly-policy-and-reader-role_a.png>)
![Reader role created and policy attached part b](<../../screenshots/Lab-09/06-readonly-policy-and-reader-role_b.png>)
*`policies/usms-student-data-ro-policy.json` is valid JSON with `0` dollar signs, and was created as `arn:aws:iam::000000000000:policy/USMSStudentDataReadOnly`. It allows only `s3:ListBucket` and `s3:GetObject`, and explicitly denies `PutObject`, `DeleteObject`, `DeleteBucket` and `PutBucketPolicy`. That Deny adds nothing today, but it still wins if someone later attaches a broader policy, so it must not be "tidied away". The scoped trust document has real values: `aws:SourceAccount 000000000000` and `aws:SourceArn arn:aws:ecs:us-east-1:000000000000:*`. `usms-transcripts-reader-role` was created with it, and the read-only policy is `attached`.*

![Original task role trust saved, then replaced part a](<../../screenshots/Lab-09/07-task-role-trust-scoped_a.png>)
![The new role and its permissions part b](<../../screenshots/Lab-09/07-task-role-trust-scoped_b.png>)
![Same principal, new condition part c](<../../screenshots/Lab-09/07-task-role-trust-scoped_c.png>)
*The original `usms-ecs-task-role` trust (`AllowEcsTasksToAssumeThisRole`, no condition) was written to `outputs/lab-09-ecs-task-role-trust-before.json` first. Then `update-assume-role-policy` replaced it. Read back, the reader role shows the two conditions and `USMSStudentDataReadOnly`. The before/after comparison prints `before: [('{"Service": "ecs-tasks.amazonaws.com"}', False)]`, `after : [(... , True)]` and **`SAME PRINCIPAL, NEW CONDITION`**: who may assume the role did not change; the circumstances did. `usms-ec2-app-role` cannot be fixed this way, because EC2 does not send `aws:SourceArn` for instance profiles.*

### Step 8: A scoped `iam:PassRole`, and a permissions boundary

![Boundary and deploy policy created part a](<../../screenshots/Lab-09/08-boundary-and-deploy-role_a.png>)
![Deploy role created, boundary reads null part b](<../../screenshots/Lab-09/08-boundary-and-deploy-role_b.png>)
*All three documents are valid JSON with `0` dollar signs. `USMSPermissionsBoundary` and `USMSDeployBase` were created. `create-role ... --permissions-boundary "$BOUNDARY_ARN"` returned `arn:aws:iam::000000000000:role/usms-deploy-role`, and `USMSDeployBase` was attached. But `get-role --query Role.PermissionsBoundary` returns **`null`**: the boundary was accepted and not stored.*

![put-role-permissions-boundary also not stored part a](<../../screenshots/Lab-09/09-passrole-scoped-boundary-not-stored_a.png>)
![Deploy role readback and the PassRole statements part b](<../../screenshots/Lab-09/09-passrole-scoped-boundary-not-stored_b.png>)
![Boundary attached to nothing part c](<../../screenshots/Lab-09/09-passrole-scoped-boundary-not-stored_c.png>)
*As the guide says, I tried `put-role-permissions-boundary` once. It printed `accepted`, and the boundary is still `null`. The deploy role trusts `user/usms-admin-01`. `PassOnlyTheseThreeRolesAndOnlyToTheseServices` names exactly `usms-ecs-exec-role`, `usms-ecs-task-role` and `usms-transcripts-reader-role`, with `iam:PassedToService: ecs-tasks.amazonaws.com`. `NeverPassAnythingToEC2` denies `iam:PassRole` on `*` when passed to `ec2.amazonaws.com`. `list-entities-for-policy` on the boundary shows no roles, users or groups: it is attached to nothing, as a boundary must be.*

The escalation the guide describes (`RunInstances` plus an unscoped `PassRole` of an admin role) is now closed at step 3: this policy can pass only three ECS roles, and only to ECS tasks. The boundary is a real gap on Floci 1.7.0. The course's Known Issues page lists it for Lab 09 (screenshot 13).

### Step 9: A session policy, and the intersection worked by hand

![Session policy and the scoped session part a](<../../screenshots/Lab-09/10-session-policy-intersection_a.png>)
![Assume role with the session policy part b](<../../screenshots/Lab-09/10-session-policy-intersection_b.png>)
*The session policy allows `ec2:DescribeVpcs`, `DescribeSubnets` and `DescribeSecurityGroups`, `sts:GetCallerIdentity`, and **`s3:PutObject`**. `assume-role --profile usms-dev --policy ...` returned credentials for `assumed-role/usms-developer-role/floci-session` (Floci ignores the session name), and that session listed `2` VPCs.*

![Intersection computation part c](<../../screenshots/Lab-09/10-session-policy-intersection_c.png>)
![Identity policy allows part d](<../../screenshots/Lab-09/10-session-policy-intersection_d.png>)
![Effective permissions part e](<../../screenshots/Lab-09/10-session-policy-intersection_e.png>)
*The identity policy (`USMSDeveloperBase` v2) allows patterns including `ec2:Describe*`, `iam:Get*`/`List*`, `s3:List*` and `sts:GetCallerIdentity`. The EFFECTIVE block reads `ALLOWED` for the three EC2 describes and `GetCallerIdentity`, and **`s3:PutObject  NOT in the identity policy -> denied`**. A session policy cannot grant anything the role did not already have.*

![Simulator agrees, identity restored part f](<../../screenshots/Lab-09/10-session-policy-intersection_f.png>)
*As a second opinion, `simulate-principal-policy` returned `ec2:DescribeVpcs allowed`, `sts:GetCallerIdentity allowed`, `s3:PutObject implicitDeny` and `iam:CreateUser explicitDeny`. The last one is correct, because `USMSDeveloperBase` has a `DenyDangerousIdentityChanges` statement, so the simulator really evaluates the documents. The three variables were then unset, `whoami.sh` was back on account `000000000000`, and the session file was deleted.*

I added `s3:PutObject` to the guide's session policy because my developer policy already allows `sts:GetCallerIdentity`, so the guide's version produced no denied line. The guide's suggested substitute, `s3:ListAllMyBuckets`, would also have matched `s3:List*`.

### Step 10: Rotate the access key with no outage window

![Current key and last used part a](<../../screenshots/Lab-09/11-access-key-rotation_a.png>)
![New key created and profile moved part b](<../../screenshots/Lab-09/11-access-key-rotation_b.png>)
![Old key deactivated, profile still works part c](<../../screenshots/Lab-09/11-access-key-rotation_c.png>)
![Old key deleted part d](<../../screenshots/Lab-09/11-access-key-rotation_d.png>)
*The process ran in four stages:*
1. ***Before.** `usms-dev-01` has one key, `AKIAEES3X0N2F09V5JNX`, `Active`, created 2026-08-23. Last-used is `N/A`.*
2. ***Create and repoint.** `create-access-key` wrote straight to `outputs/usms-dev-01-access-key-new.json`, so the secret never reached the screen. `git check-ignore -v` names `.gitignore:8:outputs/*`. The new key is `AKIA3B5VPR6647E4V0BA`. After repointing the `usms-dev` profile, `get-caller-identity --profile usms-dev` returns `user/usms-dev-01`, and the profile holds the new key ID.*
3. ***Deactivate.** Two keys, one `Active` and one `Inactive`, and the profile still answers.*
4. ***Delete.** After `delete-access-key` there is exactly one key, `AKIA3B5VPR6647E4V0BA`, `Active`, created `2026-11-06T12:28:46`. The profile still answers, and Lab 01's old key file is gone; only the new, `chmod 600` file remains.*

Deactivating before deleting is what makes the rotation safe, because an inactive key can be reactivated and a deleted one cannot. The lab compresses the pause between those two steps, which on a real system would be a day or a week. On a real account this key should not exist at all: IAM Identity Center for the human, roles for workloads.

### Step 11: IMDSv2 – not available on this build

![Metadata options before and the unsupported modify part a](<../../screenshots/Lab-09/12-imdsv2-web-and-db_a.png>)
![Not applied part b](<../../screenshots/Lab-09/12-imdsv2-web-and-db_b.png>)
![usms-db-01 has no profile, disable also unsupported part c](<../../screenshots/Lab-09/12-imdsv2-web-and-db_c.png>)
*`usms-web-01` reports `HttpTokens: optional`, `HttpPutResponseHopLimit: 1`. `modify-instance-metadata-options --http-tokens required` fails: **`UnsupportedOperation ... Operation ModifyInstanceMetadataOptions is not supported`**. The read-back prints `HttpTokens : optional -> optional` and `NOT APPLIED`. For the Your-turn, `usms-db-01` has `Profile: null`, so the right setting is the stronger `--http-endpoint disabled`; that call fails the same way.*

On real AWS:
- `--http-tokens required` stops **SSRF credential theft**: a forged GET to `169.254.169.254` gets nothing, because a token needs a PUT with a header.
- Hop limit 1 stops **a container on the instance** from inheriting the host's role.
- The safe rollout is: watch `MetadataNoToken` until it reaches zero, update old SDKs, then require tokens and set it in the launch template.

Disabling the endpoint on `usms-web-01` would break it, because its application gets the `usms-ec2-app-role` credentials from IMDS.

![Known Issues alternative for the boundary and IMDS](<../../screenshots/Lab-09/13-known-issue-fallback-demo.png>)
*The two gaps read back as `boundary -> None` and `IMDS tokens -> optional`. The course's Known Issues page gives an alternative for exactly these: `student-fallback-demo.py security`. I read the script before installing it; it uses only local 127.0.0.1 servers and makes no AWS calls. It printed the intersection model `s3:GetObject: ALLOW`, `s3:PutObject: DENY` (allowed by identity, outside the boundary), `s3:DeleteObject: DENY`, then `Without token: HTTP 401` and `With token: HTTP 200`. It says itself that it is a model, not an IAM evaluator or IMDSv2.*

### Step 12: The security group audit

![SG audit part a](<../../screenshots/Lab-09/14-sg-audit-before_a.png>)
![SG audit part b](<../../screenshots/Lab-09/14-sg-audit-before_b.png>)
*`syntax OK`. All six groups carry `MED egress is the DEFAULT allow-all rule - nobody wrote this`. `usms-alb-sg` and `usms-app-sg` admit tcp/80 and 443 from `0.0.0.0/0` (HIGH). `usms-app-sg` has `MED ingress tcp/22 from a whole VPC range (10.0.0.0/16)`, and `usms-db-sg` admits 5432 only from `sg:usms-app-sg`. The total is **`HIGH=4 MED=8 LOW=4 groups=6`**, saved as `outputs/lab-09-sg-findings-before.txt`.*

I sorted the findings before fixing any of them:
- The ALB's 0.0.0.0/0 is an accepted risk; it is an internet-facing load balancer (Lab 05).
- `usms-app-sg`'s 80 and 443 are an open finding: a second internet entry point (Exercise 4).
- The SSH range is fixed in Step 16.
- Default egress is fixed in Steps 13 to 15.
- The interface count of 0 on the ALB and enrolment groups is a Floci modelling gap, not a finding.

### Step 13: Egress for the enrolment tasks

![S3 prefix list found part a](<../../screenshots/Lab-09/15-enrolment-sg-egress_a.png>)
![Egress document part b](<../../screenshots/Lab-09/15-enrolment-sg-egress_b.png>)
![Egress document continued part c](<../../screenshots/Lab-09/15-enrolment-sg-egress_c.png>)
![Undo written, authorise then revoke part d](<../../screenshots/Lab-09/15-enrolment-sg-egress_d.png>)
*`describe-prefix-lists` found the S3 prefix list `pl-63a5400a`. The document has two tcp/443 rules, one to the prefix list and one to `0.0.0.0/0` for the image pull and the log driver, each with a `Description`. It is valid JSON with 0 dollar signs. `undo document written`, then the authorise returned two rule IDs (`sgr-5f6601a0084110c12`, `sgr-9a23ebfd6f13c1985`) **before** the revoke of allow-all returned `True`.*

![Rules view still lists the revoked rule part e](<../../screenshots/Lab-09/15-enrolment-sg-egress_e.png>)
![Ingress unchanged part f](<../../screenshots/Lab-09/15-enrolment-sg-egress_f.png>)
*`describe-security-group-rules` lists the two new 443 rules, but **still lists `sgr-ac23b115666ab7238 -1 0.0.0.0/0`**. Ingress is unchanged: one rule, port 80 from `sg-948367004bbccafb6` (usms-alb-sg).*

The stale `-1` line made me check both APIs. `describe-security-groups` shows only the two tcp/443 rules, so the revoke worked. Floci's separate rules index keeps the old entry, and revoking that entry by rule ID also returns `True` and changes nothing. I used `describe-security-groups` as the source of truth, because the guide's checks, both audit scripts and verify-lab-09 all read it. Screenshot 16 shows both views side by side.

### Step 14–15: Egress for the load balancer and the data tier

![ALB egress to a group part a](<../../screenshots/Lab-09/16-alb-and-db-egress_a.png>)
![DB egress and three zeros part b](<../../screenshots/Lab-09/16-alb-and-db-egress_b.png>)
![Stale entries in the rules index part c](<../../screenshots/Lab-09/16-alb-and-db-egress_c.png>)
*The ALB now reads `In: 80 and 443 from 0.0.0.0/0` and `Out: [{Port: 80, ToGroup: sg-ed703590b42f25128, CIDR: null}]`. Anything may open HTTP to the load balancer, and it may open HTTP to exactly one thing, named as a group, so scaling never changes the rule. The DB egress is tcp/443 only. The three-line check reads **`allow-all egress rules remaining: 0`** for `usms-enrolment-sg`, `usms-alb-sg` and `usms-db-sg`. The last block shows the other view: `describe-security-group-rules` still lists one stale `-1 0.0.0.0/0` entry per group.*

The guide's three-zeros query, `length(IpPermissionsEgress[...])`, is missing `SecurityGroups[0].` and errors with `invalid type for value: None`. The same bug appears in Step 18, Step 19 and the verify script; I fixed each one. These two screenshots are rendered from the real authorise and revoke run plus a re-run of only the corrected check blocks, because re-running the authorise would just have returned "duplicate".

On real AWS, the DB rule still allows an HTTPS POST of the data anywhere. Stopping that needs hostname filtering, such as Network Firewall or a proxy. A complete rule set would also add UDP/TCP 53 to the VPC resolver for `dnf update`.

### Step 16: SSH from a bastion group, not the whole VPC

![Bastion group created part a](<../../screenshots/Lab-09/17-ssh-to-bastion-group_a.png>)
![Group-sourced SSH rule added part b](<../../screenshots/Lab-09/17-ssh-to-bastion-group_b.png>)
![Rule-ID revoke returns True and removes nothing part c](<../../screenshots/Lab-09/17-ssh-to-bastion-group_c.png>)
*`usms-bastion-sg does not exist - creating it`, giving `sg-a2b2c9e9f29481762`, with SSH in from the documentation address `203.0.113.10/32`. The new rule, tcp/22 from that group, was added first (`sgr-3173e2a8752e82494`). The guide's revoke of `sgr-c8cf47eda7d6b07f5` by `--security-group-rule-ids` returned **`True`**, but the read-back still shows two port-22 entries: `CIDR ["10.0.0.0/16"]` and `FromGroup ["sg-a2b2c9e9f29481762"]`. The rule-ID revoke removed nothing.*

![CIDR SSH rule removed by ip-permissions](<../../screenshots/Lab-09/18-ssh-cidr-rule-removed.png>)
*Revoking by `--ip-permissions 'IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=10.0.0.0/16}]'` returned `True` and worked. `usms-app-sg` now has three ingress rules: 80 and 443 from `0.0.0.0/0`, and **22 from `sg-a2b2c9e9f29481762`** with the description "SSH from the USMS jump host tier only". The count of CIDR sources on port 22 is `0`.*

SSH to the web tier is no longer reachable from anything outside the admin tier, including a compromised enrolment task.

### Step 17: The reachability matrix, and five controls on the database

![Reachability matrix ingress part a](<../../screenshots/Lab-09/19-reachability-and-negative-proof_a.png>)
![Egress, instances and single points of control part b](<../../screenshots/Lab-09/19-reachability-and-negative-proof_b.png>)
*Computed from rules only:*
- *Two groups admit `THE INTERNET`: `usms-alb-sg` and `usms-app-sg`.*
- *`usms-app-sg` port 22 comes from `group usms-bastion-sg`, `usms-db-sg` 5432 from `group usms-app-sg`, and `usms-enrolment-sg` 80 from `group usms-alb-sg`.*
- *Egress: `usms-alb-sg tcp/80 -> usms-enrolment-sg`, `usms-db-sg tcp/443 -> 0.0.0.0/0`, and `usms-enrolment-sg tcp/443 -> pl-63a5400a ; tcp/443 -> 0.0.0.0/0`.*
- *Instances: `usms-web-01` has `public=127.0.0.1` (Floci's stand-in) and `usms-db-01` has `public=NONE`.*
- *Single points of control at the group layer: `usms-bastion-sg`, `usms-db-sg`, `usms-eks-cluster-sg` and `usms-enrolment-sg`.*

![Negative proof script part c](<../../screenshots/Lab-09/19-reachability-and-negative-proof_c.png>)
![Five controls on usms-db-01 part d](<../../screenshots/Lab-09/19-reachability-and-negative-proof_d.png>)
*The claim "usms-db-01 is not reachable from the internet" rests on five controls, and each reads correctly:*
1. *no public address: `None`;*
2. *the subnet does not auto-assign one: `False`;*
3. *the default route goes to `nat-0e606949dd0ad396c`, with no IGW;*
4. *the group admits `5432` from `sg-39a66c2dc43f3eef3` and no CIDR;*
5. *the NACL is `acl-0e6976c10a52c455f`, `IsDefault False`.*

If control 3 failed, controls 1, 4 and 5 would still stop an attacker. If control 4 failed, there is still no address to send to and no route back.

### Step 18: Persistence, and proof that nothing else broke

![Nine facts before restart part a](<../../screenshots/Lab-09/20-persistence-and-regression_a.png>)
![Floci stopped and started part b](<../../screenshots/Lab-09/20-persistence-and-regression_b.png>)
*The nine facts before the restart:*
- *trust conditions on `usms-ecs-task-role`: `2`;*
- *boundary on `usms-deploy-role`: `None`;*
- *`usms-transcripts-reader-role` exists, with `USMSStudentDataReadOnly` attached;*
- *access keys on `usms-dev-01`: `1`;*
- *allow-all egress rules on the three groups: `0`, `0`, `0`;*
- *CIDR sources for SSH on `usms-app-sg`: `0`;*
- *IMDS on `usms-web-01`: `optional`.*

*Floci was then stopped ("State preserved") and started again.*

![Re-derived identifiers and PERSISTENCE PROVEN part c](<../../screenshots/Lab-09/20-persistence-and-regression_c.png>)
![Web instance restarted part d](<../../screenshots/Lab-09/20-persistence-and-regression_d.png>)
![Five scripts unchanged, NOTHING BROKE part e](<../../screenshots/Lab-09/20-persistence-and-regression_e.png>)
*Every identifier was re-derived from the API (the same four group IDs and `i-378337720bc5f9d2e`), and the diff is empty: **`PERSISTENCE PROVEN`**. As in Labs 05 to 08, the restart stopped `usms-web-01` (`stopped`), so I started it (`pending`). ECS came back at `2 2`. The five earlier scripts then read `33/0, 36/0, 37/1, 47/2, 39/3`, identical to Step 2: **`NOTHING BROKE`**.*

One honest caveat. The guide's PERSISTENCE line lists "the permissions boundary" and "the IMDSv2 requirement". Those two facts persisted as `None` and `optional`, because they were never set. They are unchanged, not proven present.

### Step 19: `configs/lab-09.env`

![Allow-all count computed first part a](<../../screenshots/Lab-09/21-lab09-env_a.png>)
![Env file heredoc part b](<../../screenshots/Lab-09/21-lab09-env_b.png>)
![All values populated part c](<../../screenshots/Lab-09/21-lab09-env_c.png>)
![Sixteen values read back part d](<../../screenshots/Lab-09/21-lab09-env_d.png>)
*The guide's escaped `\$(...)` program inside the unquoted heredoc is a bash syntax error on this shell, the same trap as Lab 06. So I used the guide's own "readable alternative": compute `REMAINING` first, giving `allow-all egress rules remaining on the three groups: 0`, then insert it. The env check prints `all values populated`. The read-back gives the three policy ARNs, the two role ARNs, bastion `sg-a2b2c9e9f29481762`, prefix list `pl-63a5400a`, imds tokens **`optional`** (honest, not hard-coded), dev key created `2026-11-06T12:28:46`, allow-all egress left `0`, review date `2026-11-06`, and **`16`** exports. The access key ID is deliberately absent.*

### Section 8: Verification

![verify-lab-09 identity checks part a](<../../screenshots/Lab-09/22-verify-lab09_a.png>)
![verify-lab-09 network and hygiene checks part b](<../../screenshots/Lab-09/22-verify-lab09_b.png>)
![Audits before and after part c](<../../screenshots/Lab-09/22-verify-lab09_c.png>)
*verify-lab-09 runs 50 checks. Every Environment, dependency, read-only split, confused-deputy, PassRole, credentials, ingress, egress, SSH cutover, negatives and hygiene check is `ok`, except two: `FAIL usms-deploy-role HAS a permissions boundary` and `FAIL usms-web-01 requires IMDSv2`. Both are in the guide's table of known benign failures, and both are the Floci gaps above. The result is **`PASS=48 FAIL=2`**. Re-running the audits: the SG audit went from `HIGH=4 MED=8 LOW=4 groups=6` to `HIGH=4 MED=5 LOW=5 groups=7` (three default-egress MEDs gone; the new bastion group adds a LOW). On a fresh inventory, `usms-ecs-task-role` has **no HIGH any more**. The new roles show only `no permissions boundary` (because Floci did not store it) and the guide's expected `USMSDeployBase: ecs:UpdateService on Resource "*"` MED. The IAM audit is now `HIGH=6`; it still exits 1, as the guide predicts, because this lab does not fix every role.*

I fixed three bugs in the guide's verify script, all documented in my notes:
- **Boundary-attachment check:** over-escaped quotes broke the query. The real `AttachmentCount` is 0.
- **Port-22 CIDR check:** the same missing `SecurityGroups[0].` as in Step 15.
- **"No unexpanded variable" check:** it flagged Lab 01's `${aws:username}`, a legitimate IAM policy variable that the guide itself says must survive. I narrowed it to shell-style `${UPPER_CASE}` names and tested that it still catches one.

The script also allows `outputs/.gitkeep`, as in Labs 04 to 08. The cleanup script was written and passed `bash -n`, but was not run.

### Step 20: Commit

![git status, ignore rules and variable check part a](<../../screenshots/Lab-09/23-commit-proof_a.png>)
![Explicit paths staged part b](<../../screenshots/Lab-09/23-commit-proof_b.png>)
![Commit created part c](<../../screenshots/Lab-09/23-commit-proof_c.png>)
![Commit file list and outputs check part d](<../../screenshots/Lab-09/23-commit-proof_d.png>)
*Nothing under `outputs/` is listed. `git check-ignore -v` names `.gitignore:8:outputs/*` for both the new key file and the inventory, `git ls-files outputs/` lists only `outputs/.gitkeep`, and the check prints `no unexpanded variables in any policy document`. Eighteen explicit paths were staged (never `git add -A`). Commit **`7af7236`** sits above `ba566b0 Lab08`, with `18 files changed, 1178 insertions(+)`: `configs/lab-09.env`, the notes, the ten new policy documents and the six scripts. Only `outputs/.gitkeep` is tracked under `outputs/`.*

## 6. Results and Evidence

### 6.1 CLI/SDK Output

| Checkpoint | What had to be true | Result |
|---|---|---|
| 1 (Step 2) | Floci under Compose, hybrid; 17 values; five scripts' baseline captured | All true (screenshot 01) |
| 2 (Step 5) | Inventory of every role and document; audit run; no role has a boundary | All true, `HIGH=7 MED=30` on 8 roles (screenshots 03, 04) |
| 3 (Step 7) | Read-only policy with explicit Deny; reader role; `SAME PRINCIPAL, NEW CONDITION` | All true (screenshots 06, 07) |
| 4 (Step 8) | Boundary attached to nothing; PassRole to 3 ARNs + `PassedToService`; deploy role carrying the boundary | **Partly met:** everything except the boundary, which Floci does not store (screenshots 08, 09, 13) |
| 5 (Step 10) | One Active key created today; profile working; old key deactivated, then deleted | All true (screenshot 11) |
| 6 (Step 11) | `HttpTokens required`, hop limit 1, or the limitation recorded | **Limitation recorded:** `UnsupportedOperation`; Known Issues alternative run (screenshots 12, 13) |
| 7 (Step 12) | SG audit showing default egress everywhere and the VPC-wide SSH rule | All true (screenshot 14) |
| 8 (Step 15) | Zero allow-all egress on three groups; ingress unchanged; undo written first | All true in `describe-security-groups`; the rules index keeps stale entries (screenshots 15, 16) |
| 9 (Step 16) | tcp/22 from `usms-bastion-sg` and no CIDR | True, after the rule-ID revoke proved a no-op (screenshots 17, 18) |
| 10 (Step 17) | Matrix from rules alone; five controls on `usms-db-01`; single points of control named | All true (screenshot 19) |
| 11 (Step 18) | `PERSISTENCE PROVEN` with re-derived IDs; `NOTHING BROKE` | Both printed; two facts are unchanged because they were never set (screenshot 20) |
| 12 (Step 20) | 16 exports, no key ID; ten new documents; nothing from `outputs/` staged | All true, commit `7af7236` (screenshots 21, 23) |

The consolidated proof is `verify-lab-09.sh` at **`PASS=48 FAIL=2`**, where both failures are the guide's known benign Floci gaps (screenshot 22).

### 6.2 AWS Console Verification

Floci has no AWS Management Console. On real AWS:
- The IAM console's role pages would show the trust relationships, the attached policies and the permissions-boundary field that `get-role` returns here.
- The EC2 console's security group tabs would show the inbound and outbound rules that `describe-security-groups` returns.
- IAM Access Analyzer would add findings from outside the account; it is not available on this build.

Here, the evidence is the read-back calls in the screenshots, which read the same APIs.

## 7. Analysis and Discussion

**What was real and what was only a document.** Every change in this lab was stored and read back, except the boundary and the IMDS options. But nothing was *enforced*: Floci authorises no API call and carries no packet. The proofs are therefore proofs about documents. For the claims this lab cares most about, that is the only proof there is anyway: the reader role can never write, PassRole names three roles, and the database has no path from the internet. The simulator was a useful second opinion, because it really evaluates documents, including the explicit Deny on `iam:CreateUser`.

**Floci limitations I hit, with what real AWS does:**

| Floci 1.7.0 | Real AWS |
|---|---|
| IAM not enforced; every call succeeds | Every call evaluated in the order in Section 2 |
| Permissions boundary accepted by `create-role` and `put-role-permissions-boundary`, not stored | Stored, shown by `get-role`, enforced |
| `ModifyInstanceMetadataOptions` is `UnsupportedOperation`; there is no IMDS | IMDSv2 enforced at the hypervisor immediately |
| `--role-session-name` ignored | The session name appears in the ARN and CloudTrail |
| `describe-security-group-rules` keeps revoked rules | One rule set; both APIs agree |
| Revoke by `--security-group-rule-ids` returns `True` and removes nothing | Removes exactly that rule |
| No traffic, so groups and NACLs are never evaluated | Every packet evaluated |
| Network interfaces not modelled for the ALB or tasks | Each has an ENI, and the audit's interface count is meaningful |
| A Floci restart stops `usms-web-01` and deletes the Lab 07 k3s cluster | Nothing restarts |

**Problems that were mine to untangle:**
- **A `True` that meant nothing.** The most important lesson was that a successful command proves nothing. Both kinds of revoke returned `True`. One removed the rule and one did not, and only reading the group back told them apart. The guide warns about the opposite case (`--ip-permissions` silently removing nothing); on this build it was the rule-ID form that lied.
- **Bugs in the guide's commands.** The `length(IpPermissionsEgress...)` query appears in six places without `SecurityGroups[0].`. The escaped program in Step 19's heredoc does not parse here. The verify script had three checks that could never pass on my repository. In each case I fixed the command, re-ran it, and wrote down what I changed, rather than accepting a FAIL or editing a number.
- **My own repository differs from the guide's.** My Lab 01 role variables hold ARNs. My transcripts policy grants two write verbs and is on three roles. My developer policy already allows `sts:GetCallerIdentity`, so the session-policy example needed a different uncovered action to show anything.
- **The restart wiped Lab 07/08 again.** After the lab I rebuilt the EKS cluster from the committed files: verify-lab-07 is `30/0` and verify-lab-08 is `33/1`, as before.

**Still open, by design or by limitation.**
- `usms-ec2-app-role` (EC2 sends no `aws:SourceArn`), the ECS execution role and the Lambda role still have unconditioned service trust (Exercise 2).
- `usms-app-sg` is a second internet entry point with default egress (Exercises 1 and 4).
- The DB tier can still HTTPS POST anywhere.
- The boundary and IMDSv2 are written down in `policies/` and the notes, but are not in force on this emulator.

## 8. Reflection

The habit I will keep is reading back instead of trusting exit codes. Twice in this lab a command said `True` and did nothing, and once a command was accepted and its setting silently dropped. On real AWS the second case is rarer, but the first is exactly how a security change "goes out" and then turns out never to have applied. The read-back has to be a different call from the write, and it has to be a script, which is what the three audit tools and the verify script are.

The two-axes picture also changed how I think about Lab 05. There I argued about the load balancer's inbound rule; I never asked what the load balancer could *initiate*. Writing egress made me derive each group's legitimate outbound traffic from the architecture: the registry, logs and S3 for the tasks; the targets for the load balancer; OS updates for the database. That derivation is what tells a correct rule from a guessed one, and it showed me that 443 to `0.0.0.0/0` is still a wide door.

Finally, the "negative" proof was the most satisfying part. I cannot test that nobody on the internet can reach the database, but I can list five independent things that would each have to fail. Writing down what still stops an attacker when any one of them breaks is a better answer to "is it secure?" than any single test could give.

## 9. Conclusion

USMS now has:
- a read-only transcripts policy on a new reader role;
- confused-deputy conditions on the ECS task role, with the same principal and permissions;
- a deploy role whose `iam:PassRole` is limited to three named ECS roles and the ECS tasks service, with an explicit Deny on passing anything to EC2;
- a rotated developer key, done without an outage window;
- written egress on the load balancer, enrolment and database groups;
- SSH to the web tier only from a bastion group.

Two audit scripts and a reachability matrix make the posture re-checkable at any time, and five independent controls keep the database off the internet.

Two controls exist only as documents on this emulator. The permissions boundary is created but not stored on the role, and IMDSv2 is unsupported. Both are listed in the course's Known Issues; I recorded them and ran its alternative.

The posture survived a Floci restart (`PERSISTENCE PROVEN`), the five earlier verification scripts report exactly what they did before (`NOTHING BROKE`), and `verify-lab-09.sh` finished at `PASS=48 FAIL=2`, with both failures being those two gaps. The work is committed as `7af7236`, with 16 values in `configs/lab-09.env` for Lab 10 and the CloudFormation lab.

## 10. Appendix

**Key resource identifiers from this lab:**

| Resource | Value |
|---|---|
| Read-only policy | `arn:aws:iam::000000000000:policy/USMSStudentDataReadOnly` (Get + List; Deny Put/Delete/DeleteBucket/PutBucketPolicy) |
| Reader role | `arn:aws:iam::000000000000:role/usms-transcripts-reader-role` (ecs-tasks + SourceAccount/SourceArn) |
| Task role trust | `usms-ecs-task-role`: same principal, conditions `aws:SourceAccount 000000000000`, `aws:SourceArn arn:aws:ecs:us-east-1:000000000000:*` |
| Deploy policy | `arn:aws:iam::000000000000:policy/USMSDeployBase` (PassRole to 3 ECS roles, ecs-tasks only; Deny PassRole to EC2) |
| Boundary | `arn:aws:iam::000000000000:policy/USMSPermissionsBoundary`, attached to nothing; not stored on the role by Floci |
| Deploy role | `arn:aws:iam::000000000000:role/usms-deploy-role` (trusts `user/usms-admin-01`) |
| Access key | `usms-dev-01`: `AKIAEES3X0N2F09V5JNX` deleted; one key created 2026-11-06 (ID kept out of committed files) |
| Bastion group | `sg-a2b2c9e9f29481762` (`usms-bastion-sg`, 22 from `203.0.113.10/32`) |
| S3 prefix list | `pl-63a5400a` |
| Egress written | `usms-enrolment-sg` 443 to the prefix list and `0.0.0.0/0`; `usms-alb-sg` 80 to `sg-ed703590b42f25128`; `usms-db-sg` 443 to `0.0.0.0/0` |
| IMDS | `usms-web-01` still `optional` (`UnsupportedOperation`) |
| Audits | IAM `HIGH=7 MED=30` → task role HIGH removed; SG `HIGH=4 MED=8 LOW=4` → `HIGH=4 MED=5 LOW=5` |
| Commit | `7af7236` |

**Files produced for this lab:**
- `policies/usms-student-data-ro-policy.json`, `usms-deploy-policy.json`, `usms-permissions-boundary.json`, `trust-ecs-tasks-scoped.json`, `trust-deploy.json`: the identity documents.
- `policies/usms-alb-sg-egress.json`, `usms-enrolment-sg-egress.json`, `usms-db-sg-egress.json`, `usms-app-sg-ssh-bastion.json`, `usms-egress-allow-all.json`: the network documents, including the undo.
- `scripts/utilities/usms-iam-audit.sh`, `usms-sg-audit.sh`, `usms-reachability-matrix.sh`: the read-only audit tools.
- `scripts/utilities/verify-lab-09.sh`: the 50-check verification (48/2).
- `scripts/utilities/student-fallback-demo.py`: the Known Issues alternative, copied from the course page after reading it.
- `scripts/cleanup/lab-09-cleanup.sh`: end-of-course teardown, syntax-checked only and never run.
- `configs/lab-09.env`: 16 exports, no access key ID.
- `notes/lab-09-notes.md`: path, deviations, "Your turn" answers, IMDS and rotation reasoning, the Section 14 answers and the limitations.
- `outputs/lab-09-*` and `outputs/usms-dev-01-access-key-new.json`: inventory, findings, before/after evidence and the new key, git-ignored.
