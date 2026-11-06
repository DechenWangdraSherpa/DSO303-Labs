# Lab 06 notes

**Support path: B (control plane only).** Floci 1.7.0 stores scalable targets, both kinds of scaling policy, the managed and custom CloudWatch alarms and the suspended state. It does not run the loop: the custom alarm stayed `INSUFFICIENT_DATA` ("Unchecked") with the metric at 260 against a threshold of 100, `set-alarm-state ALARM` was accepted but `desiredCount` stayed 2, and `DescribeScalingActivities`, `PutScheduledAction` and `DescribeScheduledActions` return `UnsupportedOperation`. Step 12 used the six-block control-plane proof (`outputs/lab-06-scaling-proof.txt`).

## Deviations from the lab text, and why

- **Service-linked role name.** `create-service-linked-role --aws-service-name ecs.application-autoscaling.amazonaws.com` created `AWSServiceRoleForEcsApplicationAutoscaling`, but the scalable target's `RoleARN` names `AWSServiceRoleForApplicationAutoScaling_ECSService`, which `get-role` cannot find. Real AWS uses the second name for both.
- **Scheduled actions.** All three (`morning-scale-out`, `evening-scale-in`, the `at()` "Your turn") were rejected with `UnsupportedOperation`, with and without `--timezone`. Nothing was created, so nothing had to be deleted.
- **Persistence check (Step 14).** The guide's comparison includes the scheduled actions and the alarm's `TreatMissingData`; this build stores neither (`TreatMissingData` reads back `null`), so both were left out of the before/after files and the PERSISTENCE line says only what was compared.
- **configs/lab-06.env.** The lab's `awk -F: '{print \$NF}'` inside `$(...)` in the unquoted heredoc reached awk with the backslash and left `USMS_SCALABLE_RESOURCE_ID` empty. Plain `$NF` is already protected by the single quotes. Same trap as Lab 05's listener line.
- **verify-lab-06.sh.** "no secret is tracked by git" allows `outputs/.gitkeep`, as in Labs 04 and 05.
- **Step 17 part 1 (hint strings).** Nothing to repair: Lab 05's cleanup script was already corrected in Lab 05 and Lab 04's already names `lab-06-cleanup.sh`. The guide's blanket replace would have turned the correct "BEFORE lab-04-cleanup.sh" lines into wrong ones, so it was not run.
- **Task definition** is `usms-enrolment:1` (my Lab 04 never registered `:2`) and the grace period is `None` (Floci never stored it in Lab 05).

## verify-lab-06.sh: PASS=39 FAIL=3, all from one limitation

| Failing check | Cause |
|---|---|
| morning action usms-enrolment-morning-scale-out exists | `PutScheduledAction` is `UnsupportedOperation` on this build |
| evening action usms-enrolment-evening-scale-in exists | same |
| the morning action raises the floor ABOVE the evening action's | listed as benign in Section 8 when scheduled actions are unimplemented |

`verify-lab-05.sh` output is identical before and after this lab (empty `diff` of `outputs/lab-06-pre-verify-05.txt` and `outputs/lab-06-post-verify-05.txt`).

## Your turn - Step 6 (MinCapacity 5)

Prediction: on real AWS `desiredCount` moves from 2 to 5 within seconds, with no policy or alarm involved. On Floci the target stored `5 10` but `desiredCount` stayed 2 for 15 seconds; the floor is stored, not enforced. Put back to `2 10`. `describe-scaling-activities` is unsupported, so whether it would have been recorded is not observable here.
(a) The scalable target made that change: registration enforces its own bounds, with no scaling policy involved.
(b) The cost is three extra Fargate tasks running all night for nothing, and `describe-scalable-targets --query 'ScalableTargets[0].[MinCapacity,MaxCapacity]'` is the one call that would have shown it.

## Your turn - Step 8 (time at 100% CPU before a third task serves traffic)

1. High alarm `Period` x `EvaluationPeriods` = 60 s x 3 = **180 s** (AWS chose these, not me).
2. Policy invocation: about **0 s**.
3. Fargate task start-up: not measured on this build (tasks start instantly or not at all); AWS's documented range is **20 to 60 s**.
4. Health check grace period (Lab 05 Step 10): **60 s**.

Total: about 180 + 0 + 60 + 60 = **300 s (5 minutes)** in the worst case, served by the two tasks I already had.
The term I would change first is the alarm evaluation: replace CPU target tracking for spikes with a step policy on my own alarm at one evaluation period (as the queue alarm does), which cuts about 2 minutes but makes scaling twitchier and needs its own scale-in policy.

## Your turn - Step 11 (at() results night)

Not observable: `PutScheduledAction` is unsupported, so the action could not be created. An `at()` action does not delete itself after firing, so the scalable target is left with an old calendar entry and, worse, the raised `MinCapacity` of 6 it set, which six months later is an unexplained floor costing four extra tasks. The runbook page that creates it should also hold `delete-scheduled-action` and the `register-scalable-target --min-capacity 2` that puts the floor back.

## Step 15 - nine lines from a click to a serving task

1. A student clicks Register. Requests per target rises past 1000, or the work queue passes 100. *(this lab)*
2. An alarm fires and invokes a policy. *(this lab)*
3. The policy writes `desiredCount`, clamped to 2..10. *(this lab)*
4. ECS starts a task from `usms-enrolment:1`. (Lab 04)
5. The task gets an address in `usms-private-subnet-a` or `-b`, no public IP. (Labs 02, 04)
6. `usms-enrolment-sg` admits tcp/80 from `usms-alb-sg` only. (Lab 05)
7. The service registers its address in `usms-enrolment-tg`. (Lab 05)
8. The load balancer health-checks it, then sends it traffic. (Lab 05)
9. Nothing about the blueprint, the service or the load balancer changed: still `:1`, 1 load balancer, 1 deployment (Step 15 block 7).

This lab owns lines 1 to 3; the other six needed no change because auto scaling only writes one integer.

## Floci limitations hit (and what real AWS does)

| Limitation on Floci 1.7.0 | Real AWS |
|---|---|
| Alarms never evaluated ("Unchecked"); `set-alarm-state ALARM` does not invoke the step policy; `desiredCount` never moves | Alarm evaluated every minute; policy invoked within seconds; activity recorded with a `Cause` naming alarm and policy |
| `DescribeScalingActivities` unsupported | Full activity log, plus `--include-not-scaled-activities` |
| `PutScheduledAction` / `DescribeScheduledActions` unsupported | Cron/rate/at schedules with IANA time zones, fired to the minute |
| `MinCapacity` stored, not enforced (min 5 left desired at 2) | Registration raises `desiredCount` to the floor immediately |
| Managed alarms use metric name `ECSServiceAverageCPUUtilization` / `ALBRequestCountPerTarget` in `AWS/ECS`, low threshold equal to the target (50) | `AWS/ECS CPUUtilization` and `AWS/ApplicationELB RequestCountPerTarget`, low threshold below the target (dead band) |
| Step policy's `Alarms` list stays empty although the alarm names the policy | The policy lists the alarm that invokes it |
| `TreatMissingData` not stored (`null`) | Stored and enforced per period |
| Service-linked role created under a different name from the one the target references; nothing assumes it | One role, assumed for every `UpdateService`, visible in CloudTrail |
| Suspension, cooldowns and `DisableScaleIn` stored but never exercised | Enforced |
| Floci restart stops `usms-web-01` and restarts the ECS tasks | Nothing restarts |
