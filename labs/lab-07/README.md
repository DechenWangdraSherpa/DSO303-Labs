# Lab 7 – Running USMS Microservices on Amazon EKS

**Name:** Dechen Wangdra Sherpa
**Student Number:** 02230281
**Course:** DSO303 – Cloud Native Design Patterns
**Lab:** Lab 7 – Amazon Elastic Kubernetes Service (EKS)

---

## 1. Aim / Objective

The aim of this lab was to run part of USMS on Kubernetes instead of ECS. I needed:
- an EKS cluster role and a node role, with Lab 01's `USMSStudentDataReadWrite` on the node role;
- a cluster security group;
- the cluster `usms-eks-cluster` across all four Lab 02 subnets, and a managed node group `usms-eks-nodes` in the two private subnets;
- `kubectl` pointed at the cluster, and a namespace `usms` holding three microservices (gateway, enrolment and results), each a Deployment behind a ClusterIP Service.

I then had to prove several things:
- the services find each other by DNS;
- a Secret is encoding, not encryption;
- a rolling update and a rollback work;
- three common pod failures can be diagnosed;
- IRSA gets as far as this build allows;
- the whole thing survives a Floci restart.

Finally I had to record every identifier in `configs/lab-07.env` and commit.

## 2. Introduction

Labs 04 to 06 ran the enrolment service on ECS. EKS does the same job, keeping N copies of a container running behind a stable name, using a different and much larger toolkit: Kubernetes. EKS has two halves, and it helps to keep them apart:

- **The control plane** (API server, scheduler, controllers, etcd) is run by AWS. I created it with `aws eks create-cluster` and never touched it again.
- **The data plane** is the worker nodes that run pods. A managed node group is EC2 instances in my private subnets, joined to the cluster.

After the cluster exists the tool changes from the AWS CLI to `kubectl`, and the objects change too:

| Object | Role |
|---|---|
| **Deployment** | Declares "2 copies of this pod template" and owns ReplicaSets. |
| **ReplicaSet** | Keeps the count. |
| **Service** | Gives the pods a stable virtual IP and a DNS name. |
| **ConfigMap** and **Secret** | Feed configuration in. |

All of these are written as YAML files in `manifests/lab-07/` and applied, so the repository describes the cluster's contents.

Floci answers the `aws eks` calls and backs the cluster with a real k3s Kubernetes server in a local container, so the Kubernetes half of this lab is genuinely real. The node group, the IAM roles and the VPC wiring are records only. The biggest surprise was the restart test in Step 22. I have kept it in, because it changed how I think about the manifests.

## 3. Use Case

USMS is a set of small services: a gateway that students hit, an enrolment service and a results service. On Kubernetes:
- Each service runs as its own Deployment with two replicas (one for the gateway), so one pod can die without an outage.
- The gateway reaches the other two by name (`usms-enrolment.usms.svc.cluster.local`), never by address, so pods can be replaced or scaled freely.
- Shared settings (environment, campus, version) live in one ConfigMap.
- The enrolment service's API token and database password live in a Secret, not in the image.
- When the enrolment team ships version 1.1.0, the Deployment rolls it out one pod at a time with no drop in capacity.
- If the release is bad, one command rolls it back.

Lab 08 will add a HorizontalPodAutoscaler on top of the CPU request declared here.

## 4. System Architecture / Design

```
  AWS side (aws eks / iam / ec2)                       Kubernetes side (kubectl)
  ------------------------------                       --------------------------
  usms-eks-cluster-role  -> trusts eks.amazonaws.com    namespace usms  (labels project/tier/lab)
     USMSEKSClusterPolicy                                 |
  usms-eks-node-role     -> trusts ec2.amazonaws.com      +-- usms-gateway    Deployment 1  -> Service ClusterIP
     USMSEKSNodePolicy + USMSStudentDataReadWrite         |      nginx proxy: /enrolment/ -> usms-enrolment.usms.svc...
  usms-eks-cluster-sg  tcp/443 from 10.0.0.0/16           |                   /results/   -> usms-results.usms.svc...
                                                          +-- usms-enrolment  Deployment 2  -> Service ClusterIP
  usms-eks-cluster  v1.30  ACTIVE                         |      RollingUpdate maxUnavailable 0 / maxSurge 1
    subnets: public a/b + private a/b (Lab 02)            |      requests cpu 50m / mem 32Mi, readiness + liveness
    endpoint https://localhost:6500  (k3s on Floci)       |      envFrom usms-app-config + usms-enrolment-secret
    tag _lb_ports_ 8081,8082  (for Lab 08)                +-- usms-results    Deployment 2  -> Service ClusterIP
  usms-eks-nodes   min 2 / max 4 / desired 2              |      default strategy 25% / 25%, readiness only
    private subnets a/b only, t3.small, AL2023            +-- ConfigMaps: usms-app-config (4 keys) + one nginx template per service
                                                          +-- Secret usms-enrolment-secret, ServiceAccount usms-enrolment-sa
  IAM OIDC provider for the cluster's issuer (IRSA steps 1-2)

  CoreDNS resolves <service>.usms.svc.cluster.local -> ClusterIP; kube-proxy spreads it over the ready pods
```

