#!/usr/bin/env bash
# `worktree push`: the auto-rebase and its skip, the rebase map, the argument
# parser, the target resolution, the force-with-lease expectation and the git
# invocation it delegates: one table, a row per scenario. A row's fixture is a
# word list of steps that builds a fresh main+origin pair with its issue
# worktree and drives it to the state under test; the command then runs from
# the main checkout (or the worktree, for the rows that push by issue ID from
# inside one), and the row pins its exit status, its stdout, the tool's own
# stderr, and what is left: the head, the commits ahead of origin/main, every
# tracked file with its first line, each remote's branch ref, the upstream
# the branch tracks, and the push argv when a shim captured it.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
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
REAL_GIT="$(command -v git)"

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
BASE=""       # origin/main at the end of the fixture
END=""        # HEAD at the end of the fixture
END1=""       # HEAD~1 at the end of the fixture
EXTERNAL=""   # a commit an outsider pushed to the remote branch
ROW_SCRIPT="" # the package copy a row runs instead of the script under test
ROW_PATH=""   # a PATH prefix holding a row's git shim
ROW_CWD=""    # the directory a row's command runs from, when not the main checkout

make_repo() {
  local repo="$1"
  mkdir -p "$repo"
  git -C "$repo" init -q -b main
  git -C "$repo" config user.email test@example.com
  git -C "$repo" config user.name Test
  git -C "$repo" config commit.gpgsign false
  printf 'orig\n' >"$repo/file.txt"
  git -C "$repo" add file.txt
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
  git --git-dir="$ROOT/$1.git" rev-parse -q --verify "refs/heads/$ISSUE" 2>/dev/null || true
}

# An outsider's commit on top of the remote branch: the tree it already has,
# a parent the local branch never saw as a tip.
external_commit() {
  local old="" tree=""
  old="$(remote_oid origin)"
  if [[ -z "$old" ]]; then
    echo "FIXTURE: no remote branch to move in $ROOT" >&2
    exit 2
  fi
  tree="$(git --git-dir="$ROOT/origin.git" rev-parse "${old}^{tree}")"
  GIT_AUTHOR_NAME=External GIT_AUTHOR_EMAIL=external@example.com \
    GIT_COMMITTER_NAME=External GIT_COMMITTER_EMAIL=external@example.com \
    git --git-dir="$ROOT/origin.git" commit-tree "$tree" -p "$old" -m 'external movement'
}

# A git ahead of the real one on PATH. `race` moves the remote branch to an
# outsider's commit the first time the tool runs a rebase, after the lease
# was captured. `capture` records the argv of the tool's push and answers
# success without a remote (the rows with a GitHub URL for a remote).
git_shim() {
  mkdir -p "$ROOT/bin"
  case "$1" in
    race)
      cat >"$ROOT/bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
for arg in "\$@"; do
  if [[ "\$arg" == rebase && ! -e "$ROOT/raced" ]]; then
    touch "$ROOT/raced"
    "$REAL_GIT" --git-dir="$ROOT/origin.git" update-ref "refs/heads/$ISSUE" "$EXTERNAL"
    break
  fi
done
exec "$REAL_GIT" "\$@"
EOF
      ;;
    capture)
      cat >"$ROOT/bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
for arg in "\$@"; do
  if [[ "\$arg" == push ]]; then
    printf '%s\n' "\$*" >"$ROOT/push.args"
    exit 0
  fi
done
exec "$REAL_GIT" "\$@"
EOF
      ;;
  esac
  chmod +x "$ROOT/bin/git"
  ROW_PATH="$ROOT/bin"
}

