# Lab 5 – Putting the USMS Enrolment Service Behind an Application Load Balancer

**Name:** Dechen Wangdra Sherpa
**Student Number:** 02230281
**Course:** DSO303 – Cloud Native Design Patterns
**Lab:** Lab 5 – Elastic Load Balancing (Application Load Balancer)

---

## 1. Aim / Objective

The aim of this lab was to give Lab 04's enrolment service a stable name. In Lab 04 the service ran two Fargate tasks with private, temporary addresses, and the only thing allowed to call them was the web tier's security group. By the end of this lab I needed an internet-facing Application Load Balancer in Lab 2's two public subnets with its own security group, a target group of type `ip` with a deliberate health check and deregistration delay, an HTTP:80 listener that forwards to it, and one listener rule. The existing ECS service had to be attached to the target group so that ECS registers and deregisters its own tasks, and then I had to cut over so that the load balancer is the only thing that can reach the tasks. Finally I had to prove the whole stack survives a restart and record its ARNs in `configs/lab-05.env` for Lab 06.

## 2. Introduction

Lab 04 moved the enrolment service onto ECS, but the tasks had no name. Every task gets a new private address when it starts, so nothing can call "the enrolment service" without looking up addresses first. A load balancer fixes that by putting one stable DNS name in front of a group of changing targets.

Elastic Load Balancing comes down to four objects, and I found it easiest to remember them as a chain where each one names the next:

- **Load balancer:** the DNS name, the subnets it lives in and its security group.
- **Listener:** one port and protocol, with exactly one default action.
- **Rule:** a condition and an action. The lowest priority number wins, and the default action always runs last.
- **Target group:** the targets plus the health check. The health check lives here, not on the load balancer.

The most important idea in this lab is that **the ECS service owns the contents of the target group, not me**. Once the service is attached, it registers every task it starts and deregisters every task it stops. Running `register-targets` by hand would appear to work and then be undone by the service.

As in the earlier labs, everything was done with the AWS CLI against Floci. The lab text warns that load balancing is the least reliably emulated service in the course, and several results below differ from what it predicted. I have kept those in and said which things I actually observed and which I could only reason about.

## 3. Use Case

The student portal's web tier calls the enrolment service on enrolment day. Before this lab, it would have had to know the private address of a task, and those addresses change on every deployment and every scaling event. With a load balancer in front, the portal calls one name, the load balancer spreads requests across healthy tasks in two Availability Zones, a broken task is taken out of rotation by the health check, and a new task is added automatically when ECS starts it. The tasks themselves stay in the private subnets with no public address. This also prepares for Lab 06: the best auto scaling signal for a web API, requests per target, only exists once there is a target group.

## 4. System Architecture / Design

Everything sits inside `usms-vpc` from Lab 2:

```
                         Internet
                             |
                 http://usms-enrolment-alb-fbe5d91316b641cd.elb.floci/
                             |
                         usms-igw  (Lab 2)
                             |
   usms-public-subnet-a (us-east-1a)        usms-public-subnet-b (us-east-1b)
        [ ALB node ]  usms-alb-sg                [ ALB node ]  usms-alb-sg
                   \     in: tcp/80, tcp/443 from 0.0.0.0/0     /
                    \                                          /
                     usms-enrolment-alb  (internet-facing, application)
                       listener HTTP:80
                         rule  priority 10  /alb-health -> fixed-response 200
                         default            -> forward usms-enrolment-tg
                                                  target-type ip, GET / every 30s,
                                                  matcher 200, deregistration delay 30s
                             |
                 tcp/80, source = usms-alb-sg ONLY  (usms-enrolment-sg, after Step 13)
                             |
   usms-private-subnet-a (us-east-1a)        usms-private-subnet-b (us-east-1b)
        [ task 1 ]                                [ task 2 ]

ECS control plane
  usms-ecs-cluster
    usms-enrolment-svc   desiredCount 2, task definition usms-enrolment:1
      loadBalancers[0]   usms-enrolment-tg / enrolment-api / 80
      >>> the SERVICE registers and deregisters the targets <<<
```

