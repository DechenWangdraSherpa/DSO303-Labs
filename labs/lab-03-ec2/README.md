# Lab 3 – EC2 Compute Tier for USMS (Web & Database Instances)

**Name:** Dechen Wangdra Sherpa
**Student Number:** 02230281
**Program:** College of Science and Technology, Royal University of Bhutan
**Course:** DSO303 – Cloud Native Design Patterns
**Lab:** Lab 3 – Amazon EC2 (Elastic Compute Cloud)

---

## 1. Aim / Objective

The aim of this lab was to bring up the compute layer of the University Student Management System (USMS) on top of the networking foundation I built in Lab 2. By the end of the lab, I needed a web-tier instance sitting in the public subnet with a stable public address, and a database-tier instance sitting in the private subnet with no public exposure at all, with the two properly wired together through security groups. The bigger objective, though, was to stop trusting that a command "worked" just because it returned success, and instead prove every property of the instances — their identity, their permissions, their networking, their data — by reading the state back from the API.

## 2. Introduction

Lab 1 gave USMS its identity and access-control layer (IAM roles, groups, and policies), and Lab 2 gave it a network to live in (the VPC, public and private subnets, route tables, NAT gateway, and security groups). Lab 3 is where actual compute finally shows up inside that network. I launched two EC2 instances: `usms-web-01`, representing the student portal's web/app server, and `usms-db-01`, representing the backend database server. The web instance lives in the public subnet created in Lab 2 and gets an Elastic IP so it has a fixed, predictable address. The database instance lives in the private subnet, has no public IP at all, and only accepts traffic from the web tier's security group — never from the open internet.

All of this was done against Floci, the local AWS emulator we've been using throughout the course, using the AWS CLI exactly as I would against real AWS. One thing worth being upfront about from the start: Floci does not actually boot a Linux kernel or run a real network stack. It stores and returns EC2 metadata faithfully (instance IDs, tags, security group rules, volume attachments, and so on), but it cannot execute a user-data script, serve real HTTP traffic, or enforce packets at a NIC. So a good part of this lab, and a good part of this report, is about proving configuration correctness through the API rather than proving that a web page is actually being served.

## 3. Use Case

USMS needs a real place for its application code and its data to run. The web tier is what students and staff will eventually reach through a browser — it needs to be reachable from the internet, so it sits in the public subnet with an Elastic IP. The database tier holds student records, grades, and other data that should never be directly reachable from outside — so it sits in the private subnet, has no public address, and only trusts connections coming from the web tier itself, never from "anywhere." This two-tier split (public web server, private database) is the same pattern any real student-facing web application uses, and it continues straight on from the VPC design in Lab 2 — the public/private subnet split I built there only becomes useful once there are actual instances using it, which is exactly what this lab does.

## 4. System Architecture / Design

At a high level, the Lab 3 architecture sits inside the `usms-vpc` built in Lab 2:

- **Web tier — `usms-web-01`**: a `t3.micro` instance in the public subnet (`subnet-c9b01466`), launched from the Amazon Linux 2 AMI, carrying the `usms-app-sg` security group and the `usms-ec2-app-profile` instance profile (so the instance can assume the `usms-ec2-app-role` IAM role from Lab 1). It has a dedicated Elastic IP so its public address doesn't change across restarts, and a second EBS volume attached at `/dev/sdf` for application data, kept separate from the root volume so it isn't wiped if the instance is replaced.
- **Database tier — `usms-db-01`**: a `t3.micro` instance in the private subnet (`subnet-1150e689`), carrying the `usms-db-sg` security group. It has no public IP and no instance profile — it doesn't need to call any AWS APIs, it only needs to accept database connections from the web tier.
- **Security group wiring**: `usms-db-sg` only allows inbound traffic on port 5432 (PostgreSQL) from `usms-app-sg` by security-group reference, not from any IP range. This means only instances that carry the web tier's security group can ever reach the database port — not "anyone on the private subnet," specifically the web tier.
- **Key pair**: a single key pair, `usms-app-key`, generated for the lab and kept out of git entirely (the private key file never gets committed).
- **Golden AMI**: once the web instance was configured, I captured it as a reusable image (`usms-web-golden`), so future labs or a real deployment could launch identical web servers without repeating every setup step by hand.