The key design choices were:

- **Nodes in private subnets only.** The control plane spans all four subnets, but worker nodes get no public addresses. This is the same rule as the ECS tasks in Lab 04.
- **Readiness and liveness are different checks.**
  - Readiness decides whether a pod is in the Service.
  - Liveness decides whether it gets restarted.

  The enrolment service has both. The results service has only readiness.
- **`maxUnavailable: 0`, `maxSurge: 1` for enrolment.** A roll never drops below two ready pods. This is the count-based equivalent of Lab 04's `minimumHealthyPercent 100`.
- **Names, not addresses.** The gateway's nginx configuration holds two hostnames and no IPs. Service ClusterIPs never move, and pods can come and go underneath.
- **A CPU request on every container.** Lab 08's HPA measures utilisation as a percentage of the request, so without one it cannot scale.

## 5. Implementation Procedure

### Step 1–2: Confirm the ground, and probe what this build supports

I sourced the course env files, checked the account, re-ran the Lab 02 and Lab 04 verification scripts, listed the four subnets this lab builds on, and ran the guide's `eks-support-probe.sh`.

![Environment check and EKS support probe part a](<../../screenshots/Lab-07/01-environment-and-support-path_a.png>)
![Environment check and EKS support probe part b](<../../screenshots/Lab-07/01-environment-and-support-path_b.png>)
*The account is `000000000000` (Floci). Lab 02 passes (`PASS=33 FAIL=0`), and Lab 04 shows its one expected failure from the Lab 05 cutover (`PASS=37 FAIL=1`). The four subnets are `usms-public-subnet-a/b` and `usms-private-subnet-a/b`, across `us-east-1a` and `us-east-1b`. The probe answers `eks list-clusters : OK` and finds `kubectl` (v1.36.5) but no `k3d`, so the verdict is `PATH A - use aws eks throughout`.*

I recorded support path A at the top of `notes/lab-07-notes.md`.

### Step 4–7: Trust policies, permissions, the two roles and the cluster security group

I wrote four policy documents from the guide:
- a trust policy for `eks.amazonaws.com`;
- a trust policy for `ec2.amazonaws.com`;
- `USMSEKSClusterPolicy` and `USMSEKSNodePolicy`, local stand-ins for the AWS managed EKS policies.

I created `usms-eks-cluster-role` and `usms-eks-node-role`, and attached Lab 01's `USMSStudentDataReadWrite` to the node role as well. Then I created `usms-eks-cluster-sg` in `usms-vpc`, admitting HTTPS from the VPC only.

![Policy documents and cluster role part a](<../../screenshots/Lab-07/02-iam-roles-and-security-group_a.png>)
![Cluster role and security group part b](<../../screenshots/Lab-07/02-iam-roles-and-security-group_b.png>)
![Node role with Lab 01 policy part c](<../../screenshots/Lab-07/02-iam-roles-and-security-group_c.png>)
![Both roles and the security group summarised part d](<../../screenshots/Lab-07/02-iam-roles-and-security-group_d.png>)
*All four policy documents are valid JSON. `usms-eks-cluster-role` trusts `eks.amazonaws.com` and carries `USMSEKSClusterPolicy`. `usms-eks-node-role` trusts `ec2.amazonaws.com` and carries `USMSEKSNodePolicy` and `USMSStudentDataReadWrite`; it now appears next to `usms-ec2-app-role` and `usms-ecs-task-role` as a third role holding that policy. The security group `sg-a69b9f7c3d0f9f5f8` is in `vpc-6ffa2a93` and allows only port `443` from `10.0.0.0/16`.*

### Step 8–9: Create the cluster

I generated `templates/lab-07-create-cluster.json` with an unquoted heredoc, so the role ARN and the four subnet IDs are real values, and checked that no literal `$USMS` text was left in it. I created the cluster as Lab 01's `usms-developer-role`, then dropped back to my own identity and waited for it to become `ACTIVE`.

![Cluster template and create-cluster part a](<../../screenshots/Lab-07/03-cluster-created_a.png>)
![Cluster becomes ACTIVE part b](<../../screenshots/Lab-07/03-cluster-created_b.png>)
*The template is valid JSON with `0` unexpanded variables. The caller is `assumed-role/usms-developer-role/floci-session`, `create-cluster` returns `usms-eks-cluster CREATING 1.30`, and after `unset` the identity is back to `root`. The wait ends at `ACTIVE`.*