The key design choices were:

- **One security group per tier, each sourced from the tier above.** `usms-alb-sg` is the only group in the course with a `0.0.0.0/0` rule, and that is deliberate: an internet-facing load balancer has to accept the internet. It is acceptable because of what sits behind it: the tasks' group `usms-enrolment-sg` accepts tcp/80 only from `usms-alb-sg`.
- **Target type `ip`.** Fargate tasks use `awsvpc` networking and have no instance ID, so `ip` is the only target type that works. It cannot be changed after creation.
- **Health check `GET /` every 30 seconds, unhealthy after 2 failures, matcher `200`.** Interval times threshold means a dead task keeps receiving requests for up to 60 seconds.
- **Deregistration delay 30 seconds** instead of the 300-second default, which is far too long for a fast API. Together with `least_outstanding_requests`, a slow but healthy task stops attracting more traffic.
- **Migration, not an outage.** The new path from the load balancer was added and proven (Steps 9 and 12) before the old path from the web tier was removed (Step 13).

## 5. Implementation Procedure

### Step 1–3: Resume the environment, check the earlier labs and probe ELBv2

I brought Floci up, sourced the five env files, and checked the twelve inherited values. Before building anything I re-ran the Lab 2, 3 and 4 verification scripts and saved Lab 04's output to `outputs/lab-05-pre-verify-04.txt` as the "before" for Step 13.

`verify-lab-03.sh` first came back with one failure: "user-data.sh exists and parses". The instances were fine. The script was still checking `labs/lab-03-ec2/user-data.sh`, but in commit `e5f4a71` I had renamed that folder to `labs/lab-03-EC2`. I fixed the path in the script and it went back to `PASS=36 FAIL=0`.

Then I ran the support probe to find out which ELBv2 calls this Floci build answers.

![Prerequisites passing, two public subnets in two AZs, ELBv2 probe part a](<../../screenshots/Lab-05/01-environment-and-support-path_a.png>)
![Prerequisites passing, two public subnets in two AZs, ELBv2 probe part b](<../../screenshots/Lab-05/01-environment-and-support-path_b.png>)
*All three earlier labs pass (`PASS=33`, `PASS=36`, `PASS=38`, all `FAIL=0`). The two public subnets are in different zones, `subnet-c9b01466` in `us-east-1a` and `subnet-92f551f3` in `us-east-1b`, which is the prerequisite most often missing because an ALB refuses to be created in one zone. Every ELBv2 and ECS call answered `SUPPORTED`.*

I recorded **support path B** at the top of `notes/lab-05-notes.md`: objects are created and describable, but there is no data path for a client request. As the rest of the lab showed, my build actually does a little more than path B, because it runs target health checks.

### Step 4: The load balancer's security group

I created `usms-alb-sg` and added its tcp/80 rule from `0.0.0.0/0` using a quoted heredoc, because that document has no variables. For "Your turn" I added a second rule for tcp/443 from a separate JSON document, `policies/usms-alb-sg-ingress-https.json`. The group now admits 80 and 443. The 443 rule alone does not make the load balancer serve HTTPS: it still needs an HTTPS listener on port 443 and a TLS certificate. AWS Certificate Manager issues the certificate for free, but the domain name has to come from a registrar and be proven with a DNS record.

### Step 5: The Application Load Balancer

I created `usms-enrolment-alb` as `internet-facing` and `application` in both public subnets with `usms-alb-sg`, waited for it, read it back, and set two attributes deliberately: a 60-second idle timeout, and dropping invalid header fields.

![Load balancer created and read back part a](<../../screenshots/Lab-05/02-load-balancer-created_a.png>)
![Load balancer created and read back part b](<../../screenshots/Lab-05/02-load-balancer-created_b.png>)
![Load balancer created and read back part c](<../../screenshots/Lab-05/02-load-balancer-created_c.png>)
*The load balancer is `active`, `application`, `internet-facing`, in `vpc-6ffa2a93`, with one entry in `us-east-1a` (`subnet-c9b01466`) and one in `us-east-1b` (`subnet-92f551f3`), carrying `sg-948367004bbccafb6` (`usms-alb-sg`). Floci named it `usms-enrolment-alb-fbe5d91316b641cd.elb.floci`, which is not a real AWS-style DNS name. Both attributes were accepted.*

