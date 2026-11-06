# Lab 8 – EKS Scaling and Service Exposure for USMS

**Name:** Dechen Wangdra Sherpa
**Student Number:** 02230281
**Course:** DSO303 – Cloud Native Design Patterns
**Lab:** Lab 8 – Amazon EKS: Scaling and Service Exposure

---

## 1. Aim / Objective

Lab 07 left three USMS microservices running on EKS. They were healthy, but they had a fixed size and could not be reached from outside the cluster. The aim of this lab was to climb two ladders on top of them.

**Scaling.** Move the replica count four ways:
- by hand with `kubectl scale`;
- by changing the manifest;
- with an `autoscaling/v2` HorizontalPodAutoscaler under real load;
- from the AWS side, by resizing the managed node group.

Then explain why the HPA and the node group are two separate control loops.

**Safety.** Read QoS classes off the cluster, prove a `nodeSelector` is enforced, and show what a PodDisruptionBudget protects and what it does not.

**Exposure.** Take `usms-gateway` up the ladder: `port-forward`, then a `NodePort` (pinned at 30080), then a `LoadBalancer`, then an `Ingress`. Map the Ingress onto the ALB I built by hand in Lab 05.

Finally, compare the ECS and EKS stacks while both were running, prove the configuration survives a Floci restart, record it in `configs/lab-08.env`, verify it and commit.

## 2. Introduction

In Lab 06, Application Auto Scaling wrote one integer, `desiredCount`, for the ECS service. Kubernetes also scales by writing one integer, `spec.replicas`. What changes from rung to rung is who writes it:

```
kubectl scale              I write the integer
replicas: in the manifest  Git writes the integer
HorizontalPodAutoscaler    a controller in the cluster writes it, from metrics
update-nodegroup-config    I write a DIFFERENT integer (nodes), on the AWS side
Cluster Autoscaler         a controller writes that one too (conceptual here)
```

The HPA needs a metrics pipeline (metrics-server serving `metrics.k8s.io`) and a CPU **request** on the container. The HPA's percentage is usage divided by that request, not node CPU.

Exposure has its own ladder, and each rung keeps the one below it. A `NodePort` Service still has a ClusterIP, and a `LoadBalancer` Service still has a nodePort and a ClusterIP. An `Ingress` is different in kind: it is HTTP routing rules that a controller turns into a load balancer. On EKS that controller is the AWS Load Balancer Controller, and what it builds is the same ALB, target groups and rules I created with `aws elbv2` in Lab 05.

## 3. Use Case

USMS is quiet for most of the year and very busy during the two enrolment weeks. On EKS, the enrolment service has to grow and shrink with load by itself. It must grow quickly, shrink slowly (so a quiet minute in a busy hour does not remove capacity), and never drop to zero pods during node maintenance.

The Examinations Office also wants results reachable from outside the cluster at one stable address, without exposing every service and without paying for one load balancer per service.

This lab gives `usms-enrolment` an HPA (2 to 8 pods at 50% CPU of its 50m request), gives the gateway and enrolment PodDisruptionBudgets, and exposes the services through a pinned NodePort, a LoadBalancer gateway and a path-routed Ingress.

## 4. System Architecture / Design

```
                                 YOUR MACHINE
  curl ---> 172.17.0.2:80 (servicelb, the node's address) ---------+
  curl ---> localhost:8081/8082 (_lb_ports_) ... not published      |
                                                                   v
  +----------------------- k3s cluster usms-eks, namespace usms ---------------------+
  |  Ingress usms-portal-ingress  /enrolment -> usms-enrolment                        |
  |    (stored, no controller:     /results  -> usms-results                         |
  |     Floci runs --disable=traefik)  /     -> usms-gateway                          |
  |                                                                                  |
  |  Service usms-gateway  LoadBalancer  80:31345  EXTERNAL-IP 172.17.0.2            |
  |    (was ClusterIP in Lab 07; still has a clusterIP and a nodePort)               |
  |       |                                                                          |
  |  Deployment usms-gateway (1)   PDB usms-gateway-pdb  minAvailable 1  -> 0 allowed |
  |       | proxy_pass by DNS name                                                   |
  |       v                              v                                           |
  |  Deployment usms-enrolment  2..8     Deployment usms-results (2)                 |
  |    nodeSelector workload=usms        Service usms-results     ClusterIP          |
  |    PDB maxUnavailable 1 -> 1 allowed Service usms-results-np  NodePort 30080     |
  |       ^                                                                          |
  |  HPA usms-enrolment-hpa  <- metrics.k8s.io <- metrics-server (ships with k3s)    |
  |    cpu 50% of 50m, scale-up 0 s window, scale-in 300 s window, 1 pod/min         |
  |                                                                                  |
  |  Deployment usms-loadgen (3 x busybox wget loop) - the load source, then deleted |
  +----------------------------------------------------------------------------------+
           AWS side: usms-eks-nodes  min 2 / max 4 / desired 2  (resize failed, Step 10)
```

Key design choices:
- **The HPA owns `replicas`.** Once it exists, `replicas: 2` in `manifests/lab-07/20-enrolment.yaml` is only a starting value. Hand scaling would be overwritten within 15 seconds.
- **Instant out, slow in.** Scale-up has no stabilisation window and may add up to 100% or 2 pods every 15 seconds, whichever is more. Scale-in waits 300 seconds and then removes at most 1 pod a minute. This is Lab 06's `ScaleInCooldown: 300`, better named.
- **Full manifests, not patches.** `usms-gateway` became a LoadBalancer by re-applying a complete Service file. A patch would have left the repository describing a ClusterIP Service that no longer exists.
- **A pinned NodePort.** `usms-results-np` is fixed at 30080, so it is predictable and survives a rebuild. The gateway's nodePort was left to be allocated, to show the difference.
- **PDBs.** `minAvailable` gives a fixed floor (gateway). `maxUnavailable` follows the HPA's moving count (enrolment).

## 5. Implementation Procedure