### Step 9–10: Read the cluster back, and create the managed node group

![Cluster description part a](<../../screenshots/Lab-07/04-cluster-and-nodegroup-active_a.png>)
![lb ports tag, OIDC issuer and node group template part b](<../../screenshots/Lab-07/04-cluster-and-nodegroup-active_b.png>)
![Node group created part c](<../../screenshots/Lab-07/04-cluster-and-nodegroup-active_c.png>)
![Node group description part d](<../../screenshots/Lab-07/04-cluster-and-nodegroup-active_d.png>)
*The cluster is `ACTIVE`, version `1.30`, endpoint `https://localhost:6500`, and uses `usms-eks-cluster-role`, all four subnets, `sg-a69b9f7c3d0f9f5f8` and `vpc-6ffa2a93`, with the `_lb_ports_` tag `8081,8082` that Lab 08 needs. The "Your turn" values are version `1.30` and the OIDC issuer `https://oidc.eks.us-east-1.amazonaws.com/id/606B2D69...`. The node group `usms-eks-nodes` is `ACTIVE` with min 2 / max 4 / desired 2. It is in the two private subnets only (`subnet-1150e689`, `subnet-47a7fe37`), uses `usms-eks-node-role`, and carries the labels `tier=app` and `workload=usms`, with `t3.small` and `AL2023_x86_64_STANDARD`.*

### Step 11–12: Point `kubectl` at the cluster, and create the namespace

`aws eks update-kubeconfig --name usms-eks-cluster --alias usms-eks` wrote the context and made it current. On the first attempt `kubectl` got `connection refused`. The k3s container behind the cluster had exited with `inotify_init: too many open files`. My machine allows 128 inotify instances per user, and the three node containers of a kind cluster from another course were using most of them. I stopped those three containers (they can be started again with `docker start`) and started the k3s container again.

![kubectl context, cluster info and nodes part a](<../../screenshots/Lab-07/05-kubectl-connected-and-namespace_a.png>)
![Node count, permissions, API resources and namespace manifest part b](<../../screenshots/Lab-07/05-kubectl-connected-and-namespace_b.png>)
*The current context is `usms-eks`, pointing at `arn:aws:eks:us-east-1:000000000000:cluster/usms-eks-cluster`. `cluster-info` shows the control plane, CoreDNS and metrics-server on `https://localhost:6500`. `get nodes` shows one node, `Ready`, role `control-plane`, `v1.34.1+k3s1`. There is `1` node, `auth can-i create deployments --all-namespaces` answers `yes`, and namespaced resources include `configmaps`, `pods`, `secrets` and `serviceaccounts`. `namespace/usms created`, and the context default namespace reads back as `usms`.*

![Namespace labels and empty namespace part c](<../../screenshots/Lab-07/05-kubectl-connected-and-namespace_c.png>)
*`usms` is `Active` with the labels `lab=07`, `project=usms` and `tier=app`, and is empty (`No resources found in usms namespace.`).*

There are two differences from the guide's expected output:
- **One node, not three.** On Floci the managed node group is a record. The single k3s server node runs every pod, and it is not tainted, so pods schedule on it and the taint workaround was not needed.
- **A newer version.** k3s runs v1.34.1 although the cluster record says 1.30.

### Step 13–14: Deploy the enrolment and results services

I applied the shared ConfigMap `usms-app-config` (four keys) and then `20-enrolment.yaml`. That one file holds the nginx template ConfigMap, the Deployment (two replicas, `maxUnavailable 0`, CPU request `50m`, separate readiness and liveness probes) and the ClusterIP Service. Then I applied `30-results.yaml`, which deliberately has no liveness probe and uses the default strategy.

![Enrolment deployment, pods, service, endpoints and in-cluster request part a](<../../screenshots/Lab-07/06-enrolment-and-results-deployed_a.png>)
![Both deployments with strategies and endpoints part b](<../../screenshots/Lab-07/06-enrolment-and-results-deployed_b.png>)
*`deployment.apps/usms-enrolment` is `2/2` on `nginx:1.27-alpine`, one ReplicaSet `usms-enrolment-6965b8dbbb` has 2 ready pods, and the Service is `ClusterIP 10.43.126.122` with `EXTERNAL-IP <none>` and two endpoints `10.42.0.5:80, 10.42.0.6:80`. A throwaway busybox pod fetched `http://usms-enrolment.usms.svc.cluster.local/` and got JSON naming the answering pod, `"env":"laboratory"` and `"version":"1.0.0"`, so the template substitution worked. The custom-columns table shows `usms-enrolment` and `usms-results` both `2/2`, both `RollingUpdate`, with `MAXUNAVAIL` `0` and `25%`, and each Service has two endpoints.*

