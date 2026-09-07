#!/usr/bin/env bash
# `worktree create --reuse/--restack` over a rebase conflict, the guarded
# restack controls that follow a pause, and the push authorization a completed
# restack leaves behind: one table, a row per scenario. A row's fixture is a
# word list of steps that builds a fresh main+origin pair with its issue
# worktree and drives it to the state under test; the command then runs from
# the main checkout, and the row pins its exit status, its stdout, the tool's
# own stderr, and the worktree's state afterwards: the engine, the branch,
# the head, the commits ahead of origin/main, the index, every tracked file
# with its first line, the restack record and the remote ref.
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
UNEXPECTED="" # a local rewrite no restack authorized
RESTACKED=""  # the head a completed restack authorized before a rewrite replaced it

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  git -C "$repo" config commit.gpgsign false
  printf 'orig\n' >"$repo/file.txt"
  # A second tracked file no rebase here touches, so a step can dirty the
  # worktree without touching the conflicting path.
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

tool() {
  (cd "$MAIN" && "$WORKTREE_SCRIPT" "$@" >/dev/null 2>&1) || true
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

paused_state_dir() {
  local state path
  for state in rebase-merge rebase-apply; do
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
    # a reuse rebase genuinely conflicts.
    conflict)
      make_pair
      commit_wt file.txt feature
      commit_main file.txt main-side
      ;;
    # The issue branch is published and main advanced on a file it never
    # touched: a reuse rebase is clean.
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
    restack) tool create "$ISSUE" --restack ;;
    reuse) tool create "$ISSUE" --reuse ;;
    continue) tool restack continue "$ISSUE" ;;
    skip) tool restack skip "$ISSUE" ;;
    push) tool push "$ISSUE" ;;
    resolve)
      printf 'resolved\n' >"$WT/file.txt"
      git -C "$WT" add file.txt
      ;;
    # The record of a paused restack from before token binding.
    unbind)
      git -C "$WT" config --worktree --unset-all kendex-restack.pending
      git -C "$WT" config --worktree --unset-all kendex-restack.stateToken
      rm -f "$(paused_state_dir)/kendex-restack-token"
      ;;
    tamper-token) printf 'tampered\n' >"$(paused_state_dir)/kendex-restack-token" ;;
    wrong-branch) git -C "$WT" config --worktree kendex-restack.branch unrelated-branch ;;
    advance-main) commit_main main-advanced-twice.txt 'advanced twice' ;;
    dirty-other) printf 'edited after staging\n' >"$WT/other.txt" ;;
    raw-abort) git -C "$WT" rebase --abort ;;
    raw-quit) git -C "$WT" rebase --quit ;;
    raw-checkout) git -C "$WT" checkout -f "$ISSUE" >/dev/null 2>&1 ;;
    commit-later) commit_wt later.txt later ;;
    move-remote)
      EXTERNAL="$(external_commit)"
      git --git-dir="$ROOT/origin.git" update-ref "refs/heads/$ISSUE" "$EXTERNAL"
      ;;
    local-rewrite)
      RESTACKED="$(git -C "$WT" rev-parse HEAD)"
      UNEXPECTED="$(git -C "$WT" commit-tree "$(git -C "$WT" rev-parse 'origin/main^{tree}')" -p origin/main -m 'unexpected local rewrite')"
      git -C "$WT" reset -q --hard "$UNEXPECTED"
      ;;
    bad-mkdirs) printf 'WORKTREE_MKDIRS="../outside"\n' >>"$MAIN/.env.local" ;;
    # A repository outside this one carrying the tool's keys; the row's
    # target and state are the outsider.
    foreign)
      WT="$ROOT/outsider"
      git init -q -b main "$WT"
      git -C "$WT" config user.email test@example.com
      git -C "$WT" config user.name Test
      printf 'outside\n' >"$WT/file.txt"
      git -C "$WT" add file.txt
      git -C "$WT" commit -q -m base
      git -C "$WT" config extensions.worktreeConfig true
      git -C "$WT" config --worktree kendex-restack.pending true
      git -C "$WT" config --worktree kendex-restack.branch main
      git -C "$WT" config --worktree kendex-restack.originalHead "$(git -C "$WT" rev-parse HEAD)"
      PRE="$(git -C "$WT" rev-parse HEAD)"
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
  PRE="" BASE="" END="" EXTERNAL="" UNEXPECTED="" RESTACKED=""
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
  elif [[ -n "$UNEXPECTED" && "$oid" == "$UNEXPECTED" ]]; then printf 'unexpected'
  elif [[ -n "$RESTACKED" && "$oid" == "$RESTACKED" ]]; then printf 'restacked'
  elif [[ "$oid" == "$(git -C "$WT" rev-parse HEAD)" ]]; then printf 'head'
  elif [[ "$oid" == "$END" ]]; then printf 'end'
  else printf '%s' "$oid"
  fi
}

