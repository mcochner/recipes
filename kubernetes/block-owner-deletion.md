# blockOwnerDeletion: Making an Owner Wait for Its Dependents

*A tiny, hands-on tour of foreground cascading deletion.*

> **Run it locally:** `make k8s-block-owner-deletion` executes every step below
> end-to-end (it'll reuse your cluster, or spin up a local one if needed). Want
> to go command-by-command? `make k8s-block-owner-deletion STEP=1` pauses for a
> keypress before each step. Prefer to do it by hand? Just copy the commands as
> you read. See the [root README](../README.md) for setup.

If you haven't met owner references yet, start with
[owner-references.md](owner-references.md) — this recipe builds directly on it.

There we saw the default behavior: delete an owner and Kubernetes cleans up its
dependents *afterwards*, in the background. But sometimes you want the opposite
guarantee: **the owner should not be considered gone until its dependents are
gone first.** That's what `blockOwnerDeletion` is for.

---

## The key idea

When you delete an object you can pick a *cascading deletion policy*:

- `--cascade=background` (the default) — the owner disappears immediately and the
  garbage collector deletes the dependents afterwards.
- `--cascade=foreground` — the owner is kept in a "deleting" state until its
  dependents are cleaned up, *then* it's removed.

Foreground deletion is where `blockOwnerDeletion` matters. Each owner reference
can set:

```yaml
ownerReferences:
  - apiVersion: v1
    kind: ConfigMap
    name: cm1
    uid: "<cm1-uid>"
    blockOwnerDeletion: true
```

With `blockOwnerDeletion: true`, a foreground deletion of the owner **waits for
this dependent** before the owner is actually removed. Under the hood,
Kubernetes adds a `foregroundDeletion` finalizer to the owner and stamps it with
a `deletionTimestamp` — the object is visibly "terminating" but still present.

To *see* that waiting clearly, we'll give the dependent a finalizer of its own
so it can't vanish in milliseconds. That keeps the dependent around long enough
to watch the owner sit and wait for it.

---

## Step 1 — Create a namespace to play in

```bash
kubectl create namespace blockowner-demo
```

## Step 2 — Create the owner, `cm1`

```bash
kubectl -n blockowner-demo create configmap cm1 \
  --from-literal=role=owner
```

## Step 3 — Grab `cm1`'s UID

<!-- recipe:capture CM1_UID -->
```bash
CM1_UID=$(kubectl -n blockowner-demo get configmap cm1 \
  -o jsonpath='{.metadata.uid}')

echo "cm1 UID is: $CM1_UID"
```

## Step 4 — Create the dependent, `cm2`, that blocks `cm1`

Two things to notice on `cm2`: the owner reference sets `blockOwnerDeletion:
true`, and we add a custom finalizer (`example.com/hold`) so the dependent
sticks around until *we* say so.

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cm2
  namespace: blockowner-demo
  finalizers:
    - example.com/hold
  ownerReferences:
    - apiVersion: v1
      kind: ConfigMap
      name: cm1
      uid: "$CM1_UID"
      blockOwnerDeletion: true
data:
  role: dependent
EOF
```

## Step 5 — Confirm the relationship

```bash
kubectl -n blockowner-demo get configmap cm2 \
  -o jsonpath='cm2 finalizers={.metadata.finalizers} blockOwnerDeletion={.metadata.ownerReferences[0].blockOwnerDeletion}{"\n"}'
```

---

## Delete the owner — in the foreground

The important flag here is `--cascade=foreground`. We also pass `--wait=false`
so `kubectl` returns immediately instead of blocking (it *would* block, because
the deletion can't finish yet — that's the whole point).

```bash
kubectl -n blockowner-demo delete configmap cm1 \
  --cascade=foreground --wait=false
```

## Watch `cm1` get stuck "terminating"

`cm1` is still there, but Kubernetes has stamped it with a `deletionTimestamp`
and a `foregroundDeletion` finalizer. It will not be removed while a blocking
dependent still exists.

<!-- recipe:retry timeout=30 interval=1 -->
```bash
kubectl -n blockowner-demo get configmap cm1 -o yaml \
  | grep -E 'deletionTimestamp:|finalizers:|foregroundDeletion'
```

And `cm2` — the thing holding everything up — is still present too:

```bash
kubectl -n blockowner-demo get configmap cm2
```

---

## The payoff: release the dependent

Now remove `cm2`'s finalizer. That lets `cm2` actually be deleted, which in turn
unblocks `cm1`'s foreground deletion.

```bash
kubectl -n blockowner-demo patch configmap cm2 \
  --type=merge -p '{"metadata":{"finalizers":null}}'
```

First `cm2` disappears:

<!-- recipe:expect-failure timeout=60 interval=2 -->
```bash
kubectl -n blockowner-demo get configmap cm2
```

…and only *then* does `cm1` finally get removed:

<!-- recipe:expect-failure timeout=60 interval=2 -->
```bash
kubectl -n blockowner-demo get configmap cm1
```

```text
Error from server (NotFound): configmaps "cm1" not found
```

`cm1` waited for `cm2` — exactly the ordering `blockOwnerDeletion` promises.

---

## Cleanup

```bash
kubectl delete namespace blockowner-demo
```

---

## Going a little deeper

- **It only bites in the foreground.** With the default
  `--cascade=background`, `blockOwnerDeletion` has no visible effect — the owner
  is removed right away regardless. Try this recipe again with
  `--cascade=background` and you'll see `cm1` vanish immediately while `cm2`
  lingers.
- **`blockOwnerDeletion: false` doesn't wait.** In a foreground deletion, only
  dependents with `blockOwnerDeletion: true` hold the owner back. Flip it to
  `false` and `cm1` can be removed even while `cm2` is still terminating.
- **Permissions.** Setting `blockOwnerDeletion: true` requires permission to
  update the owner's `finalizers`, since Kubernetes has to add the
  `foregroundDeletion` finalizer to it.

That's the second half of the lifecycle story: owner references decide *what*
gets cleaned up, and `blockOwnerDeletion` plus foreground deletion decide *in
what order*.
