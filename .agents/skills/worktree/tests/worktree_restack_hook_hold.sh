#!/usr/bin/env bash
# A paused restack whose conflicts reach a path a harness hook declaration runs:
# the hook is handed back parseable, its conflicted content saved beside it,
# and continue and skip refuse until that copy is consumed. A conflict in an
# ordinary path, a path a declared hook's path merely ends with included, keeps
# the markers in place as before. One table, a row per scenario; each row pins
# the exit status, the tool's keyed stderr records, whether a restack is still
# paused, whether each hook parses under `bash -n`, which saved copies exist,
# and which files carry conflict markers.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/messages.sh
source "$TEST_DIR/lib/messages.sh"
PACKAGE_DIR="$(cd "$TEST_DIR/.." && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$PACKAGE_DIR/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# The forge: no pull request exists for any branch here, so the merge lookup
# answers "not merged" and every restack runs.
mkdir -p "$TMP_ROOT/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP_ROOT/bin/gh"
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

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

ISSUE=topic
ROOT=""
MAIN=""
WT=""
SCRIPT=""

# The two declaration shapes kendex renders: Claude's settings.json runs a
# hook under $CLAUDE_PROJECT_DIR, Codex's hooks.json names it in a quoted
# assignment. hooks/stop.sh is the catalog source a render is made from: no
# harness runs it, and its path is the tail of both rendered paths.
CLAUDE_HOOK=.claude/hooks/stop.sh
CODEX_HOOK=.codex/hooks/stop.sh
SOURCE_HOOK=hooks/stop.sh

write_hook() {
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env bash\necho %s\n' "$2" >"$1"
}

make_pair() {
  mkdir -p "$MAIN/.claude" "$MAIN/.codex"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email test@example.com
  git -C "$MAIN" config user.name Test
  git -C "$MAIN" config commit.gpgsign false
  git -C "$MAIN" config gc.auto 0
  git -C "$MAIN" config maintenance.auto false
  cat >"$MAIN/.claude/settings.json" <<'JSON'
{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/stop.sh\""}]}]}}
JSON
  cat >"$MAIN/.codex/hooks.json" <<'JSON'
{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "p='.codex/hooks/stop.sh'; bash \"$r/$p\""}]}]}}
JSON
  write_hook "$MAIN/$CLAUDE_HOOK" base
  write_hook "$MAIN/$CODEX_HOOK" base
  write_hook "$MAIN/$SOURCE_HOOK" base
  printf 'orig\n' >"$MAIN/file.txt"
  git -C "$MAIN" add -A
  git -C "$MAIN" commit -q -m base
  printf 'WORKTREE_BASE_DIR="../trees"\n' >"$MAIN/.env.local"
  git init -q --bare "$ROOT/origin.git"
  git --git-dir="$ROOT/origin.git" config gc.auto 0
  git --git-dir="$ROOT/origin.git" config maintenance.auto false
  git -C "$MAIN" remote add origin "$ROOT/origin.git"
  git -C "$MAIN" push -q -u origin main
  (cd "$MAIN" && "$SCRIPT" create "$ISSUE" >/dev/null 2>&1)
}

# Edit each named path on one side and commit: `wt` for the issue branch,
# `main` for the pushed default branch.
edit() {
  local side="$1" dir path
  shift
  if [[ "$side" == wt ]]; then dir="$WT"; else dir="$MAIN"; fi
  for path in "$@"; do
    if [[ "$path" == file.txt ]]; then printf '%s\n' "$side" >"$dir/$path"; else write_hook "$dir/$path" "$side"; fi
    git -C "$dir" add "$path"
  done
  git -C "$dir" commit -q -m "$side: $*"
  [[ "$side" == wt ]] || git -C "$MAIN" push -q origin main
}

