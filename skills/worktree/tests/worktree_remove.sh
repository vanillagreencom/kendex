#!/usr/bin/env bash
# Regression tests for worktree remove diagnostics and branch cleanup.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKTREE_SCRIPT="$(cd "$TEST_DIR/.." && pwd)/scripts/worktree"
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

assert_remote_branch_exists() {
  local repo="$1" branch="$2" name="$3"
  if git -C "$repo" ls-remote --exit-code --heads origin "$branch" >/dev/null 2>&1; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        missing remote branch: %s\n' "$name" "$branch"
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

echo "=== worktree remove ==="

# Merged/no-extra-commit branch: worktree and branch both disappear, exit 0.
MERGED_ROOT="$TMP_ROOT/merged"
make_repo "$MERGED_ROOT/main"
git -C "$MERGED_ROOT/main" worktree add -q -b issue-merged "$MERGED_ROOT/trees/issue-merged" main
merged_out=$(cd "$MERGED_ROOT/main" && "$WORKTREE_SCRIPT" remove ISSUE-MERGED 2>"$MERGED_ROOT/merged.err")
assert_eq "$merged_out" "Removed: $MERGED_ROOT/trees/issue-merged" "merged branch removal exits cleanly"
assert_path_absent "$MERGED_ROOT/trees/issue-merged" "merged branch worktree removed"
assert_branch_absent "$MERGED_ROOT/main" "issue-merged" "merged branch deleted"

# Unmerged branch: worktree is removed, branch remains, exit 1 includes diagnostic.
UNMERGED_ROOT="$TMP_ROOT/unmerged"
make_repo "$UNMERGED_ROOT/main"
git -C "$UNMERGED_ROOT/main" worktree add -q -b issue-unmerged "$UNMERGED_ROOT/trees/issue-unmerged" main
printf 'branch-only\n' >> "$UNMERGED_ROOT/trees/issue-unmerged/file.txt"
git -C "$UNMERGED_ROOT/trees/issue-unmerged" add file.txt
git -C "$UNMERGED_ROOT/trees/issue-unmerged" commit -q -m 'branch only'
set +e
unmerged_out=$(cd "$UNMERGED_ROOT/main" && "$WORKTREE_SCRIPT" remove ISSUE-UNMERGED 2>"$UNMERGED_ROOT/unmerged.err")
unmerged_code=$?
set -e
assert_eq "$unmerged_code" "1" "unmerged branch removal exits nonzero"
assert_eq "$unmerged_out" "Removed: $UNMERGED_ROOT/trees/issue-unmerged" "unmerged branch still reports removed worktree"
assert_path_absent "$UNMERGED_ROOT/trees/issue-unmerged" "unmerged branch worktree removed"
assert_branch_exists "$UNMERGED_ROOT/main" "issue-unmerged" "unmerged branch retained"
assert_contains "$(cat "$UNMERGED_ROOT/unmerged.err")" "could not delete local branch 'issue-unmerged'" "unmerged branch diagnostic names failed cleanup step"
assert_contains "$(cat "$UNMERGED_ROOT/unmerged.err")" "branch -D \"issue-unmerged\"" "unmerged branch diagnostic gives manual recovery command"

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
WORKTREE_RELATIVE_SYMLINKS=".claude/CLAUDE.md=../AGENTS.md"
ENV
git -C "$LINK_ROOT/main" worktree add -q -b issue-links "$LINK_ROOT/trees/issue-links" main
links_out=$(cd "$LINK_ROOT/main" && "$WORKTREE_SCRIPT" fix-links "$LINK_ROOT/trees/issue-links")
assert_eq "$links_out" "Restored symlinks in $LINK_ROOT/trees/issue-links" "fix-links reports restored symlinks"
assert_symlink_target "$LINK_ROOT/trees/issue-links/.env.local" "$LINK_ROOT/main/.env.local" ".env.local symlink points to main checkout"
assert_symlink_target "$LINK_ROOT/trees/issue-links/.claude/settings.json" "$LINK_ROOT/main/.claude/settings.json" "configured file symlink points to main checkout"
assert_git_status_clean_for_path "$LINK_ROOT/trees/issue-links" ".claude/settings.json" "configured tracked file symlink is hidden from git status"
assert_symlink_target "$LINK_ROOT/trees/issue-links/.claude/agents" "$LINK_ROOT/main/.claude/agents" "configured dir symlink points to main checkout"
assert_symlink_target "$LINK_ROOT/trees/issue-links/.claude/CLAUDE.md" "../AGENTS.md" "relative symlink keeps worktree-local AGENTS target"

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

CODEX_PUSH_ROOT="$TMP_ROOT/codex-push"
make_repo "$CODEX_PUSH_ROOT/main"
git init -q --bare "$CODEX_PUSH_ROOT/origin.git"
git -C "$CODEX_PUSH_ROOT/main" remote add origin "$CODEX_PUSH_ROOT/origin.git"
git -C "$CODEX_PUSH_ROOT/main" push -q -u origin main
cat > "$CODEX_PUSH_ROOT/main/.env.local" <<'ENV'
WORKTREE_BASE_DIR="../registry-trees"
ENV
git -C "$CODEX_PUSH_ROOT/main" worktree add -q -b issue-codex-push "$CODEX_PUSH_ROOT/app-worktrees/issue-codex-push" main
printf 'codex-change\n' >> "$CODEX_PUSH_ROOT/app-worktrees/issue-codex-push/file.txt"
git -C "$CODEX_PUSH_ROOT/app-worktrees/issue-codex-push" add file.txt
git -C "$CODEX_PUSH_ROOT/app-worktrees/issue-codex-push" commit -q -m 'codex push change'
set +e
(
  cd "$CODEX_PUSH_ROOT/app-worktrees/issue-codex-push" && \
    "$WORKTREE_SCRIPT" push ISSUE-CODEX-PUSH --no-rebase >"$CODEX_PUSH_ROOT/codex-push.out" 2>"$CODEX_PUSH_ROOT/codex-push.err"
)
codex_push_code=$?
set -e
assert_eq "$codex_push_code" "0" "push issue ID uses current Codex worktree outside configured registry"
assert_remote_branch_exists "$CODEX_PUSH_ROOT/main" "issue-codex-push" "push issue ID publishes current Codex worktree branch"
assert_path_absent "$CODEX_PUSH_ROOT/registry-trees/issue-codex-push" "push issue ID does not require configured registry path"

GITHUB_PUSH_ROOT="$TMP_ROOT/github-push"
make_repo "$GITHUB_PUSH_ROOT/main"
git -C "$GITHUB_PUSH_ROOT/main" remote add origin git@github.com:owner/repo.git
git -C "$GITHUB_PUSH_ROOT/main" worktree add -q -b issue-github-push "$GITHUB_PUSH_ROOT/trees/issue-github-push" main
printf 'github-change\n' >> "$GITHUB_PUSH_ROOT/trees/issue-github-push/file.txt"
git -C "$GITHUB_PUSH_ROOT/trees/issue-github-push" add file.txt
git -C "$GITHUB_PUSH_ROOT/trees/issue-github-push" commit -q -m 'github push change'
mkdir -p "$GITHUB_PUSH_ROOT/bin"
REAL_GIT="$(command -v git)"
cat > "$GITHUB_PUSH_ROOT/bin/git" <<EOF
#!/usr/bin/env bash
set -euo pipefail
for arg in "\$@"; do
  if [[ "\$arg" == "push" ]]; then
    printf '%s\n' "\$*" >"$GITHUB_PUSH_ROOT/push.args"
    exit 0
  fi
done
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GITHUB_PUSH_ROOT/bin/git"
cat > "$GITHUB_PUSH_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  auth)
    if [[ "${2:-}" == "status" || "${2:-}" == "git-credential" ]]; then
      echo "Logged in"
      exit 0
    fi
    ;;
  api)
    if [[ "${2:-}" == "user" ]]; then
      echo "test-user"
      exit 0
    fi
    ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF
chmod +x "$GITHUB_PUSH_ROOT/bin/gh"
set +e
(
  cd "$GITHUB_PUSH_ROOT/trees/issue-github-push" && \
    PATH="$GITHUB_PUSH_ROOT/bin:$PATH" "$WORKTREE_SCRIPT" push ISSUE-GITHUB-PUSH --no-rebase --set-upstream >"$GITHUB_PUSH_ROOT/github-push.out" 2>"$GITHUB_PUSH_ROOT/github-push.err"
)
github_push_code=$?
set -e
assert_eq "$github_push_code" "0" "push uses gh HTTPS fallback for GitHub SSH remote"
assert_contains "$(cat "$GITHUB_PUSH_ROOT/push.args")" "credential.helper=!gh auth git-credential" "push command installs gh credential helper"
assert_contains "$(cat "$GITHUB_PUSH_ROOT/push.args")" "url.https://github.com/.insteadOf=git@github.com:" "push command rewrites GitHub scp SSH URL"
assert_contains "$(cat "$GITHUB_PUSH_ROOT/push.args")" "push -u origin HEAD:refs/heads/issue-github-push" "push command still targets configured remote branch"

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

# WORKTREE_BASE_DIR can be set in .env or .env.local. Relative values resolve
# from the main checkout; vstack.settings.toml overrides legacy .env, and
# .env.local overrides both. Trailing slashes are ignored.
CONFIG_ROOT="$TMP_ROOT/config"
make_repo "$CONFIG_ROOT/main"
cat > "$CONFIG_ROOT/main/.env" <<'ENV'
WORKTREE_BASE_DIR="../from-env"
ENV
config_path=$(cd "$CONFIG_ROOT/main" && "$WORKTREE_SCRIPT" path ISSUE-CONFIG)
assert_eq "$config_path" "$CONFIG_ROOT/from-env/issue-config" ".env WORKTREE_BASE_DIR controls path"
cat > "$CONFIG_ROOT/main/vstack.settings.toml" <<'TOML'
[env]
WORKTREE_BASE_DIR = "../from-settings"
WORKTREE_MKDIRS = ["tmp", "cache"]
TOML
config_settings_path=$(cd "$CONFIG_ROOT/main" && "$WORKTREE_SCRIPT" path ISSUE-CONFIG)
assert_eq "$config_settings_path" "$CONFIG_ROOT/from-settings/issue-config" "vstack.settings.toml WORKTREE_BASE_DIR overrides .env"
cat > "$CONFIG_ROOT/main/.env.local" <<ENV
WORKTREE_BASE_DIR="$CONFIG_ROOT/from-local/"
ENV
config_local_path=$(cd "$CONFIG_ROOT/main" && "$WORKTREE_SCRIPT" path ISSUE-CONFIG)
assert_eq "$config_local_path" "$CONFIG_ROOT/from-local/issue-config" ".env.local WORKTREE_BASE_DIR overrides .env"

# create uses the configured worktree parent directory, not only the path helper.
CREATE_ROOT="$TMP_ROOT/create-custom"
make_repo "$CREATE_ROOT/main"
cat > "$CREATE_ROOT/main/.env" <<'ENV'
WORKTREE_BASE_DIR="../custom-trees"
ENV
custom_create_out=$(cd "$CREATE_ROOT/main" && "$WORKTREE_SCRIPT" create ISSUE-CUSTOM --from main)
assert_eq "$custom_create_out" "$CREATE_ROOT/custom-trees/issue-custom" "create reports configured WORKTREE_BASE_DIR path"
assert_git_worktree "$CREATE_ROOT/custom-trees/issue-custom" "create writes worktree under configured WORKTREE_BASE_DIR"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