### Step 6–8: Target group, its attributes, and the listener

I created `usms-enrolment-tg` with `--target-type ip` and the five health check values, set the deregistration delay to 30 seconds and the algorithm to `least_outstanding_requests`, wrote the listener's default action to `templates/lab-05-listener-default-actions.json` with an unquoted heredoc so `$TG_ARN` expanded, and created the HTTP:80 listener.

![Target group, attributes and listener part a](<../../screenshots/Lab-05/03-target-group-and-listener_a.png>)
![Target group, attributes and listener part b](<../../screenshots/Lab-05/03-target-group-and-listener_b.png>)
![Target group, attributes and listener part c](<../../screenshots/Lab-05/03-target-group-and-listener_c.png>)
*The target group is type `ip`, HTTP on 80, in `usms-vpc`, health check `/` every 30 seconds with a 5-second timeout, thresholds 2 and 2, matcher `200`. The deregistration delay is `30` and the algorithm is `least_outstanding_requests`. `grep -c '\$'` printed `0`, so no variable was left unexpanded. The listener forwards HTTP:80 to the target group, and `AttachedLBs` is now `1`.*

For "Your turn" in Step 6 I widened the matcher to `200-399` with `modify-target-group`, read it back, and put it back to `200`. Both changes took effect immediately without recreating anything. The target group was still empty (`[]`), which is correct at this point.

### Step 9: Let the load balancer reach the tasks

I added an inbound rule to `usms-enrolment-sg` admitting tcp/80 from `usms-alb-sg`, using an unquoted heredoc so `$ALB_SG` expanded. Both paths now existed side by side: the old one from `usms-app-sg` and the new one from `usms-alb-sg`. Floci listed them as two separate permission entries, where real AWS would merge them into one. Screenshot 06 shows this group after the cutover.

### Step 10–11: Attach the service, and watch it register its own targets

This step needed the lab's fallback. `update-service --load-balancers ... --health-check-grace-period-seconds 60` returned successfully, but the result showed `"LB": null` and `"Grace": null`, and a fresh `describe-services` confirmed that neither had been stored. The target group stayed empty. The course's Known Issues page lists this exact problem for Lab 05.

Before using the destructive fallback, I tested it safely. I created a throwaway service, `usms-lbprobe-svc`, with zero tasks and the same `--load-balancers` document. `create-service` did keep the `loadBalancers` entry (but still not the grace period), so I deleted the throwaway and used the lab's fallback. I scaled `usms-enrolment-svc` to 0, deleted it, and recreated it with exactly the same name, cluster, task definition (`usms-enrolment:1`), desired count 2, both private subnets, `usms-enrolment-sg`, no public IP and the same `Lab=04` tags, plus the load balancer document. I saved the old service's settings to a file first so I could check that the copy matched.

![Service attached, targets registered by the service part a](<../../screenshots/Lab-05/04-service-attached-targets-registered_a.png>)
![Service attached, targets registered by the service part b](<../../screenshots/Lab-05/04-service-attached-targets-registered_b.png>)
*The recreated service is `ACTIVE`, Desired 2 / Running 2, still on `usms-enrolment:1`, with one `loadBalancers` entry naming `usms-enrolment-tg`, container `enrolment-api`, port `80`. `Grace` is `null` because Floci does not store it. The target group now holds two targets, both `healthy`, and I did not register either of them. The two tasks are `RUNNING`, and ECS reports no container health (`None`) because revision 1 has no container health check. That is the "UNKNOWN / healthy" row of the health table, which is not a fault.*

