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
END2=""       # HEAD~2 at the end of the fixture, where the branch has one
EXTERNAL=""   # a commit an outsider pushed to the remote branch
UNMAPPED=""   # the head a refusing push rewrote the branch from
ROW_SCRIPT="" # the package copy a row runs instead of the script under test
ROW_PATH=""   # a PATH prefix holding a row's git shim
ROW_CWD=""    # the directory a row's command runs from, when not the main checkout
SEED=""       # the source checkout for a true standalone clone fixture

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

make_pair_with_lock() {
  make_repo "$MAIN"
  printf 'base-lock\n' >"$MAIN/.kendex-lock.json"
  git -C "$MAIN" add .kendex-lock.json
  git -C "$MAIN" commit -q -m 'base: portable lock'
  printf 'WORKTREE_COPIES=".kendex-lock.json"\n' >>"$MAIN/.env.local"
  git init -q --bare "$ROOT/origin.git"
  git -C "$MAIN" remote add origin "$ROOT/origin.git"
  git -C "$MAIN" push -q -u origin main
  (cd "$MAIN" && "$WORKTREE_SCRIPT" create "$ISSUE" >/dev/null 2>&1)
}

make_standalone_clone() {
  SEED="$ROOT/seed"
  make_repo "$SEED"
  printf 'base-lock\n' >"$SEED/.kendex-lock.json"
  git -C "$SEED" add .kendex-lock.json
  git -C "$SEED" commit -q -m 'base: portable lock'
  git init -q --bare "$ROOT/origin.git"
  git -C "$SEED" remote add origin "$ROOT/origin.git"
  git -C "$SEED" push -q -u origin main
  git --git-dir="$ROOT/origin.git" symbolic-ref HEAD refs/heads/main
  git clone -q "$ROOT/origin.git" "$MAIN"
  git -C "$MAIN" config user.email test@example.com
  git -C "$MAIN" config user.name Test
  git -C "$MAIN" config commit.gpgsign false
  git -C "$MAIN" switch -q -c "$ISSUE"
  printf 'WORKTREE_COPIES=".kendex-lock.json local.txt"\n' >"$MAIN/.env.local"
  printf 'local-only\n' >"$MAIN/local.txt"
  printf 'local.txt\n' >>"$MAIN/.git/info/exclude"
  WT="$MAIN"
  ROW_CWD="$MAIN"
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

# A branch commit under an explicit subject, so a row can give two commits
# one subject between them.
commit_wt_subject() {
  local file="$1" content="$2" subject="$3"
  printf '%s\n' "$content" >"$WT/$file"
  git -C "$WT" add "$file"
  git -C "$WT" commit -q -m "$subject"
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
  local fail_repo=""
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
    index-unreadable-wt|index-unreadable-main)
      if [[ "$1" == index-unreadable-wt ]]; then
        fail_repo="$WT"
      else
        fail_repo="$MAIN"
      fi
      cat >"$ROOT/bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
repo="" saw_ls=false saw_lock=false previous=""
for arg in "\$@"; do
  [[ "\$previous" == -C ]] && repo="\$arg"
  [[ "\$arg" == ls-files ]] && saw_ls=true
  [[ "\$arg" == ':(literal).kendex-lock.json' ]] && saw_lock=true
  previous="\$arg"
done
if [[ "\$repo" == "$fail_repo" && "\$saw_ls" == true && "\$saw_lock" == true ]]; then
  exit 3
fi
exec "$REAL_GIT" "\$@"
EOF
      ;;
  esac
  chmod +x "$ROOT/bin/git"
  ROW_PATH="$ROOT/bin"
}

