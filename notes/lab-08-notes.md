# Lab 08 notes

**Support path: A.** The `eks` API answers and `kubectl` reaches the k3s cluster from Lab 07 (`usms-eks`, API on `https://localhost:6500`). Step 1 found both prerequisites in place: `usms-enrolment` requests `{"cpu":"50m","memory":"32Mi"}` and the cluster carries `_lb_ports_=8081,8082`. `verify-lab-07.sh` was `PASS=30 FAIL=0` before I started.

## Deviations from the lab text, and why

- **Step 10, `update-nodegroup-config` fails.** The CLI posts to the right EKS path (`POST /clusters/usms-eks-cluster/node-groups/usms-eks-nodes/update-config`), but Floci 1.7.0 hands it to its S3 handler, which answers `400 InvalidArgument: POST requires either ?uploads, ?uploadId, ?restore or ?select parameter`. `list-updates` returns nothing, and the node group stays at min 2 / max 4 / desired 2. The guide's Known Issues page lists this exact failure for Lab 08; its alternative is the HPA drill from Steps 8 and 9, which I had already done with real load (below). This is the only failing check in `verify-lab-08.sh`.
- **Node group labels did not reach the node.** `workload=usms` and `tier=app` exist only on the AWS record, so I labelled the k3s node by hand (Step 11 Part 2). That label is imperative, so the rebuild after Step 18 had to repeat it.
- **No ingress controller.** Floci starts k3s with `--disable=traefik`, so there is no IngressClass. The Ingress is stored and its rules resolve to the right endpoints, but it never gets an address (Step 16, the Conceptual case).
- **LoadBalancer.** k3s's built-in service load balancer (`svclb-usms-gateway-*`) is running, so `usms-gateway` got `EXTERNAL-IP 172.17.0.2`, which is the node container's address on the Docker bridge. My host can reach it directly and it answers. Floci publishes only port 6500 for this cluster, so `localhost:8081` and `localhost:8082` never answered: the `_lb_ports_` tag is stored but not enacted on this build.
- **NodePort from the host.** `localhost:30080` does not answer, because the node container does not publish that port. The NodePort answered through the node's InternalIP from inside the cluster, and through `port-forward` (the guide's fallback). That proves the Service works, not that the NodePort is reachable from outside.
- **One node, not two.** Step 14's "every node answers" and Exercise 2's spreading had only one node to show.
- **Step 18 persistence.** Same as Lab 07: Floci's stop removed the k3s container. See Step 18 below.
- **`kubectl drain --dry-run=client`** listed the gateway pod as "evicting" even though `usms-gateway-pdb` allows 0. A client-side dry run does not call the eviction API, so it never consults a PDB; a real drain would have blocked on that pod.
- **Screenshots of `kubectl diff`** filter out the `last-applied-configuration` annotation line, which is one very long JSON line. The exit code is still printed from `PIPESTATUS`.
- **verify-lab-08.sh.** It has the same one change as Labs 04 to 07: "no secret is tracked by git" allows `outputs/.gitkeep`. It has 34 checks, as the guide says.

## Step 3 "Your turn" - ten times the traffic on `usms-enrolment`

1. **Dimension 1 first (more pods).** Raise `maxReplicas` (or let the HPA climb). Between steps, check `kubectl get hpa` and that no pods are `Pending`.
2. **Dimension 3 when pods go `Pending` (more nodes).** Raise the node group's `desiredSize`/`maxSize`, or let a Cluster Autoscaler / Karpenter do it. Check that nodes are `Ready` and the `Pending` pods are scheduled.
3. **Dimension 2 only if one pod is the bottleneck** (bigger requests). Check `kubectl top pods` against the limit, since throttling shows up as latency rather than CPU. This restarts every pod and changes the HPA's denominator.
4. **Dimension 4 last, and never in place.** A bigger instance type means a new node group, then cordon and drain the old one.

