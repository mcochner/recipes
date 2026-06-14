# Controllers & the Reconcile Loop: Watch Pods, Reconcile ReplicaSets

*Seeing the keys that drive a Kubernetes controller.*

> **Run it locally:** `make k8s-reconcile-observer` executes every step below
> end-to-end. Step through it command-by-command with
> `make k8s-reconcile-observer STEP=1`. Prefer to do it by hand? Copy the
> commands as you read. See the [root README](../README.md) for setup.

In the [owner-references](./owner-references.md) recipe you deleted `cm1` and
`cm2` vanished on its own. That "on its own" was a **controller** running its
**reconcile loop**. Almost everything Kubernetes does — recreating a crashed
Pod, rolling out a Deployment, garbage-collecting children — is some controller
reconciling. This recipe makes that loop *visible*: we run a tiny, read-only
controller of our own that prints the **reconcile key** for every event, so you
can watch a Pod being deleted turn into a *ReplicaSet* being reconciled.

---

## The key idea

A controller **watches** one or more Kinds, but each call to `Reconcile` is
about **exactly one object**, identified by a **key** = `{namespace, name}`.

- A watch is only a *trigger*. It says "something happened, go look." It does
  **not** tell the controller *what* changed.
- For each event, the controller decides **which key** to enqueue. That
  translation step is the **mapping** (a.k.a. event handler).
- The ReplicaSet controller watches **two** Kinds:
  - a **ReplicaSet** changed → reconcile **that** ReplicaSet (identity mapping)
  - a **Pod** changed → reconcile the **ReplicaSet that owns the Pod**, found via
    the Pod's `controller: true` ownerReference — the very ownerReference from
    the [owner-references](./owner-references.md) recipe.

So the reconcile key is **always a ReplicaSet key**, even when the thing that
moved was a Pod. And because the controller only ever compares *current state*
to *desired state* (it is **level-triggered**), it never needs to be told what
changed — it just re-derives "desired 3, actual 2, create 1" every time.

Our observer is in [`reconcile-observer/main.go`](./reconcile-observer/main.go).
Its whole controller is three lines:

```text
ctrl.NewControllerManagedBy(mgr).
    For(&appsv1.ReplicaSet{}).                                             // watch #1: ReplicaSets
    Watches(&corev1.Pod{}, handler.EnqueueRequestsFromMapFunc(mapPodToRS)). // watch #2: Pods -> owner RS
    Complete(observer)
```

It only **reads and prints** — it never creates or deletes anything — so it's
safe to run next to the cluster's real `kube-controller-manager`. The real
controller does the work (recreating Pods); ours just narrates the keys:

```text
MAP pod -> RS      pod=demo-7fb87548c-zz8xl  enqueue=default/demo-7fb87548c
RECONCILE KEY      key=default/demo-7fb87548c
    desired vs actual   key=default/demo-7fb87548c desired=3 actual=3
```

---

## Step 1 — Build the observer and start it in the background

We build the controller, run it in the background, and send its output to a log
file. (Want a live view? Open a second terminal and `tail -f` that log file.)

```bash
OBSERVER_DIR="kubernetes/reconcile-observer"
OBSERVER_LOG="$(mktemp -t reconcile-observer.XXXXXX.log)"

# Build it (first run downloads controller-runtime; give it a minute).
( cd "$OBSERVER_DIR" && go build -o observer . )

# A couple of helpers to keep the steps below readable.
mark() { echo "===== $* =====" >> "$OBSERVER_LOG"; }
# Print the observer's interesting lines produced SINCE the most recent mark.
# The observer watches EVERY ReplicaSet in the cluster (coredns, etc.), so we
# scope the display to our "demo" workload to keep the output focused.
show_since() {
  awk '/^===== /{n=NR} {a[NR]=$0} END{for (i=n+1;i<=NR;i++) print a[i]}' "$OBSERVER_LOG" \
    | grep -aE "MAP pod|RECONCILE KEY|desired vs actual|not found" \
    | grep -a demo || true
}

# Run it in the background; stop it automatically when the recipe exits.
"$OBSERVER_DIR/observer" > "$OBSERVER_LOG" 2>&1 &
OBSERVER_PID=$!
trap 'kill "$OBSERVER_PID" 2>/dev/null || true' EXIT
echo "observer PID=$OBSERVER_PID  log=$OBSERVER_LOG"
```

Wait until it has connected to the cluster and started watching:

<!-- recipe:retry timeout=90 interval=2 -->
```bash
grep -q "observer started" "$OBSERVER_LOG"
```

## Step 2 — Create a workload and watch the keys appear

Creating a Deployment makes the Deployment controller create a **ReplicaSet**,
which creates 3 **Pods**. Every one of those is a watch event the observer turns
into the *same* ReplicaSet key.

```bash
mark "create deployment (replicas=3)"
kubectl create deployment demo --image=nginx --replicas=3
```

