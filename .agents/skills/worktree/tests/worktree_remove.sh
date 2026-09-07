#!/usr/bin/env bash
# `worktree remove`: the table below. The blocks after it (fix-links, the
# Codex hooks, the configured base directory) are other surfaces that move
# to their own suites as those are reshaped.
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

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        unexpected substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

assert_path_absent() {
  local path="$1" name="$2"
  if [[ ! -e "$path" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        still exists: %s\n' "$name" "$path"
  fi
}

assert_path_exists() {
  local path="$1" name="$2"
  if [[ -e "$path" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing path: %s\n' "$name" "$path"
  fi
}

assert_git_worktree() {
  local path="$1" name="$2"
  if git -C "$path" rev-parse --git-dir >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        not a git worktree: %s\n' "$name" "$path"
  fi
}

assert_symlink_target() {
  local path="$1" want="$2" name="$3"
  if [[ -L "$path" && "$(readlink "$path")" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    local got="<missing>"
    [[ -e "$path" || -L "$path" ]] && got="$(readlink "$path" 2>/dev/null || printf '<not symlink>')"
    printf '  FAIL  %s\n        expected symlink target: %s\n        got:                     %s\n' "$name" "$want" "$got"
  fi
}

assert_git_status_clean_for_path() {
  local repo="$1" path="$2" name="$3"
  local status
  status=$(git -C "$repo" status --short -- "$path")
  if [[ -z "$status" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        git status: %s\n' "$name" "$status"
  fi
}

assert_branch_exists() {
  local repo="$1" branch="$2" name="$3"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing branch: %s\n' "$name" "$branch"
  fi
}

assert_branch_absent() {
  local repo="$1" branch="$2" name="$3"
  if git -C "$repo" show-ref --verify --quiet "refs/heads/$branch"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        branch still exists: %s\n' "$name" "$branch"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
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

# Relative symlinks: create link inside worktree with target resolved from the
# worktree path, not from the main checkout.
LINK_ROOT="$TMP_ROOT/links"
make_repo "$LINK_ROOT/main"
printf 'agents\n' > "$LINK_ROOT/main/AGENTS.md"
mkdir -p "$LINK_ROOT/main/.claude/agents"
printf '{"hooks":{}}\n' > "$LINK_ROOT/main/.claude/settings.json"
git -C "$LINK_ROOT/main" add AGENTS.md .claude/settings.json
git -C "$LINK_ROOT/main" commit -q -m agents
cat > "$LINK_ROOT/main/.env.local" <<'ENV'
WORKTREE_SYMLINKS=".env.local .claude/settings.json .claude/agents"
WORKTREE_RELATIVE_SYMLINKS=".claude/POINTER.md=../AGENTS.md"
ENV
git -C "$LINK_ROOT/main" worktree add -q -b issue-links "$LINK_ROOT/trees/issue-links" main
links_out=$(cd "$LINK_ROOT/main" && "$WORKTREE_SCRIPT" fix-links "$LINK_ROOT/trees/issue-links")
assert_eq "$links_out" "Restored symlinks in $LINK_ROOT/trees/issue-links" "fix-links reports restored symlinks"
assert_symlink_target "$LINK_ROOT/trees/issue-links/.env.local" "$LINK_ROOT/main/.env.local" ".env.local symlink points to main checkout"
assert_symlink_target "$LINK_ROOT/trees/issue-links/.claude/settings.json" "$LINK_ROOT/main/.claude/settings.json" "configured file symlink points to main checkout"
assert_git_status_clean_for_path "$LINK_ROOT/trees/issue-links" ".claude/settings.json" "configured tracked file symlink is hidden from git status"
assert_symlink_target "$LINK_ROOT/trees/issue-links/.claude/agents" "$LINK_ROOT/main/.claude/agents" "configured dir symlink points to main checkout"
assert_symlink_target "$LINK_ROOT/trees/issue-links/.claude/POINTER.md" "../AGENTS.md" "relative symlink keeps worktree-local AGENTS target"

# Codex Desktop owns worktree lifecycle. codex-setup applies project setup to
# an already-created app worktree; codex-cleanup is a non-destructive hook and
# leaves worktree/branch deletion to the app.
CODEX_ROOT="$TMP_ROOT/codex"
make_repo "$CODEX_ROOT/main"
mkdir -p "$CODEX_ROOT/main/config"
printf 'local-config\n' > "$CODEX_ROOT/main/config/local.txt"
printf 'copied-config\n' > "$CODEX_ROOT/main/copied.txt"
cat > "$CODEX_ROOT/main/.env.local" <<'ENV'
WORKTREE_SYMLINKS=".env.local config/local.txt"
WORKTREE_COPIES="copied.txt"
WORKTREE_MKDIRS="tmp/cache"
BOT_NAME="Codex Bot"
BOT_EMAIL="codex@example.com"
ENV
git -C "$CODEX_ROOT/main" worktree add -q -b issue-codex "$CODEX_ROOT/trees/issue-codex" main
codex_setup_out=$(cd "$CODEX_ROOT/main" && "$WORKTREE_SCRIPT" codex-setup "$CODEX_ROOT/trees/issue-codex")
assert_eq "$codex_setup_out" "Configured Codex worktree: $CODEX_ROOT/trees/issue-codex" "codex-setup reports configured worktree"
assert_symlink_target "$CODEX_ROOT/trees/issue-codex/.env.local" "$CODEX_ROOT/main/.env.local" "codex-setup links .env.local"
assert_symlink_target "$CODEX_ROOT/trees/issue-codex/config/local.txt" "$CODEX_ROOT/main/config/local.txt" "codex-setup links configured file"
assert_path_exists "$CODEX_ROOT/trees/issue-codex/tmp/cache" "codex-setup creates configured mkdir"
assert_eq "$(cat "$CODEX_ROOT/trees/issue-codex/copied.txt")" "copied-config" "codex-setup copies configured file"
assert_eq "$(git -C "$CODEX_ROOT/trees/issue-codex" config --worktree user.name)" "Codex Bot" "codex-setup configures worktree user.name"
assert_eq "$(git -C "$CODEX_ROOT/trees/issue-codex" config --worktree user.email)" "codex@example.com" "codex-setup configures worktree user.email"
codex_cleanup_out=$(cd "$CODEX_ROOT/main" && "$WORKTREE_SCRIPT" codex-cleanup "$CODEX_ROOT/trees/issue-codex")
assert_eq "$codex_cleanup_out" "Codex cleanup hook complete; app owns worktree deletion: $CODEX_ROOT/trees/issue-codex" "codex-cleanup reports app-owned deletion"
assert_symlink_target "$CODEX_ROOT/trees/issue-codex/.env.local" "$CODEX_ROOT/main/.env.local" "codex-cleanup leaves configured symlink intact"
assert_git_worktree "$CODEX_ROOT/trees/issue-codex" "codex-cleanup leaves worktree for app deletion"
assert_branch_exists "$CODEX_ROOT/main" "issue-codex" "codex-cleanup leaves branch for app deletion"
assert_eq "$(git -C "$CODEX_ROOT/trees/issue-codex" status --short)" "" "codex-cleanup leaves worktree clean"

CODEX_BRANCH_ROOT="$TMP_ROOT/codex-branch"
make_repo "$CODEX_BRANCH_ROOT/main"
cat > "$CODEX_BRANCH_ROOT/main/.env.local" <<'ENV'
WORKTREE_MKDIRS="tmp"
ENV
git -C "$CODEX_BRANCH_ROOT/main" worktree add -q -b app-managed-branch "$CODEX_BRANCH_ROOT/trees/app-managed" main
codex_branch_out=$(cd "$CODEX_BRANCH_ROOT/main" && "$WORKTREE_SCRIPT" codex-branch CC-999 "$CODEX_BRANCH_ROOT/trees/app-managed")
assert_eq "$codex_branch_out" "Codex worktree branch ready: cc-999 ($CODEX_BRANCH_ROOT/trees/app-managed)" "codex-branch reports normalized branch"
assert_eq "$(git -C "$CODEX_BRANCH_ROOT/trees/app-managed" branch --show-current)" "cc-999" "codex-branch renames app branch to issue branch"
assert_branch_absent "$CODEX_BRANCH_ROOT/main" "app-managed-branch" "codex-branch removes old app branch name"
assert_path_exists "$CODEX_BRANCH_ROOT/trees/app-managed/tmp" "codex-branch reapplies setup after branch normalization"

# .env.local is not special-cased. It is only linked when listed in
# WORKTREE_SYMLINKS.
NOENV_ROOT="$TMP_ROOT/noenv"
make_repo "$NOENV_ROOT/main"
cat > "$NOENV_ROOT/main/.env.local" <<'ENV'
WORKTREE_SYMLINKS=""
ENV
git -C "$NOENV_ROOT/main" worktree add -q -b issue-noenv "$NOENV_ROOT/trees/issue-noenv" main
noenv_out=$(cd "$NOENV_ROOT/main" && "$WORKTREE_SCRIPT" fix-links "$NOENV_ROOT/trees/issue-noenv")
assert_eq "$noenv_out" "Restored symlinks in $NOENV_ROOT/trees/issue-noenv" "fix-links works without .env.local symlink"
assert_path_absent "$NOENV_ROOT/trees/issue-noenv/.env.local" ".env.local not linked unless configured"

# WORKTREE_BASE_DIR can be set in kendex.settings.toml [env] or .env.local.
# Relative values resolve from the main checkout; a .env file is read by
# nothing, and .env.local overrides the settings files. Trailing slashes are
# ignored.
CONFIG_ROOT="$TMP_ROOT/config"
make_repo "$CONFIG_ROOT/main"
cat > "$CONFIG_ROOT/main/.env" <<'ENV'
WORKTREE_BASE_DIR="../from-env"
ENV
config_path=$(cd "$CONFIG_ROOT/main" && "$WORKTREE_SCRIPT" path ISSUE-CONFIG)
assert_eq "$config_path" "$CONFIG_ROOT/.worktrees/main/issue-config" "a .env WORKTREE_BASE_DIR is ignored; the default path stands"
cat > "$CONFIG_ROOT/main/kendex.settings.toml" <<'TOML'
[env]
WORKTREE_BASE_DIR = "../from-settings"
WORKTREE_MKDIRS = "tmp cache"
TOML
config_settings_path=$(cd "$CONFIG_ROOT/main" && "$WORKTREE_SCRIPT" path ISSUE-CONFIG)
assert_eq "$config_settings_path" "$CONFIG_ROOT/from-settings/issue-config" "kendex.settings.toml WORKTREE_BASE_DIR applies while the .env value stays ignored"
cat > "$CONFIG_ROOT/main/.env.local" <<ENV
WORKTREE_BASE_DIR="$CONFIG_ROOT/from-local/"
ENV
config_local_path=$(cd "$CONFIG_ROOT/main" && "$WORKTREE_SCRIPT" path ISSUE-CONFIG)
assert_eq "$config_local_path" "$CONFIG_ROOT/from-local/issue-config" ".env.local WORKTREE_BASE_DIR overrides kendex.settings.toml"

# create uses the configured worktree parent directory, not only the path helper.
CREATE_ROOT="$TMP_ROOT/create-custom"
make_repo "$CREATE_ROOT/main"
git init -q --bare "$CREATE_ROOT/origin.git"
git -C "$CREATE_ROOT/main" remote add origin "$CREATE_ROOT/origin.git"
git -C "$CREATE_ROOT/main" push -q -u origin main
mkdir -p "$CREATE_ROOT/bin"
cat >"$CREATE_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}:${2:-}" in
  pr:list) ;;
esac
STUB
chmod +x "$CREATE_ROOT/bin/gh"
cat > "$CREATE_ROOT/main/.env.local" <<'ENV'
WORKTREE_BASE_DIR="../custom-trees"
ENV
custom_create_out=$(cd "$CREATE_ROOT/main" && PATH="$CREATE_ROOT/bin:$PATH" "$WORKTREE_SCRIPT" create ISSUE-CUSTOM --from main)
assert_eq "$custom_create_out" "$CREATE_ROOT/custom-trees/issue-custom" "create reports configured WORKTREE_BASE_DIR path"
assert_git_worktree "$CREATE_ROOT/custom-trees/issue-custom" "create writes worktree under configured WORKTREE_BASE_DIR"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
