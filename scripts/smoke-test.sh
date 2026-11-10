
#!/usr/bin/env bash
set -euo pipefail

ALB_URL="${1:?usage: smoke-test.sh http://alb-dns-name}"

# Add http:// if only the ALB DNS name is provided
if [[ "$ALB_URL" != http://* && "$ALB_URL" != https://* ]]; then
  ALB_URL="http://${ALB_URL}"
fi

for attempt in $(seq 1 30); do
  if curl --fail --silent --show-error --max-time 10 "$ALB_URL" | grep -Fq 'Hello, World!'; then
    echo "PASS: ALB serves Hello, World! at $ALB_URL"
    exit 0
  fi

  echo "Waiting for healthy ALB target (attempt $attempt/30)"
  sleep 10
done

echo "FAIL: Application unavailable through ALB" >&2
exit 1
