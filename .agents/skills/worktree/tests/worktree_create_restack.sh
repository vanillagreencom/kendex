#!/usr/bin/env bash
# `worktree create --reuse/--restack` over a rebase conflict, the guarded
# restack controls that follow a pause, and the push authorization a completed
# restack leaves behind: one table, a row per scenario. A row's fixture is a
# word list of steps that builds a fresh main+origin pair with its issue
# worktree and drives it to the state under test; the command then runs from
# the main checkout, and the row pins its exit status, its stdout, the tool's
# own stderr, and the worktree's state afterwards: the engine, the branch,
# the head, the commits ahead of origin/main, the index, every tracked file
# with its first line, the restack record, the remote ref and the rebase map
# the restack left in the worktree for orch/scripts/worktree-push.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/messages.sh
source "$TEST_DIR/lib/messages.sh"
PACKAGE_DIR="$(cd "$TEST_DIR/.." && pwd)"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$PACKAGE_DIR/scripts/worktree}"
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
PRE1=""       # that tip's parent
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
    # The branch already contains the advanced main, so a reuse or restack
    # rebases nothing and rewrites no commit.
    contained)
      make_pair
      commit_main main-advanced.txt advanced
      git -C "$WT" merge -q --ff-only origin/main
      commit_wt fix.txt fix
      ;;
    # Two branch commits under one subject, main landing the first one's patch:
    # the restack rewrites the branch and its map cannot say which of the pair
    # survived, so the completion refuses.
    twins)
      make_pair
      printf 'a\n' >"$WT/twin-a.txt"
      git -C "$WT" add twin-a.txt
      git -C "$WT" commit -q -m 'twin subject'
      printf 'b\n' >"$WT/twin-b.txt"
      git -C "$WT" add twin-b.txt
      git -C "$WT" commit -q -m 'twin subject'
      printf 'a\n' >"$MAIN/twin-a.txt"
      git -C "$MAIN" add twin-a.txt
      git -C "$MAIN" commit -q -m 'main: twin-a'
      git -C "$MAIN" push -q origin main
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
  PRE="" PRE1="" BASE="" END="" EXTERNAL="" UNEXPECTED="" RESTACKED=""
  for word in "$@"; do
    step "$word"
    if [[ -z "$PRE" ]]; then
      PRE="$(git -C "$WT" rev-parse HEAD)"
      PRE1="$(git -C "$WT" rev-parse -q --verify 'HEAD~1' 2>/dev/null || true)"
    fi
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
  local head head1
  head="$(git -C "$WT" rev-parse HEAD)"
  head1="$(git -C "$WT" rev-parse -q --verify 'HEAD~1' 2>/dev/null || printf 'NONE')"
  message_records |
  sed \
    -e "s|$WT|<wt>|g" \
    -e "s|$ROOT|<root>|g" \
    -e "s|$WORKTREE_SCRIPT|<worktree>|g" \
    -e "s|$head1|<head~1>|g" \
    -e "s|$head|<head>|g" \
    -e "s|${PRE1:-NONE}|<pre~1>|g" \
    -e "s|$PRE|<pre>|g" \
    -e "s|$END|<end>|g" \
    -e "s|$BASE|<base>|g" \
    -e "s|${EXTERNAL:-NONE}|<external>|g" \
    -e "s|${UNEXPECTED:-NONE}|<unexpected>|g" \
    -e "s|${RESTACKED:-NONE}|<restacked>|g" \
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

