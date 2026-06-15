# Elastic Workload Slices: Who Ungates the Scale-Up Pods?

*Following a reconcile key through a Kueue elastic-job scale-up.*

> **Run it locally:** `make k8s-elastic-slices` executes every step below
> end-to-end. Step through it command-by-command with
> `make k8s-elastic-slices STEP=1`. See the [root README](../README.md) for setup.
>
> **Needs a cluster with Kueue installed** (built from a branch where the
> `ElasticJobsViaWorkloadSlices` *and* `ElasticJobsViaWorkloadSlicesSiblingCap`
> feature gates are enabled), plus `kubectl` and [`jq`](https://jqlang.github.io/jq/).

In [controllers-and-reconcile](./controllers-and-reconcile.md) we watched the
ReplicaSet controller turn a **Pod** event into a **ReplicaSet** reconcile key.
This recipe follows the same idea into a real production controller — Kueue's
**elastic-job ungater** — where the mapping has a twist that decides who is
responsible for a scaled-up Job's surplus Pods.

---

## The key idea

An **elastic Job** (annotated `kueue.x-k8s.io/elastic-job: "true"`) can change
its `parallelism` while running. Kueue models each size as a **workload slice**:

- The first admission creates the **root** slice (a `Workload`), which reserves
  quota for the initial replica count.
- Scaling up creates a **replacement** slice — a *new* `Workload` that reserves
  quota for the larger count. The root slice is then retired.

Kueue gates every elastic Pod with a scheduling gate
(`kueue.x-k8s.io/elastic-job`) and the **ungater** removes that gate once quota
exists. Just like the ReplicaSet controller, the ungater watches Pods but
reconciles **Workloads**, mapping each Pod to a Workload **key** via the Pod's
`kueue.x-k8s.io/workload` annotation:

| | ReplicaSet controller | Kueue elastic-job ungater |
| --- | --- | --- |
| Reconciles (the key) | ReplicaSet | **Workload** (a slice) |
| Pod → key mapping via | ownerReference | the Pod's `kueue.x-k8s.io/workload` annotation |
| Acts on | creates/deletes Pods | removes the **scheduling gate** on Pods |

The twist you'll see: **every Pod — including the scale-up surplus — keeps the
*root* slice's name in that annotation**, even though the quota for the surplus
lives on the *replacement* slice. So the reconcile key for those Pods is always
the **root** Workload, and the root's own grant no longer covers them. That is
exactly the situation the `ElasticJobsViaWorkloadSlicesSiblingCap` gate
addresses, and in the bonus step you'll watch it both ways.

---

## Step 1 — Preflight, queues, and a live view of reconcile keys

Check the tools and the cluster, (re)create the quota objects, and start
streaming the Kueue manager's logs into a file so we can read the reconcile keys
it prints. (Want a live view? `tail -f` the printed log path in another terminal.)

```bash
command -v jq  >/dev/null || { echo "this recipe needs jq (brew install jq)"; exit 1; }
kubectl -n kueue-system get deploy kueue-controller-manager >/dev/null 2>&1 || {
  echo "Kueue is not installed (no kueue-system/kueue-controller-manager)."
  echo "Install Kueue built from the elastic branch with the feature gates enabled, then re-run."
  exit 1
}
kubectl -n kueue-system logs deploy/kueue-controller-manager --tail=-1 2>/dev/null \
  | grep -c '"ElasticJobsViaWorkloadSlices":true' >/dev/null || {
  echo "ElasticJobsViaWorkloadSlices is not enabled on the running manager."; exit 1; }
echo "preflight OK: kueue installed, elastic enabled, jq present"
```

Create the ResourceFlavor / ClusterQueue / LocalQueue (idempotent):

```bash
kubectl apply -f - <<'EOF'
apiVersion: kueue.x-k8s.io/v1beta1
kind: ResourceFlavor
metadata:
  name: default-flavor
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: ClusterQueue
metadata:
  name: cluster-queue
spec:
  namespaceSelector: {}
  resourceGroups:
  - coveredResources: ["cpu", "memory"]
    flavors:
    - name: default-flavor
      resources:
      - name: cpu
        nominalQuota: "10"
      - name: memory
        nominalQuota: "4Gi"
---
apiVersion: kueue.x-k8s.io/v1beta1
kind: LocalQueue
metadata:
  name: user-queue
  namespace: default
spec:
  clusterQueue: cluster-queue
EOF
```

Start by clearing any leftovers from a previous run, then tail the manager logs
and define two helpers: `mark` (remember where we are in the log) and
`show_since` (print only the ungater's reconcile keys produced since the mark).

```bash
kubectl delete job sample-elastic-job --ignore-not-found --wait=true >/dev/null 2>&1 || true

MGR_LOG="$(mktemp -t kueue-mgr.XXXXXX.log)"
kubectl logs -f -n kueue-system deploy/kueue-controller-manager > "$MGR_LOG" 2>&1 &
MGR_PID=$!
trap 'kill "$MGR_PID" 2>/dev/null || true' EXIT

mark() { __MARK="$(wc -l < "$MGR_LOG" | tr -d ' ')"; }
show_since() {
  tail -n "+$(( ${__MARK:-0} + 1 ))" "$MGR_LOG" \
  | jq -rR 'fromjson?
            | select(.logger=="ElasticJobUngater")
            | select(.msg|test("Reconcile ElasticJobUngater|identified elastic pods to ungate|ungating elastic pod"))
            | "  " + .msg
              + "  key=" + (.namespace // "?") + "/" + (.name // "?")
              + (if .count != null then "  count=" + (.count|tostring) else "" end)
              + (if .pod   != null then "  pod="   + .pod.name           else "" end)' \
  || true
}
echo "tailing manager logs (PID=$MGR_PID): $MGR_LOG"
```

## Step 2 — Admit an elastic Job at parallelism 2

The Job is annotated `kueue.x-k8s.io/elastic-job: "true"`. Kueue creates one
**root** slice, reserves quota for 2, and the ungater removes the gate from 2 Pods.

```bash
mark
kubectl apply -f - <<'EOF'
apiVersion: batch/v1
kind: Job
metadata:
  name: sample-elastic-job
  namespace: default
  annotations:
    kueue.x-k8s.io/elastic-job: "true"
  labels:
    kueue.x-k8s.io/queue-name: user-queue
spec:
  parallelism: 2
  completions: 50
  template:
    spec:
      containers:
      - name: dummy-job
        image: registry.k8s.io/e2e-test-images/agnhost:2.53
        command: ["/bin/sh"]
        args: ["-c", "sleep 3600"]
        resources:
          requests:
            cpu: "100m"
            memory: "100Mi"
      restartPolicy: Never
EOF
```

Wait until both Pods are running (gate removed):

<!-- recipe:retry timeout=120 interval=3 -->
```bash
[ "$(kubectl get pods -l job-name=sample-elastic-job --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')" -ge 2 ]
```

Now look at the reconcile keys the ungater logged. Every key is a **Workload**
(`default/job-sample-elastic-job-...`), and you'll see it identify and ungate the Pods:

```bash
show_since
```

Capture the root slice's name — we'll point back to it after the scale-up:

<!-- recipe:capture ROOT_WL -->
```bash
ROOT_WL="$(kubectl get workloads.kueue.x-k8s.io -o jsonpath='{.items[0].metadata.name}')"
echo "root slice (Workload) = $ROOT_WL"
```

## Step 3 — Scale up to 4: a new slice appears

`kubectl scale` doesn't work on Jobs (no scale subresource), so we patch
`parallelism` directly. This makes Kueue create a **replacement** slice that
reserves quota for 4, and the Job controller creates 2 more (gated) Pods.

```bash
mark
kubectl patch job/sample-elastic-job --type=merge -p '{"spec":{"parallelism":4}}'
```

Wait for all 4 Pods to be running:

<!-- recipe:retry timeout=120 interval=3 -->
```bash
[ "$(kubectl get pods -l job-name=sample-elastic-job --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')" -ge 4 ]
```

There are now **two** slices — the retired root and the admitted replacement:

```bash
kubectl get workloads.kueue.x-k8s.io -o custom-columns=\
'NAME:.metadata.name,CHAIN:.metadata.annotations.kueue\.x-k8s\.io/workload-slice-name,ADMITTED:.status.conditions[?(@.type=="Admitted")].status,QUOTA:.status.conditions[?(@.type=="QuotaReserved")].status'
```

And the ungater's reconcile keys for the scale-up:

```bash
show_since
```

## Step 4 — The reveal: every Pod points at the *root* slice

This is the whole point. List the Pods with their `kueue.x-k8s.io/workload`
annotation (the reconcile key the ungater maps them to):

```bash
kubectl get pods -l job-name=sample-elastic-job -o custom-columns=\
'POD:.metadata.name,WORKLOAD-KEY:.metadata.annotations.kueue\.x-k8s\.io/workload,CHAIN:.metadata.annotations.kueue\.x-k8s\.io/workload-slice-name,GATED:.spec.schedulingGates[*].name'
```

```bash
echo "Root slice:        $ROOT_WL"
echo "Replacement slice: $(kubectl get workloads.kueue.x-k8s.io -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' | grep -v "^$ROOT_WL$" | head -1)"
echo
echo "Note: EVERY pod's WORKLOAD-KEY is the root slice ($ROOT_WL)."
echo "The replacement slice holds the quota for the 2 surplus pods, yet no pod"
echo "references it. So only the ROOT reconcile ever matches these pods — and the"
echo "root's own grant was 2. To ungate the 2 surplus pods the ungater must read"
echo "the replacement (sibling) slice's reservation. That is the sibling cap."
```

## Step 5 — (Bonus) Turn the sibling cap OFF and watch surplus get stuck

With `ElasticJobsViaWorkloadSlicesSiblingCap` disabled, the cap is computed
**per slice**: the root reconcile only sees its own grant, so a further scale-up
leaves the new surplus Pods gated forever. This step mutates the running manager
and restores it at the end.

Disable the gate (rewrites the manager's `--feature-gates` arg) and wait for the
new Pod to roll out:

<!-- recipe:allow-failure -->
```bash
mark
NEWARGS="$(kubectl -n kueue-system get deploy kueue-controller-manager -o json \
  | jq -c '[.spec.template.spec.containers[0].args[]
            | if test("^--feature-gates=") then "--feature-gates=ElasticJobsViaWorkloadSlices=true,ElasticJobsViaWorkloadSlicesSiblingCap=false" else . end]')"
kubectl -n kueue-system patch deploy/kueue-controller-manager --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":$NEWARGS}]"
kubectl -n kueue-system rollout status deploy/kueue-controller-manager --timeout=120s
```

The manager pod was replaced, so re-tail the logs:

```bash
kill "$MGR_PID" 2>/dev/null || true
MGR_LOG="$(mktemp -t kueue-mgr.XXXXXX.log)"
kubectl logs -f -n kueue-system deploy/kueue-controller-manager > "$MGR_LOG" 2>&1 &
MGR_PID=$!
mark
echo "re-tailing manager logs (sibling cap now OFF): $MGR_LOG"
```

Scale 4 → 6 and give the controller a few seconds to (not) ungate:

```bash
kubectl patch job/sample-elastic-job --type=merge -p '{"spec":{"parallelism":6}}'
sleep 12
kubectl get pods -l job-name=sample-elastic-job -o custom-columns=\
'POD:.metadata.name,PHASE:.status.phase,GATED:.spec.schedulingGates[*].name'
echo "Expect: 2 surplus pods stuck in Pending/SchedulingGated — per-slice cap left them gated."
```

The ungater did run on the root key, but capped ungating to the root's own grant:

```bash
show_since
```

Now restore the gate (sibling cap back ON) and watch the stuck Pods get ungated:

```bash
mark
RESTOREARGS="$(kubectl -n kueue-system get deploy kueue-controller-manager -o json \
  | jq -c '[.spec.template.spec.containers[0].args[]
            | if test("^--feature-gates=") then "--feature-gates=ElasticJobsViaWorkloadSlices=true" else . end]')"
kubectl -n kueue-system patch deploy/kueue-controller-manager --type=json \
  -p "[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/args\",\"value\":$RESTOREARGS}]"
kubectl -n kueue-system rollout status deploy/kueue-controller-manager --timeout=120s
```

<!-- recipe:retry timeout=120 interval=3 -->
```bash
[ "$(kubectl get pods -l job-name=sample-elastic-job --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l | tr -d ' ')" -ge 6 ]
```

```bash
echo "All 6 running again — restoring the sibling cap let the root reconcile read"
echo "the replacement slice's grant (6) and ungate the surplus."
```

## Step 6 — Clean up

```bash
kubectl delete job sample-elastic-job --ignore-not-found
kill "$MGR_PID" 2>/dev/null || true
echo "Done. (Queues and Kueue are left installed.)"
```

The manager log tail is stopped automatically when the recipe exits (the `trap`
from Step 1). The ClusterQueue/LocalQueue are left in place so you can re-run.

---

## What just happened

- **One reconcile = one key.** Every ungater reconcile key was a **Workload**
  (a slice) `{namespace, name}`, never a Pod — the Pod events were *mapped* to a
  Workload via the `kueue.x-k8s.io/workload` annotation.
- **The mapping pins responsibility to the root.** Scale-up surplus Pods keep
  the **root** slice's name in that annotation, so only the root slice's
  reconcile ever matches them — even though the **replacement** slice holds their
  quota.
- **That's why the sibling cap exists.** To ungate the surplus, the root
  reconcile must look across the slice **chain** (its sibling slices) for the
  current granted count. With `ElasticJobsViaWorkloadSlicesSiblingCap` **off**,
  the per-slice cap uses only the root's own (stale) grant and the surplus stays
  gated; **on**, the chain-aware cap releases them.
- **Level-triggered, like every controller.** The ungater never gets told "a
  pod was added." It re-derives "granted N, gated M, ungate up to the cap" from
  current state each time.
