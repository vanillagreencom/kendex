#!/usr/bin/env bash
# `worktree create --reuse/--restack --replay`, the policy-blocked twin of the
# rebase engine: ordered plain cherry-picks that must leave the same rebased
# history, pause into the same guarded state with the same controls, and
# record the same pinned push authorization. One table, a row per scenario,
# on the same step vocabulary and renderer as worktree_create_restack.sh.
# Every row's command runs behind a PATH shim that fails any git invocation
# carrying a `rebase` argument, so rebase porcelain anywhere under the tool
# reds the row: passing execution policies that reject `git rebase` is the
# point of the engine.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}:${2:-}" in
  pr:list) ;;
esac
STUB
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

# The real git, resolved before the shim goes ahead of it.
REAL_GIT="$(command -v git)"
mkdir -p "$TMP_ROOT/norebase"
cat >"$TMP_ROOT/norebase/git" <<STUB
#!/usr/bin/env bash
for arg in "\$@"; do
  if [[ "\$arg" == rebase ]]; then
    echo "rebase porcelain invoked under --replay: git \$*" >&2
    exit 97
  fi
done
exec "$REAL_GIT" "\$@"
STUB
chmod +x "$TMP_ROOT/norebase/git"
NOREBASE_PATH="$TMP_ROOT/norebase:$PATH"

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

# --- fixtures -----------------------------------------------------------------
# Every row's world lives under its own ROOT: the main checkout at ROOT/main,
# the bare origin at ROOT/origin.git, the issue worktree at ROOT/trees/topic.

ISSUE=topic
ROOT=""
MAIN=""
WT=""
PRE=""        # the branch tip the world was built with, before any tool step
BASE=""       # origin/main at the end of the fixture
END=""        # HEAD at the end of the fixture
EXTERNAL=""   # a commit an outsider pushed to the remote branch

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  git -C "$repo" config commit.gpgsign false
  printf 'orig\n' >"$repo/file.txt"
  printf 'orig\n' >"$repo/other.txt"
  git -C "$repo" add file.txt other.txt
  git -C "$repo" commit -q -m base
  printf 'WORKTREE_BASE_DIR="../trees"\n' >"$repo/.env.local"
}

# A main+origin pair whose issue worktree was created through the script.
make_pair() {
  make_repo "$MAIN"
  git init -q --bare "$ROOT/origin.git"
  git -C "$MAIN" remote add origin "$ROOT/origin.git"
  git -C "$MAIN" push -q -u origin main
  (cd "$MAIN" && "$WORKTREE_SCRIPT" create "$ISSUE" >/dev/null 2>&1)
}

commit_main() {
  local file="$1" content="$2"
  printf '%s\n' "$content" >"$MAIN/$file"
  git -C "$MAIN" add "$file"
  git -C "$MAIN" commit -q -m "main: $file"
  git -C "$MAIN" push -q origin main
}

commit_wt() {
  local file="$1" content="$2"
  printf '%s\n' "$content" >"$WT/$file"
  git -C "$WT" add "$file"
  git -C "$WT" commit -q -m "wt: $file"
}

# A tool step of the fixture runs behind the same shim as the row's command.
tool() {
  (cd "$MAIN" && PATH="$NOREBASE_PATH" "$WORKTREE_SCRIPT" "$@" >/dev/null 2>&1) || true
}

remote_oid() {
  git --git-dir="$ROOT/origin.git" rev-parse -q --verify "refs/heads/$ISSUE" 2>/dev/null || true
}

# An outsider's commit on top of the remote branch: the tree it already has,
# a parent the local branch never saw as a tip.
external_commit() {
  local old="" tree=""
  old="$(remote_oid)"
  tree="$(git --git-dir="$ROOT/origin.git" rev-parse "${old}^{tree}")"
  GIT_AUTHOR_NAME=External GIT_AUTHOR_EMAIL=external@example.com \
    GIT_COMMITTER_NAME=External GIT_COMMITTER_EMAIL=external@example.com \
    git --git-dir="$ROOT/origin.git" commit-tree "$tree" -p "$old" -m 'external movement'
}

