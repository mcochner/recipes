#!/usr/bin/env bash
#
# Run a Markdown recipe.
#
# The Markdown file is the single source of truth: this runner extracts the
# fenced ```bash (or ```sh) code blocks and executes them, in order, in one
# shell so variables set in one block are visible in the next.
#
#   scripts/run-recipe.sh kubernetes/owner-references.md
#
# Blocks in other languages (```text, ```yaml, ...) are shown in the docs but
# never executed.
#
# Behavior is controlled with invisible HTML comments placed on the line(s)
# directly above a code block. They render as nothing in the Markdown, so the
# document stays clean:
#
#   <!-- recipe:skip -->                 don't run this block
#   <!-- recipe:allow-failure -->        run it, but ignore a non-zero exit
#   <!-- recipe:retry timeout=60 interval=2 -->
#                                        re-run until it succeeds (or times out)
#   <!-- recipe:expect-failure timeout=60 interval=2 -->
#                                        re-run until it FAILS (e.g. waiting for
#                                        something to be deleted)
set -euo pipefail

usage() {
  cat >&2 <<EOF
Usage: $0 [--step] [--fresh] PATH_TO_RECIPE.md

  --step, -s   Interactive mode: pause before each command and wait for a key
               ([enter] run, [s] skip, [q] quit). Same as RECIPE_INTERACTIVE=1.
  --fresh      Start from a clean slate: discard any saved state before running.

State that a recipe explicitly captures (via '<!-- recipe:capture VAR -->') is
saved to a readable file and reloaded on the next run, so you can resume a
step-through where you left off. Inspect or override it with RECIPE_STATE_FILE.
EOF
  exit 2
}

INTERACTIVE="${RECIPE_INTERACTIVE:-0}"
FRESH=0
MD=""
while [ $# -gt 0 ]; do
  case "$1" in
    --step|-s) INTERACTIVE=1 ;;
    --fresh) FRESH=1 ;;
    -h|--help) usage ;;
    -*) echo "Unknown option: $1" >&2; usage ;;
    *)
      [ -z "$MD" ] || usage
      MD="$1"
      ;;
  esac
  shift
done

[ -n "$MD" ] || usage
[ -f "$MD" ] || { echo "No such recipe file: $MD" >&2; exit 1; }

# Where the explicit, saved state for this recipe lives.
RECIPE_ID="$(printf '%s' "$MD" | sed 's#[^A-Za-z0-9._-]#_#g')"
STATE_DIR="${RECIPE_STATE_DIR:-.recipe-state}"
STATE_FILE="${RECIPE_STATE_FILE:-$STATE_DIR/$RECIPE_ID.env}"
mkdir -p "$(dirname "$STATE_FILE")"
if [ "$FRESH" = "1" ]; then
  rm -f "$STATE_FILE"
  echo "Starting fresh — cleared saved state ($STATE_FILE)."
fi

GEN="$(mktemp "${TMPDIR:-/tmp}/recipe.XXXXXX.sh")"
trap 'rm -f "$GEN"' EXIT

# arg_value KEY "args string" DEFAULT  ->  prints value of KEY=... or DEFAULT
arg_value() {
  local key="$1" args="$2" default="$3" tok
  for tok in $args; do
    case "$tok" in
      "$key"=*) printf '%s' "${tok#*=}"; return 0 ;;
    esac
  done
  printf '%s' "$default"
}

{
  echo '#!/usr/bin/env bash'
  echo 'set -euo pipefail'
  echo "RECIPE_INTERACTIVE=${INTERACTIVE}"
  printf '__RECIPE_STATE_FILE=%q\n' "$STATE_FILE"
  cat <<'__STATE__'
# --- explicit, persisted state ---------------------------------------------
# Keys captured via '<!-- recipe:capture VAR -->'. Saved to a readable env file
# and reloaded on the next run so state survives between commands and runs.
__RECIPE_KEYS=""
mkdir -p "$(dirname "$__RECIPE_STATE_FILE")"
if [ -s "$__RECIPE_STATE_FILE" ]; then
  while IFS= read -r __line; do
    [ -n "$__line" ] || continue
    __k="${__line%%=*}"
    case " $__RECIPE_KEYS " in *" $__k "*) ;; *) __RECIPE_KEYS="$__RECIPE_KEYS $__k" ;; esac
  done < "$__RECIPE_STATE_FILE"
  # shellcheck disable=SC1090
  source "$__RECIPE_STATE_FILE"
  printf '\033[2m(loaded saved state from %s:%s)\033[0m\n' "$__RECIPE_STATE_FILE" "$__RECIPE_KEYS"
fi