Two things here differ from the lab text. First, Floci really ran the health checks. A new target showed `initial` and then `healthy` about 30 seconds later, where the lab expected targets to stay `initial` forever on Floci. Second, the target addresses are `172.20.0.x`, not addresses in `10.0.3.0/24` and `10.0.4.0/24`. I checked with `docker inspect`: Floci runs each task as a real nginx container on its Docker network `floci-course_default` (172.20.0.0/16) and registers those addresses. It does not model task network interfaces inside the VPC's private subnets.

For "Your turn" I set the desired count to 3 and then back to 2. The target group went to three targets (`.3`, `.4`, `.5`) and back to two, without me running `register-targets` or `deregister-targets` once. Without that, every scaling event in Lab 06 would need someone to register the new task addresses by hand.

### Step 12: Prove the path, and be honest about which proof I got

I tried the real request first. The DNS name `usms-enrolment-alb-fbe5d91316b641cd.elb.floci` does not resolve, and `curl` cannot connect (`http_code=000`). While testing, I also sent a request to `localhost:4566` with the load balancer's name as the `Host` header and got a `200`. Reading the body showed it was Floci's S3 endpoint listing buckets, not the load balancer, so I did not count it as proof. I then ran the lab's control-plane proof.

![Data path attempt and five-block control-plane proof part a](<../../screenshots/Lab-05/05-path-proof-control-plane_a.png>)
![Data path attempt and five-block control-plane proof part b](<../../screenshots/Lab-05/05-path-proof-control-plane_b.png>)
![Data path attempt and five-block control-plane proof part c](<../../screenshots/Lab-05/05-path-proof-control-plane_c.png>)
*The data path is not available on this build. The five blocks still form one chain: (1) the listener is HTTP:80 and forwards to the target group, (2) the target group is `usms-enrolment-tg`, type `ip`, HTTP:80, health check `/`, in `vpc-6ffa2a93`, (3) it holds two targets, (4) the service `usms-enrolment-svc` put them there with `enrolment-api` on port 80, and (5) `usms-enrolment-sg` admits `sg-948367004bbccafb6`, which is `usms-alb-sg`. Block 3 flags the two `172.20.0.x` addresses as "NOT in a Lab 02 private subnet". That is the Floci Docker network explained above, not a wiring fault. At this point block 5 still listed `usms-app-sg` as well, because the cutover had not happened yet. The output is saved in `outputs/lab-05-path-proof.txt`.*

### Step 13 and 17: The cutover, and closing the loop

With the new path proven, I removed the direct rule from `usms-app-sg`. The lab's command, `revoke-security-group-ingress --security-group-rule-ids sgr-840e72f138e074a9f`, returned `True` but removed nothing: a fresh read still showed both sources. I revoked it again by restating the permission from Lab 04's own document, `policies/usms-enrolment-sg-ingress.json`, which worked. `describe-security-group-rules` still lists the old rule ID afterwards, which is another Floci quirk, but `describe-security-groups` (what both verification scripts read) is correct.

![Cutover confirmed and loop closed part a](<../../screenshots/Lab-05/06-cutover-confirmed_a.png>)
![Cutover confirmed and loop closed part b](<../../screenshots/Lab-05/06-cutover-confirmed_b.png>)
![Cutover confirmed and loop closed part c](<../../screenshots/Lab-05/06-cutover-confirmed_c.png>)
*`usms-enrolment-sg` now has exactly one source on port 80, `sg-948367004bbccafb6` (`usms-alb-sg`), with no `usms-app-sg` and no CIDR. The `diff` of Lab 04's verification shows exactly one check changing state, "usms-enrolment-sg is sourced from usms-app-sg (not a CIDR)", taking it from `PASS=38 FAIL=0` to `PASS=37 FAIL=1`. The Step 17 checks print `CUTOVER CONFIRMED` (the only thing that may open a connection to an enrolment task is `usms-alb-sg`) and `LOOP CLOSED` (`usms-web-01`, `i-378337720bc5f9d2e`, still carries `usms-app-sg` but now calls the load balancer's name).*

