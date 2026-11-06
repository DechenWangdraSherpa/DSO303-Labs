# Lab 6 – Auto Scaling the USMS Enrolment Service on Amazon ECS

**Name:** Dechen Wangdra Sherpa
**Student Number:** 02230281
**Course:** DSO303 – Cloud Native Design Patterns
**Lab:** Lab 6 – Application Auto Scaling for an ECS service

---

## 1. Aim / Objective

The aim of this lab was to hand the enrolment service's `desiredCount` to Application Auto Scaling. By the end I needed the service registered as a scalable target (minimum 2, maximum 10), two target tracking policies (CPU at 50 per cent and `ALBRequestCountPerTarget` at 1000), a step scaling policy driven by a CloudWatch alarm I wrote myself on a custom metric, and two scheduled actions for the enrolment morning and evening. I then had to fire the alarm and prove that something other than me moved `desiredCount`, suspend and resume scaling, prove the whole configuration survives a restart, and record every name in `configs/lab-06.env`.

## 2. Introduction

In Lab 04 the enrolment service ran at a fixed `desiredCount` of 2, and in Lab 05 I put a load balancer in front of it. The count still only changed when I typed `update-service`. Application Auto Scaling changes that, but it is worth being precise about how little it does: **it writes one integer**. ECS, the target group and the load balancer built in the earlier labs do everything after that.

The pieces fit together like this:

- **Scalable target:** a registration saying "this dimension of this resource may move between these two numbers". Its address is three strings, not an ARN: namespace `ecs`, resource ID `service/usms-ecs-cluster/usms-enrolment-svc`, and dimension `ecs:service:DesiredCount`.
- **Target tracking policy:** one metric and one target value. It creates two CloudWatch alarms for me (high and low) and computes a capacity.
- **Step scaling policy:** a piecewise response ("+1 at this backlog, +3 at that one") driven by an alarm I own.
- **Scheduled action:** changes the floor and ceiling at a time. It is the only form of scaling that can be early.
- **Suspended state:** three switches on the target that stop scaling without deleting anything.

Every reactive decision comes from a CloudWatch alarm, so reactive scaling is always late: a metric has to be published, an alarm has to evaluate it, and a new task has to start and pass its health check. That is why the minimum capacity, the asymmetric cooldowns and the scheduled actions in this lab exist.

As in the earlier labs, everything was done with the AWS CLI against Floci. This lab touches the least complete part of Floci so far. The objects can be created and read back, but the loop that connects an alarm to a change in `desiredCount` does not run, and scheduled actions are not supported at all. I have kept those results in and said which things I actually observed.

## 3. Use Case

Enrolment traffic is not flat. When a new cohort becomes eligible, the portal gets a sharp spike in the first minutes, and for the rest of enrolment week traffic stays above normal. A fixed count of 2 either wastes money all year or falls over on enrolment day. With auto scaling, the service keeps a floor of two tasks (one per Availability Zone) to absorb the start of any spike, grows on request rate or CPU when traffic climbs, adds tasks quickly if the enrolment work queue backs up, and raises its floor before enrolment opens each morning so capacity is ready rather than late. The ceiling of 10 stops a misbehaving policy from scaling without limit.

## 4. System Architecture / Design

Everything from Labs 02 to 05 is unchanged. This lab adds a control loop on top that writes one number:

