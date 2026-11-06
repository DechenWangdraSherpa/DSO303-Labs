# Lab 05 notes

**Support path: B (control plane only), with one extra.** Every ELBv2 call answered in the Step 3 probe and every object was created and describable. Floci 1.7.0 also *ran target health checks* (targets went `initial` -> `healthy` about 30 s after registration, and briefly `unhealthy` while a container restarted). But there is no client data path: the DNS name `usms-enrolment-alb-fbe5d91316b641cd.elb.floci` does not resolve and `curl` cannot connect. Requests through the listener, rule evaluation, draining and HTTPS were reasoned about, not observed.

## Deviations from the lab text, and why

- **Step 10 took the fallback.** `update-service --load-balancers ... --health-check-grace-period-seconds 60` returned success but `describe-services` showed `loadBalancers: null` and `healthCheckGracePeriodSeconds: null` (Known Issues - Lab 05). A throwaway zero-task service proved `create-service` *does* keep `loadBalancers`, so `usms-enrolment-svc` was deleted and recreated with the same name, cluster, task definition (`usms-enrolment:1`), desired count 2, subnets, security group and `Lab=04` tags. The grace period is still not stored.
- **Task definition is `usms-enrolment:1`, not `:2`.** My Lab 04 never registered revision 2; no new revision was registered here either.
- **Step 13 revoke.** `revoke-security-group-ingress --security-group-rule-ids sgr-840e72f138e074a9f` returned `True` but removed nothing. Revoking by restating the permission from `policies/usms-enrolment-sg-ingress.json` (Lab 04's own document) worked. `describe-security-group-rules` still lists the old rule ID afterwards; `describe-security-groups` (what both verify scripts read) is correct.
- **Step 18 listener line.** The lab's `\`80\`` escaping inside `$(...)` in the heredoc reached JMESPath with the backslashes and left `USMS_ALB_LISTENER_ARN` empty. Plain backticks inside the single-quoted query work.
- **verify-lab-03.sh** checked `labs/lab-03-ec2/user-data.sh`, but commit e5f4a71 renamed the folder to `lab-03-EC2`. Path fixed so Checkpoint 1 is `FAIL=0`.
- **verify-lab-05.sh** "no secret is tracked by git" allows `outputs/.gitkeep`, the same fix as Lab 04.
- **lab-05-cleanup.sh** comments said "AFTER lab-04-cleanup.sh and BEFORE lab-04-cleanup.sh"; the first is Lab 06's scaling cleanup. Fixed. The script was only `bash -n` checked, never run.

## verify-lab-05.sh: PASS=47 FAIL=2, both benign

| Failing check | Cause |
|---|---|
| `healthCheckGracePeriodSeconds is set` | Listed in Section 8 as benign: Floci accepts `--health-check-grace-period-seconds 60` on both `update-service` and `create-service` and does not store it (`describe-services` -> `None`). |
| `configs/lab-05.env has no empty values` | Consequence of the same fact: `USMS_SVC_GRACE_PERIOD` is read back, not hard-coded, so it is honestly `None`. |

`verify-lab-04.sh` went from `PASS=38 FAIL=0` to `PASS=37 FAIL=1` after Step 13, the one expected failure: `usms-enrolment-sg is sourced from usms-app-sg (not a CIDR)`. Left failing and documented (Exercise 2 is the proper fix).

## Your turn - Step 4 (tcp/443 on usms-alb-sg)

Added from `policies/usms-alb-sg-ingress-https.json`; the group now admits 80 and 443 from `0.0.0.0/0`. The load balancer still will not serve one HTTPS request because two things are missing: an **HTTPS listener on port 443** (the security group only opens the port, nothing listens on it) and a **TLS certificate** for that listener. AWS Certificate Manager issues a public certificate for free, but you must own a domain name and prove it with a DNS record, and the domain has to come from outside AWS (a registrar) unless it is registered through Route 53.

## Your turn - Step 6 (matcher)

Matcher went `200` -> `200-399` -> `200` with `modify-target-group`; both changes took effect immediately and nothing was recreated.
(a) Any app whose `/` redirects to a login page (for example `302` to `/login`) would be reported unhealthy forever with a strict `200` matcher.
(b) It would be a bug in my work, not the script: a verification script records the configuration the lab specified, so a mismatch means the build drifted from the specification, even if the drifted value would also have worked.

## Your turn - Step 11 (desired count 3 then 2)

`describe-target-health` showed three targets (`172.20.0.3`, `.4`, `.5`) and then two, and I never ran `register-targets` or `deregister-targets`. Without self-registration I would have had to register every new task's IP address (and deregister every stopped one) by hand after every single scaling event.

## Step 11 part 3 - two health opinions, side by side

| ECS `healthStatus` | Target health | Diagnosis |
|---|---|---|
| `HEALTHY` | `healthy` | Working |
| `HEALTHY` | `unhealthy` | The network path is broken: security group, subnet, or the health check path returning the wrong code |
| `UNHEALTHY` | `unhealthy` | The application is broken. Read the container logs |
| `UNKNOWN` | `healthy` | Not a fault. The task definition has no container health check |
| anything | `unused` | Nothing forwards to this target group |

Observed on my build: ECS `healthStatus` `None` (revision 1 has no container health check) with target `healthy` - the `UNKNOWN` / `healthy` row.

## Floci limitations hit (and what real AWS does)

| Limitation on Floci 1.7.0 | Real AWS |
|---|---|
| `update-service` drops `loadBalancers` and grace period; `create-service` keeps `loadBalancers` but drops the grace period | Both stored; ECS ignores target health for the grace period |
| Target addresses are Docker IPs `172.20.0.x` on `floci-course_default`, not task ENIs in `10.0.3.0/24` / `10.0.4.0/24` | Targets are the task ENI addresses inside the private subnets |
| DNS name `*.elb.floci` does not resolve; no data path on 4566 (a `200` on 4566 with the ALB Host header was S3 `ListBuckets`, not the ALB) | Public DNS name resolving to one node per AZ |
| `--force-new-deployment` is a no-op: same task IDs, same targets, one deployment | Every task replaced: new target `initial` -> `healthy`, old one `draining` for the deregistration delay |
| Scale-in removes a target immediately: no `draining` state, no 30 s delay | Target stays `draining` for up to `deregistration_delay.timeout_seconds` |
| `revoke ... --security-group-rule-ids` returns `True` but removes nothing; rule-ID index keeps revoked rules | Rule removed |
| `length(deployments)` intermittently errors on `null` | Always a list |
| Security groups, rule evaluation, `fixed-response` and idle timeout stored, never enforced | Enforced on every request |
| After a Floci restart, the service starts new tasks (new task IDs) on the same addresses | Tasks keep running |