# The step vocabulary. The first word of a fixture builds the world; the
# rest drive it.
step() {
  case "$1" in
    pair) make_pair ;;
    # The issue worktree is registered outside the configured trees base:
    # the layout an app that owns worktree creation leaves.
    outside)
      make_repo "$MAIN"
      git init -q --bare "$ROOT/origin.git"
      git -C "$MAIN" remote add origin "$ROOT/origin.git"
      git -C "$MAIN" push -q -u origin main
      printf 'WORKTREE_BASE_DIR="../registry-trees"\n' >"$MAIN/.env.local"
      # Something sits at the configured path, so only the current checkout
      # can answer the ID: the registered-branch fallback would take this.
      mkdir -p "$ROOT/registry-trees/$ISSUE"
      WT="$ROOT/app-worktrees/$ISSUE"
      git -C "$MAIN" worktree add -q -b "$ISSUE" "$WT" main
      ROW_CWD="$WT"
      ;;
    # The remote is a GitHub URL nothing here can reach; the push is captured.
    github)
      make_repo "$MAIN"
      git -C "$MAIN" remote add origin git@github.com:owner/repo.git
      git -C "$MAIN" worktree add -q -b "$ISSUE" "$WT" main
      git_shim capture
      ;;
    # The issue worktree and origin/main edit the same line of file.txt, and
    # the worktree merged origin/main and resolved it: origin/main is an
    # ancestor of the branch, and a rebase would replay the resolved edit.
    merged)
      commit_wt file.txt feature
      commit_main file.txt main-side
      git -C "$WT" fetch -q origin
      git -C "$WT" merge origin/main >/dev/null 2>&1 || true
      printf 'merged\n' >"$WT/file.txt"
      git -C "$WT" add file.txt
      git -C "$WT" commit -q -m 'merge origin/main'
      ;;
    advance) commit_main main-advanced.txt advanced ;;
    fix) commit_wt fix.txt fix ;;
    fix2) commit_wt fix2.txt fix2 ;;
    # The branch's patch that main lands independently under another subject.
    dup) commit_wt dup.txt dup ;;
    dup-main) commit_main dup.txt dup ;;
    publish) tool push "$ISSUE" --set-upstream ;;
    move-remote)
      EXTERNAL="$(external_commit)"
      git --git-dir="$ROOT/origin.git" update-ref "refs/heads/$ISSUE" "$EXTERNAL"
      ;;
    # The main checkout fetched the remote branch after the outsider moved it.
    observe) git -C "$MAIN" fetch -q origin "+refs/heads/$ISSUE:refs/remotes/origin/$ISSUE" ;;
    race) EXTERNAL="$(external_commit)"; git_shim race ;;
    # An outsider published the branch before this checkout ever fetched it:
    # the first push's empty lease must refuse rather than overwrite.
    foreign)
      EXTERNAL="$(GIT_AUTHOR_NAME=External GIT_AUTHOR_EMAIL=external@example.com \
        GIT_COMMITTER_NAME=External GIT_COMMITTER_EMAIL=external@example.com \
        git --git-dir="$ROOT/origin.git" commit-tree \
          "$(git --git-dir="$ROOT/origin.git" rev-parse 'refs/heads/main^{tree}')" \
          -p refs/heads/main -m 'external branch')"
      git --git-dir="$ROOT/origin.git" update-ref "refs/heads/$ISSUE" "$EXTERNAL"
      ;;
    bot-remote)
      git init -q --bare "$ROOT/bot.git"
      git -C "$MAIN" remote add bot "$ROOT/bot.git"
      printf 'BOT_REMOTE_NAME="bot"\n' >>"$MAIN/.env.local"
      ;;
    broken-remote)
      git -C "$MAIN" remote add broken "$ROOT/missing.git"
      printf 'BOT_REMOTE_NAME="broken"\n' >>"$MAIN/.env.local"
      ;;
    # A copy of the package alone, or beside a sibling GitHub package whose
    # helper marks the git invocation it owns.
    standalone)
      mkdir -p "$ROOT/pkg"
      cp -R "$PACKAGE_DIR" "$ROOT/pkg/worktree"
      ROW_SCRIPT="$ROOT/pkg/worktree/scripts/worktree"
      ;;
    with-helper)
      step standalone
      mkdir -p "$ROOT/pkg/github/scripts/lib"
      printf 'kendex_github_git() {\n  git -c kendex.test-github-helper=loaded "$@"\n}\n' >"$ROOT/pkg/github/scripts/lib/gh-auth.sh"
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
  BASE="" END="" END1="" EXTERNAL="" ROW_SCRIPT="" ROW_PATH="" ROW_CWD=""
  for word in "$@"; do
    step "$word"
  done
  BASE="$(git -C "$MAIN" rev-parse -q --verify origin/main 2>/dev/null || git -C "$MAIN" rev-parse main)"
  END="$(git -C "$WT" rev-parse HEAD)"
  END1="$(git -C "$WT" rev-parse HEAD~1)"
}

# --- rendering ------------------------------------------------------------------

oid_name() {
  local oid="$1"
  if [[ -z "$oid" ]]; then printf -- '-'
  elif [[ "$oid" == "$BASE" ]]; then printf 'base'
  elif [[ "$oid" == "$END" ]]; then printf 'end'
  elif [[ -n "$EXTERNAL" && "$oid" == "$EXTERNAL" ]]; then printf 'external'
  elif [[ "$oid" == "$(git -C "$WT" rev-parse HEAD)" ]]; then printf 'head'
  else printf '%s' "$oid"
  fi
}

