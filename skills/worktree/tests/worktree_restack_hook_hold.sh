#!/usr/bin/env bash
# A paused restack whose conflicts reach a path a harness hook declaration runs,
# at the pre-restack head or on the new base: the hook is handed back
# parseable, its conflicted content saved beside it, and continue and skip
# refuse until that copy is consumed by a move over the hook or a delete. A conflict in an
# ordinary path, a path a declared hook's path merely ends with included, keeps
# the markers in place as before. One table, a row per scenario; each row pins
# the exit status, the tool's keyed stderr records, whether a restack is still
# paused, whether each hook parses under `bash -n` and runs, which saved copies
# exist, and which files carry conflict markers. A library a declared hook
# sources, directly or through another library, is held the same way.
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
BASE_PATH="$PATH"

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
# A hook the base tree carries but no declaration names until one side of the
# restack adds .cursor/hooks.json.
CURSOR_HOOK=.cursor/hooks/stop.sh

# Libraries under the kendex skills tree: the Claude hook sources LIB, LIB
# sources INNER beside it from inside a function, under an indented directive
# as lane-mail-check.sh does, and nothing sources OTHER, which shares INNER's
# name.
# EXTRA is sourced only once the branch's Codex hook starts sourcing it.
LIB=.agents/skills/guard/scripts/lib/guard.sh
INNER=.agents/skills/guard/scripts/lib/inner.sh
OTHER=.agents/skills/other/scripts/lib/inner.sh
EXTRA=.agents/skills/guard/scripts/lib/extra.sh

# A hook sourcing a library the way a shipped hook does: under set -e, so a
# library that fails to parse fails the hook, with a directive naming the
# library through the harness's skills tree and a line finding it at run time.
write_sourcing_hook() {
  mkdir -p "$(dirname "$1")"
  printf '#!/usr/bin/env bash\nset -euo pipefail\n# shellcheck source=../skills/%s\nsource "$(dirname "$0")/../../.agents/skills/%s"\necho %s\n' "$2" "$2" "$3" >"$1"
}