Wait for the ReplicaSet to settle at 3 pods, then look at what the observer saw:

<!-- recipe:retry timeout=120 interval=2 -->
```bash
[ "$(kubectl get pods -l app=demo --no-headers 2>/dev/null | wc -l | tr -d ' ')" -ge 3 ]
```

```bash
show_since
```

Notice: every `RECONCILE KEY` line is a `default/demo-<hash>` **ReplicaSet** key,
and `desired vs actual` climbs to `3 / 3`.

## Step 3 — Delete a Pod: see the Pod → ReplicaSet mapping

This is the heart of it. You delete a **Pod**, but a **ReplicaSet** gets
reconciled — because the Pod's ownerReference maps the event back to its owner.

```bash
mark "delete one pod"
kubectl delete "$(kubectl get pod -l app=demo -o name | head -1)"
```

Wait for the real controller to bring it back to 3, then inspect:

<!-- recipe:retry timeout=120 interval=2 -->
```bash
[ "$(kubectl get pods -l app=demo --no-headers 2>/dev/null | wc -l | tr -d ' ')" -ge 3 ]
```

```bash
show_since
```

You should see a `MAP pod -> RS  pod=demo-...  enqueue=default/demo-<hash>` line
(the deleted Pod being **translated** into its owner's key), followed by a
`RECONCILE KEY` for that ReplicaSet. You never told anything to "recreate the
pod" — the reconcile simply saw `actual 2 < desired 3` and the real controller
made one.

## Step 4 — Scale: a ReplicaSet event, with no Pod involved

Editing `replicas` changes the **ReplicaSet object itself** (watch #1, the
identity mapping), so this time you'll see `RECONCILE KEY` with **no** preceding
`MAP pod -> RS` line.

```bash
mark "scale to 5"
kubectl scale deployment demo --replicas=5
```

<!-- recipe:retry timeout=120 interval=2 -->
```bash
[ "$(kubectl get pods -l app=demo --no-headers 2>/dev/null | wc -l | tr -d ' ')" -ge 5 ]
```

```bash
show_since
```

`desired vs actual` now shows `desired=5`, and the gap is filled by Pod
creations — each of which maps back to the same ReplicaSet key.

## Step 5 — (Bonus) Fight the controller

Create a rogue Pod that matches the ReplicaSet's selector. The ReplicaSet will
see `actual > desired` and the real controller will **delete one** to get back
to 5 — proof that it only cares about current vs. desired, not history.

<!-- recipe:allow-failure -->
```bash
mark "rogue pod"
HASH="$(kubectl get rs -l app=demo -o jsonpath='{.items[0].metadata.labels.pod-template-hash}')"
kubectl run intruder --image=nginx --labels="app=demo,pod-template-hash=$HASH"
sleep 8
show_since
kubectl get pods -l app=demo --no-headers | wc -l
```

## Step 6 — Clean up

Deleting the Deployment removes the ReplicaSet, and the Pods vanish via
ownerReferences + the garbage collector (the [owner-references](./owner-references.md)
behavior again). The observer logs a final reconcile that can't find the
ReplicaSet anymore.

```bash
mark "cleanup"
kubectl delete deployment demo
kubectl delete pod intruder --ignore-not-found
sleep 4
show_since
```

The observer is stopped automatically when the recipe exits (the `trap` from
Step 1). If you ran it by hand, stop it with `kill "$OBSERVER_PID"`.

---

## What just happened

- **One reconcile = one key.** Every `RECONCILE KEY` was a `{namespace, name}`
  of a **ReplicaSet** — never a Pod.
- **Two watches, one reconciled Kind.** `For(&ReplicaSet{})` and
  `Watches(&Pod{}, ...)` both feed the *same* reconcile function.
- **The mapping is the bridge.** A lone Pod event has nothing to reconcile *about
  a Pod* here, so `mapPodToRS` reads the Pod's ownerReference and enqueues the
  **owner's** key instead.
- **Level-triggered.** Reconcile was never handed "a pod was deleted." It
  re-counted `desired vs actual` from current state and acted. That's why
  controllers self-heal.

## Where this shows up: Kueue's elastic-job ungater

Kueue's elastic-job ungater is the same shape with the names swapped:

| | ReplicaSet controller | Kueue elastic-job ungater |
| --- | --- | --- |
| Reconciles (the key) | ReplicaSet | **Workload** |
| Watches | ReplicaSets + Pods | Workloads + Pods |
| Pod → key mapping via | ownerReference (`controller: true`) | the Pod's `WorkloadAnnotation` |
| Acts on | creates / deletes Pods | removes the scheduling **gate** on Pods |

Because the ungater maps Pods by their `WorkloadAnnotation` — which holds the
*origin* workload-slice's name — every Pod event lands on the **origin
Workload's** key. That is exactly why the origin slice's reconcile is the one
responsible for those Pods, even after the live quota has moved to a replacement
slice.