# A pre-push hook publishing the commit-guards message protocol the tool
# reads: `pre-push: <key>=<value>` lines, a completed run ending in
# `pre-push: result=<code>`. One writer for every transcript a row needs,
# since what separates them is the verdict line, the exit status, and whether
# a consumer's own half spoke under a clean lane verdict — the shape the
# installer leaves in a repository that already had a pre-push hook. An empty
# verdict leaves the transcript with keyed lines and none.
arm_pre_push_hook() { # VERDICT-LINE-OR-EMPTY EXIT [CONSUMER-STDERR-LINE]
  mkdir -p "$MAIN/.git/hooks"
  cat >"$MAIN/.git/hooks/pre-push" <<HOOK
#!/usr/bin/env bash
cat >/dev/null
printf 'pre-push: step=all\n'
${1:+printf '$1\n'}
${3:+printf '$3\n' >&2}
exit $2
HOOK
  chmod +x "$MAIN/.git/hooks/pre-push"
}

# The step vocabulary. The first word of a fixture builds the world; the
# rest drive it.
step() {
  case "$1" in
    pair) make_pair ;;
    pair-lock) make_pair_with_lock ;;
    standalone-clone) make_standalone_clone ;;
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
    clone-advance)
      printf 'advanced\n' >"$SEED/main-advanced.txt"
      git -C "$SEED" add main-advanced.txt
      git -C "$SEED" commit -q -m 'main: advanced'
      git -C "$SEED" push -q origin main
      git -C "$MAIN" fetch -q origin main
      ;;
    fix) commit_wt fix.txt fix ;;
    fix2) commit_wt fix2.txt fix2 ;;
    lock-fix) commit_wt .kendex-lock.json branch-lock ;;
    setup-fails)
      printf 'WORKTREE_COPIES="copy-parent/copied.txt"\n' >>"$MAIN/.env.local"
      mkdir -p "$MAIN/copy-parent"
      printf 'copy-source\n' >"$MAIN/copy-parent/copied.txt"
      commit_wt copy-parent blocked
      ;;
    # The branch's patch that main lands independently under another subject.
    dup) commit_wt dup.txt dup ;;
    dup-main) commit_main dup.txt dup ;;
    # Two branch commits under one subject.
    twins)
      commit_wt_subject twin-a.txt a 'twin subject'
      commit_wt_subject twin-b.txt b 'twin subject'
      ;;
    # Main lands the first twin's patch under its own subject, so the rebase
    # drops one of the pair and the subject they share says nothing about
    # which one it was.
    twins-main) commit_main twin-a.txt a ;;
    # The push that rewrites the branch and then refuses, because its map
    # cannot be derived. It leaves the record a later push must refuse on;
    # UNMAPPED is the head it rewrote from.
    unmapped-push)
      UNMAPPED="$(git -C "$WT" rev-parse HEAD)"
      tool push "$ISSUE" --set-upstream
      ;;
    # What a killed rewrite leaves: the record is written before git touches a
    # commit, so a death anywhere between that write and the map reaching disk
    # leaves exactly this. The rebase is run by hand here, because the window
    # the record covers is the one no process survives to report.
    killed-rewrite)
      UNMAPPED="$(git -C "$WT" rev-parse HEAD)"
      printf '%s %s\n' 'rebase-unmapped:' "$UNMAPPED" \
        >"$(git -C "$WT" rev-parse --absolute-git-dir)/kendex-rebase-map"
      git -C "$WT" rebase origin/main >/dev/null 2>&1
      ;;
    publish) tool push "$ISSUE" --set-upstream ;;
    move-remote)
      EXTERNAL="$(external_commit)"
      git --git-dir="$ROOT/origin.git" update-ref "refs/heads/$ISSUE" "$EXTERNAL"
      ;;
    # The main checkout fetched the remote branch after the outsider moved it.
    observe) git -C "$MAIN" fetch -q origin "+refs/heads/$ISSUE:refs/remotes/origin/$ISSUE" ;;
    race) EXTERNAL="$(external_commit)"; git_shim race ;;
    index-unreadable-wt) git_shim index-unreadable-wt ;;
    index-unreadable-main) git_shim index-unreadable-main ;;
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
    # The four transcripts the classifier has to tell apart, one hook each.
    # A refusal carrying its verdict; one that never reaches a verdict, the
    # shape the commit-guards lane's collection refusals exit in; a clean run,
    # after which anything the remote rejects is the remote's to explain; and
    # a composed hook, whose lane half is clean and whose consumer half then
    # refuses on its own, the shape the installer leaves in a repository that
    # already had a pre-push hook.
    hook-refuses) arm_pre_push_hook 'pre-push: result=1' 1 ;;
    hook-aborts) arm_pre_push_hook '' 1 ;;
    hook-passes) arm_pre_push_hook 'pre-push: result=0' 0 ;;
    hook-composed) arm_pre_push_hook 'pre-push: result=0' 1 'consumer-hook: refused' ;;
    # The must-fail control's world: a package copy with the hook-refusal arm
    # cut out, so a refusal this tool can read reaches the last arm instead of
    # its own record.
    unfixed-hook)
      step standalone
      step hook-refuses
      sed -i.bak 's/if push_output_refused_by_hook .*; then/if false; then/' "$ROW_SCRIPT"
      rm -f "$ROW_SCRIPT.bak"
      grep -q 'if false; then' "$ROW_SCRIPT" || {
        echo "FIXTURE: the hook-arm edit matched nothing in $ROW_SCRIPT" >&2
        exit 2
      }
      ;;
    # The other must-fail control's world: a package copy whose lease arm goes
    # back to keying on the absence of a readable hook verdict instead of on
    # git's own rejection line, which is what told a composed hook's refusal
    # as a remote that moved.
    unfixed-lease)
      step standalone
      step hook-composed
      sed -i.bak 's/elif push_output_lease_rejected .*; then/elif [[ ${#PUSH_LEASE[@]} -gt 0 ]]; then/' "$ROW_SCRIPT"
      rm -f "$ROW_SCRIPT.bak"
      grep -q 'elif \[\[ ${#PUSH_LEASE\[@\]} -gt 0 \]\]; then' "$ROW_SCRIPT" || {
        echo "FIXTURE: the lease-arm edit matched nothing in $ROW_SCRIPT" >&2
        exit 2
      }
      ;;
    unfixed-copy-ownership)
      step standalone
      mutant="$ROOT/pkg/worktree/scripts/lib/links.sh"
      [[ "$(grep -cF 'if [[ -n "$copy_tracked" ]]; then' "$mutant")" == 1 ]] || {
        echo "FIXTURE: the copy-ownership arm was not unique in $mutant" >&2
        exit 2
      }
      sed -i.bak 's/if \[\[ -n "$copy_tracked" \]\]; then/if false; then/' "$mutant"
      rm -f "$mutant.bak"
      grep -qF 'if false; then' "$mutant" || {
        echo "FIXTURE: the copy-ownership edit matched nothing in $mutant" >&2
        exit 2
      }
      ;;
    unfixed-index-read)
      step standalone
      mutant="$ROOT/pkg/worktree/scripts/lib/links.sh"
      [[ "$(grep -cF 'if git -C "$repo" ls-files -z -- ":(literal)$rel" >"$entries" 2>/dev/null; then' "$mutant")" == 1 ]] || {
        echo "FIXTURE: the checked index read was not unique in $mutant" >&2
        exit 2
      }
      sed -i.bak 's|if git -C "$repo" ls-files -z -- ":(literal)$rel" >"$entries" 2>/dev/null; then|if :; then|' "$mutant"
      rm -f "$mutant.bak"
      grep -qF 'if :; then' "$mutant" || {
        echo "FIXTURE: the index-read edit matched nothing in $mutant" >&2
        exit 2
      }
      ;;
    unfixed-standalone-copy)
      step standalone
      mutant="$ROOT/pkg/worktree/scripts/lib/links.sh"
      [[ "$(grep -cF 'if same_canonical_dir "$PROJECT_ROOT" "$wt"; then' "$mutant")" == 1 ]] || {
        echo "FIXTURE: the standalone-copy arm was not unique in $mutant" >&2
        exit 2
      }
      sed -i.bak 's/if same_canonical_dir "$PROJECT_ROOT" "$wt"; then/if false; then/' "$mutant"
      rm -f "$mutant.bak"
      grep -qF 'if false; then' "$mutant" || {
        echo "FIXTURE: the standalone-copy edit matched nothing in $mutant" >&2
        exit 2
      }
      ;;
    unfixed-map-order)
      step standalone
      mutant="$ROW_SCRIPT"
      [[ "$(grep -cF '          setup_worktree_links "$WT_PATH" || exit 1' "$mutant")" == 1 ]] || {
        echo "FIXTURE: the post-map setup call was not unique in $mutant" >&2
        exit 2
      }
      [[ "$(grep -cF '          POST_REBASE_COMMITS="$(git -C "$WT_PATH" log --reverse --format='"'"'%H %s'"'"' "origin/$DEFAULT_BRANCH..HEAD")"' "$mutant")" == 1 ]] || {
        echo "FIXTURE: the post-rebase snapshot was not unique in $mutant" >&2
        exit 2
      }
      sed -i.bak \
        -e '/^          setup_worktree_links "$WT_PATH" || exit 1$/d' \
        -e '/^          POST_REBASE_COMMITS=/i\          setup_worktree_links "$WT_PATH" || exit 1' \
        "$mutant"
      rm -f "$mutant.bak"
      [[ "$(grep -cF '          setup_worktree_links "$WT_PATH" || exit 1' "$mutant")" == 1 ]] || {
        echo "FIXTURE: the setup-order edit did not leave one call in $mutant" >&2
        exit 2
      }
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
  BASE="" END="" END1="" END2="" EXTERNAL="" UNMAPPED="" ROW_SCRIPT="" ROW_PATH="" ROW_CWD="" SEED=""
  for word in "$@"; do
    step "$word"
  done
  BASE="$(git -C "$MAIN" rev-parse -q --verify origin/main 2>/dev/null || git -C "$MAIN" rev-parse main)"
  END="$(git -C "$WT" rev-parse HEAD)"
  END1="$(git -C "$WT" rev-parse HEAD~1)"
  END2="$(git -C "$WT" rev-parse -q --verify 'HEAD~2' 2>/dev/null || true)"
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
    -e "s|${END2:-NONE}|<end~2>|g" \
    -e "s|$END1|<end~1>|g" \
    -e "s|$END|<end>|g" \
    -e "s|$head1|<head~1>|g" \
    -e "s|$head|<head>|g" \
    -e "s|${EXTERNAL:-NONE}|<external>|g" \
    -e "s|${UNMAPPED:-NONE}|<unmapped>|g" \
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

