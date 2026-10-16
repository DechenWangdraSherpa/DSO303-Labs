# Lab 4 – Containerising the USMS Enrolment Service on Amazon ECS (Fargate)

**Name:** Dechen Wangdra Sherpa
**Student Number:** 02230281
**Course:** DSO303 – Cloud Native Design Patterns
**Lab:** Lab 4 – Amazon ECS

---

## 1. Aim / Objective

The aim of this lab was to move the USMS enrolment service, the endpoint the student portal calls when someone clicks "Register for this module", off a hand-managed server and onto Amazon ECS using Fargate. By the end I needed a cluster, a log group, a task definition and a service holding a fixed `desiredCount` of 2 across both private subnets from Lab 2. I also had to keep two ECS roles separate (the execution role that pulls the image and writes logs, and the task role that is the application's own identity), reuse Lab 1's `USMSStudentDataReadWrite` policy on the task role, and record every name and ARN in `configs/lab-04.env` so Labs 5 and 6 can use them.

## 2. Introduction

Lab 1 gave USMS its identities and permissions, Lab 2 gave it a network, and Lab 3 put EC2 servers inside that network. Those servers are fixed-size and need someone to look after them. In this lab I moved the enrolment service onto ECS, where I describe what should run (a task definition) and a service controller keeps the right number of copies running, replacing any that fail.

ECS comes down to four objects, which I found easiest to remember this way:

- **Cluster:** a namespace, not a machine. It is the folder everything else lives in.
- **Task definition:** an immutable, versioned blueprint (`usms-enrolment:1`). I never edit a revision, I register a new one.
- **Task:** one running copy of that blueprint.
- **Service:** the controller that keeps `runningCount` equal to `desiredCount`.

Fargate removes the servers I had to manage in Lab 3, but it does not remove the network. Each Fargate task in `awsvpc` mode still gets its own network interface in my subnet, with my security group, and it still follows my route tables.

As in the earlier labs, everything was done with the AWS CLI against Floci, a local AWS emulator. Floci stores and returns ECS objects correctly, but it does not behave exactly like real AWS in places, so a few results below differ from what the lab text predicted. I have kept those in rather than hiding them.

## 3. Use Case

On enrolment day, the student portal's web tier calls the enrolment service, and that traffic spikes hard in the first few minutes. The service should not live on a single server I have to log in to and fix. With ECS, the enrolment API runs as an immutable task definition in private subnets across two Availability Zones, so one zone failing does not take it down. Nothing from the internet can reach it directly, only the web tier can call it, and a failed task is replaced automatically. This lab builds that service at a fixed size. Lab 5 puts a load balancer in front of it and Lab 6 lets the count change on its own.

## 4. System Architecture / Design

Everything sits inside `usms-vpc` from Lab 2:

```
Web tier (usms-web-01, usms-app-sg)  --- tcp/80 --->  usms-enrolment-sg
                                                         |
                                  +----------------------+----------------------+
                                  |                                             |
                     usms-private-subnet-a (AZ a)                 usms-private-subnet-b (AZ b)
                             [ task 1 ]                                   [ task 2 ]
                                  |                                             |
                                  +---- usms-private-rt --> NAT gateway --> image pull

ECS control plane
  usms-ecs-cluster
    usms-enrolment-svc   desiredCount 2 (set by hand)
      task definition usms-enrolment:1  (FARGATE, awsvpc, 256 CPU / 512 MiB)
        execution role  usms-ecs-exec-role  -> pull image, write logs
        task role       usms-ecs-task-role  -> USMSStudentDataReadWrite (from Lab 1)
```

The key design choices were:

- **Two roles, same trust policy, different jobs.** Both trust `ecs-tasks.amazonaws.com`. The execution role is used by Fargate before my code starts (image pull, log stream). The task role is used by my code once it is running.
- **Least privilege on the execution role.** My `USMSECSTaskExecution` policy allows only the four ECR pull actions and log writes to one log group, instead of the broader AWS-managed execution policy.
- **Security group sourced from a group, not a CIDR.** `usms-enrolment-sg` accepts tcp/80 only from `usms-app-sg`. Tasks have no stable addresses, so a group reference keeps working however many tasks there are.
- **No public IP.** The service uses `assignPublicIp=DISABLED` in both private subnets. A private-subnet task can still pull its image because `usms-private-rt` sends outbound traffic to the NAT gateway from Lab 2, and layer data can come through the S3 gateway endpoint.

## 5. Implementation Procedure

### Step 1–2: Resume the environment and check Labs 2 and 3

I brought Floci up, loaded the four env files, and printed the eight values this lab needs (both private subnets, the app security group, VPC, NAT gateway, web instance, region, account). Then I re-ran the Lab 2 and Lab 3 verify scripts to make sure what I was building on was still intact.

![Identity and the eight inherited values](<../../screenshots/Lab-04/01-environment-and-labs-ready_1.png>)
*All eight values came back non-empty, including both private subnets, which matters because the service needs two Availability Zones.*

![Lab 2 verification passing](<../../screenshots/Lab-04/01-environment-and-labs-ready_2.png>)
*`verify-lab-02.sh` ended at `PASS=33 FAIL=0`. The line I cared most about is "private rt has NO route to an internet gateway", because if that fails the subnets are not really private.*

![Lab 3 verification passing](<../../screenshots/Lab-04/01-environment-and-labs-ready_3.png>)
*`verify-lab-03.sh` ended at `PASS=36 FAIL=0`, including "usms-web-01 carries usms-app-sg", which the enrolment security group depends on.*

### Step 3: Probe what this Floci build supports

Before building, I probed which ECS, Application Auto Scaling and CloudWatch operations this Floci build actually answers, so I would know now rather than in Lab 6.

![Floci support probe](<../../screenshots/Lab-04/02-support-path-probed.png>)
*Two lines said `not available`. I ran both directly. `describe-services` on a cluster called `probe` returned `ClusterNotFoundException`, which means ECS did answer and the cluster just does not exist, so ECS is supported. `describe-scheduled-actions` returned `UnsupportedOperation`, which is a real gap. Scalable targets and scaling policies work, but scheduled actions do not.*

I recorded this at the top of `notes/lab-04-notes.md` as **Path B (ECS supported, Application Auto Scaling only partly)**. Nothing in Lab 4 changes for that, but Lab 6 reads this note and needs a fallback for its scheduled-scaling step.

### Step 4: Create the cluster as the developer role

I assumed `usms-developer-role` (as in Lab 2) and created the cluster with Container Insights requested, then unset the temporary credentials so the rest of my commands ran as my normal identity again.

![Assumed role and cluster created](<../../screenshots/Lab-04/03-cluster-created_1.png>)
*The caller identity shows `assumed-role/usms-developer-role/...`, so the cluster was created under the developer role and not my root identity. (Floci names the session `floci-session` instead of the `lab04-ecs-build` name I asked for, which is harmless.)*

![Identity restored and cluster verified](<../../screenshots/Lab-04/03-cluster-created_2.png>)
*After `unset`, `whoami.sh` shows my normal identity again, and `describe-clusters` reports `ACTIVE` with 0 services and 0 tasks. `Settings` came back `null`, so Floci did not store the Container Insights setting I asked for. I recorded that as a limitation.*

### Step 5: Log group

ECS does not create the log group for me, and a missing one stops the task from starting, so I created `/usms/ecs/enrolment` and set 7-day retention.

![Log group with retention](<../../screenshots/Lab-04/04-log-group-created.png>)
*The log group exists with `Retention = 7`. Bytes is 0 because nothing has logged yet. Retention is a separate call, and without it a log group keeps data forever.*

### Step 6: Task execution role

I wrote the trust policy for `ecs-tasks.amazonaws.com`, created `usms-ecs-exec-role`, then wrote and attached my own least-privilege policy `USMSECSTaskExecution`.

![Trust policy valid and execution role created](<../../screenshots/Lab-04/05-execution-role-created_1.png>)
*The trust policy validated as JSON and the role was created.*

![Execution policy attached and role verified](<../../screenshots/Lab-04/05-execution-role-created_2.png>)
*The role's principal is `ecs-tasks.amazonaws.com` (not `ecs.amazonaws.com`, the most common typo) and `USMSECSTaskExecution` is attached.*

### Step 7: Task role, reusing Lab 1's policy

I created `usms-ecs-task-role` with the same trust policy and attached Lab 1's `USMSStudentDataReadWrite` unchanged, instead of writing a new copy.

My first attach attempt failed with `NoSuchEntity`. The lab builds the ARN as `policy/${USMS_POLICY_S3_RW}`, but in my Lab 1 env file that variable already holds the **full ARN**, so the command produced `policy/arn:aws:iam::...:policy/...`. I attached it again using the variable directly as the ARN, and the role itself did not need to be recreated.

![Task role carries Lab 1's policy](<../../screenshots/Lab-04/06-task-role-reuses-lab1-policy.png>)
*The task role has `USMSStudentDataReadWrite` attached, and the policy document shows what it allows: list the bucket, read/write/delete objects inside `usms-student-data`, and an explicit deny on `s3:DeleteBucket`. That is the same policy Lab 3 gave to the EC2 instance through an instance profile. The bucket does not exist yet, so the permission chain is correct but unused until it is created in a later lab.*

### Step 8: Enrolment security group

I created `usms-enrolment-sg` and allowed tcp/80 only from `usms-app-sg`, by group reference.

![Security group sourced from the web tier group](<../../screenshots/Lab-04/07-enrolment-sg-created.png>)
*One inbound rule, port 80, `FromGroup` is `sg-39a66c2dc43f3eef3` (the web tier's `usms-app-sg`) and `FromCIDR` is `null`. `OutboundRules` is 1, the default allow-all egress, which the image pull needs.*

### Step 9: Write and register the task definition

I wrote `templates/lab-04-taskdef.json` with an unquoted heredoc so my role ARNs and log group were filled in at write time. It is a request body, so it lives in `templates/` and not `policies/`. Then I registered it.

![Task definition registered and read back](<../../screenshots/Lab-04/08-taskdef-registered.png>)
*The file is valid JSON and `grep -c '\$'` printed `0`, so no variable was left unexpanded. The task definition `usms-enrolment:1` is `ACTIVE`, `awsvpc`, 256 CPU / 512 MiB, FARGATE compatible, and `Exec` and `Task` are two different ARNs (`usms-ecs-exec-role` and `usms-ecs-task-role`). If they had been the same, my code would have been denied access to S3. The container is `enrolment-api` using `nginx:stable-alpine` as a stand-in image. `LogGroup` printed `null` in this readback, so I could not confirm the log configuration through `describe-task-definition` on this build, even though I wrote it into the file.*

### Step 10–11: Create the service and read the four numbers

I created `usms-enrolment-svc` with `desiredCount` 2 on FARGATE, across both private subnets, with `assignPublicIp=DISABLED` and the enrolment security group.

![Service created in both private subnets](<../../screenshots/Lab-04/09-service-created-and-stable.png>)
*The service is `ACTIVE` with `Desired: 2`, `Running: 2`, `Pending: 0`, on FARGATE, spanning `subnet-1150e689` and `subnet-47a7fe37` (my two private subnets), carrying `sg-ed703590b42f25128` (`usms-enrolment-sg`) with `PublicIP: DISABLED`. `list-tasks` returned 2, so this build did start two tasks. The `TaskDef` field showed the family name `usms-enrolment` and not the full revision ARN, and the service events list printed `None`, so Floci does not narrate service events the way real ECS does.*

**Your turn: changing the count by hand.** Before any auto scaling exists, I set the desired count to 3, then back to 2, which is exactly what a scaling policy will do for me in Lab 6.

![Desired count 2 to 3 to 2](<../../screenshots/Lab-04/10-desired-count-changed-by-hand.png>)
*`desiredCount` moved to 3 and back to 2. I checked five seconds after each change, and `Running` trailed behind: it was still 2 when desired was 3, then showed 3 right after I set desired back to 2. I read that as the service controller catching up one step late. When I checked again later it had settled at Desired 2 / Running 2. This is the "reconciliation loop" in practice: I change the target number and the controller works toward it.*

### Step 12: Record everything in `configs/lab-04.env`

I wrote the env file with lookups (not shell variables), so a filled-in value is proof the resource exists.

![Lab 4 env file written and sourced](<../../screenshots/Lab-04/11-lab04-env-written.png>)
*`all values populated`, nothing empty or `None`. The printed values show the cluster, service, `baseline desired = 2` (read back, not typed in), task revision 1, container `enrolment-api`, 256 / 512, the enrolment security group, and the task role ARN. The file has 17 exports.*

### Section 8: Verification script and cleanup script

I built `verify-lab-04.sh` from the lab. On the first run it gave `PASS=37 FAIL=1`. The failing check was "no secret is tracked by git", which fails if git tracks anything under `outputs/`. My repo deliberately tracks `outputs/.gitkeep`, so the lab's check was tripping on its own placeholder file. I confirmed with `git ls-files outputs/` that only `.gitkeep` was tracked and `git check-ignore -v` showed my credentials file was ignored, then changed that one check to allow `.gitkeep` and still fail on any other tracked file under `outputs/`.

![Final verification](<../../screenshots/Lab-04/12-verify-lab04-pass.png>)
*After the fix, every Lab 4 check is `ok` and the script ends at `PASS=38 FAIL=0`.*

I also built `scripts/cleanup/lab-04-cleanup.sh` and ran only `bash -n` on it, which parses the script without executing it. It deletes the service, cluster, roles and log group, and Labs 5 and 6 depend on all of those, so it is for the very end of the course only.

### Step 13: Commit

I checked that the credentials file was git-ignored and that nothing under `outputs/` was staged, staged the Lab 4 files by explicit path, and committed.

![Lab 4 committed](<../../screenshots/Lab-04/13-commit-proof.png>)
*The commit contains 7 files (the env file, the three policy documents, the task definition template, and both scripts), and `git log` shows the Lab 2, Lab 3 and Lab 4 commits in order.*

## 6. Results and Evidence

### 6.1 CLI/SDK Output

Everything was built and checked through the AWS CLI against Floci. The final state, matching the lab's checkpoints:

| Checkpoint | What had to be true | Result |
|---|---|---|
| 1 (Step 3) | Env loaded, Labs 2 and 3 pass, support path recorded | Lab 2 `PASS=33`, Lab 3 `PASS=36`, Path B recorded |
| 2 (Step 7) | Cluster ACTIVE, 7-day log group, two roles, task role has Lab 1's policy | Cluster `ACTIVE`, retention `7`, `USMSStudentDataReadWrite` on the task role |
| 3 (Step 9) | `usms-enrolment:1` ACTIVE, `awsvpc`, FARGATE, 256/512, two different role ARNs | Matches, and `Exec` and `Task` are different roles |
| 4 (Step 11) | Service ACTIVE, desired 2, both private subnets, no public IP, enrolment SG | `ACTIVE`, Desired 2 / Running 2, two subnets, `PublicIP: DISABLED`, `sg-ed703590b42f25128` |
| 5 (Step 13) | Env file has 17 exports, committed, nothing from `outputs/` staged | 17 exports, commit `d02adcc`, ignore rule shown |

The consolidated proof is the verify script at `PASS=38 FAIL=0` (screenshot 12).

## 7. Analysis and Discussion

**What I could observe and what I could only reason about.** I observed: the cluster, the task definition and its immutable revision, the service placement in both private subnets, both roles with their trust and attached policies, the group-referenced security group rule, and `desiredCount` changing by hand. I could only reason about: containers genuinely serving requests, Container Insights metrics, real Fargate start-up delay, packet-level enforcement of the security group, and cost.

**Floci limitations I hit, with what real AWS does:**

- **Container Insights setting not stored.** `describe-clusters --include SETTINGS` returned `Settings: null`. On real AWS the cluster would report `containerInsights = enabled` and publish per-service CPU and memory metrics, which Lab 6's target tracking will need. This build would need a custom metric instead.
- **`describe-scheduled-actions` unsupported.** Application Auto Scaling is only partly implemented. Scalable targets and scaling policies exist, but scheduled scaling does not. Real AWS supports all three, and Lab 6 will need a documented fallback for the scheduled part.
- **Service events are empty.** On real AWS, `describe-services` events narrate what the service is doing and are the first place to look when `runningCount` will not rise. Here the events list printed `None`.
- **Some fields come back thinner than expected.** `describe-services` showed the task definition as the family name and not a full revision ARN, and the log group option read back as `null` from `describe-task-definition`. The values were in the file I registered, but I could not confirm them through the API.
- **Task credentials are not served.** Real Fargate gives the container rotating credentials from `AWS_CONTAINER_CREDENTIALS_RELATIVE_URI`. Floci does not serve that, so the task role is verifiable through the chain (task definition names the role, the role trusts ECS, the role holds the policy) but cannot be used from inside a container.
- **Security groups are not enforced.** I proved the rule is correct, but nothing here drops a packet that breaks it.
- **Snapshots are not supported.** At the end of the lab, `floci snapshot save lab-04-complete` returned HTTP 400, so this build has no snapshot feature. The lab's filesystem fallback is the alternative.
- **Task start-up looks instant.** Real Fargate takes 20 to 60 seconds to start a task. My two tasks showed as running almost immediately, which also means Lab 6's cooldown timings will not behave like real AWS.

**Two problems that were mine to untangle, and not Floci's:**

- **Doubled policy ARN in Step 7.** My Lab 1 env file stores the full policy ARN in `USMS_POLICY_S3_RW`, but the lab assumes it holds only the name. The attach failed with `NoSuchEntity` and I fixed it by using the variable as the ARN directly.
- **A false failure in the verify script.** The lab's "no secret is tracked by git" check fails when `outputs/.gitkeep` is tracked, which it is meant to be. I fixed the check instead of un-tracking the file.

**The count lag.** In "Your turn", `Running` trailed `Desired` by one step in both directions. That is the point of the lab: `desiredCount` is the only thing I write, and the service controller does the rest, over time. It also shows why a fixed count of 2 cannot answer the lab's "08:03 enrolment spike" problem. Nothing in this service reads a metric or a clock, so only a human running `update-service` changes its capacity. That is the gap Application Auto Scaling fills in Lab 6.

## 8. Reflection

The part of this lab that stuck with me is the split between the execution role and the task role. They have the same trust policy and do completely different jobs, and the symptom tells you which one is wrong: if the task never starts and the stopped reason mentions the image or logs, it is the execution role, and if it starts and then my code gets `AccessDenied`, it is the task role. Checking that `Exec` and `Task` were two different ARNs in the task definition felt like a small step, but it is the one that prevents the confusing failure later.

I also liked how Lab 1's policy ended up on two kinds of compute. In Lab 3 it reached an EC2 instance through an instance profile, and here it reaches a container through a task role, and neither has a key sitting on disk. Both will start working the moment the bucket is created.

On the Floci side, this lab reminded me again to read results back instead of trusting that a command ran. Several of the answers I got (null settings, empty events, the policy ARN problem) were only visible because I looked at the output and not just the exit code. I also learned that a check script can be wrong too, as with the `.gitkeep` check, so a failing check is worth investigating before assuming my own work is at fault.

## 9. Conclusion

USMS now has its enrolment service running as an ECS service on Fargate. It has a cluster, a log group with 7-day retention, an immutable task definition, two separate IAM roles (with Lab 1's policy reused on the task role), a security group that only trusts the web tier, and a service holding a fixed `desiredCount` of 2 across both private subnets with no public IP. Every name and ARN is in `configs/lab-04.env` for Labs 5 and 6, the verify script passes at `PASS=38 FAIL=0`, the cleanup script is built and syntax-checked but deliberately not run, and the work is committed. I also recorded the Floci limitations I found (Container Insights settings, scheduled scaling actions, service events, task credentials, snapshots) so the next labs know what to expect. Lab 5 puts a load balancer in front of this service, and Lab 6 makes the count move on its own.

## 10. Appendix

**Key resource identifiers from this lab:**

| Resource | Value |
|---|---|
| Cluster | `usms-ecs-cluster` (`arn:aws:ecs:us-east-1:000000000000:cluster/usms-ecs-cluster`) |
| Log group | `/usms/ecs/enrolment` (7-day retention) |
| Execution role | `usms-ecs-exec-role` (`arn:aws:iam::000000000000:role/usms-ecs-exec-role`) |
| Execution policy | `USMSECSTaskExecution` (`arn:aws:iam::000000000000:policy/USMSECSTaskExecution`) |
| Task role | `usms-ecs-task-role` (`arn:aws:iam::000000000000:role/usms-ecs-task-role`) |
| Reused policy | `USMSStudentDataReadWrite` (from Lab 1) |
| Enrolment security group | `usms-enrolment-sg` = `sg-ed703590b42f25128` |
| Allowed source | `usms-app-sg` = `sg-39a66c2dc43f3eef3` |
| Task definition | `usms-enrolment:1` (FARGATE, awsvpc, 256 CPU / 512 MiB) |
| Container | `enrolment-api` (`public.ecr.aws/nginx/nginx:stable-alpine`) |
| Service | `usms-enrolment-svc` (desired 2, both private subnets, no public IP) |
| Private subnets | `subnet-1150e689` (a), `subnet-47a7fe37` (b) |
| Commit | `d02adcc` |

**Files produced for this lab:**
- `policies/trust-ecs-tasks.json`: trust policy used by both ECS roles.
- `policies/usms-ecs-task-execution-policy.json`: least-privilege execution policy.
- `policies/usms-enrolment-sg-ingress.json`: the group-referenced ingress rule.
- `templates/lab-04-taskdef.json`: task definition request body.
- `configs/lab-04.env`: 17 exports for Labs 5 and 6.
- `scripts/utilities/verify-lab-04.sh`: automated check (38/38 passing).
- `scripts/cleanup/lab-04-cleanup.sh`: end-of-course teardown, syntax-checked only and never run.