# Lab 2 — Virtual Private Cloud and Networking

**Course:** DSO303
**Practical:** Lab 02 — VPC and Networking (AWS CLI + Floci)

---

## 1. Aim / Objective

Coming to this lab, the goal was to actually build the network that the USMS (University Student Management System) project sits on top of, using nothing but the AWS CLI against Floci. By the end of it I wanted to be able to:

- Explain what a VPC actually is and why AWS won't let an EC2 instance exist outside of one.
- Read and write CIDR notation properly and size subnets without guessing.
- Build a VPC, subnets, an internet gateway and route tables from the CLI, and get every ID into a shell variable instead of copy-pasting it from the terminal.
- Say exactly what makes a subnet "public" and back that up by reading the effective route table of two subnets instead of just trusting the name I gave them.
- Actually know the difference between a security group and a network ACL, not just recite the definitions.
- Reference one security group from another instead of hard-coding an IP range.
- Use `--filters` and `--query` the right way round, and know which one runs where.
- Create a gateway VPC endpoint and understand what it changes about where traffic actually goes.
- Prove the network survives a restart of the emulator instead of just assuming it will.
- Get every identifier this lab produces into `configs/lab-02.env` so Lab 3 doesn't require me to remember any of it.

## 2. Introduction

Amazon VPC (Virtual Private Cloud) is basically your own private, walled-off chunk of AWS's network, defined by an IP range you pick yourself in CIDR notation. Everything else lives inside it — subnets, an internet gateway if you want public access, route tables that decide where traffic goes, and two separate layers of firewalling (security groups and network ACLs) that control what's allowed in and out. On top of that you can connect privately to other AWS services through VPC endpoints, which is something I hadn't really thought about before this lab. VPC matters because it's the thing almost everything else in AWS sits inside — you can't launch an EC2 instance, attach an RDS database, or run most other services without a network for them to live in first. In practice this is the kind of thing you'd use to run a proper multi-tier app: a public-facing web layer that anyone can reach, and a private layer behind it (a database, usually) that nobody outside the network should ever be able to touch directly, while still letting it reach out for things like security patches.

## 3. Use Case

For USMS specifically, here's what the network I built is actually for:

- The public subnet is where the web tier goes — the part students and staff hit from the internet, routed out through an internet gateway.
- The private subnet is where the data tier goes — transcripts, enrolment records — and it has no route in from the internet at all, on purpose, so a mistake somewhere else can't accidentally expose it.
- The private subnet still needs to reach the internet outbound for OS patches, which is what the NAT gateway is for — traffic can leave, nothing can start a connection in.
- The app tier and the database tier talk to each other through security groups that point at each other's group ID rather than an IP range, so the rule doesn't quietly break if either side gets rebuilt later.
- The private subnet reaches S3 through a gateway endpoint instead of going out to the internet and back in, which matters once Lab 4's bucket exists.

## 4. System Architecture / Design

Here's roughly what I ended up with, laid out the same way the lab's own diagram does it — one VPC split into a public side that can reach the internet and a private side that can't, with the NAT gateway and the S3 endpoint being the two ways the private side still gets out.

```
                                   Internet
                                      |
                                 usms-igw
                                      |
   usms-vpc  10.0.0.0/16             |
   ┌─────────────────────────────────┼─────────────────────────────┐
   │                                 │                              │
   │   usms-public-rt  0.0.0.0/0 -> usms-igw ; 10.0.0.0/16 -> local │
   │        │                                        │              │
   │  usms-public-subnet-a                  usms-public-subnet-b    │
   │   10.0.1.0/24  AZ a                      10.0.2.0/24  AZ b     │
   │   [ usms-nat ]  Elastic IP                                     │
   │        │                                                       │
   │        │ outbound only (0.0.0.0/0 -> usms-nat)                 │
   │        ▼                                                       │
   │  usms-private-rt  ; pl-... -> usms-s3-endpoint                 │
   │        │                                        │              │
   │  usms-private-subnet-a                 usms-private-subnet-b   │
   │   10.0.3.0/24  AZ a                      10.0.4.0/24  AZ b     │
   │   [ usms-private-nacl ]                                        │
   │   [ web tier -> Lab 03, app-sg ]                               │
   │   [ data tier -> Lab 03, db-sg, sourced from app-sg ]          │
   │                                                                 │
   └─────────────────────────────────────────────────────────────┘

   Security groups (instance level, stateful):
     usms-app-sg  : in 80/443/22   out: all
     usms-db-sg   : in 5432 from usms-app-sg (not a CIDR)   out: all
```