# The paused engine's state directory: the cherry-pick sequencer for a replay,
# the rebase directories for the engine this suite must never reach.
paused_state_dir() {
  local state path
  for state in sequencer rebase-merge rebase-apply; do
    path="$(git -C "$WT" rev-parse --git-path "$state" 2>/dev/null)" || continue
    [[ "$path" == /* ]] || path="$WT/$path"
    if [[ -d "$path" ]]; then
      printf '%s\n' "$path"
      return 0
    fi
  done
  return 1
}

# The step vocabulary. The first word of a fixture builds the world; the
# rest drive it.
step() {
  case "$1" in
    # The issue worktree and origin/main edit the same line of file.txt, so
    # a replay genuinely conflicts.
    conflict)
      make_pair
      commit_wt file.txt feature
      commit_main file.txt main-side
      ;;
    # The issue branch is published and main advanced on a file it never
    # touched: a replay is clean.
    clean)
      make_pair
      commit_wt feature.txt feature
      git -C "$WT" push -q origin "HEAD:refs/heads/$ISSUE"
      commit_main main-advanced.txt advanced
      ;;
    # The first issue commit is already represented on main with a further
    # edit; a refresh-only commit follows it. A skip drops the represented
    # commit whatever the index holds, so no row resolves it first.
    merged)
      make_pair
      commit_wt file.txt 'already merged'
      commit_wt refresh-only.txt 'refresh only'
      git -C "$WT" push -q origin "HEAD:refs/heads/$ISSUE"
      commit_main file.txt 'already merged plus main follow-up'
      ;;
    # An unpublished branch with one commit behind an advanced main.
    plain)
      make_pair
      commit_wt fix.txt fix
      commit_main main-advanced.txt advanced
      ;;
    publish) git -C "$WT" push -q origin "HEAD:refs/heads/$ISSUE" ;;
    replay) tool create "$ISSUE" --reuse --replay ;;
    restack-replay) tool create "$ISSUE" --restack --replay ;;
    continue) tool restack continue "$ISSUE" ;;
    push) tool push "$ISSUE" ;;
    resolve)
      printf 'resolved\n' >"$WT/file.txt"
      git -C "$WT" add file.txt
      ;;
    dirty) printf 'uncommitted\n' >>"$WT/file.txt" ;;
    # A merge commit in the range: history an ordered cherry-pick cannot represent.
    merge)
      git -C "$WT" checkout -q -b side
      commit_wt side.txt side
      git -C "$WT" checkout -q "$ISSUE"
      git -C "$WT" merge -q --no-ff --no-edit side
      git -C "$WT" branch -q -D side
      ;;
    second) commit_wt second.txt second ;;
    raw-checkout) git -C "$WT" checkout -f "$ISSUE" >/dev/null 2>&1 ;;
    raw-quit) git -C "$WT" cherry-pick --quit ;;
    raw-abort) git -C "$WT" cherry-pick --abort ;;
    move-remote)
      EXTERNAL="$(external_commit)"
      git --git-dir="$ROOT/origin.git" update-ref "refs/heads/$ISSUE" "$EXTERNAL"
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
  WT="$ROOT/trees/$ISSUE"
  PRE="" BASE="" END="" EXTERNAL=""
  for word in "$@"; do
    step "$word"
    [[ -n "$PRE" ]] || PRE="$(git -C "$WT" rev-parse HEAD)"
  done
  BASE="$(git -C "$MAIN" rev-parse origin/main)"
  END="$(git -C "$WT" rev-parse HEAD)"
}

# --- rendering ------------------------------------------------------------------

oid_name() {
  local oid="$1"
  if [[ -z "$oid" ]]; then printf -- '-'
  elif [[ "$oid" == "$PRE" ]]; then printf 'pre'
  elif [[ "$oid" == "$BASE" ]]; then printf 'base'
  elif [[ -n "$EXTERNAL" && "$oid" == "$EXTERNAL" ]]; then printf 'external'
  elif [[ "$oid" == "$END" ]]; then printf 'end'
  elif [[ "$oid" == "$(git -C "$WT" rev-parse HEAD)" ]]; then printf 'head'
  else printf '%s' "$oid"
  fi
}

# Paths and commits by their names. Git's own push report is not the tool's
# clause and is dropped. The lines the tool relays from git under its "git:"
# prefix collapse to one marker, their wording being git's, except a line
# naming the conflicting path: that the relay names the path is the tool's
# own contract. A literal semicolon is escaped before the lines are joined
# on it.
alias_text() {
  sed \
    -e "s|$WT|<wt>|g" \
    -e "s|$ROOT|<root>|g" \
    -e "s|$WORKTREE_SCRIPT|<worktree>|g" \
    -e "s|$PRE|<pre>|g" \
    -e "s|$BASE|<base>|g" \
    -e "s|${EXTERNAL:-NONE}|<external>|g" \
    -e '/^To <root>\/origin\.git$/d' \
    -e '/^error: failed to push/d' \
    -e '/^hint: /d' \
    -e "/^branch '.*' set up to track/d" \
    -e '/^ [!*+] /d' \
    -e '/^   [0-9a-f][0-9a-f]*\.\.[0-9a-f][0-9a-f]* /d' \
    -e 's|^  git: .*file\.txt.*|  git:<file.txt>|' \
    -e 's/^  git: .*/  git:.../' \
    -e 's/;/\\;/g' |
    awk 'BEGIN { prev = "" } { if ($0 ~ /^  git:/ && prev == $0) next; prev = $0; print }' |
    paste -s -d ';' -
}

worktree_head() {
  local head
  head="$(git -C "$WT" rev-parse HEAD)"
  if [[ "$head" == "$PRE" ]]; then printf 'pre'
  elif [[ "$head" == "$BASE" ]]; then printf 'base'
  elif [[ "$head" == "$END" ]]; then printf 'end'
  elif git -C "$WT" merge-base --is-ancestor "$BASE" "$head"; then printf 'rebased'
  else printf 'other'
  fi
}

restack_keys() {
  local marker="" key value out=""
  marker="$(head -n 1 "$(paused_state_dir)/kendex-restack-token" 2>/dev/null || true)"
  while IFS=' ' read -r key value; do
    [[ -n "$key" ]] || continue
    key="${key#kendex-restack.}"
    case "$key" in
      expectedremoteoid) key=expected; value="$(oid_name "$value")" ;;
      originalhead) key=orig; value="$(oid_name "$value")" ;;
      baseoid) key=base; value="$(oid_name "$value")" ;;
      authorizedhead) key=authorized; value="$(oid_name "$value")" ;;
      statetoken)
        key=token
        if [[ -n "$marker" && "$marker" == "$value" ]]; then value=bound; else value=unbound; fi
        ;;
    esac
    out="$out,$key:$value"
  done <<<"$(git -C "$WT" config --worktree --get-regexp '^kendex-restack\.' 2>/dev/null || true)"
  printf '%s' "${out:-,-}" | cut -c2-
}

