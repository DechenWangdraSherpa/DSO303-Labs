# Lab 07 notes

**Support path: A (`aws eks` throughout).** `eks-support-probe.sh` answered `eks list-clusters : OK`, `kubectl` v1.36.5 is installed, `k3d` is not. Floci 1.7.0 backs `create-cluster` with one `rancher/k3s` container (`floci-floci-course-eks-usms-eks-cluster`, API published on `https://localhost:6500`, not the guide's 6443). The node group is a record only: `kubectl get nodes` shows the single k3s server node, which is untainted, so pods schedule on it and no taint workaround was needed.

## Deviations from the lab text, and why

- **k3s would not start (Step 11).** The container exited with `inotify_init: too many open files`, because the host allows 128 inotify instances per user and my three DSO202 kind node containers were holding most of them. I stopped `dso202-control-plane`, `dso202-worker` and `dso202-worker2` (restart them with `docker start`), then started the k3s container again. Raising `fs.inotify.max_user_instances` to 512 with sudo is the permanent fix.
- **kubeconfig.** `update-kubeconfig --alias usms-eks` added the context and made it current. My previous context was `kind-pet-portal`; the original file is backed up at `~/.kube/config.before-lab07.bak`.
- **Server version.** k3s reports `v1.34.1+k3s1` although the EKS record says `1.30`. Floci stores the requested version but runs whatever k3s image it has.
- **`kubectl set env --from=secret` (Step 17).** This kubectl writes two `env` entries with `secretKeyRef` instead of an `envFrom.secretRef`, so the `envFrom` jsonpath shows only the ConfigMap. `describe` and `printenv` both show the two `ENROLMENT_*` keys coming from `usms-enrolment-secret`, so the result is the same.
- **`kubectl get endpoints`** prints a deprecation warning (v1 Endpoints is deprecated in v1.33+). It still answers; EndpointSlices are the replacement.
- **The pod-delete "Your turn"** was re-run after Step 17 because the first tally ran before the replacement pod was Ready. The screenshot is the second run.
- **Step 18 annotate.** `kubectl annotate` on the Deployment's metadata returned `successfully rolled out` immediately and changed nothing, as the guide warned. `rollout restart` did the roll.
- **Step 22 persistence: not proven for the Kubernetes half.** See below.
- **Secret manifest.** I left `manifests/lab-07/50-secret.yaml` committed. Its values are dummies, and the rebuild after Step 22 showed why a declared Secret is useful: `kubectl apply -f manifests/lab-07/` restored it. In any real repository it would live in `outputs/` or a secrets manager.

## Step 9 "Your turn"

`cluster.version` is `1.30`; `cluster.identity.oidc.issuer` was `https://oidc.eks.us-east-1.amazonaws.com/id/606B2D69F5954BD697154C2174D0E285` for the first cluster and `.../1B68171CD0804AA4B1DBE960E40AC051` after the rebuild. The issuer is per cluster, which is why IRSA providers are registered per cluster.

## Step 16 "Your turn" - who replaced the pod

The ReplicaSet `usms-enrolment-7d8557c58d` created the replacement (`SuccessfulCreate ... Created pod: usms-enrolment-7d8557c58d-f6l58`). Not the Deployment, which only manages ReplicaSets, and not me. Twelve requests through the gateway all succeeded, 6 and 6 across the old and the new pod.

## Step 18 "Your turn" - image roll of usms-results

`kubectl set image deployment/usms-results results=nginx:1.27`, then `rollout undo`. `rollout history` shows **two revisions** afterwards (2 and 3: undo re-numbers the old template as the newest), and the Deployment is back on `nginx:1.27-alpine`. Peak pod count was **3**. With 2 replicas the default 25% / 25% rounds to maxSurge 1 and maxUnavailable 0 (surge rounds up, unavailable rounds down), so the roll had exactly the same shape as `usms-enrolment`'s explicit 0 / +1: one new pod up and Ready before each old one was terminated. The defaults only differ from `maxUnavailable: 0` at 4 or more replicas.

## Step 20 - ECS and Kubernetes, compared with both running

| Question | ECS answer | Kubernetes answer |
| --- | --- | --- |
| What holds the container spec? | Task definition `usms-enrolment:1` (immutable revisions) | The Deployment's pod template (`spec.template`) |
| What keeps N copies alive? | The ECS service scheduler, `desiredCount` 2 | The ReplicaSet the Deployment owns, `replicas` 2 |
| What gives it a stable name? | The ALB DNS name and target group (Lab 05) | A ClusterIP Service: `usms-enrolment.usms.svc.cluster.local` |
| How does another service find it? | Through the ALB (or Cloud Map, not used) | CoreDNS resolves the Service name; kube-proxy picks an endpoint |
| What does a rolling update create? | A new deployment pointing at a new task definition revision | A new ReplicaSet with a new pod-template hash |
| Where does rollback state live? | Older task definition revisions; you redeploy one | Old ReplicaSets scaled to 0, up to `revisionHistoryLimit` 5 |
| Which IAM role does the app code use? | The task role `usms-ecs-task-role`, per task | The node role (`usms-eks-node-role`) unless IRSA / Pod Identity maps a ServiceAccount to a role |
| What would I have to change to move to another cloud? | Nearly everything: task definitions, services and the ALB are AWS-only | Manifests move; IAM roles, VPC, node groups and load balancer annotations do not |

For USMS I would stay on ECS for the enrolment service today: it is three small HTTP services, ECS needs no control plane to run or upgrade, and the task role gives per-service IAM with no extra machinery. Kubernetes earns its cost when there are many services and teams, or a real need for portability and its ecosystem (HPA on custom metrics, service mesh), which USMS does not have yet.

## Step 21 - IRSA, which of the six steps completed

| # | Step | Result on Floci 1.7.0 |
|---|---|---|
| 1 | Cluster publishes an OIDC issuer | Yes, `cluster.identity.oidc.issuer` is filled in |
| 2 | Register it in IAM as an OIDC provider | Yes, `create-open-id-connect-provider` returned an ARN and `list-open-id-connect-providers` shows it |
| 3 | Role trusting that provider for `system:serviceaccount:usms:usms-enrolment-sa` | Not attempted: IAM trust is never evaluated on Floci, so it would prove nothing |
| 4 | Annotate the ServiceAccount with the role ARN | ServiceAccount created, not annotated (no role) |
| 5 | Webhook injects the projected token and env vars | Not observable (Floci writes a `token-webhook.yaml`, but nothing uses it here) |
| 6 | SDK calls `AssumeRoleWithWebIdentity` | Not observable; the issuer URL is not publicly reachable, so real STS could never fetch it |

After the rebuild I deleted the provider for the old issuer and registered the new one.

## Step 22 - persistence: half proven

The AWS-side records survived the Floci stop/start: `list-clusters` re-derived `usms-eks-cluster` (`ACTIVE 1.30`) and `list-nodegroups` re-derived `usms-eks-nodes`. The Kubernetes side did not: `docker compose stop` made Floci remove the k3s container, which had no volume, and `floci-up.sh` did not recreate it. `kubectl` had nothing to talk to, so the namespace, deployments, services, ConfigMaps and the Secret were all gone. The `diff` reported the differences instead of `PERSISTENCE PROVEN`. `FLOCI_STORAGE_MODE` was `hybrid`, so this is not the memory-mode trap the guide warns about.

Recovery took about a minute and used only committed files: delete the node group and cluster records, `create-cluster` and `create-nodegroup` from the two templates, `update-kubeconfig`, then `kubectl apply -f manifests/lab-07/`. The only thing the manifests did not bring back was the Step 17 `kubectl set env` change, which was imperative; I re-ran it. That is the lesson: anything changed with `kubectl set` / `annotate` / `scale` instead of in a file is lost when the cluster is rebuilt.

Side effects of the restart, as in Labs 05 and 06: `usms-web-01` stopped (started again) and the ECS tasks were replaced (2/2 again). `verify-lab-05.sh` 47/2 and `verify-lab-06.sh` 39/3 are unchanged.

## verify-lab-07.sh: PASS=30 FAIL=0

Same one change as Labs 04 to 06: "no secret is tracked by git" allows `outputs/.gitkeep`. Smoke test through the gateway: `SMOKE TEST PASSED`.

## Floci limitations hit (and what real AWS does)

| Limitation on Floci 1.7.0 | Real AWS |
|---|---|
| The node group is a record; one k3s server node runs every pod | Real EC2 instances in the private subnets, in an Auto Scaling group |
| k3s runs v1.34.1 whatever `version` says (1.30 requested) | The control plane runs the requested version |
| Pods get k3s addresses (10.42.x.x), Services 10.43.x.x, unrelated to `10.0.0.0/16` | VPC CNI gives pods real VPC addresses from the subnets |
| The k3s container is removed on Floci stop; Kubernetes state does not survive | The control plane and etcd are managed and persistent |
| Cluster and node IAM roles stored, never evaluated | A missing permission fails cluster creation or node registration |
| OIDC issuer not reachable; IRSA cannot complete | IRSA works end to end, or EKS Pod Identity |
| Host inotify limits shared with every other local cluster | Not applicable |
