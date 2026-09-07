#!/usr/bin/env bash
# The shape of the info/exclude entry a configured symlink path gets. The entry
# lands in the COMMON git dir's info/exclude, which every checkout reads,
# including main, where the same path is a real directory: a bare entry alone
# marked that directory ignored in main, so `git add` of a tracked file under
# it refused with git's ignore complaint while status still listed the file
# as modified, and the entry outlived the worktree. When the path holds
# tracked content the bare entry is followed by `!<path>/`: a trailing-slash
# pattern matches a real directory but not a symlink to one, so main regains
# the directory and the worktree's link stays ignored. A runtime-only path
# keeps the plain entry (kendex's own .agents mirror is hidden in main by that
# entry alone). The shape is recomputed on every pass, so it follows a path
# that gains or loses tracked content, and lines other tools wrote stay.
# One table, a row per scenario: the fixture is a word list of steps that
# builds a checkout with its bare origin, the configured entry's content and
# any worktree the row needs, the command runs from the checkout, and the row
# pins its exit status, its stdout, its stderr and what is left: the exclude
# file's lines, git's status of main, whether main can stage every tracked
# file under the entry (git's own refusal, first line), and every entry of
# the worktree with git's status of it.
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
# bare origin, and the worktree at ROOT/trees/<id>. ENTRY is the one
# configured symlink path of the row.

ROOT=""
MAIN=""
WT=""
ENTRY=""

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
    # The entry holds a tracked file beside an ignored runtime file.
    tracked-entry)
      ENTRY=harness
      mkdir -p "$MAIN/harness/skills"
      printf 'harness/state.json\n' >"$MAIN/.gitignore"
      printf 'runtime\n' >"$MAIN/harness/state.json"
      printf 'v1\n' >"$MAIN/harness/skills/tool.md"
      printf 'WORKTREE_SYMLINKS="harness"\n' >>"$MAIN/.env.local"
      must git -C "$MAIN" add .gitignore .env.local harness/skills/tool.md
      commit_push harness
      ;;
    # The entry holds runtime files only, nothing tracked and no ignore rule.
    runtime-entry)
      ENTRY=runtime
      mkdir -p "$MAIN/runtime/sub"
      printf 'state\n' >"$MAIN/runtime/state.json"
      printf 'more\n' >"$MAIN/runtime/sub/x.json"
      printf 'WORKTREE_SYMLINKS="runtime"\n' >>"$MAIN/.env.local"
      must git -C "$MAIN" add .env.local
      commit_push runtime
      ;;
    # A file under the entry becomes tracked, or the tracked file stops being.
    track:*)
      printf 'now-tracked\n' >"$MAIN/${1#track:}"
      must git -C "$MAIN" add -f "${1#track:}"
      commit_push "track ${1#track:}"
      ;;
    untrack:*)
      must git -C "$MAIN" rm -q --cached "${1#untrack:}"
      commit_push "untrack ${1#untrack:}"
      ;;
    # The worktree's branch fast-forwarded to main, so its index agrees with main's.
    sync-wt) must git -C "$WT" merge -q --ff-only origin/main ;;
    # A tracked file under the entry edited in main, so staging it means something.
    edit:*) printf 'v2\n' >"$MAIN/${1#edit:}" ;;
    # A line another tool wrote into the shared exclude file.
    foreign-line) printf '%s\n' '**/.claude/*' >>"$MAIN/.git/info/exclude" ;;
    # A worktree created before the row's command; its own output is not the row's.
    create:*)
      WT="$ROOT/trees/${1#create:}"
      (cd "$MAIN" && "$WORKTREE_SCRIPT" create "${1#create:}" >/dev/null 2>&1) || true
      [[ -d "$WT" ]] || { echo "FIXTURE: create ${1#create:} left no worktree in $ROOT" >&2; exit 2; }
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
  ENTRY=""
  mkdir -p "$ROOT"
  for word in "$@"; do
    step "$word"
  done
}

# --- rendering ------------------------------------------------------------------

alias_text() {
  sed -e "s|$MAIN|<main>|g" -e "s|$ROOT|<root>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" |
    paste -s -d ';' -
}

