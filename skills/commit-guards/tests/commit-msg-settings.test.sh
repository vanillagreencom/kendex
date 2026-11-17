#!/usr/bin/env bash
# The settings scripts/commit-msg judges a commit by, read as the hook lane
# reads them: a tracked source resolves from the INDEX so an unstaged edit
# cannot loosen the committed policy, an untracked one is the worktree copy,
# a source outside the repository is the worktree copy too, a spelling that
# normalizes back inside is the committed file, `.env` is read by nothing,
# and a git that cannot answer the index or HEAD probe is a collection error,
# never a fall back to the built-in setting. One table: a row builds its own
# repository staging one file under each of three folders, runs the gate
# under an optional PATH shim, and reads back the exit status and every line
# printed — the path a missing entry names is which source's required-path
# list answered, and no line at all is the built-in rule, which is off. The precedence ladder itself is
# settings-precedence.test.sh; the readers are index-reads.test.sh.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CM="$SKILL_DIR/scripts/commit-msg"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
ROOT="$TMP"
REAL_GIT="$(command -v git)"

unset COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS COMMIT_GUARDS_CHANGELOG_PATHS \
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
required_toml() { # FILE LIST — a settings file naming LIST as the required paths
  printf '[env]\nCOMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS = "%s"\n' "$2" >"$1"
}
# One staged file per folder a list below can name, and no fragment.
stage_changes() {
  mkdir -p "$R/docs" "$R/build" "$R/chore"
  printf 'a\n' >"$R/docs/a.md"
  printf 'b\n' >"$R/build/b.txt"
  printf 'c\n' >"$R/chore/c.txt"
  git -C "$R" add docs build chore
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
  out="$(printf '%s\n' "$out" | LC_ALL=C awk '/^commit-msg: [a-z-]+=/ { print }')"
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}

owed() { # PATH — the missing entry, naming the staged path the answering list required
  printf '%s' "commit-msg: changelog-missing=$1:changelog.d/*/*.md"
}

# A git that fails one probe and nothing else, so the row reads which
# probe the lane refused to guess past. The HEAD resolve carries no path,
# so its refusal names the first source the walk probes.
git_shim() { # NAME PATTERN — exits 71 for an argv matching PATTERN
  local dir="$ROOT/git-shim-$1"
  mkdir -p "$dir"
  printf '#!/usr/bin/env bash\ncase " $* " in %s) echo "fatal: simulated %s failure" >&2; exit 71 ;; esac\nexec "%s" "$@"\n' "$2" "$1" "$REAL_GIT" >"$dir/git"
  chmod +x "$dir/git"
}
git_shim ls-files '*" ls-files --error-unmatch "*":(literal)kendex.settings.toml "*'
git_shim ls-files-s '*" ls-files -s "*":(literal)kendex.settings.toml "*'
git_shim ls-tree '*" ls-tree "*":(literal)kendex.settings.toml "*'
git_shim rev-parse '*" rev-parse --verify --quiet HEAD "*'

# The out-of-repo source every fixture below can name: a list no committed
# file carries, so a verdict naming it was read from here.
required_toml "$ROOT/outside-settings.toml" "build/*"

fx_untracked() { new_repo "$1"; required_toml "$R/kendex.settings.toml" "docs/*"; stage_changes; }
fx_dotenv() { new_repo "$1"; printf 'COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS=docs/*\n' >"$R/.env"; stage_changes; }
fx_dotenv_local() { new_repo "$1"; printf 'COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS=chore/*\n' >"$R/.env.local"; stage_changes; }
fx_committed() { # NAME — the docs list committed
  new_repo "$1"
  required_toml "$R/kendex.settings.toml" "docs/*"
  git -C "$R" add -A
  git -C "$R" commit -qm "docs: base"
  stage_changes
}
fx_loosened() { # NAME — the docs list committed, the worktree copy loosened to require nothing
  fx_committed "$1"
  mkdir -p "$R/sub"
  echo keep >"$R/sub/keep.txt"
  git -C "$R" add sub
  required_toml "$R/kendex.settings.toml" ""
}
fx_recreated() { # NAME — the docs list committed, staged for deletion, recreated in the worktree as the chore list
  fx_committed "$1"
  git -C "$R" rm -q --cached kendex.settings.toml
  required_toml "$R/kendex.settings.toml" "chore/*"
}