Once I actually sat with it, the whole design really just comes down to three plain sentences: the web tier needs to be reachable from the internet, the data tier absolutely must not be, and the data tier still needs a way to get updates out. Everything in that diagram — the split, the NAT gateway, both firewalls — only exists to satisfy those three things.

## 5. Implementation Procedure

**Part A — Environment and least-privilege setup**
First thing was making sure Floci was still up from Lab 1 and running the way it should be — Docker Compose, hybrid storage. I sourced `configs/course.env` and `configs/lab-01.env` to pull in the developer role, developer user, and account ID Lab 1 had already produced. Before touching anything, I checked which version of `USMSDeveloperBase` was actually the default (v2) and read the document itself, just to make sure the EC2 actions this lab needed were genuinely in there rather than assuming they were. Then I assumed `usms-developer-role` through STS as `usms-dev-01` and built the VPC under that identity rather than as root, which felt like the point of the whole exercise — using the role Lab 1 built instead of just defaulting back to admin. Afterwards I unset the temporary credentials, confirmed I was back to my normal identity, and read the VPC back to prove it was a real object in the account and not just something that existed for the duration of that one assumed session.

**Part B — Core networking**
I turned on DNS support and DNS hostnames for the VPC, then created and attached an internet gateway. Public subnet first (`10.0.1.0/24`, AZ a), with auto-assign public IPv4 switched on, then the private subnet (`10.0.3.0/24`, AZ a) with that setting left off. I built a route table for the public subnet with a `0.0.0.0/0` route pointing at the internet gateway and associated it, then built a completely separate route table for the private subnet with no internet route in it at all. I also did the "Your turn" bit and added a second public subnet (`10.0.2.0/24`, AZ b) so the web tier isn't sitting in a single Availability Zone. The part that actually proved anything, though, was reading back each subnet's effective route table from the API — the public one resolved to the internet gateway, the private one resolved to nothing. That's the moment "public subnet" stopped being a name I gave something and became something I could actually point to.

**Part C — Security groups and NACL**
`usms-app-sg` got rules for HTTP, HTTPS, and SSH — but SSH only from inside the VPC, not the whole internet. `usms-db-sg` was the more interesting one: instead of writing a CIDR range for its PostgreSQL rule, I sourced it from `usms-app-sg`'s group ID directly, using the longer `--ip-permissions` JSON form instead of the quick inline flags. After that I had a look at the default network ACL (which, it turns out, allows basically everything both ways until the invisible final deny rule) and built a custom one for the private subnet with an explicit PostgreSQL rule, an ephemeral-port rule for return traffic, and outbound HTTPS. Then I swapped the private subnet's NACL association over to the new one.

**Part D — NAT gateway and S3 endpoint**
Allocated an Elastic IP, created the NAT gateway inside the public subnet, waited for it to go `available`, then pointed the private route table's default route at the NAT gateway instead of leaving it empty. After that I created a gateway VPC endpoint for S3 and attached it to the private route table, so that S3 traffic doesn't have to detour out through the NAT gateway and back in over the public internet.

**Part E — Verification and handoff**
I ran a tag audit across everything with `describe-tags --filters "Name=tag:Project,Values=USMS"` to make sure the tagging convention actually held up rather than just assuming I'd remembered it every time, and threw in a sorted subnet inventory table as an extra check while I was at it. Then came the part that mattered most to me: proving the whole network survives a restart. I recorded the VPC ID, subnet count, and security group count, stopped and restarted Floci, re-derived everything by tag afterwards, and diffed the two records. After that I wrote `configs/lab-02.env`, made sure nothing in it came back empty, and committed everything — double-checking with `git check-ignore` first that nothing under `outputs/` was about to get staged by accident. Last step was building `scripts/utilities/verify-lab-02.sh` and running it, which checks the environment, every resource's actual configuration, and Git hygiene all in one go.

## 6. Results and Evidence

### 6.1 CLI / SDK Output

**Environment and identity**

![Environment and Floci storage check passing](<../../screenshots/Lab-02/1.1-Environment-and-identity-ready.png>)

*floci-up.sh reports the container was already running under Compose, and floci-storage-check.sh comes back clean on all six checks — good sign that the environment carried over properly from Lab 1.*

![Lab 1 environment sourced and identity confirmed](<../../screenshots/Lab-02/1.2-Environment-and-identity-ready.png>)

*After sourcing course.env and lab-01.env, whoami.sh confirms account 000000000000, and the developer role and user values from Lab 1 both come through correctly.*

**Assuming the developer role and creating the VPC**

