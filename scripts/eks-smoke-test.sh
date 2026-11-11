#!/usr/bin/env bash
set -euo pipefail

namespace="${1:-sre-demo}"
service="${2:-sre-web}"
port="${PORT:-18080}"

kubectl -n "$namespace" rollout status deployment/sre-web --timeout=300s
kubectl -n "$namespace" get pods -l app=sre-web -o wide
kubectl -n "$namespace" get svc "$service"

kubectl -n "$namespace" port-forward "service/$service" "$port:80" >/tmp/sre-eks-portforward.log 2>&1 &
pid=$!
trap 'kill "$pid" 2>/dev/null || true' EXIT

for attempt in $(seq 1 30); do
  if curl --fail --silent --show-error --max-time 5 "http://127.0.0.1:$port/" | grep -Fq 'Hello, World!'; then
    echo "PASS: EKS service serves Hello, World!"
    exit 0
  fi
  echo "Waiting for EKS service ($attempt/30)"
  sleep 5
done
cat /tmp/sre-eks-portforward.log >&2 || true
echo "FAIL: EKS smoke test did not pass" >&2
exit 1