# Paths and commits by their names. Git's own push report (the remote's
# path, the ref lines, the rejection, its hint) is not the tool's clause and
# is dropped. A literal semicolon is escaped before the lines are joined on
# it; usage text is cut at its first line.
alias_text() {
  local head head1
  head="$(git -C "$WT" rev-parse HEAD)"
  head1="$(git -C "$WT" rev-parse HEAD~1)"
  sed \
    -e "s|$WT|<wt>|g" \
    -e "s|$ROOT|<root>|g" \
    -e "s|${ROW_SCRIPT:-$WORKTREE_SCRIPT}|<worktree>|g" \
    -e "s|$END1|<end~1>|g" \
    -e "s|$END|<end>|g" \
    -e "s|$head1|<head~1>|g" \
    -e "s|$head|<head>|g" \
    -e "s|${EXTERNAL:-NONE}|<external>|g" \
    -e '/^To <root>\/[a-z]*\.git$/d' \
    -e '/^To git@github\.com/d' \
    -e '/^error: failed to push/d' \
    -e '/^hint: /d' \
    -e "/^branch '.*' set up to track/d" \
    -e '/^ [!*+] /d' \
    -e '/^   [0-9a-f][0-9a-f]*\.\.[0-9a-f][0-9a-f]* /d' \
    -e 's/;/\\;/g' |
    awk '/^Usage: / { print; exit } { print }' |
    paste -s -d ';' -
}

worktree_head() {
  local head
  head="$(git -C "$WT" rev-parse HEAD)"
  if [[ "$head" == "$END" ]]; then printf 'end'
  elif git -C "$WT" merge-base --is-ancestor "$BASE" "$head"; then printf 'rebased'
  else printf 'other'
  fi
}

state() {
  local ahead tree remotes="" name push="-"
  ahead="$(git -C "$WT" rev-list --count "$BASE..HEAD" 2>/dev/null || true)"
  tree="$(git -C "$WT" ls-tree -r --name-only HEAD | while read -r name; do
    body="$(git -C "$WT" cat-file -p "HEAD:$name")"
    printf '%s:%s,' "$name" "${body%%$'\n'*}"
  done)"
  for name in origin bot; do
    [[ -d "$ROOT/$name.git" ]] && remotes="$remotes,$name:$(oid_name "$(remote_oid "$name")")"
  done
  [[ -f "$ROOT/push.args" ]] && push="$(alias_text <"$ROOT/push.args")"
  printf 'head=%s ahead=%s tree=%s remote=%s upstream=%s push=%s' \
    "$(worktree_head)" "${ahead:--}" "${tree%,}" "${remotes:-,-}" \
    "$(git -C "$WT" config "branch.$ISSUE.remote" 2>/dev/null || printf -- '-')" "$push"
}

# The command runs from the main checkout (or the row's directory) under the
# row's PATH prefix and script; @wt names the worktree's path.
run() {
  local -a argv
  local rc=0 i
  read -r -a argv <<<"$1"
  for i in "${!argv[@]}"; do
    [[ "${argv[i]}" == @wt ]] && argv[i]="$WT"
    [[ "${argv[i]}" == @empty ]] && argv[i]=""
  done
  (cd "${ROW_CWD:-$MAIN}" && PATH="${ROW_PATH:+$ROW_PATH:}$PATH" "${ROW_SCRIPT:-$WORKTREE_SCRIPT}" "${argv[@]}" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  printf 'rc=%s out=%s err=%s %s' "$rc" \
    "$(alias_text <"$ROOT/out")" "$(alias_text <"$ROOT/err")" "$(state | sed 's/remote=,/remote=/')"
}

# --- the expected text ----------------------------------------------------------
# Each spec word expands to the tool's whole message for that terminal path.

err_text() {
  local spec="$1"
  case "$spec" in
    *+*) printf '%s;%s' "$(err_text "${spec%%+*}")" "$(err_text "${spec#*+}")" ;;
    -) printf '' ;;
    skip-rebase) printf '%s' "→ origin/main already contained in topic\; skipping rebase" ;;
    map:*) printf '%s' "→ auto-rebase rewrote ${spec#map:} branch commit(s)\; rebase-map lines follow (kendex#728)" ;;
    unknown:*) printf '%s' "Error: unknown option '${spec#unknown:}' for push;Run: <worktree> push --help" ;;
    two:*) printf '%s' "Error: push takes a single issue ID or path (got '${spec#two:}')" ;;
    empty) printf '%s' "Error: push target is empty — pass an issue ID or path, or no argument at all to push the current checkout" ;;
    lease-rejected) printf '%s' "Error: Push rejected. Remote 'origin/topic' may have changed since the force-with-lease expectation\; fetch and rebase/merge before retrying." ;;
    not-contained) printf '%s' "Error: Remote 'origin/topic' points at <external>, which is not contained in local branch 'topic'.;Fetch and rebase/merge 'origin/topic' before using worktree push." ;;
    fetch-failed) printf '%s' "Error: Could not fetch remote branch 'topic' from remote 'broken' for force-with-lease.;  fatal: '<root>/missing.git' does not appear to be a git repository;  fatal: Could not read from remote repository.;  ;  Please make sure you have the correct access rights;  and the repository exists." ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$spec" ;;
  esac
}

