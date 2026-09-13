#!/usr/bin/env bash
# `worktree remove`: one table.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/messages.sh
source "$TEST_DIR/lib/messages.sh"
WORKTREE_PACKAGE_DIR="$(cd "$TEST_DIR/.." && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$WORKTREE_PACKAGE_DIR/scripts/worktree}"
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
    # An unreconciled rebase map in the worktree's private git dir: the only
    # record of a rewrite, which removal would delete while keeping the
    # branch the rewrite produced.
    unreconciled-map)
      MAP_FILE="$(git -C "$WT" rev-parse --absolute-git-dir)/kendex-rebase-map"
      printf 'rebase-unmapped: %s\n' "$(git -C "$WT" rev-parse HEAD)" >"$MAP_FILE"
      ;;
    # The worktree directory gone while its registration stands: what git's
    # own non-transactional deletion leaves behind, and what a later remove
    # meets. Its private git dir, and anything in it, is still there until the
    # registration removal.
    vanished) rm -rf -- "${WT:?}" ;;
    vanished-sibling-map)
      git -C "$MAIN" worktree add -q -b sibling "$ROOT/trees/sibling" main
      SIBLING_GIT_DIR="$(git -C "$ROOT/trees/sibling" rev-parse --absolute-git-dir)"
      printf 'rebase-unmapped: %s\n' "$(git -C "$MAIN" rev-parse HEAD)" >"$ROOT/sibling-map"
      cp "$ROOT/sibling-map" "$SIBLING_GIT_DIR/kendex-rebase-map"
      rm -rf -- "$ROOT/trees/sibling"
      ;;
    # A symlink TO the worktree. Its own canonical form is the path git
    # recorded; nothing built from its parent and its own basename is.
    alias) ln -s "$WT" "$ROOT/alias" ;;
    lock) git -C "$MAIN" worktree lock "$WT" --reason "session guard: owner=topic" ;;
    empty-lock) git -C "$MAIN" worktree lock "$WT" ;;
    own-lease | foreign-lease)
      local owner=TOPIC
      [[ "$1" != foreign-lease ]] || owner=another-session
      "$WORKTREE_PACKAGE_DIR/scripts/worktree-session-guard" claim "$WT" --owner "$owner" >/dev/null
      ;;
    lock-record)
      LOCK_FILE="$(git -C "$WT" rev-parse --absolute-git-dir)/locked"
      cp "$LOCK_FILE" "$ROOT/lock-copy"
      ;;
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
  MAP_FILE=""
  SIBLING_GIT_DIR=""
  LOCK_FILE=""
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
  if [[ -n "$SIBLING_GIT_DIR" ]]; then
    local sibling=absent map=missing
    git -C "$MAIN" worktree list --porcelain | grep -xF "worktree $ROOT/trees/sibling" >/dev/null && sibling=registered
    cmp -s "$ROOT/sibling-map" "$SIBLING_GIT_DIR/kendex-rebase-map" && map=intact
    printf ' sibling=%s/%s' "$sibling" "$map"
  fi
  if [[ -n "$LOCK_FILE" ]]; then
    local lock=changed
    cmp -s "$ROOT/lock-copy" "$LOCK_FILE" && lock=intact
    printf ' lock=%s' "$lock"
  fi
}

REAL_GIT_BIN="$(command -v git)"
MAP_FILE=""

run_remove() {
  local -a argv
  local rc=0
  local i
  read -r -a argv <<<"$1"
  for i in "${!argv[@]}"; do
    [[ "${argv[i]}" == @alias ]] && argv[i]="$ROOT/alias"
  done
  (cd "$MAIN" && PATH="$ROW_PATH" REAL_GIT_BIN="$REAL_GIT_BIN" \
    "$WORKTREE_SCRIPT" remove "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  printf 'rc=%s out=%s err=%s %s' "$rc" \
    "$(message_records <"$ROOT/out" | sed -e "s|$WT|<wt>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" -e '/^Usage: /q' | paste -s -d ';' -)" \
    "$(message_records <"$ROOT/err" | sed -e "s|${MAP_FILE:-NONE}|<map>|g" -e "s|$ROOT/alias|<alias>|g" -e "s|$WT|<wt>|g" -e "s|$MAIN|<main>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" | paste -s -d ';' -)" \
    "$(remove_state)"
}

locked_block() {
  printf '%s' 'worktree-worktree-locked: <wt>'
}

refused_block() {
  printf '%s' 'worktree-remove-failed: <wt>'
}

map_block() {
  printf '%s' 'worktree-remove-rebase-map: <map>'
}

unmerged_block() {
  printf '%s' 'worktree-branch-delete-failed: topic'
}

remove_out() {
  case "$1" in
    -) printf '' ;;
    removed) printf 'worktree-removed: <wt>' ;;
    usage) printf 'worktree-help: remove' ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

remove_err() {
  case "$1" in
    -) printf '' ;;
    deleted) printf "worktree-branch-deleted: topic" ;;
    released+deleted) printf '%s' 'worktree-lease-released: path=<wt> owner=TOPIC;worktree-branch-deleted: topic' ;;
    unknown-option) printf '%s' "worktree-remove-option-unknown: --bogus" ;;
    unmerged) unmerged_block ;;
    locked) locked_block ;;
    refused) refused_block ;;
    held-map) map_block ;;
    unidentified) printf '%s' 'worktree-remove-unidentified: <alias>' ;;
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
a worktree still holding an unreconciled rebase map is refused, tree and branch intact|tree commit links unreconciled-map|TOPIC|1|-|held-map|worktree=registered/yes branch=present dirs=topic links=LINKS
the same refusal reaches it through a symlink, which removal accepts and would follow|tree commit links unreconciled-map alias|@alias|1|-|held-map|worktree=registered/yes branch=present dirs=topic links=LINKS
the same refusal covers a worktree whose directory is already gone|tree commit unreconciled-map vanished|TOPIC|1|-|held-map|worktree=registered/no branch=present dirs=- links=-
an address that resolves to no registration refuses removal|tree commit unreconciled-map alias vanished|@alias|1|-|unidentified|worktree=registered/no branch=present dirs=- links=-
an absent worktree with an unmerged branch names the kept branch|tree commit vanished|TOPIC|1|removed|unmerged|worktree=absent/no branch=present dirs=- links=-
an absent worktree with a merged branch deletes the branch|tree vanished|TOPIC|0|removed|deleted|worktree=absent/no branch=absent dirs=- links=-
removing a live target preserves an absent sibling registration and its map|tree vanished-sibling-map|TOPIC|0|removed|deleted|worktree=absent/no branch=absent dirs=- links=- sibling=registered/intact
removing an absent target preserves an absent sibling registration and its map|tree vanished-sibling-map vanished|TOPIC|0|removed|deleted|worktree=absent/no branch=absent dirs=- links=- sibling=registered/intact
an absent locked worktree keeps its registration, branch and lock|tree lock lock-record vanished|TOPIC|1|-|locked|worktree=registered/no branch=present dirs=- links=- lock=intact
an absent worktree with an empty native lock stays registered|tree empty-lock lock-record vanished|TOPIC|1|-|locked|worktree=registered/no branch=present dirs=- links=- lock=intact
an absent worktree with a foreign lease keeps its registration, branch and lease|tree foreign-lease lock-record vanished|TOPIC|1|-|locked|worktree=registered/no branch=present dirs=- links=- lock=intact
an absent worktree releases its own lease and is removed|tree own-lease vanished|TOPIC|0|removed|released+deleted|worktree=absent/no branch=absent dirs=- links=-
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