step() {
  case "$1" in
    # Both declared hooks conflict in the branch's one commit.
    hooks) make_pair; edit wt "$CLAUDE_HOOK" "$CODEX_HOOK"; edit main "$CLAUDE_HOOK" "$CODEX_HOOK" ;;
    # Only the undeclared source conflicts.
    source) make_pair; edit wt "$SOURCE_HOOK"; edit main "$SOURCE_HOOK" ;;
    # An ordinary conflict first, then a hook conflict in the next commit.
    later) make_pair; edit wt file.txt; edit wt "$CLAUDE_HOOK"; edit main file.txt "$CLAUDE_HOOK" ;;
    restack) (cd "$MAIN" && "$SCRIPT" create "$ISSUE" --restack >/dev/null 2>&1) || true ;;
    resolve-file) printf 'resolved\n' >"$WT/file.txt"; git -C "$WT" add file.txt ;;
    continue) (cd "$MAIN" && "$SCRIPT" restack continue "$ISSUE" >/dev/null 2>&1) || true ;;
    stage-all) git -C "$WT" add -A ;;
    # The documented resolution: fix the saved copy, then move it over the
    # hook in one step.
    consume)
      local path
      for path in "$CLAUDE_HOOK" "$CODEX_HOOK"; do
        [[ -e "$WT/$path.restack-conflict" ]] || continue
        write_hook "$WT/$path.restack-conflict" resolved
        mv "$WT/$path.restack-conflict" "$WT/$path"
        git -C "$WT" add "$path"
      done
      ;;
    *) echo "UNKNOWN-STEP: $1" >&2; exit 2 ;;
  esac
}

build() {
  local word
  ROOT="$TMP_ROOT/$1"
  MAIN="$ROOT/main"
  WT="$ROOT/trees/$ISSUE"
  SCRIPT="$2"
  shift 2
  for word in "$@"; do step "$word"; done
}

