#!/usr/bin/env bash
# Pins for lib/common.sh's index reads and policy writes: a probe git could
# not answer never becomes an answer, a configured path is matched literally,
# a --cached scan refuses an unmerged index, and a policy file is replaced by
# a same-directory rename or not at all. Every clean assertion is paired with
# a control that proves it can fail.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
COMMON="$SCRIPTS/lib/common.sh"
SETTINGS="$SCRIPTS/lib/settings.sh"

# A scratch root this suite OWNS: an assertion over a namespace shared with
# other processes cannot tell "the code under test leaked" from "someone
# else's run moved".
ROOT="$(mktemp -d "${TMPDIR:-/tmp}/gg-index-reads.XXXXXX")"
trap 'rm -rf "$ROOT"' EXIT

# The fixtures below are judged against THEIR OWN configuration: the caller's
# core.hooksPath, init.templateDir or commit.gpgsign would otherwise run the
# caller's hooks against generated repos, or block their commits outright.
export HOME="$ROOT/home"
export XDG_CONFIG_HOME="$ROOT/xdg"
export GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$XDG_CONFIG_HOME"

unset GROWTH_GUARDS_SETTINGS_FILE GROWTH_GUARDS_CONFLICT_EXCLUDES 2>/dev/null || true

TAB="$(printf '\t')"
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

new_repo() { # NAME — fresh fixture repo in $R, cwd unchanged
  R="$ROOT/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

# Run a snippet with common.sh sourced, inside $R. OUT captures stdout+stderr,
# RC the exit status — a collection error is exit 2 and must be observable.
call() { # SNIPPET
  OUT=""
  RC=0
  OUT="$(cd "$R" && GG_CHECK=probe bash -c '
    set -euo pipefail
    . "$1"
    shift
    eval "$1"
  ' _ "$COMMON" "$1" 2>&1)" || RC=$?
}

echo "=== gg_policy_content: the index governs, and a probe that failed is not an answer ==="

new_repo staged-wins
printf 'seed\n' >"$R/seed.txt"
mkdir -p "$R/tools"
printf 'INDEX\treason\n' >"$R/tools/ex.tsv"
git -C "$R" add -A
git -C "$R" commit -qm base
printf 'WORKTREE\treason\n' >"$R/tools/ex.tsv"
call 'gg_policy_content tools/ex.tsv'
[ "$RC" -eq 0 ] && [ "$OUT" = "INDEX${TAB}reason" ] \
  && ok "the staged copy governs over an unstaged edit" \
  || bad "the staged copy governs over an unstaged edit" "rc=$RC out=$OUT"

# Control: the SAME fixture, with the index unreadable. Before this was
# classified, the failed probe fell through to the worktree copy and the
# commit was judged against policy it does not carry.
printf 'not an index\n' >"$ROOT/corrupt.idx"
call 'GIT_INDEX_FILE="'"$ROOT"'/corrupt.idx" gg_policy_content tools/ex.tsv'
[ "$RC" -eq 2 ] && case "$OUT" in *"could not query the index"*) true ;; *) false ;; esac \
  && ok "an unreadable index is a collection error, not a fall-through" \
  || bad "an unreadable index is a collection error, not a fall-through" "rc=$RC out=$OUT"
case "$OUT" in
  *WORKTREE*) bad "the failed probe never emits the worktree copy" "out=$OUT" ;;
  *) ok "the failed probe never emits the worktree copy" ;;
esac

new_repo staged-deletion
mkdir -p "$R/tools"
printf 'INDEX\treason\n' >"$R/tools/ex.tsv"
git -C "$R" add -A
git -C "$R" commit -qm base
git -C "$R" rm -q --cached tools/ex.tsv
call 'gg_policy_content tools/ex.tsv'
[ "$RC" -eq 1 ] && [ -z "$OUT" ] \
  && ok "a staged deletion governs as absent even with the worktree copy present" \
  || bad "a staged deletion governs as absent even with the worktree copy present" "rc=$RC out=$OUT"

new_repo never-tracked
printf 'seed\n' >"$R/seed.txt"
git -C "$R" add -A
git -C "$R" commit -qm base
mkdir -p "$R/tools"
printf 'ONDISK\treason\n' >"$R/tools/ex.tsv"
call 'gg_policy_content tools/ex.tsv'
[ "$RC" -eq 0 ] && case "$OUT" in ONDISK*) true ;; *) false ;; esac \
  && ok "a never-tracked policy file falls back to the worktree copy" \
  || bad "a never-tracked policy file falls back to the worktree copy" "rc=$RC out=$OUT"

