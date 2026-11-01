#!/usr/bin/env bash
# `worktree remove`: one table.
set -euo pipefail
# The fixtures' origin is a local path that names no GitHub repository, so
# the suite names the default branch.
export WORKTREE_DEFAULT_BRANCH=main
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/messages.sh
source "$TEST_DIR/lib/messages.sh"
WORKTREE_PACKAGE_DIR="$(cd "$TEST_DIR/.." && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$WORKTREE_PACKAGE_DIR/scripts/worktree}"
TMP_ROOT="$(mktemp -d)" || { echo "worktree_remove: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "worktree_remove: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "worktree_remove: scratch=resolve-failed" >&2; exit 1; }
LIVE_PID=''
finish_session() {
  [[ -n "$LIVE_PID" ]] || return 0
  printf 'close\n' >"$ROOT/session.pipe"
  wait "$LIVE_PID"
  LIVE_PID=''
}
trap 'finish_session; rm -rf -- "${TMP_ROOT:?}"' EXIT

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
  git -C "$repo" config gc.auto 0
  git -C "$repo" config maintenance.auto false
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
ROW_ENV=()

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
    adopted-lease)
      # The hook claims under the session identity; orch adopts under its item.
      # These rows hold the writer-PID rule of a lease that records no session
      # process, as an older lease does: a ps that cannot answer keeps the
      # adopt from recording the suite's own ancestry. The lifecycle suite
      # covers leases that record one.
      if [[ ! -x "$TMP_ROOT/no-ps-bin/ps" ]]; then
        mkdir -p "$TMP_ROOT/no-ps-bin"
        printf '#!/usr/bin/env bash\nexit 2\n' >"$TMP_ROOT/no-ps-bin/ps"
        chmod +x "$TMP_ROOT/no-ps-bin/ps"
      fi
      env KENDEX_SESSION_OWNER=predecessor "$WORKTREE_PACKAGE_DIR/scripts/worktree-session-guard" claim "$WT" >/dev/null
      env KENDEX_SESSION_OWNER=predecessor PATH="$TMP_ROOT/no-ps-bin:$PATH" "$WORKTREE_PACKAGE_DIR/scripts/worktree-session-guard" claim "$WT" --owner TOPIC --adopt >/dev/null
      [[ -z "$("$WORKTREE_PACKAGE_DIR/scripts/worktree-session-guard" status "$WT" | jq -r .sessions)" ]] || { echo 'worktree_remove: fixture=adopted-lease-recorded-a-session' >&2; exit 1; }
      ;;
    item-record)
      # create records the normalized issue ID, rather than the lease spelling.
      printf 'topic\n' >"$(git -C "$WT" rev-parse --absolute-git-dir)/kendex-issue"
      ;;
    kendex-session-owner)
      ROW_ENV=(-u HT_SESSION_OWNER KENDEX_SESSION_OWNER=predecessor USER=fallback-session)
      ;;
    ht-session-owner)
      ROW_ENV=(-u KENDEX_SESSION_OWNER HT_SESSION_OWNER=predecessor USER=fallback-session)
      ;;
    no-jq)
      # Derive the command path from this host, without the optional parser.
      # Only the removal process uses it; fixture assertions can still use jq.
      local path_dir path_exe exe_name
      local -a path_dirs
      if [[ ! -d "$TMP_ROOT/no-jq-bin" ]]; then
        mkdir "$TMP_ROOT/no-jq-bin"
        IFS=: read -r -a path_dirs <<<"$PATH"
        for path_dir in "${path_dirs[@]}"; do
          [[ -d "$path_dir" ]] || continue
          for path_exe in "$path_dir"/*; do
            exe_name="${path_exe##*/}"
            [[ "$exe_name" != jq && -x "$path_exe" && ! -d "$path_exe" ]] || continue
            [[ ! -e "$TMP_ROOT/no-jq-bin/$exe_name" ]] || continue
            ln -s "$path_exe" "$TMP_ROOT/no-jq-bin/$exe_name"
          done
        done
      fi
      ROW_PATH="$ROOT/bin:$TMP_ROOT/bin:$TMP_ROOT/no-jq-bin"
      if PATH="$ROW_PATH" "$BASH" -c 'command -v jq' >/dev/null 2>&1; then
        echo 'worktree_remove: fixture=jq-still-available' >&2
        exit 1
      fi
      ;;
    live-process | remote-host | invalid-pid)
      local lease_file lease before old replacement
      lease_file="$(git -C "$WT" rev-parse --absolute-git-dir)/locked"
      before="$(cat -- "$lease_file")"
      case "$1" in
        live-process)
          # Hold a PID for the recorded writer check. This fixture does not
          # establish harness liveness or use a reaped child's PID.
          mkfifo "$ROOT/session.pipe"
          "$BASH" -c 'read -r token < "$1"' session "$ROOT/session.pipe" &
          LIVE_PID=$!
          old="$("$WORKTREE_PACKAGE_DIR/scripts/worktree-session-guard" status "$WT" | jq -r .pid)"
          replacement="pid=$LIVE_PID"
          old="pid=$old"
          ;;
        remote-host)
          old="$("$WORKTREE_PACKAGE_DIR/scripts/worktree-session-guard" status "$WT" | jq -r .host)"
          replacement="host=$old.remote"
          old="host=$old"
          ;;
        invalid-pid)
          old="$("$WORKTREE_PACKAGE_DIR/scripts/worktree-session-guard" status "$WT" | jq -r .pid)"
          replacement='pid=unknown'
          old="pid=$old"
          ;;
      esac
      lease="${before/" $old "/" $replacement "}"
      [[ "$lease" != "$before" ]] || { echo 'worktree_remove: fixture=unchanged-lease' >&2; exit 1; }
      printf '%s\n' "$lease" >"$lease_file"
      ;;
    absent-process | unread-process | noisy-process)
      # ps is the real producer of absent/error states. Inject its result
      # instead of querying liveness against a reaped predecessor's PID.
      mkdir -p "$ROOT/bin"
      local ps_rc=1 ps_output=''
      [[ "$1" != unread-process ]] || ps_rc=2
      [[ "$1" != noisy-process ]] || ps_output='process table unavailable'
      printf '#!/usr/bin/env bash\nprintf "%%s" %q\nexit %s\n' "$ps_output" "$ps_rc" >"$ROOT/bin/ps"
      chmod +x "$ROOT/bin/ps"
      ROW_PATH="$ROOT/bin:$ROW_PATH"
      ;;
    lock-record)
      LOCK_FILE="$(git -C "$WT" rev-parse --absolute-git-dir)/locked"
      cp "$LOCK_FILE" "$ROOT/lock-copy"
      ;;
    unlock) git -C "$MAIN" worktree unlock "$WT" ;;
    # A lane's own mailbox in the worktree, as orch's lane-marker places it,
    # with the liveness record its standing monitor writes.
    mail)
      MAIL_ITEM=KEN-1
      mkdir -p "$WT/tmp/lane-mail/KEN-1"
      printf '{"id":"wt-1"}\n{"id":"wt-2"}\n' >"$WT/tmp/lane-mail/KEN-1/to-overseer.jsonl"
      printf 'live\n' >"$WT/tmp/lane-mail/KEN-1/to-lane.watch"
      ;;
    # The main checkout already holds a mailbox for the item: a relaunch after
    # an earlier removal, or a send that fell back there.
    main-mail)
      mkdir -p "$MAIN/tmp/lane-mail/KEN-1"
      printf '{"id":"main-1"}\n' >"$MAIN/tmp/lane-mail/KEN-1/to-overseer.jsonl"
      ;;
    # The lane asked, the overseer answered on to-lane.jsonl and sent a
    # directive, and the lane read both.
    answered)
      MAIL_REPLIES=1
      printf '{"id":"wt-3","kind":"ask","text":"Which?"}\n' >>"$WT/tmp/lane-mail/KEN-1/to-overseer.jsonl"
      printf '{"id":"re-3","kind":"answer","re":"wt-3","text":"This."}\n{"id":"dir-1","kind":"directive","text":"Stop."}\n' \
        >"$WT/tmp/lane-mail/KEN-1/to-lane.jsonl"
      printf '2\n' >"$WT/tmp/lane-mail/KEN-1/to-lane.cursor"
      ;;
    # The main checkout's mailbox holds a directive nobody read.
    main-unread)
      printf '{"id":"main-dir","kind":"directive","text":"Wait."}\n' >"$MAIN/tmp/lane-mail/KEN-1/to-lane.jsonl"
      ;;
    # The worktree's tmp links to the main checkout's, so its mailbox is
    # already the one the watch reads.
    shared-tmp)
      mkdir -p "$MAIN/tmp"
      ln -s "$MAIN/tmp" "$WT/tmp"
      ;;
    # git itself refuses the removal after every precheck passed: the lock
    # precheck is a racy diagnostic, and only "nothing is stripped before git
    # runs" keeps the links whole here, so this row and the locked one are
    # two mechanisms, not one.
    git-refuses | git-refuses-unread)
      mkdir -p "$ROOT/bin"
      cat >"$ROOT/bin/git" <<'STUB'