declare_cursor() {
  printf '{"hooks": {"stop": [{"command": "bash .cursor/hooks/stop.sh"}]}}\n' >"$1/.cursor/hooks.json"
  git -C "$1" add .cursor/hooks.json
}

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
  write_sourcing_hook "$MAIN/$CLAUDE_HOOK" guard/scripts/lib/guard.sh base
  mkdir -p "$MAIN/${LIB%/*}"
  printf 'guard_load() {\n  # shellcheck source=inner.sh\n  source "${BASH_SOURCE[0]%%/*}/inner.sh"\n}\nguard_load\n' >"$MAIN/$LIB"
  write_hook "$MAIN/$INNER" base
  write_hook "$MAIN/$OTHER" base
  write_hook "$MAIN/$EXTRA" base
  write_hook "$MAIN/$CODEX_HOOK" base
  write_hook "$MAIN/$SOURCE_HOOK" base
  write_hook "$MAIN/$CURSOR_HOOK" base
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
    # One commit conflicting in an ordinary file and a declared hook at once.
    mixed) make_pair; edit wt file.txt "$CLAUDE_HOOK"; edit main file.txt "$CLAUDE_HOOK" ;;
    # An ordinary conflict first, then a hook conflict in the next commit.
    later) make_pair; edit wt file.txt; edit wt "$CLAUDE_HOOK"; edit main file.txt "$CLAUDE_HOOK" ;;
    # A library the Claude hook sources conflicts.
    lib) make_pair; edit wt "$LIB"; edit main "$LIB" ;;
    # A library that library sources conflicts.
    inner) make_pair; edit wt "$INNER"; edit main "$INNER" ;;
    # A file named like a sourced library, in a directory nothing sources from.
    other) make_pair; edit wt "$OTHER"; edit main "$OTHER" ;;
    # A later branch commit than the conflicting one starts sourcing EXTRA,
    # which the base edits too: only the pre-restack head sources it.
    branch-sourced)
      make_pair
      edit wt "$EXTRA"
      write_sourcing_hook "$WT/$CODEX_HOOK" guard/scripts/lib/extra.sh base
      git -C "$WT" add "$CODEX_HOOK"
      git -C "$WT" commit -q -m "wt: source $EXTRA"
      edit main "$EXTRA"
      ;;
    # The replayed commit starts sourcing EXTRA and edits it, the next branch
    # commit stops sourcing it, and the base edits it: only the commit being
    # replayed sources it, and its hook change is applied in the worktree.
    replayed-sourced)
      make_pair
      write_sourcing_hook "$WT/$CODEX_HOOK" guard/scripts/lib/extra.sh base
      git -C "$WT" add "$CODEX_HOOK"
      edit wt "$EXTRA"
      write_hook "$WT/$CODEX_HOOK" base
      git -C "$WT" add "$CODEX_HOOK"
      git -C "$WT" commit -q -m "wt: stop sourcing $EXTRA"
      edit main "$EXTRA"
      ;;
    # The base's Codex hook starts sourcing EXTRA, which the branch edits too:
    # only the paused HEAD sources it.
    base-sourced)
      make_pair
      edit wt "$EXTRA"
      write_sourcing_hook "$MAIN/$CODEX_HOOK" guard/scripts/lib/extra.sh base
      git -C "$MAIN" add "$CODEX_HOOK"
      edit main "$EXTRA"
      ;;
    # The declaration naming the hook exists only at the pre-restack head: a
    # later branch commit than the conflicting one adds it.
    branch-declared)
      make_pair
      edit wt "$CURSOR_HOOK"
      declare_cursor "$WT"
      git -C "$WT" commit -q -m "wt: declare .cursor/hooks.json"
      edit main "$CURSOR_HOOK"
      ;;
    # The declaration naming the hook exists only on the new base.
    base-declared) make_pair; edit wt "$CURSOR_HOOK"; declare_cursor "$MAIN"; edit main "$CURSOR_HOOK" ;;
    # The base deletes a declared hook the branch edits: a modify/delete
    # conflict with no base side to hold.
    deleted)
      make_pair
      edit wt "$CLAUDE_HOOK"
      git -C "$MAIN" rm -q "$CLAUDE_HOOK"
      git -C "$MAIN" commit -q -m "main: delete $CLAUDE_HOOK"
      git -C "$MAIN" push -q origin main
      ;;
    # A jq that fails, ahead of the real one: the declarations cannot be read.
    broken-jq)
      mkdir -p "$ROOT/stub"
      printf '#!/usr/bin/env bash\nexit 1\n' >"$ROOT/stub/jq"
      chmod +x "$ROOT/stub/jq"
      PATH="$ROOT/stub:$PATH"
      ;;
    # A git that fails the one discovery read named after the colon, ahead of
    # the real one: the grep and the read of the declarations, the listing of
    # tracked files, the read of the Claude hook as a sourcing script, and the
    # resolution of the commit being rebased.
    broken-git:*)
      local read
      case "${1#broken-git:}" in
        grep) read='*" grep -l -F "*' ;;
        declaration) read='*" cat-file -p "*":.claude/settings.json "*' ;;
        ls-tree) read='*" ls-tree -r --name-only "*' ;;
        sourcing) read="*\" cat-file -p \"*\":$CLAUDE_HOOK \"*" ;;
        pick) read='*" rev-parse --verify -q REBASE_HEAD^{commit} "*' ;;
        *) echo "UNKNOWN-READ: $1" >&2; exit 2 ;;
      esac
      mkdir -p "$ROOT/stub"
      printf '#!/usr/bin/env bash\ncase " $* " in %s) exit 128 ;; esac\nexec %q "$@"\n' "$read" "$(command -v git)" >"$ROOT/stub/git"
      chmod +x "$ROOT/stub/git"
      PATH="$ROOT/stub:$PATH"
      ;;
    restack) (cd "$MAIN" && "$SCRIPT" create "$ISSUE" --restack >/dev/null 2>&1) || true ;;
    restack-replay) (cd "$MAIN" && "$SCRIPT" create "$ISSUE" --restack --replay >/dev/null 2>&1) || true ;;
    resolve-file) printf 'resolved\n' >"$WT/file.txt"; git -C "$WT" add file.txt ;;
    continue) (cd "$MAIN" && "$SCRIPT" restack continue "$ISSUE" >/dev/null 2>&1) || true ;;
    stage-all) git -C "$WT" add -A ;;
    # The documented way to keep the held side: delete the saved copy and
    # stage the path.
    discard)
      local held
      for held in "$CLAUDE_HOOK" "$CODEX_HOOK"; do
        [[ -e "$WT/$held.restack-conflict" ]] || continue
        rm "$WT/$held.restack-conflict"
        git -C "$WT" add "$held"
        git -C "$WT" rm -q --cached --ignore-unmatch -- "$held.restack-conflict"
      done
      ;;
    # The documented resolution: fix the saved copy, then move it over the
    # hook in one step.
    consume|consume-staged)
      local path
      for path in "$CLAUDE_HOOK" "$CODEX_HOOK"; do
        [[ -e "$WT/$path.restack-conflict" ]] || continue
        write_hook "$WT/$path.restack-conflict" resolved
        mv "$WT/$path.restack-conflict" "$WT/$path"
        git -C "$WT" add "$path"
        # consume-staged skips the unstage, leaving a copy an earlier
        # `git add -A` staged in the index.
        [[ "$1" == consume-staged ]] || git -C "$WT" rm -q --cached --ignore-unmatch -- "$path.restack-conflict"
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
  PATH="$BASE_PATH"
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

