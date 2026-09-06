#!/usr/bin/env bash
# The index reads the checks share, one table per reader: gg_policy_content
# (the index governs a policy file, a probe git could not answer is never an
# answer, a configured path is literal), gg_require_merged_index (a --cached
# scan refuses an unmerged index, for the paths it scans), the excludes read
# a lane makes through them, and the settings cache lib/settings.sh
# materializes by rename. Each row builds its own fixture repository, makes
# one call, and reads back the exit status and every line printed, the
# scratch roots aliased. lib/atomic-install.sh is atomic-install.test.sh; the
# lanes end to end over these readers are lane-readers.test.sh.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
COMMON="$SCRIPTS/lib/common.sh"
SETTINGS="$SCRIPTS/lib/settings.sh"
ROOT="$TMP"

unset COMMIT_GUARDS_SETTINGS_FILE COMMIT_GUARDS_CONFLICT_EXCLUDES 2>/dev/null || true

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
commit_all() { # MESSAGE
  git -C "$R" add -A
  git -C "$R" commit -qm "$1"
}

# One line for a run: the exit status, then every printed line in order,
# joined by ';' with the roots aliased and a tab spelled out, so a diagnostic
# reads as the detector that wrote it and the path it names.
line() { # RC OUT
  local out="$2"
  out="${out//"$R"/<repo>}"
  out="${out//"$ROOT"/<root>}"
  printf 'rc=%s' "$1"
  [ -z "$out" ] || printf ' %s' "$(printf '%s\n' "$out" | sed -e 's/[[:space:]]*$//' -e 's/\t/\\t/g' | paste -sd ';' -)"
}

# A snippet with common.sh and one more lib sourced, run inside $R, with
# $SHIM first on PATH when a row sets one.
SHIM=""
call() { # LIB SNIPPET
  local rc=0 out
  out="$(cd "$R" && PATH="${SHIM:+$SHIM:}$PATH" GG_CHECK=probe bash -c '
    set -euo pipefail
    . "$1"
    . "$2"
    shift 2
    eval "$1"
  ' _ "$COMMON" "$1" "$2" 2>&1)" || rc=$?
  line "$rc" "$out"
}

# --- gg_policy_content -------------------------------------------------------

fx_policy() { # NAME STAGED WORKTREE — tools/ex.tsv committed as STAGED, then edited to WORKTREE
  new_repo "$1"
  mkdir -p "$R/tools"
  printf 'seed\n' >"$R/seed.txt"
  printf '%s\treason\n' "$2" >"$R/tools/ex.tsv"
  commit_all base
  [ -z "$3" ] || printf '%s\treason\n' "$3" >"$R/tools/ex.tsv"
}
fx_staged_deletion() { fx_policy staged-deletion INDEX ""; git -C "$R" rm -q --cached tools/ex.tsv; }
fx_never_tracked() { new_repo never-tracked; printf 'seed\n' >"$R/seed.txt"; commit_all base; mkdir -p "$R/tools"; printf 'ONDISK\treason\n' >"$R/tools/ex.tsv"; }
fx_unborn() { new_repo unborn-head; mkdir -p "$R/tools"; printf 'ONDISK\treason\n' >"$R/tools/ex.tsv"; }
fx_glob() { new_repo "$1"; mkdir -p "$R/tools"; printf 'REAL\treason\n' >"$R/tools/exA.tsv"; commit_all base; }
printf 'not an index\n' >"$ROOT/corrupt.idx"

echo "=== gg_policy_content ==="
# label | fixture | snippet | expect
rows=(
  "the staged copy governs over an unstaged edit|fx_policy staged-wins INDEX WORKTREE|gg_policy_content tools/ex.tsv|rc=0 INDEX\\treason"
  "an unreadable index is a collection error, never the worktree copy|fx_policy corrupt INDEX WORKTREE|GIT_INDEX_FILE=$ROOT/corrupt.idx gg_policy_content tools/ex.tsv|rc=2 ::error::probe: could not query the index for tools/ex.tsv (git ls-files exit 128); refusing to treat it as untracked"
  "a staged deletion governs as absent with the worktree copy present|fx_staged_deletion|gg_policy_content tools/ex.tsv|rc=1"
  "a never-tracked policy file falls back to the worktree copy|fx_never_tracked|gg_policy_content tools/ex.tsv|rc=0 ONDISK\\treason"
  "an unborn HEAD carries nothing and does not fail the read|fx_unborn|gg_policy_content tools/ex.tsv|rc=0 ONDISK\\treason"
  "a glob-shaped path matches only itself|fx_glob glob-path|gg_policy_content 'tools/ex?.tsv'|rc=1"
  "control: the literal path it names resolves|fx_glob literal-path|gg_policy_content tools/exA.tsv|rc=0 REAL\\treason"
)
for row in "${rows[@]}"; do
  IFS='|' read -r label fixture snippet expect <<<"$row"
  $fixture
  assert_eq "$label" "$expect" "$(call "$SETTINGS" "$snippet")"
done

# --- gg_require_merged_index -------------------------------------------------