### Step 15–16: The gateway, and service discovery by DNS

The gateway's configuration holds two hostnames and proxies `/enrolment/` and `/results/` to them.

![Five pods running and gateway log part a](<../../screenshots/Lab-07/07-gateway-and-service-discovery_a.png>)
![Service names resolve to ClusterIPs part b](<../../screenshots/Lab-07/07-gateway-and-service-discovery_b.png>)
![Requests through the gateway and the twelve-request tally part c](<../../screenshots/Lab-07/07-gateway-and-service-discovery_c.png>)
*Five pods are `Running` (two enrolment, two results, one gateway), and the gateway log has no `emerg` lines. From inside a pod, CoreDNS at `10.43.0.10` resolves `usms-enrolment.usms.svc.cluster.local` to `10.43.126.122` and `usms-results...` to `10.43.156.136`. Both are ClusterIPs, not pod addresses. The gateway root lists its two routes, `/enrolment/` is answered by `usms-enrolment`, and `/results/` by `usms-results` with `"campus":"rtc"`. Twelve requests through `/enrolment/` were answered 5 times by `...-c7srk` and 7 times by `...-xwqp4`, so the gateway holds one name and kube-proxy spreads the load under it.*

**Your turn: delete a pod.** I deleted one enrolment pod, waited for the replacement to be Ready, and sent twelve more requests through the gateway without restarting it.

![Pod deleted and replaced by its ReplicaSet](<../../screenshots/Lab-07/08-pod-deleted-replicaset-replaced.png>)
*Deleting `usms-enrolment-7d8557c58d-h94vv` produced a replacement, `...-f6l58`, within seconds. All twelve requests succeeded, with no `FAILED` lines: 6 were answered by the new pod and 6 by `...-r5bgm`. The events show the ReplicaSet `usms-enrolment-7d8557c58d` doing it (`SuccessfulCreate ... Created pod: usms-enrolment-7d8557c58d-f6l58`). The replacement came from the ReplicaSet, not the Deployment and not me.*

I re-ran this check after Step 17. The first attempt's tally ran before the replacement was Ready, so it only showed the surviving pod. That is why the ReplicaSet hash here is the post-Step-17 `7d8557c58d`.

### Step 17: ConfigMaps and Secrets, and what a Secret really is

![Secret created and decoded, then wired into the deployment part a](<../../screenshots/Lab-07/09-secret-is-base64-not-encryption_a.png>)
![Environment sources and the values inside the container part b](<../../screenshots/Lab-07/09-secret-is-base64-not-encryption_b.png>)
*`--dry-run=client -o yaml` generated the Secret manifest, and `secret/usms-enrolment-secret created`. The stored token is `ZmxvY2ktZHVtbXktdG9rZW4tbm90LWEtcmVhbC1zZWNyZXQ=`, and one `base64 -d` turns it back into `floci-dummy-token-not-a-real-secret`. No key and no extra permission were needed. `kubectl set env --from=secret/...` rolled out a new ReplicaSet. `describe` lists `usms-app-config` as a ConfigMap source and both `ENROLMENT_*` keys as coming from `usms-enrolment-secret`. Inside the container, `printenv` shows four `APP_*` keys and both `ENROLMENT_*` values in plain text.*

This kubectl version writes the Secret keys as two `env` entries with `secretKeyRef` rather than an `envFrom.secretRef`, so the guide's `envFrom` jsonpath shows only the ConfigMap. `describe` and `printenv` both show that the effect is the same.

### Step 18: Roll out a change, then roll it back

![ConfigMap changed, nothing happens, then rollout restart part a](<../../screenshots/Lab-07/10-rollout-and-rollback_a.png>)
![Rollout history, ReplicaSets and rollback part b](<../../screenshots/Lab-07/10-rollout-and-rollback_b.png>)
![ConfigMap restored to 1.0.0 part c](<../../screenshots/Lab-07/10-rollout-and-rollback_c.png>)
*After changing `APP_VERSION` to `"1.1.0"`, the service still said `"version":"1.0.0"`: changing a ConfigMap does not restart pods. `kubectl annotate` on the Deployment's own metadata returned `successfully rolled out` without rolling anything. `rollout restart` did roll it, and the response then said `1.1.0` from a pod with a new hash (`676766c7b5`). `rollout history` shows revisions 1, 2 and 3, and the ReplicaSets show the old two at `0` and revision 3 at `2`. `rollout undo` put revision 2's template back (`...-7d8557c58d-8xbls`), but the response still said `1.1.0`, because undo reverts the pod template, not the ConfigMap. Restoring the ConfigMap and restarting brings it back to `1.0.0`.*