#!/usr/bin/env bash
if [[ " $* " == *" worktree remove --force "* ]]; then
  [[ ! -f "$0.unread" ]] || : >"$0.failed"
  echo "simulated worktree removal failure" >&2
  exit 1
fi
if [[ -f "$0.failed" && " $* " == *" worktree list --porcelain "* ]]; then
  echo "simulated registration read failure" >&2
  exit 1
fi
exec "$REAL_GIT_BIN" "$@"
STUB
      [[ "$1" != git-refuses-unread ]] || : >"$ROOT/bin/git.unread"
      chmod +x "$ROOT/bin/git"
      ROW_PATH="$ROOT/bin:$ROW_PATH"
      ;;
    # Git's non-atomic removal can discard its private registration while a
    # filesystem failure leaves files. Readdir order decides whether .git is
    # among the files kept. Only fixture-owned paths go.
    git-partial | git-partial-kept-git)
      mkdir -p "$ROOT/bin"
      cat >"$ROOT/bin/git" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ " $* " == *" worktree remove --force "* ]]; then
  target="${!#}"
  registration="$("$REAL_GIT_BIN" -C "$target" rev-parse --absolute-git-dir)"
  [[ -f "$0.kept-git" ]] || rm -f -- "${target:?}/.git"
  rm -rf -- "${registration:?}"
  echo "simulated directory deletion failure after registration removal" >&2
  exit 1
