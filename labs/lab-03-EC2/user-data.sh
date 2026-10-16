#!/bin/bash
# USMS web tier bootstrap. Runs ONCE, as root, at first boot, via cloud-init.
# Everything here must be non-interactive and idempotent.
set -x
exec > /var/log/usms-bootstrap.log 2>&1

echo "USMS bootstrap starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

dnf -y update
dnf -y install nginx

# Ask the instance about itself, using IMDSv2 (token-based, the secure default).
TOKEN=$(curl -sX PUT "http://169.254.169.254/latest/api/token" \
  -H "X-aws-ec2-metadata-token-ttl-seconds: 300")
meta() {
  curl -s -H "X-aws-ec2-metadata-token: $TOKEN" \
    "http://169.254.169.254/latest/meta-data/$1"
}

INSTANCE_ID=$(meta instance-id)
AZ=$(meta placement/availability-zone)
PRIVATE_IP=$(meta local-ipv4)

cat > /usr/share/nginx/html/index.html <<HTML
<!doctype html>
<html lang="en">
<head><meta charset="utf-8"><title>USMS - University Student Management System</title></head>
<body style="font-family:system-ui,sans-serif;max-width:40rem;margin:4rem auto">
  <h1>USMS Student Portal</h1>
  <p>University Student Management System &mdash; web tier</p>
  <table border="1" cellpadding="6" cellspacing="0">
    <tr><td>Instance</td><td>${INSTANCE_ID}</td></tr>
    <tr><td>Availability Zone</td><td>${AZ}</td></tr>
    <tr><td>Private address</td><td>${PRIVATE_IP}</td></tr>
    <tr><td>Bootstrapped</td><td>$(date -u +%Y-%m-%dT%H:%M:%SZ)</td></tr>
  </table>
</body>
</html>
HTML

# A machine-readable endpoint, so a health check does not have to parse HTML.
printf '{"service":"usms-web","status":"ok","instance":"%s","az":"%s"}\n' \
  "$INSTANCE_ID" "$AZ" > /usr/share/nginx/html/health.json

systemctl enable --now nginx
echo "USMS bootstrap complete"