### Step 1–2: Check what Lab 07 left behind, and record a baseline

The HPA cannot work without a CPU request on `usms-enrolment`, and Step 15 needs the `_lb_ports_` tag, so I checked both before changing anything. Then I ran `verify-lab-07.sh` and saved a narrow baseline to `outputs/lab-08-baseline.txt`.

![Floci up, whoami, context and the two prerequisite checks part a](<../../screenshots/Lab-08/01-prerequisites-and-baseline_a.png>)
*`floci-up.sh` reports Floci up on `http://localhost:4566`, and `whoami.sh` confirms account `000000000000`, which is Floci. The context is `usms-eks` with default namespace `usms`. `usms-enrolment` requests `{"cpu":"50m","memory":"32Mi"}`, and the `_lb_ports_` tag reads `8081,8082` both from `configs/lab-07.env` and from `describe-cluster`.*

![verify-lab-07 and the Lab 07 objects part b](<../../screenshots/Lab-08/01-prerequisites-and-baseline_b.png>)
*`verify-lab-07.sh` ends `PASS=30 FAIL=0`. The three Deployments are at `2/2`, `1/1` and `2/2`, there are three ClusterIP Services with `EXTERNAL-IP <none>`, four USMS ConfigMaps and the one Secret `usms-enrolment-secret`.*

![Baseline file written with tee part c](<../../screenshots/Lab-08/01-prerequisites-and-baseline_c.png>)
*The baseline records desired and ready counts of 2, 1 and 2, the endpoints, every Service `ClusterIP` with `EXTERNAL` `<none>`, and one node `d3c4fc01636a` `Ready` with 8 CPUs. The empty EXTERNAL column is recorded on purpose: Step 15 fills it in.*

**Your turn (Step 3): ten times the traffic.** My plan, in `notes/lab-08-notes.md`, goes in this order:
1. Dimension 1, more pods, checking for `Pending` pods.
2. Dimension 3, more nodes, when pods go `Pending`.
3. Dimension 2, bigger pods, only if one pod is throttled at its limit.
4. Dimension 4, bigger nodes. This one cannot change in place, so it means a new node group and a drain.

### Step 4: Scale by hand, and watch what moves

![Scale to five, rollout, endpoints and ReplicaSet part a](<../../screenshots/Lab-08/02-scale-by-hand_a.png>)
*Before scaling there is one ReplicaSet, `usms-enrolment-575945b968`, at 2. After `kubectl scale --replicas=5`, the rollout waits for 2, then 3, then 4 of 5 to be available. The Deployment is `5/5`, the endpoints list grows to `10.42.0.11:80,10.42.0.12:80,10.42.0.13:80 + 2 more`, and it is **the same ReplicaSet** now at 5/5/5. Only `spec.replicas` changed, so there was no rollout. The 40-request tally through the gateway reached all five pods (10, 10, 9, 6, 5), and the gateway was not touched.*

![Scale back to two part b](<../../screenshots/Lab-08/02-scale-by-hand_b.png>)
*After scaling back to 2, the endpoints list is two addresses again. Pods leave the endpoint list before they get SIGTERM, which is the Kubernetes version of Lab 05's 30-second deregistration delay.*

### Step 5: Scale declaratively, and meet configuration drift

![Drift created, then undone by apply part a](<../../screenshots/Lab-08/03-configuration-drift_a.png>)
*`kubectl scale --replicas=6` makes the cluster say `6`, while `grep` shows the file still says `35:  replicas: 2`. Nothing warns about the difference. An unrelated `kubectl apply -f manifests/lab-07/20-enrolment.yaml` then silently puts it back to `2`.*

![kubectl diff before apply part b](<../../screenshots/Lab-08/03-configuration-drift_b.png>)
*After editing the file to `replicas: 3`, `kubectl diff` shows `-  replicas: 2` / `+  replicas: 3` and exits `1`. That exit code means "there is a difference", not an error. Applying it makes the cluster read `3`.*

![Restored to two, no bak files part c](<../../screenshots/Lab-08/03-configuration-drift_c.png>)
*The file is restored to `replicas: 2`, applied and rolled out, the `.bak` files are removed, and all three Deployments are back at `2/2`, `1/1` and `2/2`.*

### Step 6–7: Requests, limits, QoS classes and the metrics pipeline