# Paths and commits by their names. Git's own push report (the remote's
# path, the ref line, the rejection, its hint) is not the tool's clause and
# is dropped. The lines the tool relays from git under its "git:" prefix
# collapse to one marker, their wording being git's, except a line naming
# the conflicting path: that the relay names the path is the tool's own
# contract ("the paths Git names above"). A literal semicolon is escaped
# before the lines are joined on it.
alias_text() {
  sed \
    -e "s|$WT|<wt>|g" \
    -e "s|$ROOT|<root>|g" \
    -e "s|$WORKTREE_SCRIPT|<worktree>|g" \
    -e "s|$PRE|<pre>|g" \
    -e "s|$BASE|<base>|g" \
    -e "s|${EXTERNAL:-NONE}|<external>|g" \
    -e "s|${UNEXPECTED:-NONE}|<unexpected>|g" \
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

state() {
  local engine=none branch ahead dirty tree
  paused_state_dir >/dev/null && engine=rebase
  branch="$(git -C "$WT" branch --show-current)"
  ahead="$(git -C "$WT" rev-list --count "$BASE..HEAD" 2>/dev/null || true)"
  dirty="$(git -C "$WT" status --porcelain | paste -s -d ',' -)"
  tree="$(git -C "$WT" ls-tree -r --name-only HEAD | while read -r name; do
    body="$(git -C "$WT" cat-file -p "HEAD:$name")"
    printf '%s:%s,' "$name" "${body%%$'\n'*}"
  done)"
  printf 'engine=%s branch=%s head=%s ahead=%s dirty=%s tree=%s restack=%s remote=%s' \
    "$engine" "${branch:-detached}" "$(worktree_head)" "${ahead:--}" "${dirty:--}" "${tree%,}" \
    "$(restack_keys)" "$(oid_name "$(remote_oid)")"
}