# engine is the paused state directory's owner: replay for the cherry-pick
# sequencer, rebase for the rebase engine, none when nothing is paused.
state() {
  local engine=none branch ref ahead dirty tree paused
  if paused="$(paused_state_dir)"; then
    case "$paused" in
      */sequencer) engine=replay ;;
      *) engine=rebase ;;
    esac
  fi
  branch="$(git -C "$WT" branch --show-current)"
  ahead="$(git -C "$WT" rev-list --count "$BASE..HEAD" 2>/dev/null || true)"
  dirty="$(git -C "$WT" status --porcelain | paste -s -d ',' -)"
  tree="$(git -C "$WT" ls-tree -r --name-only HEAD | while read -r name; do
    body="$(git -C "$WT" cat-file -p "HEAD:$name")"
    printf '%s:%s,' "$name" "${body%%$'\n'*}"
  done)"
  ref="$(git -C "$WT" rev-parse -q --verify "refs/heads/$ISSUE" 2>/dev/null || true)"
  printf 'engine=%s branch=%s head=%s ref=%s ahead=%s dirty=%s tree=%s restack=%s remote=%s' \
    "$engine" "${branch:-detached}" "$(worktree_head)" "$(oid_name "$ref")" "${ahead:--}" \
    "${dirty:--}" "${tree%,}" "$(restack_keys)" "$(oid_name "$(remote_oid)")"
}