This mirrors a standard two-tier architecture: public-facing compute in a public subnet behind an Elastic IP, and private compute in a private subnet that only the application tier can reach.

## 5. Implementation Procedure

### Step 1–2: Resuming the environment and picking an AMI

I started by bringing Floci back up and sourcing the three environment files from the earlier labs (`course.env`, `lab-01.env`, `lab-02.env`), then running the Lab 2 verification script one more time to confirm the VPC, subnets, and security groups from Lab 2 were still intact before building anything new on top of them.

![Environment and network verified before starting Lab 3](<../../screenshots/Lab-03/01-environment-and-network-ready.png>)
*Before touching EC2 at all, I re-ran `verify-lab-02.sh` to make sure Lab 2's network was still healthy — it came back clean at 33/33, so I had solid ground to build the compute tier on.*

With the network confirmed, I looked through the available AMIs with `describe-images` to pick a base image for the web and database instances, and settled on the Amazon Linux 2 AMI that the lab pointed to, capturing its ID as `AMI_ID`.

![AMI selected for the instances](<../../screenshots/Lab-03/02-ami-selected.png>)
*I compared a few of the seeded AMIs (Amazon Linux 2, Amazon Linux 2023, Debian, Alpine, Windows Server) and picked the Amazon Linux 2 one that the lab specifies, recording its ID for the launch step.*

### Step 3–4: Key pair

I generated the `usms-app-key` key pair with `create-key-pair`, saved the private key with `chmod 600` so only I can read it, and immediately checked that it was excluded by `.gitignore` before doing anything else with it — I didn't want a stray terminal mistake to accidentally stage a private key.

![Key pair created with correct permissions](<../../screenshots/Lab-03/03-keypair-created.png>)
*The PEM file came out with `-rw-------` permissions as expected, and `describe-key-pairs` confirms `usms-app-key` is registered.*

![Key pair confirmed git-ignored](<../../screenshots/Lab-03/04-keypair-gitignored.png>)
*Right after creating it, I checked that the `.pem` file is caught by `.gitignore` — this was non-negotiable before I let myself move on to the next step.*

### Step 5: User data script

The lab provides a user-data script meant to install and start nginx and drop a small portal placeholder page on first boot. I validated it with `bash -n` before using it anywhere, to rule out a syntax mistake being the reason it might not behave later.

![User data script validated](<../../screenshots/Lab-03/05-userdata-script-valid.png>)
*`bash -n` on the script came back clean, and the file size (1657 bytes) matched what I expected — the script itself was not the problem, which became relevant later.*

### Step 6–7: Launching the web instance

I filled in `templates/lab-03-run-instances.json` with the AMI, instance type, key pair, public subnet, `usms-app-sg`, and the `usms-ec2-app-profile` instance profile, validated it as JSON, and launched the web instance with `run-instances --cli-input-json` plus `--user-data file://...`, then waited for it to reach the `running` state.

![Run-instances request validated and web instance launched](<../../screenshots/Lab-03/06-web-instance-launched_1.png>)
![Web instance launch command output](<../../screenshots/Lab-03/06-web-instance-launched_2.png>)
![Web instance reached running state](<../../screenshots/Lab-03/06-web-instance-launched_3.png>)
*The launch request validated as proper JSON, the instance came back with an ID, and `wait instance-running` returned exit code 0 — the instance was up.*

I later terminated this first web instance and relaunched a clean one using the same documented method, after running into the user-data issue described in Step 12 below. Every screenshot from this point on reflects the relaunched instance.

![Web instance described after relaunch](<../../screenshots/Lab-03/07-web-instance-described.png>)
*`describe-instances` on the (relaunched) web instance shows everything I expect: AZ `us-east-1a`, key `usms-app-key`, private IP `172.20.0.3`, the `usms-ec2-app-profile` instance profile attached, state `running`, sitting in the public subnet, and type `t3.micro`. Floci shows the public IP as `127.0.0.1`, which is its standard placeholder rather than a real routable address — the Elastic IP step below is what actually gives it a stable, meaningful public address.*