## Step 6 "Your turn" - Guaranteed gateway

I set `--requests=cpu=200m,memory=128Mi --limits=cpu=200m,memory=128Mi`. The QoS class went Burstable → Guaranteed (pod `usms-gateway-7b46b9d8fb-qwvtm`), then back to Burstable with 50m/32Mi requests (pod `usms-gateway-58854c9ffd-tsv66`). The limits were unchanged, so the gateway could do exactly what it did before; only the reservation grew.

Each change **replaced** the pod rather than adjusting it. Resources are part of the pod template (dimension 2), and a changed template is a new ReplicaSet. That is why VerticalPodAutoscaler is used far less than HPA: every resize is a restart.

I would want `Guaranteed` for something that must be evicted last under node pressure and must never be throttled below its reservation, such as a database or a latency-critical gateway on a crowded node.

## Step 7 - metrics

k3s ships metrics-server: `v1beta1.metrics.k8s.io ... True` and `metrics API: AVAILABLE`. No install was needed and `--kubelet-insecure-tls` was **not** used. At idle each pod uses about `1m` CPU, which is 2% of the 50m request.

## Steps 8 and 9 - the HPA moved for real

`usms-enrolment-hpa` read `cpu: 2%/50%` within 30 seconds, with `ScalingActive True ValidMetricFound`. With 3 `usms-loadgen` pods running, `hpa-watch.sh` showed:

```
11:24:42  41%/50%   2
11:24:56  59%/50%   3      ceil(2 x 59 / 50) = ceil(2.36) = 3
11:25:23  49%/50%   3      ceil(3 x 49 / 50) = ceil(2.94) = 3   stable
11:27:13  42%/50%   3
```

It went to **3, not the 4 in the guide's example**. The `behavior` policies (Percent 100 / Pods 2 per 15 s, `selectPolicy: Max`) are an upper bound on how fast replicas may grow: they would have allowed +2, but they never raise the recommendation, which was 3.

I scaled `usms-loadgen` to 0 at 11:27:38. CPU fell to 2% by 11:29:11, but replicas stayed at 3 until **11:33:16**, about 5 minutes after the last recommendation of 3. That is `scaleDown.stabilizationWindowSeconds: 300` holding capacity. It then removed one pod, as `Pods 1 per 60s` allows. The HPA's own words:

- `New size: 3; reason: cpu resource utilization (percentage of request) above target`
- `New size: 2; reason: All metrics below target`

## Step 11 - Cluster Autoscaler and Karpenter

- **Cluster Autoscaler** sees `Pending` pods and raises the `desiredSize` of an Auto Scaling group I defined in advance, so it can only add the node shapes I already chose.
- **Karpenter** sees the same `Pending` pods and launches EC2 instances directly, choosing an instance type that fits them from a `NodePool`'s constraints.

Neither is installed: both need IRSA (not functional here, Lab 07 Step 21) and a real ASG / EC2 API.

The `nodeSelector` was enforced. With `workload: nonexistent`, the new pod stayed `Pending` with `0/1 nodes are available: 1 node(s) didn't match Pod's node affinity/selector`, while the two old pods kept serving because Lab 07 set `maxUnavailable: 0`. `manifests/lab-07/20-enrolment.yaml` now carries `nodeSelector: workload: usms`, and `kubectl diff` was clean.

## Step 12 - PDBs

`usms-enrolment-pdb` (maxUnavailable 1) allows 1 disruption and `usms-gateway-pdb` (minAvailable 1 on one replica) allows 0. The eviction API answered `TooManyRequests: Cannot evict pod as it would violate the pod's disruption budget`. A plain `kubectl delete pod` went straight through and the ReplicaSet replaced the pod. The node was left uncordoned.

## Step 13 - port-forward, and why it is debugging only

It is one tunnel to **one pod** (no load balancing, no failover). It exists only while the command runs on my machine, and every byte goes through the API server.

