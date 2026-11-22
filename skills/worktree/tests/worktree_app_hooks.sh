#!/usr/bin/env bash
# The app-owned worktree hooks. Given a PATH, the setup hooks (`codex-setup`,
# `claude-setup`) apply the project's configured setup (links, copies,
# directories, the bot identity) to a worktree the app already made and
# refuse the main checkout; `codex-branch` renames the app's branch to the
# issue branch and reapplies the setup; the cleanup hooks (`codex-cleanup`,
# `claude-cleanup`) leave the worktree, its branch and its links for the app
# to delete. Given no PATH, `claude-setup` and `claude-cleanup` are Claude
# Code's WorktreeCreate and WorktreeRemove hooks, which replace Claude Code's
# own creation and removal: they read the hook's JSON on stdin, create (or
# reopen) the tree and print its path last, and remove the tree. One table, a
# row per scenario: the fixture is a word list of steps that builds a checkout
# with its bare origin and configured setup, registers the worktree the way
# the app does, writes the hook input, and shapes it; the command runs from
# the checkout with that input on stdin, and the
# row pins its exit status, its stdout, its stderr and what is left: every
# entry of the worktree (a link with its target, a file with its first line,
# an empty directory), the worktree's branch and identity, git's status of
# it, whether it is still registered, and the checkout's branches.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/messages.sh
source "$TEST_DIR/lib/messages.sh"
WORKTREE_SCRIPT="${WORKTREE_SCRIPT:-$(cd "$TEST_DIR/.." && pwd)/scripts/worktree}"
TMP_ROOT="$(mktemp -d)" || { echo "worktree_app_hooks: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "worktree_app_hooks: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "worktree_app_hooks: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

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

# gh is quiet: no row asks about a pull request.
mkdir -p "$TMP_ROOT/bin"
printf '#!/usr/bin/env bash\nexit 0\n' >"$TMP_ROOT/bin/gh"
chmod +x "$TMP_ROOT/bin/gh"
export PATH="$TMP_ROOT/bin:$PATH"

# --- fixtures -----------------------------------------------------------------
# Every row's world lives under its own ROOT: the checkout at ROOT/main, its
# bare origin (what codex-branch's fetch and its remote-branch lookup traverse),
# and the worktree at ROOT/trees/<id>.

ROOT=""
MAIN=""
WT=""
TREE_BASE=""

make_repo() {
  mkdir -p "$MAIN"
  git -C "$MAIN" init -q -b main
  git -C "$MAIN" config user.email test@example.com
  git -C "$MAIN" config user.name Test
  git -C "$MAIN" config commit.gpgsign false
  git -C "$MAIN" config gc.auto 0
  git -C "$MAIN" config maintenance.auto false
  printf 'base\n' >"$MAIN/base.txt"
  git -C "$MAIN" add base.txt
  git -C "$MAIN" commit -q -m base
  git init -q --bare "$ROOT/origin.git"
  git -C "$MAIN" remote add origin "$ROOT/origin.git"
  git -C "$MAIN" push -q -u origin main
  # A clone records origin's HEAD; create reads the default branch from it.
  git -C "$MAIN" remote set-head origin main >/dev/null
}

must() {
  "$@" || { echo "FIXTURE: '$*' failed in $ROOT" >&2; exit 2; }
}

# The step vocabulary. `repo` builds the world; the rest shape it.
step() {
  case "$1" in
    repo) make_repo ;;
    # The project's configured setup: a file link, a nested file link, a copy,
    # a directory and the bot identity.
    setup-config)
      mkdir -p "$MAIN/config"
      printf 'local-config\n' >"$MAIN/config/local.txt"
      printf 'copied-config\n' >"$MAIN/copied.txt"
      printf 'WORKTREE_SYMLINKS=".env.local config/local.txt"\nWORKTREE_COPIES="copied.txt"\nWORKTREE_MKDIRS="tmp/cache"\nBOT_NAME="Codex Bot"\nBOT_EMAIL="codex@example.com"\n' >"$MAIN/.env.local"
      ;;
    mkdir-config) printf 'WORKTREE_MKDIRS="tmp"\n' >"$MAIN/.env.local" ;;
    # A setup command that fails on every attempt.
    setup-fail-config) printf 'WORKTREE_SETUP_CMD="exit 1"\n' >"$MAIN/.env.local" ;;
    # A setup command that fails on its first attempt and installs on the next.
    setup-retry-config) printf 'WORKTREE_SETUP_CMD='"'"'if [ -e %s/attempted ]; then printf ready >deps-ready; else : >%s/attempted; exit 1; fi'"'"'\n' "$ROOT" "$ROOT" >"$MAIN/.env.local" ;;
    # The base dir is an in-repository link to a directory outside the checkout.
    symlinked-base)
      mkdir -p "$ROOT/real-trees"
      ln -s "$ROOT/real-trees" "$MAIN/trees"
      printf 'WORKTREE_BASE_DIR="trees"\n' >"$MAIN/.env.local"
      TREE_BASE="$ROOT/real-trees"
      ;;
    # The worktree as the app registers it: a bare git worktree on a branch of
    # the app's naming, no setup applied.
    app-wt:*)
      WT="$ROOT/trees/${1#app-wt:}"
      must git -C "$MAIN" worktree add -q -b "${1#app-wt:}" "$WT" main
      ;;
    # Claude Code's hook input, as its hooks reference shows it. WorktreeCreate
    # names the tree; the tree it makes is the one `create <name>` makes,
    # under the base dir, at its physical path. `create-input:NAME=TREE`
    # names the tree a NAME outside the issue-ID alphabet maps to.
    create-input:*=*)
      local spec="${1#create-input:}"
      WT="$TREE_BASE/${spec#*=}"
      printf '{"session_id":"s","cwd":"%s","hook_event_name":"WorktreeCreate","name":"%s"}\n' "$MAIN" "${spec%%=*}" >"$ROOT/stdin"
      ;;
    create-input:*)
      WT="$TREE_BASE/$(printf '%s' "${1#create-input:}" | tr '[:upper:]' '[:lower:]')"
      printf '{"session_id":"s","cwd":"%s","hook_event_name":"WorktreeCreate","name":"%s"}\n' "$MAIN" "${1#create-input:}" >"$ROOT/stdin"
      ;;
    remove-input) printf '{"session_id":"s","cwd":"%s","hook_event_name":"WorktreeRemove","worktree_path":"%s"}\n' "$MAIN" "$WT" >"$ROOT/stdin" ;;
    empty-input)
      WT="$ROOT/.worktrees/main/unnamed"
      printf '{"session_id":"s","hook_event_name":"WorktreeCreate"}\n' >"$ROOT/stdin"
      ;;
    # The create hook already ran for that name, as when Claude Code reopens it.
    hook-created) (cd "$MAIN" && "$WORKTREE_SCRIPT" claude-setup <"$ROOT/stdin" >/dev/null 2>&1) || { echo "FIXTURE: claude-setup hook failed in $ROOT" >&2; exit 2; } ;;
    # The create hook ran for that name and its setup command failed, so
    # Claude Code started no session there.
    hook-setup-failed)
      local rc=0
      (cd "$MAIN" && "$WORKTREE_SCRIPT" claude-setup <"$ROOT/stdin" >/dev/null 2>&1) || rc=$?
      [[ "$rc" -eq 1 ]] || { echo "FIXTURE: claude-setup hook exited $rc, not 1, in $ROOT" >&2; exit 2; }
      ;;
    # The setup applied by the fixture, so a cleanup row starts from a configured worktree.
    configured) (cd "$MAIN" && "$WORKTREE_SCRIPT" codex-setup "$WT" >/dev/null 2>&1) || { echo "FIXTURE: codex-setup failed in $ROOT" >&2; exit 2; } ;;
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
  WT=""
  TREE_BASE="$ROOT/.worktrees/main"
  mkdir -p "$ROOT"
  for word in "$@"; do
    step "$word"
  done
}

