#!/usr/bin/env bash
# The settings scripts/commit-msg judges a commit by, read as the hook lane
# reads them: a tracked source resolves from the INDEX so an unstaged edit
# cannot loosen the committed policy, an untracked one is the worktree copy,
# a source outside the repository is the worktree copy too, a spelling that
# normalizes back inside is the committed file, `.env` is read by nothing,
# and a git that cannot answer the index or HEAD probe is a collection error,
# never a fall back to the built-in list. One table: a row builds its own
# repository, runs the gate under an optional PATH shim, and reads back the
# exit status and every line printed — the type list a refusal names is
# which source answered. The precedence ladder itself is
# settings-precedence.test.sh; the readers are index-reads.test.sh.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CM="$SKILL_DIR/scripts/commit-msg"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
ROOT="$TMP"
REAL_GIT="$(command -v git)"

unset COMMIT_GUARDS_COMMIT_TYPES COMMIT_GUARDS_SUBJECT_MAX \
  COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS COMMIT_GUARDS_CHANGELOG_PATHS \
  COMMIT_GUARDS_CHANGELOG_RECORD COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}

new_repo() { # NAME — fresh fixture repo in $R, cwd unchanged
  R="$ROOT/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}
types_toml() { # FILE LIST — a settings file naming LIST as the type list
  printf '[env]\nCOMMIT_GUARDS_COMMIT_TYPES = "%s"\n' "$2" >"$1"
}

# One line for a run of the gate inside $R over a message on stdin, SHIM-DIR
# first on PATH when given: the exit status, then every printed line in
# order joined by ';' with the scratch root aliased. ENVS is a
# comma-separated list of assignments, <root> in one standing for the
# scratch root.
judge() { # SHIM-DIR ENVS MSG
  local dir="$1" envs=() rc=0 out
  [ -z "$2" ] || IFS=',' read -ra envs <<<"${2//<root>/$ROOT}"
  out="$(cd "$R" && printf '%s\n' "$3" |
    PATH="${dir:+$dir:}$PATH" env ${envs[@]+"${envs[@]}"} "$CM" 2>&1)" || rc=$?
  out="${out//"$ROOT"/<root>}"
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}

OK="commit-msg: OK — conventional header:"
shape_fail() { # HEADER TYPES — the whole shape violation, naming the list that answered
  printf '%s' "commit-msg FAIL non-conventional header: $1;  expected: type(scope)!: subject — scope and '!' optional; types: $2;  scope accepts uppercase issue keys and issue numbers, e.g. fix(ABC-123): tighten the gate / fix(#123): case-fold IDs;  git-generated headers (Merge/Revert/Reapply, fixup!/squash!/amend!) pass unchanged"
}

# A git that fails one probe of the committed settings file and nothing
# else, so the row reads which probe the lane refused to guess past.
git_shim() { # SUBCOMMAND — exits 71 for SUBCOMMAND over kendex.settings.toml
  local dir="$ROOT/git-shim-$1"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\ncase " $* " in *" %s "*":(literal)kendex.settings.toml "*) echo "fatal: simulated %s failure" >&2; exit 71 ;; esac\nexec "%s" "$@"\n' "$1" "$1" "$REAL_GIT" >"$dir/git"
  chmod +x "$dir/git"
}
git_shim ls-files
git_shim ls-tree

# The out-of-repo source every fixture below can name: a list no committed
# file carries, so a verdict naming it was read from here.
types_toml "$ROOT/outside-settings.toml" "docs build"

fx_untracked() { new_repo "$1"; types_toml "$R/kendex.settings.toml" docs; }
fx_dotenv() { new_repo "$1"; printf 'COMMIT_GUARDS_COMMIT_TYPES=docs\n' >"$R/.env"; }
fx_dotenv_local() { new_repo "$1"; printf 'COMMIT_GUARDS_COMMIT_TYPES=chore\n' >"$R/.env.local"; }
fx_committed() { # NAME — the docs-only list committed
  new_repo "$1"
  types_toml "$R/kendex.settings.toml" docs
  git -C "$R" add -A
  git -C "$R" commit -qm "docs: base"
}
fx_loosened() { # NAME — committed docs-only, the worktree copy loosened to admit feat
  fx_committed "$1"
  mkdir -p "$R/sub"
  echo keep >"$R/sub/keep.txt"
  git -C "$R" add -A
  git -C "$R" commit -qm "docs: subdir"
  types_toml "$R/kendex.settings.toml" "docs feat"
}
fx_recreated() { # NAME — committed docs-only, staged for deletion, recreated in the worktree as chore-only
  fx_committed "$1"
  git -C "$R" rm -q --cached kendex.settings.toml
  types_toml "$R/kendex.settings.toml" chore
}