# The worktree-private record a rewrite leaves standing until its map is
# durable or the rewrite is unwound. Every row pins it, so an ordinary push
# clearing its own record is what stops one being left behind to refuse the
# next push.
pending_record() {
  local path=""
  path="$(git -C "$WT" rev-parse --git-path kendex-rebase-map 2>/dev/null)" || { printf -- '-'; return; }
  [[ "$path" == /* ]] || path="$WT/$path"
  [[ -e "$path" ]] || { printf -- '-'; return; }
  message_records <"$path" | alias_text
}

state() {
  local ahead tree remotes="" name push="-" lock_state="" lock_clean=clean
  ahead="$(git -C "$WT" rev-list --count "$BASE..HEAD" 2>/dev/null || true)"
  tree="$(git -C "$WT" ls-tree -r --name-only HEAD | while read -r name; do
    body="$(git -C "$WT" cat-file -p "HEAD:$name")"
    printf '%s:%s,' "$name" "${body%%$'\n'*}"
  done)"
  for name in origin bot; do
    [[ -d "$ROOT/$name.git" ]] && remotes="$remotes,$name:$(oid_name "$(remote_oid "$name")")"
  done
  [[ -f "$ROOT/push.args" ]] && push="$(alias_text <"$ROOT/push.args")"
  if [[ -f "$WT/.kendex-lock.json" ]]; then
    git -C "$WT" diff --quiet -- .kendex-lock.json || lock_clean=dirty
    lock_state=" lock=$(sed -n '1p' "$WT/.kendex-lock.json"):$lock_clean"
  fi
  printf 'head=%s ahead=%s tree=%s remote=%s upstream=%s push=%s%s map=%s' \
    "$(worktree_head)" "${ahead:--}" "${tree%,}" "${remotes:-,-}" \
    "$(git -C "$WT" config "branch.$ISSUE.remote" 2>/dev/null || printf -- '-')" "$push" "$lock_state" \
    "$(pending_record)"
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
    "$(message_records <"$ROOT/out" | alias_text)" "$(message_records <"$ROOT/err" | alias_text)" "$(state | sed 's/remote=,/remote=/')"
}

# --- the expected text ----------------------------------------------------------
# Each spec word expands to the tool's whole message for that terminal path.

err_text() {
  local spec="$1"
  case "$spec" in
    *+*) printf '%s;%s' "$(err_text "${spec%%+*}")" "$(err_text "${spec#*+}")" ;;
    -) printf '' ;;
    skip-rebase) printf 'worktree-rebase-skipped: topic' ;;
    map:*) printf 'worktree-rebase-count: %s' "${spec#map:}" ;;
    ambiguous) printf 'worktree-rebase-map-ambiguous: twin subject' ;;
    unmapped) printf 'worktree-push-rebase-unmapped: <end>' ;;
    unmapped-retry) printf 'worktree-push-rebase-unmapped: <unmapped>' ;;
    unknown:*) printf 'worktree-push-option-unknown: %s' "${spec#unknown:}" ;;
    two:*) printf 'worktree-push-target-count: 2' ;;
    empty) printf 'worktree-push-target-empty: target' ;;
    lease-rejected) printf 'worktree-push-rejected: origin/topic' ;;
    hook-rejected) printf 'worktree-push-hook-rejected: origin/topic' ;;
    push-failed) printf 'worktree-push-failed: origin/topic' ;;
    not-contained) printf 'worktree-push-remote-uncontained: origin/topic' ;;
    fetch-failed) printf 'worktree-remote-fetch-failed: broken/topic' ;;
    copy-failed:*) printf 'worktree-copy-failed: <wt>/%s' "${spec#copy-failed:}" ;;
    index-read-wt) printf 'worktree-index-read-failed: <wt>:.kendex-lock.json' ;;
    index-read-main) printf 'worktree-index-read-failed: <root>/main:.kendex-lock.json' ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$spec" ;;
  esac
}

# What the worktree's map file holds: either the record a rewrite leaves until
# its map is durable, named by the head it covers, or the hop a mapped rewrite
# wrote there, whose lines are the ones it also printed.
map_text() {
  case "$1" in
    -) printf -- '-' ;;
    end) printf 'rebase-unmapped: <end>' ;;
    unmapped) printf 'rebase-unmapped: <unmapped>' ;;
    hop:*) printf 'rebase-hop:;%s' "$(out_text "${1#hop:}")" ;;
    *) printf 'UNKNOWN-MAP-SPEC:%s' "$1" ;;
  esac
}

out_text() {
  case "$1" in
    -) printf '' ;;
    usage) printf 'worktree-help: push' ;;
    map2) printf '%s' "rebase-map: <end~1> <head~1>;rebase-map: <end> <head>" ;;
    map-dropped) printf '%s' "rebase-map: <end~1> dropped;rebase-map: <end> <head>" ;;
    map-group) printf '%s' "rebase-map: <end~2> <head~1>;rebase-map: <end~1> <head>;rebase-map: <end> dropped" ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

# --- the rows ---------------------------------------------------------------------
# label|fixture|command|rc|out|err|state
ROWS='a branch that already contains origin/main is pushed unrebased, with no map|pair merged|push @wt --set-upstream|0|-|skip-rebase|head=end ahead=2 tree=file.txt:merged remote=origin:end upstream=origin push=- map=-
a behind branch is rebased onto the advanced base and the map pairs each rewritten commit by position|pair advance fix fix2|push @wt --set-upstream|0|map2|map:2|head=rebased ahead=2 tree=file.txt:orig,fix.txt:fix,fix2.txt:fix2,main-advanced.txt:advanced remote=origin:head upstream=origin push=- map=hop:map2
a configured copy leaves a linked worktree branch lock under Git ownership|pair-lock advance fix lock-fix|push @wt --set-upstream|0|map2|map:2|head=rebased ahead=2 tree=.kendex-lock.json:branch-lock,file.txt:orig,fix.txt:fix,main-advanced.txt:advanced remote=origin:head upstream=origin push=- lock=branch-lock:clean map=hop:map2
must-fail: without the ownership arm, setup overwrites the linked worktree branch lock|pair-lock advance fix lock-fix unfixed-copy-ownership|push @wt --set-upstream|0|map2|map:2|head=rebased ahead=2 tree=.kendex-lock.json:branch-lock,file.txt:orig,fix.txt:fix,main-advanced.txt:advanced remote=origin:head upstream=origin push=- lock=base-lock:dirty map=hop:map2
a failed worktree index read refuses the copy and preserves the branch lock|pair-lock advance fix lock-fix index-unreadable-wt|push @wt --set-upstream|1|map2|map:2+index-read-wt|head=rebased ahead=2 tree=.kendex-lock.json:branch-lock,file.txt:orig,fix.txt:fix,main-advanced.txt:advanced remote=origin:- upstream=- push=- lock=branch-lock:clean map=hop:map2
a failed main index read refuses the copy and preserves the branch lock|pair-lock advance fix lock-fix index-unreadable-main|push @wt --set-upstream|1|map2|map:2+index-read-main|head=rebased ahead=2 tree=.kendex-lock.json:branch-lock,file.txt:orig,fix.txt:fix,main-advanced.txt:advanced remote=origin:- upstream=- push=- lock=branch-lock:clean map=hop:map2
must-fail: without the checked index read, the failed probe overwrites the branch lock|pair-lock advance fix lock-fix index-unreadable-wt unfixed-index-read|push @wt --set-upstream|0|map2|map:2|head=rebased ahead=2 tree=.kendex-lock.json:branch-lock,file.txt:orig,fix.txt:fix,main-advanced.txt:advanced remote=origin:head upstream=origin push=- lock=base-lock:dirty map=hop:map2
a true standalone clone ignores its stale committed-lock copy setting and pushes after rebase|standalone-clone clone-advance fix lock-fix|push @wt --set-upstream|0|map2|map:2|head=rebased ahead=2 tree=.kendex-lock.json:branch-lock,file.txt:orig,fix.txt:fix,main-advanced.txt:advanced remote=origin:head upstream=origin push=- lock=branch-lock:clean map=hop:map2
must-fail: without the standalone no-op, the same clone copies its local file onto itself|standalone-clone clone-advance fix lock-fix unfixed-standalone-copy|push @wt --set-upstream|1|map2|map:2+copy-failed:local.txt|head=rebased ahead=2 tree=.kendex-lock.json:branch-lock,file.txt:orig,fix.txt:fix,main-advanced.txt:advanced remote=origin:- upstream=- push=- lock=branch-lock:clean map=hop:map2
a setup failure after a successful rebase leaves the map durable and does not push|pair advance fix setup-fails|push @wt --set-upstream|1|map2|map:2+copy-failed:copy-parent/copied.txt|head=rebased ahead=2 tree=copy-parent:blocked,file.txt:orig,fix.txt:fix,main-advanced.txt:advanced remote=origin:- upstream=- push=- map=hop:map2
must-fail: setup before map persistence leaves the successful rewrite unmapped|pair advance fix setup-fails unfixed-map-order|push @wt --set-upstream|1|-|copy-failed:copy-parent/copied.txt|head=rebased ahead=2 tree=copy-parent:blocked,file.txt:orig,fix.txt:fix,main-advanced.txt:advanced remote=origin:- upstream=- push=- map=end
--no-rebase pushes the behind branch where it stands|pair advance fix|push @wt --set-upstream --no-rebase|0|-|-|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:end upstream=origin push=- map=-
an unknown flag is a usage error that pushes and rebases nothing|pair advance fix|push @wt --no-rebse|1|-|unknown:--no-rebse|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=- map=-
flags before the target still make the trailing positional the pushed tree, not the checkout|pair advance fix|push --no-rebase --set-upstream @wt|0|-|-|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:end upstream=origin push=- map=-
push --help, the advertised recovery, prints the push usage|pair fix|push --help|0|usage|-|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=- map=-
a second positional is a usage error|pair fix|push @wt topic|1|-|two:<wt>'"'"' and '"'"'topic|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=- map=-
an empty positional is refused, not resolved to the current checkout|pair fix|push @empty|1|-|empty|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=- map=-
an empty positional before a real one is still refused|pair fix|push @empty @wt|1|-|empty|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=- map=-
an empty positional after a real one is a duplicate, not a silent second target|pair fix|push @wt @empty|1|-|two:<wt>'"'"' and '"'"'|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=- map=-
a commit whose patch main already landed is dropped by the rebase and mapped as dropped|pair dup fix dup-main|push @wt --set-upstream|0|map-dropped|map:2|head=rebased ahead=1 tree=dup.txt:dup,file.txt:orig,fix.txt:fix remote=origin:head upstream=origin push=- map=hop:map-dropped
commits sharing one subject, partly dropped, refuse the push rather than guess which survived|pair twins twins-main|push @wt --set-upstream|1|-|ambiguous+unmapped|head=rebased ahead=1 tree=file.txt:orig,twin-a.txt:a,twin-b.txt:b remote=origin:- upstream=- push=- map=end
a push after an unmapped rewrite refuses on its record rather than publishing it|pair twins twins-main unmapped-push|push @wt --set-upstream|1|-|unmapped-retry|head=end ahead=1 tree=file.txt:orig,twin-a.txt:a,twin-b.txt:b remote=origin:- upstream=- push=- map=unmapped
a rewrite killed before its map reached disk still refuses the next push|pair advance fix killed-rewrite|push @wt --set-upstream|1|-|unmapped-retry|head=end ahead=1 tree=file.txt:orig,fix.txt:fix,main-advanced.txt:advanced remote=origin:- upstream=- push=- map=unmapped
a whole subject group that survives beside a dropped commit still maps|pair twins dup dup-main|push @wt --set-upstream|0|map-group|map:3|head=rebased ahead=2 tree=dup.txt:dup,file.txt:orig,twin-a.txt:a,twin-b.txt:b remote=origin:head upstream=origin push=- map=hop:map-group
an issue ID names the current checkout when it is an issue worktree outside the trees base|outside fix|push TOPIC --no-rebase|0|-|-|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:end upstream=origin push=- map=-
a first push by issue ID creates the remote branch and sets its upstream|pair fix|push TOPIC --set-upstream|0|-|skip-rebase|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:end upstream=origin push=- map=-
an unobserved remote branch is not overwritten by a first push|pair fix foreign|push TOPIC --set-upstream|1|-|skip-rebase+lease-rejected|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:external upstream=- push=- map=-
a rebased push over a published branch replaces the remote under its lease|pair fix publish advance fix2|push TOPIC|0|map2|map:2|head=rebased ahead=2 tree=file.txt:orig,fix.txt:fix,fix2.txt:fix2,main-advanced.txt:advanced remote=origin:head upstream=origin push=- map=hop:map2
a remote moved after the lease was captured is not overwritten|pair fix publish advance fix2 race|push TOPIC|1|map2|map:2+lease-rejected|head=rebased ahead=2 tree=file.txt:orig,fix.txt:fix,fix2.txt:fix2,main-advanced.txt:advanced remote=origin:external upstream=origin push=- map=hop:map2
a remote already observed to diverge is refused before any rebase|pair fix publish move-remote observe fix2|push TOPIC|1|-|not-contained|head=end ahead=2 tree=file.txt:orig,fix.txt:fix,fix2.txt:fix2 remote=origin:external upstream=origin push=- map=-
a lease fetch that fails for a reason other than a missing branch aborts the push|pair fix broken-remote|push TOPIC|1|-|fetch-failed|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=- map=-
the configured bot remote takes the lease and the push|pair bot-remote fix publish advance fix2|push TOPIC|0|map2|map:2|head=rebased ahead=2 tree=file.txt:orig,fix.txt:fix,fix2.txt:fix2,main-advanced.txt:advanced remote=origin:-,bot:head upstream=bot push=- map=hop:map2
the package alone pushes through plain git|github fix standalone|push TOPIC --no-rebase --set-upstream|0|-|-|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=- upstream=- push=-C <wt> push -u origin HEAD:refs/heads/topic map=-
a sibling GitHub helper, when present, owns the git invocation|github fix with-helper|push TOPIC --no-rebase --set-upstream|0|-|-|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=- upstream=- push=-c kendex.test-github-helper=loaded -C <wt> push -u origin HEAD:refs/heads/topic map=-
a pre-push hook refusal is named as one, not as a force-with-lease conflict|pair fix hook-refuses|push TOPIC --set-upstream|1|-|skip-rebase+hook-rejected|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=- map=-
must-fail: with the hook arm cut, the same refusal loses its own record|pair fix unfixed-hook|push TOPIC --set-upstream|1|-|skip-rebase+push-failed|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=- map=-
keyed lines that never reach a verdict are a refusal too, the shape a hook aborts in|pair fix hook-aborts|push TOPIC --set-upstream|1|-|skip-rebase+hook-rejected|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=- map=-
a clean hook leaves the remote its own rejection to explain, under the lease record|pair fix foreign hook-passes|push TOPIC --set-upstream|1|-|skip-rebase+lease-rejected|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:external upstream=- push=- map=-
a composed hook whose consumer half refuses under a clean lane verdict is not a lease conflict|pair fix hook-composed|push TOPIC --set-upstream|1|-|skip-rebase+push-failed|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=- map=-
must-fail: with the lease arm keyed on the absence of a hook verdict, it is told as one|pair fix unfixed-lease|push TOPIC --set-upstream|1|-|skip-rebase+lease-rejected|head=end ahead=1 tree=file.txt:orig,fix.txt:fix remote=origin:- upstream=- push=- map=-
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
  # The state column's trailing map= carries a shape word for the record.
  want_state="${want_state% map=*} map=$(map_text "${want_state##* map=}")"
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
echo "=== a record that cannot be cleared stops before the push ==="

# The record is cleared once the map is on disk, and a clear that cannot be
# performed would publish a branch whose record then refuses every push after
# it. The denial is built so the writes before it still succeed: the map file
# already exists and stays writable, so appending the record and the hop works,
# while the read-only git dir stops the clear, which has to create a temporary
# file beside it. chmod mode bits do not bind root, so the case is probed and
# skipped visibly where it cannot take effect.
build uncleared pair advance fix
uncleared_git_dir="$(git -C "$WT" rev-parse --absolute-git-dir)"
: >"$uncleared_git_dir/kendex-rebase-map"
chmod a-w "$uncleared_git_dir"
if touch "$uncleared_git_dir/.write-probe" 2>/dev/null; then
  rm -f "$uncleared_git_dir/.write-probe"
  chmod u+w "$uncleared_git_dir"
  printf '  skip  %s\n' "uncleared-record case: chmod a-w does not deny writes here (running as root?)"
else
  uncleared_rc=0
  (cd "$MAIN" && "$WORKTREE_SCRIPT" push "$WT" --set-upstream \
    >"$ROOT/uncleared.out" 2>"$ROOT/uncleared.err") || uncleared_rc=$?
  chmod u+w "$uncleared_git_dir"
  assert_eq "$uncleared_rc" "1" "a record that cannot be cleared fails the push"
  assert_eq "$(grep '^worktree-rebase-pending-uncleared:' "$ROOT/uncleared.err" | sed "s|$WT|<wt>|")" \
    "worktree-rebase-pending-uncleared: <wt>" "the refusal names the worktree whose record still stands"
  assert_eq "$(remote_oid origin)" "" "the branch was never published"
  assert_eq "$(grep -c '^rebase-unmapped: ' "$uncleared_git_dir/kendex-rebase-map" || true)" "1" \
    "and the record it could not clear is still there"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