# Persist one or more variables, then show them so the state is explicit.
__recipe_save() {
  local k
  for k in "$@"; do
    case " $__RECIPE_KEYS " in *" $k "*) ;; *) __RECIPE_KEYS="$__RECIPE_KEYS $k" ;; esac
  done
  : > "$__RECIPE_STATE_FILE"
  for k in $__RECIPE_KEYS; do
    printf '%s=%q\n' "$k" "${!k-}" >> "$__RECIPE_STATE_FILE"
  done
  printf '\033[2m  saved state ->'
  for k in "$@"; do printf ' %s=%s' "$k" "${!k-}"; done
  printf ' (in %s)\033[0m\n' "$__RECIPE_STATE_FILE"
}
# ---------------------------------------------------------------------------
__STATE__
  cat <<'__HELPERS__'
# Pause before a step in interactive mode. Returns 0 to run the step, 1 to skip
# it, and exits the recipe on 'q'. In non-interactive mode it always runs.
__recipe_proceed() {
  [ "${RECIPE_INTERACTIVE:-0}" = "1" ] || return 0
  [ -e /dev/tty ] || return 0
  local key
  printf '  \033[2m[enter] run   [s] skip   [q] quit\033[0m > ' > /dev/tty
  IFS= read -rsn1 key < /dev/tty || true
  printf '\n' > /dev/tty
  case "$key" in
    q|Q) printf 'Quitting recipe.\n' > /dev/tty; exit 0 ;;
    s|S) printf '\033[2mskipped\033[0m\n' > /dev/tty; return 1 ;;
    *)   return 0 ;;
  esac
}
__HELPERS__
} > "$GEN"

directive=""
dargs=""
capture_vars=""
in_block=0
block_lang=""
block_body=""

flush_block() {
  local exec_block=0
  case "$block_lang" in
    bash|sh) exec_block=1 ;;
  esac

  if [ "$exec_block" -eq 1 ] && [ "$directive" != "skip" ]; then
    # Header that echoes the upcoming command, then a gate that (in
    # interactive mode) waits for a keypress before running it.
    {
      printf "printf '\\\\n\\\\033[1;34m==>\\\\033[0m next step:\\\\n'\n"
      printf "cat <<'__RECIPE_SHOW__'\n"
      printf '%s' "$block_body"
      printf '__RECIPE_SHOW__\n'
      echo 'if __recipe_proceed; then'
    } >> "$GEN"

    case "$directive" in
      allow-failure)
        {
          echo 'set +e'
          printf '%s' "$block_body"
          echo 'set -e'
        } >> "$GEN"
        ;;
      retry)
        local t i
        t="$(arg_value timeout "$dargs" 60)"
        i="$(arg_value interval "$dargs" 2)"
        {
          echo "__deadline=\$((SECONDS + $t))"
          echo 'until ('
          printf '%s' "$block_body"
          echo '); do'
          echo "  if (( SECONDS >= __deadline )); then echo 'recipe: retry timed out' >&2; exit 1; fi"
          echo "  sleep $i"
          echo 'done'
        } >> "$GEN"
        ;;
      expect-failure)
        local t i
        t="$(arg_value timeout "$dargs" 60)"
        i="$(arg_value interval "$dargs" 2)"
        {
          echo "__deadline=\$((SECONDS + $t))"
          echo 'while ('
          printf '%s' "$block_body"
          echo ') >/dev/null 2>&1; do'
          echo "  if (( SECONDS >= __deadline )); then echo 'recipe: expected failure never happened' >&2; exit 1; fi"
          echo "  sleep $i"
          echo 'done'
        } >> "$GEN"
        ;;
      *)
        printf '%s' "$block_body" >> "$GEN"
        ;;
    esac
    if [ -n "${capture_vars// /}" ]; then
      echo "__recipe_save${capture_vars%% }" >> "$GEN"
    fi
    echo 'fi' >> "$GEN"
  fi

  directive=""
  dargs=""
  capture_vars=""
}

while IFS= read -r line || [ -n "$line" ]; do
  if [ "$in_block" -eq 0 ]; then
    # Pick up a recipe directive from an HTML comment.
    if [[ "$line" =~ ^[[:space:]]*\<!--[[:space:]]*recipe:([a-z-]+)([^>]*)--\>[[:space:]]*$ ]]; then
      if [ "${BASH_REMATCH[1]}" = "capture" ]; then
        # Stacks with a run directive; declares which vars are saved state.
        capture_vars="${BASH_REMATCH[2]}"
      else
        directive="${BASH_REMATCH[1]}"
        dargs="${BASH_REMATCH[2]}"
      fi
      continue
    fi
    # Opening fence?
    if [[ "$line" =~ ^[[:space:]]*\`\`\`(.*)$ ]]; then
      in_block=1
      block_lang="${BASH_REMATCH[1]%% *}"
      block_body=""
    fi
  else
    # Closing fence?
    if [[ "$line" =~ ^[[:space:]]*\`\`\`[[:space:]]*$ ]]; then
      in_block=0
      flush_block
    else
      block_body+="$line"$'\n'
    fi
  fi
done < "$MD"

if [ "${RECIPE_DRY_RUN:-}" = "1" ]; then
  echo "# Dry run — generated script for: $MD"
  cat "$GEN"
  exit 0
fi

echo "Running recipe: $MD"
bash "$GEN"