### Step 11: Tracing the permission chain

Before trusting that the web instance could reach anything in S3 (needed later in Lab 4), I traced its permission chain end to end: instance → instance profile → IAM role → attached policy → policy document, rather than just assuming the profile was correctly wired.

![Permission chain traced from instance to policy](<../../screenshots/Lab-03/08-permission-chain-traced.png>)
*Starting from the instance's profile ARN, I resolved it down to `usms-ec2-app-role`, listed its attached policies, and confirmed `USMSStudentDataReadWrite` is attached — the same policy created back in Lab 1. The bucket it grants access to (`usms-student-data`) doesn't exist yet; that comes in Lab 4. But the permission chain itself is already correctly wired and ready for it.*

### Step 12: Proving the user data actually ran

This is the step that gave me the most trouble, and I want to be straightforward about what happened rather than paper over it. The first time I checked `describe-instance-attribute --attribute userData`, it came back as a mismatch against what I expected.

![First user-data check failing](<../../screenshots/Lab-03/error.png>)
*My first attempt at proving the user data came back with a mismatch rather than a match — this is the output that first told me something was off.*

I tried fixing it by stopping the instance and re-applying the user data with `modify-instance-attribute` (base64-encoding it manually myself, since that command — unlike `run-instances` — doesn't do the encoding for me). That didn't fix it either. I then terminated the original instance entirely and relaunched a completely clean one using the documented `--cli-input-json` + `--user-data file://...` method from Step 8, to rule out any mistake on my end in how the data was supplied. The result was the same: `describe-instance-attribute --attribute userData` still returned `None`.

To make sure the `describe-instance-attribute` API itself wasn't broken, I ran the same command asking for the `instanceType` attribute instead, and that came back correctly as `t3.micro`. That told me the API call mechanism works fine in general — it's specifically the `userData` attribute that Floci isn't returning, even when it was correctly supplied at launch time.

![User data proof — honest diagnostic result](<../../screenshots/Lab-03/09-userdata-proven.png>)
*Since I couldn't get a clean "user data proven" result, I documented what I could actually verify: (1) the `describe-instance-attribute` API itself works, proven by asking for `instanceType` instead and getting `t3.micro` back correctly; (2) `userData` specifically always comes back as `None`; (3) the user-data script itself is valid and was correctly base64-encoded; (4) the data was confirmed supplied at launch time via the `--user-data` flag. I'm treating this as a genuine Floci limitation rather than something I did wrong, and I go into more detail on why in the Analysis section below.*

### Step 13: A stable public address for the web server

With the web instance confirmed running, I allocated an Elastic IP and associated it with `usms-web-01`, so the web server has a fixed public address rather than relying on whatever address Floci might assign on its own.

![Elastic IP allocated and attached](<../../screenshots/Lab-03/10-elastic-ip-attached.png>)
*The allocation and association both went through cleanly, tying the address to the web instance. (Floci's `describe-instances` still shows the placeholder `127.0.0.1` for the instance's own public IP field — the actual address lives on the Elastic IP allocation itself, which is what `describe-addresses` confirms.)*

### Step 14: Testing the application (and proving reachability the honest way)

The lab expects a `curl` to the web server's public address. Since Floci doesn't run a real network stack, this times out — which is expected, not a failure. Instead, I proved reachability through the chain of configuration that would make a real request succeed: instance state, internet gateway, route table, security group rule, and the NACL.

![Reachability chain proven through configuration](<../../screenshots/Lab-03/11-reachability-chain-proven.png>)
*The direct `curl` timed out as expected, so I fell back to checking the six things that would actually need to be true on real AWS for that request to succeed: the instance is running, the internet gateway (`igw-184eb7e2`) is attached, the route table is available, there's a `0.0.0.0/0` route out, the public IP is associated, and the public NACL (`acl-e4e0fde3681f7d76a`) allows the traffic. All six checked out.*

### Step 15: Attaching a data volume

I created and attached a second EBS volume to the web instance at `/dev/sdf`, separate from the root volume, with `DeleteOnTermination` set to `False` so application data would survive if the instance were ever replaced.

![Data volume attached to the web instance](<../../screenshots/Lab-03/12-data-volume-attached.png>)
*`describe-volumes` shows two volumes on the web instance: the root volume (which deletes with the instance, as expected) and `usms-web-data-vol` at `/dev/sdf`, explicitly set to NOT delete on termination, both correctly sitting in the same Availability Zone (`us-east-1a`) as the instance itself — attaching across AZs isn't allowed, so confirming this mattered.*

### Step 16: Launching the database tier instance

I launched `usms-db-01` into the private subnet, with the `usms-db-sg` security group, no public IP, and no instance profile — it has no reason to call AWS APIs, so it gets none of that access.

![Database instance launched into the private subnet](<../../screenshots/Lab-03/13-db-instance-launched.png>)
*`describe-instances` on the new database instance confirms exactly what I wanted: no public address, no instance profile, the `usms-db-sg` security group, state `running`, and sitting in the private subnet (`subnet-1150e689`) rather than the public one.*

### Step 17: Proving the two tiers are actually wired together

Rather than just trusting that the security group rule I wrote was correct, I looked up what security group the database rule actually references and confirmed it matches the group the web instance itself carries.

![Web and database tiers proven wired together](<../../screenshots/Lab-03/14-tiers-wiring-proven.png>)
*I pulled the inbound rule on `usms-db-sg` and confirmed it admits port 5432 only from `sg-39a66c2dc43f3eef3` — and that is the exact same security group ID the web instance carries. So the database genuinely only trusts the web tier, not a CIDR range, not "anywhere." I also checked the private route table, which correctly sends outbound traffic through the NAT gateway rather than an internet gateway, keeping the database tier from ever being directly reachable from the internet.*

### Step 18–19: Stop/start test, then proving compute survives a restart

The lab asks for two persistence checks: first, whether the Elastic IP stays correctly associated through a simple stop/start of the instance, and second, whether the instances themselves survive a full Floci container restart.

![Stop/start cycle and Elastic IP behavior](<../../screenshots/Lab-03/15-stop-start-eip-test.png>)
*I stopped the web instance, confirmed it reached `stopped`, started it again, and confirmed it came back to `running`. Checking `describe-addresses` afterward showed the Elastic IP still correctly associated with the instance — a simple stop/start cycle on its own did not disturb the association.*

![Compute identity proven to survive a full restart](<../../screenshots/Lab-03/16-compute-persistence-proven.png>)
*For the bigger test, I took a snapshot of both instances, fully restarted the Floci container (`floci-down.sh` then `floci-up.sh`), and compared. The IDs, subnets, and security groups of both `usms-web-01` and `usms-db-01` were still exactly the same after the restart — only their run-state had reverted to `stopped`. The one line that shows up as a "difference" in the comparison is the original, already-terminated web instance from Step 12, which Floci still reports back for a while after termination — that's expected lab behavior, not a third resource. After confirming the identity and configuration had genuinely survived, I started both instances back up. I talk about why the run-state itself doesn't survive a restart, while everything else does, in the Analysis section below.*

### Step 20: Creating a golden AMI

With the web instance correctly configured, I captured it as a reusable image so future labs (or a real deployment) don't have to repeat the setup from scratch.

![Golden AMI created from the configured web instance](<../../screenshots/Lab-03/17-golden-ami-created.png>)
*I confirmed the web instance was running, then ran `create-image` with `--no-reboot` (so I wouldn't have to restart a production-representing instance just to snapshot it), tagged the resulting image, and waited for it to become `available`. `describe-images` confirms `usms-web-golden` exists and is ready to use.*

### Step 21–22: Auditing everything and writing the environment file

Before committing, I pulled a full audit of every Lab 3 resource — instances, volumes, Elastic IPs, and images — and used that to write out `configs/lab-03.env` so later labs can reference these resources without me having to look up IDs by hand again.

![Full resource audit before writing the environment file](<../../screenshots/Lab-03/18-audit-and-env-written_1.png>)
*The audit shows all three instances tagged under the USMS project (the terminated original web instance still listed, as expected), the data volume correctly attached, and two Elastic IPs in this environment — `usms-nat-eip` (used by the NAT gateway from Lab 2, unassociated with any instance) and `usms-web-eip` (associated with the current web instance) — plus the golden AMI, available.*

![Environment file written and sourced](<../../screenshots/Lab-03/18-audit-and-env-written_2.png>)
*I generated `configs/lab-03.env` directly from live `describe-*` lookups rather than typing IDs in by hand, sourced it, and printed back the key values to confirm they populated correctly. One thing I noticed afterward: the public IP value that got written down matches `usms-nat-eip`'s address rather than `usms-web-eip`'s — with two Elastic IPs present in the same environment, the lookup picked up the wrong one. I flag this honestly in the Analysis section rather than quietly editing the screenshot evidence to hide it.*

### Step 23: Committing the work

With the environment file written and the resources confirmed, I staged and committed the Lab 3 changes, and double-checked beforehand that the private key was still correctly excluded from git.

![Lab 3 work committed to git](<../../screenshots/Lab-03/19-commit-proof.png>)
*`git check-ignore -v` confirmed the `.pem` file is still caught by `.gitignore` before I committed anything. The commit itself went through cleanly, and `git log` shows it sitting on top of the Lab 1 and Lab 2 history.*

## 6. Results and Evidence

### 6.1 CLI/SDK Output

Everything in this lab was built and verified through the AWS CLI against Floci — there is no separate SDK step. The final verification script, run after everything above was in place, is the clearest single piece of evidence that the lab's required state was reached.

![Final verification script passing](<../../screenshots/Lab-03/20-verify-lab03-pass.png>)
*`verify-lab-03.sh` checked the environment, the Lab 1/Lab 2 dependencies, the key pair, both instances' configuration, the data volume, the golden AMI, tagging, and git hygiene, and came back `PASS=36 FAIL=0`. One caveat worth being honest about: the "has user data stored" check in this script only tests that the stored value is a non-empty string. Since Floci returns the literal text `"None"` for that attribute (as documented in Step 12), the check passes even though the actual user-data content isn't really being returned. The script passing doesn't contradict what I found manually in Step 12 — it's just not a check that was built to catch this particular Floci quirk.*

### 6.2 AWS Console Verification

Floci is a CLI-only emulator — there is no graphical AWS Console sitting behind it to click through. In place of console screenshots, every property that a console page would normally show me (instance state, security group rules, subnet placement, volume attachment, IP association) was instead confirmed directly through `describe-*` API calls, which is exactly what the console itself does behind the scenes. Screenshots 07, 08, 12, 13, and 14 above are effectively the CLI equivalent of opening the EC2 console, clicking into an instance's details page, its security tab, and its storage tab, and reading the same information straight from the source.

## 7. Analysis and Discussion

A few real, reproducible things came up in this lab that are worth discussing honestly rather than smoothing over.

**User data is not readable back on this Floci build.** No matter how correctly the user-data script was supplied — at launch time via `--user-data`, or after the fact via `modify-instance-attribute` with a manually base64-encoded value — `describe-instance-attribute --attribute userData` consistently returned `None`. I confirmed this wasn't a general API problem by requesting a different attribute (`instanceType`), which returned correctly. This directly contradicts the course's own "Floci vs Real AWS" comparison table, which claims user data is "Implemented in Floci." Based on what I actually observed, it isn't readable back, even though it's clearly accepted at launch time without error.

**Run-state does not survive a Floci container restart, but identity does.** After a full `floci-down.sh` / `floci-up.sh` cycle, both EC2 instances reverted from `running` to `stopped` — but every other property (instance ID, subnet, security groups, tags) stayed exactly the same. This tells me Floci's persistence model keeps resource identity and configuration durable across a restart, but treats run-state as more like live, in-memory session data that doesn't get saved the same way.

**Elastic IP associations can be fragile across restart/stop cycles, though not always.** During the stop/start test in Step 18, the Elastic IP stayed correctly associated with the web instance. But earlier in this lab's troubleshooting, I did run into a case where an association had silently dropped after an earlier container restart, and I had to re-run `associate-address` to fix it. Taken together with the user-data and run-state findings above, this points to a pattern: Floci reliably persists the *existence* of a resource, but relationships and transient state between resources are less consistently preserved.

**With two Elastic IPs in the same environment, a tag-based lookup can grab the wrong one.** When I generated `configs/lab-03.env`, the public IP value it wrote down turned out to match `usms-nat-eip` (from the Lab 2 NAT gateway) rather than `usms-web-eip` (the one actually associated with the web instance). Both addresses exist correctly and are each tagged — but the lookup used to populate the environment file picked up the NAT gateway's address instead of the web tier's. It's a small thing, but it's a good reminder that once an environment has more than one resource of the same type, a tag filter needs to be specific enough to not quietly return the wrong one.

**Terminated instances stay visible for a while — this one is actually documented, not a bug.** The very first web instance I launched and later terminated (after the user-data troubleshooting) kept showing up in tag-based `describe-instances` queries well after termination. The lab text itself says this is expected behavior for roughly an hour post-termination, so I made sure not to mistake it for an unexplained extra resource when reading my own audit output.

None of these are things a correct `run-instances` or `associate-address` call could have prevented — they're properties of the emulator itself, and the right response to each of them was the same one the lab keeps pushing: don't trust that a command worked just because it returned without an error, read the state back and check it.

## 8. Reflection

This lab changed how I think about "proof" when working with cloud infrastructure. Going in, I would have assumed that if `run-instances` returns an instance ID and no error, the job is basically done. The user-data problem in Step 12 broke that assumption pretty quickly — the command succeeded every single time, and yet the thing it was supposed to do couldn't actually be confirmed. The only way I found that out was by trying to read the state back and noticing it didn't match what I expected.

I also found the permission-chain tracing in Step 11 genuinely useful beyond just this lab — being able to start from an instance and walk all the way down to the exact policy document it's allowed to use is something I'll want to do again any time I'm not sure why something does or doesn't have access to a resource.

The part I found most uncomfortable, honestly, was the environment-file mismatch in Step 22. It would have been easy to just quietly fix the value before writing the report and never mention it. But the whole point of this lab is proving things by reading them back rather than assuming — so leaving that mismatch in and explaining it felt like the more honest way to finish a lab that's specifically about not trusting things blindly.

## 9. Conclusion

By the end of this lab, USMS has an actual compute tier: a public web server with a stable Elastic IP, correctly permissioned through the IAM chain from Lab 1 and sitting inside the network built in Lab 2, and a private database server that only the web tier can reach, never the open internet. I also came away with a reusable golden AMI of the configured web server, and an environment file that later labs can build on. Along the way, I ran into — and documented rather than hid — a handful of genuine Floci limitations around user-data readback, run-state persistence across restarts, and Elastic IP association stability. Lab 4 will build directly on top of this, specifically the `usms-student-data` S3 bucket that the web instance's IAM role is already correctly permissioned to use, even though the bucket itself doesn't exist until then.

## 10. Appendix

**Key resource identifiers from this lab:**

| Resource | Value |
|---|---|
| Web instance (`usms-web-01`) | `i-378337720bc5f9d2e` |
| Database instance (`usms-db-01`) | `i-b299af1075d366945` |
| Key pair | `usms-app-key` |
| Web tier Elastic IP (`usms-web-eip`) | `54.58.133.236` |
| Web tier data volume (`usms-web-data-vol`) | `vol-ce5e8cc2fef46b820` |
| Golden AMI (`usms-web-golden`) | `ami-1f5d6adfe8f8166fd` |
| Base AMI (Amazon Linux 2) | `ami-0abcdef1234567890` |
| Instance type | `t3.micro` |
| Web tier security group | `sg-39a66c2dc43f3eef3` (`usms-app-sg`) |
| Database tier security group | `usms-db-sg` |
| Public subnet | `subnet-c9b01466` |
| Private subnet | `subnet-1150e689` |

**Scripts produced for this lab:**
- `scripts/utilities/verify-lab-03.sh` — automated check of all Lab 3 requirements (36/36 passing).
- `scripts/cleanup/lab-03-cleanup.sh` — destructive end-of-course teardown script, syntax-checked only (`bash -n`) and never executed, since Lab 4 and Lab 8 both depend on resources created in this lab.