# The exclude file's lines in order (git's template comments left out); main's status; whether main can stage
# every tracked file under the entry (a dry run: its exit status and first
# line, git's own refusal when the entry ignores them); then every entry of
# the worktree (a link with its target, a file by name; git's own directory
# left out, links not followed) and git's status of it. A removed worktree
# renders as `wt=gone`.
state() {
  local exclude="" main_status="" stage="" entries="" wt_status="" path rc=0 out=""
  local -a tracked=()
  exclude="$(grep -v '^#' "$MAIN/.git/info/exclude" 2>/dev/null | paste -s -d ',' - || true)"
  main_status="$(git -C "$MAIN" status --porcelain | paste -s -d ',' -)"
  while IFS= read -r path; do
    [[ -n "$path" ]] && tracked+=("$path")
  done < <(git -C "$MAIN" ls-files -- "$ENTRY" "$ENTRY/" 2>/dev/null)
  if [[ ${#tracked[@]} -gt 0 ]]; then
    out="$(LC_ALL=C git -C "$MAIN" add --dry-run -- "${tracked[@]}" 2>&1)" || rc=$?
    out="${out%%$'\n'*}"
    stage="$rc:${out:--}"
  fi
  if [[ -n "$WT" && -d "$WT" ]]; then
    entries="$(cd "$WT" && find . -mindepth 1 \( -path ./.git -prune \) -o \( -type f -o -type l \) -print | LC_ALL=C sort | while IFS= read -r path; do
      if [[ -L "$path" ]]; then printf '%s->%s,' "${path#./}" "$(readlink "$path" | sed -e "s|$MAIN|<main>|" -e "s|$ROOT|<root>|")"
      else printf '%s,' "${path#./}"; fi
    done | sed 's/,$//')"
    wt_status="$(git -C "$WT" status --porcelain 2>/dev/null | paste -s -d ',' -)"
    printf 'exclude=%s main=%s stage=%s wt=%s wt-status=%s' "${exclude:--}" "${main_status:--}" "${stage:--}" "${entries:--}" "${wt_status:--}"
  elif [[ -n "$WT" ]]; then
    printf 'exclude=%s main=%s stage=%s wt=gone' "${exclude:--}" "${main_status:--}" "${stage:--}"
  else
    printf 'exclude=%s main=%s stage=%s' "${exclude:--}" "${main_status:--}" "${stage:--}"
  fi
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
    deleted:*) printf "Deleted branch '%s' — merged into origin/main." "${1#deleted:}" ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}

out_text() {
  case "$1" in
    -) printf '' ;;
    wt:*) printf '<root>/trees/%s' "${1#wt:}" ;;
    restored:*) printf 'Restored symlinks in <root>/trees/%s' "${1#restored:}" ;;
    removed:*) printf 'Removed: <root>/trees/%s' "${1#removed:}" ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

# --- the rows ---------------------------------------------------------------------
# label|fixture|command|rc|out|err|state
ROWS='an entry with tracked content gets the bare line and the negation after it, and main stages its tracked file|repo tracked-entry edit:harness/skills/tool.md|create tracked-check|0|wt:tracked-check|-|exclude=harness,!harness/,harness/state.json main= M harness/skills/tool.md stage=0:add '\''harness/skills/tool.md'\'' wt=.env.local,.gitignore,base.txt,harness/skills/tool.md,harness/state.json-><main>/harness/state.json wt-status=-
the entry'\''s lines stay after the worktree is removed|repo tracked-entry create:tracked-check|remove tracked-check|0|removed:tracked-check|deleted:tracked-check|exclude=harness,!harness/,harness/state.json main=- stage=0:- wt=gone
a runtime-only entry keeps the plain line, and main does not see the runtime tree|repo runtime-entry|create clean-check|0|wt:clean-check|-|exclude=runtime main=- stage=- wt=.env.local,base.txt,runtime-><main>/runtime wt-status=-
the negation appears once the entry gains a tracked file, the link becomes per-child links, and main stages it|repo runtime-entry create:clean-check track:runtime/sub/keep.md|fix-links <wt>|0|restored:clean-check|-|exclude=runtime,!runtime/,runtime/state.json,runtime/sub/x.json main=- stage=0:- wt=.env.local,base.txt,runtime/state.json-><main>/runtime/state.json,runtime/sub/x.json-><main>/runtime/sub/x.json wt-status=-
a repeated pass rewrites the negation after the lines, once|repo tracked-entry create:tracked-check|fix-links <wt>|0|restored:tracked-check|-|exclude=harness,harness/state.json,!harness/ main=- stage=0:- wt=.env.local,.gitignore,base.txt,harness/skills/tool.md,harness/state.json-><main>/harness/state.json wt-status=-
the negation stays while the worktree'\''s own index still tracks the file main dropped|repo tracked-entry create:tracked-check untrack:harness/skills/tool.md|fix-links <wt>|0|restored:tracked-check|-|exclude=harness,harness/state.json,!harness/ main=?? harness/ stage=- wt=.env.local,.gitignore,base.txt,harness/skills/tool.md,harness/state.json-><main>/harness/state.json wt-status=-
the negation goes once neither index tracks a file under the entry|repo tracked-entry create:tracked-check untrack:harness/skills/tool.md sync-wt|fix-links <wt>|0|restored:tracked-check|-|exclude=harness,harness/state.json main=- stage=- wt=.env.local,.gitignore,base.txt,harness-><main>/harness wt-status=-
a line another tool wrote into the exclude file stays, before ours|repo tracked-entry foreign-line|create tracked-check|0|wt:tracked-check|-|exclude=**/.claude/*,harness,!harness/,harness/state.json main=- stage=0:- wt=.env.local,.gitignore,base.txt,harness/skills/tool.md,harness/state.json-><main>/harness/state.json wt-status=-
'

echo "=== the exclude entry of a configured symlink path ==="
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