DOCS_ONLY="$(shape_fail 'feat: base type' docs)"
OUTSIDE="$(shape_fail 'feat: base type' 'docs build')"
LS_FILES="::error::kendex.settings.toml: could not query the index while resolving a setting (git ls-files exit 71); refusing to treat it as untracked"
LS_TREE="::error::kendex.settings.toml: could not probe HEAD while resolving a setting (git ls-tree exit 71); refusing to treat it as untracked"
echo "=== which settings source answers in the hook lane ==="
# label | fixture | shim | env | message | expect
rows=(
  "an untracked kendex.settings.toml is the worktree copy: its list admits docs|fx_untracked untracked-1|||docs: settings-admitted type|rc=0 $OK docs: settings-admitted type"
  "control: that list refuses feat, and the refusal names it|fx_untracked untracked-2|||feat: base type|rc=1 $DOCS_ONLY"
  "a .env type list is read by nothing: the built-in list decides|fx_dotenv dotenv|||feat: base type|rc=0 $OK feat: base type"
  "control: .env.local restricts the list|fx_dotenv_local dotenv-local-1|||feat: base type|rc=1 $(shape_fail 'feat: base type' chore)"
  "the /dev/null sentinel selects no source at all, .env.local included|fx_dotenv_local dotenv-local-2||COMMIT_GUARDS_SETTINGS_FILE=/dev/null|feat: base type|rc=0 $OK feat: base type"
  "control: the committed list refuses feat|fx_committed committed-1|||feat: base type|rc=1 $DOCS_ONLY"
  "a failing index probe is exit 2, never a fall back to the built-in list|fx_committed committed-2|$ROOT/git-shim-ls-files||feat: base type|rc=2 $LS_FILES"
  "an absolute source outside the repository is the worktree copy, not a failed probe|fx_committed committed-3||COMMIT_GUARDS_SETTINGS_FILE=<root>/outside-settings.toml|feat: base type|rc=1 $OUTSIDE"
  "a relative source escaping the repository is the worktree copy too|fx_committed committed-4||COMMIT_GUARDS_SETTINGS_FILE=../outside-settings.toml|feat: base type|rc=1 $OUTSIDE"
  "the committed list governs over the loosened worktree copy|fx_loosened loosened-1||COMMIT_GUARDS_SETTINGS_FILE=kendex.settings.toml|feat: base type|rc=1 $DOCS_ONLY"
  "a '..' that normalizes back inside is the committed file|fx_loosened loosened-2||COMMIT_GUARDS_SETTINGS_FILE=sub/../kendex.settings.toml|feat: base type|rc=1 $DOCS_ONLY"
  "a leading './' is the committed file|fx_loosened loosened-3||COMMIT_GUARDS_SETTINGS_FILE=./kendex.settings.toml|feat: base type|rc=1 $DOCS_ONLY"
  "segments that never existed cancel out to the committed file|fx_loosened loosened-4||COMMIT_GUARDS_SETTINGS_FILE=a/b/../../kendex.settings.toml|feat: base type|rc=1 $DOCS_ONLY"
  "control: a spelling that still escapes once normalized reads the out-of-repo file|fx_loosened loosened-5||COMMIT_GUARDS_SETTINGS_FILE=sub/../../outside-settings.toml|feat: base type|rc=1 $OUTSIDE"
  "control: a source staged for deletion governs as absent, whatever the recreated copy says|fx_recreated recreated-1|||feat: base type|rc=0 $OK feat: base type"
  "a failing HEAD probe is exit 2, never authority for the recreated copy|fx_recreated recreated-2|$ROOT/git-shim-ls-tree||feat: base type|rc=2 $LS_TREE"
)
for row in "${rows[@]}"; do
  IFS='|' read -r label fixture shim env msg expect <<<"$row"
  $fixture
  assert_eq "$label" "$expect" "$(judge "$shim" "$env" "$msg")"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