## Step 15 - the three annotations

- `aws-load-balancer-type: external`: the AWS Load Balancer Controller handles the Service, not the legacy in-tree provider.
- `aws-load-balancer-nlb-target-type: ip`: register **pod** IPs as NLB targets, the same as Lab 05's target group `--target-type ip` and for the same reason (a pod, like a Fargate task, has its own VPC address).
- `aws-load-balancer-scheme: internet-facing`: put the NLB in Lab 02's public subnets.

One line shows the whole ladder: `type=LoadBalancer  clusterIP=10.43.22.15  nodePort=30971  external=172.17.0.2`.

## Step 16 - Ingress annotations and Lab 05's `elbv2` calls

| Ingress (this lab) | Lab 05, by hand |
| --- | --- |
| `scheme: internet-facing` plus the Ingress itself | `aws elbv2 create-load-balancer --scheme internet-facing --subnets <public a,b>` |
| `target-type: ip`, one per backend Service | `aws elbv2 create-target-group --target-type ip` (x3 here) |
| `listen-ports: [{"HTTP": 80}]` | `aws elbv2 create-listener --port 80` |
| each `spec.rules[].http.paths[]` entry | `aws elbv2 create-rule --priority N --conditions path-pattern` |
| `healthcheck-path: /healthz` | `--health-check-path` on the target group |
| the controller watching EndpointSlices | `register-targets` / `deregister-targets` (ECS did it for me) |

With no controller here, the four `elbv2` commands the AWS Load Balancer Controller would have run for me, in order, are: `create-load-balancer`, `create-target-group` (one per backend), `create-listener`, `create-rule` (one per path). After that it keeps targets registered as pods come and go.

Routing is disambiguated differently. The Ingress uses the longest matching prefix (`/enrolment/x` goes to enrolment even though `/` also matches), whereas Lab 05's ALB used explicit numeric rule priorities.

## Step 17 - Practical 2 and Practical 4, compared with both running

### Scaling

| Question | ECS + Application Auto Scaling | Kubernetes + HPA |
| --- | --- | --- |
| What integer is written? | `usms-enrolment-svc` `desiredCount` (2, range 2..10) | `usms-enrolment` `spec.replicas` (2, range 2..8) |
| Who writes it? | Application Auto Scaling, through the scalable target | The HPA controller in kube-controller-manager |
| Where does that thing run? | In AWS, outside anything I own | Inside the cluster's control plane (AWS-operated on real EKS) |
| Where does the metric come from? | CloudWatch (`AWS/ECS` CPU, ALB request count), through alarms | metrics-server → `metrics.k8s.io`, polled every 15 s |
| What does "50% CPU" mean - 50% of what? | Of the CPU **reserved by the task** (task-level CPU units) | Of the container's **request** (50m), so 25m per pod; not the node and not the limit |
| How is scale-in slowed down? | `ScaleInCooldown: 300` | `scaleDown.stabilizationWindowSeconds: 300` plus `Pods 1 per 60s` (observed holding 5 min) |
| What happens if there is no capacity for the new instance/pod? | Fargate finds capacity; nothing waits for nodes | The pod sits `Pending` until something adds a node |
| What creates the alarms, if anything? | Target tracking creates two CloudWatch alarms for me | No alarms; the controller polls |

On Floci, the ECS side was stored but never acted (Lab 06). The Kubernetes side actually scaled 2 → 3 → 2.

### Exposure