```
  Internet -> usms-enrolment-alb -> usms-enrolment-tg -> tasks in private subnets a + b
                                                              ^
                       ECS starts and stops tasks to match    |
  usms-ecs-cluster / usms-enrolment-svc   desiredCount  <-----+------- writes ONE integer
                                                                       |
  Application Auto Scaling                                             |
    scalable target  service/usms-ecs-cluster/usms-enrolment-svc       |
                     ecs:service:DesiredCount   min 2   max 10  -------+
      usms-enrolment-cpu-target-tracking       CPU -> 50.0
        + TargetTracking-...-AlarmHigh / AlarmLow    (created FOR me)
      usms-enrolment-requests-target-tracking  ALBRequestCountPerTarget -> 1000.0
        ResourceLabel app/usms-enrolment-alb/<id>/targetgroup/usms-enrolment-tg/<id>
        + TargetTracking-...-AlarmHigh / AlarmLow    (created FOR me)
      usms-enrolment-queue-step-out            StepScaling, +1 at 100-200, +3 at 200+
        driven by usms-enrolment-queue-high    (an alarm I wrote)
          USMS/Enrolment EnrolmentQueueDepth >= 100 -> AlarmActions = the policy ARN
      scheduled: morning floor 4 / evening floor 2   (rejected by this Floci build)
      suspended state: DynamicScalingIn / DynamicScalingOut / ScheduledScaling

  Identity: a service-linked role holds ecs:UpdateService on my behalf
```

The key design choices were:

- **A floor of 2 is a latency decision, not a cost decision.** One task per Availability Zone absorbs the first minutes of a spike while the reactive policies catch up.
- **Scale out eagerly, scale in reluctantly.** `ScaleOutCooldown` is 60 seconds and `ScaleInCooldown` is 300 seconds.
- **Two target tracking policies on different metrics.** When they disagree, the largest requested capacity wins on scale-out, and scale-in happens only when every policy agrees. A second policy on a different metric can therefore only make the service larger.
- **Step scaling for the queue.** "Add one task at a backlog of 100, three at 200" has no set point, so target tracking cannot express it. Because I own that alarm, it is also the one I can fire deliberately to test the chain.

## 5. Implementation Procedure

### Step 1–3: Resume, check the earlier labs, and probe what Floci supports