fi
exec "$REAL_GIT_BIN" "$@"
STUB
      [[ "$1" != git-partial-kept-git ]] || : >"$ROOT/bin/git.kept-git"
      chmod +x "$ROOT/bin/git"
      ROW_PATH="$ROOT/bin:$ROW_PATH"
      ROW_ENV+=("WORKTREE_BASE_DIR=$ROOT/trees")
      ;;
    after-partial-remove) FIRST_REMOVE_STATE="$(run_remove TOPIC)" ;;
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
  ROW_ENV=(-u KENDEX_SESSION_OWNER -u HT_SESSION_OWNER USER=returning-session)
  MAP_FILE=""
  SIBLING_GIT_DIR=""
  LOCK_FILE=""
  MAIL_ITEM=""
  MAIL_REPLIES=""
  FIRST_REMOVE_STATE=""
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
  if [[ -n "$MAIL_ITEM" ]]; then
    local staged
    staged="$(find "$MAIN/tmp/lane-mail" -mindepth 1 -maxdepth 1 -name ".$MAIL_ITEM.*" 2>/dev/null | wc -l | tr -d ' ')"
    printf ' mail=main:%s wt:%s staged=%s' "$(mail_box "$MAIN")" "$(mail_box "$WT")" "${staged:-0}"
  fi
  [[ -z "$MAIL_REPLIES" ]] || printf ' %s' "$(mail_replies)"
}