# The command runs from the main checkout; @outsider names the foreign
# repository's path.
run() {
  local -a argv
  local rc=0 i
  read -r -a argv <<<"$1"
  for i in "${!argv[@]}"; do
    [[ "${argv[i]}" == @outsider ]] && argv[i]="$ROOT/outsider"
  done
  (cd "$MAIN" && "$WORKTREE_SCRIPT" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  printf 'rc=%s out=%s err=%s %s' "$rc" \
    "$(alias_text <"$ROOT/out")" "$(alias_text <"$ROOT/err")" "$(state)"
}

# --- the expected text ----------------------------------------------------------
# Each spec word expands to the tool's whole message for that terminal path.

paused_block() {
  printf '%s' "Error: Rebase onto origin/main stopped on conflicts in <wt>.;Conflicting files:;  $1;The rebase is paused in the worktree so the conflicts can be resolved:;  1. Edit each conflicting file to remove the conflict markers.;  2. git -C \"<wt>\" add <file>    (each resolved file);  3. <worktree> restack continue \"<wt>\"    (repeat if it stops again);     If the resolved commit is empty: <worktree> restack skip \"<wt>\";To back out instead: <worktree> restack abort \"<wt>\""
}

aborted_block() {
  printf '%s' "Error: Rebase onto origin/main failed for <wt> (conflicts).;Conflicting files:;  $1;The rebase was aborted\; the worktree is back on its pre-rebase state with no conflicts left to resolve.;Recovery options:;  1. Redo the rebase and stop in the conflict state to resolve it:;       <worktree> create topic --restack;  2. Discard local divergence and recreate fresh from origin/main:;       <worktree> remove topic && <worktree> create topic"
}

refusal() {
  printf '%s' "Error: Restack state for $1 is $2\; refusing to run a rebase control command.;Only an exact paused state created by 'worktree create <ID> --restack' can be continued, skipped, or aborted."
}

restore_lines() {
  printf '%s' "To restore the pre-restack branch: <worktree> restack abort \"<wt>\";Recorded branch: topic"
}

err_text() {
  local spec="$1"
  case "$spec" in
    *+*) printf '%s;%s' "$(err_text "${spec%%+*}")" "$(err_text "${spec#*+}")" ;;
    skip-rebase) printf '%s' "→ origin/main already contained in topic\; skipping rebase" ;;
    -) printf '' ;;
    paused) paused_block file.txt ;;
    aborted) aborted_block file.txt ;;
    refusal:*) refusal '<wt>' "${spec#refusal:}" ;;
    conflicts) printf '%s' "  git:<file.txt>;  git:...;Restack stopped on conflicts:;  file.txt;Resolve and stage each file, then run: <worktree> restack continue \"<wt>\";$(restore_lines)" ;;
    unstaged) printf '%s' "  git:...;Restack stopped on unstaged changes, not on unresolved conflicts:;  other.txt;Stage or discard them, then run: <worktree> restack continue \"<wt>\";$(restore_lines)" ;;
    orphan-moved) printf '%s' "Error: No restack is paused in <wt>, and 'topic' is no longer at its recorded pre-restack commit <pre>\; refusing to clear the recorded state.;Something rewrote the branch outside the guarded restack\; inspect it before retrying." ;;
    unreattachable) printf '%s' "  git:...;  git:<file.txt>;Error: Could not reattach <wt> to 'topic'\; the recorded restack state was preserved.;A 'rebase --quit' or 'cherry-pick --quit' leaves the conflicted index in place: stage or discard the paths Git names above.;Then re-run: <worktree> restack abort \"<wt>\"" ;;
    remote-moved) printf '%s' "Error: Remote 'origin/topic' changed while the supported restack was paused\; refusing to continue or skip.;Abort the guarded restack before reconciling the moved remote." ;;
    setup-warning) printf '%s' "Error: invalid WORKTREE_MKDIRS entry '../outside'. Use a worktree-relative path without '.', '..', absolute, backslash, or glob metacharacter components.;Warning: Restack was aborted successfully, but worktree setup could not be reapplied. Fix the WORKTREE_* configuration, then run: <worktree> fix-links '<wt>'" ;;
    lease-rejected) printf '%s' "Error: Push rejected. Remote 'origin/topic' may have changed since the force-with-lease expectation\; fetch and rebase/merge before retrying." ;;
    not-contained) printf '%s' "Error: Remote 'origin/topic' points at <pre>, which is not contained in local branch 'topic'.;Fetch and rebase/merge 'origin/topic' before using worktree push." ;;
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
ROWS='--reuse over a conflict aborts the rebase and names both recovery paths|conflict|create topic --reuse|1|-|aborted|engine=none branch=topic head=pre ahead=1 dirty=- tree=file.txt:feature,other.txt:orig restack=- remote=-
--restack over a published branch pauses in the conflict with a bound token|conflict publish|create topic --restack|1|-|paused|engine=rebase branch=detached head=base ahead=0 dirty=UU file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:pre,orig:pre,base:base,pending:true,token:bound remote=pre
--restack over an unpublished branch pauses with no remote lease|conflict|create topic --restack|1|-|paused|engine=rebase branch=detached head=base ahead=0 dirty=UU file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:-,orig:pre,base:base,pending:true,token:bound remote=-
a paused restack from before token binding is refused|conflict publish restack unbind|restack continue topic|1|-|refusal:missing its tool-created pending marker|engine=rebase branch=detached head=base ahead=0 dirty=UU file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:pre,orig:pre,base:base remote=pre
a tampered sequencer token is refused|conflict publish restack tamper-token|restack continue topic|1|-|refusal:missing its matching tool-created state token|engine=rebase branch=detached head=base ahead=0 dirty=UU file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:pre,orig:pre,base:base,pending:true,token:unbound remote=pre
a record naming another branch is refused|conflict publish restack wrong-branch|restack skip topic|1|-|refusal:not the rebase recorded by the worktree tool|engine=rebase branch=detached head=base ahead=0 dirty=UU file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:unrelated-branch,expected:pre,orig:pre,base:base,pending:true,token:bound remote=pre
continue over an unresolved conflict reports the conflict, not unstaged changes|conflict restack|restack continue topic|1|-|conflicts|engine=rebase branch=detached head=base ahead=0 dirty=UU file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:-,orig:pre,base:base,pending:true,token:bound remote=-
continue over a clean index with unstaged changes names them and offers no skip|conflict restack resolve dirty-other|restack continue topic|1|-|unstaged|engine=rebase branch=detached head=base ahead=0 dirty=M  file.txt, M other.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:-,orig:pre,base:base,pending:true,token:bound remote=-
continue completes the resolved restack and authorizes its exact head|conflict publish restack resolve|restack continue topic|0|completed|-|engine=none branch=topic head=rebased ahead=1 dirty=- tree=file.txt:resolved,other.txt:orig restack=remote:origin,branch:topic,expected:pre,authorized:head remote=pre
an unpublished completion leaves no push authorization|conflict restack resolve|restack continue topic|0|completed|-|engine=none branch=topic head=rebased ahead=1 dirty=- tree=file.txt:resolved,other.txt:orig restack=- remote=-
push after a completed restack publishes the head with the original lease|conflict publish restack resolve continue|push topic|0|-|skip-rebase|engine=none branch=topic head=end ahead=1 dirty=- tree=file.txt:resolved,other.txt:orig restack=- remote=head
a completed restack cannot be controlled again|conflict publish restack resolve continue push|restack continue topic|1|-|refusal:missing a paused rebase|engine=none branch=topic head=end ahead=1 dirty=- tree=file.txt:resolved,other.txt:orig restack=- remote=head
skip over a conflict drops that commit and completes|conflict publish restack|restack skip topic|0|completed|-|engine=none branch=topic head=base ahead=0 dirty=- tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:pre,authorized:base remote=pre
skip drops the represented commit and replays the refresh-only commit|merged restack|restack skip topic|0|completed|-|engine=none branch=topic head=rebased ahead=1 dirty=- tree=file.txt:already merged plus main follow-up,other.txt:orig,refresh-only.txt:refresh only restack=remote:origin,branch:topic,expected:pre,authorized:head remote=pre
abort restores the pre-restack branch and clears the record|conflict publish restack|restack abort topic|0|aborted|-|engine=none branch=topic head=pre ahead=1 dirty=- tree=file.txt:feature,other.txt:orig restack=- remote=pre
a clean restack authorizes its rewritten head|clean|create topic --restack|0|wt|-|engine=none branch=topic head=rebased ahead=1 dirty=- tree=feature.txt:feature,file.txt:orig,main-advanced.txt:advanced,other.txt:orig restack=remote:origin,branch:topic,expected:pre,authorized:head remote=pre
a second clean restack rewrites the authorized head and keeps the lease|clean restack advance-main|create topic --restack|0|wt|-|engine=none branch=topic head=rebased ahead=1 dirty=- tree=feature.txt:feature,file.txt:orig,main-advanced-twice.txt:advanced twice,main-advanced.txt:advanced,other.txt:orig restack=remote:origin,branch:topic,expected:pre,authorized:head remote=pre
continue on a record whose rebase was aborted by hand is refused|conflict restack raw-abort|restack continue topic|1|-|refusal:missing a paused rebase|engine=none branch=topic head=pre ahead=1 dirty=- tree=file.txt:feature,other.txt:orig restack=remote:origin,branch:topic,expected:-,orig:pre,base:base,pending:true,token:unbound remote=-
abort on a record whose rebase was aborted by hand clears the record|conflict restack raw-abort|restack abort topic|0|cleared|-|engine=none branch=topic head=pre ahead=1 dirty=- tree=file.txt:feature,other.txt:orig restack=- remote=-
abort on a record whose branch moved after the hand abort is refused|conflict restack raw-abort commit-later|restack abort topic|1|-|orphan-moved|engine=none branch=topic head=end ahead=2 dirty=- tree=file.txt:feature,later.txt:later,other.txt:orig restack=remote:origin,branch:topic,expected:-,orig:pre,base:base,pending:true,token:unbound remote=-
continue with HEAD checked out off the recorded base is refused|conflict restack raw-checkout|restack continue topic|1|-|refusal:stale or no longer based on its recorded commits|engine=rebase branch=topic head=pre ahead=1 dirty=- tree=file.txt:feature,other.txt:orig restack=remote:origin,branch:topic,expected:-,orig:pre,base:base,pending:true,token:bound remote=-
abort with HEAD checked out off the recorded base restores the branch|conflict restack raw-checkout|restack abort topic|0|aborted|-|engine=none branch=topic head=pre ahead=1 dirty=- tree=file.txt:feature,other.txt:orig restack=- remote=-
abort after a hand quit refuses to force the checkout over the unmerged index|conflict restack raw-quit|restack abort topic|1|-|unreattachable|engine=none branch=detached head=base ahead=0 dirty=UU file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:-,orig:pre,base:base,pending:true,token:unbound remote=-
a foreign repository carrying the keys is refused and untouched|conflict foreign|restack abort @outsider|1|-|refusal:not a registered worktree of this repository|engine=none branch=main head=pre ahead=- dirty=- tree=file.txt:outside restack=pending:true,branch:main,orig:pre remote=-
remote movement while paused refuses continue and leaves the remote alone|conflict publish restack resolve move-remote|restack continue topic|1|-|remote-moved|engine=rebase branch=detached head=base ahead=0 dirty=M  file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:pre,orig:pre,base:base,pending:true,token:bound remote=external
abort succeeds under a setup config that no longer applies|conflict publish restack resolve move-remote bad-mkdirs|restack abort topic|0|aborted|setup-warning|engine=none branch=topic head=pre ahead=1 dirty=- tree=file.txt:feature,other.txt:orig restack=- remote=external
remote movement after authorization fails the exact lease|clean reuse move-remote|push topic|1|-|skip-rebase+lease-rejected|engine=none branch=topic head=end ahead=1 dirty=- tree=feature.txt:feature,file.txt:orig,main-advanced.txt:advanced,other.txt:orig restack=remote:origin,branch:topic,expected:pre,authorized:head remote=external
a local rewrite is not covered by prior authorization|clean reuse local-rewrite|push topic|1|-|not-contained|engine=none branch=topic head=end ahead=1 dirty=- tree=file.txt:orig,main-advanced.txt:advanced,other.txt:orig restack=remote:origin,branch:topic,expected:pre,authorized:restacked remote=pre
clean reuse rebases onto the advanced main and prints the path|plain|create topic --reuse|0|wt|-|engine=none branch=topic head=rebased ahead=1 dirty=- tree=file.txt:orig,fix.txt:fix,main-advanced.txt:advanced,other.txt:orig restack=- remote=-
--restack with nothing to rebase is a no-op|plain reuse|create topic --restack|0|wt|-|engine=none branch=topic head=end ahead=1 dirty=- tree=file.txt:orig,fix.txt:fix,main-advanced.txt:advanced,other.txt:orig restack=- remote=-
'