| Question | ECS + ALB (Lab 05) | Kubernetes + Ingress (Step 16) |
| --- | --- | --- |
| How many AWS objects did I create by hand? | Load balancer, target group, listener, two security groups, plus the service's `loadBalancers` link: about 6 | None. One Ingress object; the controller would create the ALB, target groups and rules |
| What is the target type, and why? | `ip`: Fargate tasks have their own ENI, so there is no instance to register | `ip` (annotation), for the same reason: pods have VPC addresses with the VPC CNI |
| How are targets registered and deregistered? | ECS registers each task, and deregisters with a 30 s delay | The controller watches EndpointSlices; readiness gates registration |
| How are competing routing rules disambiguated? | Numeric rule priority | Longest matching path prefix |
| What would I change to move this to another cloud? | Everything: `elbv2` calls, target groups, the ECS service link | The `alb.ingress.kubernetes.io/*` annotations and the ingress class; the rules stay |
| What is the cost of exposing ten services? | Ten rules on one ALB if I build it that way, or ten ALBs if I do it per service | One ALB for one Ingress with ten paths; ten `LoadBalancer` Services would be ten NLBs |

### Two paragraphs, in prose

1. **If the AWS control plane has a bad afternoon.** Application Auto Scaling, CloudWatch alarms and the ECS scheduler all live in AWS. If those APIs are degraded, the running tasks keep serving but nothing scales, and I can only look at what AWS's own APIs are willing to tell me. The HPA lives in the EKS control plane, which AWS also operates, so a regional EKS control-plane outage stops it too. But the data plane keeps running, and when the API server is reachable I can read everything myself: `kubectl describe hpa` shows the conditions, the metrics and the arithmetic in words. Of the two, Kubernetes is the one I can debug, because the controller's reasoning is an object I can read rather than an alarm history in someone else's console.

2. **For USMS - one small team, one region, quiet for eight months and busy for two - I would choose ECS on Fargate.** There is no node layer to size, patch or autoscale. Lab 06's scheduled actions match the enrolment calendar exactly, and Lab 05 showed the ALB is a handful of objects. The strongest argument against my choice is what this lab demonstrated: the HPA scaled for real in seconds on a policy I could read and change in Git, and the same manifests would run on any cluster. ECS ties the whole runtime, scaling and exposure to AWS-specific APIs, and if USMS ever grows past three services, Kubernetes' one-Ingress-many-paths model and its ecosystem would start paying for its complexity.

## Step 18 - persistence: configuration came back only from Git

The `nodegroup` record survived the stop/start (`2 4 2`). The k3s container did not: `docker compose stop` made Floci remove it, so `kubectl` got `connection to the server localhost:6500 was refused` and every HPA, PDB, Service and Ingress was gone. `FLOCI_STORAGE_MODE` was `hybrid`, so this is not the memory-mode trap; it is the same Floci 1.7.0 behaviour as in Lab 07.

I rebuilt from committed files only: delete and recreate the cluster and node group from the Lab 07 templates, `update-kubeconfig`, `kubectl apply -f manifests/lab-07/`, then the five Lab 08 manifests (not `20-loadgen.yaml`, so the rebuild would not start load). I also re-ran the two imperative steps: the Lab 07 `kubectl set env --from=secret` and this lab's `kubectl label node`. Finally I registered the new OIDC issuer (`.../id/908C96D1CDD547C3956DFAAE78E1EB11`) and deleted the old provider.

Comparing the read-back with the before-file gave exactly one difference: `usms-gateway` nodePort `30971 → 31345`. That port is auto-allocated, so a new Service gets a new one. `usms-results-np` stayed on `30080` because it is pinned, which is the argument for pinning. HPA bounds, both PDBs, the Service types and the Ingress paths were identical. So the configuration survives, but because it is in Git, not because the cluster kept it.

Side effects of the restart, as in Labs 05 to 07: `usms-web-01` stopped (I started it again), and ECS came back at 2/2. `verify-lab-05.sh` 47/2, `verify-lab-06.sh` 39/3 and `verify-lab-07.sh` 30/0 are unchanged.

## verify-lab-08.sh: PASS=33 FAIL=1

| Failing check | Cause |
|---|---|
| node group maxSize was raised to 6 | `UpdateNodegroupConfig` is misrouted to the S3 handler on Floci 1.7.0 (Step 10) |