![Policy version checked before assuming the role](<../../screenshots/Lab-02/2.1-assumed-role-vpc-created.png>)

*Before assuming anything, I checked USMSDeveloperBase's default version — it's v2, which lines up with where Lab 1 left it.*

![VPC created under the assumed developer role](<../../screenshots/Lab-02/2.2-assumed-role-vpc-created.png>)

*assume-role hands back temporary credentials for usms-developer-role, get-caller-identity confirms the Arn actually ends in assumed-role/usms-developer-role, and the VPC gets created as vpc-6ffa2a93 while I'm holding that identity.*

![Identity restored and VPC verified independently](<../../screenshots/Lab-02/3-identity-restored-vpc-verified.png>)

*Once I unset the temporary credentials, whoami.sh goes back to the normal root identity, and describe-vpcs reads the VPC back with State: available and Default: False — so it's a genuine, persisted resource, not something tied to the session that created it.*

**DNS attributes and internet gateway**

![DNS support and hostnames enabled](<../../screenshots/Lab-02/4.1-dns-and-igw-attached.png>)

*Both enableDnsSupport and enableDnsHostnames come back True after the two modify-vpc-attribute calls.*

![Internet gateway created and attached](<../../screenshots/Lab-02/4.2-dns-and-igw-attached.png>)

*usms-igw (igw-184eb7e2) gets created and attached, and describe-internet-gateways confirms the attachment state is available and pointing at the right VPC.*

**Public and private subnets**

![Public subnet created in AZ a](<../../screenshots/Lab-02/5.1-public-and-private-subnets-created.png>)

*usms-public-subnet-a (subnet-c9b01466, 10.0.1.0/24) gets created, and modify-subnet-attribute switches on auto-assign public IPv4 for it.*

![Both subnets compared side by side](<../../screenshots/Lab-02/5.2-public-and-private-subnets-created.png>)

*usms-private-subnet-a (subnet-1150e689, 10.0.3.0/24) is created here too, and the combined table makes the difference obvious at a glance — public shows Public: True, private shows Public: False.*

**Route tables**

![Public route table with the default route to the internet gateway](<../../screenshots/Lab-02/6-public-route-table.png>)

*usms-public-rt (rtb-4579f26c) gets its 0.0.0.0/0 route to the internet gateway, sitting alongside the automatic local route AWS gives every route table for free.*

![Second public subnet for the second Availability Zone](<../../screenshots/Lab-02/7.1-second-az-public-subnet.png>)

*This is the "Your turn" task — associating the public subnet with usms-public-rt and getting back PUBLIC_ASSOC_A_ID.*

![Second AZ task fully verified](<../../screenshots/Lab-02/7.2-YourTurnProofOfCompletion.png>)

*usms-public-subnet-b gets created and associated with the same route table — now there are two associations on usms-public-rt, and describe-subnets shows three subnets spread across two Availability Zones.*

![Private route table with no internet route](<../../screenshots/Lab-02/8-private-route-table-no-internet.png>)

*usms-private-rt (rtb-9bb508ae) is created and associated with the private subnet, and I deliberately skipped the create-route call here — at this point it genuinely has no way out to the internet.*

**Proving the subnets are actually different**

![Effective route table comparison between the two subnets](<../../screenshots/Lab-02/9-subnets-proven-different.png>)

*This was the loop that actually settled the question — reading each subnet's effective route table straight from the API instead of trusting the name I'd given it. Public comes back with default-route-target=igw-184eb7e2, private comes back with None. That's the whole "what makes a subnet public" argument, right there in one line of output.*

**Security groups**

![Application security group created with its rules](<../../screenshots/Lab-02/10.1-security-groups-created.png>)

*usms-app-sg (sg-39a66c2dc43f3eef3) gets port 80, then port 22 restricted to the VPC's own CIDR, and then the 443 rule from the "Your turn" task with a proper description attached.*

![All three inbound rules on the application security group](<../../screenshots/Lab-02/10.2-security-groups-created.png>)

*describe-security-group-rules confirms all three inbound rules are actually there — 80, 443, and 22.*

![Database security group sourced from the application group](<../../screenshots/Lab-02/10.3-security-groups-created.png>)

*usms-db-sg's rule comes from the usms-db-sg-ingress.json document, and the verify table shows SourceSG holding the app group's ID with SourceCIDR sitting at None — exactly the group-referenced setup the lab was pushing for, not an address range.*

**Network ACL**

![Private NACL created and associated with the private subnet](<../../screenshots/Lab-02/11-private-nacl-associated.png>)