That one Lab 04 failure is expected. The script describes the architecture Lab 04 built, and that architecture has legitimately changed. I left it failing and documented it rather than rewriting Lab 04's history, and from this point `verify-lab-05.sh` is the script of record. The Step 17 tag audit also showed that `usms-alb-sg`, the load balancer and the target group all carry `Lab=05`.

### Step 14: Deploy behind the load balancer, and watch target states

I recorded the service and target list before and after `--force-new-deployment`, then polled both sides.

![Forced deployment and target state changes](<../../screenshots/Lab-05/07-deployment-and-target-states.png>)
*The pre and post files are identical: same task definition, same counts and the same two addresses, `172.20.0.3` and `172.20.0.5`. I separately confirmed that the running task IDs did not change either, so on Floci `--force-new-deployment` is a no-op. To still observe target states, I scaled out and in. A new target `172.20.0.4` appeared as `initial` and became `healthy` 30 seconds later, matching the 30-second interval and threshold of 2. On scale-in, a target was removed within 6 seconds with no `draining` state.*

So `initial` and `healthy` were observed, but `draining` was not. On real AWS, a deregistered target would stay `draining` for up to 30 seconds (the deregistration delay) while in-flight requests finish, and a forced deployment would replace every task, using the health check as a gate before old tasks drain. I could only reason about that part on this build.

### Step 15: A listener rule

I wrote the condition (`/alb-health` and `/alb-health/*`) and the action (`fixed-response` 200, `text/plain`) as JSON documents with quoted heredocs, and created the rule at priority 10. I used two patterns because `/alb-health*` would also match something like `/alb-healthcheck-internal`.

![Listener rule and decision table part a](<../../screenshots/Lab-05/08-listener-rule_a.png>)
![Listener rule and decision table part b](<../../screenshots/Lab-05/08-listener-rule_b.png>)
*`describe-rules` shows the full decision table in order: priority `10`, path-pattern `/alb-health`, `/alb-health/*`, action `fixed-response` with status `200` and no target group, then the `default` entry forwarding to `usms-enrolment-tg`. I could not test the rule with `curl` because the DNS name does not resolve, so the `describe-rules` output is the evidence.*

### Step 16: Prove the whole thing survives a restart

I recorded seven facts across ELBv2, ECS and EC2, stopped and started Floci, threw away my shell variables, re-derived every ARN from the API by name (and walked down from the load balancer to find the listener, since listeners have no name), and compared.

![Persistence proven across a Floci restart part a](<../../screenshots/Lab-05/09-persistence-proven_a.png>)
![Persistence proven across a Floci restart part b](<../../screenshots/Lab-05/09-persistence-proven_b.png>)
![Persistence proven across a Floci restart part c](<../../screenshots/Lab-05/09-persistence-proven_c.png>)
*All four re-derived ARNs match the originals, and the `diff` is empty: `PERSISTENCE PROVEN`. The load balancer (scheme, type, 2 AZs, 1 security group), the target group with its health check settings, the listener, the rule, the service's `loadBalancers` entry and both security groups including the Step 13 cutover are all unchanged.*

After the restart, Floci started two new tasks (new task IDs) that reused the same addresses. One target briefly showed `unhealthy` while its container came up and then turned `healthy` again, which is the health check doing its job.

### Step 18: Record everything in `configs/lab-05.env`

I wrote the env file with lookups rather than shell variables, so a populated value proves the resource exists. The lab's listener line escapes the JMESPath backticks as `` \` `` inside a nested `$(...)`, and on my shell that passed the backslashes through to JMESPath and left `USMS_ALB_LISTENER_ARN` empty. Inside `$(...)` the single quotes already protect plain backticks, so I used those instead.

![Lab 05 env file written and sourced part a](<../../screenshots/Lab-05/10-lab05-env-written_a.png>)
![Lab 05 env file written and sourced part b](<../../screenshots/Lab-05/10-lab05-env-written_b.png>)
*The file has 15 exports. The load balancer name, scheme, DNS name, security group, target group, target type `ip`, health path, listener ARN, container `enrolment-api` and port `80` all populate. The only `None` is the grace period, which is read back rather than hard-coded, so it honestly reports that Floci did not store it.*

