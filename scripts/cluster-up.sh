#!/usr/bin/env bash
#
# Make sure a local Kubernetes cluster is available.
#
# If kubectl can already reach a cluster, we use that one. Otherwise we spin up
# a throwaway local cluster with kind (https://kind.sigs.k8s.io), which only
# needs Docker.
set -euo pipefail

CLUSTER_NAME="${RECIPES_CLUSTER_NAME:-recipes}"

if kubectl cluster-info >/dev/null 2>&1; then
  CURRENT_CTX="$(kubectl config current-context 2>/dev/null || echo '?')"
  if [[ "$CURRENT_CTX" == "kind-${CLUSTER_NAME}" || "$CURRENT_CTX" == kind-* ]]; then
    echo "Reusing the existing kind cluster (context: ${CURRENT_CTX}) — no need to recreate it."
  else
    echo "A Kubernetes cluster is already reachable (context: ${CURRENT_CTX}). Using it."
    echo "(Run 'make cluster-down' first if you'd rather spin up a fresh kind cluster.)"
  fi
  exit 0
fi

echo "No reachable Kubernetes cluster found."

# Even if kubectl can't reach it, an already-created kind cluster just needs its
# context selected rather than a full recreate.
if command -v kind >/dev/null 2>&1 && kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "Found an existing kind cluster '${CLUSTER_NAME}'. Selecting its context instead of recreating it."
  kubectl config use-context "kind-${CLUSTER_NAME}" >/dev/null
  kubectl cluster-info >/dev/null 2>&1 && { echo "Cluster ready."; exit 0; }
  echo "That kind cluster isn't responding; recreating it." >&2
  kind delete cluster --name "${CLUSTER_NAME}" >/dev/null 2>&1 || true
fi

if ! command -v kind >/dev/null 2>&1; then
  cat >&2 <<'EOF'

This recipe needs a local cluster and the easiest option is kind, which wasn't
found on your PATH. Install it, then re-run this command:

  macOS (Homebrew):   brew install kind
  Linux / other:      https://kind.sigs.k8s.io/docs/user/quick-start/#installation

kind requires Docker to be running.
EOF
  exit 1
fi

if ! docker info >/dev/null 2>&1; then
  echo "kind needs Docker, but Docker doesn't appear to be running. Start Docker and try again." >&2
  exit 1
fi

echo "Creating a local kind cluster named '${CLUSTER_NAME}'..."
kind create cluster --name "${CLUSTER_NAME}"
echo
echo "Cluster ready. Current context:"
kubectl config current-context