# The main checkout's mailbox as its to-lane.jsonl ids and to-lane.cursor, and
# what lane-mail's pending, the overseer's list of what it owes, lists there.
mail_replies() {
  local box="$MAIN/tmp/lane-mail/$MAIL_ITEM" ids cursor=- pending
  ids="$(jq -r '.id' "$box/to-lane.jsonl" 2>/dev/null | paste -s -d ',' -)"
  [[ ! -f "$box/to-lane.cursor" ]] || cursor="$(head -n 1 "$box/to-lane.cursor")"
  pending="$("$LANE_MAIL" pending --item "$MAIL_ITEM" --root "$MAIN" | jq -r '.id' | paste -s -d ',' -)" ||
    pending=failed
  printf 'lane=%s@%s pending=%s' "${ids:--}" "$cursor" "${pending:--}"
}

# A mailbox as the ids its to-overseer.jsonl holds, in order, and +watch where
# its liveness record stands.
mail_box() { # ROOT
  local box="$1/tmp/lane-mail/$MAIL_ITEM" ids
  [[ -d "$box" ]] || { printf 'absent'; return 0; }
  ids="$(jq -r '.id' "$box/to-overseer.jsonl" 2>/dev/null | paste -s -d ',' -)"
  printf '%s' "${ids:--}"
  [[ ! -e "$box/to-lane.watch" ]] || printf '+watch'
}

LANE_MAIL="$WORKTREE_PACKAGE_DIR/../mailbox/scripts/lane-mail"
REAL_GIT_BIN="$(command -v git)"
MAP_FILE=""

run_remove() {
  local -a argv
  local rc=0
  local i
  read -r -a argv <<<"$1"
  for i in "${!argv[@]}"; do
    [[ "${argv[i]}" == @alias ]] && argv[i]="$ROOT/alias"
    [[ "${argv[i]}" == @path ]] && argv[i]="$WT"
  done
  (cd "$MAIN" && env "${ROW_ENV[@]}" PATH="$ROW_PATH" REAL_GIT_BIN="$REAL_GIT_BIN" \
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
  printf '%s' 'worktree-remove-failed: <wt>;worktree-remove-recovery: repository=<main> path=<wt> branch=topic registration=present directory=remaining recovery=manual'
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
    live-process) printf 'worktree-guard-process-live: path=<wt> pid=%s;worktree-lease-release-failed: <wt>' "$LIVE_PID" ;;
    unverified-process)
      local info
      info="$("$WORKTREE_PACKAGE_DIR/scripts/worktree-session-guard" status "$WT" | jq -r '"pid=\(.pid) host=\(.host)"')"
      printf 'worktree-guard-process-unverified: path=<wt> %s;worktree-lease-release-failed: <wt>' "$info"
      ;;
    unknown-option) printf '%s' "worktree-remove-option-unknown: --bogus" ;;
    unmerged) unmerged_block ;;
    locked) locked_block ;;
    refused) refused_block ;;
    refused-alias) printf '%s' 'worktree-remove-failed: <alias>;worktree-remove-recovery: repository=<main> path=<wt> branch=topic registration=present directory=remaining recovery=manual' ;;
    unread) printf '%s' 'worktree-remove-failed: <wt>;worktree-remove-registration-unread: operation=worktree-list status=1 cause=simulated registration read failure;worktree-remove-recovery: repository=<main> path=<wt> branch=topic registration=unread directory=remaining recovery=manual' ;;
    held-map) map_block ;;
    unidentified) printf '%s' 'worktree-remove-unidentified: <alias>;worktree-remove-recovery: repository=<main> path=<alias> branch=unknown registration=unresolved recovery=manual' ;;
    partial) printf '%s' 'worktree-lease-released: path=<wt> owner=TOPIC;worktree-remove-failed: <wt>;worktree-remove-recovery: repository=<main> path=<wt> branch=topic registration=missing directory=remaining recovery=manual' ;;
    leftover) printf '%s' 'worktree-remove-unidentified: <wt>;worktree-remove-recovery: repository=<main> path=<wt> branch=unknown registration=unresolved recovery=manual' ;;
    leftover-alias) printf '%s' 'worktree-remove-unidentified: <alias>;worktree-remove-recovery: repository=<main> path=<wt> branch=unknown registration=unresolved recovery=manual' ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}