### Section 8: Verification and cleanup scripts

I built `verify-lab-05.sh` from the lab with one change: the "no secret is tracked by git" check allows `outputs/.gitkeep`, the same fix I made in Lab 04, because my repo tracks that placeholder on purpose. I also built `scripts/cleanup/lab-05-cleanup.sh`. The lab text said to run it "AFTER lab-04-cleanup.sh and BEFORE lab-04-cleanup.sh". By the lab's own ordering table, the first of those is Lab 06's scaling cleanup, so I corrected the comments. I only checked it with `bash -n` and did not run it.

![Verification result and cleanup syntax check part a](<../../screenshots/Lab-05/11-verify-lab05_a.png>)
![Verification result and cleanup syntax check part b](<../../screenshots/Lab-05/11-verify-lab05_b.png>)
*`verify-lab-05.sh` reports `PASS=47 FAIL=2` out of the 49 checks. Both failures come from one Floci limitation. "healthCheckGracePeriodSeconds is set" fails because `describe-services` returns `None`, and the lab lists this as a known benign failure. "configs/lab-05.env has no empty values" fails because that same `None` is in the env file. Every other check passes, including the cutover, both AZs, target type `ip`, the fixed-response rule, exactly one deployment and Git hygiene. The cleanup script parses: `syntax OK - do NOT run it`.*

### Step 19: Commit

I checked that `outputs/` was protected, staged every Lab 05 file by explicit path, and committed.

![Lab 05 committed part a](<../../screenshots/Lab-05/12-commit-proof_a.png>)
![Lab 05 committed part b](<../../screenshots/Lab-05/12-commit-proof_b.png>)
*`git check-ignore -v` names the rule `.gitignore:8:outputs/*` for `outputs/lab-05-path-proof.txt`, and `git ls-files outputs/` lists only `outputs/.gitkeep`. The staged files are the env file, the notes, three security group documents, four templates, both Lab 05 scripts and the `verify-lab-03.sh` path fix, and nothing under `outputs/`. The commit is `c7bd913`, with 12 files, sitting on top of the Lab 03 and Lab 04 commits.*

## 6. Results and Evidence

### 6.1 CLI/SDK Output

Everything was built and checked through the AWS CLI against Floci. The final state against the lab's checkpoints:

| Checkpoint | What had to be true | Result |
|---|---|---|
| 1 (Step 3) | Earlier labs pass, two public subnets in two AZs, support path recorded | Lab 2 `33/0`, Lab 3 `36/0`, Lab 4 `38/0`; `us-east-1a` + `us-east-1b`; path B recorded (screenshot 01) |
| 2 (Step 5) | ALB active, internet-facing, application, two AZs, `usms-alb-sg` | All true (screenshot 02) |
| 3 (Step 8) | Target group `ip`, health check `/` every 30 s, matcher 200, delay 30; listener forwards; 1 attached LB | All true (screenshot 03) |
| 4 (Step 11) | One `loadBalancers` entry, 60 s grace, unchanged task definition, two targets registered by the service | Entry present, task definition unchanged, two targets `healthy`; grace not stored by Floci; addresses on Floci's Docker network (screenshot 04) |
| 5 (Step 14) | Forced deployment with `initial`, `healthy` and `draining` seen | `initial` and `healthy` seen; forced deployment is a no-op and `draining` never appears on Floci (screenshot 07) |
| 6 (Step 15) | Priority-10 `fixed-response` rule above the default | True (screenshot 08) |
| 7 (Step 16) | `PERSISTENCE PROVEN` with every ARN re-derived | True (screenshot 09) |
| 8 (Step 19) | 15 exports, committed, nothing from `outputs/` staged | 15 exports, commit `c7bd913` (screenshots 10 and 12) |

The consolidated proof is `verify-lab-05.sh` at `PASS=47 FAIL=2`, with both failures explained by the grace period not being stored (screenshot 11).

