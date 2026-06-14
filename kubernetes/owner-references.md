# Owner References: How One ConfigMap Can Delete Another

*A tiny, hands-on tour of the Kubernetes object lifecycle.*

When you delete an object in Kubernetes, sometimes a whole pile of other
objects quietly disappears with it. Delete a Deployment and its ReplicaSets and
Pods go too. Delete a Job and its Pods get cleaned up. This isn't magic — it's
**owner references** and the **garbage collector** doing their job.

In this recipe we'll build the smallest possible example of that behavior using
two ConfigMaps: `cm1` owns `cm2`, and deleting `cm1` causes Kubernetes to
delete `cm2` for us.

---

## The key idea

Every object can declare a list of *owners* in its `metadata.ownerReferences`.
Each entry says: *"this object belongs to that object."* When **all** of an
object's owners are gone, the garbage collector deletes the object too.

The one detail that trips people up:

> An owner reference points at the owner's **UID**, not just its name. Kubernetes
> assigns that UID only *after* the object is created.

That has a practical consequence: **the owner must exist first.** You cannot ship
one static YAML file that contains the correct UID ahead of time, because the
UID doesn't exist until `cm1` is created. So the flow is always: create the
owner, read its UID, then create the dependent.

A couple of rules worth remembering:

- For namespaced objects like ConfigMaps, the owner and the dependent must live
  in the **same namespace**.
- The owner reference must include the owner's `apiVersion`, `kind`, `name`, and
  `uid`.

---

## Step 1 — Create a namespace to play in

```bash
kubectl create namespace ownerref-demo
```

## Step 2 — Create the owner, `cm1`

```bash
kubectl -n ownerref-demo create configmap cm1 \
  --from-literal=role=owner
```

## Step 3 — Grab `cm1`'s UID

This is the part you can't skip — `cm2` needs this exact value.

```bash
CM1_UID=$(kubectl -n ownerref-demo get configmap cm1 \
  -o jsonpath='{.metadata.uid}')

echo "cm1 UID is: $CM1_UID"
```

## Step 4 — Create the dependent, `cm2`, pointing at `cm1`

```bash
cat <<EOF | kubectl apply -f -
apiVersion: v1
kind: ConfigMap
metadata:
  name: cm2
  namespace: ownerref-demo
  ownerReferences:
    - apiVersion: v1
      kind: ConfigMap
      name: cm1
      uid: "$CM1_UID"
data:
  role: dependent
EOF
```

## Step 5 — Inspect the relationship

```bash
kubectl -n ownerref-demo get configmap cm2 -o yaml
```

You'll see the `ownerReferences` block on `cm2` pointing back at `cm1`'s UID.

---

## The payoff: delete the owner

```bash
kubectl -n ownerref-demo delete configmap cm1
```

Give the garbage collector a moment, then check on `cm2`:

```bash
kubectl -n ownerref-demo get configmap cm2
```

Expected result once garbage collection has run:

```text
Error from server (NotFound): configmaps "cm2" not found
```

`cm2` is gone — not because you deleted it, but because its only owner went away.

---

## Cleanup

```bash
kubectl delete namespace ownerref-demo
```

---

## Going a little deeper

A few things to explore once the basic demo clicks:

- **Cascading deletion policies.** When you delete the owner you can choose
  `--cascade=background` (default — return immediately, clean up dependents
  asynchronously), `--cascade=foreground` (the owner sticks around in a
  "deleting" state until dependents are gone), or `--cascade=orphan` (delete the
  owner but leave the dependents behind).
- **`blockOwnerDeletion`.** An owner reference can set this to `true`, which makes
  foreground deletion wait for that specific dependent before the owner is
  removed.
- **Multiple owners.** An object only gets garbage-collected when *every* owner
  is gone, so an object can be co-owned and survive until the last owner leaves.

That's the whole lifecycle in miniature: owners, UIDs, and a garbage collector
that tidies up after them.