new_repo unborn-head
mkdir -p "$R/tools"
printf 'ONDISK\treason\n' >"$R/tools/ex.tsv"
call 'gg_policy_content tools/ex.tsv'
[ "$RC" -eq 0 ] && case "$OUT" in ONDISK*) true ;; *) false ;; esac \
  && ok "an unborn HEAD carries nothing and does not fail the read" \
  || bad "an unborn HEAD carries nothing and does not fail the read" "rc=$RC out=$OUT"

echo "=== gg_policy_content: a configured path is a literal path, never a glob ==="

new_repo glob-path
mkdir -p "$R/tools"
printf 'REAL\treason\n' >"$R/tools/exA.tsv"
git -C "$R" add -A
git -C "$R" commit -qm base
call "gg_policy_content 'tools/ex?.tsv'"
[ "$RC" -eq 1 ] && [ -z "$OUT" ] \
  && ok "a glob-shaped path matches only itself, and it does not exist" \
  || bad "a glob-shaped path matches only itself, and it does not exist" "rc=$RC out=$OUT"
case "$OUT" in
  *REAL* | *"diff --git"*)
    bad "a glob-shaped path never yields another entry's content" "out=$OUT"
    ;;
  *) ok "a glob-shaped path never yields another entry's content" ;;
esac
# Control: the literal path this repo does carry still resolves.
call 'gg_policy_content tools/exA.tsv'
[ "$RC" -eq 0 ] && case "$OUT" in REAL*) true ;; *) false ;; esac \
  && ok "the literal path it names still resolves" \
  || bad "the literal path it names still resolves" "rc=$RC out=$OUT"

echo "=== gg_require_merged_index: a --cached scan refuses an unmerged index ==="

conflicted_repo() { # NAME — fixture left mid-merge, f.txt unmerged
  new_repo "$1"
  printf 'line1\nbase\nline3\n' >"$R/f.txt"
  git -C "$R" add -A
  git -C "$R" commit -qm base
  git -C "$R" checkout -q -b other
  printf 'line1\ntheirs\nline3\n' >"$R/f.txt"
  git -C "$R" commit -qam other
  git -C "$R" checkout -q main
  printf 'line1\nours\nline3\n' >"$R/f.txt"
  git -C "$R" commit -qam ours
  git -C "$R" merge other >/dev/null 2>&1 || true
}

conflicted_repo unmerged
[ "$(git -C "$R" ls-files -u | wc -l)" -eq 3 ] \
  && ok "the fixture really is mid-merge (three index stages)" \
  || bad "the fixture really is mid-merge (three index stages)" "stages=$(git -C "$R" ls-files -u | wc -l)"

call 'gg_require_merged_index'
[ "$RC" -eq 2 ] && case "$OUT" in *"unmerged path"*"finish or abort the merge"*) true ;; *) false ;; esac \
  && ok "an unmerged index is a collection error naming the remedy" \
  || bad "an unmerged index is a collection error naming the remedy" "rc=$RC out=$OUT"
case "$OUT" in
  *f.txt*) ok "the refusal names the unmerged path" ;;
  *) bad "the refusal names the unmerged path" "out=$OUT" ;;
esac

# Scope: the guard answers for the paths the lane actually scans. An unmerged
# path outside the pathspec leaves that scan complete.
call "gg_require_merged_index '*.rs'"
[ "$RC" -eq 0 ] \
  && ok "an unmerged path outside the pathspec does not block that scan" \
  || bad "an unmerged path outside the pathspec does not block that scan" "rc=$RC out=$OUT"
call "gg_require_merged_index 'f.txt'"
[ "$RC" -eq 2 ] \
  && ok "an unmerged path inside the pathspec does block it" \
  || bad "an unmerged path inside the pathspec does block it" "rc=$RC out=$OUT"

echo "=== end to end: conflict-markers over an unmerged index ==="

conflicted_repo cm-unmerged
RC=0
OUT="$(cd "$R" && "$SCRIPTS/conflict-markers" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] \
  && ok "conflict-markers refuses rather than reporting OK over an unmerged index" \
  || bad "conflict-markers refuses rather than reporting OK over an unmerged index" "rc=$RC out=$OUT"
case "$OUT" in
  *"OK — no conflict markers"*)
    bad "the refusal is not dressed as a clean verdict" "out=$OUT"
    ;;
  *) ok "the refusal is not dressed as a clean verdict" ;;
esac

# Control: staging the conflicted content resolves the index, and the SAME
# bytes then fail as the violation they are — the guard did not replace the
# measurement, it unblocked it.
git -C "$R" add f.txt
RC=0
OUT="$(cd "$R" && "$SCRIPTS/conflict-markers" 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && case "$OUT" in *"conflict marker: f.txt:"*) true ;; *) false ;; esac \
  && ok "once staged, the same markers fail as violations" \
  || bad "once staged, the same markers fail as violations" "rc=$RC out=$OUT"

