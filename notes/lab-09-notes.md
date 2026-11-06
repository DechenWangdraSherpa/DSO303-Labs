# Lab 09 notes

**Support path: A.** Every IAM read and write call in Step 3 answered, and `simulate-principal-policy` answered too. Only `get-account-authorization-details`, `accessanalyzer list-analyzers` and `get-credential-report` are not available. The simulator really reads the documents: it returned `explicitDeny` for `iam:CreateUser` because `USMSDeveloperBase` has a `DenyDangerousIdentityChanges` statement.

**The bucket did not exist yet.** `head-bucket --bucket usms-student-data` returned `404 Not Found` (exit 254). Lab 10 creates it. An IAM policy is about ARNs, so it can be reviewed before the resource exists.

## Deviations from the lab text, and why

- **Role variables hold ARNs.** In my `configs/lab-01.env`, `USMS_ROLE_DEVELOPER`, `USMS_ROLE_EC2` and `USMS_ROLE_LAMBDA` are full ARNs, not names (the same as `USMS_POLICY_S3_RW`). I used `${VAR##*/}` where the guide needs a name, and the ARN directly in Step 9 instead of rebuilding it.
- **More roles than the guide.** The inventory has 8 roles: the guide's 5, plus `usms-eks-cluster-role` and `usms-eks-node-role` from Lab 07, plus Lab 06's `AWSServiceRoleForEcsApplicationAutoscaling`. The IAM audit therefore reports `HIGH=7 MED=30`, not `4/5`. The EKS roles are out of scope for this review, as the guide says, but the audit sees them and I left them in.
- **Lab 01's policy has two write verbs.** My `USMSStudentDataReadWrite` grants `s3:PutObject` **and** `s3:DeleteObject`, and it is on three roles (EC2, ECS task, EKS node). The guide expects one write verb on two roles.
- **Step 9: no line was denied at first.** My `USMSDeveloperBase` allows `sts:GetCallerIdentity` explicitly. The guide's substitute, `s3:ListAllMyBuckets`, would still match `s3:List*`. So I added `s3:PutObject` to the session policy, an action the role never had, and it came out `NOT in the identity policy -> denied`. The simulator agreed (`implicitDeny`). Floci also ignored `--role-session-name` (the session ARN reads `.../floci-session`).
- **Permissions boundary not stored.** `create-role --permissions-boundary` and then `put-role-permissions-boundary` were both accepted, but `get-role` returns `PermissionsBoundary: null`. This is the Known Issue for Lab 09; verify-lab-09 lists it as benign.
- **IMDSv2 not available.** `modify-instance-metadata-options` returns `UnsupportedOperation`, so `usms-web-01` stays `HttpTokens: optional`. The `usms-db-01` "Your turn" (`--http-endpoint disabled`) failed the same way. This is also the Known Issue for Lab 09.
- **Known Issues alternative.** I installed `scripts/utilities/student-fallback-demo.py` from the course's Known Issues page, after reading it: it uses only local 127.0.0.1 servers and makes no AWS calls. `security` printed `s3:GetObject: ALLOW`, `s3:PutObject: DENY`, `s3:DeleteObject: DENY`, `Without token: HTTP 401`, `With token: HTTP 200`. It is a teaching model, not an IAM evaluator or IMDSv2.
- **Two views of the security groups disagree.** `revoke-security-group-egress --ip-permissions` returns `True` and removes the rule from `describe-security-groups`. But `describe-security-group-rules` keeps listing the revoked `-1` rule (`sgr-ac23b115666ab7238`, `sgr-ca15d4e9cafc926aa`, `sgr-8470bff36f49d8cff`). Revoking that stale entry by `--security-group-rule-ids` also returns `True` and changes nothing. I treated `describe-security-groups` as the source of truth, because the guide's checks, the audit scripts and verify-lab-09 all read it.
- **Step 16: the rule-ID revoke is a no-op.** The guide's `revoke-security-group-ingress --security-group-rule-ids sgr-c8cf47eda7d6b07f5` returned `True`, but the 10.0.0.0/16 SSH rule was still there. The guide warns about the opposite case. I revoked it with `--ip-permissions 'IpProtocol=tcp,FromPort=22,ToPort=22,IpRanges=[{CidrIp=10.0.0.0/16}]'`, which worked, and checked that the CIDR count on port 22 is `0`.
- **The guide's `length(IpPermissionsEgress[...])` query is missing `SecurityGroups[0].`** It errors with `invalid type for value: None`. This is in Step 15's check, Step 18 (twice), Step 19's env heredoc and verify-lab-09's `allowall()`, and the same for the port-22 `IpPermissions` count. I fixed each one by adding `SecurityGroups[0].`.
- **Step 19: escaped `\$(...)` in the unquoted heredoc** is a bash syntax error on this shell (the same trap as Lab 06). I used the guide's own "readable alternative": compute `REMAINING` first, then insert it. `bc` is not installed, so the sum uses `awk`.
- **verify-lab-09.sh: three script bugs fixed, two benign failures kept.**
  - The boundary-attachment check had over-escaped quotes (`\\\"`), so the query was garbage. The real `AttachmentCount` is `0`.
  - The port-22 CIDR check had the missing `SecurityGroups[0].` described above.
  - "No unexpanded variable" flagged Lab 01's `usms-self-manage-credentials.json`, whose `${aws:username}` is a legitimate IAM policy variable. The guide itself says that variable must survive. I narrowed the check to shell-style `${UPPER_CASE}` names and tested it with a temporary file containing `${USMS_ACCOUNT_ID}`, which it caught.
  - As in Labs 04 to 08, "no secret is tracked by git" allows `outputs/.gitkeep`.