I loaded the six env files and printed the values this lab depends on, re-ran the verification scripts from Labs 02 to 05 (saving Lab 05's output as a "before" to compare with at the end), confirmed the service was at its baseline, and probed which Application Auto Scaling and CloudWatch calls this Floci build answers.

![Prerequisites and Application Auto Scaling support probe part a](<../../screenshots/Lab-06/01-environment-and-support-path_a.png>)
![Prerequisites and Application Auto Scaling support probe part b](<../../screenshots/Lab-06/01-environment-and-support-path_b.png>)
*Lab 02 and Lab 03 pass (`PASS=33`, `PASS=36`). Lab 04 shows its one expected failure from the Lab 05 cutover, and Lab 05 shows its two documented grace-period failures. The guide accepts both as documented. The service is at the baseline: Desired 2, Running 2, one deployment, one load balancer. The probe shows scalable targets, scaling policies, CloudWatch alarms and metrics and the service-linked role all answer, but `describe-scheduled-actions` and `describe-scaling-activities` do not.*

Running those two calls directly returned `UnsupportedOperation`. My Lab 04 notes had already recorded the same gap. I recorded **support path B (control plane only)** at the top of `notes/lab-06-notes.md`.

### Step 4–6: The service-linked role and the scalable target

I created the service-linked role, built the resource ID from the service's own ARN (everything after the last colon, checked for three segments starting with `service`), and registered the scalable target with a minimum of 2 and a maximum of 10. Then I raised the ceiling to 12 with only `--max-capacity`, read it back, and put it back, to see how re-registration works.

![Service-linked role and scalable target registered part a](<../../screenshots/Lab-06/02-scalable-target-registered_a.png>)
![Service-linked role and scalable target registered part b](<../../screenshots/Lab-06/02-scalable-target-registered_b.png>)
![Service-linked role and scalable target registered part c](<../../screenshots/Lab-06/02-scalable-target-registered_c.png>)
*The resource ID derived from the ARN is `service/usms-ecs-cluster/usms-enrolment-svc` (3 segments, first `service`). The target is registered in namespace `ecs` with dimension `ecs:service:DesiredCount`, min 2, max 10, all three suspension switches `false`, and a `RoleARN` filled in although I passed none. Registering did not change the service (Desired 2). Passing only `--max-capacity 12` left the minimum at 2 (`2 12`), the bounds went back to `2..10`, and there is exactly one scalable target.*

One Floci mismatch shows here. `create-service-linked-role` created a role called `AWSServiceRoleForEcsApplicationAutoscaling`, but the target's `RoleARN` names `AWSServiceRoleForApplicationAutoScaling_ECSService`, and `get-role` cannot find that one. On real AWS they are the same role. Floci does not assume either, so nothing failed because of it.

For "Your turn" I re-registered with `--min-capacity 5` while two tasks were running. On real AWS the target enforces its own floor, so `desiredCount` would jump to 5 within seconds with no policy involved. On Floci the target stored `5 10`, but `desiredCount` stayed at 2. I put the bounds back to `2 10`. The object that would have made that change is the scalable target itself, and `describe-scalable-targets` is the call that would show someone had left the floor raised.

### Step 7–9: Two target tracking policies, and the alarms they create

I wrote the CPU policy configuration (target 50, out 60, in 300) with a quoted heredoc, because it has no variables, and created the policy. Then I read the two alarms that appeared as a side effect. For the request-count policy, I built the `ResourceLabel` from the two Lab 05 ARNs (everything after `:loadbalancer/`, then everything after the target group ARN's last colon), validated it, and wrote it into the second configuration with an unquoted heredoc.

![CPU and request-count target tracking policies with their managed alarms part a](<../../screenshots/Lab-06/03-target-tracking-policies_a.png>)
![CPU and request-count target tracking policies with their managed alarms part b](<../../screenshots/Lab-06/03-target-tracking-policies_b.png>)
![CPU and request-count target tracking policies with their managed alarms part c](<../../screenshots/Lab-06/03-target-tracking-policies_c.png>)
![CPU and request-count target tracking policies with their managed alarms part d](<../../screenshots/Lab-06/03-target-tracking-policies_d.png>)
![CPU and request-count target tracking policies with their managed alarms part e](<../../screenshots/Lab-06/03-target-tracking-policies_e.png>)
*The CPU policy was created, and two alarms I did not write appeared: `AlarmHigh` (period 60, 3 evaluations, `GreaterThanThreshold` 50) and `AlarmLow` (period 60, 15 evaluations, `LessThanThreshold`), both `INSUFFICIENT_DATA`. The `ResourceLabel` is `app/usms-enrolment-alb/fbe5d91316b641cd/targetgroup/usms-enrolment-tg/7d4bb562e9aa48c7`, validated as 6 segments with `app` first and `targetgroup` fourth. Both JSON documents are valid with no unexpanded `$`. The final table shows both policies with targets 50.0 and 1000.0, out 60, in 300 and 2 alarms each, and there are 4 managed alarms in total.*

I also checked each managed alarm's action. The CPU alarms invoke the CPU policy's ARN and the request alarms invoke the request policy's ARN, so each policy owns its own pair. The evaluation windows match real AWS: 3 minutes to scale out and 15 to scale in. Two details are Floci's own:
- **Metric names:** the alarms use `ECSServiceAverageCPUUtilization` and `ALBRequestCountPerTarget` in `AWS/ECS`. Real AWS would use `CPUUtilization` in `AWS/ECS` and `RequestCountPerTarget` in `AWS/ApplicationELB`.
- **No dead band:** the low alarm's threshold equals the target (50) instead of sitting slightly below it, so the dead band that stops oscillation on real AWS is missing.

For the Step 8 "Your turn", the time at 100 per cent CPU before a third task serves traffic is about **5 minutes** in the worst case. It adds up four delays:
1. **Alarm evaluation:** 60 s × 3 = 180 s.
2. **Policy invocation:** about 0 s.
3. **Fargate start-up:** 20 to 60 s, the figure AWS documents.
4. **Grace period:** 60 s.

All of that is served by the two tasks I already had.

### Step 10–11: A step scaling policy with its own alarm, and scheduled actions

I published the custom metric `USMS/Enrolment EnrolmentQueueDepth` (a few small values so it exists), wrote the step table, created the step policy first, and then created the alarm `usms-enrolment-queue-high` with the policy's ARN as its action. The order matters, because the alarm needs the ARN.

![Step scaling policy, its alarm, and the scheduled actions part a](<../../screenshots/Lab-06/04-step-policy-alarm-and-schedules_a.png>)
![Step scaling policy, its alarm, and the scheduled actions part b](<../../screenshots/Lab-06/04-step-policy-alarm-and-schedules_b.png>)
![Step scaling policy, its alarm, and the scheduled actions part c](<../../screenshots/Lab-06/04-step-policy-alarm-and-schedules_c.png>)
![Step scaling policy, its alarm, and the scheduled actions part d](<../../screenshots/Lab-06/04-step-policy-alarm-and-schedules_d.png>)
![Step scaling policy, its alarm, and the scheduled actions part e](<../../screenshots/Lab-06/04-step-policy-alarm-and-schedules_e.png>)
![Step scaling policy, its alarm, and the scheduled actions part f](<../../screenshots/Lab-06/04-step-policy-alarm-and-schedules_f.png>)
*`list-metrics` shows `EnrolmentQueueDepth` with dimension `Service=enrolment`. The step policy is `StepScaling`, `ChangeInCapacity`, cooldown 60, with two steps: `0..100 → +1` and `100.. → +3`, with no upper bound on the top step. The alarm watches `USMS/Enrolment EnrolmentQueueDepth`, `Average`, period 60, 1 evaluation, `>= 100`, and its `AlarmActions` is exactly the step policy's ARN. Floci did not store `TreatMissingData` (`null`) and leaves the policy's own `Alarms` list empty. Both `put-scheduled-action` calls, with `--timezone Asia/Thimphu` and with the UTC fallback, failed with `UnsupportedOperation`.*

I also tried the evening action and the Step 11 "Your turn" one-off `at()` action. Both were rejected the same way, so no scheduled action exists and there was nothing to delete. On real AWS the morning action would raise the floor to 4 at 07:45 Thimphu time on weekdays and the evening action would lower it to 2 at 20:00. They move the bounds, never the count directly.

### Step 12: Fire the alarm, and prove the chain

I recorded the starting state, pushed the queue metric to 260 three times against a threshold of 100, and read the datapoints back. A breach of 160 falls in the open-ended second step, so the prediction was +3, taking the count from 2 to 5. Then I watched whether the alarm fired on its own, forced it with `set-alarm-state` when it did not, and polled `desiredCount`.

![Metric pushed past the threshold and alarm forced to ALARM part a](<../../screenshots/Lab-06/05-alarm-fired-and-scaling-proof_a.png>)
![Metric pushed past the threshold and alarm forced to ALARM part b](<../../screenshots/Lab-06/05-alarm-fired-and-scaling-proof_b.png>)
![Metric pushed past the threshold and alarm forced to ALARM part c](<../../screenshots/Lab-06/05-alarm-fired-and-scaling-proof_c.png>)
*The starting state was `2 2 0`, and `get-metric-statistics` shows the metric at 260 (average and maximum) in the latest minute. The alarm never evaluated on its own: six polls over 90 seconds all show `INSUFFICIENT_DATA` with reason "Unchecked". `set-alarm-state ALARM` was accepted, but `desiredCount` stayed at 2 across six polls, and `describe-scaling-activities` returned `UnsupportedOperation`. The scaling loop does not run on this build.*

Because the number did not move, I used the lab's six-block control-plane proof. Each block names the next, so together they prove the wiring that real AWS would use.

![Six-block scaling proof and return to baseline part a](<../../screenshots/Lab-06/06-scaling-chain-proof_a.png>)
![Six-block scaling proof and return to baseline part b](<../../screenshots/Lab-06/06-scaling-chain-proof_b.png>)
*(1) The alarm watches `USMS/Enrolment EnrolmentQueueDepth >= 100` and is now in `ALARM`. (2) Its action is the step policy's ARN. (3) That ARN belongs to `usms-enrolment-queue-step-out` on `service/usms-ecs-cluster/usms-enrolment-svc`, `ecs:service:DesiredCount`. (4) A breach of 160 selects `+3`. (5) The bounds are `2 10`, which would allow 5. (6) The desired count is still `2`. Then I returned to the baseline in the guide's order: alarm back to `OK`, metric pushed down to 4, 3, 2 first, and only then the count set to 2. The pre and post files both read `2 2 0`.*

The chain holds from end to end, and the one link Floci does not connect is the alarm actually invoking the policy. On real AWS the next step would have been a scaling activity with a `Cause` naming both `usms-enrolment-queue-high` and `usms-enrolment-queue-step-out`, `desiredCount` going to 5, and three pending tasks that would not count as capacity for another minute because of the grace period.

### Step 13: Suspend and resume scaling

I wrote the suspended state to `templates/lab-06-suspended-state.json` (scale-in suspended, the other two not), applied it by re-registering the target, checked that the policies and alarms were untouched, then resumed with the shorthand form and proved no switch was left on.

![Scale-in suspended, policies untouched, then resumed part a](<../../screenshots/Lab-06/07-suspend-and-resume_a.png>)
![Scale-in suspended, policies untouched, then resumed part b](<../../screenshots/Lab-06/07-suspend-and-resume_b.png>)
*While suspended, the target showed min 2, max 10 and `DynamicScalingInSuspended: true` with the other two `false`. All three policies were still listed and the 4 managed alarms were unchanged, so suspension removes nothing. After resuming, all three switches are `false`, `SuspendedState.*` prints `False False False`, and `grep -ci true` returns `0`.*

Floci stores the suspension but, since the loop does not run, it never actually prevents anything. On real AWS, a target left with `DynamicScalingOutSuspended: true` would silently fail to scale out in the next incident, which is why the verification script asserts all three are `false`.

### Step 14: Prove the configuration survives a restart

I recorded the scalable target, its suspension switches, the three policies, the CPU policy's configuration, the step policy's configuration and the custom alarm. Then I stopped and started Floci, threw away my shell variables, and re-derived everything from the API: the resource ID from the service ARN, the dimension from the target, the step policy by its type, the CPU policy by a name fragment, and the alarm by prefix.

![Scaling configuration proven to survive a Floci restart part a](<../../screenshots/Lab-06/08-persistence-proven_a.png>)
![Scaling configuration proven to survive a Floci restart part b](<../../screenshots/Lab-06/08-persistence-proven_b.png>)
![Scaling configuration proven to survive a Floci restart part c](<../../screenshots/Lab-06/08-persistence-proven_c.png>)
*Every identifier was re-derived (resource ID, dimension, CPU policy, step policy, queue alarm), and the `diff` of the before and after files is empty: `PERSISTENCE PROVEN`.*

I left two facts out of the guide's comparison because Floci never stored them: the scheduled actions (rejected in Step 11) and `TreatMissingData` (`null`). The success message lists only what was compared. As in Lab 05, the restart stopped `usms-web-01` and restarted the ECS tasks; I started the instance again, and the service came back at 2 tasks.

Step 15's trace from a student's click to a new task is saved in `outputs/lab-06-close-the-loop.txt` and written out as nine lines in my notes. Only three of the nine lines belong to this lab: the alarm, the policy and the one integer. The task definition is still `usms-enrolment:1`, with one load balancer entry and one deployment, so this lab changed nothing in Labs 04 and 05.

### Step 16: Record everything in `configs/lab-06.env`

I wrote the env file from the guide's block, which looks every value up from the API. The guide's resource ID line escapes awk's field as `\$NF` inside a `$(...)` in the heredoc. In my shell that passed the backslash through to awk and left `USMS_SCALABLE_RESOURCE_ID` empty, which the empty-value check caught immediately. Inside `$(...)` the single quotes already protect a plain `$NF`, so I used that. It is the same trap as the listener line in Lab 05.

![Lab 06 env file written and sourced part a](<../../screenshots/Lab-06/09-lab06-env-written_a.png>)
![Lab 06 env file written and sourced part b](<../../screenshots/Lab-06/09-lab06-env-written_b.png>)
![Lab 06 env file written and sourced part c](<../../screenshots/Lab-06/09-lab06-env-written_c.png>)
*`all values populated` and 22 exports. The resource ID, dimension, bounds `2 .. 10`, all three policy ARNs, the alarm, the custom metric, the scheduled action names and the service-linked role name are filled in, and the resource ID matches what the API returns right now.*

The two scheduled action names are recorded as names only, because those actions could not be created on this build.

### Section 8: Verification and cleanup scripts

I built `verify-lab-06.sh` from the lab, with the same one change as Labs 04 and 05: the "no secret is tracked" check allows `outputs/.gitkeep`. I also built `scripts/cleanup/lab-06-cleanup.sh` and only checked it with `bash -n`.

![Verification result, scheduled actions check, and Lab 05 unchanged part a](<../../screenshots/Lab-06/10-verify-lab06_a.png>)
![Verification result, scheduled actions check, and Lab 05 unchanged part b](<../../screenshots/Lab-06/10-verify-lab06_b.png>)
*`verify-lab-06.sh` reports `PASS=39 FAIL=3`, and all three failures are the scheduled actions (`morning ... exists`, `evening ... exists`, and the morning-above-evening comparison). The next command shows why: `DescribeScheduledActions` is `UnsupportedOperation`, and the guide lists the comparison as a benign failure when scheduled actions are unimplemented. Everything else passes, including one target at the right resource ID, min 2, max 10, no suspension left on, the step policy's open-ended top step, the alarm invoking the step policy, the managed alarms, the service back at the baseline with one deployment, and the files. The cleanup script parses. `verify-lab-05.sh` produces exactly the same output as before this lab: `Lab 05 is exactly as this lab found it`.*

Step 17 also asks to repair a stale `lab-04-cleanup.sh` hint in the Lab 04 and Lab 05 cleanup scripts. When I checked, both already named `lab-06-cleanup.sh` where they should (I fixed Lab 05's in Lab 05), and the remaining `lab-04-cleanup.sh` mentions are correct, because Lab 04's cleanup really does run after Lab 05's. The guide's blanket replace would have broken those lines, so I left both files unchanged.

### Step 17: Commit

I checked that `outputs/` was protected, staged the Lab 06 files by explicit path, and committed.

![Lab 06 committed part a](<../../screenshots/Lab-06/11-commit-proof_a.png>)
![Lab 06 committed part b](<../../screenshots/Lab-06/11-commit-proof_b.png>)
*`git check-ignore -v` names `.gitignore:8:outputs/*` for `outputs/lab-06-scaling-proof.txt`, and `git ls-files outputs/` lists only `.gitkeep`. The commit `401dd26` contains the env file, the notes, the four templates and both scripts (8 files), with nothing under `outputs/`, on top of the Lab 05 commits.*

## 6. Results and Evidence

### 6.1 CLI/SDK Output

| Checkpoint | What had to be true | Result |
|---|---|---|
| 1 (Step 3) | Earlier labs pass or have documented failures; service at baseline; support path recorded | Labs 02/03 `FAIL=0`, Lab 04 one expected failure, Lab 05 two documented failures; desired 2, 1 deployment; path B (screenshot 01) |
| 2 (Step 6) | One scalable target, `ecs:service:DesiredCount`, min 2, max 10, `RoleARN` filled in, switches false | All true (screenshot 02) |
| 3 (Step 9) | CPU at 50.0 and requests at 1000.0, two managed alarms each, `ResourceLabel` validated | All true, 4 managed alarms (screenshot 03) |
| 4 (Step 11) | Step policy with open-ended top step; alarm naming the policy; two scheduled actions | Policy and alarm correct; scheduled actions rejected by Floci (screenshot 04) |
| 5 (Step 12) | A scaling activity naming alarm and policy, or the six-block proof; back at desired 2 | Loop not run on Floci; six-block proof recorded; back at 2 (screenshots 05, 06) |
| 6 (Step 13) | Suspension exercised, policies untouched, `grep -ci true` is 0 | All true (screenshot 07) |
| 7 (Step 14) | `PERSISTENCE PROVEN` with identifiers re-derived | True (screenshot 08) |
| 8 (Step 17) | 22 exports, committed, nothing from `outputs/` staged | 22 exports, commit `401dd26` (screenshots 09, 11) |

The consolidated proof is `verify-lab-06.sh` at `PASS=39 FAIL=3`, with all three failures caused by Floci not supporting scheduled actions (screenshot 10).

### 6.2 AWS Console Verification

Floci has no AWS Management Console. Everything the ECS console's Auto Scaling tab and the CloudWatch alarms page would show was read directly from the `describe-scalable-targets`, `describe-scaling-policies` and `describe-alarms` calls in the screenshots above. Those calls are the same API the console uses.

## 7. Analysis and Discussion

**What I observed and what I could only reason about.** I observed:
- the scalable target and its bounds;
- re-registration replacing only what I passed;
- both target tracking policies and the four alarms they created, each pointing back at its own policy;
- the validated `ResourceLabel` and the step table;
- the custom alarm naming the step policy;
- the custom metric reaching 260;
- suspension and resumption;
- the restart proof.

I could only reason about:
- an alarm evaluating and firing;
- a policy invoking and `desiredCount` moving;
- the target tracking capacity calculation;
- cooldowns;
- scheduled actions firing;
- Fargate start-up time and the grace period.

**Floci limitations I hit, with what real AWS does:**

- **The scaling loop is not closed.** The custom alarm stayed `INSUFFICIENT_DATA` ("Unchecked") with the metric at 260, and forcing it to `ALARM` did not invoke the step policy. On real AWS the alarm evaluates every minute, the policy runs within seconds, and `desiredCount` would have gone from 2 to 5.
- **No scaling activity log.** `DescribeScalingActivities` is unsupported. Real AWS records every activity with a `Cause` string, plus the decisions not to scale with `--include-not-scaled-activities`, which is the best diagnostic the service has.
- **No scheduled actions.** `PutScheduledAction` and `DescribeScheduledActions` are unsupported, so the morning and evening floors and the one-off `at()` action could not be created. On real AWS they are the only way to have capacity ready before a known spike.
- **Bounds are stored, not enforced.** Raising `MinCapacity` to 5 left the service at 2. Real AWS raises `desiredCount` to the floor immediately.
- **Managed alarms differ in detail.** They use the predefined metric type as the metric name, put the request alarm under `AWS/ECS`, and have no dead band between the high and low thresholds.
- **Smaller storage gaps.** `TreatMissingData` was not stored, the step policy does not list the alarm that invokes it, and the service-linked role was created under a different name from the one the target references.
- **Suspension, cooldowns and `DisableScaleIn` are stored but never exercised**, because nothing scales.

**Problems that were mine to untangle:**

- **The env file's awk escape.** The guide's `\$NF` left the resource ID empty in my shell. The empty-value check caught it and I fixed it to `$NF`.
- **The cleanup hint repair.** The guide's blanket replacement would have broken lines that were already correct, so I checked each mention instead of running it.
- **Mismatches with the lab text.** The guide assumes a newer Lab 04 and Lab 05 than mine: task definition `:2`, a grace period of 60 and Lab 05 at `FAIL=0`. Mine has `:1`, a grace period Floci never stored, and Lab 05's two documented grace-period failures. None of that affects this lab's objects.

**Why the numbers are provisional.** Nothing in this lab was load tested, so the CPU target of 50, the 1000 requests per target, the queue threshold of 100 and the ceiling of 10 are starting points. The mechanism is correct; the numbers would come from a load test that measures what one task can actually serve.

## 8. Reflection

The idea I will keep from this lab is that auto scaling writes one integer. Every policy, alarm and schedule I created exists only to decide what that number should be. Starting tasks, placing them in the private subnets, registering them in the target group and health-checking them was already built in Labs 04 and 05 and did not change. Tracing Step 15's nine lines made that concrete: this lab owns three of them.

The alarms that target tracking created for me were the other surprise. I did not write them, but they decide when the service scales, and AWS chose their evaluation periods. That is why the Step 8 arithmetic came out at about five minutes before a third task helps, and why the minimum capacity and the scheduled actions matter more than the reactive policies for a spike you know is coming.

On the Floci side, this was the first lab where the main thing the lab is about could not run at all. It would have been easy to treat `set-alarm-state` returning successfully as proof of scaling. Reading `desiredCount` back, seeing it still at 2, and falling back to proving the chain link by link was the honest result, and the six-block proof showed exactly which link was missing.

## 9. Conclusion

The enrolment service is now registered as a scalable target with a floor of 2 and a ceiling of 10. It has a CPU target tracking policy, a request-count target tracking policy built on Lab 05's load balancer and target group, and a step scaling policy driven by my own alarm on a custom queue-depth metric, all with asymmetric cooldowns. I exercised suspension and cleared it, proved the configuration survives a restart, recorded every name in `configs/lab-06.env`, and committed the work as `401dd26`. Lab 05 is exactly as this lab found it.

On this Floci build the control plane works but the loop does not. The alarm never fired on its own, forcing it did not move `desiredCount`, and scheduled actions are not supported, so I proved the scaling chain from the configuration rather than from a scaling activity, and recorded each of these as a limitation. The verification script passes 39 of 42 checks, and all three failures come from the unsupported scheduled actions.

## 10. Appendix

**Key resource identifiers from this lab:**

| Resource | Value |
|---|---|
| Scalable target | `service/usms-ecs-cluster/usms-enrolment-svc`, `ecs:service:DesiredCount`, min 2, max 10 |
| Scalable target ARN | `arn:aws:application-autoscaling:us-east-1:000000000000:scalable-target/0d9ef7c184114f4a91b432320baa3209` |
| CPU policy | `usms-enrolment-cpu-target-tracking` (target 50.0, out 60, in 300) |
| Request policy | `usms-enrolment-requests-target-tracking` (target 1000.0, out 60, in 300) |
| ResourceLabel | `app/usms-enrolment-alb/fbe5d91316b641cd/targetgroup/usms-enrolment-tg/7d4bb562e9aa48c7` |
| Step policy | `usms-enrolment-queue-step-out` (`ChangeInCapacity`, +1 at 0–100, +3 at 100+, cooldown 60) |
| Custom alarm | `usms-enrolment-queue-high` (`USMS/Enrolment EnrolmentQueueDepth >= 100`, 1 × 60 s) |
| Managed alarms | 4 (`TargetTracking-service/usms-ecs-cluster/usms-enrolment-svc-AlarmHigh/Low-…`) |
| Scheduled actions | `usms-enrolment-morning-scale-out`, `usms-enrolment-evening-scale-in` (rejected: `UnsupportedOperation`) |
| Service-linked role | Created as `AWSServiceRoleForEcsApplicationAutoscaling`; target references `AWSServiceRoleForApplicationAutoScaling_ECSService` |
| Commit | `401dd26` |

**Files produced for this lab:**
- `templates/lab-06-target-tracking-cpu.json`, `templates/lab-06-target-tracking-requests.json`: target tracking configurations.
- `templates/lab-06-step-scaling-out.json`: the step table.
- `templates/lab-06-suspended-state.json`: the "suspend scale-in" runbook document.
- `configs/lab-06.env`: 22 exports for later labs.
- `notes/lab-06-notes.md`: support path, "Your turn" answers, the Step 8 arithmetic, the nine-line chain, benign failures and limitations.
- `scripts/utilities/verify-lab-06.sh`: automated check (39/42, three documented benign failures).
- `scripts/cleanup/lab-06-cleanup.sh`: end-of-course teardown, syntax-checked only and never run.
- `outputs/lab-06-*.txt`: evidence files, including `lab-06-scaling-proof.txt` and `lab-06-close-the-loop.txt` (git-ignored).