# The command runs from the main checkout behind the no-rebase shim.
run() {
  local -a argv
  local rc=0
  read -r -a argv <<<"$1"
  (cd "$MAIN" && PATH="$NOREBASE_PATH" "$WORKTREE_SCRIPT" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  printf 'rc=%s out=%s err=%s %s' "$rc" \
    "$(alias_text <"$ROOT/out")" "$(alias_text <"$ROOT/err")" "$(state)"
}

# --- the expected text ----------------------------------------------------------
# Each spec word expands to the tool's whole message for that terminal path.

restore_lines() {
  printf '%s' "To restore the pre-restack branch: <worktree> restack abort \"<wt>\";Recorded branch: topic"
}

err_text() {
  local spec="$1"
  case "$spec" in
    *+*) printf '%s;%s' "$(err_text "${spec%%+*}")" "$(err_text "${spec#*+}")" ;;
    -) printf '' ;;
    skip-rebase) printf '%s' "→ origin/main already contained in topic\; skipping rebase" ;;
    dirty) printf '%s' "Error: <wt> has uncommitted changes\; refusing to replay over them.;Commit or discard them, then retry." ;;
    merges) printf '%s' "Error: The replay range origin/main..topic in <wt> contains merge commits, which an ordered cherry-pick replay cannot represent.;Use the rebase engine (<worktree> create topic --reuse) or reconcile the merge manually." ;;
    aborted) printf '%s' "Error: Cherry-pick replay onto origin/main failed for <wt> (conflicts).;Conflicting files:;  file.txt;The replay was aborted\; the worktree is back on its pre-replay state with no conflicts left to resolve.;Recovery options:;  1. Redo the replay and stop in the conflict state to resolve it:;       <worktree> create topic --restack --replay;  2. Discard local divergence and recreate fresh from origin/main:;       <worktree> remove topic && <worktree> create topic" ;;
    paused) printf '%s' "Error: Cherry-pick replay onto origin/main stopped on conflicts in <wt>.;Conflicting files:;  file.txt;The replay is paused in the worktree so the conflicts can be resolved:;  1. Edit each conflicting file to remove the conflict markers.;  2. git -C \"<wt>\" add <file>    (each resolved file);  3. <worktree> restack continue \"<wt>\"    (repeat if it stops again);     If the resolved commit is empty: <worktree> restack skip \"<wt>\";To back out instead: <worktree> restack abort \"<wt>\"" ;;
    refusal:*) printf '%s' "Error: Restack state for <wt> is ${spec#refusal:}\; refusing to run a rebase control command.;Only an exact paused state created by 'worktree create <ID> --restack' can be continued, skipped, or aborted." ;;
    unreattachable) printf '%s' "  git:...;  git:<file.txt>;Error: Could not reattach <wt> to 'topic'\; the recorded restack state was preserved.;A 'rebase --quit' or 'cherry-pick --quit' leaves the conflicted index in place: stage or discard the paths Git names above.;Then re-run: <worktree> restack abort \"<wt>\"" ;;
    remote-moved) printf '%s' "Error: Remote 'origin/topic' changed while the supported restack was paused\; refusing to continue or skip.;Abort the guarded restack before reconciling the moved remote." ;;
    lease-rejected) printf '%s' "Error: Push rejected. Remote 'origin/topic' may have changed since the force-with-lease expectation\; fetch and rebase/merge before retrying." ;;
    bare-flag) printf '%s' "Error: --replay selects the restack engine for --reuse/--restack\; combine it with one of them." ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$spec" ;;
  esac
}

out_text() {
  case "$1" in
    -) printf '' ;;
    wt) printf '<wt>' ;;
    completed) printf 'Completed guarded restack for topic: <wt>' ;;
    aborted) printf 'Aborted guarded restack and restored topic: <wt>' ;;
    cleared) printf 'No restack was paused\; cleared the recorded restack state for topic: <wt>' ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

