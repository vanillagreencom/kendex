#!/usr/bin/env bash
# The two detectors of a materialized link. A rebase can replace a configured
# symlink with a real directory holding only the tracked files under it,
# dropping every kendex-installed path there while git sees a clean tree. The
# use-time check on `push` (the usual first command after a manual rebase)
# names each such path and sends the operator to the main checkout, because
# the worktree's own copy of this script may be among the missing files; the
# support-library guard turns the bare 127 of a script whose lib/ vanished
# into that same account. An entry holding tracked content is a real
# directory with per-child links by design and reads as healthy. One table,
# a row per scenario: the fixture is a word list of steps that builds a
# checkout with its bare origin, its two entries and the worktree, and
# damages the shape under test; the command runs from the checkout (a copy of
# the script without its lib/ for the guard row), and the row pins its exit
# status, its stdout, its stderr and what is left: every entry of the
# worktree (a link with its target, a file by name) and git's status of it.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

# gh is quiet: no row asks about a pull request. BROKEN is a copy of the
# script with no lib/ beside it, the shape a materialized harness leaves.
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/broken/scripts/lib"
cp "$WORKTREE_SCRIPT" "$TMP_ROOT/broken/scripts/worktree"
chmod +x "$TMP_ROOT/broken/scripts/worktree"
BROKEN="$TMP_ROOT/broken/scripts/worktree"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP_ROOT/bin/gh"
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

# --- fixtures -----------------------------------------------------------------
# Every row's world lives under its own ROOT: the checkout at ROOT/main, its
# bare origin, and the worktree at ROOT/trees/<id>.

ROOT=""
MAIN=""
WT=""

make_repo() {
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email test@example.com
  git -C "$MAIN" config user.name Test
  git -C "$MAIN" config commit.gpgsign false
  printf 'base\n' >"$MAIN/base.txt"
  git -C "$MAIN" add base.txt
  git -C "$MAIN" commit -q -m base
  git init -q --bare "$ROOT/origin.git"
  git -C "$MAIN" remote add origin "$ROOT/origin.git"
  git -C "$MAIN" push -q -u origin main
  printf 'WORKTREE_BASE_DIR="../trees"\n' >"$MAIN/.env.local"
}

must() {
  "$@" || { echo "FIXTURE: '$*' failed in $ROOT" >&2; exit 2; }
}

commit_push() {
  must git -C "$MAIN" commit -q -m "$1"
  must git -C "$MAIN" push -q origin main
}

# The step vocabulary. `repo` builds the world; the rest shape it.
step() {
  case "$1" in
    repo) make_repo ;;
    # Both provisioning shapes: harness/ mixes installed content with a
    # tracked file (a real directory with per-child links); runtime/ is
    # untracked only (a plain parent link, the shape a rebase materializes).
    harness)
      mkdir -p "$MAIN/harness/skills" "$MAIN/runtime"
      printf 'harness/**\n!harness/tracked.md\nruntime/\n' >"$MAIN/.gitignore"
      printf 'installed\n' >"$MAIN/harness/skills/installed.txt"
      printf 'tracked\n' >"$MAIN/harness/tracked.md"
      printf 'state\n' >"$MAIN/runtime/state.json"
      printf 'WORKTREE_SYMLINKS="harness runtime"\n' >>"$MAIN/.env.local"
      must git -C "$MAIN" add .gitignore .env.local harness/tracked.md
      commit_push harness
      ;;
    # A worktree created before the row's command; its own output is not the row's.
    create:*)
      WT="$ROOT/trees/${1#create:}"
      (cd "$MAIN" && "$WORKTREE_SCRIPT" create "${1#create:}" >/dev/null 2>&1) || true
      [[ -d "$WT" ]] || { echo "FIXTURE: create ${1#create:} left no worktree in $ROOT" >&2; exit 2; }
      ;;
    # What a rebase leaves: a real directory where the parent link was, the
    # installed content gone.
    materialized:*) rm -f "$WT/${1#materialized:}"; mkdir -p "$WT/${1#materialized:}" ;;
    *)
      echo "UNKNOWN-STEP: $1" >&2
      exit 2
      ;;
  esac
}

build() {
  local word
  ROOT="$TMP_ROOT/$1"
  shift
  MAIN="$ROOT/main"
  WT=""
  mkdir -p "$ROOT"
  for word in "$@"; do
    step "$word"
  done
}

# --- rendering ------------------------------------------------------------------

alias_text() {
  sed -e "s|$WT|<wt>|g" -e "s|$MAIN|<main>|g" -e "s|$TMP_ROOT/broken|<broken>|g" -e "s|$ROOT|<root>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" |
    paste -s -d ';' -
}

# Every entry of the worktree (a link with its target, a file by name; git's
# own directory left out, links not followed), then git's status of it.
state() {
  local entries="" wt_status="" path
  entries="$(cd "$WT" && find . -mindepth 1 \( -path ./.git -prune \) -o \( -type f -o -type l -o \( -type d -empty \) \) -print | LC_ALL=C sort | while IFS= read -r path; do
    if [[ -L "$path" ]]; then printf '%s->%s,' "${path#./}" "$(readlink "$path" | sed -e "s|$MAIN|<main>|" -e "s|$ROOT|<root>|")"
    elif [[ -d "$path" ]]; then printf '%s/,' "${path#./}"
    else printf '%s,' "${path#./}"; fi
  done | sed 's/,$//')"
  wt_status="$(git -C "$WT" status --porcelain 2>/dev/null | paste -s -d ',' -)"
  printf 'wt=%s wt-status=%s' "${entries:--}" "${wt_status:--}"
}