`configs/lab-08.env` has 19 exports. Only `USMS_INGRESS_CLASS` is empty (no controller, an expected exception). The node group values read `2 / 4 / 2`, because that is what is actually true. The smoke test passed.

## Section 14 - review questions

1. **"Scales when the node hits 50% CPU."** No. The HPA divides each pod's usage by the container's CPU **request** (50m), so it scales out when the pods average more than 25m, whatever the node is doing. My node sat at 1% while the HPA read 59%. If someone halves the request to 25m without touching the HPA, the same usage reads as twice the percentage, so the HPA adds pods twice as eagerly. The scheduler also reserves half as much per pod. The workload ends up with more pods but less guaranteed CPU each, and every recorded percentage stops being comparable with the old ones.

2. **Ten times by Monday.** (a) Dimension 3 first if the nodes have no headroom: raise the node group's `maxSize`/`desiredSize`, and check that nodes are `Ready` with allocatable CPU to spare. (b) Dimension 1: raise `maxReplicas`, load-test, and check `kubectl get hpa` reaches a steady percentage below target with no `Pending` pods. (c) Dimension 2 only if a single pod is throttled at its limit: raise requests and limits together, check that the HPA's percentages make sense against the new denominator and that pods still fit on a node. Dimension 4, a bigger instance type, cannot change in place. I would create a second node group with the new type, cordon and drain the old one (the PDBs keep it safe), then delete it.

3. **Outside versus inside.** (a) Failure: Application Auto Scaling keeps working if my cluster is sick, but I cannot fix it if AWS's service is sick. The HPA is gone if the control plane is down, but it is entirely inspectable and re-creatable from a manifest. (b) Ownership and change: the HPA is a YAML file in Git that I `kubectl diff` and review like code. The ECS policy is an API call whose state lives in AWS, and I discover drift with `describe-*` calls. There is also an observability consequence: ECS records scaling activities with a cause in AWS, whereas the HPA's history is a few Kubernetes events that age out.

4. **4 → 8 with four pods `Pending` for twenty minutes.** The HPA's loop did its job: it wrote `replicas: 8`. The node group's loop is a different controller watching a different number (`desiredSize`), and nothing connected the two, so there was no room and the scheduler left the pods `Pending` (`Insufficient cpu`). On real EKS, a Cluster Autoscaler or Karpenter watches `Pending` pods and raises capacity. Lowering the CPU request would make the pods "fit" by lying to the scheduler: the node is no more capable. It also halves the HPA's denominator, so the HPA scales even more aggressively and the pods end up throttled.

5. **NodePort versus LoadBalancer.** A NodePort opens one high port (30000–32767) on every node. Clients must know node addresses, which change whenever a node is replaced, and must be allowed through to the nodes. A LoadBalancer Service keeps that NodePort and adds one stable address in front of it, with health checks and, on AWS, `target-type: ip` straight to pods. Requirement: "the Examinations Office needs one stable address on port 80 that survives node replacement". A NodePort fails it (port 30080, addresses that move); a LoadBalancer meets it.

6. **`/enrolment` through the Ingress or through the gateway.** I would keep one route: through `usms-gateway`. I would delete the `/enrolment` and `/results` rules and leave only `/` → `usms-gateway` on the Ingress. The gateway is where cross-cutting behaviour lives: it strips the prefix and adds headers, and it is the place for rate limits, authentication or a maintenance page. A direct Ingress rule silently bypasses all of that for one path, and two routes to the same service means two behaviours to test. The Ingress rule's advantage, one hop less, is not worth that for USMS.