# --- the rows ---------------------------------------------------------------------
# label|fixture|command|rc|out|err|state
ROWS='a clean replay rewrites the branch onto the moved base and authorizes its exact head|clean|create topic --reuse --replay|0|wt|-|engine=none branch=topic head=rebased ref=head ahead=1 dirty=- tree=feature.txt:feature,file.txt:orig,main-advanced.txt:advanced,other.txt:orig restack=remote:origin,branch:topic,expected:pre,authorized:head remote=pre
push after a clean replay publishes the head with the original lease|clean replay|push topic|0|-|skip-rebase|engine=none branch=topic head=end ref=end ahead=1 dirty=- tree=feature.txt:feature,file.txt:orig,main-advanced.txt:advanced,other.txt:orig restack=- remote=end
a dirty tree is refused before any mutation|clean dirty|create topic --reuse --replay|1|-|dirty|engine=none branch=topic head=pre ref=pre ahead=1 dirty= M file.txt tree=feature.txt:feature,file.txt:orig,other.txt:orig restack=- remote=pre
a merge commit in the range is refused and routed to the rebase engine|clean merge|create topic --reuse --replay|1|-|merges|engine=none branch=topic head=end ref=end ahead=3 dirty=- tree=feature.txt:feature,file.txt:orig,other.txt:orig,side.txt:side restack=- remote=pre
--reuse --replay over a conflict aborts back to the pre-replay branch and names both recovery paths|conflict|create topic --reuse --replay|1|-|aborted|engine=none branch=topic head=pre ref=pre ahead=1 dirty=- tree=file.txt:feature,other.txt:orig restack=- remote=-
--restack --replay over a published branch pauses the sequencer with a bound token and the branch unmoved|conflict publish|create topic --restack --replay|1|-|paused|engine=replay branch=detached head=base ref=pre ahead=0 dirty=UU file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:pre,orig:pre,base:base,pending:true,token:bound,mode:replay remote=pre
--restack --replay over an unpublished branch pauses with no remote lease|conflict|create topic --restack --replay|1|-|paused|engine=replay branch=detached head=base ref=pre ahead=0 dirty=UU file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:-,orig:pre,base:base,pending:true,token:bound,mode:replay remote=-
continue completes the resolved replay and authorizes its exact head|conflict publish restack-replay resolve|restack continue topic|0|completed|-|engine=none branch=topic head=rebased ref=head ahead=1 dirty=- tree=file.txt:resolved,other.txt:orig restack=remote:origin,branch:topic,expected:pre,authorized:head remote=pre
push after a completed replay publishes the rewritten head|conflict publish restack-replay resolve continue|push topic|0|-|skip-rebase|engine=none branch=topic head=end ref=end ahead=1 dirty=- tree=file.txt:resolved,other.txt:orig restack=- remote=end
skip drops the represented commit and replays the refresh-only commit|merged restack-replay|restack skip topic|0|completed|-|engine=none branch=topic head=rebased ref=head ahead=1 dirty=- tree=file.txt:already merged plus main follow-up,other.txt:orig,refresh-only.txt:refresh only restack=remote:origin,branch:topic,expected:pre,authorized:head remote=pre
abort restores the pre-replay branch and clears the record|conflict restack-replay|restack abort topic|0|aborted|-|engine=none branch=topic head=pre ref=pre ahead=1 dirty=- tree=file.txt:feature,other.txt:orig restack=- remote=-
continue with HEAD checked out onto the branch is refused|conflict second restack-replay raw-checkout|restack continue topic|1|-|refusal:not the replay recorded by the worktree tool|engine=replay branch=topic head=end ref=end ahead=2 dirty=- tree=file.txt:feature,other.txt:orig,second.txt:second restack=remote:origin,branch:topic,expected:-,orig:end,base:base,pending:true,token:bound,mode:replay remote=-
abort with HEAD checked out onto the branch restores it|conflict second restack-replay raw-checkout|restack abort topic|0|aborted|-|engine=none branch=topic head=end ref=end ahead=2 dirty=- tree=file.txt:feature,other.txt:orig,second.txt:second restack=- remote=-
abort after a hand cherry-pick quit refuses to force the checkout over the unmerged index|conflict restack-replay raw-quit|restack abort topic|1|-|unreattachable|engine=none branch=detached head=base ref=pre ahead=0 dirty=UU file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:-,orig:pre,base:base,pending:true,token:unbound,mode:replay remote=-
abort after a hand cherry-pick abort clears the orphaned record and reattaches the branch|conflict restack-replay raw-abort|restack abort topic|0|cleared|-|engine=none branch=topic head=pre ref=pre ahead=1 dirty=- tree=file.txt:feature,other.txt:orig restack=- remote=-
remote movement while paused refuses continue and leaves the replay paused|conflict publish restack-replay resolve move-remote|restack continue topic|1|-|remote-moved|engine=replay branch=detached head=base ref=pre ahead=0 dirty=M  file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:pre,orig:pre,base:base,pending:true,token:bound,mode:replay remote=external
abort stays available after remote movement|conflict publish restack-replay resolve move-remote|restack abort topic|0|aborted|-|engine=none branch=topic head=pre ref=pre ahead=1 dirty=- tree=file.txt:feature,other.txt:orig restack=- remote=external
remote movement after authorization fails the exact lease|clean replay move-remote|push topic|1|-|skip-rebase+lease-rejected|engine=none branch=topic head=end ref=end ahead=1 dirty=- tree=feature.txt:feature,file.txt:orig,main-advanced.txt:advanced,other.txt:orig restack=remote:origin,branch:topic,expected:pre,authorized:end remote=external
--replay without an engine to modify is refused|plain|create topic --replay|1|-|bare-flag|engine=none branch=topic head=pre ref=pre ahead=1 dirty=- tree=file.txt:orig,fix.txt:fix,other.txt:orig restack=- remote=-
'

echo "=== worktree create --replay (the policy-blocked restack engine) ==="
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