LINKS='.env.local-><main>/.env.local,.agents-><main>/.agents,.claude/agents-><main>/.claude/agents,.claude/POINTER.md->../AGENTS.md'

check_remove_row() {
  local label="$1" args="$2" rc="$3" out="$4" err="$5" want_state="$6"
  if [[ -n "$FIRST_REMOVE_STATE" ]]; then
    assert_eq "$FIRST_REMOVE_STATE" "rc=1 out= err=$(remove_err partial) worktree=unregistered/no branch=present dirs=topic links=$LINKS mail=main:absent wt:wt-1,wt-2+watch staged=0" "$label: first removal retains identity and leftovers"
  fi
  assert_eq "$(run_remove "$args")" "rc=$rc out=$(remove_out "$out") err=$(remove_err "$err") $want_state" "$label"
}

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
a removal git refuses through a symlink records the physical worktree|tree links alias git-refuses|@alias|1|-|refused-alias|worktree=registered/yes branch=present dirs=topic links=LINKS
a failed registration read after Git refuses keeps the state unverified|tree links git-refuses-unread|TOPIC|1|-|unread|worktree=registered/yes branch=present dirs=topic links=LINKS
a retry after Git deletes registration preserves unidentified leftovers|tree links own-lease mail git-partial after-partial-remove|TOPIC|1|-|leftover|worktree=unregistered/no branch=present dirs=topic links=LINKS mail=main:absent wt:wt-1,wt-2+watch staged=0
a retry after Git deletes registration but keeps .git preserves unidentified leftovers|tree links own-lease mail git-partial-kept-git after-partial-remove|TOPIC|1|-|leftover|worktree=unregistered/no branch=present dirs=topic links=LINKS mail=main:absent wt:wt-1,wt-2+watch staged=0
the same retry through a symlink records the physical leftover|tree links own-lease mail git-partial-kept-git after-partial-remove alias|@alias|1|-|leftover-alias|worktree=unregistered/no branch=present dirs=topic links=LINKS mail=main:absent wt:wt-1,wt-2+watch staged=0
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
a returning session removes its adopted item by path without the old environment or jq|tree adopted-lease item-record absent-process no-jq|@path|0|removed|released+deleted|worktree=absent/no branch=absent dirs=- links=-
a live recorded writer PID refuses removal by issue ID without jq|tree adopted-lease item-record live-process lock-record no-jq|TOPIC|1|-|live-process|worktree=registered/yes branch=present dirs=topic links=- lock=intact
a live recorded writer PID refuses removal by path without jq|tree adopted-lease item-record live-process lock-record no-jq|@path|1|-|live-process|worktree=registered/yes branch=present dirs=topic links=- lock=intact
a foreign lease refuses item-record path removal without jq|tree foreign-lease item-record absent-process lock-record no-jq|@path|1|-|locked|worktree=registered/yes branch=present dirs=topic links=- lock=intact
a remote-host item lease stays locked|tree adopted-lease item-record remote-host absent-process lock-record|@path|1|-|unverified-process|worktree=registered/yes branch=present dirs=topic links=- lock=intact
an unreadable process table keeps the item lease|tree adopted-lease item-record unread-process lock-record|@path|1|-|unverified-process|worktree=registered/yes branch=present dirs=topic links=- lock=intact
a process lookup error with the absent exit code keeps the item lease|tree adopted-lease item-record noisy-process lock-record|@path|1|-|unverified-process|worktree=registered/yes branch=present dirs=topic links=- lock=intact
an invalid recorded PID keeps the item lease|tree adopted-lease item-record invalid-pid absent-process lock-record|@path|1|-|unverified-process|worktree=registered/yes branch=present dirs=topic links=- lock=intact
the lane mailbox moves to the main checkout, its stale monitor record dropped|tree mail|TOPIC|0|removed|deleted|worktree=absent/no branch=absent dirs=- links=- mail=main:wt-1,wt-2 wt:absent staged=0
a removal git refuses puts the lane mailbox back in the worktree whole|tree mail git-refuses|TOPIC|1|-|refused|worktree=registered/yes branch=present dirs=topic links=- mail=main:absent wt:wt-1,wt-2+watch staged=0
a lane mailbox meeting one in the main checkout adds its lines after the lines there|tree mail main-mail|TOPIC|0|removed|deleted|worktree=absent/no branch=absent dirs=- links=- mail=main:main-1,wt-1,wt-2 wt:absent staged=0
the same meeting refused by git leaves both mailboxes as they were|tree mail main-mail git-refuses|TOPIC|1|-|refused|worktree=registered/yes branch=present dirs=topic links=- mail=main:main-1 wt:wt-1,wt-2+watch staged=0
the moved lane mailbox keeps its answered ask answered|tree mail answered|TOPIC|0|removed|deleted|worktree=absent/no branch=absent dirs=- links=- mail=main:wt-1,wt-2,wt-3 wt:absent staged=0 lane=re-3,dir-1@2 pending=-
a lane mailbox meeting one in the main checkout carries the answer to its ask but not its directive|tree mail answered main-mail|TOPIC|0|removed|deleted|worktree=absent/no branch=absent dirs=- links=- mail=main:main-1,wt-1,wt-2,wt-3 wt:absent staged=0 lane=re-3@1 pending=-
a carried answer leaves unread a line the main checkout mailbox had not read|tree mail answered main-mail main-unread|TOPIC|0|removed|deleted|worktree=absent/no branch=absent dirs=- links=- mail=main:main-1,wt-1,wt-2,wt-3 wt:absent staged=0 lane=main-dir,re-3@- pending=main-dir
a worktree tmp linked to the tmp of the main checkout leaves its mailbox where it is|tree shared-tmp mail|TOPIC|0|removed|deleted|worktree=absent/no branch=absent dirs=- links=- mail=main:wt-1,wt-2+watch wt:absent staged=0
'