# Saved copies in the worktree or in the index: a staged copy is one a
# continue would record in the branch.
saved() {
  local found
  found="$(cd "$WT" && { find . -name '*.restack-conflict' | sed 's|^\./||'; git ls-files -- '*.restack-conflict'; } | LC_ALL=C sort -u | paste -s -d ',' -)"
  printf '%s' "${found:--}"
}

# Whether each declared hook runs to exit 0, the libraries it sources
# included: a conflicted library fails the hook while `bash -n` passes.
runs() {
  local path out=""
  for path in "$CLAUDE_HOOK" "$CODEX_HOOK"; do
    if [[ ! -e "$WT/$path" ]]; then out="$out,-"
    elif (cd "$WT" && bash "$path" >/dev/null 2>&1); then out="$out,ok"
    else out="$out,FAIL"
    fi
  done
  printf '%s' "${out#,}"
}

markers() {
  local found
  found="$(cd "$WT" && { git grep -l --no-index -e '^<<<<<<< ' -- . 2>/dev/null || true; } | LC_ALL=C sort | paste -s -d ',' -)"
  printf '%s' "${found:--}"
}

# What each declared hook holds: the side's word the fixture wrote (`main` on
# the base, `wt` on the branch, `resolved` after a consume), `markers` for a
# conflicted file, `-` for none.
bodies() {
  local path out=""
  for path in "$CLAUDE_HOOK" "$CODEX_HOOK"; do
    if [[ ! -e "$WT/$path" ]]; then out="$out,-"
    elif grep -q -e '^<<<<<<< ' "$WT/$path"; then out="$out,markers"
    else out="$out,$(sed -n 's/^echo //p' "$WT/$path")"
    fi
  done
  printf '%s' "${out#,}"
}

# The paths the report tells the caller to resolve by editing out markers,
# read off its ordinary-path step; `-` when it names none.
ordinary() {
  local found
  found="$(sed -n 's/^Resolve \([^:]*\): edit out the conflict markers.*/\1/p' "$ROOT/err" | paste -s -d ';' -)"
  printf '%s' "${found:--}"
}

