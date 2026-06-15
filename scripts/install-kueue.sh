#!/usr/bin/env bash
#
# Install Kueue into the current cluster via Helm, with the elastic-job feature
# gates turned ON, using a locally-built controller image loaded into kind.
#
# This is the "be there next time I recreate the cluster" step: it is idempotent
# (re-running upgrades in place) and declarative, so after a `kind delete` you
# just run it again (e.g. `make kueue-up`) and Kueue comes back exactly as
# configured here.
#
# Configurable via env vars:
#   KUEUE_SRC        path to a Kueue source checkout (used for the chart and to
#                    build the image).            default: $HOME/code/kueue
#   KUEUE_IMAGE      full controller image ref to install. When unset it is
#                    derived from KUEUE_SRC's `git describe`.
#   KUEUE_CHART      chart location.              default: $KUEUE_SRC/charts/kueue
#   KUEUE_BUILD      "1" to build the image if it isn't present.  default: 1
#   KUEUE_NAMESPACE  install namespace.           default: kueue-system
#   RECIPES_CLUSTER_NAME  kind cluster to load the image into. Defaults to the
#                    cluster behind the current kube-context (kind-<name>).
set -euo pipefail

KUEUE_SRC="${KUEUE_SRC:-$HOME/code/kueue}"
KUEUE_NAMESPACE="${KUEUE_NAMESPACE:-kueue-system}"
KUEUE_BUILD="${KUEUE_BUILD:-1}"
CHART="${KUEUE_CHART:-$KUEUE_SRC/charts/kueue}"

# Prefer a helm on PATH; otherwise fall back to the one vendored in the Kueue
# checkout ($KUEUE_SRC/bin/helm), so you don't need a separate install.
HELM="$(command -v helm 2>/dev/null || true)"
if [[ -z "$HELM" && -x "$KUEUE_SRC/bin/helm" ]]; then
  HELM="$KUEUE_SRC/bin/helm"
fi
if [[ -z "$HELM" ]]; then
  echo "install-kueue: 'helm' not found on PATH and no $KUEUE_SRC/bin/helm." >&2
  echo "  Install it with: brew install helm   (or run 'make helm' in your Kueue checkout)" >&2
  exit 1
fi

for tool in kubectl docker; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "install-kueue: '$tool' is required but was not found on PATH." >&2
    exit 1
  }
done

# Figure out which kind cluster to load the image into (from the current context).
CTX="$(kubectl config current-context 2>/dev/null || true)"
CLUSTER_NAME="${RECIPES_CLUSTER_NAME:-}"
if [[ -z "$CLUSTER_NAME" && "$CTX" == kind-* ]]; then
  CLUSTER_NAME="${CTX#kind-}"
fi

# Resolve the image ref (build a default from the source tree's git describe).
if [[ -z "${KUEUE_IMAGE:-}" ]]; then
  [[ -d "$KUEUE_SRC" ]] || {
    echo "install-kueue: KUEUE_SRC ($KUEUE_SRC) not found." >&2
    echo "  Set KUEUE_SRC to your Kueue checkout, or set KUEUE_IMAGE to a prebuilt ref." >&2
    exit 1
  }
  GIT_TAG="$(cd "$KUEUE_SRC" && git describe --tags --dirty --always)"
  KUEUE_IMAGE="us-central1-docker.pkg.dev/k8s-staging-images/kueue/kueue:${GIT_TAG}"
fi
IMAGE_REPO="${KUEUE_IMAGE%:*}"
IMAGE_TAG="${KUEUE_IMAGE##*:}"

echo "install-kueue: image  = $KUEUE_IMAGE"
echo "install-kueue: chart  = $CHART"
echo "install-kueue: target = ${CLUSTER_NAME:-<current context>} / ns=$KUEUE_NAMESPACE"

# Build the host-arch image if asked and it isn't already in the local daemon.
if [[ "$KUEUE_BUILD" == "1" ]] && ! docker image inspect "$KUEUE_IMAGE" >/dev/null 2>&1; then
  [[ -d "$KUEUE_SRC" ]] || {
    echo "install-kueue: need to build $KUEUE_IMAGE but KUEUE_SRC ($KUEUE_SRC) not found." >&2
    exit 1
  }
  echo "install-kueue: building image (host arch) via 'make kind-image-build'..."
  make -C "$KUEUE_SRC" kind-image-build
fi

# Load the image into the kind node so an IfNotPresent pull resolves locally.
if [[ -n "$CLUSTER_NAME" ]] && command -v kind >/dev/null 2>&1; then
  echo "install-kueue: loading $KUEUE_IMAGE into kind cluster '$CLUSTER_NAME'..."
  kind load docker-image "$KUEUE_IMAGE" --name "$CLUSTER_NAME"
else
  echo "install-kueue: not a kind cluster (or kind missing) — skipping image load." >&2
  echo "  The image must be pullable by the cluster, or set pullPolicy accordingly." >&2
fi

echo "install-kueue: helm upgrade --install (using $HELM)..."
"$HELM" upgrade --install kueue "$CHART" \
  --namespace "$KUEUE_NAMESPACE" --create-namespace \
  --set controllerManager.manager.image.repository="$IMAGE_REPO" \
  --set controllerManager.manager.image.tag="$IMAGE_TAG" \
  --set controllerManager.manager.image.pullPolicy=IfNotPresent \
  --set controllerManager.manager.logLevel=6 \
  --set 'controllerManager.featureGates[0].name=ElasticJobsViaWorkloadSlices' \
  --set 'controllerManager.featureGates[0].enabled=true' \
  --set 'controllerManager.featureGates[1].name=ElasticJobsViaWorkloadSlicesSiblingCap' \
  --set 'controllerManager.featureGates[1].enabled=true' \
  --wait --timeout 5m

kubectl -n "$KUEUE_NAMESPACE" rollout status deploy/kueue-controller-manager --timeout=180s
echo "install-kueue: Kueue is ready with elastic gates enabled."
echo "  ElasticJobsViaWorkloadSlices=true, ElasticJobsViaWorkloadSlicesSiblingCap=true"
echo "  image: $KUEUE_IMAGE"