![QoS classes and the node's allocated resources part a](<../../screenshots/Lab-08/04-qos-classes-and-requests_a.png>)
*All five pods are `Burstable`, with request `50m` and limit `200m` (requests set but lower than limits). The node shows Capacity and Allocatable both at `cpu 8` and `7965236Ki`; k3s reserves nothing here, which a real EKS node would. The scheduler has allocated `450m (5%)` of CPU requests and `1 (12%)` of limits.*

![The HPA's denominator part b](<../../screenshots/Lab-08/04-qos-classes-and-requests_b.png>)
*The request read live is `50m`, so a 50% target means 25m average per pod. It is not 50% of a node and not 50% of the limit.*

**Your turn: a Guaranteed gateway.** I made requests equal limits (`200m` / `128Mi`) so the gateway could do exactly what it did before, then put it back.

![Gateway Burstable to Guaranteed part a](<../../screenshots/Lab-08/05-guaranteed-qos-and-metrics-api_a.png>)
*Before: `usms-gateway-58854c9ffd-d6frz` is `Burstable`. After `kubectl set resources` with equal requests and limits, a **new** pod `usms-gateway-7b46b9d8fb-qwvtm` is `Guaranteed` with `200m`/`200m`.*

![Back to Burstable and the metrics API part b](<../../screenshots/Lab-08/05-guaranteed-qos-and-metrics-api_b.png>)
*Putting the requests back to `50m` replaced the pod again, with `usms-gateway-58854c9ffd-tsv66` back to `Burstable` `50m`/`200m`. The pod was replaced each time, not adjusted, because resources are part of the pod template. That is dimension 2, and it is why VerticalPodAutoscaler is used far less than HPA. The metrics check shows `v1beta1.metrics.k8s.io kube-system/metrics-server True`, a `metrics-server 1/1` Deployment, and `metrics API: AVAILABLE`. k3s ships it, so nothing was installed and `--kubelet-insecure-tls` was not needed.*

![kubectl top nodes and pods at idle part c](<../../screenshots/Lab-08/05-guaranteed-qos-and-metrics-api_c.png>)
*`kubectl top` works. The node uses `111m` (1%), and every USMS pod sits at `1m` CPU and `7Mi`, which is 2% of the 50m request. This is the idle figure Step 9 starts from.*

### Step 8: Create the HorizontalPodAutoscaler

`manifests/lab-08/10-hpa-enrolment.yaml` is `autoscaling/v2`: min 2, max 8, CPU 50%, with the `behavior` block described in Section 4. Each field maps to Lab 06:

| Lab 06 | This HPA |
| --- | --- |
| `MinCapacity` / `MaxCapacity` | `minReplicas` / `maxReplicas` |
| `TargetTrackingScaling` on CPU | `metrics[].resource` with `averageUtilization` |
| `ScaleInCooldown: 300` | `scaleDown.stabilizationWindowSeconds: 300` |
| the two alarms AWS created | nothing; the controller polls every 15 seconds |

![HPA created, unknown then two percent part a](<../../screenshots/Lab-08/06-hpa-created_a.png>)
*`horizontalpodautoscaler.autoscaling/usms-enrolment-hpa created`. At `0s` it reads `cpu: <unknown>/50%` with 0 replicas; it has not polled yet. Thirty seconds later it reads `cpu: 2%/50%`, MINPODS `2`, MAXPODS `8`, REPLICAS `2`.*

![HPA behavior and conditions part b](<../../screenshots/Lab-08/06-hpa-created_b.png>)
*`describe` shows the behaviour as written. Scale Up: window `0 seconds`, Select Policy `Max`, `Percent 100` and `Pods 2` per 15 seconds. Scale Down: window `300 seconds`, Select Policy `Min`, `Pods 1` per 60 seconds. The conditions are `AbleToScale True`, `ScalingActive True ValidMetricFound` ("the HPA was able to successfully calculate a replica count from cpu resource utilization (percentage of request)") and `ScalingLimited False DesiredWithinRange`.*

### Step 9: Generate load and watch the HPA respond

I wrote `scripts/utilities/hpa-watch.sh`, which prints CPU, desired, ready and pod counts every 10 seconds (13 seconds in practice, because of the kubectl calls). Then I applied `usms-loadgen`: three busybox pods looping `wget` against the gateway's `/enrolment/`.

![hpa-watch syntax, load generator rolled out and the scale-out part a](<../../screenshots/Lab-08/07-hpa-scales-out-under-load_a.png>)
*`hpa-watch.sh: valid bash syntax` and `usms-loadgen` rolled out 3/3. The watch shows CPU at `2%`, then `5%`, then `41%`, then **`59%/50%` at 11:24:56 with REPLICAS `3`**. The third pod is ready on the next line, and CPU settles at `42%` with 3 pods.*

![HPA and kubectl top under load part b](<../../screenshots/Lab-08/07-hpa-scales-out-under-load_b.png>)
*Under load the HPA reads `cpu: 42%/50%` with REPLICAS `3`, and `kubectl top` shows each of the three enrolment pods at `21m`, which is 42% of 50m.*

The arithmetic: ceil(2 × 59 / 50) = ceil(2.36) = **3**. With 3 pods at 42%, ceil(3 × 42 / 50) = ceil(2.52) = 3, so it held. The guide's example went to 4, but mine went to 3. The `behavior` policies are a speed limit, not a target. They would have allowed +2, but they never raise the controller's recommendation, which was 3.

Then I scaled `usms-loadgen` to 0 and watched for 6½ minutes:

![Load removed and the stabilisation window holding three pods part a](<../../screenshots/Lab-08/08-hpa-scale-in-after-window_a.png>)
*The load was removed at `11:27:38`. CPU falls from `42%` to `18%`, `5%`, then `2%` by 11:29:11, but REPLICAS stays at **3** for every line until `11:33:03`. At **`11:33:16`** it drops to 2. That is about five minutes after the last recommendation of 3 (11:28:19): the 300-second scale-in window holding capacity, then one pod removed.*

![HPA events quoting its reasons part b](<../../screenshots/Lab-08/08-hpa-scale-in-after-window_b.png>)
*The HPA's own events: `New size: 3; reason: cpu resource utilization (percentage of request) above target` and, 8½ minutes later, `New size: 2; reason: All metrics below target`.*

### Step 10: Scale the data plane from the AWS side – failed on this build

![Node group before the change part a](<../../screenshots/Lab-08/09-nodegroup-update-fails_a.png>)
*`usms-eks-nodes` is `ACTIVE` with scaling `minSize 2, maxSize 4, desiredSize 2`, `t3.small`, the two private subnets `subnet-1150e689` and `subnet-47a7fe37`, and labels `tier=app`, `workload=usms`.*

![update-nodegroup-config rejected by the S3 handler part b](<../../screenshots/Lab-08/09-nodegroup-update-fails_b.png>)
*`update-nodegroup-config --scaling-config minSize=2,maxSize=6,desiredSize=3` fails with `An error occurred (400) when calling the UpdateNodegroupConfig operation: ... <Code>InvalidArgument</Code><Message>POST requires either ?uploads, ?uploadId, ?restore or ?select parameter.`, which is an **S3** error. With `--debug` the request URL is the correct EKS path `http://localhost:4566/clusters/usms-eks-cluster/node-groups/usms-eks-nodes/update-config`, so Floci 1.7.0 routes this POST to its S3 handler. `list-updates` returns no update id.*

![Node group unchanged and the node as Kubernetes sees it part c](<../../screenshots/Lab-08/09-nodegroup-update-fails_c.png>)
*The scaling config reads back `2 / 4 / 2`, unchanged. Kubernetes sees one node, `d3c4fc01636a`, `Ready`, and its `workload` label is `<none>`: the node group's labels never reached the node.*

The course's Known Issues page lists this exact failure for Lab 08. Its alternative is the HPA drill from Steps 8–9: load changes the pod count, but no nodes are added. I had already done that drill with real load (screenshots 07 and 08). I did not fake the resize by deleting and recreating the node group. On real AWS, the update would return an `InProgress` Update object, and the ASG would launch a third EC2 instance that joins as `Ready` within minutes.

### Step 11: A `nodeSelector` that is actually enforced

Neither Cluster Autoscaler nor Karpenter is installed, because both need IRSA, which is not functional here.
- **Cluster Autoscaler** watches `Pending` pods and raises the `desiredSize` of node groups I defined in advance.
- **Karpenter** watches the same pods and launches EC2 instances directly, picking a size that fits them.

![Node labelled by hand and the selector applied part a](<../../screenshots/Lab-08/10-nodeselector-enforced_a.png>)
*`node group labels did not reach the nodes`, so I labelled the node, and `get nodes -L workload,tier` shows `usms` and `app`. Patching `nodeSelector: workload: usms` into `usms-enrolment` rolled out normally.*

![Unmatchable selector leaves the new pod Pending part b](<../../screenshots/Lab-08/10-nodeselector-enforced_b.png>)
*With `workload: nonexistent`, the new pod `usms-enrolment-cfb5b9fc7-rpc7h` is `Pending` while the two old pods stay `1/1 Running`. Its event reads `FailedScheduling ... 0/1 nodes are available: 1 node(s) didn't match Pod's node affinity/selector`. Lab 07's `maxUnavailable: 0` kept the service serving: stuck is better than broken. Putting `workload: usms` back rolled out, and both pods run on `d3c4fc01636a`.*

![Manifest updated and kubectl diff clean part c](<../../screenshots/Lab-08/10-nodeselector-enforced_c.png>)
*The script reports `nodeSelector already present in manifests/lab-07/20-enrolment.yaml` (this was the second run; the first added it), and `kubectl diff: no differences`. The repository matches the cluster.*

### Step 12: PodDisruptionBudgets, and what they do not protect against

![PDBs created and the eviction refused part a](<../../screenshots/Lab-08/11-pdb-eviction-vs-delete_a.png>)
*`usms-enrolment-pdb` shows `MAX UNAVAILABLE 1` and `ALLOWED DISRUPTIONS 1`. `usms-gateway-pdb` shows `MIN AVAILABLE 1` and **`ALLOWED DISRUPTIONS 0`**: one replica with a floor of one cannot be drained. POSTing an Eviction for the gateway pod returns `Error from server (TooManyRequests): Cannot evict pod as it would violate the pod's disruption budget.` Then a plain `kubectl delete pod usms-gateway-58854c9ffd-tsv66` succeeds, and `usms-gateway-58854c9ffd-rlvvm` is already `ContainerCreating`. The PDB said nothing.*

![Drain dry run and node still schedulable part b](<../../screenshots/Lab-08/11-pdb-eviction-vs-delete_b.png>)
*`kubectl drain --dry-run=client` lists the four USMS pods it would evict and `node/d3c4fc01636a drained (dry run)`. The node is still `Ready` and not cordoned. A client-side dry run never calls the eviction API, which is why it lists the gateway pod even though a real drain would block on it.*

Both outcomes are correct. A PDB governs the eviction API, which drains, autoscalers and node upgrades use. It does not stop a direct delete, or anything involuntary such as a kernel panic, an OOM or a terminated instance.

### Step 13–14: Rung one, ClusterIP and port-forward, then rung two, NodePort

![ClusterIP unreachable and port-forward working part a](<../../screenshots/Lab-08/12-clusterip-portforward-nodeport_a.png>)
*The three Services are ClusterIP. `curl http://10.43.22.15/` from my machine fails: `as expected: a ClusterIP is not routable from your machine`. Through `kubectl port-forward svc/usms-gateway 18080:80`, `/`, `/enrolment/` and `/results/` return the gateway, enrolment and results JSON. A port-forward is a tunnel through the API server to one pod, it exists only while the command runs, and it is for debugging only.*

![NodePort 30080 created and answering part b](<../../screenshots/Lab-08/12-clusterip-portforward-nodeport_b.png>)
*`usms-results-np` is a second Service on the same `app=usms-results` pods: `NodePort 10.43.190.255 80:30080/TCP`. It still has a ClusterIP. Through the node's InternalIP `172.17.0.2:30080`, a pod in the cluster gets the results JSON. From my machine, `localhost:30080` gives `no answer: 30080 is not published by the node container`. The guide's port-forward fallback returns the results JSON, which proves the Service works, but not that the NodePort is reachable from outside. There is only one node, so "every node answers" had one node to show.*

### Step 15: Rung three, LoadBalancer

`manifests/lab-08/50-service-loadbalancer.yaml` is a complete `usms-gateway` Service, so the type change is in Git. It has three AWS annotations:
- `aws-load-balancer-type: external`: use the AWS Load Balancer Controller.
- `aws-load-balancer-nlb-target-type: ip`: pod IPs as targets. This is Lab 05's `--target-type ip`, for the same reason: pods, like Fargate tasks, have their own addresses.
- `aws-load-balancer-scheme: internet-facing`: put the NLB in Lab 02's public subnets.

![Gateway becomes LoadBalancer and gets an address part a](<../../screenshots/Lab-08/13-gateway-loadbalancer_a.png>)
*`service/usms-gateway configured` reads `LoadBalancer ... <pending> 80:30971/TCP`. Forty-five seconds later it has **`EXTERNAL-IP 172.17.0.2`**, provided by k3s's built-in service load balancer (the `svclb-usms-gateway-d3e493d3-qfv95` pod in `kube-system`). `localhost:8081` and `8082` give no answer, and `docker port` shows the cluster container publishes only `6443/tcp -> 0.0.0.0:6500`.*

![Reaching the external address and the ladder on one line part b](<../../screenshots/Lab-08/13-gateway-loadbalancer_b.png>)
*`EXTERNAL-IP = 172.17.0.2`. Both a busybox pod and `curl` from my own machine get `{"service":"usms-gateway",...}` from that address. The ladder fits on one line: `type=LoadBalancer  clusterIP=10.43.22.15  nodePort=30971  external=172.17.0.2`. LoadBalancer contains NodePort, which contains ClusterIP.*

The `_lb_ports_` tag is stored but not enacted on this build, so 8081/8082 never answered. The EXTERNAL-IP is the node container's address on the Docker bridge, which my Linux host can route to. On real EKS the same manifest would produce an NLB named like `k8s-usms-usmsgat-....elb.us-east-1.amazonaws.com`, billed per hour.

### Step 16: Rung four, Ingress, and Lab 05's ALB

![No IngressClass and traefik disabled part a](<../../screenshots/Lab-08/14-ingress-without-controller_a.png>)
*`kubectl get ingressclass` returns `No resources found`, no ingress controller pod exists, and the k3s container was started with `--disable=traefik`. After `kubectl apply`, `usms-portal-ingress` shows CLASS `<none>`, HOSTS `*`, and an empty ADDRESS. `describe` shows the three rules resolving to real endpoints: `/enrolment` to `usms-enrolment:80 (10.42.0.33:80,10.42.0.34:80)`, `/results` to `usms-results:80 (...)`, and `/` to `usms-gateway:80 (10.42.0.35:80)`. It also lists the five `alb.ingress.kubernetes.io` annotations.*

![No answer on 8081 and no ingress address part b](<../../screenshots/Lab-08/14-ingress-without-controller_b.png>)
*No path answers on `8081`, and `ingress address: none`: `No ingress address: no controller is implementing this object.` The Ingress is a valid, stored object with nothing acting on it. That is the Conceptual result.*

What the AWS Load Balancer Controller would have done with that object is exactly what I did by hand in Lab 05:

| Ingress | Lab 05 `elbv2` call |
| --- | --- |
| `scheme: internet-facing` and the Ingress itself | `create-load-balancer --scheme internet-facing` in the public subnets |
| `target-type: ip`, one per backend | `create-target-group --target-type ip` (three here) |
| `listen-ports: [{"HTTP": 80}]` | `create-listener --port 80` |
| each `paths[]` entry | `create-rule --priority N` with a path-pattern condition |
| `healthcheck-path: /healthz` | the target group's `--health-check-path` |

The order would be create-load-balancer, create-target-group, create-listener, create-rule, and then the controller keeps targets registered as pods come and go. One difference: the Ingress picks the **longest matching prefix**, whereas Lab 05's ALB used explicit numeric priorities.

### Step 17: ECS and EKS, compared with both running

![ECS service, scalable target and policies part a](<../../screenshots/Lab-08/15-ecs-and-eks-side-by-side_a.png>)
*ECS: `usms-enrolment-svc` Desired `2`, Running `2`, `usms-enrolment:1`, attached to `usms-enrolment-tg`, Grace `null` (never stored, as in Lab 05). Its scalable target `service/usms-ecs-cluster/usms-enrolment-svc` is Min `2`, Max `10`, with three policies: two `TargetTrackingScaling` and one `StepScaling`.*

![Deployments, HPA, Services, Ingress and PDBs part b](<../../screenshots/Lab-08/15-ecs-and-eks-side-by-side_b.png>)
*EKS: four Deployments (`usms-loadgen` at `0/0`), the HPA at `cpu: 2%/50%` with 2 replicas, `usms-gateway` `LoadBalancer 172.17.0.2 80:30971/TCP`, `usms-results-np` `NodePort 80:30080/TCP`, the Ingress with no address, and both PDBs.*

My two comparison tables and two paragraphs are in `notes/lab-08-notes.md`. In short:
- **The two "50%" values differ.** ECS measures CPU against the task's reservation; the HPA measures it against the container's request.
- **Where the scaler runs.** Application Auto Scaling runs in AWS outside anything I own. The HPA runs in the control plane, and I can read its reasoning with `describe`.
- **Running out of capacity.** Fargate never runs out of room, but the HPA can leave pods `Pending`.
- **Cost of ten services.** Ten services cost one ALB through one Ingress, but ten NLBs as ten LoadBalancer Services.
- **What actually ran on Floci.** The ECS policy never acted on Floci (Lab 06), but the HPA really scaled.

### Step 18: Restart Floci and check what survives

![Before restart snapshot part a](<../../screenshots/Lab-08/16-persistence-after-restart_a.png>)
*Before: the HPA is `2 8 50`; the PDBs are `usms-enrolment-pdb <none> 1` and `usms-gateway-pdb 1 <none>`; the Service types include `usms-gateway LoadBalancer 30971` and `usms-results-np NodePort 30080`; the Ingress paths are `/enrolment,/results,/`; the node group is `2 4 2`.*

![Floci stopped and started, API server refused part b](<../../screenshots/Lab-08/16-persistence-after-restart_b.png>)
*`FLOCI_STORAGE_MODE=hybrid`. Floci was stopped ("State preserved in /home/dw4ngsh3rs/floci-data") and started again. `kubectl cluster-info` then gets `The connection to the server localhost:6500 was refused`, and `docker ps -a` lists no `usms-eks-cluster` container: Floci removed it on stop.*

![After restart readback part c](<../../screenshots/Lab-08/16-persistence-after-restart_c.png>)
*After: every Kubernetes query is `connection ... refused`. Only the AWS record answers: the node group is still `2 4 2`.*

![Diff reports every Kubernetes object missing part d](<../../screenshots/Lab-08/16-persistence-after-restart_d.png>)
*The diff lists every HPA, PDB, Service and Ingress line as missing and ends `differences above - read them before deciding whether they matter`. It does **not** print `PERSISTENCE PROVEN`.*

This is the same result as Lab 07. In hybrid mode the AWS-side records persist, but the k3s container has no volume and is deleted when Floci stops, so the Kubernetes objects go with it.

### Recovery: rebuild from the repository, then read back again

I used the Lab 07 rebuild procedure, then added this lab's manifests.

![Cluster and node group recreated from the templates part a](<../../screenshots/Lab-08/17-cluster-rebuilt-from-manifests_a.png>)
*The node group and cluster records were deleted (`DELETING`) and the old OIDC provider was removed. `create-cluster` from `templates/lab-07-create-cluster.json` went `CREATING` and then `cluster: ACTIVE`, and `create-nodegroup` from its template returned `usms-eks-nodes ACTIVE`.*

![Lab 07 manifests reapplied part b](<../../screenshots/Lab-08/17-cluster-rebuilt-from-manifests_b.png>)
*`update-kubeconfig` updated context `usms-eks`, and a new node `70ce684e5aef` was `Ready` in 7 seconds. `kubectl apply -f manifests/lab-07/` recreated the namespace, ConfigMaps, Deployments, Services, Secret and ServiceAccount. Then I re-ran the one imperative step from Lab 07, `kubectl set env ... --from=secret` (`env updated`), and registered the new issuer as `arn:aws:iam::000000000000:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/908C96D1CDD547C3956DFAAE78E1EB11`.*

![Node labelled and Lab 08 manifests reapplied part c](<../../screenshots/Lab-08/17-cluster-rebuilt-from-manifests_c.png>)
*The node label had to be applied by hand again (`node/70ce684e5aef labeled`), because it is the one imperative step in this lab. Then five Lab 08 manifests were applied: the HPA, both PDBs, `usms-results-np`, `usms-gateway configured` (to LoadBalancer) and the Ingress. `20-loadgen.yaml` was left out on purpose so the rebuild would not start load. All three Deployments rolled out.*

![Read back after the rebuild part a](<../../screenshots/Lab-08/18-readback-after-rebuild_a.png>)
*After the rebuild: HPA `2 8 50`, both PDBs as before, `usms-results-np NodePort 30080`, Ingress paths `/enrolment,/results,/`, node group `2 4 2`.*

![Diff shows only the allocated nodePort part b](<../../screenshots/Lab-08/18-readback-after-rebuild_b.png>)
*The diff against the original before-file has exactly one line: `usms-gateway LoadBalancer 30971` became `31345`. That nodePort is auto-allocated, so a new Service gets a new one. The pinned `30080` is unchanged, which is the argument for pinning. The gateway again shows `type=LoadBalancer  clusterIP=10.43.106.27  nodePort=31345  external=172.17.0.2`, and the HPA reads `cpu: 2%/50%`.*

The restart also stopped `usms-web-01` again, as in Labs 05 to 07, and I started it with `aws ec2 start-instances`. ECS came back at 2/2.

### Step 19 and Section 15: `configs/lab-08.env`, then clean-up

![lab-08.env generated part a](<../../screenshots/Lab-08/19-lab08-env-and-cleanup_a.png>)
*The unquoted heredoc looks up every value live: the HPA bounds, the PDB names, the NodePort and gateway Service, the Ingress class and the node group size.*

![Values checked and temporary objects removed part b](<../../screenshots/Lab-08/19-lab08-env-and-cleanup_b.png>)
*The empty-value check flags only `20:export USMS_INGRESS_CLASS=`. That is one of the guide's expected exceptions, because no ingress controller is running. The summary reads `hpa: 2..8 at 50% cpu, scale-in window 300s` and `nodeport: 30080   gateway: LoadBalancer`, and there are `19` exports. The Section 15 clean-up found no `usms-loadgen` left (the rebuild had already lost it), no Exercise 3 objects, no `.bak` files and no cordoned nodes. Exactly five pods remain: two enrolment, one gateway, two results.*

The node group values in the file are `2 / 4 / 2` because that is what is actually true after Step 10 failed.

### Section 8: Verification and smoke test

![verify-lab-08 environment, autoscaling, PDB and exposure checks part a](<../../screenshots/Lab-08/20-verify-lab08-and-smoke-test_a.png>)
![verify-lab-08 data plane and git hygiene part b](<../../screenshots/Lab-08/20-verify-lab08-and-smoke-test_b.png>)
*Every Environment, Lab 07 dependency, autoscaling, disruption budget and exposure ladder check is `ok`, including the `_lb_ports_` tag, `HPA scale-in stabilisation window is 300s`, `usms-results-np is pinned to node port 30080`, `usms-gateway kept a nodePort` and `Ingress declares three paths`. The single failure is `FAIL node group maxSize was raised to 6` (Step 10). The file and Git checks pass, including `every Lab 08 manifest passes a client-side dry run`. Result: **`PASS=33  FAIL=1`**.*

![Smoke test through the gateway part c](<../../screenshots/Lab-08/20-verify-lab08-and-smoke-test_c.png>)
![HPA, PDBs, Services, Ingress and verify-lab-07 part d](<../../screenshots/Lab-08/20-verify-lab08-and-smoke-test_d.png>)
*From inside the cluster, `/`, `/enrolment/` and `/results/` through `usms-gateway` all return JSON (enrolment from node `70ce684e5aef`), and the run ends `SMOKE TEST PASSED`. The final state is the HPA at `2%/50%` with 2 replicas, the PDBs allowing `1` and `0`, `usms-gateway LoadBalancer 172.17.0.2 80:31345/TCP`, `usms-results-np 80:30080/TCP` and the Ingress. `verify-lab-07.sh` is still `PASS=30 FAIL=0`.*

`verify-lab-05.sh` (47/2) and `verify-lab-06.sh` (39/3) give the same results as before this lab. `scripts/cleanup/lab-08-cleanup.sh` was written and passed `bash -n`, but was not run.

### Step 20: Commit

![git status and the ignore rule part a](<../../screenshots/Lab-08/21-commit-proof_a.png>)
*Before adding: `manifests/lab-07/20-enrolment.yaml` is modified (the `nodeSelector`), and the Lab 08 manifests, env, scripts and notes are untracked. Nothing under `outputs/` is listed. `git check-ignore -v` names the rule that protected me: `.gitignore:8:outputs/*`. After `git add`, 12 paths are staged. The PDF and `screenshots/Lab-08/` are deliberately left out.*

![Commit created part b](<../../screenshots/Lab-08/21-commit-proof_b.png>)
![Commit file list and outputs check part c](<../../screenshots/Lab-08/21-commit-proof_c.png>)
*`5dcfd98 Lab 08: EKS scaling and service exposure` sits above Lab 07's `606025e`. `git show --stat` lists `configs/lab-08.env`, `manifests/lab-07/20-enrolment.yaml` (+2), the six `manifests/lab-08/*.yaml`, `notes/lab-08-notes.md` and the three scripts: `12 files changed, 569 insertions(+)`. `git ls-files` finds exactly one path under `outputs/`, and it is `outputs/.gitkeep`.*

## 6. Results and Evidence

### 6.1 CLI/SDK Output

| Checkpoint | What had to be true | Result |
|---|---|---|
| 1 (Step 2) | Floci up, `verify-lab-07` `FAIL=0`, CPU request present, `_lb_ports_` present, baseline saved | All true (screenshot 01) |
| 2 (Step 5) | `kubectl scale` writes one field with no new ReplicaSet; endpoints grow on readiness; drift created and resolved; `kubectl diff` exit 1 understood; back at 2/2 | All true (screenshots 02, 03) |
| 3 (Step 9) | HPA `autoscaling/v2` with `behavior`; replicas observed moving under load and returning after 300 s | All true, observed 2 → 3 → 2 with real metrics (screenshots 06–08) |
| 4 (Step 12) | Node group 2/6/3; `nodeSelector` enforcement proven; both PDBs; eviction refused and delete allowed | **Partly met:** node group resize fails on Floci 1.7.0 (screenshot 09); everything else true (screenshots 10, 11) |
| 5 (Step 14) | ClusterIP unroutable from the host; port-forward used; NodePort 30080 answering on the node address | True, with the NodePort reached in-cluster and through the fallback, not from the host (screenshot 12) |
| 6 (Step 16) | Gateway `LoadBalancer` with clusterIP, nodePort and an external address; Ingress with three prefix paths; annotation mapping written | All true; the Ingress has no address because there is no controller (screenshots 13, 14) |
| 7 (Step 18) | `PERSISTENCE PROVEN` after a Floci restart | **Not met by the cluster:** k3s was removed again. After rebuilding from Git, everything is identical except the auto-allocated gateway nodePort (screenshots 16–18) |
| 8 (Step 20) | 19 exports; manifest updated with the `nodeSelector`; nothing from `outputs/` staged; `check-ignore` rule named | All true, commit `5dcfd98` (screenshots 19, 21) |

The consolidated proof is `verify-lab-08.sh` at `PASS=33 FAIL=1`, where the one failure is the node group resize, plus `SMOKE TEST PASSED` (screenshot 20).

### 6.2 AWS Console Verification

Floci has no AWS Management Console. On real AWS:
- The EKS console's Compute tab would show the node group's scaling configuration, which is what `describe-nodegroup` returns in screenshot 09.
- The EC2 Load Balancers page would show the NLB and ALB that the LoadBalancer Service and the Ingress would create.

Here the evidence is the `aws eks describe-*` calls and the `kubectl get`/`describe` output in the screenshots, which read the same APIs.

## 7. Analysis and Discussion

**What was real, what was recorded and what was conceptual.** The guide asks me to sort every claim into these three groups.
- **Observed:** hand and declarative scaling, endpoints growing on readiness, the HPA scaling 2 → 3 and back after five minutes, QoS classes, `nodeSelector` enforcement, the PDB refusing an eviction, port-forward, the NodePort answering on the node's address, and a LoadBalancer Service getting an address that answers from my machine.
- **Recorded but not enacted:** the `_lb_ports_` tag, the AWS annotations on the Service and the Ingress, the Ingress itself, and the node group's scaling configuration (which could not even be recorded, because the update failed).
- **Conceptual:** the AWS Load Balancer Controller, Cluster Autoscaler, Karpenter, custom metrics and the cost.

**Floci limitations I hit, with what real AWS does:**

| Floci 1.7.0 | Real AWS |
|---|---|
| `UpdateNodegroupConfig` is routed to the S3 handler and fails with `InvalidArgument` | Returns an `InProgress` Update; the ASG changes and instances join |
| Node group labels do not reach the node; I labelled it by hand | Every node in the group carries the labels |
| One k3s node; `desiredSize` would never start a second | The ASG launches EC2 instances |
| `_lb_ports_` stored, but only port 6500 is published | An NLB with a DNS name in the public subnets |
| `--disable=traefik`, no IngressClass, the Ingress never gets an address | The AWS Load Balancer Controller creates an ALB |
| NodePort not published to the host | Reachable on every node, subject to security groups |
| The k3s container is deleted on Floci stop | The control plane and etcd persist |
| IRSA not functional, so no Cluster Autoscaler, Karpenter or LB controller | All three are standard |

Where Floci was nicer than reality: pods started in seconds, metrics-server came for free, and nothing cost money. On real AWS, ten LoadBalancer Services are ten hourly NLBs, and `maxReplicas` / `maxSize` are spending limits.

**Problems that were mine to untangle:**
- **The scale-out went to 3, not the guide's 4.** I first thought the `behavior` block should have doubled it. Working the formula by hand showed that the recommendation was 3, and that the policies only cap how fast replicas may grow. They are a speed limit, not a target.
- **Screenshots taken too early.** In the Guaranteed-QoS run, my first pod listing showed both the old and the new gateway pod, because the old one was still terminating. I re-ran it with a wait until only one pod remained, and the screenshot is the second run. The `nodeSelector` screenshot was also re-taken, because my first `grep` missed the `FailedScheduling` event.
- **The node group failure.** I captured the request URL with `--debug` to show that the CLI was right and Floci was routing the call to S3, rather than assuming my command was wrong.
- **The rebuild.** I left `20-loadgen.yaml` out of the re-apply. Applying the whole folder would have started the load generator and scaled the HPA during the read-back.

**The persistence result, again.** Lab 07 taught me that Git is the real backup for this cluster. This lab confirmed it with more objects. The HPA, two PDBs, two new Service shapes and an Ingress all came back from six files. Only two things needed repeating by hand: the node label and Lab 07's `set env`, both imperative. The one value that changed, the gateway nodePort, changed because I had not pinned it.

## 8. Reflection

The most useful thing in this lab was watching the HPA hold three pods for five minutes while CPU sat at 2%. Before that, "stabilisation window" was a field name. Now it is a decision I can defend: adding a pod costs a little, and removing one too early during enrolment week costs a failed registration. Lab 06 made the same decision with `ScaleInCooldown`, but on Floci I never saw it act. Here I did, and the HPA told me its reasons in plain words.

The second thing was the two control loops. The HPA happily wrote `replicas: 3`, and if the node had been full, the third pod would simply have sat `Pending`. Nothing connected that to the node group, and on this build I could not even change the node group by hand. On real EKS that gap is filled by Cluster Autoscaler or Karpenter, and I now understand why every production EKS cluster needs one.

The exposure ladder made the Lab 05 work feel different. The five annotations on one Ingress object replace the load balancer, target groups, listener and rules I built with `aws elbv2`. That is not new infrastructure. It is the same ALB, declared instead of commanded. For USMS I still prefer ECS, for the reasons in my notes, but I can now say exactly what EKS would give me in exchange for its extra layers.

## 9. Conclusion

USMS's enrolment service on EKS now scales itself. `usms-enrolment-hpa` (`autoscaling/v2`, 2 to 8 pods at 50% of the 50m CPU request) went from 2 to 3 pods under real load and back to 2 after its 300-second window. The service is pinned to `workload=usms` nodes, with enforcement proven, and is protected by `usms-enrolment-pdb`. The gateway is protected by `usms-gateway-pdb`, and I showed that the eviction API respects a PDB while `kubectl delete` does not.

The exposure ladder is complete:
- ClusterIP;
- port-forward;
- `usms-results-np` on NodePort 30080;
- `usms-gateway` as a LoadBalancer with an external address that answers;
- `usms-portal-ingress`, with three prefix paths mapped one-to-one onto Lab 05's `elbv2` calls.

Two things did not work on Floci 1.7.0, and both are recorded rather than hidden. Resizing the node group failed because the call is routed to S3; this matches the course's Known Issues page, and I did its alternative. The Floci restart deleted the k3s cluster again; I rebuilt it from Git, and the configuration came back identical apart from one auto-allocated port.

I finished with `verify-lab-08.sh` at `PASS=33 FAIL=1`, a passing smoke test, 19 values in `configs/lab-08.env`, and commit `5dcfd98`. `verify-lab-07.sh` is still 30/0, and Labs 05 and 06 are unchanged.

## 10. Appendix

**Key resource identifiers from this lab:**

| Resource | Value |
|---|---|
| HPA | `usms-enrolment-hpa`, autoscaling/v2, min 2 / max 8, CPU 50% of `50m`, scale-up window 0 s (Percent 100 / Pods 2 per 15 s, Max), scale-down window 300 s (Pods 1 per 60 s, Min) |
| Observed scaling | 2 → 3 at 59% (11:24:56Z); 3 → 2 at 11:33:16Z, after the load was removed at 11:27:38Z |
| PDBs | `usms-gateway-pdb` minAvailable 1 (0 allowed); `usms-enrolment-pdb` maxUnavailable 1 (1 allowed) |
| NodePort Service | `usms-results-np`, `80:30080/TCP`, selector `app=usms-results` |
| LoadBalancer Service | `usms-gateway`, nodePort `31345` (was `30971` before the rebuild), EXTERNAL-IP `172.17.0.2` from k3s servicelb |
| Ingress | `usms-portal-ingress`: `/enrolment`, `/results`, `/`; no class, no address |
| Node selector | `workload=usms` on `usms-enrolment`; node `70ce684e5aef` labelled `workload=usms`, `tier=app` by hand |
| Node group | `usms-eks-nodes`, still min 2 / max 4 / desired 2 (the resize to 2/6/3 failed) |
| OIDC issuer (current) | `https://oidc.eks.us-east-1.amazonaws.com/id/908C96D1CDD547C3956DFAAE78E1EB11` |
| Load generator | `usms-loadgen`, 3 × busybox, deleted at the end (lost in the rebuild; still in `20-loadgen.yaml`) |
| Commit | `5dcfd98` |

**Files produced for this lab:**
- `manifests/lab-08/10-hpa-enrolment.yaml` … `60-ingress.yaml`: the HPA, load generator, PDBs, NodePort Service, LoadBalancer gateway Service and Ingress.
- `manifests/lab-07/20-enrolment.yaml`: now carries `nodeSelector: workload: usms`.
- `configs/lab-08.env`: 19 exports. `USMS_INGRESS_CLASS` is empty because there is no controller.
- `notes/lab-08-notes.md`: deviations, the "Your turn" answers, the HPA arithmetic and quoted reasons, the annotation-to-`elbv2` table, the two Step 17 tables and paragraphs, the Section 14 answers, the persistence result, Exercise 5 and the limitations.
- `scripts/utilities/hpa-watch.sh`: the read-only HPA watcher.
- `scripts/utilities/verify-lab-08.sh`: automated check (33/34; the failure is the node group resize).
- `scripts/cleanup/lab-08-cleanup.sh`: end-of-course teardown, syntax-checked only and never run.
- `outputs/lab-08-*.txt|json`: evidence files (baseline, node group before/after, eviction body, before/after restart, after rebuild), git-ignored. They include Exercise 5's `lab-08-scaling-evidence.json` and `lab-08-lab06-readiness.txt`, which Lab 10 reads.