paused() {
  local state path
  for state in rebase-merge rebase-apply sequencer; do
    path="$(git -C "$WT" rev-parse --git-path "$state")"
    [[ "$path" == /* ]] || path="$WT/$path"
    if [[ -d "$path" ]]; then printf 'yes'; return; fi
  done
  printf 'no'
}

parses() {
  local path out=""
  for path in "$CLAUDE_HOOK" "$CODEX_HOOK"; do
    if bash -n "$WT/$path" 2>/dev/null; then out="$out,ok"; else out="$out,FAIL"; fi
  done
  printf '%s' "${out#,}"
}

saved() {
  local found
  found="$(cd "$WT" && find . -name '*.restack-conflict' | sed 's|^\./||' | LC_ALL=C sort | paste -s -d ',' -)"
  printf '%s' "${found:--}"
}

markers() {
  local found
  found="$(cd "$WT" && { git grep -l --no-index -e '^<<<<<<< ' -- . 2>/dev/null || true; } | LC_ALL=C sort | paste -s -d ',' -)"
  printf '%s' "${found:--}"
}

run() {
  local -a argv
  local rc=0 records
  read -r -a argv <<<"$1"
  (cd "$MAIN" && "$SCRIPT" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  records="$(message_records <"$ROOT/err" | grep -v '^rebase-' | sed "s|$WT|<wt>|g" | paste -s -d ';' -)"
  printf 'rc=%s err=%s paused=%s parses=%s saved=%s markers=%s' \
    "$rc" "$records" "$(paused)" "$(parses)" "$(saved)" "$(markers)"
}

C=.claude/hooks/stop.sh.restack-conflict
X=.codex/hooks/stop.sh.restack-conflict
HELD="worktree-restack-hook-held: $CLAUDE_HOOK $CODEX_HOOK"

# label|fixture|command|expected
ROWS="a restack conflicting in declared hooks holds both at a parseable side and names them on one line|hooks|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt>;$HELD paused=yes parses=ok,ok saved=$C,$X markers=$C,$X
a replay conflicting in declared hooks holds them the same way|hooks|create topic --restack --replay|rc=1 err=worktree-replay-conflicts: <wt>;$HELD paused=yes parses=ok,ok saved=$C,$X markers=$C,$X
a conflict in an undeclared path that a hook path ends with keeps the markers in place|source|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=ok,ok saved=- markers=hooks/stop.sh
continue refuses while a saved copy remains, even with everything staged|hooks restack stage-all|restack continue topic|rc=1 err=worktree-restack-hook-unconsumed: $C $X paused=yes parses=ok,ok saved=$C,$X markers=$C,$X
skip refuses while a saved copy remains|hooks restack|restack skip topic|rc=1 err=worktree-restack-hook-unconsumed: $C $X paused=yes parses=ok,ok saved=$C,$X markers=$C,$X
continue completes once each saved copy is moved over its hook|hooks restack consume|restack continue topic|rc=0 err=worktree-rebase-count: 1 paused=no parses=ok,ok saved=- markers=-
abort restores the branch's hooks and removes the saved copies|hooks restack|restack abort topic|rc=0 err= paused=no parses=ok,ok saved=- markers=-
continue that stops again in a hook holds it too|later restack resolve-file|restack continue topic|rc=1 err=worktree-restack-conflicts: $CLAUDE_HOOK;worktree-restack-hook-held: $CLAUDE_HOOK paused=yes parses=ok,ok saved=$C markers=$C
"

echo "=== worktree restack over a conflicted harness hook ==="
n=0
while IFS='|' read -r label fixture command want; do
  [[ -n "$label" ]] || continue
  n=$((n + 1))
  # shellcheck disable=SC2086
  build "row-$n" "$WORKTREE_SCRIPT" $fixture
  assert_eq "$(run "$command")" "$want" "$label"
done <<<"$ROWS"

echo
echo "=== must-fail controls: each cut on a private package copy ==="

# Each row removes one call on a private copy of the package and reruns the
# row that pins it. The call's text goes and nothing else, so a red row proves
# the assertion above reaches that call. Fields split on '@', which no call
# contains: label@file@call removed@its occurrences@fixture@command@expected
CONTROLS="without the hold the hooks keep their markers and fail to parse@scripts/worktree@restack_hold_conflicted_hooks \"\$WT_PATH\" \"\$CONFLICT_FILES\" || true@2@hooks@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=FAIL,FAIL saved=- markers=$CLAUDE_HOOK,$CODEX_HOOK
without the hold a continue that stops again leaves the markers in the hook@scripts/lib/restack-state.sh@restack_hold_conflicted_hooks \"\$wt\" \"\$conflict_files\" || true@1@later restack resolve-file@restack continue topic@rc=1 err=worktree-restack-conflicts: $CLAUDE_HOOK paused=yes parses=FAIL,ok saved=- markers=$CLAUDE_HOOK
without the refusal continue records the saved copies in the branch@scripts/worktree@restack_refuse_unconsumed_hooks \"\$WT_PATH\" || exit 1@1@hooks restack stage-all@restack continue topic@rc=0 err=worktree-rebase-count: 1 paused=no parses=ok,ok saved=$C,$X markers=$C,$X
without the cleanup abort leaves the saved copies behind@scripts/worktree@rm -f -- \"\$WT_PATH/\$HELD_COPY\"@1@hooks restack@restack abort topic@rc=0 err= paused=no parses=ok,ok saved=$C,$X markers=$C,$X
"
m=0
while IFS='@' read -r label target call count fixture command want; do
  [[ -n "$label" ]] || continue
  m=$((m + 1))
  pkg="$TMP_ROOT/control-$m/pkg/worktree"
  mkdir -p "$(dirname "$pkg")"
  cp -R "$PACKAGE_DIR" "$pkg"
  file="$pkg/$target"
  assert_eq "$(grep -c -F -e "$call" "$file")" "$count" "control $m finds every copy of the call it removes"
  awk -v c="$call" '{ while ((i = index($0, c)) > 0) $0 = substr($0, 1, i - 1) ": cut" substr($0, i + length(c)); print }' \
    "$file" >"$file.cut"
  cat "$file.cut" >"$file"
  assert_eq "$(grep -c -F -e "$call" "$file" || true)" "0" "control $m removes it from its private copy only"
  # shellcheck disable=SC2086
  build "control-$m" "$pkg/scripts/worktree" $fixture
  assert_eq "$(run "$command")" "$want" "control: $label"
done <<<"$CONTROLS"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