# The map a completed restack appends to the worktree's own git dir for
# `orch/scripts/worktree-push` to consume. Absent is the answer for every path
# that rewrote nothing, so every row pins it.
restack_map() {
  local path=""
  path="$(git -C "$WT" rev-parse --git-path kendex-rebase-map 2>/dev/null)" || { printf -- '-'; return; }
  [[ "$path" == /* ]] || path="$WT/$path"
  if [[ ! -e "$path" ]]; then printf -- '-'; return; fi
  alias_text <"$path"
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
  printf 'engine=%s branch=%s head=%s ahead=%s dirty=%s tree=%s restack=%s remote=%s map=%s' \
    "$engine" "${branch:-detached}" "$(worktree_head)" "${ahead:--}" "${dirty:--}" "${tree%,}" \
    "$(restack_keys)" "$(oid_name "$(remote_oid)")" "$(restack_map)"
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





# The map lines one restack reports, by shape. The same text appears twice: on
# stderr under the restack's count record, and under that restack's own hop in
# the pending map file the worktree's git dir carries for
# orch/scripts/worktree-push. A shape's leading digit is how many pre-restack
# commits the count record names.
map_lines() {
  case "$1" in
    -) printf -- '-' ;;
    1) printf 'rebase-map: <pre> <head>' ;;
    1d) printf 'rebase-map: <pre> dropped' ;;
    1e) printf 'rebase-map: <end> <head>' ;;
    1p) printf 'rebase-map: <pre> <end>' ;;
    # Not a hop: the record a refusing restack leaves so a later push refuses
    # too, naming the head it rewrote from.
    unmapped) printf 'rebase-unmapped: <pre>' ;;
    unmapped-head) printf 'rebase-unmapped: <head>' ;;
    unmapped-head1) printf 'rebase-unmapped: <head~1>' ;;
    1r) printf 'rebase-map: <pre> <restacked>' ;;
    2d) printf 'rebase-map: <pre~1> dropped;rebase-map: <pre> <head>' ;;
    2x) printf 'rebase-map: <pre> <head~1>;rebase-map: <end> <head>' ;;
    *) printf 'UNKNOWN-MAP-SPEC:%s' "$1" ;;
  esac
}

# The map file's whole content: a '+'-joined list of hop shapes, each opening
# with its own boundary line. Two hops is a worktree restacked twice before one
# push, which worktree-push must apply in order rather than as one map.
map_file_text() {
  local spec="$1"
  case "$spec" in
    -) printf -- '-' ;;
    *+*) printf '%s;%s' "$(map_file_text "${spec%%+*}")" "$(map_file_text "${spec#*+}")" ;;
    unmapped*) map_lines "$spec" ;;
    *) printf 'rebase-hop:;%s' "$(map_lines "$spec")" ;;
  esac
}

err_text() {
  local spec="$1" shape=""
  case "$spec" in
    *+*) printf '%s;%s' "$(err_text "${spec%%+*}")" "$(err_text "${spec#*+}")" ;;
    -) printf '' ;;
    map:*)
      shape="${spec#map:}"
      printf 'worktree-rebase-count: %s;%s' "${shape%%[a-z]*}" "$(map_lines "$shape")"
      ;;
    skip-rebase) printf 'worktree-rebase-skipped: topic' ;;
    paused) printf 'worktree-rebase-conflicts: <wt>' ;;
    aborted) printf 'worktree-rebase-failed: <wt>' ;;
    refusal:*) printf 'worktree-restack-state: path=<wt> reason=%s' "${spec#refusal:}" ;;
    conflicts) printf 'worktree-restack-conflicts: file.txt' ;;
    unstaged) printf 'worktree-restack-unstaged: other.txt' ;;
    orphan-moved) printf 'worktree-restack-orphan-moved: <wt>' ;;
    unreattachable) printf 'worktree-restack-reattach-failed: <wt>' ;;
    remote-moved) printf 'worktree-restack-remote-moved: origin/topic' ;;
    setup-warning) printf 'worktree-config-path-invalid: WORKTREE_MKDIRS=../outside;worktree-restack-setup-failed: <wt>' ;;
    ambiguous) printf 'worktree-rebase-map-ambiguous: twin subject' ;;
    map-unreadable) printf 'worktree-restack-map-unreadable: <wt>' ;;
    pending-standing) printf 'worktree-rebase-pending-standing: <pre>' ;;
    lease-rejected) printf 'worktree-push-rejected: origin/topic' ;;
    not-contained) printf 'worktree-push-remote-uncontained: origin/topic' ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$spec" ;;
  esac
}

out_text() {
  case "$1" in
    -) printf '' ;;
    wt) printf '<wt>' ;;
    completed) printf 'worktree-restack-complete: <wt>' ;;
    aborted) printf 'worktree-restack-aborted: <wt>' ;;
    cleared) printf 'worktree-restack-cleared: <wt>' ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

# --- the rows ---------------------------------------------------------------------
# label|fixture|command|rc|out|err|state
ROWS='--reuse over a conflict aborts the rebase and names both recovery paths|conflict|create topic --reuse|1|-|aborted|engine=none branch=topic head=pre ahead=1 dirty=- tree=file.txt:feature,other.txt:orig restack=- remote=- map=-
--restack over a published branch pauses in the conflict with a bound token|conflict publish|create topic --restack|1|-|paused|engine=rebase branch=detached head=base ahead=0 dirty=UU file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:pre,orig:pre,base:base,pending:true,token:bound remote=pre map=unmapped
--restack over an unpublished branch pauses with no remote lease|conflict|create topic --restack|1|-|paused|engine=rebase branch=detached head=base ahead=0 dirty=UU file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:-,orig:pre,base:base,pending:true,token:bound remote=- map=unmapped
a paused restack from before token binding is refused|conflict publish restack unbind|restack continue topic|1|-|refusal:pending-marker-missing|engine=rebase branch=detached head=base ahead=0 dirty=UU file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:pre,orig:pre,base:base remote=pre map=unmapped
a tampered sequencer token is refused|conflict publish restack tamper-token|restack continue topic|1|-|refusal:token-mismatch|engine=rebase branch=detached head=base ahead=0 dirty=UU file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:pre,orig:pre,base:base,pending:true,token:unbound remote=pre map=unmapped
a record naming another branch is refused|conflict publish restack wrong-branch|restack skip topic|1|-|refusal:rebase-mismatch|engine=rebase branch=detached head=base ahead=0 dirty=UU file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:unrelated-branch,expected:pre,orig:pre,base:base,pending:true,token:bound remote=pre map=unmapped
continue over an unresolved conflict reports the conflict, not unstaged changes|conflict restack|restack continue topic|1|-|conflicts|engine=rebase branch=detached head=base ahead=0 dirty=UU file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:-,orig:pre,base:base,pending:true,token:bound remote=- map=unmapped
continue over a clean index with unstaged changes names them and offers no skip|conflict restack resolve dirty-other|restack continue topic|1|-|unstaged|engine=rebase branch=detached head=base ahead=0 dirty=M  file.txt, M other.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:-,orig:pre,base:base,pending:true,token:bound remote=- map=unmapped
continue completes the resolved restack and authorizes its exact head|conflict publish restack resolve|restack continue topic|0|completed|map:1|engine=none branch=topic head=rebased ahead=1 dirty=- tree=file.txt:resolved,other.txt:orig restack=remote:origin,branch:topic,expected:pre,authorized:head remote=pre map=1
an unpublished completion leaves no push authorization|conflict restack resolve|restack continue topic|0|completed|map:1|engine=none branch=topic head=rebased ahead=1 dirty=- tree=file.txt:resolved,other.txt:orig restack=- remote=- map=1
push after a completed restack publishes the head with the original lease|conflict publish restack resolve continue|push topic|0|-|skip-rebase|engine=none branch=topic head=end ahead=1 dirty=- tree=file.txt:resolved,other.txt:orig restack=- remote=head map=1
a completed restack cannot be controlled again|conflict publish restack resolve continue push|restack continue topic|1|-|refusal:no-paused-state|engine=none branch=topic head=end ahead=1 dirty=- tree=file.txt:resolved,other.txt:orig restack=- remote=head map=1
skip over a conflict drops that commit and completes|conflict publish restack|restack skip topic|0|completed|map:1d|engine=none branch=topic head=base ahead=0 dirty=- tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:pre,authorized:base remote=pre map=1d
skip drops the represented commit and replays the refresh-only commit|merged restack|restack skip topic|0|completed|map:2d|engine=none branch=topic head=rebased ahead=1 dirty=- tree=file.txt:already merged plus main follow-up,other.txt:orig,refresh-only.txt:refresh only restack=remote:origin,branch:topic,expected:pre,authorized:head remote=pre map=2d
abort restores the pre-restack branch and clears the record|conflict publish restack|restack abort topic|0|aborted|-|engine=none branch=topic head=pre ahead=1 dirty=- tree=file.txt:feature,other.txt:orig restack=- remote=pre map=-
a clean restack authorizes its rewritten head|clean|create topic --restack|0|wt|map:1|engine=none branch=topic head=rebased ahead=1 dirty=- tree=feature.txt:feature,file.txt:orig,main-advanced.txt:advanced,other.txt:orig restack=remote:origin,branch:topic,expected:pre,authorized:head remote=pre map=1
a clean restack over a two-commit branch maps every rewritten commit|clean commit-later|create topic --restack|0|wt|map:2x|engine=none branch=topic head=rebased ahead=2 dirty=- tree=feature.txt:feature,file.txt:orig,later.txt:later,main-advanced.txt:advanced,other.txt:orig restack=remote:origin,branch:topic,expected:pre,authorized:head remote=pre map=2x
a second clean restack rewrites the authorized head and keeps the lease|clean restack advance-main|create topic --restack|0|wt|map:1e|engine=none branch=topic head=rebased ahead=1 dirty=- tree=feature.txt:feature,file.txt:orig,main-advanced-twice.txt:advanced twice,main-advanced.txt:advanced,other.txt:orig restack=remote:origin,branch:topic,expected:pre,authorized:head remote=pre map=1p+1e
continue on a record whose rebase was aborted by hand is refused|conflict restack raw-abort|restack continue topic|1|-|refusal:no-paused-state|engine=none branch=topic head=pre ahead=1 dirty=- tree=file.txt:feature,other.txt:orig restack=remote:origin,branch:topic,expected:-,orig:pre,base:base,pending:true,token:unbound remote=- map=unmapped-head
abort on a record whose rebase was aborted by hand clears the record|conflict restack raw-abort|restack abort topic|0|cleared|-|engine=none branch=topic head=pre ahead=1 dirty=- tree=file.txt:feature,other.txt:orig restack=- remote=- map=-
abort on a record whose branch moved after the hand abort is refused|conflict restack raw-abort commit-later|restack abort topic|1|-|orphan-moved|engine=none branch=topic head=end ahead=2 dirty=- tree=file.txt:feature,later.txt:later,other.txt:orig restack=remote:origin,branch:topic,expected:-,orig:pre,base:base,pending:true,token:unbound remote=- map=unmapped-head1
continue with HEAD checked out off the recorded base is refused|conflict restack raw-checkout|restack continue topic|1|-|refusal:base-mismatch|engine=rebase branch=topic head=pre ahead=1 dirty=- tree=file.txt:feature,other.txt:orig restack=remote:origin,branch:topic,expected:-,orig:pre,base:base,pending:true,token:bound remote=- map=unmapped-head
abort with HEAD checked out off the recorded base restores the branch|conflict restack raw-checkout|restack abort topic|0|aborted|-|engine=none branch=topic head=pre ahead=1 dirty=- tree=file.txt:feature,other.txt:orig restack=- remote=- map=-
abort after a hand quit refuses to force the checkout over the unmerged index|conflict restack raw-quit|restack abort topic|1|-|unreattachable|engine=none branch=detached head=base ahead=0 dirty=UU file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:-,orig:pre,base:base,pending:true,token:unbound remote=- map=unmapped
a foreign repository carrying the keys is refused and untouched|conflict foreign|restack abort @outsider|1|-|refusal:unregistered|engine=none branch=main head=pre ahead=- dirty=- tree=file.txt:outside restack=pending:true,branch:main,orig:pre remote=- map=-
remote movement while paused refuses continue and leaves the remote alone|conflict publish restack resolve move-remote|restack continue topic|1|-|remote-moved|engine=rebase branch=detached head=base ahead=0 dirty=M  file.txt tree=file.txt:main-side,other.txt:orig restack=remote:origin,branch:topic,expected:pre,orig:pre,base:base,pending:true,token:bound remote=external map=unmapped
abort succeeds under a setup config that no longer applies|conflict publish restack resolve move-remote bad-mkdirs|restack abort topic|0|aborted|setup-warning|engine=none branch=topic head=pre ahead=1 dirty=- tree=file.txt:feature,other.txt:orig restack=- remote=external map=-
remote movement after authorization fails the exact lease|clean reuse move-remote|push topic|1|-|skip-rebase+lease-rejected|engine=none branch=topic head=end ahead=1 dirty=- tree=feature.txt:feature,file.txt:orig,main-advanced.txt:advanced,other.txt:orig restack=remote:origin,branch:topic,expected:pre,authorized:head remote=external map=1
a local rewrite is not covered by prior authorization|clean reuse local-rewrite|push topic|1|-|not-contained|engine=none branch=topic head=end ahead=1 dirty=- tree=file.txt:orig,main-advanced.txt:advanced,other.txt:orig restack=remote:origin,branch:topic,expected:pre,authorized:restacked remote=pre map=1r
clean reuse rebases onto the advanced main and prints the path|plain|create topic --reuse|0|wt|map:1|engine=none branch=topic head=rebased ahead=1 dirty=- tree=file.txt:orig,fix.txt:fix,main-advanced.txt:advanced,other.txt:orig restack=- remote=- map=1
--restack with nothing to rebase is a no-op|plain reuse|create topic --restack|0|wt|-|engine=none branch=topic head=end ahead=1 dirty=- tree=file.txt:orig,fix.txt:fix,main-advanced.txt:advanced,other.txt:orig restack=- remote=- map=1
a restack over a base the branch already contains rewrites nothing and leaves no map|contained|create topic --restack|0|wt|-|engine=none branch=topic head=pre ahead=1 dirty=- tree=file.txt:orig,fix.txt:fix,main-advanced.txt:advanced,other.txt:orig restack=- remote=- map=-
a restack whose map cannot be derived records the rewrite for a later push to refuse on|twins|create topic --restack|1|-|ambiguous+map-unreadable|engine=none branch=topic head=rebased ahead=1 dirty=- tree=file.txt:orig,other.txt:orig,twin-a.txt:a,twin-b.txt:b restack=- remote=- map=unmapped
a second rewrite refuses while the first one is still unresolved|twins restack advance-main|create topic --reuse|1|-|pending-standing|engine=none branch=topic head=end ahead=1 dirty=- tree=file.txt:orig,other.txt:orig,twin-a.txt:a,twin-b.txt:b restack=- remote=- map=unmapped
'

echo "=== worktree create reuse rebase-conflict recovery ==="
n=0
while IFS='|' read -r label fixture command rc out err want_state; do
  [[ -n "$label$fixture$command$rc$out$err$want_state" ]] || continue
  n=$((n + 1))
  # shellcheck disable=SC2086
  build "row-$n" $fixture
  # The state column's trailing map= carries a hop-shape list, expanded here
  # from the same renderer the err column's map: spec draws its lines from.
  want_state="${want_state% map=*} map=$(map_file_text "${want_state##* map=}")"
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
echo "=== must-fail control: with the emission cut, a completed restack records nothing ==="

# Every row above pins what a completed restack reports and what it leaves in
# the worktree. The defect planted here is the emission call itself, on a
# private package copy: the same rebase still happens, and the map that the
# rows above assert is then gone from both channels.
build map-mutant clean
mkdir -p "$ROOT/pkg"
cp -R "$PACKAGE_DIR" "$ROOT/pkg/worktree"
mutant_script="$ROOT/pkg/worktree/scripts/worktree"
assert_eq "$(grep -c 'emit_restack_rebase_map "\$WT_PATH"' "$mutant_script")" "3" \
  "control finds every restack map emission to remove"
sed -i.bak 's/emit_restack_rebase_map "\$WT_PATH"/: "no map"/' "$mutant_script"
rm -f "$mutant_script.bak"
assert_eq "$(grep -c 'emit_restack_rebase_map "\$WT_PATH"' "$mutant_script")" "0" \
  "control removes them only from its private copy"
mutant_rc=0
(cd "$MAIN" && "$mutant_script" create "$ISSUE" --restack >"$ROOT/mutant.out" 2>"$ROOT/mutant.err") || mutant_rc=$?
assert_eq "$mutant_rc" "0" "control: the mutant completes the same restack"
assert_eq "$(worktree_head)" "rebased" "control: the mutant rewrote the branch"
assert_eq "$(grep -c '^rebase-map: ' "$ROOT/mutant.err" || true)" "0" \
  "control: the mutant reports no map"
assert_eq "$(restack_map)" "$(map_lines unmapped)" \
  "control: with no emission to clear it, the mutant leaves the write-ahead record standing"

echo
echo "=== a rewrite whose record cannot be written never starts ==="

# The record is what a later push refuses on, so a restack that cannot write it
# must not rewrite anything: there would be no way to refuse the publish
# afterwards. A directory at the file's own path is what makes the write fail.
build map-unwritable clean
map_path="$(git -C "$WT" rev-parse --git-path kendex-rebase-map)"
[[ "$map_path" == /* ]] || map_path="$WT/$map_path"
mkdir -p "$map_path"
unwritable_head="$(git -C "$WT" rev-parse HEAD)"
unwritable_rc=0
(cd "$MAIN" && "$WORKTREE_SCRIPT" create "$ISSUE" --restack \
  >"$ROOT/unwritable.out" 2>"$ROOT/unwritable.err") || unwritable_rc=$?
assert_eq "$unwritable_rc" "1" "a restack whose record cannot be written fails"
assert_eq "$(grep '^worktree-rebase-pending-unrecorded:' "$ROOT/unwritable.err" | sed "s|$WT|<wt>|")" \
  "worktree-rebase-pending-unrecorded: <wt>" "the refusal names the worktree it could not record in"
assert_eq "$(git -C "$WT" rev-parse HEAD)" "$unwritable_head" "the branch was never rewritten"
assert_eq "$(restack_keys)" "-" "the refused restack leaves no push authorization"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
