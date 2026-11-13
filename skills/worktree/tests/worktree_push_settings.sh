#!/usr/bin/env bash
# `worktree push` runs from the main checkout and loads that checkout's
# settings, while git hands its pre-push hook the push's own environment. A
# hook lane resolves a setting from its environment ahead of the pushed tree's
# committed settings, so the push leaves the main checkout's committed values
# out of what git inherits: the lane reads the branch's own value, a value the
# caller exported, or a personal override from the private env file or an
# untracked settings file. `push --prepare-base` folds the item commits with
# the commit hooks running, under the same boundary. The hook
# is the commit-guards resolver itself, reading COMMIT_GUARDS_CHANGELOG_PATHS
# the way the changelog lane does.
set -euo pipefail
# A pre-commit hook exports GIT_DIR and GIT_INDEX_FILE, which point every git
# call below at the real repository; -C overrides neither.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset COMMIT_GUARDS_CHANGELOG_PATHS
# The fixtures' origin is a local path that names no GitHub repository, so
# the suite names the default branch.
export WORKTREE_DEFAULT_BRANCH=main

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PACKAGE_DIR="$(cd "$TEST_DIR/.." && pwd)"
WORKTREE_SCRIPT="$PACKAGE_DIR/scripts/worktree"
SETTINGS_LIB="$(cd "$PACKAGE_DIR/../commit-guards/scripts/lib" && pwd)/settings.sh"
TMP_ROOT="$(mktemp -d)" || { echo "worktree_push_settings: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "worktree_push_settings: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "worktree_push_settings: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/gh" <<'STUB'
#!/usr/bin/env bash
exit 0
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

# Git's background maintenance stays off in a fixture the suite removes, so
# the removal cannot race its writer.
quiet_repo() { # REPO
  git -C "$1" config gc.auto 0
  git -C "$1" config maintenance.auto false
}

# A main checkout whose committed FILE assigns the key `main-value`, or leaves
# it out where MAIN is `-`, its origin, and an issue worktree whose branch
# commits `branch-value` to the same file. The pre-push and pre-commit hooks,
# shared by every worktree, record what the resolver answers from the worktree
# for COMMIT_GUARDS_CHANGELOG_PATHS, or for the key a row writes to hook.key.
build() { # ROOT SETTINGS-FILE MAIN
  local root="$1" file="$2" main="$1/main" wt="$1/trees/topic"
  mkdir -p "$main"
  git -C "$main" init -q -b main
  quiet_repo "$main"
  git -C "$main" config user.email test@example.com
  git -C "$main" config user.name Test
  git -C "$main" config commit.gpgsign false
  mkdir -p "$main/$(dirname "$file")"
  printf '[env]\n' >"$main/$file"
  [[ "$3" == - ]] || printf 'COMMIT_GUARDS_CHANGELOG_PATHS = "%s"\n' "$3" >>"$main/$file"
  git -C "$main" add "$file"
  git -C "$main" commit -q -m base
  printf 'WORKTREE_BASE_DIR="../trees"\n' >"$main/.env.local"
  git init -q --bare "$root/origin.git"
  quiet_repo "$root/origin.git"
  git -C "$main" remote add origin "$root/origin.git"
  git -C "$main" push -q -u origin main
  (cd "$main" && "$WORKTREE_SCRIPT" create topic >/dev/null 2>&1)
  printf '[env]\nCOMMIT_GUARDS_CHANGELOG_PATHS = "branch-value"\n' >"$wt/$file"
  git -C "$wt" commit -q -am 'branch: move the changelog paths'
  cat >"$main/.git/hooks/pre-push" <<HOOK
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
source "$SETTINGS_LIB"
key=COMMIT_GUARDS_CHANGELOG_PATHS
[[ ! -f "$root/hook.key" ]] || key="\$(cat "$root/hook.key")"
gg_setting "\$key" built-in-default >"$root/hook.read"
HOOK
  chmod +x "$main/.git/hooks/pre-push"
  cp "$main/.git/hooks/pre-push" "$main/.git/hooks/pre-commit"
}

# The row's package copy, made once beside a copy of commit-guards, whose
# resolver the hooks run, its script path on stdout.
package_copy() { # ROOT
  [[ -d "$1/pkg/worktree" ]] || {
    mkdir -p "$1/pkg" && cp -R "$PACKAGE_DIR" "$1/pkg/worktree" &&
      cp -R "$PACKAGE_DIR/../commit-guards" "$1/pkg/commit-guards"
  }
  printf '%s' "$1/pkg/worktree/scripts/worktree"
}

# A package copy with one edit applied, its script path on stdout. The edit
# must leave exactly one line holding `: cut`.
cut_copy() { # ROOT SED-EXPRESSION
  local script
  script="$(package_copy "$1")"
  sed -i.bak "$2" "$script"
  rm -f -- "${script:?}.bak"
  [[ "$(grep -c ': cut' "$script" || true)" == 1 ]] || {
    echo "FIXTURE: the edit $2 did not match exactly once in $script" >&2
    exit 2
  }
  printf '%s' "$script"
}

# Each row: label | committed settings file | the main checkout's committed
# value (- for none) | world edits | caller's export (- for none) | the value
# the hook resolved. `local` and `local-export` add a private env file
# override to the main checkout, plain or exported, with the value after the
# colon; `envfile` names .env.private as the private env file in the main
# checkout's kendex.settings.toml and sets the override there;
# `untracked-nested` adds an untracked .kendex/settings.toml override the same
# way; `helper` is a package copy whose sibling GitHub library
# exports the key when sourced, the way that library exports the token it
# resolves; `fold` runs `push --prepare-base`, whose fold commit fires the
# pre-commit hook, in place of the push. The `unfixed` word is the must-fail
# control's world, a package copy with one rule cut. The fixture names no WORKTREE_SYMLINKS, so the
# worktree has no private env file or untracked settings file of its own, and
# an override reaches the hook only through the environment. `key:NAME`, the
# row's first word, makes NAME the key the overrides set and the hook reads.
# `copy` runs the package copy; `no-cg` takes commit-guards from beside it
# and `gh-sibling` puts a copy of github there. The
# `*-unread` words cut the line adding that sibling's names to worktree's
# list, and the `*-unguarded` words cut the check that its list file stands.
# A want that starts with `rc=` is the whole expected outcome.
ROWS='the hook reads the branch'"'"'s committed value, not the main checkout'"'"'s|kendex.settings.toml|main-value|-|-|branch-value
the nested settings file is kept out of the hook the same way|.kendex/settings.toml|main-value|-|-|branch-value
must-fail: with the unexport cut, the hook reads the main checkout'"'"'s value|kendex.settings.toml|main-value|unfixed|-|main-value
a value the caller exported still wins, even when it equals the committed one|kendex.settings.toml|main-value|-|main-value|main-value
a private env file override stays exported, since no branch carries it|kendex.settings.toml|main-value|local:local-value|-|local-value
an exported private env file override equal to the committed value stays exported|kendex.settings.toml|main-value|local-export:main-value|-|main-value
a key only the private env file exports stays exported|kendex.settings.toml|-|local-export:local-value|-|local-value
a private env file the tracked settings name, not .env.local, keeps its override exported|kendex.settings.toml|main-value|envfile:private-value|-|private-value
an untracked settings file is a local override and stays exported|kendex.settings.toml|main-value|untracked-nested:nested-value|-|nested-value
an untracked override equal to the committed value stays exported|kendex.settings.toml|main-value|untracked-nested:main-value|-|main-value
a key a sourced library exports at run time stays exported|kendex.settings.toml|-|helper|-|helper-value
the fold'"'"'s commit hook reads the branch'"'"'s committed value, not the main checkout'"'"'s|kendex.settings.toml|main-value|fold|-|branch-value
a package copy beside commit-guards hands the hook a private env file override of its key|kendex.settings.toml|main-value|copy local:local-value|-|local-value
must-fail: with commit-guards'"'"' names left out of the list, the override never reaches the hook|kendex.settings.toml|main-value|cg-unread local:local-value|-|branch-value
a package copy with no commit-guards beside it hands the hook worktree'"'"'s names alone|kendex.settings.toml|main-value|no-cg local:local-value|-|branch-value
must-fail: with the presence check cut, a copy with no commit-guards stops at its load|kendex.settings.toml|main-value|no-cg cg-unguarded local:local-value|-|rc=1 read=-
github'"'"'s names reach the hook where the github package stands beside worktree|kendex.settings.toml|main-value|key:GH_ISSUE_PATTERN local-export:gh-pattern|-|gh-pattern
a package copy beside github hands the hook a private env file override of github'"'"'s key|kendex.settings.toml|main-value|key:GH_ISSUE_PATTERN gh-sibling local-export:gh-pattern|-|gh-pattern
must-fail: with github'"'"'s names left out of the list, github'"'"'s key never reaches the hook|kendex.settings.toml|main-value|key:GH_ISSUE_PATTERN gh-sibling gh-unread local-export:gh-pattern|-|built-in-default
a package copy with no github beside it leaves github'"'"'s key out|kendex.settings.toml|main-value|key:GH_ISSUE_PATTERN copy local-export:gh-pattern|-|built-in-default
must-fail: with the presence check cut, a copy with no github stops at its load|kendex.settings.toml|main-value|gh-unguarded local:local-value|-|rc=1 read=-'

echo "=== worktree push hands its hooks the branch's settings ==="
n=0
while IFS='|' read -r label file main_value edit caller want; do
  n=$((n + 1))
  root="$TMP_ROOT/row-$n"
  build "$root" "$file" "$main_value"
  script="$WORKTREE_SCRIPT"
  op=(push topic --no-rebase --set-upstream)
  key=COMMIT_GUARDS_CHANGELOG_PATHS
  for word in $edit; do
    case "$word" in
      -) ;;
      key:*) key="${word#*:}"; printf '%s' "$key" >"$root/hook.key" ;;
      local:*) printf '%s="%s"\n' "$key" "${word#*:}" >>"$root/main/.env.local" ;;
      local-export:*) printf 'export %s="%s"\n' "$key" "${word#*:}" >>"$root/main/.env.local" ;;
      envfile:*)
        printf 'KENDEX_ENV_FILE = ".env.private"\n' >>"$root/main/kendex.settings.toml"
        cp "$root/main/.env.local" "$root/main/.env.private"
        printf 'COMMIT_GUARDS_CHANGELOG_PATHS="%s"\n' "${word#*:}" >>"$root/main/.env.private"
        ;;
      untracked-nested:*)
        mkdir -p "$root/main/.kendex"
        printf '[env]\nCOMMIT_GUARDS_CHANGELOG_PATHS = "%s"\n' "${word#*:}" >"$root/main/.kendex/settings.toml"
        ;;
      helper)
        script="$(package_copy "$root")"
        mkdir -p "$root/pkg/github/scripts/lib"
        printf 'export COMMIT_GUARDS_CHANGELOG_PATHS=helper-value\n' >"$root/pkg/github/scripts/lib/gh-auth.sh"
        ;;
      fold) op=(push topic --prepare-base) ;;
      unfixed) script="$(cut_copy "$root" 's/|| export -n "\${COMMITTED_UNEXPORT\[@\]}"$/|| : cut/')" ;;
      copy) script="$(package_copy "$root")" ;;
      no-cg)
        script="$(package_copy "$root")"
        rm -rf -- "${root:?}/pkg/commit-guards"
        ;;
      gh-sibling)
        script="$(package_copy "$root")"
        cp -R "$PACKAGE_DIR/../github" "$root/pkg/github"
        ;;
      cg-unread) script="$(cut_copy "$root" 's/^  WORKTREE_SETTINGS_NAMES+=("\${commit_guards_settings_names\[@\]}")$/  : cut/')" ;;
      gh-unread) script="$(cut_copy "$root" 's/^  WORKTREE_SETTINGS_NAMES+=("\${github_settings_names\[@\]}")$/  : cut/')" ;;
      cg-unguarded) script="$(cut_copy "$root" 's/^if \[\[ -f "\$COMMIT_GUARDS_NAMES_LIB" \]\]; then$/if : cut; then/')" ;;
      gh-unguarded) script="$(cut_copy "$root" 's/^if \[\[ -f "\$GITHUB_NAMES_LIB" \]\]; then$/if : cut; then/')" ;;
      # The phase-two unset loop sits between the tracked snapshot and the
      # first loop that reads it; the clearing loop is the one that reads
      # compgen -e inside committed_settings_keys.
      *) echo "FIXTURE: unknown edit $word" >&2; exit 2 ;;
    esac
  done
  rc=0
  if [[ "$caller" == - ]]; then
    (cd "$root/main" && "$script" "${op[@]}" >"$root/out" 2>&1) || rc=$?
  else
    (cd "$root/main" && COMMIT_GUARDS_CHANGELOG_PATHS="$caller" "$script" "${op[@]}" >"$root/out" 2>&1) || rc=$?
  fi
  [[ "$want" == rc=* ]] || want="rc=0 read=$want"
  [[ "$rc" == 0 || "$want" != rc=0* ]] || sed 's/^/        push: /' "$root/out"
  assert_eq "rc=$rc read=$(cat "$root/hook.read" 2>/dev/null || printf -- -)" "$want" "$label"
done <<<"$ROWS"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