**Your turn: an image roll of `usms-results`.** I did `set image ... results=nginx:1.27` and then `rollout undo`, while watching the pods. `rollout history` showed two revisions afterwards, and the Deployment was back on `nginx:1.27-alpine`. The peak was 3 pods. I expected the default 25%/25% strategy to behave differently from enrolment's 0/+1, but with 2 replicas it rounds to maxSurge 1 and maxUnavailable 0, so the roll had exactly the same shape. The difference only appears at 4 or more replicas.

### Step 19: Break pods deliberately, and diagnose them

![ImagePullBackOff with old pods still serving, then undo part a](<../../screenshots/Lab-07/11-three-failures-diagnosed_a.png>)
![Pending pod with FailedScheduling part b](<../../screenshots/Lab-07/11-three-failures-diagnosed_b.png>)
![CrashLoopBackOff with its logs and last state part c](<../../screenshots/Lab-07/11-three-failures-diagnosed_c.png>)
![All three cleaned up and five pods running part d](<../../screenshots/Lab-07/11-three-failures-diagnosed_d.png>)
*The three failures and what showed them:*
- *A non-existent tag gave `ImagePullBackOff` on the new pod while both old `usms-results` pods stayed `1/1 Running`, so the strategy kept the broken image away from users. `rollout undo` fixed it.*
- *A pod requesting 64 CPUs and 256 Gi stayed `Pending` with `FailedScheduling ... 0/1 nodes are available: 1 Insufficient cpu, 1 Insufficient memory`.*
- *A container that exits 1 went to `CrashLoopBackOff` with `2` restarts. `kubectl logs` shows `usms-crasher starting` and `fatal: no database configured`, and `Last State: Terminated, Reason: Error, Exit Code: 1`.*

*Both temporary pods were deleted, and the namespace is back to five `Running` pods.*

For the crasher, the first run caught the pod between restarts (`Error`) and `logs --previous` had nothing yet. I re-ran it, waiting until the status actually read `CrashLoopBackOff`.

### Step 20–21: ECS next to EKS, and IRSA

![ECS service and EKS deployments side by side part a](<../../screenshots/Lab-07/12-ecs-comparison-and-irsa_a.png>)
![OIDC issuer, provider registered and ServiceAccount part b](<../../screenshots/Lab-07/12-ecs-comparison-and-irsa_b.png>)
![ServiceAccount and provider listed part c](<../../screenshots/Lab-07/12-ecs-comparison-and-irsa_c.png>)
*ECS still shows `usms-enrolment-svc` at Desired 2, Running 2, task definition `usms-enrolment:1`, one load balancer and one deployment. EKS shows three Deployments (`2/2`, `1/1`, `2/2`) and three ClusterIP Services with no external address. The cluster publishes an OIDC issuer, so the guide's branch ran `create-open-id-connect-provider` and returned `arn:aws:iam::000000000000:oidc-provider/oidc.eks.us-east-1.amazonaws.com/id/606B2D69...`. `usms-enrolment-sa` was created in `usms`, and `list-open-id-connect-providers` lists the provider.*

The ECS and Kubernetes comparison table is filled in in my notes. Of IRSA's six steps, this build completed the first two (an issuer, and a registered provider). I did not write the web-identity role. Floci never evaluates trust policies, and its issuer URL is not reachable by STS, so steps 3 to 6 would not have proved anything.

### Step 22: Restart Floci and check what survives

I recorded the cluster, the node group, the three Deployments and the three Service IPs, then ran `floci-down.sh` and `floci-up.sh` and re-derived everything from the API.

![State recorded before the restart part a](<../../screenshots/Lab-07/13-persistence-after-restart_a.png>)
![Re-derived after the restart part b](<../../screenshots/Lab-07/13-persistence-after-restart_b.png>)
![Differences reported part c](<../../screenshots/Lab-07/13-persistence-after-restart_c.png>)
*Before the restart: the cluster `ACTIVE 1.30`, the node group `ACTIVE 2`, the Deployments at `2`, `1` and `2`, and the three ClusterIPs. After the restart, the AWS half came back: `usms-eks-cluster` was re-derived from `list-clusters` (`ACTIVE 1.30`), and `usms-eks-nodes` from `list-nodegroups`. The Kubernetes half is empty: nothing at all under `--- kubernetes ---`. The `diff` reports every Kubernetes line as missing and ends with `differences above - read them before deciding whether they matter`, not `PERSISTENCE PROVEN`.*