### 6.2 AWS Console Verification

Floci has no AWS Management Console, so there is no console screenshot. Everything the EC2 console's load balancer, target group and listener pages would show (state, scheme, zones, security groups, health check settings, registered targets and their health, the rules table) was read directly from the `describe-*` calls in the screenshots above, which is what the console does behind the scenes.

## 7. Analysis and Discussion

**What I observed and what I could only reason about.** I observed every object being created and read back, the target group going from 0 to 1 attached load balancer, the service registering and deregistering its own targets as the count changed, real health checks moving targets from `initial` to `healthy`, the rule ordering, the cutover, and the restart proof. I could only reason about a client request travelling through the listener, the rule actually being evaluated, connection draining during a deployment, security groups dropping packets, and HTTPS.

**Floci limitations I hit, with what real AWS does:**

- **`update-service` drops the load balancer attachment.** On real AWS, `update-service --load-balancers` attaches the target group in place for a rolling deployment. Here it was accepted and discarded, so I used the lab's recreate fallback, after first proving on a throwaway service that `create-service` keeps the entry.
- **The grace period is never stored.** On real AWS, ECS would ignore target health for each task's first 60 seconds, so a slow-starting task is not marked unhealthy and replaced in a loop. Here it reads back as `None` on both `update-service` and `create-service`. That is the reason for both verification failures.
- **Targets are Docker addresses, not task ENIs.** Real targets would be the task network interfaces in `10.0.3.0/24` and `10.0.4.0/24`, one per Availability Zone. Floci registers the containers' `172.20.0.x` addresses and reports no Availability Zone.
- **No client data path.** Real AWS publishes a DNS name that resolves to one node per AZ. Floci's `*.elb.floci` name does not resolve, so `curl`, the `/alb-health` rule and the idle timeout could not be exercised.
- **Forced deployments and draining are not modelled.** On real AWS, every task would be replaced, new targets would pass the health check before receiving traffic, and old ones would stay `draining` for up to 30 seconds. Here the forced deployment did nothing, and scale-in removed a target immediately.
- **Revoking by rule ID does nothing.** `--security-group-rule-ids` returned `True` without removing the rule, and the rule-ID index keeps revoked rules. Real AWS removes the rule.
- **`length(deployments)` sometimes errors on `null`.** Real ECS always returns a list.
- **Security groups are not enforced.** I proved the rules are correct, but nothing here drops a packet that breaks them. That is why the verification script asserts the Step 9 rule instead of testing it.

**Problems that were mine to untangle, not Floci's:**

- **The Lab 03 verify path.** My own folder rename in commit `e5f4a71` broke a check in `verify-lab-03.sh`. A one-line path fix brought it back to `FAIL=0`.
- **The env file listener line.** The lab's backslash-escaped backticks left the variable empty in my shell. The empty-value check caught it straight away, which is exactly what that check is for.
- **A false failure in the verify script.** The "no secret is tracked" check would fail on `outputs/.gitkeep`, so I made the same fix as in Lab 04 rather than untracking the file.
- **Mismatches with the lab text.** The lab assumes a newer Lab 04 than mine: task definition revision 2 with a container health check, and a Lab 04 verify count of 49. My Lab 04 has revision 1 and 38 checks, so my before/after counts were `38/0` to `37/1` instead of `49/0` to `48/1`. The one-check change is the same.

**Why the order of Steps 9, 12 and 13 matters.** The new path was built and proven before the old one was removed, so at no point was there no path to the tasks. On a real system, anything still calling the tasks by address would break at Step 13, which is why you prove the replacement first.

## 8. Reflection

The idea that stuck with me most is that the target group is not mine to fill. When the target group was empty after Step 10, the obvious move would have been `register-targets`. Instead I checked what the service actually stored, found the `loadBalancers` entry missing, and fixed the attachment. Once the service owned the target group, scaling from 2 to 3 and back added and removed targets with no help from me. That is what will make Lab 06's auto scaling work.