# --- rendering ------------------------------------------------------------------

alias_text() {
  message_records |
  sed -e "s|$WT|<wt>|g" -e "s|$MAIN|<main>|g" -e "s|$ROOT|<root>|g" -e "s|$WORKTREE_SCRIPT|<worktree>|g" |
    paste -s -d ';' -
}

# Every entry of the worktree (a link with its target, a file with its first
# line, an empty directory; git's own file left out, links not followed), the
# worktree's branch and per-worktree identity, git's status of it, whether the
# checkout still registers it, and the checkout's branches besides main.
state() {
  local entries="" wt_status="" branch="" identity="" registered="" branches="" path
  branches="$(git -C "$MAIN" for-each-ref --format='%(refname:short)' refs/heads | grep -vx main | paste -s -d ',' -)"
  if [[ ! -e "$WT" && ! -L "$WT" ]]; then
    registered=no
    git -C "$MAIN" worktree list --porcelain | grep -qxF "worktree $WT" && registered=yes
    printf 'wt=<absent> registered=%s branches=%s' "$registered" "${branches:--}"
    return
  fi
  entries="$(cd "$WT" && find . -mindepth 1 \( -path ./.git -prune \) -o \( -type f -o -type l -o \( -type d -empty \) \) -print | LC_ALL=C sort | while IFS= read -r path; do
    if [[ -L "$path" ]]; then printf '%s->%s,' "${path#./}" "$(readlink "$path" | sed -e "s|$MAIN|<main>|" -e "s|$ROOT|<root>|")"
    elif [[ -d "$path" ]]; then printf '%s/,' "${path#./}"
    else printf '%s:%s,' "${path#./}" "$(head -1 "$path")"; fi
  done | sed 's/,$//')"
  branch="$(git -C "$WT" branch --show-current 2>/dev/null)"
  identity="$(git -C "$WT" config --worktree user.name 2>/dev/null) <$(git -C "$WT" config --worktree user.email 2>/dev/null)>"
  [[ "$identity" != " <>" ]] || identity=-
  if wt_status="$(git -C "$WT" status --porcelain 2>/dev/null)"; then
    wt_status="$(paste -s -d ',' - <<<"$wt_status")"
  else
    wt_status='<git-failed>'
  fi
  registered=no
  git -C "$MAIN" worktree list --porcelain | grep -qxF "worktree $WT" && registered=yes
  printf 'wt=%s branch=%s identity=%s wt-status=%s registered=%s branches=%s' "${entries:--}" "${branch:--}" "$identity" "${wt_status:--}" "$registered" "${branches:--}"
}