The differences did matter. `FLOCI_STORAGE_MODE` was `hybrid`, so this was not the memory-mode trap the guide warns about. `docker compose stop` made Floci remove the k3s container, which had no volume, and `floci-up.sh` does not recreate it. The EKS records persisted, but the real Kubernetes cluster behind them, with everything in it, did not.

### Recovery: rebuild the cluster from the repository

All the cluster state was in committed files, so I rebuilt it from them:
1. deleted the stale node group and cluster records, and the old OIDC provider;
2. ran `create-cluster` and `create-nodegroup` from the two templates;
3. ran `update-kubeconfig`;
4. ran `kubectl apply -f manifests/lab-07/`;
5. registered the new cluster's OIDC issuer.

![Records deleted, cluster and node group recreated from the templates part a](<../../screenshots/Lab-07/14-cluster-rebuilt-from-manifests_a.png>)
![Every object recreated by one kubectl apply part b](<../../screenshots/Lab-07/14-cluster-rebuilt-from-manifests_b.png>)
![Secret env re-applied, three deployments ready, new OIDC provider part c](<../../screenshots/Lab-07/14-cluster-rebuilt-from-manifests_c.png>)
*Both records went to `DELETING`, and the old OIDC provider was removed. The cluster was recreated (`CREATING` then `ACTIVE`), the node group came back `ACTIVE`, and a new node `d3c4fc01636a` is `Ready`. One `kubectl apply -f manifests/lab-07/` recreated the namespace, all four ConfigMaps, three Deployments, three Services, the Secret and the ServiceAccount. The Step 17 `kubectl set env` change was imperative and therefore missing, so I re-ran it. All three Deployments are ready (`2/2`, `1/1`, `2/2`), and the new issuer is registered as `.../id/1B68171CD0804AA4B1DBE960E40AC051`.*

The restart also stopped `usms-web-01` and replaced the ECS tasks, as in Labs 05 and 06. I started the instance again, the service came back at 2/2, and `verify-lab-05.sh` (47/2) and `verify-lab-06.sh` (39/3) are unchanged.

### Step 23 and Section 8: `configs/lab-07.env`, verification and a smoke test

I wrote the env file from the guide's unquoted heredoc. Every AWS value is looked up from the API at that moment, so it holds the rebuilt cluster's values. I also wrote `verify-lab-07.sh`, with the same change as in Labs 04 to 06 (the "no secret is tracked" check allows `outputs/.gitkeep`), and `scripts/cleanup/lab-07-cleanup.sh`, which I only checked with `bash -n`.

![Env file written part a](<../../screenshots/Lab-07/15-lab07-env-verify-and-smoke-test_a.png>)
![All values populated and 21 exports part b](<../../screenshots/Lab-07/15-lab07-env-verify-and-smoke-test_b.png>)
![verify-lab-07 PASS 30 FAIL 0 part c](<../../screenshots/Lab-07/15-lab07-env-verify-and-smoke-test_c.png>)
![Smoke test through the gateway part d](<../../screenshots/Lab-07/15-lab07-env-verify-and-smoke-test_d.png>)
*`all values populated` and `21` exports, with `cluster=usms-eks-cluster ns=usms lb_ports=8081,8082`. `verify-lab-07.sh` reports **`PASS=30 FAIL=0`**:*
- *Environment: all checks pass.*
- *Earlier labs: the Lab 01 role and policy, and the Lab 02 VPC and subnets, are still present.*
- *Lab 07 IAM and EC2: both roles, with their trust and the Lab 01 policy, and the security group in `usms-vpc`.*
- *EKS: the cluster `ACTIVE` with `_lb_ports_`, and the node group `ACTIVE`.*
- *Kubernetes: the API is reachable, `usms` exists, the replica counts are 2/2/1, there are at least 2 enrolment endpoints, and the CPU request is declared.*
- *Files and Git: all six checks pass.*

*The smoke test through the gateway returned all three JSON documents and `SMOKE TEST PASSED`.*

### Step 24: Commit

![Status and ignore rule checked part a](<../../screenshots/Lab-07/16-commit-proof_a.png>)
![Files staged by explicit path and committed part b](<../../screenshots/Lab-07/16-commit-proof_b.png>)
![Commit contents and nothing under outputs part c](<../../screenshots/Lab-07/16-commit-proof_c.png>)
*No `outputs/` path appears in `git status`. `git check-ignore -v` names `.gitignore:8:outputs/*`, and `git ls-files outputs/` lists only `.gitkeep`. Commit `47fb283` contains 18 files: seven manifests, four policies, two templates, the env file, the notes, and the three scripts. The final count of tracked `outputs/` files other than `.gitkeep` is `0`.*

I kept `manifests/lab-07/50-secret.yaml` in the commit on purpose. Its values are labelled dummies, and the rebuild showed the value of having the Secret declared. In a real repository it would be generated into `outputs/` or replaced by a secrets manager.