- **Tags.** I tagged the new resources `Lab=09`. The guide still says `Lab=05`, left over from the old numbering.
- **Step 18 restart side effects.** As in Labs 05 to 08, the restart stopped `usms-web-01`, and I started it before the regression run (on screen). It also deleted the Lab 07/08 k3s cluster again. I rebuilt it from the committed templates and manifests after the lab: verify-lab-07 `30/0`, verify-lab-08 `33/1`, both unchanged.

## Step 4 "Your turn" - two kinds of trust

`usms-ec2-app-role` trusts `{"Service": "ec2.amazonaws.com"}`. Its credentials go to whatever EC2 instance is launched with its instance profile, and are fetched by any code on that instance from the metadata service. So *who* gets them depends on who may call `ec2:RunInstances` with `iam:PassRole` for that profile, and on anything that can make the instance send a metadata request (SSRF).

`usms-developer-role` trusts `{"AWS": "arn:aws:iam::000000000000:user/usms-dev-01"}`. Only that one named user can obtain its credentials, by calling `sts:AssumeRole` with their own access key. *How* is a deliberate API call by a known identity, which is logged and can require MFA.

## Step 6 "Your turn" - what each workload needs

- **Enrolment API, showing a transcript:** `s3:GetObject` on `usms-student-data/*`, plus `s3:ListBucket` on the bucket, so that a missing key returns `404 NoSuchKey` instead of `403 AccessDenied` and the application can tell "not uploaded yet" from "forbidden".
- **Registry upload workflow, storing one:** the same two, plus `s3:PutObject`.
- **The difference is exactly `s3:PutObject`.** My Lab 01 policy also grants `s3:DeleteObject` (and `s3:GetBucketLocation`). Neither workload deletes transcripts, so `DeleteObject` is a second verb nobody uses. On the reader role it is now explicitly denied.

## Step 10 - rotation

`AKIAEES3X0N2F09V5JNX` (created 2026-08-23) was replaced by `AKIA3B5VPR6647E4V0BA` (2026-11-06). The order was create, repoint the `usms-dev` profile, deactivate, delete. `get-caller-identity --profile usms-dev` answered `user/usms-dev-01` after every step. The lab compresses the pause between deactivating and deleting; on a real system I would leave the old key inactive for a day or a week. Lab 01's key file `outputs/usms-dev-01-access-key.json` was removed. The new one is `chmod 600` and ignored by `.gitignore:8:outputs/*`.

What would replace this key on a real account: IAM Identity Center (SSO) for the human, giving short-lived credentials per login, and roles (instance profile, task role, IRSA) for every workload.

## Step 11 - IMDSv2 (not applied: UnsupportedOperation)

