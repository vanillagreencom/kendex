#!/usr/bin/env bash
# `worktree push` runs from the main checkout and loads that checkout's
# settings, while git hands its pre-push hook the push's own environment. A
# hook lane resolves a setting from its environment ahead of the pushed tree's
# committed settings, so the push leaves the main checkout's committed values
# out of what git inherits: the lane reads the branch's own value, a value the
# caller exported, or a personal override from the private env file or an
# untracked settings file. The hook
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
# commits `branch-value` to the same file. The pre-push hook, shared by every
# worktree, records what the resolver answers from the pushed worktree.
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
gg_setting COMMIT_GUARDS_CHANGELOG_PATHS built-in-default >"$root/hook.read"
HOOK
  chmod +x "$main/.git/hooks/pre-push"
}

# The row's package copy, made once, its script path on stdout.
package_copy() { # ROOT
  [[ -d "$1/pkg/worktree" ]] || { mkdir -p "$1/pkg" && cp -R "$PACKAGE_DIR" "$1/pkg/worktree"; }
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
# resolves. Each `unfixed` word is a must-fail control's world, a package
# copy with one rule cut. The fixture names no WORKTREE_SYMLINKS, so the
# worktree has no private env file or untracked settings file of its own, and
# an override reaches the hook only through the environment.
ROWS='the hook reads the branch'"'"'s committed value, not the main checkout'"'"'s|kendex.settings.toml|main-value|-|-|branch-value
the nested settings file is kept out of the hook the same way|.kendex/settings.toml|main-value|-|-|branch-value
must-fail: with the unexport cut, the hook reads the main checkout'"'"'s value|kendex.settings.toml|main-value|unfixed|-|main-value
a value the caller exported still wins, even when it equals the committed one|kendex.settings.toml|main-value|-|main-value|main-value
must-fail: with the caller check cut, that export is dropped for the branch'"'"'s value|kendex.settings.toml|main-value|unfixed-caller|main-value|branch-value
a private env file override stays exported, since no branch carries it|kendex.settings.toml|main-value|local:local-value|-|local-value
an exported private env file override equal to the committed value stays exported|kendex.settings.toml|main-value|local-export:main-value|-|main-value
must-fail: with the private env file layer cut, that override is dropped for the branch'"'"'s value|kendex.settings.toml|main-value|local-export:main-value unfixed-private|-|branch-value
a key only the private env file exports stays exported|kendex.settings.toml|-|local-export:local-value|-|local-value
a private env file the tracked settings name, not .env.local, keeps its override exported|kendex.settings.toml|main-value|envfile:private-value|-|private-value
an untracked settings file is a local override and stays exported|kendex.settings.toml|main-value|untracked-nested:nested-value|-|nested-value
an untracked override equal to the committed value stays exported|kendex.settings.toml|main-value|untracked-nested:main-value|-|main-value
must-fail: with the tracked check cut, the untracked override is dropped for the branch'"'"'s value|kendex.settings.toml|main-value|untracked-nested:nested-value unfixed-tracked|-|branch-value
a key a sourced library exports at run time stays exported|kendex.settings.toml|-|helper|-|helper-value
must-fail: with the subshell clearing cut, that key is dropped for the branch'"'"'s value|kendex.settings.toml|-|helper unfixed-clear|-|branch-value'

echo "=== worktree push hands its hooks the branch's settings ==="
n=0
while IFS='|' read -r label file main_value edit caller want; do
  n=$((n + 1))
  root="$TMP_ROOT/row-$n"
  build "$root" "$file" "$main_value"
  script="$WORKTREE_SCRIPT"
  for word in $edit; do
    case "$word" in
      -) ;;
      local:*) printf 'COMMIT_GUARDS_CHANGELOG_PATHS="%s"\n' "${word#*:}" >>"$root/main/.env.local" ;;
      local-export:*) printf 'export COMMIT_GUARDS_CHANGELOG_PATHS="%s"\n' "${word#*:}" >>"$root/main/.env.local" ;;
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
      unfixed) script="$(cut_copy "$root" 's/|| export -n "\${PUSH_UNEXPORT\[@\]}"$/|| : cut/')" ;;
      # The phase-two unset loop sits between the tracked snapshot and the
      # first loop that reads it; the clearing loop is the one that reads
      # compgen -e inside committed_settings_keys.
      unfixed-caller) script="$(cut_copy "$root" '/^  tracked="\$(compgen -e)"$/,/^  done <<<"\$tracked"$/s/caller_exported "\$name" || unset/: cut; unset/')" ;;
      unfixed-clear) script="$(cut_copy "$root" '/^committed_settings_keys() ($/,/^  done < <(compgen -e)$/s/caller_exported "\$name" || unset "\$name"$/: cut/')" ;;
      unfixed-tracked) script="$(cut_copy "$root" 's/^      1) untracked+=("\$file") ;;$/      1) : cut; kendex_load_settings_file "$PROJECT_ROOT\/$file" ;;/')" ;;
      unfixed-private) script="$(cut_copy "$root" 's/^  kendex_source_env_file "\$PROJECT_ROOT\/\$private" || exit 1$/  : cut/')" ;;
      *) echo "FIXTURE: unknown edit $word" >&2; exit 2 ;;
    esac
  done
  rc=0
  if [[ "$caller" == - ]]; then
    (cd "$root/main" && "$script" push topic --no-rebase --set-upstream >"$root/out" 2>&1) || rc=$?
  else
    (cd "$root/main" && COMMIT_GUARDS_CHANGELOG_PATHS="$caller" "$script" push topic --no-rebase --set-upstream >"$root/out" 2>&1) || rc=$?
  fi
  [[ "$rc" == 0 ]] || sed 's/^/        push: /' "$root/out"
  assert_eq "rc=$rc read=$(cat "$root/hook.read" 2>/dev/null || printf -- -)" "rc=0 read=$want" "$label"
done <<<"$ROWS"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