I also learned to test a destructive fallback before running it. Deleting the service felt risky, so I tried `create-service` on a throwaway service with zero tasks first. That told me the recreate would actually keep the attachment before I deleted anything real.

The Step 12 `200` was a good reminder to read the body of a response, not just the status code. A `200` from port 4566 looked like the load balancer working, but it was S3 answering. Claiming it would have been exactly the kind of invented observation the lab warns about. As in the previous labs, several results only made sense because I read the output back instead of trusting the exit code: the revoke that returned `True` without removing anything, the `null` grace period, and the empty listener ARN.

## 9. Conclusion

The USMS enrolment service now sits behind `usms-enrolment-alb`, an internet-facing Application Load Balancer in both public subnets with its own security group. It has an HTTP:80 listener forwarding to `usms-enrolment-tg`, a target group of type `ip` whose contents are managed by the ECS service, and a priority-10 `/alb-health` rule. After the cutover, the only thing that can open a connection to an enrolment task is the load balancer's security group, and the tasks still have no public address. The whole stack survived a Floci restart unchanged, every ARN is in `configs/lab-05.env` for Lab 06, the verification script passes 47 of 49 checks with both failures traced to one documented Floci limitation, the cleanup script is built but not run, and the work is committed as `c7bd913`. Lab 06 will hand this service's desired count to Application Auto Scaling, and the target group built here is what makes a requests-per-target scaling policy possible.

## 10. Appendix

**Key resource identifiers from this lab:**

| Resource | Value |
|---|---|
| Load balancer security group | `usms-alb-sg` = `sg-948367004bbccafb6` (tcp/80 and tcp/443 from `0.0.0.0/0`) |
| Load balancer | `usms-enrolment-alb` (`arn:aws:elasticloadbalancing:us-east-1:000000000000:loadbalancer/app/usms-enrolment-alb/fbe5d91316b641cd`) |
| DNS name (Floci) | `usms-enrolment-alb-fbe5d91316b641cd.elb.floci` |
| Target group | `usms-enrolment-tg` (`arn:aws:elasticloadbalancing:us-east-1:000000000000:targetgroup/usms-enrolment-tg/7d4bb562e9aa48c7`) |
| Listener | HTTP:80 (`.../listener/app/usms-enrolment-alb/fbe5d91316b641cd/0f7e0085e5b74e85`) |
| Listener rule | priority 10, `/alb-health` -> fixed-response 200 (`.../229322f310fe4ef9`) |
| Public subnets | `subnet-c9b01466` (us-east-1a), `subnet-92f551f3` (us-east-1b) |
| Enrolment security group | `usms-enrolment-sg` = `sg-ed703590b42f25128`, tcp/80 from `usms-alb-sg` only |
| Removed source | `usms-app-sg` = `sg-39a66c2dc43f3eef3` (Step 13) |
| Service | `usms-enrolment-svc`, recreated with `loadBalancers` = `usms-enrolment-tg` / `enrolment-api` / 80 |
| Task definition | `usms-enrolment:1` (unchanged) |
| Commit | `c7bd913` |

**Files produced for this lab:**
- `policies/usms-alb-sg-ingress.json`: the load balancer's tcp/80 rule.
- `policies/usms-alb-sg-ingress-https.json`: the "Your turn" tcp/443 rule.
- `policies/usms-enrolment-sg-ingress-alb.json`: the tasks' new rule, sourced from `usms-alb-sg`.
- `templates/lab-05-listener-default-actions.json`, `templates/lab-05-rule-conditions.json`, `templates/lab-05-rule-actions.json`, `templates/lab-05-service-load-balancers.json`: request bodies.
- `configs/lab-05.env`: 15 exports for Lab 06.
- `notes/lab-05-notes.md`: support path, "Your turn" answers, the health table, benign failures and limitations.
- `scripts/utilities/verify-lab-05.sh`: automated check (47/49, two documented benign failures).
- `scripts/cleanup/lab-05-cleanup.sh`: end-of-course teardown, syntax-checked only and never run.
- `outputs/lab-05-*.txt`: evidence files (git-ignored).
