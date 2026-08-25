
# Prediction for usms-audit-01:
- ec2:CreateVpc -> implicitDeny, because the auditor has read-only permissions and creating a VPC is not allowed.
- ec2:DescribeVpcs -> allowed, because it is a read operation covered by ec2:Describe*.

# 11. Review Questions

## 1. Trust vs permissions

The role is probably missing a **trust policy**. The trust policy decides who can assume the role, while the permissions policy decides what the role can do. IAM separates them so access and permissions can be controlled separately.

## 2. Explicit vs implicit deny

Both actions show `AccessDenied`, but the reason is different. `iam:CreateUser` is an **explicit deny** because the policy directly denies it. `dynamodb:PutItem` is an **implicit deny** because no policy allows it. I can check the policies or use policy simulation to identify the reason. To fix an implicit deny, I add an allow permission. An explicit deny must be removed or changed.

## 3. Roles over keys

Using `usms-ec2-app-role` is safer because it provides temporary credentials instead of storing a long-term access key in the application. If the configuration file is exposed, the access key could be stolen. Roles also make it easier to manage permissions without changing the application configuration.

## 4. The S3 ARN trap

The policy needs two different ARNs. `s3:ListBucket` uses the bucket ARN:

```text
arn:aws:s3:::usms-student-data
```

`s3:GetObject` needs the object ARN:

```text
arn:aws:s3:::usms-student-data/*
```

Without `/*`, the policy does not allow access to the objects inside the bucket.

## 5. The Floci illusion

A successful command in Floci does not guarantee that the policy will work exactly the same way in real AWS. Floci may not support every AWS feature. Before using a policy in production, I would test it with IAM policy simulation and test it in a separate AWS test environment.

## 6. The persistence trap

The users may disappear because `--persist` only mounts a directory and does not change the storage mode from `memory`. Sidecar services may also need a separate persistent storage path. Also, the settings used with `floci start` are not automatically remembered. A quick test is to create a user, restart Floci, and check whether the user still exists using `aws iam list-users`.

## 7. Configuration as evidence

A committed `docker-compose.yml` file provides a record of how the environment was configured. An instructor or colleague can check the repository to verify settings such as volumes, environment variables, and container configuration. A command typed once in the terminal is harder to verify or reproduce later.