echo "=== worktree create reuse rebase-conflict recovery ==="
n=0
while IFS='|' read -r label fixture command rc out err want_state; do
  [[ -n "$label$fixture$command$rc$out$err$want_state" ]] || continue
  n=$((n + 1))
  # shellcheck disable=SC2086
  build "row-$n" $fixture
  assert_eq "$(run "$command")" "rc=$rc out=$(out_text "$out") err=$(err_text "$err") $want_state" "$label"
done <<<"$ROWS"

# A git hook exports GIT_DIR and GIT_INDEX_FILE at the worktree it fires in,
# and both outrank -C, so a sibling suite run from that context builds its
# fixtures at that worktree unless it clears them first: it dies at its first
# fixture, or worse, lands commits there. The battery a restack is verified
# with runs beside a live authorization, so one is held here across such a
# run.
build env-live clean restack
env_git_dir="$(git -C "$WT" rev-parse --absolute-git-dir)"
env_fingerprint() {
  git -C "$WT" log --format=%H
  echo '--'
  git -C "$WT" ls-files --stage
  echo '--'
  git -C "$WT" config --worktree --list
}
env_before="$(env_fingerprint)"
env_suite_rc=0
env GIT_DIR="$env_git_dir" GIT_INDEX_FILE="$env_git_dir/index" \
  bash "$TEST_DIR/worktree_push_rebase.sh" >"$ROOT/suite.out" 2>&1 || env_suite_rc=$?
assert_eq "$env_suite_rc" "0" "a sibling suite passes under an exported git environment"
assert_eq "$(env_fingerprint)" "$env_before" "that suite left the live worktree's log, index and restack authorization untouched"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
