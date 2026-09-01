#!/usr/bin/env bash
# Spin up a local kind cluster and deploy the dev overlay end-to-end.
#
# Requires: docker, kind, kubectl
#
# Note: kind's default CNI (kindnet) applies NetworkPolicy objects but does not
# ENFORCE them. To actually enforce the segmentation policies, install a
# NetworkPolicy-capable CNI (Calico/Cilium) — see README.
set -euo pipefail

CLUSTER=capstone
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INGRESS_NGINX_REF="controller-v1.11.3"

cd "$ROOT"

echo "==> Creating kind cluster '${CLUSTER}'"
if ! kind get clusters | grep -qx "$CLUSTER"; then
  kind create cluster --config kind/kind-config.yaml
else
  echo "    cluster already exists, reusing"
fi

echo "==> Building API image"
docker build -t capstone-api:latest ./api

echo "==> Loading image into the cluster"
kind load docker-image capstone-api:latest --name "$CLUSTER"

echo "==> Installing ingress-nginx (kind)"
kubectl apply -f "https://raw.githubusercontent.com/kubernetes/ingress-nginx/${INGRESS_NGINX_REF}/deploy/static/provider/kind/deploy.yaml"

echo "==> Waiting for the ingress controller to be ready"
kubectl -n ingress-nginx wait --for=condition=Ready pod \
  --selector=app.kubernetes.io/component=controller --timeout=180s

echo "==> Deploying dev overlay"
kubectl apply -k k8s/overlays/dev

echo "==> Waiting for workloads to become ready"
kubectl -n capstone rollout status statefulset/postgres --timeout=180s
kubectl -n capstone rollout status deployment/redis     --timeout=120s
kubectl -n capstone rollout status deployment/api        --timeout=180s
kubectl -n capstone rollout status deployment/nginx      --timeout=120s

cat <<'EOF'

==> Done. Try it:

    curl -H 'Host: capstone.local' http://localhost:8080/health
    curl -H 'Host: capstone.local' http://localhost:8080/
    curl -H 'Host: capstone.local' http://localhost:8080/db-check

Tear down with: ./scripts/teardown-kind.sh
EOF