run() {
  local -a argv
  local rc=0
  local script="$WORKTREE_SCRIPT"
  read -r -a argv <<<"${1//<wt>/$WT}"
  if [[ "${argv[0]}" == "<broken>" ]]; then script="$BROKEN"; argv=("${argv[@]:1}"); fi
  (cd "$MAIN" && LC_ALL=C "$script" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  printf 'rc=%s out=%s err=%s %s' "$rc" "$(alias_text <"$ROOT/out")" "$(alias_text <"$ROOT/err")" "$(state)"
}

# --- the expected text ----------------------------------------------------------

# The production text, held once; `+` composes two specs.
err_text() {
  case "$1" in
    -) printf '' ;;
    *+*) err_text "${1%%+*}"; printf ';'; err_text "${1#*+}" ;;
    pushed:*) printf 'To <root>/origin.git; * [new branch]      HEAD -> %s' "${1#pushed:}" ;;
    materialized:*) printf '%s' "Warning: harness paths in this worktree are real directories, not symlinks:;  - ${1#materialized:};  A rebase materialized them, so kendex-installed files under those paths are gone.;  git status will look clean — it tracks only the files that survived.;  Restore them by running fix-links FROM THE MAIN CHECKOUT, because this;  worktree's own copy of the script may be among the missing files:;    cd '<main>' && .agents/skills/worktree/scripts/worktree fix-links '<wt>'" ;;
    no-lib) printf '%s' "Error: worktree support library is missing: <broken>/scripts/lib/kendex-env.sh;  This is the signature of a materialized harness directory: a rebase replaced;  the symlink with a real directory containing only the tracked files, dropping;  everything installed by kendex.;  Recover by running fix-links FROM THE MAIN CHECKOUT (this copy is incomplete):;    cd <main checkout> && .agents/skills/worktree/scripts/worktree fix-links '<main>'" ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}

out_text() {
  case "$1" in
    -) printf '' ;;
    restored) printf 'Restored symlinks in <wt>' ;;
    tracking:*) printf "branch '%s' set up to track 'origin/%s'." "${1#tracking:}" "${1#tracking:}" ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

# --- the rows ---------------------------------------------------------------------
# label|fixture|command|rc|out|err|state
ROWS='a healthy worktree pushes with no warning: the tracked-content entry is a real directory with per-child links by design|repo harness create:mat-check|push mat-check --no-rebase|0|tracking:mat-check|pushed:mat-check|wt=.env.local,.gitignore,base.txt,harness/skills-><main>/harness/skills,harness/tracked.md,runtime-><main>/runtime wt-status=-
push names a materialized parent link and sends the operator to the main checkout|repo harness create:mat-check materialized:runtime|push mat-check --no-rebase|0|tracking:mat-check|materialized:runtime+pushed:mat-check|wt=.env.local,.gitignore,base.txt,harness/skills-><main>/harness/skills,harness/tracked.md,runtime/ wt-status=-
push names a materialized per-child link under the tracked-content entry|repo harness create:mat-check materialized:harness/skills|push mat-check --no-rebase|0|tracking:mat-check|materialized:harness/skills+pushed:mat-check|wt=.env.local,.gitignore,base.txt,harness/skills/,harness/tracked.md,runtime-><main>/runtime wt-status=-
fix-links from the main checkout restores the materialized parent link|repo harness create:mat-check materialized:runtime|fix-links <wt>|0|restored|-|wt=.env.local,.gitignore,base.txt,harness/skills-><main>/harness/skills,harness/tracked.md,runtime-><main>/runtime wt-status=-
a script whose lib/ vanished refuses with the same account instead of a bare 127|repo harness create:mat-check|<broken> list|1|-|no-lib|wt=.env.local,.gitignore,base.txt,harness/skills-><main>/harness/skills,harness/tracked.md,runtime-><main>/runtime wt-status=-
'

echo "=== the materialization detectors ==="
n=0
while IFS= read -r row; do
  [[ -n "$row" ]] || continue
  IFS='|' read -r label fixture command rc out err want_state <<<"$row"
  for field in "$label" "$fixture" "$command" "$rc" "$out" "$err" "$want_state"; do
    [[ -n "$field" ]] || { printf 'a row with an empty field asserts nothing: %s\n' "$row" >&2; exit 1; }
  done
  n=$((n + 1))
  # shellcheck disable=SC2086
  build "row-$n" $fixture
  # A rendering aid for writing rows: prints what each row produces instead of
  # asserting it. A run that asserted no row is refused after the loop.
  if [[ "${WORKTREE_TABLE_PROBE:-}" == 1 ]]; then
    printf '%s => %s\n' "$label" "$(run "$command")"
    continue
  fi
  assert_eq "$(run "$command")" "rc=$rc out=$(out_text "$out") err=$(err_text "$err") $want_state" "$label"
done <<<"$ROWS"
[[ "$((PASS + FAIL))" -gt 0 ]] || { echo "no row was asserted (a probe run renders rows instead)" >&2; exit 2; }

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