DOCS_ONLY="$(owed docs/a.md)"
OUTSIDE="$(owed build/b.txt)"
LS_FILES="commit-msg: settings-index-query=kendex.settings.toml:71"
LS_TREE="commit-msg: settings-head-query=kendex.settings.toml:71"
LS_FILES_S="commit-msg: settings-index-mode=kendex.settings.toml:71"
REV_PARSE="commit-msg: settings-head-resolve=.kendex/settings.toml:71"
echo "=== which settings source answers in the hook lane ==="
# label | fixture | shim | env | message | expect
rows=(
  "an untracked kendex.settings.toml is the worktree copy, and its list answers|fx_untracked untracked-1|||feat: base type|rc=1 $DOCS_ONLY"
  "a .env list is read by nothing: the built-in setting, off, decides|fx_dotenv dotenv|||feat: base type|rc=0"
  "control: .env.local sets the list|fx_dotenv_local dotenv-local-1|||feat: base type|rc=1 $(owed chore/c.txt)"
  "the /dev/null sentinel selects no source at all, .env.local included|fx_dotenv_local dotenv-local-2||COMMIT_GUARDS_SETTINGS_FILE=/dev/null|feat: base type|rc=0"
  "control: the committed list answers|fx_committed committed-1|||feat: base type|rc=1 $DOCS_ONLY"
  "a failing index probe is exit 2, never a fall back to the built-in list|fx_committed committed-2|$ROOT/git-shim-ls-files||feat: base type|rc=2 $LS_FILES"
  "a failing index-mode read is exit 2, never the symlink shape let through|fx_committed committed-5|$ROOT/git-shim-ls-files-s||feat: base type|rc=2 $LS_FILES_S"
  "a failing HEAD resolve is exit 2, named on the first source probed|fx_committed committed-6|$ROOT/git-shim-rev-parse||feat: base type|rc=2 $REV_PARSE"
  "an absolute source outside the repository is the worktree copy, not a failed probe|fx_committed committed-3||COMMIT_GUARDS_SETTINGS_FILE=<root>/outside-settings.toml|feat: base type|rc=1 $OUTSIDE"
  "a relative source escaping the repository is the worktree copy too|fx_committed committed-4||COMMIT_GUARDS_SETTINGS_FILE=../outside-settings.toml|feat: base type|rc=1 $OUTSIDE"
  "the committed list governs over the loosened worktree copy|fx_loosened loosened-1||COMMIT_GUARDS_SETTINGS_FILE=kendex.settings.toml|feat: base type|rc=1 $DOCS_ONLY"
  "a '..' that normalizes back inside is the committed file|fx_loosened loosened-2||COMMIT_GUARDS_SETTINGS_FILE=sub/../kendex.settings.toml|feat: base type|rc=1 $DOCS_ONLY"
  "a leading './' is the committed file|fx_loosened loosened-3||COMMIT_GUARDS_SETTINGS_FILE=./kendex.settings.toml|feat: base type|rc=1 $DOCS_ONLY"
  "segments that never existed cancel out to the committed file|fx_loosened loosened-4||COMMIT_GUARDS_SETTINGS_FILE=a/b/../../kendex.settings.toml|feat: base type|rc=1 $DOCS_ONLY"
  "control: a spelling that still escapes once normalized reads the out-of-repo file|fx_loosened loosened-5||COMMIT_GUARDS_SETTINGS_FILE=sub/../../outside-settings.toml|feat: base type|rc=1 $OUTSIDE"
  "control: a source staged for deletion governs as absent, whatever the recreated copy says|fx_recreated recreated-1|||feat: base type|rc=0"
  "a failing HEAD probe is exit 2, never authority for the recreated copy|fx_recreated recreated-2|$ROOT/git-shim-ls-tree||feat: base type|rc=2 $LS_TREE"
)
for row in "${rows[@]}"; do
  IFS='|' read -r label fixture shim env msg expect <<<"$row"
  $fixture
  assert_eq "$label" "$expect" "$(judge "$shim" "$env" "$msg")"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