conflicted_repo() { # NAME — fixture left mid-merge, f.txt unmerged
  new_repo "$1"
  printf 'line1\nbase\nline3\n' >"$R/f.txt"
  commit_all base
  git -C "$R" checkout -q -b other
  printf 'line1\ntheirs\nline3\n' >"$R/f.txt"
  git -C "$R" commit -qam other
  git -C "$R" checkout -q main
  printf 'line1\nours\nline3\n' >"$R/f.txt"
  git -C "$R" commit -qam ours
  git -C "$R" merge other >/dev/null 2>&1 || true
}
conflicted_repo unmerged
assert_eq "the fixture really is mid-merge (three index stages)" 3 "$(git -C "$R" ls-files -u | wc -l | tr -d ' ')"
# A git that cannot list the unmerged paths at all: the probe's failure is
# never read as "nothing unmerged".
mkdir -p "$ROOT/git-shim-unmerged"
printf '#!/usr/bin/env bash\ncase " $* " in *" --unmerged "*) echo "git ls-files: simulated failure" >&2; exit 128 ;; esac\nexec "%s" "$@"\n' "$(command -v git)" >"$ROOT/git-shim-unmerged/git"
chmod +x "$ROOT/git-shim-unmerged/git"

echo "=== gg_require_merged_index ==="
REFUSAL="f.txt;::error::probe: the index carries 1 unmerged path(s) (listed above) and a --cached scan skips them silently — finish or abort the merge, then re-run"
# label | shim | pathspec | expect
rows=(
  "an unmerged index is a collection error naming the path and the remedy|||rc=2 $REFUSAL"
  "an unmerged path outside the pathspec does not block that scan||'*.rs'|rc=0"
  "an unmerged path inside the pathspec does block it||'f.txt'|rc=2 $REFUSAL"
  "a probe that could not list the unmerged paths is a collection error, never an empty list|$ROOT/git-shim-unmerged||rc=2 git ls-files: simulated failure;::error::probe: could not read the index for unmerged paths (git ls-files exit 128)"
)
for row in "${rows[@]}"; do
  IFS='|' read -r label SHIM pathspec expect <<<"$row"
  assert_eq "$label" "$expect" "$(call "$SETTINGS" "gg_require_merged_index $pathspec")"
done
SHIM=""

# --- a failed policy read stops the gate ------------------------------------

# gg_policy_content runs inside a command substitution, so its exit 2 dies in
# that subshell and reaches gg_load_excludes as a bare status. This shim fails
# ONLY the index probe, so nothing later in the run can mask the propagation.
mkdir -p "$ROOT/gitstub"
cat >"$ROOT/gitstub/git" <<'STUB'
#!/usr/bin/env bash
for a in "$@"; do
  [ "$a" = "--error-unmatch" ] || continue
  echo "fatal: simulated index failure" >&2
  exit 128
done
exec "$GG_REAL_GIT" "$@"
STUB
chmod +x "$ROOT/gitstub/git"
GG_REAL_GIT="$(command -v git)"
export GG_REAL_GIT

new_repo excludes-unread
printf 'seed\n' >"$R/seed.txt"
mkdir -p "$R/tools"
printf '# notes\n\nTODO: an unlinked work marker\n' >"$R/bad.md"
printf 'bad.md\tallowed to carry markers\n' >"$R/tools/todo-ban-excludes"
commit_all base

lane() { # SHIM-DIR SCRIPT [ARG...] — one line for a lane run inside $R, SHIM-DIR first on PATH when given
  local dir="$1" script="$2" rc=0 out
  shift 2
  out="$(cd "$R" && PATH="${dir:+$dir:}$PATH" "$SCRIPTS/$script" "$@" 2>&1)" || rc=$?
  line "$rc" "$out"
}

echo "=== a failed policy read stops the gate, it does not become an empty list ==="
assert_eq "control: with the excludes readable, the excluded marker passes" \
  "rc=0 todo-ban: OK — no work markers in tracked files" "$(lane "" todo-ban)"
assert_eq "an unreadable exclusion list stops the run at exit 2, with no verdict" \
  "rc=2 ::error::todo-ban: could not query the index for tools/todo-ban-excludes (git ls-files exit 128); refusing to treat it as untracked;::error::todo-ban: refusing to run on an unread exclusion list: tools/todo-ban-excludes (exit 2, cause above)" \
  "$(lane "$ROOT/gitstub" todo-ban)"

# --- the settings cache ------------------------------------------------------

mkdir -p "$ROOT/nomv"
printf '#!/bin/sh\nexit 1\n' >"$ROOT/nomv/mv"
chmod +x "$ROOT/nomv/mv"
new_repo settings-cache
printf 'COMMIT_GUARDS_TODO_MAX=7\n' >"$R/kendex.settings.toml"
commit_all base
RESOLVE='gg_settings_index_mode; src="$(gg_settings_source kendex.settings.toml)" || exit 3; cat "$src"; find "$GG_SETTINGS_INDEX_DIR" -name "*.part" -print | sed "s/^/PART:/"'

echo "=== the settings cache is materialized by rename, never by a live redirect ==="
assert_eq "the cache resolves the staged value when the rename succeeds, leaving no partial file" \
  "rc=0 COMMIT_GUARDS_TODO_MAX=7" "$(call "$SETTINGS" "$RESOLVE")"
assert_eq "a failed rename fails the resolve loudly and hands out no cache path" \
  "rc=3 ::error::kendex.settings.toml: could not materialize the staged copy while resolving a setting" \
  "$(call "$SETTINGS" "PATH=$ROOT/nomv:\$PATH; $RESOLVE")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