run() {
  local -a argv
  local rc=0
  local spec="${1//<wt>/$WT}"
  read -r -a argv <<<"${spec//<main>/$MAIN}"
  local input=/dev/null
  [[ ! -e "$ROOT/stdin" ]] || input="$ROOT/stdin"
  (cd "$MAIN" && LC_ALL=C "$WORKTREE_SCRIPT" "${argv[@]}" <"$input" >"$ROOT/out" 2>"$ROOT/err") || rc=$?
  printf 'rc=%s out=%s err=%s %s' "$rc" "$(alias_text <"$ROOT/out")" "$(alias_text <"$ROOT/err")" "$(state)"
}

# --- the expected text ----------------------------------------------------------

# The production text, held once.
err_text() {
  case "$1" in
    -) printf '' ;;
    main-checkout) printf 'worktree-path-main: <main>' ;;
    claude-configured) printf 'worktree-claude-configured: <wt>' ;;
    setup-failed) printf 'worktree-setup-command-failed: path=<wt> status=1' ;;
    hook-input:*) printf 'worktree-claude-hook-input-unreadable: field=%s' "${1#hook-input:}" ;;
    name-unmappable:*) printf 'worktree-claude-name-unmappable: %s' "${1#name-unmappable:}" ;;
    branch-deleted:*) printf 'worktree-branch-deleted: %s' "${1#branch-deleted:}" ;;
    *) printf 'UNKNOWN-ERR-SPEC:%s' "$1" ;;
  esac
}