## 6. Results and Evidence

### 6.1 CLI/SDK Output

| Checkpoint | What had to be true | Result |
|---|---|---|
| 1 (Step 2) | Floci up, Lab 02 `FAIL=0`, four subnets in two AZs, `kubectl` installed, path recorded | All true, path A (screenshot 01) |
| 2 (Step 7) | Two roles with the right trust and policies, Lab 01 policy on the node role, SG with 443 from the VPC | All true (screenshot 02) |
| 3 (Step 10) | Cluster `ACTIVE` on four subnets with `_lb_ports_`; node group `ACTIVE` in private subnets, 2/4/2 | All true (screenshots 03, 04) |
| 4 (Step 13) | Enrolment 2/2, two endpoints, CPU `50m`, distinct probes | All true (screenshot 06) |
| 5 (Step 16) | Three Deployments healthy, names resolve to ClusterIPs, two pod names in the tally | All true, 5/7 split (screenshots 07, 08) |
| 6 (Step 18) | New ReplicaSet on a roll, history readable, undo exercised, ConfigMap back at 1.0.0 | All true (screenshot 10) |
| 7 (Step 19) | Three failures produced and diagnosed, temporary objects deleted | All true (screenshot 11) |
| 8 (Step 22) | `PERSISTENCE PROVEN` after a Floci restart | **Not met:** the AWS records persisted, but the k3s cluster was removed; rebuilt from the repository (screenshots 13, 14) |
| 9 (Step 24) | 21 exports, no empty values, committed, nothing from `outputs/` | All true, commit `47fb283` (screenshots 15, 16) |

The consolidated proof is `verify-lab-07.sh` at `PASS=30 FAIL=0`, plus `SMOKE TEST PASSED` (screenshot 15).

### 6.2 AWS Console Verification

Floci has no AWS Management Console. The EKS console's cluster, compute and resources tabs would show what `describe-cluster`, `describe-nodegroup` and the `kubectl get` commands in the screenshots show. Those calls are the same APIs the console reads.

## 7. Analysis and Discussion

**What was real and what was only a record.** Everything on the Kubernetes side was real:
- scheduling;
- ReplicaSets replacing pods;
- CoreDNS and kube-proxy;
- probes;
- rolling updates and rollbacks;
- the three failure modes.

Most of the AWS side was stored rather than acted on:
- the node group is a record, and one k3s server node ran every pod;
- `instanceTypes`, `amiType` and the private subnets have no effect;
- the IAM roles are never evaluated, so even a missing permission would not have failed;
- pods got k3s addresses (`10.42.x.x`, Services `10.43.x.x`) instead of VPC addresses from `10.0.0.0/16`;
- k3s runs v1.34.1 whatever version the cluster record says.

**Floci limitations I hit, with what real AWS does:**

- **Kubernetes state does not survive a Floci restart.** The k3s container is removed on stop and not recreated. On real EKS the control plane and etcd are managed and persistent, and stopping my laptop would not touch them. This is the reason Checkpoint 8 failed.
- **One node instead of a node group.** Real EKS would give me two EC2 nodes in different AZs, and the scheduler would spread the replicas across them. Here every pod ran on one node, so the "one pod per AZ" resilience of the design was not tested.
- **IRSA stops at step 2.** Real EKS publishes the issuer publicly, so STS can verify a pod's token and hand it 15-minute credentials for its own role. Here the node role is the only way a pod could get AWS permissions, which is exactly the over-sharing IRSA exists to prevent.
- **No real load balancer.** All three Services are ClusterIP, and nothing outside the cluster can reach them. That is Lab 08's job.

**Problems that were mine to untangle:**

- **The inotify limit.** It was not a lab problem but a host problem: another course's kind cluster was holding inotify instances. Reading the k3s container's own log, rather than retrying `kubectl`, found it in one step.
- **Timing in my own checks.** Two of my first captures were taken too early: the pod tally before the replacement was Ready, and the crasher between restarts. I re-ran both with an explicit wait instead of a longer `sleep`.
- **Imperative changes.** The one thing `kubectl apply -f manifests/lab-07/` could not rebuild was the Secret wiring I had added with `kubectl set env`. I had to remember it.

**Why Step 22's failure was the most useful result in the lab.** If the restart had worked, the manifests would have felt like paperwork. Because it failed, the manifests became the cluster's real backup: two JSON templates and seven YAML files recreated everything in about a minute. The same rebuild also showed what was not in the files.

## 8. Reflection

What I will keep from this lab is the difference between declaring and doing. Everything that survived the rebuild was something I had written down as a file and applied. Everything that did not survive was something I had done with a verb: `set env`, `annotate`, `scale`, `rollout undo`. On a real team that is the argument for GitOps. If a change is not in the repository, the cluster will eventually forget it, and so will everyone else.