7. **`minAvailable: 1` did not stop `kubectl delete pod`.** A PDB constrains the **eviction API**, which cooperative processes use: `kubectl drain`, Cluster Autoscaler, node upgrades. `kubectl delete pod` is a direct delete, not an eviction, so it is not consulted, which is correct because an operator deleting a named pod has made a deliberate decision. Voluntary disruptions (a drain, an autoscaler scale-in, a managed node group upgrade) are requested through an API and respect PDBs. Involuntary ones (kernel panic, OOM, hardware failure, someone terminating the instance) are not requested by anyone, and a PDB cannot stop them. Realistic save: during an EKS managed node group upgrade, nodes are drained one after another. `usms-enrolment-pdb` (`maxUnavailable: 1`) makes the drain wait until a replacement enrolment pod is Ready before evicting the next, so enrolment never drops to zero in the middle of registration week.

## Exercise 5 - artefacts for Lab 10

- `outputs/lab-08-scaling-evidence.json`: HPA spec and status, deployment replicas, the node group's scaling config with the failed-update note, observed timestamps. Assembled from live calls with `python3`, and `json.tool` accepts it.
- `outputs/lab-08-lab06-readiness.txt`: `USMSStudentDataReadWrite` is on `usms-ec2-app-role`, `usms-ecs-task-role` and `usms-eks-node-role`. The bucket ARN read out of policy version v1 is `arn:aws:s3:::usms-student-data`, and the bucket does not exist yet. Under IRSA, `usms/usms-enrolment-sa` would carry `eks.amazonaws.com/role-arn` naming a new role that trusts the cluster's OIDC provider, not `usms-eks-node-role`, because the node role is shared by every pod on every node.
- Both files are ignored by `.gitignore:8:outputs/*`.

Exercises 1 to 4 were not attempted.

### ECS or Kubernetes for USMS

ECS on Fargate. In Practical 2, three services ran with no nodes to own. Lab 06's scheduled actions describe the enrolment calendar directly, and Lab 05's ALB was six objects I understood one by one. The strongest argument against it came from Practical 4. The HPA reacted in under 15 seconds to real load and explained itself in plain words (`New size: 3; reason: cpu resource utilization ... above target`), and the stabilisation window visibly held capacity for five minutes. Everything that did that is a YAML file that `kubectl diff` checks against Git. Meanwhile, Lab 06's target tracking on the same Floci never moved `desiredCount` at all. Three specific observations: (1) Kubernetes state lived only in a container that a Floci stop deleted, and I got it back in two minutes only because every object was a manifest. So with Kubernetes, Git is the source of truth or there is none. (2) `update-nodegroup-config` failed and node labels never reached the node, so the AWS half of EKS is where the operational weight sits. (3) ECS's 50% CPU is measured against the task's reservation and the HPA's against the container's request, so "50%" in the two systems is not the same load. For a small team that is quiet for eight months, fewer layers wins.

## Floci limitations hit (and what real AWS does)

| Limitation on Floci 1.7.0 | Real AWS | Status in this lab |
|---|---|---|
| `UpdateNodegroupConfig` routed to the S3 handler, 400 `InvalidArgument` | Updates the ASG, returns an `InProgress` Update | Failed; HPA drill used instead |
| Node group labels not applied to the node | Labels on every node in the group | Labelled by hand |
| One k3s node; no third node from `desiredSize` | ASG launches EC2 instances that join as `Ready` | Conceptual |
| `_lb_ports_` stored; 8081/8082 not published | n/a; an NLB gets a DNS name | Recorded, not enacted |
| k3s servicelb gives the node container IP as EXTERNAL-IP | NLB in public subnets with pod-IP targets | Observed (local equivalent) |
| Traefik disabled; no IngressClass; Ingress has no address | AWS Load Balancer Controller creates an ALB | Conceptual |
| NodePort not published to the host | Reachable on any node subject to security groups | Observed in-cluster only |
| k3s container removed on Floci stop | Control plane and etcd persist | Rebuilt from Git |
| IRSA not functional, so no Cluster Autoscaler / Karpenter / LB controller | All three are standard on EKS | Conceptual |
| metrics-server shipped by k3s | Installed once, or as an EKS add-on | Observed, HPA worked |