out_text() {
  case "$1" in
    -) printf '' ;;
    usage) printf 'Usage: worktree push [ID|/path] [--set-upstream|-u] [--no-rebase]' ;;
    map2) printf '%s' "rebase-map: <end~1> <head~1>;rebase-map: <end> <head>" ;;
    map-dropped) printf '%s' "rebase-map: <end~1> dropped;rebase-map: <end> <head>" ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

# --- the rows ---------------------------------------------------------------------
# label|fixture|command|rc|out|err|state
ROWS='a branch that already contains origin/main is pushed unrebased, with no map|pair merged|push @wt --set-upstream|0|-|skip-rebase|head=end ahead=2 tree=file.txt:merged remote=origin:end upstream=origin push=-
a behind branch is rebased onto the advanced base and the map pairs each rewritten commit by position|pair advance fix fix2|push @wt --set-upstream|0|map2|map:2|head=rebased ahead=2 tree=file.txt:orig,fix.txt:fix,fix2.txt:fix2,main-advanced.txt:advanced remote=origin:head upstream=origin push=-
--no-rebase pushes the behind branch where it stands|pair advance fix|push @wt --set-upstream --no-rebase|0|-|-|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:end upstream=origin push=-
an unknown flag is a usage error that pushes and rebases nothing|pair advance fix|push @wt --no-rebse|1|-|unknown:--no-rebse|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=-
flags before the target still make the trailing positional the pushed tree, not the checkout|pair advance fix|push --no-rebase --set-upstream @wt|0|-|-|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:end upstream=origin push=-
push --help, the advertised recovery, prints the push usage|pair fix|push --help|0|usage|-|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=-
a second positional is a usage error|pair fix|push @wt topic|1|-|two:<wt>'"'"' and '"'"'topic|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=-
an empty positional is refused, not resolved to the current checkout|pair fix|push @empty|1|-|empty|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=-
an empty positional before a real one is still refused|pair fix|push @empty @wt|1|-|empty|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=-
an empty positional after a real one is a duplicate, not a silent second target|pair fix|push @wt @empty|1|-|two:<wt>'"'"' and '"'"'|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=-
a commit whose patch main already landed is dropped by the rebase and mapped as dropped|pair dup fix dup-main|push @wt --set-upstream|0|map-dropped|map:2|head=rebased ahead=1 tree=dup.txt:dup,file.txt:orig,fix.txt:fix remote=origin:head upstream=origin push=-
an issue ID names the current checkout when it is an issue worktree outside the trees base|outside fix|push TOPIC --no-rebase|0|-|-|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:end upstream=origin push=-
a first push by issue ID creates the remote branch and sets its upstream|pair fix|push TOPIC --set-upstream|0|-|skip-rebase|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:end upstream=origin push=-
an unobserved remote branch is not overwritten by a first push|pair fix foreign|push TOPIC --set-upstream|1|-|skip-rebase+lease-rejected|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:external upstream=- push=-
a rebased push over a published branch replaces the remote under its lease|pair fix publish advance fix2|push TOPIC|0|map2|map:2|head=rebased ahead=2 tree=file.txt:orig,fix.txt:fix,fix2.txt:fix2,main-advanced.txt:advanced remote=origin:head upstream=origin push=-
a remote moved after the lease was captured is not overwritten|pair fix publish advance fix2 race|push TOPIC|1|map2|map:2+lease-rejected|head=rebased ahead=2 tree=file.txt:orig,fix.txt:fix,fix2.txt:fix2,main-advanced.txt:advanced remote=origin:external upstream=origin push=-
a remote already observed to diverge is refused before any rebase|pair fix publish move-remote observe fix2|push TOPIC|1|-|not-contained|head=end ahead=2 tree=file.txt:orig,fix.txt:fix,fix2.txt:fix2 remote=origin:external upstream=origin push=-
a lease fetch that fails for a reason other than a missing branch aborts the push|pair fix broken-remote|push TOPIC|1|-|fetch-failed|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=-
the configured bot remote takes the lease and the push|pair bot-remote fix publish advance fix2|push TOPIC|0|map2|map:2|head=rebased ahead=2 tree=file.txt:orig,fix.txt:fix,fix2.txt:fix2,main-advanced.txt:advanced remote=origin:-,bot:head upstream=bot push=-
the package alone pushes through plain git|github fix standalone|push TOPIC --no-rebase --set-upstream|0|-|-|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=- upstream=- push=-C <wt> push -u origin HEAD:refs/heads/topic
a sibling GitHub helper, when present, owns the git invocation|github fix with-helper|push TOPIC --no-rebase --set-upstream|0|-|-|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=- upstream=- push=-c kendex.test-github-helper=loaded -C <wt> push -u origin HEAD:refs/heads/topic
'

echo "=== worktree push ==="
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
