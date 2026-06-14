# recipes

Small, hands-on technical recipes you can actually run. Each recipe is a single
Markdown file you can read top-to-bottom — and **the same file is runnable**, so
you can watch it work instead of just reading about it.

## Run a recipe

Every recipe runs with one command:

```bash
make k8s-owner-references
```

That's it. The command spins up a throwaway local cluster if you don't already
have one, runs every step in the recipe, verifies the result, and cleans up
after itself.

To see everything you can run:

```bash
make
```

### Step through it one command at a time

Add `STEP=1` to run a recipe interactively. It pauses before every command and
waits for a key — `enter` to run it, `s` to skip, `q` to quit:

```bash
make k8s-owner-references STEP=1
```

(Equivalent to `scripts/run-recipe.sh --step kubernetes/owner-references.md`.)

### State carried between commands

Some steps produce a value that a later step needs (for example, an object's
UID). A recipe declares these explicitly with a `recipe:capture` annotation, and
the runner saves them to a small, readable env file under `.recipe-state/`:

```bash
cat .recipe-state/kubernetes_owner-references.md.env
# CM1_UID=ff20c335-4a6d-4d39-bd47-06f76f279d93
```

That state is reloaded on the next run, so you can quit a step-through (`q`) and
pick up where you left off — captured values survive between commands *and*
between runs. After each capture the runner prints `saved state -> VAR=value`,
so it's always visible what's being carried forward. Start clean with `FRESH=1`
(or `--fresh`):

```bash
make k8s-owner-references FRESH=1
```

## Recipes

| Recipe | What you'll learn | Run it |
| --- | --- | --- |
| [kubernetes/owner-references.md](kubernetes/owner-references.md) | How deleting one object garbage-collects others via owner references | `make k8s-owner-references` |

## Prerequisites

You only need tools for the recipe you're running.

- **Kubernetes recipes** need [`kubectl`](https://kubernetes.io/docs/tasks/tools/).
  For a local cluster you also need [Docker](https://docs.docker.com/get-docker/)
  and [`kind`](https://kind.sigs.k8s.io/docs/user/quick-start/#installation)
  (`brew install kind`). If your `kubectl` already points at a cluster (Docker
  Desktop, minikube, a cloud cluster, ...), that one is used instead and `kind`
  isn't required.

Don't have a cluster? `make cluster-up` creates a local one, and
`make cluster-down` deletes it again. The teardown only ever removes the cluster
these scripts created — it won't touch a cluster you brought yourself.

`cluster-up` is smart about reuse: if `kubectl` is already pointed at a cluster
(including an existing `kind` cluster) it reuses it instead of recreating
anything. If a `kind` cluster exists but isn't selected, it just switches to its
context. A fresh `kind` cluster is only created as a last resort.

## How the runner works

The Markdown file is the **single source of truth** — the real commands live
only in the recipe, never duplicated in a script. `scripts/run-recipe.sh`
extracts the fenced ` ```bash ` blocks from the `.md` and runs them in order in
one shell, so a variable set in one step is available in the next. Blocks in
other languages (` ```text `, ` ```yaml `, ...) are shown for context but never
executed.

Where a step needs special handling, the recipe uses an invisible HTML comment
on the line above the code block. These render as nothing, so the document stays
clean:

| Annotation | Effect |
| --- | --- |
| `<!-- recipe:skip -->` | Show the block in the docs, but don't run it |
| `<!-- recipe:allow-failure -->` | Run it, but don't fail the recipe on a non-zero exit |
| `<!-- recipe:retry timeout=60 interval=2 -->` | Re-run until it succeeds (or times out) |
| `<!-- recipe:expect-failure timeout=60 interval=2 -->` | Re-run until it *fails* — e.g. waiting for something to be deleted |
| `<!-- recipe:capture VAR [VAR2 ...] -->` | After the block runs, save these variables as explicit state (persisted to `.recipe-state/` and reloaded on the next run) |

## Adding a recipe

1. Write a Markdown walkthrough under a topic folder (e.g. `kubernetes/`), with
   the runnable steps as ` ```bash ` blocks.
2. Add `recipe:` annotations above any blocks that need retries, expected
   failures, captured state, or should be skipped.
3. Add a `make` target in the [`Makefile`](Makefile) that runs it via
   `scripts/run-recipe.sh`, and list it in the table above.