- **`--http-tokens required`** stops **SSRF credential theft**. An attacker who makes the application GET `http://169.254.169.254/latest/meta-data/iam/security-credentials/...` gets nothing, because a token needs a `PUT` with a header, which an SSRF bug almost never controls.
- **`--http-put-response-hop-limit 1`** stops a **container on the instance** (one network hop away) from getting a token, and so from inheriting the host's role.
- **Rollout without an outage:**
  1. Watch the `MetadataNoToken` CloudWatch metric.
  2. Update any old SDKs or agents still using IMDSv1 until the metric stays at zero.
  3. Only then set `required`.
  4. Then do the same through the launch template, so replacement instances are born compliant.

**Your turn, `usms-db-01`:** it has no instance profile (`Profile: null`), so it needs no metadata credentials at all. The stronger setting is `--http-endpoint disabled`, which turns IMDS off completely. That call also failed with `UnsupportedOperation`. Applying `--http-endpoint disabled` to `usms-web-01` would break it: its application gets the `usms-ec2-app-role` credentials from IMDS (Lab 03 Step 11), so every AWS SDK call from the web tier would fail with no credentials.

## Step 15 - what the DB egress rule still allows

DNS, SSH, database connections, SMTP and port 80 out are now denied. tcp/443 to `0.0.0.0/0` still lets an attacker HTTPS POST the data to any server. Stopping that needs hostname filtering (AWS Network Firewall or an egress proxy with an allow-list), which this course cannot build on Floci. A complete rule set would also need UDP and TCP 53 to the VPC resolver for `dnf update`. That is left out because Floci provides no resolver (Exercise 1).

## Step 17 - defence in depth on usms-db-01

All five controls read correctly:
1. no public IP (`None`);
2. `MapPublicIpOnLaunch False`;
3. the default route goes to `nat-0e606949dd0ad396c`, not an IGW;
4. `5432` from `sg-39a66c2dc43f3eef3` (usms-app-sg) with no CIDR;
5. `acl-0e6976c10a52c455f`, `IsDefault False`.

- **If control 3 failed** (an IGW route appeared): the instance still has no public address for the internet to send to, the group still admits only `usms-app-sg`, and the custom NACL still applies.
- **If control 4 failed** (the group admitted `0.0.0.0/0`): there is still no public address and no route to an internet gateway, so nothing on the internet can reach it or get a reply.

The matrix also names `usms-enrolment-sg`, `usms-db-sg`, `usms-bastion-sg` and `usms-eks-cluster-sg` as single points of control at the security-group layer.

## Section 14 - review questions

1. **Why "NOTHING BROKE" is strong.** Those five scripts were written before this lab, by someone who was not thinking about it, and they assert dozens of properties: routes, groups, the service, the load balancer, scaling. An identical summary line means none of those properties moved, even though I rewrote a trust policy, removed three egress rules and replaced an SSH rule. A plausible break: Lab 05's verify could check that `usms-alb-sg` egress reaches the targets. If I had written the ALB egress as a CIDR or forgotten it, that check would have failed. I would read the failing check, decide whether my change or the check was wrong, and either fix the rule or update the check with a comment saying why (Lab 05 Step 13's rule).

2. **Attaching the boundary as an ordinary policy.** It is no longer a ceiling; it becomes a grant.
   - **Upward:** the role gains `ecs:*`, `elasticloadbalancing:*`, `logs:*`, `cloudwatch:*`, `s3:Get*`/`List*`/`PutObject`, and **`iam:PassRole` on `Resource "*"`**. Combined with `ecs:*`, that is exactly the escalation path Step 8 closed.
   - **Downward:** the role loses its ceiling. A later broad policy would apply in full, except where the Deny statements, which are still attached, still deny.

   It becomes dangerous as soon as a privileged role with an `ecs-tasks` trust exists, because the deploy role could then pass it. Section 8's "the boundary is attached to NOTHING as an ordinary policy" check catches it (the attachment count stops being 0).