ADOPTED_OWNER_ROWS='
an adopted item removes by ID with KENDEX_SESSION_OWNER set and no jq|tree adopted-lease item-record absent-process kendex-session-owner no-jq|TOPIC|0|removed|released+deleted|worktree=absent/no branch=absent dirs=- links=-
an adopted item removes by path with KENDEX_SESSION_OWNER set and no jq|tree adopted-lease item-record absent-process kendex-session-owner no-jq|@path|0|removed|released+deleted|worktree=absent/no branch=absent dirs=- links=-
an adopted item removes by ID with HT_SESSION_OWNER set and no jq|tree adopted-lease item-record absent-process ht-session-owner no-jq|TOPIC|0|removed|released+deleted|worktree=absent/no branch=absent dirs=- links=-
an adopted item removes by path with HT_SESSION_OWNER set and no jq|tree adopted-lease item-record absent-process ht-session-owner no-jq|@path|0|removed|released+deleted|worktree=absent/no branch=absent dirs=- links=-
a foreign lease stays held with KENDEX_SESSION_OWNER set and no jq|tree foreign-lease item-record absent-process kendex-session-owner lock-record no-jq|@path|1|-|locked|worktree=registered/yes branch=present dirs=topic links=- lock=intact
a foreign lease stays held with HT_SESSION_OWNER set and no jq|tree foreign-lease item-record absent-process ht-session-owner lock-record no-jq|@path|1|-|locked|worktree=registered/yes branch=present dirs=topic links=- lock=intact
'

