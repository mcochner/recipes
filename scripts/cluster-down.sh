#!/usr/bin/env bash
#
# Tear down the local kind cluster created by cluster-up.sh.
#
# This only ever deletes the kind cluster we created. It will not touch a
# cluster you brought yourself (e.g. Docker Desktop, minikube, or a cloud
# cluster), so it's safe to run.
set -euo pipefail

CLUSTER_NAME="${RECIPES_CLUSTER_NAME:-recipes}"

if ! command -v kind >/dev/null 2>&1; then
  echo "kind isn't installed, so there's no kind cluster to delete. Nothing to do."
  exit 0
fi

if kind get clusters 2>/dev/null | grep -qx "${CLUSTER_NAME}"; then
  echo "Deleting kind cluster '${CLUSTER_NAME}'..."
  kind delete cluster --name "${CLUSTER_NAME}"
else
  echo "No kind cluster named '${CLUSTER_NAME}' found. Nothing to do."
fi