3. **A breach with perfect ingress.** An attacker finds an SSRF or code-execution bug in the enrolment API, through the load balancer, on a port that is correctly open. The task role can read transcripts, so the attacker reads them and sends them out. Every ingress rule did its job.
   - **Step 13** narrows the exit: with tcp/443 only, the attacker cannot use DNS tunnelling, SSH or arbitrary command-and-control ports, but an HTTPS POST to their own server still works.
   - **Step 15** does the same for the data tier.
   - **Prevention** needs egress filtered by destination name or identity: VPC interface endpoints plus no `0.0.0.0/0` route, an egress proxy or Network Firewall allow-list, and S3 endpoint and bucket policies pinned to the VPC endpoint (Exercise 5). This course cannot build it because Floci carries no traffic and has no Network Firewall.

4. **Calling `sts:AssumeRole` from an attacker's own machine.**
   - **`usms-ecs-task-role` and `usms-transcripts-reader-role`:** the trust principal is the ECS tasks *service*, so a human or an outside account calling `AssumeRole` is not that principal and is refused. The conditions also stop the ECS service assuming the role on behalf of another account's tasks (the confused deputy).
   - **`usms-deploy-role`:** the principal is the user `usms-admin-01`. If the attacker holds that user's credentials, `AssumeRole` succeeds from anywhere. What limits the damage is the deploy policy and the boundary, and on this build the boundary is not stored, so on Floci only the policy would. The hardening is an `aws:MultiFactorAuthPresent` condition.

   The answers differ because service trust is about *who may act as a service*, while user trust is about *whose credentials an attacker has*.

5. **Five controls versus one.** They are not five times better, because they are not independent in every failure mode.
   - Controls 1 and 2 (no public IP, no auto-assign) would both be undone by the same mistake: launching into the wrong subnet.
   - Controls 3 and 5 sit on the same subnet association.

   Real independence is between layers: addressing, routing, the security group and the NACL. And the matrix models **security groups only**. The enrolment tasks also sit in private subnets with no public IP and no IGW route, so at the network level they have the same address and routing controls as the database. The "single point of control" finding is true for the SG layer and overstated for the system.

6. **The two extra rotation steps.**
   - **Updating consumers before deactivating** prevents the outage where the old key dies while something still uses it, which shows up as `InvalidClientTokenId` across the pipeline.
   - **Deactivating before deleting** prevents an irreversible mistake. If a forgotten consumer breaks, one `update-access-key --status Active` brings the key back; a deleted key cannot be re-issued.

   A long-lived key is a compromise because it is valid until someone remembers to rotate it, it can be copied without anyone noticing, and it ends up in laptops, CI variables and screenshots. A real system would use IAM Identity Center for humans and roles for workloads, so that nothing long-lived exists.

7. **Is reading enough instead of testing?** It is not a full substitute.
   - **Reading catches** what testing cannot show: that the reader role *could never* write, or that `iam:PassRole` names three ARNs. "Cannot" is a property of the document, and no finite set of tests proves a negative.
   - **Testing catches** what reading misses: a condition key the service never sends (`aws:SourceArn` from EC2), which reads as correct but makes the role unassumable. Or a policy that is right but attached to the wrong role.

   For student transcripts I would want reading first, because the most important claim is a negative (nobody else can read or change them). I would follow it with real-AWS tests of the positive paths before any data went in.

## Floci limitations hit (and what real AWS does)

| Floci 1.7.0 | Real AWS |
|---|---|
| Nothing is authorised against IAM; every call succeeds | Every call evaluated: Deny, SCP, boundary, session, identity, resource |
| `--permissions-boundary` / `put-role-permissions-boundary` accepted, not stored | Stored, enforced, and shown by `get-role` |
| `ModifyInstanceMetadataOptions` is `UnsupportedOperation`; no IMDS exists | IMDSv2 enforced at the hypervisor immediately |
| `simulate-principal-policy` works and reads the documents | The same, plus resource policies and conditions with context keys |
| `--role-session-name` ignored (`floci-session`) | The session name appears in the ARN and CloudTrail |
| `describe-security-group-rules` keeps rules that `describe-security-groups` no longer has | One rule set, two views of it |
| Revoke by `--security-group-rule-ids` returns `True` and removes nothing | Removes exactly that rule |
| No traffic: security groups and NACLs are never evaluated | Every packet evaluated |
| Network interfaces not modelled for the ALB or tasks (audit shows 0) | Each ALB node and task has an ENI |
| A Floci restart stops `usms-web-01` and deletes the k3s cluster | Nothing restarts |
