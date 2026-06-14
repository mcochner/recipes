# Finalizers: How to Block a Delete Until Cleanup Runs

*A tiny, hands-on tour of cooperative deletion.*

> **Run it locally:** `make k8s-finalizers` executes every step below end-to-end
> (it'll reuse your cluster, or spin up a local one if needed). Want to go
> command-by-command? `make k8s-finalizers STEP=1` pauses for a keypress before
> each step. Prefer to do it by hand? Just copy the commands as you read. See
> the [root README](../README.md) for setup.

In the [owner references](owner-references.md) and
[blockOwnerDeletion](block-owner-deletion.md) recipes you saw objects get stuck
"terminating" thanks to a built-in finalizer called `foregroundDeletion`. This
recipe is about the general mechanism: **finalizers let *you* hook into deletion
and run cleanup before an object is allowed to disappear.**

---

## The key idea

A finalizer is just a string in `metadata.finalizers`. Kubernetes never runs
any code for you — it simply **refuses to delete an object while that list is
non-empty.** The flow is cooperative:

1. Something adds a finalizer string to the object (usually a controller, on
   create).
2. Someone runs `kubectl delete`. Because finalizers are present, the API server
   does **not** delete the object. Instead it sets `metadata.deletionTimestamp`
   and leaves the object in place, now "terminating".
3. A controller notices the `deletionTimestamp` and its own finalizer, does
   whatever cleanup is needed (delete a cloud bucket, deregister a webhook…),
   and then **removes its finalizer** from the list.
4. Once the list is empty, the API server finally deletes the object.

A couple of conventions worth knowing:

> Finalizer names should be **DNS-qualified** — `<domain>/<name>`, e.g.
> `recipes.example.com/cleanup`. The API server warns about unqualified names.
> The built-in `foregroundDeletion` and `orphan` are the blessed exceptions.

You'll see real ones like `kubernetes.io/pv-protection` (don't delete a
PersistentVolume that's still bound) and
`service.kubernetes.io/load-balancer-cleanup` (tear down the cloud load balancer
first).

---

## Step 1 — Create a namespace to play in

```bash
kubectl create namespace finalizer-demo
```

## Step 2 — Create an object with a finalizer

We'll add our own finalizer, `recipes.example.com/cleanup`, to a ConfigMap.

```bash
kubectl apply -f - <<EOF
apiVersion: v1
kind: ConfigMap
metadata:
  name: widget
  namespace: finalizer-demo
  finalizers:
    - recipes.example.com/cleanup
data:
  hello: world
EOF
```

## Step 3 — Confirm the finalizer is there

```bash
kubectl -n finalizer-demo get configmap widget \
  -o jsonpath='widget finalizers={.metadata.finalizers}{"\n"}'
```

---

## Try to delete it

We pass `--wait=false` so `kubectl` returns immediately — otherwise it would
block forever, because the object can't actually be removed yet.

```bash
kubectl -n finalizer-demo delete configmap widget --wait=false
```

## It's stuck "terminating"

The object is still here. Kubernetes has stamped it with a `deletionTimestamp`,
but it won't be removed while our finalizer remains.

```bash
kubectl -n finalizer-demo get configmap widget \
  -o jsonpath='widget: deletionTimestamp={.metadata.deletionTimestamp} finalizers={.metadata.finalizers}{"\n"}'
```

---

## The payoff: be the controller

This is the job a real controller would do: notice the object is terminating,
run cleanup, then remove **only its own** finalizer. We use `jq` to filter our
string out of the list and `kubectl replace` to write it back — note that we
remove *just* our finalizer, never blindly wiping the whole list.

```bash
echo "controller: running cleanup for widget before letting it go..."

kubectl -n finalizer-demo get configmap widget -o json \
  | jq '(.metadata.finalizers) |= map(select(. != "recipes.example.com/cleanup"))' \
  | kubectl replace -f -
```

With our finalizer gone, the list is empty and the API server finishes the
delete:

<!-- recipe:expect-failure timeout=30 interval=2 -->
```bash
kubectl -n finalizer-demo get configmap widget
```

```text
Error from server (NotFound): configmaps "widget" not found
```

`widget` only disappeared once *we* allowed it to — exactly the hook finalizers
give you.

---

## Cleanup

```bash
kubectl delete namespace finalizer-demo
```

---

## Going a little deeper

**Listing finalizers.** To find everything of a kind that carries one:

<!-- recipe:skip -->
```bash
kubectl get pvc -A -o jsonpath='{range .items[?(@.metadata.finalizers)]}{.metadata.namespace}/{.metadata.name}: {.metadata.finalizers}{"\n"}{end}'
```

**A tiny "controller" loop.** The same logic, but reacting on its own instead of
you running a command. (Illustrative — this one loops forever, so the runner
skips it.)

<!-- recipe:skip -->
```bash
while true; do
  kubectl get configmaps -A -o json \
    | jq -r '.items[]
        | select(.metadata.deletionTimestamp != null)
        | select(.metadata.finalizers // [] | index("recipes.example.com/cleanup"))
        | "\(.metadata.namespace) \(.metadata.name)"' \
  | while read -r ns name; do
      echo "cleaning up $ns/$name ..."
      # ...do real cleanup here...
      kubectl -n "$ns" get configmap "$name" -o json \
        | jq '(.metadata.finalizers) |= map(select(. != "recipes.example.com/cleanup"))' \
        | kubectl replace -f -
    done
  sleep 2
done
```

In production you wouldn't poll — `controller-runtime` (Go) gives you
`AddFinalizer`/`RemoveFinalizer` and the standard reconcile pattern, and
`kopf` (Python) backs its `@kopf.on.delete` handlers with finalizers
automatically.

**The escape hatch.** If an object is wedged because its controller is gone, you
can force-remove *all* finalizers by hand. Use this sparingly — it skips
whatever cleanup the finalizer was protecting.

<!-- recipe:skip -->
```bash
kubectl -n finalizer-demo patch configmap widget \
  --type=merge -p '{"metadata":{"finalizers":null}}'
```

That's the whole mechanism: a string that means "not yet", and a controller that
removes it once cleanup is done.