*After swapping the association over, describe-network-acls confirms the private subnet is now using usms-private-nacl (acl-0e6976c10a52c455f), that it's not the default ACL anymore, and that the swap genuinely happened.*

**NAT gateway**

![NAT gateway created and private route pointed at it](<../../screenshots/Lab-02/12-nat-gateway-and-private-route.png>)

*Elastic IP allocated, usms-nat (nat-0e606949dd0ad396c) created in the public subnet and reaching available, and then the private route table's default route gets pointed at it instead of sitting empty.*

**S3 gateway endpoint**

![S3 gateway endpoint created](<../../screenshots/Lab-02/13-s3-gateway-endpoint.png>)

*usms-s3-endpoint (vpce-ababcd9bbeb227091) is created against com.amazonaws.us-east-1.s3 and shows as associated with the private route table. What's interesting is that it reports available and lists the route table correctly, but the actual prefix-list route never shows up when I read the route table back — more on that in Section 7, but it's a known Floci thing, not something I broke.*

**Tag audit**

![Every resource audited for the Project=USMS tag](<../../screenshots/Lab-02/14.1-tag-audit.png>)

*Filtering describe-tags on Project=USMS pulls back everything this lab created — VPC, IGW, both route tables, both subnets shown here, both security groups, the NACL, the NAT gateway and its Elastic IP, and the S3 endpoint. Nothing missing, which was a relief given how many --tag-specifications flags I typed out over this lab.*

![Sorted subnet inventory saved to a file](<../../screenshots/Lab-02/14.2-(Your Task)Produce a table of every subnet in usms-vpc.png>)

*Extra task here — a table of every subnet in the VPC, sorted so private ones come before public ones, saved out to outputs/lab-02-subnet-inventory.txt.*

**Persistence proof**

![Network proven to survive a Floci restart](<../../screenshots/Lab-02/15-network-persistence-proof.png>)

*Recorded the VPC ID, subnet count, and security group count, then stopped and restarted Floci and re-derived everything by tag. The diff between before and after comes back empty, and the line I was actually hoping to see prints out: "PERSISTENCE PROVEN: VPC id, subnet count and security group count all unchanged."*

**Handoff file for Lab 3**

![configs/lab-02.env populated](<../../screenshots/Lab-02/16-lab02-env-written.png>)

*Every value in configs/lab-02.env gets looked up fresh by tag instead of reused from whatever was still sitting in a shell variable, and the empty-value check comes back with "all values populated" before I source it and spot-check a few values.*

**Git commit**

![Work committed to Git](<../../screenshots/Lab-02/17-commit Proof.png>)

*git status shows only configs/lab-02.env and the security group policy document staged — nothing under outputs/ snuck in — and the commit lands as 073e5d3.*

**Final verification**

![verify-lab-02.sh passing end to end](<../../screenshots/Lab-02/17-verify-lab02-pass.png>)

*Everything across the environment checks, Lab 1 dependencies, this lab's resources, tagging, and Git hygiene comes back green, finishing on PASS=33 FAIL=0.*

### 6.2 AWS Management Console Verification

There's no console screen to show here — Floci is CLI/API only and doesn't come with a web console, same as Lab 1. What I did instead was verify every resource's existence and configuration through `describe-*` calls right after creating it, which is basically the same thing you'd be doing by clicking around the VPC and EC2 consoles on real AWS, just from the terminal. The `verify-lab-02.sh` run at the end is probably the closest thing this setup has to a proper console-wide check, since it goes back and re-reads the actual configuration of everything rather than just confirming each resource exists.

## 7. Analysis and Discussion

Overall this lab did what it was supposed to. I came out the other end with a proper two-tier network — public web side, private data side, spread across two AZs — with routing, two separate layers of firewalling, a NAT gateway, and an S3 endpoint, all built through the CLI and checked automatically at the end with `verify-lab-02.sh` landing on 33 passes and zero failures. The two checkpoints I actually cared about both held up: the route-table comparison in Step 13 showed the public subnet pointing at the internet gateway and the private subnet pointing at nothing, and the restart test in Step 23 showed the VPC, its subnet count, and its security group count completely unchanged after stopping and starting Floci back up.

The one real hiccup was the S3 endpoint. The endpoint object itself was created fine and reported available, and it correctly showed the private route table as associated — but the actual prefix-list route that's supposed to land in that route table never showed up when I checked (Screenshot 13). Turns out this is a documented limitation on this particular Floci build, called out directly in the lab's own "Floci vs Real AWS" notes, and the advice was basically: note it down and move on, since Floci routes S3 traffic to its endpoint internally regardless of whether that route is visible from the outside. That's what I did, and it didn't cause any knock-on problems — the verification script only checks that the endpoint exists, not that the route shows up.

