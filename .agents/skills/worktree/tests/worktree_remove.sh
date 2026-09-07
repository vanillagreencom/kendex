#!/usr/bin/env bash
# `worktree remove`: one table.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_PACKAGE_DIR="$(cd "$TEST_DIR/.." && pwd)"
WORKTREE_SCRIPT="$WORKTREE_PACKAGE_DIR/scripts/worktree"
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

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  git -C "$repo" config commit.gpgsign false
  printf 'base\n' > "$repo/file.txt"
  git -C "$repo" add file.txt
  git -C "$repo" commit -q -m base
}

# --- remove: one table ------------------------------------------------------------
# A row builds its own main checkout with an issue worktree at trees/topic,
# runs one `remove` command line from the main checkout, and pins the exit
# status, stdout (usage text by its first line), stderr whole and what is left:
# the worktree's registration, the branch, the directories under trees/ and
# every configured symlink's target.
mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}:${2:-}" in
  pr:list) ;;
esac
STUB
chmod +x "$TMP_ROOT/bin/gh"

ROOT=""
MAIN=""
WT=""
ROW_PATH=""

step() {
  case "$1" in
    tree)
      make_repo "$MAIN"
      git -C "$MAIN" worktree add -q -b topic "$WT" main
      ;;
    commit)
      printf 'branch-only\n' >>"$WT/file.txt"
      git -C "$WT" add file.txt
      git -C "$WT" commit -q -m 'branch only'
      ;;
    links)
      printf 'agents\n' >"$MAIN/AGENTS.md"
      mkdir -p "$MAIN/.agents" "$MAIN/.claude/agents"
      printf 'lib\n' >"$MAIN/.agents/lib.sh"
      git -C "$MAIN" add AGENTS.md
      git -C "$MAIN" commit -q -m agents
      printf '%s\n' 'WORKTREE_SYMLINKS=".env.local .agents .claude/agents"' \
        'WORKTREE_RELATIVE_SYMLINKS=".claude/POINTER.md=../AGENTS.md"' >"$MAIN/.env.local"
      (cd "$MAIN" && "$WORKTREE_SCRIPT" fix-links "$WT") >/dev/null
      ;;
    lock) git -C "$MAIN" worktree lock "$WT" --reason "session guard: owner=topic" ;;
    unlock) git -C "$MAIN" worktree unlock "$WT" ;;
    # git itself refuses the removal after every precheck passed: the lock
    # precheck is a racy diagnostic, and only "nothing is stripped before git
    # runs" keeps the links whole here, so this row and the locked one are
    # two mechanisms, not one.
    git-refuses)
      mkdir -p "$ROOT/bin"
      cat >"$ROOT/bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" worktree remove --force "* ]]; then
  echo "simulated worktree removal failure" >&2
  exit 1
fi
exec "$REAL_GIT_BIN" "$@"
STUB
      chmod +x "$ROOT/bin/git"
      ROW_PATH="$ROOT/bin:$ROW_PATH"
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
  WT="$ROOT/trees/topic"
  ROW_PATH="$TMP_ROOT/bin:$PATH"
  for word in "$@"; do step "$word"; done
}

link_targets() {
  local rel out=""
  for rel in .env.local .agents .claude/agents .claude/POINTER.md; do
    [[ -L "$WT/$rel" ]] || continue
    out="$out,$rel->$(readlink "$WT/$rel" | sed -e "s|$MAIN|<main>|")"
  done
  printf '%s' "${out:-,-}" | cut -c2-
}

# The worktree as the main checkout registers it and as the worktree itself
# answers (live: its own .git resolves), the branch, the trees/ directory and
# every configured symlink's target.
remove_state() {
  local worktree=absent live=no branch=absent dirs
  git -C "$WT" rev-parse --git-dir >/dev/null 2>&1 && live=yes
  if git -C "$MAIN" worktree list --porcelain | grep -qx "worktree $WT"; then
    worktree=registered
  elif [[ -e "$WT" ]]; then
    worktree=unregistered
  fi
  git -C "$MAIN" show-ref --verify --quiet refs/heads/topic && branch=present
  dirs="$(find "$ROOT/trees" -mindepth 1 -maxdepth 1 2>/dev/null | sed 's|.*/||' | sort | paste -s -d ',' - || true)"
  printf 'worktree=%s/%s branch=%s dirs=%s links=%s' "$worktree" "$live" "$branch" "${dirs:--}" "$(link_targets)"
}

REAL_GIT_BIN="$(command -v git)"