out_text() {
  case "$1" in
    -) printf '' ;;
    codex-configured) printf 'worktree-codex-configured: <wt>' ;;
    claude-configured) printf 'worktree-claude-configured: <wt>' ;;
    codex-cleaned) printf 'worktree-codex-cleanup: <wt>' ;;
    claude-cleaned) printf 'worktree-claude-cleanup: <wt>' ;;
    # Claude Code reads a WorktreeCreate command hook's last stdout line as
    # the path of the tree it enters.
    path) printf '<wt>' ;;
    removed) printf 'worktree-removed: <wt>' ;;
    branch-ready:*) printf 'worktree-codex-branch-ready: %s' "${1#branch-ready:}" ;;
    *) printf 'UNKNOWN-OUT-SPEC:%s' "$1" ;;
  esac
}

# --- the rows ---------------------------------------------------------------------
# label|fixture|command|rc|out|err|state
ROWS='codex-setup applies the configured links, copy, directory and bot identity to an app-made worktree|repo setup-config app-wt:issue-codex|codex-setup <wt>|0|codex-configured|-|wt=.env.local-><main>/.env.local,base.txt:base,config/local.txt-><main>/config/local.txt,copied.txt:copied-config,tmp/cache/ branch=issue-codex identity=Codex Bot <codex@example.com> wt-status=- registered=yes branches=issue-codex
codex-cleanup leaves the worktree, its branch and its links for the app|repo setup-config app-wt:issue-codex configured|codex-cleanup <wt>|0|codex-cleaned|-|wt=.env.local-><main>/.env.local,base.txt:base,config/local.txt-><main>/config/local.txt,copied.txt:copied-config,tmp/cache/ branch=issue-codex identity=Codex Bot <codex@example.com> wt-status=- registered=yes branches=issue-codex
codex-branch renames the app branch to the issue branch and reapplies the setup|repo mkdir-config app-wt:app-managed-branch|codex-branch CC-999 <wt>|0|branch-ready:cc-999|-|wt=base.txt:base,tmp/ branch=cc-999 identity=- wt-status=- registered=yes branches=cc-999
claude-setup applies the configured setup like codex-setup|repo setup-config app-wt:issue-claude|claude-setup <wt>|0|claude-configured|-|wt=.env.local-><main>/.env.local,base.txt:base,config/local.txt-><main>/config/local.txt,copied.txt:copied-config,tmp/cache/ branch=issue-claude identity=Codex Bot <codex@example.com> wt-status=- registered=yes branches=issue-claude
claude-setup refuses the main checkout|repo app-wt:issue-claude|claude-setup <main>|1|-|main-checkout|wt=base.txt:base branch=issue-claude identity=- wt-status=- registered=yes branches=issue-claude
codex-setup refuses the main checkout|repo app-wt:issue-codex|codex-setup <main>|1|-|main-checkout|wt=base.txt:base branch=issue-codex identity=- wt-status=- registered=yes branches=issue-codex
claude-cleanup leaves the links in place|repo setup-config app-wt:issue-claude configured|claude-cleanup <wt>|0|claude-cleaned|-|wt=.env.local-><main>/.env.local,base.txt:base,config/local.txt-><main>/config/local.txt,copied.txt:copied-config,tmp/cache/ branch=issue-claude identity=Codex Bot <codex@example.com> wt-status=- registered=yes branches=issue-claude
claude-setup as the WorktreeCreate hook creates the named tree with the setup and prints its path last|repo setup-config create-input:bold-oak-a3f2|claude-setup|0|path|-|wt=.env.local-><main>/.env.local,base.txt:base,config/local.txt-><main>/config/local.txt,copied.txt:copied-config,tmp/cache/ branch=bold-oak-a3f2 identity=Codex Bot <codex@example.com> wt-status=- registered=yes branches=bold-oak-a3f2
claude-setup as the WorktreeCreate hook reopens the tree its name already has|repo setup-config create-input:bold-oak-a3f2 hook-created|claude-setup|0|path|claude-configured|wt=.env.local-><main>/.env.local,base.txt:base,config/local.txt-><main>/config/local.txt,copied.txt:copied-config,tmp/cache/ branch=bold-oak-a3f2 identity=Codex Bot <codex@example.com> wt-status=- registered=yes branches=bold-oak-a3f2
claude-setup as the WorktreeCreate hook reruns a failed setup command when Claude Code reopens the name|repo setup-retry-config create-input:bold-oak-a3f2 hook-setup-failed|claude-setup|0|path|claude-configured|wt=base.txt:base,deps-ready:ready branch=bold-oak-a3f2 identity=- wt-status=?? deps-ready registered=yes branches=bold-oak-a3f2
claude-setup as the WorktreeCreate hook fails when the setup command fails again on reopen|repo setup-fail-config create-input:bold-oak-a3f2 hook-setup-failed|claude-setup|1|-|setup-failed|wt=base.txt:base branch=bold-oak-a3f2 identity=- wt-status=- registered=yes branches=bold-oak-a3f2
claude-setup as the WorktreeCreate hook prints the physical path of a tree it creates behind a symlinked base dir|repo symlinked-base create-input:bold-oak-a3f2|claude-setup|0|path|-|wt=base.txt:base branch=bold-oak-a3f2 identity=- wt-status=- registered=yes branches=bold-oak-a3f2
claude-setup as the WorktreeCreate hook prints the physical path of a tree it reopens behind a symlinked base dir|repo symlinked-base create-input:bold-oak-a3f2 hook-created|claude-setup|0|path|claude-configured|wt=base.txt:base branch=bold-oak-a3f2 identity=- wt-status=- registered=yes branches=bold-oak-a3f2
claude-setup as the WorktreeCreate hook maps a slashed name onto a tree it creates|repo create-input:feature/auth=feature-auth|claude-setup|0|path|-|wt=base.txt:base branch=feature-auth identity=- wt-status=- registered=yes branches=feature-auth
claude-setup as the WorktreeCreate hook maps a slashed name onto the tree it reopens|repo create-input:feature/auth=feature-auth hook-created|claude-setup|0|path|claude-configured|wt=base.txt:base branch=feature-auth identity=- wt-status=- registered=yes branches=feature-auth
claude-setup as the WorktreeCreate hook maps a name that starts with a dot onto a tree it creates|repo create-input:.hidden=hidden|claude-setup|0|path|-|wt=base.txt:base branch=hidden identity=- wt-status=- registered=yes branches=hidden
claude-setup as the WorktreeCreate hook maps a name that starts with a dot onto the tree it reopens|repo create-input:.hidden=hidden hook-created|claude-setup|0|path|claude-configured|wt=base.txt:base branch=hidden identity=- wt-status=- registered=yes branches=hidden
claude-setup as the WorktreeCreate hook maps a name that starts with an underscore onto a tree it creates|repo create-input:_scratch=scratch|claude-setup|0|path|-|wt=base.txt:base branch=scratch identity=- wt-status=- registered=yes branches=scratch
claude-setup as the WorktreeCreate hook maps a name that starts with an underscore onto the tree it reopens|repo create-input:_scratch=scratch hook-created|claude-setup|0|path|claude-configured|wt=base.txt:base branch=scratch identity=- wt-status=- registered=yes branches=scratch
claude-setup as the WorktreeCreate hook maps a name with two dots onto a tree it creates|repo create-input:v1..2=v1-2|claude-setup|0|path|-|wt=base.txt:base branch=v1-2 identity=- wt-status=- registered=yes branches=v1-2
claude-setup as the WorktreeCreate hook maps a name with two dots onto the tree it reopens|repo create-input:v1..2=v1-2 hook-created|claude-setup|0|path|claude-configured|wt=base.txt:base branch=v1-2 identity=- wt-status=- registered=yes branches=v1-2
claude-setup as the WorktreeCreate hook refuses a name with no letter or digit|repo create-input:_=-|claude-setup|1|-|name-unmappable:_|wt=<absent> registered=no branches=-
claude-setup as the WorktreeCreate hook refuses input without a name|repo empty-input|claude-setup|1|-|hook-input:name|wt=<absent> registered=no branches=-
claude-cleanup as the WorktreeRemove hook removes the tree and its merged branch|repo create-input:bold-oak-a3f2 hook-created remove-input|claude-cleanup|0|removed|branch-deleted:bold-oak-a3f2|wt=<absent> registered=no branches=-
'

echo "=== the app-owned worktree hooks ==="
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