check_remove_rows() {
  local rows="$1" prefix="$2" n=0 label fixture args rc out err want_state
  while IFS='|' read -r label fixture args rc out err want_state; do
    [[ -n "$label$fixture$args$rc$out$err$want_state" ]] || continue
    n=$((n + 1))
    # shellcheck disable=SC2086
    build "$prefix-$n" $fixture
    want_state="${want_state//LINKS/$LINKS}"
    check_remove_row "$label" "$args" "$rc" "$out" "$err" "$want_state"
    finish_session
  done <<<"$rows"
}

echo "=== worktree remove ==="
check_remove_rows "$REMOVE_ROWS
$ADOPTED_OWNER_ROWS" remove

# Recovery records are observed through message_records, which keeps keyed
# command data and discards human prose. Losing the known branch must fail.
RECOVERY_CONTROL="$TMP_ROOT/recovery-control"
cp -R "$WORKTREE_PACKAGE_DIR/scripts" "$RECOVERY_CONTROL"
RECOVERY_BRANCH='branch=${BRANCH:-unknown} registration=$REMOVE_REGISTRATION_STATE'
[[ "$(grep -cF -- "$RECOVERY_BRANCH" "$RECOVERY_CONTROL/worktree")" == 1 ]] || { echo 'worktree_remove: control=recovery-target-count' >&2; exit 1; }
CONTROL_TEXT="$(cat -- "$RECOVERY_CONTROL/worktree")"
printf '%s\n' "${CONTROL_TEXT/"$RECOVERY_BRANCH"/'branch=unknown registration=$REMOVE_REGISTRATION_STATE'}" >"$RECOVERY_CONTROL/worktree"
! cmp -s "$WORKTREE_PACKAGE_DIR/scripts/worktree" "$RECOVERY_CONTROL/worktree" || { echo 'worktree_remove: control=recovery-unchanged' >&2; exit 1; }
PARTIAL_ROWS="$(awk -F '|' '$2 ~ /after-partial-remove/ { print }' <<<"$REMOVE_ROWS")"
[[ -n "$PARTIAL_ROWS" ]] || { echo 'worktree_remove: control=recovery-row-missing' >&2; exit 1; }
control_log="$(PASS=0 FAIL=0 WORKTREE_SCRIPT="$RECOVERY_CONTROL/worktree"; check_remove_rows "$PARTIAL_ROWS" recovery-control)"
expected_failures="$(awk -F '|' '{ print $1 ": first removal retains identity and leftovers" }' <<<"$PARTIAL_ROWS" | paste -s -d ';' -)"
assert_eq "$(sed -n 's/^  FAIL  //p' <<<"$control_log" | paste -s -d ';' -)" "$expected_failures" \
  'control: losing the known branch fails the partial-removal identity assertion'

# Control: a remove that leaves the mailbox to git's deletion. The mailbox
# state above must tell it apart, or no row there proves the move.
MUTANT_DIR="$TMP_ROOT/mutant-scripts"
cp -R "$WORKTREE_PACKAGE_DIR/scripts" "$MUTANT_DIR"
MOVE_CALL='if ! lane_mail_move_out "$1"; then'
[[ "$(grep -cF -- "$MOVE_CALL" "$MUTANT_DIR/worktree")" == 1 ]] || { echo "worktree_remove: control=target-count" >&2; exit 1; }
MUTANT_TEXT="$(<"$MUTANT_DIR/worktree")"
printf '%s\n' "${MUTANT_TEXT/"$MOVE_CALL"/if false; then}" >"$MUTANT_DIR/worktree"
! cmp -s "$WORKTREE_PACKAGE_DIR/scripts/worktree" "$MUTANT_DIR/worktree" || { echo "worktree_remove: control=unchanged" >&2; exit 1; }
build remove-control tree mail
assert_eq "$(WORKTREE_SCRIPT="$MUTANT_DIR/worktree" run_remove TOPIC)" \
  "rc=0 out=$(remove_out removed) err=$(remove_err deleted) worktree=absent/no branch=absent dirs=- links=- mail=main:absent wt:absent staged=0" \
  "control: a remove that does not move the lane mailbox deletes it with the worktree"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