The bigger thing I noticed, though, is how little of this lab's "proof" actually comes from a command succeeding. Every create-* call here returned success no matter what, because Floci doesn't check security groups, NACLs, or IAM policies against real traffic — it just stores whatever you send it. So the two steps that actually prove something (the route table comparison and the restart test) exist specifically because "the command didn't error" tells you almost nothing about whether the thing you built is actually correct. That's the same lesson Lab 1 was making with its persistence proof, just showing up again here in a networking context instead of an identity one.

## 8. Reflection

**What did you learn about this AWS service?**
Mainly that a subnet being "public" isn't a property of the subnet at all — it's entirely about whether its route table has a path to an internet gateway. Not the name, not the tags, not whether it hands out public IPv4 addresses automatically. None of that actually makes it public on its own. I also got a much better feel for how security groups and NACLs are supposed to divide the work — security groups do the real, meaningful access control because they're stateful and can point at each other, while NACLs are more of a blunt, subnet-wide safety net that nothing at the instance level can accidentally undo.

**What challenges did you encounter?**
Honestly, the heredoc quoting rules gave me the most trouble — knowing when to use `<< EOF` unquoted so the shell fills in variables immediately (like the security group JSON and the final lab-02.env file), versus `<< 'EOF'` quoted so it leaves things like `${aws:username}` completely alone. Get that backwards and nothing tells you — it just quietly writes the wrong thing to the file. So I got into the habit of stopping and thinking about which one I actually needed before writing each one. The S3 endpoint's missing route threw me for a minute too, until I found the note in the lab explaining it was expected on this build.

**How would you apply this service in a real-world cloud environment?**
I'd use the same public/private split for anything with a data layer worth protecting — keep the database subnet with no inbound path from the internet at all, use a NAT gateway only for the outbound traffic it actually needs to handle, and always reference security groups by group ID rather than baking in an address that'll go stale the moment something gets rebuilt. I'd also default to gateway endpoints wherever they're supported, since there's really no downside — you get rid of both the cost and the exposure of sending traffic out to the internet just to reach another AWS service in the same region.

**What additional concepts or features would you like to explore?**
VPC peering and Transit Gateway for connecting multiple VPCs together, interface endpoints for the services that don't support the gateway type, and VPC Flow Logs so I can actually watch traffic happen instead of just reasoning about it — Floci doesn't forward real packets, so that side of things stayed entirely theoretical in this lab.

## 9. Conclusion

I'd say this lab did exactly what it set out to do. I ended up with a full VPC network for USMS — two Availability Zones, public and private subnets, proper routing, two layers of firewalling, a NAT gateway for controlled outbound access, and a gateway endpoint for S3 — built entirely through the CLI and checked end to end with `verify-lab-02.sh` coming back at 33 passes and zero failures. The main things I'm walking away with are a real understanding of what makes a subnet public, the practical split between security groups and NACLs, why referencing a security group beats hard-coding an address, and how gateway endpoints change where traffic actually goes. On the skills side, I got a lot more comfortable capturing resource IDs into variables instead of copying them by hand, using `--filters` and `--query` the right way round, and writing a config file that rebuilds itself from tags rather than trusting whatever's left in the shell. Bigger picture, this is the network everything else in the course is going to sit inside — Lab 3's instances, Lab 4's bucket access, Lab 6's RDS subnet group — so getting this right now matters more than any single lab on its own would suggest.

## 10. Appendix

**Policy / rule documents**
- `policies/usms-db-sg-ingress.json` — the group-referenced ingress rule for `usms-db-sg`

**Scripts**
- `scripts/utilities/verify-lab-02.sh` — end-to-end verification (environment, resources, tagging, Git hygiene)
- `scripts/cleanup/lab-02-cleanup.sh` — end-of-course teardown script; built and syntax-checked with `bash -n` but **not executed**, since Labs 3–6 all depend on this network

**Configuration**
- `configs/lab-02.env` — every VPC, subnet, route table, security group, NACL, NAT gateway, and endpoint ID, regenerated by tag for Lab 3 to consume

**Other evidence referenced above**
- `outputs/lab-02-subnet-inventory.txt` — sorted subnet inventory (Screenshot 14.2)
- `outputs/lab-02-pre-restart.txt` / `outputs/lab-02-post-restart.txt` — the before/after records used in the persistence proof (Screenshot 15)