run_remove() {
  local -a argv
  local rc=0
  read -r -a argv <<<"$1"
  (cd "$MAIN" && PATH="$ROW_PATH" REAL_GIT_BIN="$REAL_GIT_BIN" \
    "$WORKTREE_SCRIPT" remove "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  printf 'rc=%s out=%s err=%s %s' "$rc" \
    "$(sed -e "s|$WT|<wt>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" -e '/^Usage: /q' "$ROOT/out" | paste -s -d ';' -)" \
    "$(sed -e "s|$WT|<wt>|g" -e "s|$MAIN|<main>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" "$ROOT/err" | paste -s -d ';' -)" \
    "$(remove_state)"
}

locked_block() {
  printf '%s' "Error: <wt> is a locked worktree; refusing to remove it.;  Worktree: <wt>;  Lock reason: session guard: owner=topic;Nothing in the worktree was modified.;A lock usually means a live session owns this worktree; confirm it is finished first.;To release the lock and retry:;  git -C \"<main>\" worktree unlock \"<wt>\""
}

refused_block() {
  printf '%s' "Error: Git could not remove the worktree; preserving it for manual recovery: <wt>;  git: simulated worktree removal failure;  Branch: topic (not deleted);Nothing was removed before Git ran, so a refusal made before deletion started (a lock, for example) leaves the worktree exactly as it was.;Git's deletion is not atomic: if it failed partway through, the worktree may be partially removed — inspect its contents before retrying, and restore links with: <worktree> fix-links \"<wt>\""
}

unmerged_block() {
  printf '%s' "Error: Removed worktree but could not delete local branch 'topic'.;  Remaining branch: topic;  Worktree path removed/pruned: <wt>;  Not merged into main, and no pull request merged into main carries this branch name;  After verifying it is safe, delete manually with: git -C \"<main>\" branch -D \"topic\""
}

remove_out() {
  case "$1" in
    -) printf '' ;;
    removed) printf 'Removed: <wt>' ;;
    usage) printf 'Usage: worktree remove [ID|/path]' ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

remove_err() {
  case "$1" in
    -) printf '' ;;
    deleted) printf "Deleted branch 'topic' — merged into main." ;;
    unknown-option) printf '%s' "Error: unknown option '--bogus' for remove;Run: <worktree> remove --help" ;;
    unmerged) unmerged_block ;;
    locked) locked_block ;;
    refused) refused_block ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}

LINKS='.env.local-><main>/.env.local,.agents-><main>/.agents,.claude/agents-><main>/.claude/agents,.claude/POINTER.md->../AGENTS.md'

# label|fixture|args|rc|out|err|state
REMOVE_ROWS='
a merged branch: the worktree and the branch both go|tree|TOPIC|0|removed|deleted|worktree=absent/no branch=absent dirs=- links=-
--help prints usage and removes nothing|tree|--help|0|usage|-|worktree=registered/yes branch=present dirs=topic links=-
the short help flag prints usage and removes nothing|tree|-h|0|usage|-|worktree=registered/yes branch=present dirs=topic links=-
an option-looking argument is refused before it becomes a path|tree|--bogus|1|-|unknown-option|worktree=registered/yes branch=present dirs=topic links=-
an unmerged branch: the worktree goes, the branch stays, the diagnostic names the manual delete|tree commit|TOPIC|1|removed|unmerged|worktree=absent/no branch=present dirs=- links=-
a locked worktree is refused with its owner and the unlock command, links intact|tree links lock|TOPIC|1|-|locked|worktree=registered/yes branch=present dirs=topic links=LINKS
the same worktree unlocked is removed|tree links lock unlock|TOPIC|0|removed|deleted|worktree=absent/no branch=absent dirs=- links=-
a removal git refuses after every precheck leaves the worktree, branch and links intact|tree links git-refuses|TOPIC|1|-|refused|worktree=registered/yes branch=present dirs=topic links=LINKS
'

echo "=== worktree remove ==="
n=0
while IFS='|' read -r label fixture args rc out err want_state; do
  [[ -n "$label$fixture$args$rc$out$err$want_state" ]] || continue
  n=$((n + 1))
  # shellcheck disable=SC2086
  build "remove-$n" $fixture
  want_state="${want_state//LINKS/$LINKS}"
  assert_eq "$(run_remove "$args")" "rc=$rc out=$(remove_out "$out") err=$(remove_err "$err") $want_state" "$label"
done <<<"$REMOVE_ROWS"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