The Secret demonstration changed how I read the word "Secret". One `base64 -d` with no key turned the stored value back into the token. A Secret keeps the value out of the image and can be access-controlled separately, but it is not encryption. I would not have believed how thin it is without decoding it myself.

Comparing with ECS while both were running made the trade-off concrete. Kubernetes gave me a lot for free that ECS needs an ALB for (DNS discovery, load spreading, rollback by ReplicaSet), but I also had to understand ReplicaSets, Services, probes, kube-proxy and kubeconfig contexts to run three nginx containers. For USMS today I would still choose ECS. I would move to EKS when there are enough services and teams to use what Kubernetes adds.

## 9. Conclusion

USMS now has an EKS cluster `usms-eks-cluster` with its two IAM roles and security group, a managed node group in the private subnets, and a `usms` namespace running a gateway, an enrolment service and a results service. The gateway reaches the other two by DNS name, and requests are spread across replicas. I proved that a Secret is only base64. I rolled a change out and back, produced and diagnosed `ImagePullBackOff`, `FailedScheduling` and `CrashLoopBackOff`, and got IRSA as far as a registered OIDC provider.

The restart test showed that on this Floci build the EKS records survive a restart but the Kubernetes cluster does not. I rebuilt it from the committed templates and manifests, re-applied the one imperative change, and finished with `verify-lab-07.sh` at `PASS=30 FAIL=0`, a passing smoke test, 21 values in `configs/lab-07.env`, and commit `47fb283`. Labs 05 and 06 are unchanged.

## 10. Appendix

**Key resource identifiers from this lab:**

| Resource | Value |
|---|---|
| Cluster | `usms-eks-cluster` – `arn:aws:eks:us-east-1:000000000000:cluster/usms-eks-cluster`, v1.30 (k3s v1.34.1), `https://localhost:6500` |
| Cluster tag | `_lb_ports_ = 8081,8082` |
| OIDC issuer (current) | `https://oidc.eks.us-east-1.amazonaws.com/id/1B68171CD0804AA4B1DBE960E40AC051` (first cluster: `...606B2D69F5954BD697154C2174D0E285`) |
| Node group | `usms-eks-nodes` – min 2 / max 4 / desired 2, `subnet-1150e689` + `subnet-47a7fe37`, `t3.small`, `AL2023_x86_64_STANDARD` |
| Cluster role | `arn:aws:iam::000000000000:role/usms-eks-cluster-role` + `USMSEKSClusterPolicy` |
| Node role | `arn:aws:iam::000000000000:role/usms-eks-node-role` + `USMSEKSNodePolicy` + `USMSStudentDataReadWrite` |
| Cluster security group | `sg-a69b9f7c3d0f9f5f8` (`usms-eks-cluster-sg`, tcp/443 from `10.0.0.0/16`) in `vpc-6ffa2a93` |
| Namespace | `usms` |
| Deployments | `usms-gateway` (1), `usms-enrolment` (2, maxUnavailable 0), `usms-results` (2, default strategy) |
| Services | `usms-gateway`, `usms-enrolment`, `usms-results` – all ClusterIP, port 80 |
| Config | `usms-app-config` (4 keys), `usms-enrolment-secret` (2 dummy keys), `usms-enrolment-sa` |
| kubeconfig context | `usms-eks` (default namespace `usms`) |
| Commit | `47fb283` |

**Files produced for this lab:**
- `policies/trust-eks-cluster.json`, `policies/trust-eks-node.json`: trust policies.
- `policies/usms-eks-cluster-policy.json`, `policies/usms-eks-node-policy.json`: local stand-ins for the AWS managed policies.
- `templates/lab-07-create-cluster.json`, `templates/lab-07-create-nodegroup.json`: the two `--cli-input-json` documents (used twice: the first build and the rebuild).
- `manifests/lab-07/00-namespace.yaml` … `60-serviceaccount.yaml`: seven manifests that recreate the whole namespace.
- `configs/lab-07.env`: 21 exports for Lab 08.
- `notes/lab-07-notes.md`: support path, deviations, "Your turn" answers, the ECS/Kubernetes table, IRSA progress, the persistence result and the limitations.
- `scripts/utilities/eks-support-probe.sh`: the support path probe.
- `scripts/utilities/verify-lab-07.sh`: automated check (30/30).
- `scripts/cleanup/lab-07-cleanup.sh`: end-of-course teardown, syntax-checked only and never run.
- `outputs/lab-07-*.txt|json`: evidence files (support probe, cluster and node group descriptions, before/after restart), git-ignored.