# Control: a resolved, marker-free tree passes.
printf 'line1\nmerged\nline3\n' >"$R/f.txt"
git -C "$R" add f.txt
RC=0
OUT="$(cd "$R" && "$SCRIPTS/conflict-markers" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"conflict-markers: OK"*) true ;; *) false ;; esac \
  && ok "a resolved tree passes" \
  || bad "a resolved tree passes" "rc=$RC out=$OUT"

echo "=== gg_install_file: the destination is replaced whole, or not at all ==="

new_repo install-file
mkdir -p "$R/tools"
printf 'ORIGINAL\n' >"$R/tools/dest.tsv"
printf 'REPLACEMENT\n' >"$ROOT/src.tsv"
call 'gg_install_file "'"$ROOT"'/src.tsv" tools/dest.tsv "the fixture"'
[ "$RC" -eq 0 ] && [ "$(cat "$R/tools/dest.tsv")" = "REPLACEMENT" ] \
  && ok "a successful install replaces the destination" \
  || bad "a successful install replaces the destination" "rc=$RC out=$OUT content=$(cat "$R/tools/dest.tsv")"
[ -z "$(find "$R/tools" -name '.gg-install*')" ] \
  && ok "a successful install leaves no residue beside the destination" \
  || bad "a successful install leaves no residue beside the destination" "$(find "$R/tools" -name '.gg-install*')"

# Control: interrupt the install at the rename. The destination must still
# carry the reviewed bytes — a truncated ratchet file loosens the gate
# instead of failing it, so a half-done replace is worse than none.
new_repo install-fails
mkdir -p "$R/tools" "$ROOT/stub"
printf 'ORIGINAL\n' >"$R/tools/dest.tsv"
printf '#!/bin/sh\nexit 1\n' >"$ROOT/stub/mv"
chmod +x "$ROOT/stub/mv"
RC=0
OUT="$(cd "$R" && PATH="$ROOT/stub:$PATH" GG_CHECK=probe bash -c '
  set -euo pipefail
  . "$1"
  gg_install_file "$2" tools/dest.tsv "the fixture"
' _ "$COMMON" "$ROOT/src.tsv" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"could not replace the fixture"*) true ;; *) false ;; esac \
  && ok "a failed rename is a loud collection error" \
  || bad "a failed rename is a loud collection error" "rc=$RC out=$OUT"
[ "$(cat "$R/tools/dest.tsv")" = "ORIGINAL" ] \
  && ok "a failed install leaves the destination byte-identical" \
  || bad "a failed install leaves the destination byte-identical" "content=$(cat "$R/tools/dest.tsv")"

echo "=== the settings cache is materialized by rename, never by a live redirect ==="

new_repo settings-cache
printf 'GROWTH_GUARDS_TODO_MAX=7\n' >"$R/vstack.settings.toml"
git -C "$R" add -A
git -C "$R" commit -qm base
RC=0
OUT="$(cd "$R" && PATH="$ROOT/stub:$PATH" GG_CHECK=probe bash -c '
  set -euo pipefail
  . "$1"
  . "$2"
  gg_settings_index_mode
  src="$(gg_settings_source vstack.settings.toml)" || exit 3
  printf "SRC=%s\n" "$src"
  ls -A "$GG_SETTINGS_INDEX_DIR"
' _ "$COMMON" "$SETTINGS" 2>&1)" || RC=$?
[ "$RC" -eq 3 ] && case "$OUT" in *"could not materialize the staged copy"*) true ;; *) false ;; esac \
  && ok "a failed rename fails the settings resolve loudly" \
  || bad "a failed rename fails the settings resolve loudly" "rc=$RC out=$OUT"
case "$OUT" in
  *SRC=*) bad "no cache path is handed out when the rename failed" "out=$OUT" ;;
  *) ok "no cache path is handed out when the rename failed" ;;
esac

# Control: with mv working, the same resolve materializes a complete cache.
RC=0
OUT="$(cd "$R" && GG_CHECK=probe bash -c '
  set -euo pipefail
  . "$1"
  . "$2"
  gg_settings_index_mode
  src="$(gg_settings_source vstack.settings.toml)"
  cat "$src"
  find "$GG_SETTINGS_INDEX_DIR" -name "*.part" -printf "PART:%p\n"
' _ "$COMMON" "$SETTINGS" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *GROWTH_GUARDS_TODO_MAX=7*) true ;; *) false ;; esac \
  && ok "the cache resolves the staged value when the rename succeeds" \
  || bad "the cache resolves the staged value when the rename succeeds" "rc=$RC out=$OUT"
case "$OUT" in
  *PART:*) bad "no partial cache file survives the resolve" "out=$OUT" ;;
  *) ok "no partial cache file survives the resolve" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
