#!/usr/bin/env bash
# The atomic swap of a configured symlink. Replacing a link must never leave
# its destination absent, so the swap builds the new link under a temp name
# and renames it over the old one; the hazard that introduces is following a
# link-to-directory destination, where a plain `mv` deposits the temp link
# inside the target instead of replacing it (hence `mv -T` on GNU, `mv -h` on
# BSD). One table, a row per scenario: the fixture builds a checkout with its
# bare origin, a directory entry and a file entry, and the worktree, and
# shapes the destination under test; fix-links runs from the checkout, and
# the row pins its exit status, its stdout, its stderr and what is left:
# every entry of the worktree and of the main checkout's directory entry (a
# link with its target, a file by name; a temp name with its number aliased),
# so a link deposited inside the target, a temp file left behind, or content
# copied into the source all show.
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

# gh is quiet: no row asks about a pull request.
mkdir -p "$TMP_ROOT/bin"
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
    # A directory entry and a file entry, both untracked (nothing in the swap
    # path reads an ignore file, so none is written).
    entries)
      mkdir -p "$MAIN/runtime"
      printf 'state\n' >"$MAIN/runtime/state.json"
      printf 'rc\n' >"$MAIN/harnessrc"
      printf 'WORKTREE_SYMLINKS="runtime harnessrc"\n' >>"$MAIN/.env.local"
      must git -C "$MAIN" add .env.local
      commit_push entries
      ;;
    # A worktree created before the row's command; its own output is not the row's.
    create:*)
      WT="$ROOT/trees/${1#create:}"
      (cd "$MAIN" && "$WORKTREE_SCRIPT" create "${1#create:}" >/dev/null 2>&1) || true
      [[ -d "$WT" ]] || { echo "FIXTURE: create ${1#create:} left no worktree in $ROOT" >&2; exit 2; }
      ;;
    # What a rebase leaves when tracked files exist under the entry: a real
    # directory where the link was, holding a file of its own.
    materialized:*)
      rm -f "$WT/${1#materialized:}"
      mkdir -p "$WT/${1#materialized:}"
      printf 'partial\n' >"$WT/${1#materialized:}/leftover.txt"
      # Reconciliation makes this row's end state the healthy one, so the step
      # proves here that it built what the row claims to reconcile.
      [[ -d "$WT/${1#materialized:}" && ! -L "$WT/${1#materialized:}" && -s "$WT/${1#materialized:}/leftover.txt" ]] ||
        { echo "FIXTURE: materialized:${1#materialized:} left no real directory holding a file in $ROOT" >&2; exit 2; }
      ;;
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
  sed -e "s|$WT|<wt>|g" -e "s|$MAIN|<main>|g" -e "s|$ROOT|<root>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" |
    paste -s -d ';' -
}

# Every entry of the worktree, then of the main checkout's directory entry (a
# link with its target, a file by name, an empty directory with a slash;
# git's own directory left out, links not followed); a temp name's number is
# aliased so a leftover shows as one.
entries_of() {
  (cd "$1" && find . -mindepth 1 \( -path ./.git -prune \) -o \( -type f -o -type l -o \( -type d -empty \) \) -print | LC_ALL=C sort | while IFS= read -r path; do
    if [[ -L "$path" ]]; then printf '%s->%s,' "${path#./}" "$(readlink "$path" | sed -e "s|$MAIN|<main>|" -e "s|$ROOT|<root>|")"
    elif [[ -d "$path" ]]; then printf '%s/,' "${path#./}"
    else printf '%s,' "${path#./}"; fi
  done | sed -e 's/,$//' -e 's/\.wt-tmp\.[0-9]*/.wt-tmp.<n>/g')
}

state() {
  local wt_entries="" src_entries=""
  wt_entries="$(entries_of "$WT")"
  src_entries="$(entries_of "$MAIN/runtime")"
  printf 'wt=%s src=%s' "${wt_entries:--}" "${src_entries:--}"
}

run() {
  local -a argv
  local rc=0
  read -r -a argv <<<"${1//<wt>/$WT}"
  if [[ "${argv[0]}" == create ]]; then WT="$ROOT/trees/${argv[1]}"; fi
  (cd "$MAIN" && LC_ALL=C "$WORKTREE_SCRIPT" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  printf 'rc=%s out=%s err=%s %s' "$rc" "$(alias_text <"$ROOT/out")" "$(alias_text <"$ROOT/err")" "$(state)"
}

# --- the expected text ----------------------------------------------------------

err_text() {
  case "$1" in
    -) printf '' ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}

out_text() {
  case "$1" in
    -) printf '' ;;
    wt) printf '<wt>' ;;
    restored) printf 'Restored symlinks in <wt>' ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

# --- the rows ---------------------------------------------------------------------
# label|fixture|command|rc|out|err|state
ROWS='create links a directory entry and a file entry|repo entries|create swap-check|0|wt|-|wt=.env.local,base.txt,harnessrc-><main>/harnessrc,runtime-><main>/runtime src=state.json
replacing a link to a directory swaps it in place: nothing nested in the target, no temp name left|repo entries create:swap-check|fix-links <wt>|0|restored|-|wt=.env.local,base.txt,harnessrc-><main>/harnessrc,runtime-><main>/runtime src=state.json
a materialized real directory is reconciled back to a link, its content not copied into the source|repo entries create:swap-check materialized:runtime|fix-links <wt>|0|restored|-|wt=.env.local,base.txt,harnessrc-><main>/harnessrc,runtime-><main>/runtime src=state.json
'

echo "=== the atomic symlink swap ==="
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