run() {
  local -a argv
  local rc=0 records
  read -r -a argv <<<"$1"
  (cd "$MAIN" && "$SCRIPT" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  records="$(message_records <"$ROOT/err" | grep -v '^rebase-' | sed "s|$WT|<wt>|g" | paste -s -d ';' -)"
  printf 'rc=%s err=%s paused=%s parses=%s runs=%s saved=%s markers=%s body=%s ordinary=%s' \
    "$rc" "$records" "$(paused)" "$(parses)" "$(runs)" "$(saved)" "$(markers)" "$(bodies)" "$(ordinary)"
}

C=.claude/hooks/stop.sh.restack-conflict
X=.codex/hooks/stop.sh.restack-conflict
S=hooks/stop.sh.restack-conflict
U=.cursor/hooks/stop.sh.restack-conflict
L=$LIB.restack-conflict
I=$INNER.restack-conflict
E=$EXTRA.restack-conflict
HELD="worktree-restack-hook-held: $CLAUDE_HOOK $CODEX_HOOK"

# label|fixture|command|expected
ROWS="a restack conflicting in declared hooks holds both at a parseable side and names them on one line|hooks|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt>;$HELD paused=yes parses=ok,ok runs=ok,ok saved=$C,$X markers=$C,$X body=main,main ordinary=-
a replay conflicting in declared hooks holds them the same way|hooks|create topic --restack --replay|rc=1 err=worktree-replay-conflicts: <wt>;$HELD paused=yes parses=ok,ok runs=ok,ok saved=$C,$X markers=$C,$X body=main,main ordinary=-
a conflict in an undeclared path that a hook path ends with keeps the markers in place|source|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=ok,ok runs=ok,ok saved=- markers=hooks/stop.sh body=base,base ordinary=hooks/stop.sh
continue refuses while a saved copy remains, even with everything staged|hooks restack stage-all|restack continue topic|rc=1 err=worktree-restack-hook-unconsumed: $C $X paused=yes parses=ok,ok runs=ok,ok saved=$C,$X markers=$C,$X body=main,main ordinary=-
skip refuses while a saved copy remains|hooks restack|restack skip topic|rc=1 err=worktree-restack-hook-unconsumed: $C $X paused=yes parses=ok,ok runs=ok,ok saved=$C,$X markers=$C,$X body=main,main ordinary=-
continue completes once each saved copy is moved over its hook|hooks restack consume|restack continue topic|rc=0 err=worktree-rebase-count: 1 paused=no parses=ok,ok runs=ok,ok saved=- markers=- body=resolved,resolved ordinary=-
abort restores the branch's hooks and removes the saved copies|hooks restack|restack abort topic|rc=0 err= paused=no parses=ok,ok runs=ok,ok saved=- markers=- body=wt,wt ordinary=-
continue that stops again in a hook holds it too|later restack resolve-file|restack continue topic|rc=1 err=worktree-restack-conflicts: $CLAUDE_HOOK;worktree-restack-hook-held: $CLAUDE_HOOK paused=yes parses=ok,ok runs=ok,ok saved=$C markers=$C body=main,base ordinary=-
a conflict in an ordinary file and a hook at once is told to edit only the ordinary file|mixed|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt>;worktree-restack-hook-held: $CLAUDE_HOOK paused=yes parses=ok,ok runs=ok,ok saved=$C markers=$C,file.txt body=main,base ordinary=file.txt
a replay continue refuses while a copy moved off disk is still staged|hooks restack-replay stage-all consume-staged|restack continue topic|rc=1 err=worktree-restack-hook-unconsumed: $C $X paused=yes parses=ok,ok runs=ok,ok saved=$C,$X markers=- body=resolved,resolved ordinary=-
a replay continue completes once each moved copy is also unstaged|hooks restack-replay stage-all consume|restack continue topic|rc=0 err=worktree-rebase-count: 1 paused=no parses=ok,ok runs=ok,ok saved=- markers=- body=resolved,resolved ordinary=-
continue completes once each saved copy is deleted and its path staged|hooks restack discard|restack continue topic|rc=0 err=worktree-rebase-count: 1 paused=no parses=ok,ok runs=ok,ok saved=- markers=- body=main,main ordinary=-
a declaration grep that fails holds every conflicted path, an ordinary one included|source broken-git:grep|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt>;worktree-restack-hook-held: $SOURCE_HOOK paused=yes parses=ok,ok runs=ok,ok saved=$S markers=$S body=base,base ordinary=-
a declaration that cannot be read holds every conflicted path, an ordinary one included|source broken-git:declaration|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt>;worktree-restack-hook-held: $SOURCE_HOOK paused=yes parses=ok,ok runs=ok,ok saved=$S markers=$S body=base,base ordinary=-
a tracked-file listing that fails holds every conflicted path, an ordinary one included|source broken-git:ls-tree|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt>;worktree-restack-hook-held: $SOURCE_HOOK paused=yes parses=ok,ok runs=ok,ok saved=$S markers=$S body=base,base ordinary=-
a sourcing script that cannot be read holds every conflicted path, an ordinary one included|source broken-git:sourcing|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt>;worktree-restack-hook-held: $SOURCE_HOOK paused=yes parses=ok,ok runs=ok,ok saved=$S markers=$S body=base,base ordinary=-
a recorded pick that does not resolve holds every conflicted path, an ordinary one included|source broken-git:pick|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt>;worktree-restack-hook-held: $SOURCE_HOOK paused=yes parses=ok,ok runs=ok,ok saved=$S markers=$S body=base,base ordinary=-
declarations that cannot be read hold every conflicted path, an ordinary one included|source broken-jq|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt>;worktree-restack-hook-held: $SOURCE_HOOK paused=yes parses=ok,ok runs=ok,ok saved=$S markers=$S body=base,base ordinary=-
a hook declared only at the pre-restack head is held|branch-declared|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt>;worktree-restack-hook-held: $CURSOR_HOOK paused=yes parses=ok,ok runs=ok,ok saved=$U markers=$U body=base,base ordinary=-
a hook declared only on the new base is held|base-declared|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt>;worktree-restack-hook-held: $CURSOR_HOOK paused=yes parses=ok,ok runs=ok,ok saved=$U markers=$U body=base,base ordinary=-
a hook the base deleted is held at the branch's side|deleted|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt>;worktree-restack-hook-held: $CLAUDE_HOOK paused=yes parses=ok,ok runs=ok,ok saved=$C markers=- body=wt,base ordinary=-
continue refuses while a deleted hook's saved copy remains|deleted restack|restack continue topic|rc=1 err=worktree-restack-hook-unconsumed: $C paused=yes parses=ok,ok runs=ok,ok saved=$C markers=- body=wt,base ordinary=-
a library a declared hook sources is held so the hook still runs|lib|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt>;worktree-restack-hook-held: $LIB paused=yes parses=ok,ok runs=ok,ok saved=$L markers=$L body=base,base ordinary=-
a library that library sources is held too|inner|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt>;worktree-restack-hook-held: $INNER paused=yes parses=ok,ok runs=ok,ok saved=$I markers=$I body=base,base ordinary=-
a file named like a sourced library in a directory nothing sources from keeps its markers|other|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=ok,ok runs=ok,ok saved=- markers=$OTHER body=base,base ordinary=$OTHER
a library only the pre-restack head's hook sources is held|branch-sourced|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt>;worktree-restack-hook-held: $EXTRA paused=yes parses=ok,ok runs=ok,ok saved=$E markers=$E body=base,base ordinary=-
a library only the commit being rebased sources is held|replayed-sourced|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt>;worktree-restack-hook-held: $EXTRA paused=yes parses=ok,ok runs=ok,ok saved=$E markers=$E body=base,base ordinary=-
a library only the commit being replayed sources is held|replayed-sourced|create topic --restack --replay|rc=1 err=worktree-replay-conflicts: <wt>;worktree-restack-hook-held: $EXTRA paused=yes parses=ok,ok runs=ok,ok saved=$E markers=$E body=base,base ordinary=-
a library only the paused HEAD's hook sources is held|base-sourced|create topic --restack|rc=1 err=worktree-rebase-conflicts: <wt>;worktree-restack-hook-held: $EXTRA paused=yes parses=ok,ok runs=ok,ok saved=$E markers=$E body=base,base ordinary=-
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

# Each row replaces one piece of text on a private copy of the package and
# reruns the row that pins it; the behaviour goes and nothing else, so a red row
# proves the assertion above reaches it. Fields split on '@', which no text
# here contains:
# label@file@text@its occurrences@replacement@fixture@command@expected
HOLD_CALL='held="$(restack_hold_conflicted_hooks "$wt" "$conflicts")" || held=""'
CONTROLS="without the hold a create restack leaves markers in both hooks@scripts/lib/restack-state.sh@$HOLD_CALL@1@held=\"\"@hooks@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=FAIL,FAIL runs=FAIL,FAIL saved=- markers=$CLAUDE_HOOK,$CODEX_HOOK body=markers,markers ordinary=$CLAUDE_HOOK $CODEX_HOOK
without the hold a create replay leaves markers in both hooks@scripts/lib/restack-state.sh@$HOLD_CALL@1@held=\"\"@hooks@create topic --restack --replay@rc=1 err=worktree-replay-conflicts: <wt> paused=yes parses=FAIL,FAIL runs=FAIL,FAIL saved=- markers=$CLAUDE_HOOK,$CODEX_HOOK body=markers,markers ordinary=$CLAUDE_HOOK $CODEX_HOOK
without the hold a continue that stops again leaves markers in the hook@scripts/lib/restack-state.sh@$HOLD_CALL@1@held=\"\"@later restack resolve-file@restack continue topic@rc=1 err=worktree-restack-conflicts: $CLAUDE_HOOK paused=yes parses=FAIL,ok runs=FAIL,ok saved=- markers=$CLAUDE_HOOK body=markers,base ordinary=$CLAUDE_HOOK
without the refusal continue records the saved copies in the branch@scripts/worktree@restack_refuse_unconsumed_hooks \"\$WT_PATH\" || exit 1@1@:@hooks restack stage-all@restack continue topic@rc=0 err=worktree-rebase-count: 1 paused=no parses=ok,ok runs=ok,ok saved=$C,$X markers=$C,$X body=main,main ordinary=-
without the cleanup abort leaves the saved copies behind@scripts/worktree@rm -f -- \"\$WT_PATH/\$HELD_COPY\"@1@:@hooks restack@restack abort topic@rc=0 err= paused=no parses=ok,ok runs=ok,ok saved=$C,$X markers=$C,$X body=wt,wt ordinary=-
without the unreadable fallback an ordinary path keeps its markers@scripts/lib/restack-state.sh@printf '%s\n' \"\$conflicts\"@1@:@source broken-jq@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=ok,ok runs=ok,ok saved=- markers=$SOURCE_HOOK body=base,base ordinary=$SOURCE_HOOK
without the declaration grep failing the hold an ordinary path keeps its markers@scripts/lib/restack-state.sh@'*.json')\" || rc=\$?@1@'*.json')\" || rc=0@source broken-git:grep@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=ok,ok runs=ok,ok saved=- markers=$SOURCE_HOOK body=base,base ordinary=$SOURCE_HOOK
without the declaration read failing the hold an ordinary path keeps its markers@scripts/lib/restack-state.sh@2>/dev/null)\"\$'\\n' || return 1@1@2>/dev/null)\"\$'\\n'@source broken-git:declaration@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=ok,ok runs=ok,ok saved=- markers=$SOURCE_HOOK body=base,base ordinary=$SOURCE_HOOK
without the tracked-file listing failing the hold an ordinary path keeps its markers@scripts/lib/restack-state.sh@--name-only \"\$rev\")\" || return 1@1@--name-only \"\$rev\")\"@source broken-git:ls-tree@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=ok,ok runs=ok,ok saved=- markers=$SOURCE_HOOK body=base,base ordinary=$SOURCE_HOOK
without the sourcing-script read failing the hold an ordinary path keeps its markers@scripts/lib/restack-state.sh@\\1/p')\" || return 1@1@\\1/p')\"@source broken-git:sourcing@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=ok,ok runs=ok,ok saved=- markers=$SOURCE_HOOK body=base,base ordinary=$SOURCE_HOOK
without the recorded pick failing the hold an ordinary path keeps its markers@scripts/lib/restack-state.sh@-q \"\$pick^{commit}\"@1@-q \"\${pick}^{commit}\" || true@source broken-git:pick@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=ok,ok runs=ok,ok saved=- markers=$SOURCE_HOOK body=base,base ordinary=$SOURCE_HOOK
without the pre-restack head a branch-declared hook keeps its markers@scripts/lib/restack-state.sh@\"\$(restack_state_get \"\$wt\" originalHead)\" HEAD \${paused@1@HEAD \${paused@branch-declared@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=ok,ok runs=ok,ok saved=- markers=$CURSOR_HOOK body=base,base ordinary=$CURSOR_HOOK
without the paused HEAD a base-declared hook keeps its markers@scripts/lib/restack-state.sh@originalHead)\" HEAD \${paused@1@originalHead)\" \${paused@base-declared@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=ok,ok runs=ok,ok saved=- markers=$CURSOR_HOOK body=base,base ordinary=$CURSOR_HOOK
without the fallback to the branch's side a deleted hook is not held@scripts/lib/restack-state.sh@! git -C \"\$wt\" checkout --theirs -- \"\$path\" >/dev/null 2>&1; }@1@true; }@deleted@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt>;worktree-restack-hook-hold-failed: $CLAUDE_HOOK paused=yes parses=ok,ok runs=ok,ok saved=$C markers=- body=wt,base ordinary=$CLAUDE_HOOK
without the held-path exclusion the report tells the caller to edit a held hook@scripts/lib/restack-state.sh@grep -F -x -q -e \"\$path\" <<<\"\$held\" || ordinary@1@true; ordinary@mixed@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt>;worktree-restack-hook-held: $CLAUDE_HOOK paused=yes parses=ok,ok runs=ok,ok saved=$C markers=$C,file.txt body=main,base ordinary=$CLAUDE_HOOK file.txt
with the branch's side taken first the held hooks keep the branch's version@scripts/lib/restack-state.sh@checkout --ours --@1@checkout --theirs --@hooks@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt>;$HELD paused=yes parses=ok,ok runs=ok,ok saved=$C,$X markers=$C,$X body=wt,wt ordinary=-
without the index check a replay continue records a staged copy in the branch@scripts/lib/restack-state.sh@! staged=\"\$(git -C \"\$wt\" ls-files -- \"\$copy\")\" || [[ -n \"\$staged\" ]]@1@false@hooks restack-replay stage-all consume-staged@restack continue topic@rc=0 err=worktree-rebase-count: 1 paused=no parses=ok,ok runs=ok,ok saved=$C,$X markers=- body=resolved,resolved ordinary=-
without the library follow a sourced library keeps its markers and the hook fails@scripts/lib/restack-state.sh@restack_hook_libraries \"\$wt\" \"\$rev\" \"\$words\" || return 1@1@:@lib@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=ok,ok runs=FAIL,ok saved=- markers=$LIB body=base,base ordinary=$LIB
without the indent allowance a directive inside a function is not read@scripts/lib/restack-state.sh@sed -n 's/^[[:space:]]*#[[:space:]]*shellcheck@1@sed -n 's/^#[[:space:]]*shellcheck@inner@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=ok,ok runs=FAIL,ok saved=- markers=$INNER body=base,base ordinary=$INNER
without following a library's own directives a library it sources keeps its markers@scripts/lib/restack-state.sh@queue=\"\$queue\"\$'\\n'\"\$target\"@1@:@inner@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=ok,ok runs=FAIL,ok saved=- markers=$INNER body=base,base ordinary=$INNER
with every directive matched as a path suffix a same-named unsourced file is held@scripts/lib/restack-state.sh@if [[ \"\$target\" == ../* ]]; then@1@if true; then@other@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt>;worktree-restack-hook-held: $OTHER paused=yes parses=ok,ok runs=ok,ok saved=$OTHER.restack-conflict markers=$OTHER.restack-conflict body=base,base ordinary=-
with libraries read at the paused HEAD only a library the branch's hook sources keeps its markers@scripts/lib/restack-state.sh@restack_hook_libraries \"\$wt\" \"\$rev\"@1@restack_hook_libraries \"\$wt\" HEAD@branch-sourced@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=ok,ok runs=ok,ok saved=- markers=$EXTRA body=base,base ordinary=$EXTRA
with libraries read at the pre-restack head only a library the base's hook sources keeps its markers@scripts/lib/restack-state.sh@restack_hook_libraries \"\$wt\" \"\$rev\"@1@restack_hook_libraries \"\$wt\" \"\$1\"@base-sourced@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=ok,ok runs=ok,FAIL saved=- markers=$EXTRA body=base,base ordinary=$EXTRA
without the commit being rebased a library only it sources keeps its markers@scripts/lib/restack-state.sh@HEAD \${paused:+\"\$paused\"})\"@1@HEAD)\"@replayed-sourced@create topic --restack@rc=1 err=worktree-rebase-conflicts: <wt> paused=yes parses=ok,ok runs=ok,FAIL saved=- markers=$EXTRA body=base,base ordinary=$EXTRA
without the commit being replayed a library only it sources keeps its markers@scripts/lib/restack-state.sh@HEAD \${paused:+\"\$paused\"})\"@1@HEAD)\"@replayed-sourced@create topic --restack --replay@rc=1 err=worktree-replay-conflicts: <wt> paused=yes parses=ok,ok runs=ok,FAIL saved=- markers=$EXTRA body=base,base ordinary=$EXTRA
"
m=0
while IFS='@' read -r label target text count replacement fixture command want; do
  [[ -n "$label" ]] || continue
  m=$((m + 1))
  pkg="$TMP_ROOT/control-$m/pkg/worktree"
  mkdir -p "$(dirname "$pkg")"
  cp -R "$PACKAGE_DIR" "$pkg"
  file="$pkg/$target"
  assert_eq "$(grep -c -F -e "$text" "$file")" "$count" "control $m finds every copy of the text it replaces"
  CUT_TEXT="$text" CUT_WITH="$replacement" awk '
    BEGIN { c = ENVIRON["CUT_TEXT"]; r = ENVIRON["CUT_WITH"] }
    { out = ""; while ((i = index($0, c)) > 0) { out = out substr($0, 1, i - 1) r; $0 = substr($0, i + length(c)) } print out $0 }
  ' "$file" >"$file.cut"
  cat "$file.cut" >"$file"
  assert_eq "$(grep -c -F -e "$text" "$file" || true)" "0" "control $m replaces it in its private copy only"
  # shellcheck disable=SC2086
  build "control-$m" "$pkg/scripts/worktree" $fixture
  assert_eq "$(run "$command")" "$want" "control: $label"
done <<<"$CONTROLS"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
