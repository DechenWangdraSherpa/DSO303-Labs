# Lab 01 — IAM — completed

## What exists after this lab
- Environment: Floci via docker-compose.yml, FLOCI_STORAGE_MODE=hybrid,
  bind-mounted to ~/floci-data, persistence proven in Step 14
- Groups: usms-admins, usms-developers, usms-auditors
- Users: usms-admin-01, usms-dev-01, usms-audit-01
- Customer managed policies: USMSDeveloperBase (v2), USMSStudentDataReadWrite,
  USMSAssumeAppRoles, USMSLambdaBasic
- Inline policy: USMSSelfManageCredentials on usms-dev-01
- Roles: usms-ec2-app-role, usms-lambda-exec-role, usms-developer-role
- Instance profile: usms-ec2-app-profile

## Reproduce
    source ~/aws-floci-course/configs/course.env
    ./scripts/setup/floci-up.sh
    source ~/aws-floci-course/configs/lab-01.env
    ./scripts/utilities/verify-lab-01.sh

## Evidence
- [ ] whoami.sh output showing account 000000000000
- [ ] floci-storage-check.sh output, all [ok]
- [ ] Step 14 persistence proof (user survived a restart)
- [ ] verify-lab-01.sh with FAIL=0

## Problems I hit and how I fixed them
(fill this in — it is graded)
