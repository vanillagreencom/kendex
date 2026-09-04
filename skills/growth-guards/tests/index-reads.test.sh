#!/usr/bin/env bash
# Pins for the libs the checks share: lib/common.sh's index reads,
# lib/configured-paths.sh's policy reads and content sniff,
# lib/atomic-install.sh's policy writes, and the settings cache
# lib/settings.sh materializes. A probe git could not answer never becomes an
# answer, a configured path is matched literally, a --cached scan refuses an
# unmerged index, a policy file is replaced by a same-directory rename or not
# at all, and no partial cache file survives a resolve. Every clean assertion
# is paired with a control that proves it can fail.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# The harness owns the scratch root, TMPDIR inside it, and the git isolation.
# The root matters here beyond hygiene: an assertion over a namespace shared
# with other processes cannot tell "the code under test leaked" from "someone
# else's run moved".
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SCRIPTS="$SKILL_DIR/scripts"
COMMON="$SCRIPTS/lib/common.sh"
# The lib holding the install helpers, which a probe exercising them sources
# alongside COMMON: the writer lives beside common.sh rather than inside it,
# and reaches back across that boundary for the staging file common.sh
# declares and its exit trap removes.
INSTALL="$SCRIPTS/lib/atomic-install.sh"
SETTINGS="$SCRIPTS/lib/settings.sh"
ROOT="$TMP"

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

# Run a snippet with the libs sourced, inside $R. OUT captures stdout+stderr,
# RC the exit status — a collection error is exit 2 and must be observable.
call() { # SNIPPET
  OUT=""
  RC=0
  OUT="$(cd "$R" && GG_CHECK=probe bash -c '
    set -euo pipefail
    . "$1"
    . "$2"
    shift 2
    eval "$1"
  ' _ "$COMMON" "$INSTALL" "$1" 2>&1)" || RC=$?
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

echo "=== end to end: prose over an unmerged index ==="

# prose walks `ls-files -s`, which emits one record per STAGE, so an
# unresolved merge would hand it rival blobs for one path. Its guard runs
# over the whole index before the walk: the fixture carries no file the
# default path list matches, so a lane that skipped the guard would report
# the clean "no tracked file matches" verdict instead of refusing.
conflicted_repo prose-unmerged
RC=0
OUT="$(cd "$R" && "$SCRIPTS/prose" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] \
  && ok "prose refuses rather than reporting OK over an unmerged index" \
  || bad "prose refuses rather than reporting OK over an unmerged index" "rc=$RC out=$OUT"
case "$OUT" in
  *"prose: OK"*)
    bad "prose's refusal is not dressed as a clean verdict" "out=$OUT"
    ;;
  *) ok "prose's refusal is not dressed as a clean verdict" ;;
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

echo "=== byte-ceiling: an add/add conflict is not a zero-addition diff ==="

# An add/add conflict is status U, which --diff-filter=A drops entirely: the
# addition vanishes from the record set and the ceiling measures nothing.
new_repo bc-addadd
printf 'seed\n' >"$R/seed.txt"
git -C "$R" add -A
git -C "$R" commit -qm base
git -C "$R" checkout -q -b other
head -c 400000 /dev/zero | tr '\0' 'b' >"$R/big.txt"
git -C "$R" add -A
git -C "$R" commit -qm other
git -C "$R" checkout -q main
head -c 400000 /dev/zero | tr '\0' 'a' >"$R/big.txt"
git -C "$R" add -A
git -C "$R" commit -qm ours
git -C "$R" merge other >/dev/null 2>&1 || true
[ "$(git -C "$R" diff --cached --raw --diff-filter=A | wc -l)" -eq 0 ] \
  && ok "the fixture really does hide the addition from --diff-filter=A" \
  || bad "the fixture really does hide the addition from --diff-filter=A" "$(git -C "$R" diff --cached --raw --diff-filter=A)"

RC=0
OUT="$(cd "$R" && "$SCRIPTS/byte-ceiling" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] \
  && ok "byte-ceiling refuses the unmerged index instead of measuring around it" \
  || bad "byte-ceiling refuses the unmerged index instead of measuring around it" "rc=$RC out=$OUT"
case "$OUT" in
  *"0 staged addition(s) checked"* | *"byte-ceiling: OK"*)
    bad "the refusal is not dressed as a clean measurement" "out=$OUT"
    ;;
  *) ok "the refusal is not dressed as a clean measurement" ;;
esac

RC=0
OUT="$(cd "$R" && "$SCRIPTS/byte-ceiling" --all 2>&1)" || RC=$?
[ "$RC" -eq 2 ] \
  && ok "--all refuses it too, where ls-files emits one record per stage" \
  || bad "--all refuses it too, where ls-files emits one record per stage" "rc=$RC out=$OUT"

# Control: the guard did not replace the measurement. A merged index with a
# genuinely new oversized file still fails the ceiling, and a merged index
# with nothing oversized still passes.
new_repo bc-merged
printf 'seed\n' >"$R/seed.txt"
git -C "$R" add -A
git -C "$R" commit -qm base
head -c 400000 /dev/zero | tr '\0' 'a' >"$R/big.txt"
git -C "$R" add -A
RC=0
OUT="$(cd "$R" && "$SCRIPTS/byte-ceiling" 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && case "$OUT" in *big.txt*) true ;; *) false ;; esac \
  && ok "a merged index still fails an oversized addition" \
  || bad "a merged index still fails an oversized addition" "rc=$RC out=$OUT"
git -C "$R" rm -q --cached big.txt
rm -f "$R/big.txt"
printf 'small\n' >"$R/small.txt"
git -C "$R" add -A
RC=0
OUT="$(cd "$R" && "$SCRIPTS/byte-ceiling" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"byte-ceiling: OK"*) true ;; *) false ;; esac \
  && ok "a merged index with nothing oversized still passes" \
  || bad "a merged index with nothing oversized still passes" "rc=$RC out=$OUT"

echo "=== a failed policy read stops the gate, it does not become an empty list ==="

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
git -C "$R" add -A
git -C "$R" commit -qm base

RC=0
OUT="$(cd "$R" && "$SCRIPTS/todo-ban" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"todo-ban: OK"*) true ;; *) false ;; esac \
  && ok "control: with the excludes readable, the excluded marker passes" \
  || bad "control: with the excludes readable, the excluded marker passes" "rc=$RC out=$OUT"

RC=0
OUT="$(cd "$R" && PATH="$ROOT/gitstub:$PATH" "$SCRIPTS/todo-ban" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] \
  && ok "an unreadable exclusion list stops the run at exit 2" \
  || bad "an unreadable exclusion list stops the run at exit 2" "rc=$RC out=$OUT"
case "$OUT" in
  *"refusing to run on an unread exclusion list"*)
    ok "the refusal names the unread exclusion list"
    ;;
  *) bad "the refusal names the unread exclusion list" "out=$OUT" ;;
esac
# The failure mode this closes: an empty list is not "no exclusions apply".
case "$OUT" in
  *"work marker(s)"* | *"todo-ban: OK"*)
    bad "the failed read never produces a verdict" "out=$OUT"
    ;;
  *) ok "the failed read never produces a verdict" ;;
esac

echo "=== gg_install_file: the destination is replaced whole, or not at all ==="

new_repo install-file
mkdir -p "$R/tools"
printf 'ORIGINAL\n' >"$R/tools/dest.tsv"
printf 'REPLACEMENT\n' >"$ROOT/src.tsv"
call 'gg_tmpdir; gg_install_file "'"$ROOT"'/src.tsv" tools/dest.tsv "the fixture"'
[ "$RC" -eq 0 ] && [ "$(cat "$R/tools/dest.tsv")" = "REPLACEMENT" ] \
  && ok "a successful install replaces the destination" \
  || bad "a successful install replaces the destination" "rc=$RC out=$OUT content=$(cat "$R/tools/dest.tsv")"
[ -z "$(find "$R/tools" -name '*gg-install*')" ] \
  && ok "a successful install leaves no residue beside the destination" \
  || bad "a successful install leaves no residue beside the destination" "$(find "$R/tools" -name '*gg-install*')"

# mktemp creates the staging file readable by its owner alone, so a rename
# that does not take the destination's mode narrows a tracked file every
# clone reads. The control is the same call against a destination that does
# not exist yet, where there is no mode to take.
filemode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }
chmod 644 "$R/tools/dest.tsv"
call 'gg_tmpdir; gg_install_file "'"$ROOT"'/src.tsv" tools/dest.tsv "the fixture"'
[ "$RC" -eq 0 ] && [ "$(filemode "$R/tools/dest.tsv")" = 644 ] \
  && ok "an existing destination keeps its own mode" \
  || bad "an existing destination keeps its own mode" "rc=$RC mode=$(filemode "$R/tools/dest.tsv")"
chmod 755 "$R/tools/dest.tsv"
call 'gg_tmpdir; gg_install_file "'"$ROOT"'/src.tsv" tools/dest.tsv "the fixture"'
[ "$RC" -eq 0 ] && [ "$(filemode "$R/tools/dest.tsv")" = 755 ] \
  && ok "control: a mode neither the staging default nor the umask gives is kept too" \
  || bad "control: a mode neither the staging default nor the umask gives is kept too" "rc=$RC mode=$(filemode "$R/tools/dest.tsv")"
rm -f "$R/tools/fresh.tsv"
call 'gg_tmpdir; gg_install_file "'"$ROOT"'/src.tsv" tools/fresh.tsv "the fixture"'
[ "$RC" -eq 0 ] && [ "$(cat "$R/tools/fresh.tsv")" = "REPLACEMENT" ] \
  && ok "control: a destination that does not exist yet installs with no mode to take" \
  || bad "control: a destination that does not exist yet installs with no mode to take" "rc=$RC out=$OUT"

# A destination without owner-write. The mode is READ before the staging file
# is written and applied after, never carried onto it in between: staging
# under the destination's own mode makes the write fail on a file this
# process just created, and reports a staging error for what is the
# destination's mode.
printf 'REPLACED THROUGH A READ-ONLY DESTINATION\n' >"$ROOT/ro.tsv"
chmod 444 "$R/tools/dest.tsv"
call 'gg_tmpdir; gg_install_file "'"$ROOT"'/ro.tsv" tools/dest.tsv "the fixture"'
[ "$RC" -eq 0 ] && [ "$(cat "$R/tools/dest.tsv")" = "REPLACED THROUGH A READ-ONLY DESTINATION" ] \
  && ok "a destination without owner-write is still replaced" \
  || bad "a destination without owner-write is still replaced" "rc=$RC out=$OUT content=$(cat "$R/tools/dest.tsv")"
# Content AND mode in one condition: 444 survives an install that never
# happened just as well as one that did, so a mode assertion standing alone
# here cannot tell a preserved mode from a rename that stopped at a prompt.
[ "$(filemode "$R/tools/dest.tsv")" = 444 ] \
  && [ "$(cat "$R/tools/dest.tsv")" = "REPLACED THROUGH A READ-ONLY DESTINATION" ] \
  && ok "and keeps its read-only mode across the rename that replaced it" \
  || bad "and keeps its read-only mode across the rename that replaced it" "mode=$(filemode "$R/tools/dest.tsv") content=$(cat "$R/tools/dest.tsv")"
chmod 644 "$R/tools/dest.tsv"

# A SYMLINK destination. `[ -f "$dest" ]` follows the link and the mode read
# must follow it too: reading the link's own 0777 instead would publish a
# world-writable file where a 0644 one stood — and for the suppression
# baseline this helper writes, world-writable means any local account can
# lower the ratchet without repository write access.
mkdir -p "$ROOT/outside"
printf 'BEHIND THE LINK\n' >"$ROOT/outside/target.tsv"
chmod 644 "$ROOT/outside/target.tsv"
ln -sf "$ROOT/outside/target.tsv" "$R/tools/linked.tsv"
[ "$(filemode "$R/tools/linked.tsv")" != 644 ] \
  && ok "the fixture link really carries a mode of its own, unlike its target" \
  || bad "the fixture link really carries a mode of its own, unlike its target" "link=$(filemode "$R/tools/linked.tsv")"
call 'gg_tmpdir; gg_install_file "'"$ROOT"'/src.tsv" tools/linked.tsv "the fixture"'
[ "$RC" -eq 0 ] && [ "$(filemode "$R/tools/linked.tsv")" = 644 ] \
  && [ "$(cat "$R/tools/linked.tsv")" = "REPLACEMENT" ] \
  && ok "a symlink destination takes the mode of the file behind it, not the link's" \
  || bad "a symlink destination takes the mode of the file behind it, not the link's" "rc=$RC mode=$(filemode "$R/tools/linked.tsv") out=$OUT"

# A mode that cannot be read is a loud refusal, never a rename that narrows
# the destination to the staging file's owner-only bits. `stat` shadowed by a
# failing stub is the only way to reach it: every real file has a mode.
mkdir -p "$ROOT/nostat"
printf '#!/bin/sh\nexit 1\n' >"$ROOT/nostat/stat"
chmod +x "$ROOT/nostat/stat"
RC=0
OUT="$(cd "$R" && PATH="$ROOT/nostat:$PATH" GG_CHECK=probe bash -c '
  set -euo pipefail
  . "$1"
  . "$2"
  gg_tmpdir
  gg_install_file "$3" tools/dest.tsv "the fixture"
' _ "$COMMON" "$INSTALL" "$ROOT/src.tsv" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"could not read the mode of tools/dest.tsv"*) true ;; *) false ;; esac \
  && ok "an unreadable mode is a loud refusal, not a narrowing rename" \
  || bad "an unreadable mode is a loud refusal, not a narrowing rename" "rc=$RC out=$OUT"
[ "$(filemode "$R/tools/dest.tsv")" = 644 ] \
  && ok "and the destination keeps the mode it had" \
  || bad "and the destination keeps the mode it had" "mode=$(filemode "$R/tools/dest.tsv")"

# The scratch directory each step's stderr is captured into. Without one,
# GG_TMP is set-but-EMPTY, so the capture would resolve to /install.err — a
# path outside the repository, and one whose failure would itself be the bare
# shell line this capture exists to stop. Every caller in the family arms
# gg_tmpdir; one that has not is a programming error that says so.
RC=0
OUT="$(cd "$R" && GG_CHECK=probe bash -c '
  set -euo pipefail
  . "$1"
  . "$2"
  gg_install_file "$3" tools/dest.tsv "the fixture"
' _ "$COMMON" "$INSTALL" "$ROOT/src.tsv" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"needs gg_tmpdir called first"*) true ;; *) false ;; esac \
  && ok "an install with no scratch directory refuses rather than writing beside the root" \
  || bad "an install with no scratch directory refuses rather than writing beside the root" "rc=$RC out=$OUT"
[ -z "$(find "$R/tools" -name '*gg-install*')" ] \
  && ok "and stages nothing before refusing" \
  || bad "and stages nothing before refusing" "$(find "$R/tools" -name '*gg-install*')"

# The chmod branch: its whole diagnostic — the mode it could not give, and
# what chmod said — is otherwise unpinned, so it could regress to a bare
# symptom line with every suite green. A failing stub ahead of PATH, in the
# same shape as the stat and mv stubs.
mkdir -p "$ROOT/nochmod"
printf '#!/bin/sh\necho "chmod: refused by the test stub" >&2\nexit 1\n' >"$ROOT/nochmod/chmod"
chmod +x "$ROOT/nochmod/chmod"
# Its own known destination state, so this case reports on the chmod branch
# rather than on whatever the case above it managed to install.
printf 'BEFORE THE CHMOD REFUSAL\n' >"$R/tools/dest.tsv"
chmod 644 "$R/tools/dest.tsv"
RC=0
OUT="$(cd "$R" && PATH="$ROOT/nochmod:$PATH" GG_CHECK=probe bash -c '
  set -euo pipefail
  . "$1"
  . "$2"
  gg_tmpdir
  gg_install_file "$3" tools/dest.tsv "the fixture"
' _ "$COMMON" "$INSTALL" "$ROOT/src.tsv" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"could not give the replacement for the fixture tools/dest.tsv's mode (644)"*) true ;; *) false ;; esac \
  && ok "a failed chmod names the mode it could not give" \
  || bad "a failed chmod names the mode it could not give" "rc=$RC out=$OUT"
case "$OUT" in
  *"could not give the replacement"*"refused by the test stub"*)
    ok "and carries what chmod said inside its own line" ;;
  *) bad "and carries what chmod said inside its own line" "$OUT" ;;
esac
[ "$(cat "$R/tools/dest.tsv")" = "BEFORE THE CHMOD REFUSAL" ] \
  && ok "and the destination is untouched by that refusal" \
  || bad "and the destination is untouched by that refusal" "content=$(cat "$R/tools/dest.tsv")"

# A planted staging file must not redirect the write. cp writes THROUGH a
# symlink, so a staging name the repository can predict is an arbitrary-file
# overwrite waiting for the next --update. The writer publishes its own pid
# and waits, so the symlink is planted at the EXACT name a pid-derived
# scheme would choose — the control is aimed, not a guess.
new_repo install-symlink
mkdir -p "$R/tools"
printf 'ORIGINAL\n' >"$R/tools/dest.tsv"
printf 'VICTIM\n' >"$ROOT/victim.txt"
pidfile="$ROOT/writer.pid"
gofile="$ROOT/writer.go"
rm -f "$pidfile" "$gofile"
(
  cd "$R" && GG_CHECK=probe bash -c '
    set -euo pipefail
    echo "$$" >"$3"
    i=0
    while [ ! -e "$4" ] && [ "$i" -lt 200 ]; do i=$((i + 1)); sleep 0.05; done
    . "$1"
    . "$2"
    gg_tmpdir
    gg_install_file "$5" tools/dest.tsv "the fixture"
  ' _ "$COMMON" "$INSTALL" "$pidfile" "$gofile" "$ROOT/src.tsv"
) >"$ROOT/writer.out" 2>&1 &
writer=$!
i=0
while [ ! -s "$pidfile" ] && [ "$i" -lt 200 ]; do i=$((i + 1)); sleep 0.05; done
if [ -s "$pidfile" ]; then
  ln -s "$ROOT/victim.txt" "$R/tools/.gg-install.$(cat "$pidfile").dest.tsv"
  ok "the control is aimed at the pid the writer actually uses"
else
  bad "the control is aimed at the pid the writer actually uses" "no pid published"
fi
: >"$gofile"
wait "$writer" || true
[ "$(cat "$ROOT/victim.txt")" = "VICTIM" ] \
  && ok "a planted staging symlink does not redirect the write" \
  || bad "a planted staging symlink does not redirect the write" "victim=$(cat "$ROOT/victim.txt")"
[ "$(cat "$R/tools/dest.tsv")" = "REPLACEMENT" ] \
  && ok "the install still lands on its real destination" \
  || bad "the install still lands on its real destination" "content=$(cat "$R/tools/dest.tsv") out=$(cat "$ROOT/writer.out")"
[ -z "$(find "$R/tools" -name '.gg-install.*.XXXXXX' -o -name '*.gg-install.??????')" ] \
  && ok "no staging file is left behind beside the destination" \
  || bad "no staging file is left behind beside the destination" "$(find "$R/tools" -name '*gg-install*')"

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
  . "$2"
  gg_tmpdir
  gg_install_file "$3" tools/dest.tsv "the fixture"
' _ "$COMMON" "$INSTALL" "$ROOT/src.tsv" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"could not replace the fixture"*) true ;; *) false ;; esac \
  && ok "a failed rename is a loud collection error" \
  || bad "a failed rename is a loud collection error" "rc=$RC out=$OUT"
[ "$(cat "$R/tools/dest.tsv")" = "ORIGINAL" ] \
  && ok "a failed install leaves the destination byte-identical" \
  || bad "a failed install leaves the destination byte-identical" "content=$(cat "$R/tools/dest.tsv")"

echo "=== the settings cache is materialized by rename, never by a live redirect ==="

new_repo settings-cache
printf 'GROWTH_GUARDS_TODO_MAX=7\n' >"$R/kendex.settings.toml"
git -C "$R" add -A
git -C "$R" commit -qm base
RC=0
OUT="$(cd "$R" && PATH="$ROOT/stub:$PATH" GG_CHECK=probe bash -c '
  set -euo pipefail
  . "$1"
  . "$2"
  gg_settings_index_mode
  src="$(gg_settings_source kendex.settings.toml)" || exit 3
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
  src="$(gg_settings_source kendex.settings.toml)"
  cat "$src"
  find "$GG_SETTINGS_INDEX_DIR" -name "*.part" -print | sed "s/^/PART:/"
' _ "$COMMON" "$SETTINGS" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *GROWTH_GUARDS_TODO_MAX=7*) true ;; *) false ;; esac \
  && ok "the cache resolves the staged value when the rename succeeds" \
  || bad "the cache resolves the staged value when the rename succeeds" "rc=$RC out=$OUT"
case "$OUT" in
  *PART:*) bad "no partial cache file survives the resolve" "out=$OUT" ;;
  *) ok "no partial cache file survives the resolve" ;;
esac

echo "=== gg_grep_lane: content decides what is scanned, an attributes rule never does ==="

# Every index-wide lane in the family scans through gg_grep_lane. `git grep
# -I` takes its binary verdict from the path's userdiff driver, so ONE
# committed attributes row would put a whole extension outside the scan with
# no status and no stderr — a clean verdict over content never read. Each
# lane is pinned end to end, each against a control proving the same fixture
# fails without the row.
run_check() { # SCRIPT [ARG...] — RC and OUT from a run inside $R
  local script="$1"; shift; RC=0
  OUT="$(cd "$R" && "$SCRIPTS/$script" "$@" 2>&1)" || RC=$?
}

new_repo attrs-todo
# Spelled in halves so this suite is not itself a work marker.
MARKER="TO""DO"
printf 'x = 1  # %s: real\n' "$MARKER" >"$R/code.py"
git -C "$R" add -A
run_check todo-ban
[ "$RC" -eq 1 ] && case "$OUT" in *"work marker: code.py:1:"*) true ;; *) false ;; esac \
  && ok "control: the marker fails with no attributes row" \
  || bad "control: the marker fails with no attributes row" "rc=$RC out=$OUT"
printf '*.py -diff\n' >"$R/.gitattributes"
git -C "$R" add -A
# The fixture is real only if git's own -I judgement has in fact flipped.
RC=0
OUT="$(cd "$R" && git grep --cached -nIE "$MARKER" -- 'code.py' 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && [ -z "$OUT" ] \
  && ok "fixture: with '*.py -diff' a bare -I grep drops the file silently" \
  || bad "fixture: -diff makes a bare -I grep drop the file" "rc=$RC out=$OUT"
run_check todo-ban
[ "$RC" -eq 1 ] && case "$OUT" in *"work marker: code.py:1:"*) true ;; *) false ;; esac \
  && ok "the index-wide todo-ban lane still reads a '-diff' path" \
  || bad "index-wide todo-ban reads a '-diff' path" "rc=$RC out=$OUT"
case "$OUT" in *"OK — no work markers"*) bad "no clean verdict may accompany the hidden marker" "$OUT" ;; *) ok "no clean verdict accompanies the hidden marker" ;; esac
printf '*.py binary\n' >"$R/.gitattributes"
git -C "$R" add -A
run_check todo-ban
[ "$RC" -eq 1 ] && case "$OUT" in *"work marker: code.py:1:"*) true ;; *) false ;; esac \
  && ok "the 'binary' attribute macro cannot hide it either" \
  || bad "'binary' macro cannot hide the marker" "rc=$RC out=$OUT"

new_repo attrs-conflict
printf '<<<<<<< HEAD\na\n=======\nb\n>>>>>>> other\n' >"$R/merge.txt"
git -C "$R" add -A
run_check conflict-markers
[ "$RC" -eq 1 ] && case "$OUT" in *"conflict marker: merge.txt:1:"*) true ;; *) false ;; esac \
  && ok "control: the conflict markers fail with no attributes row" \
  || bad "control: conflict markers fail without the row" "rc=$RC out=$OUT"
printf '*.txt -diff\n' >"$R/.gitattributes"
git -C "$R" add -A
run_check conflict-markers
[ "$RC" -eq 1 ] && case "$OUT" in *"conflict marker: merge.txt:1:"*) true ;; *) false ;; esac \
  && ok "a '-diff' row cannot hide a conflict marker" \
  || bad "'-diff' row cannot hide a conflict marker" "rc=$RC out=$OUT"

new_repo attrs-suppression
printf '#![allow(dead_code)]\n' >"$R/lib.rs"
git -C "$R" add -A
run_check suppression-ban
[ "$RC" -eq 1 ] && case "$OUT" in *"module-wide rust allow: lib.rs:1:"*) true ;; *) false ;; esac \
  && ok "control: the blanket allow fails with no attributes row" \
  || bad "control: blanket allow fails without the row" "rc=$RC out=$OUT"
printf '*.rs -diff\n' >"$R/.gitattributes"
git -C "$R" add -A
run_check suppression-ban
[ "$RC" -eq 1 ] && case "$OUT" in *"module-wide rust allow: lib.rs:1:"*) true ;; *) false ;; esac \
  && ok "a '-diff' row cannot hide a blanket suppression" \
  || bad "'-diff' row cannot hide a blanket suppression" "rc=$RC out=$OUT"

# Gate 2, the bare-allow ratchet, counts over that same content rule. An
# attributes row that emptied its count file would read as "no bare allows
# anywhere", and the stale rows that follow print a remedy — `--update` —
# that erases the ratchet while the violations stand.
new_repo attrs-ratchet
mkdir -p "$R/tools"
printf '#[allow(dead_code)]\nfn a() {}\n' >"$R/a.rs"
printf '#[allow(dead_code)]\nfn b() {}\n' >"$R/b.rs"
printf 'b.rs\t1\n' >"$R/tools/suppression-baseline.tsv"
git -C "$R" add -A
run_check suppression-ban
[ "$RC" -eq 1 ] && case "$OUT" in *"new bare allow: a.rs"*) true ;; *) false ;; esac \
  && ok "control: the unbaselined bare allow fails with no attributes row" \
  || bad "control: unbaselined bare allow fails without the row" "rc=$RC out=$OUT"
case "$OUT" in
  *"stale baseline row: b.rs"*) bad "control: a live baseline row is not called stale" "out=$OUT" ;;
  *) ok "control: a live baseline row is not called stale" ;;
esac

printf '*.rs -diff\n' >"$R/.gitattributes"
git -C "$R" add -A
run_check suppression-ban
[ "$RC" -eq 1 ] && case "$OUT" in *"new bare allow: a.rs"*) true ;; *) false ;; esac \
  && ok "a '-diff' row cannot hide a bare allow from the ratchet count" \
  || bad "'-diff' row cannot hide a bare allow" "rc=$RC out=$OUT"
case "$OUT" in
  *"stale baseline row: b.rs"*) bad "an emptied count never turns a live row stale" "out=$OUT" ;;
  *) ok "an emptied count never turns a live row stale" ;;
esac
case "$OUT" in
  *"suppression-ban: OK"*) bad "no clean verdict accompanies the hidden bare allows" "out=$OUT" ;;
  *) ok "no clean verdict accompanies the hidden bare allows" ;;
esac

# The remedy those stale rows print, followed to its end: --update must not
# be able to write a 0-row baseline while both files still carry bare
# allows. The baseline is tighten-only, so a row dropped here never returns.
RC=0
OUT="$(cd "$R" && "$SCRIPTS/suppression-ban" --update 2>&1)" || RC=$?
[ "$(cat "$R/tools/suppression-baseline.tsv")" = "b.rs${TAB}1" ] \
  && ok "--update cannot be led into erasing the ratchet" \
  || bad "--update cannot be led into erasing the ratchet" "baseline=$(cat "$R/tools/suppression-baseline.tsv") out=$OUT"
[ "$RC" -eq 1 ] && case "$OUT" in *"new bare allow: a.rs"*) true ;; *) false ;; esac \
  && ok "the re-check after --update still fails the bare allow" \
  || bad "the re-check after --update still fails" "rc=$RC out=$OUT"

# The other half of forcing text: what the scan may NOT decode. The judgement
# is the blob's own bytes — a NUL in its leading block, git's content rule —
# so an asset whose bytes happen to spell the shape is skipped rather than
# reported as a violation record full of raw bytes.
new_repo attrs-binary
printf 'PNG\000 %s: not a marker\n' "$MARKER" >"$R/logo.png"
git -C "$R" add -A
run_check todo-ban
[ "$RC" -eq 0 ] && case "$OUT" in *"OK — no work markers"*) true ;; *) false ;; esac \
  && ok "a blob whose leading bytes carry a NUL is not scanned" \
  || bad "binary blob is not scanned" "rc=$RC out=$OUT"
case "$OUT" in *"$MARKER"*) bad "no raw bytes from the asset reach the output" "$OUT" ;; *) ok "no raw bytes from the asset reach the output" ;; esac
# The path MATCHED the banned shape and was then left unread, so it is named
# and counted apart: an unqualified OK here would be a clean verdict over
# content the lane deliberately did not scan.
case "$OUT" in
  *"todo-ban: not measured: logo.png — binary content"*)
    ok "the unread match is named, not silently dropped"
    ;;
  *) bad "the unread match is named" "out=$OUT" ;;
esac
case "$OUT" in
  *"OK — no work markers in tracked files; 1 matched path(s) not measured"*)
    ok "the verdict carries the qualifier rather than reading as a plain OK"
    ;;
  *) bad "the verdict carries the qualifier" "out=$OUT" ;;
esac
# Control: the same bytes without the NUL are text, and text is scanned.
printf 'PNG  %s: not a marker\n' "$MARKER" >"$R/logo.png"
git -C "$R" add -A
run_check todo-ban
[ "$RC" -eq 1 ] && case "$OUT" in *"work marker: logo.png:1:"*) true ;; *) false ;; esac \
  && ok "control: the same bytes without the NUL are scanned as text" \
  || bad "control: same bytes without the NUL are scanned" "rc=$RC out=$OUT"
case "$OUT" in
  *"not measured"*) bad "control: a scanned path is never named as unmeasured" "out=$OUT" ;;
  *) ok "control: a scanned path is never named as unmeasured" ;;
esac

echo "=== the shared readers fail closed, once, for every lane that uses them ==="

# gg_grep_guard, gg_read_blob and gg_blob_is_binary are the family's index
# readers: every lane collects through them, so an incomplete scan is refused
# HERE, once — including the call sites no default-lane run reaches, which
# the arms below drive through the lane that owns them.
REAL_GIT="$(command -v git)"
git_failing_on() { # ARG [LANE-ARG...] — todo-ban under a git that exits 128 for ARG
  local a="$1" dir="$TMP/git-shim-$1"; shift; mkdir -p "$dir"
  printf '#!/usr/bin/env bash\ncase " $* " in *" %s "*) echo "git %s: simulated failure" >&2; exit 128 ;; esac\nexec "%s" "$@"\n' "$a" "$a" "$REAL_GIT" >"$dir/git"
  chmod +x "$dir/git"
  under_shim "$dir" todo-ban "$@"
}
under_shim() { # SHIM-DIR SCRIPT [ARG...] — run SCRIPT with SHIM-DIR first on PATH
  local dir="$1"; shift; local script="$1"; shift; RC=0
  OUT="$(cd "$R" && PATH="$dir:$PATH" "$SCRIPTS/$script" "$@" 2>&1)" || RC=$?
}
refused() { # LABEL NEEDLE [CHECK] — exit 2 carrying NEEDLE, and never a clean verdict
  [ "$RC" -eq 2 ] && case "$OUT" in *"$2"*) true ;; *) false ;; esac \
    && ok "$1" || bad "$1" "rc=$RC out=$OUT"
  case "$OUT" in *"${3:-todo-ban}: OK"*) bad "no OK verdict may accompany $1" "$OUT" ;; *) ok "and no OK verdict accompanies it" ;; esac
}

new_repo readers
printf '// %s: stranded work\n' "$MARKER" >"$R/a.rs"
git -C "$R" add -A
run_check todo-ban
[ "$RC" -eq 1 ] && ok "control: the staged marker trips with the real git" \
  || bad "control: the staged marker trips" "rc=$RC out=$OUT"
git_failing_on grep
refused "a git grep execution failure is a collection error, never OK" "git grep failed scanning tracked files"
git_failing_on cat-file
refused "a blob read that cannot run is exit 2, never a path skipped" "refusing to skip an unread work marker"
# git spends no error status on a staged blob it cannot read: the `error:`
# line on stderr is all that separates a partial scan from a clean one.
OID="$(git -C "$R" rev-parse :a.rs)"
[ -f "$R/.git/objects/${OID:0:2}/${OID:2}" ] || bad "fixture: the staged blob is a loose object" "$OID"
rm -f -- "$R/.git/objects/${OID:0:2}/${OID:2}"
run_check todo-ban
refused "a vanished staged blob is exit 2 carrying git's own error line" "unable to read"
printf '// %s: readable\n' "$MARKER" >"$R/b.rs"
git -C "$R" add b.rs
run_check todo-ban
refused "a scan matching one file it read and one it could not is exit 2, never a violation" "unable to read"

# The --staged lane reaches the same readers through calls of its own that
# the default lane never makes: the carriers pre-filter grep, and the
# per-file content sniff that reads each staged blob. The fixture stages a
# marker, so no arm below can be clean by construction.
new_repo readers-staged
printf 'fn main() {}\n' >"$R/ok.rs"
git -C "$R" add -A
git -C "$R" commit -qm seed
printf '// %s: staged for the pre-filter to find\n' "$MARKER" >>"$R/ok.rs"
git -C "$R" add ok.rs
run_check todo-ban --staged
[ "$RC" -eq 1 ] && ok "control: the staged marker fires with the real tools" \
  || bad "control: the staged marker fires" "rc=$RC out=$OUT"
git_failing_on grep --staged
refused "a broken staged pre-filter is a collection error, never OK" "git grep failed listing the staged files that carry a work marker"
git_failing_on cat-file --staged
refused "a staged blob the sniff cannot read is exit 2, never a path skipped" "refusing to skip an unread work marker"

# gg_blob_is_binary sizes the leading bytes twice, and neither count may
# decide the verdict after failing: a silent zero out of the NUL strip reads
# as "every byte was a NUL" and folds an unread blob into a clean pass. One
# shim per count — the wc shim fails once, so the first count fails while
# the second succeeds; the tr shim breaks only the strip inside the second.
COUNT_SHIM="$TMP/count-shim"
mkdir -p "$COUNT_SHIM"
printf '#!/usr/bin/env bash\nif [ ! -e "%s" ]; then : >"%s"; echo "wc: simulated execution failure" >&2; exit 1; fi\nexec "%s" "$@"\n' \
  "$TMP/wc-fired" "$TMP/wc-fired" "$(command -v wc)" >"$COUNT_SHIM/wc"
chmod +x "$COUNT_SHIM/wc"
rm -f "$TMP/wc-fired"
under_shim "$COUNT_SHIM" todo-ban --staged
refused "a first block that cannot be sized is exit 2, never OK" "could not sample ok.rs to classify its content"
TR_SHIM="$TMP/tr-shim"
mkdir -p "$TR_SHIM"
printf '#!/usr/bin/env bash\necho "tr: simulated execution failure" >&2\nexit 1\n' >"$TR_SHIM/tr"
chmod +x "$TR_SHIM/tr"
under_shim "$TR_SHIM" todo-ban --staged
refused "a NUL-free count that cannot run is exit 2, never OK" "could not sample ok.rs to classify its content"

# suppression-ban's per-carrier count is its own call, made after the shared
# listing has already named the carrier, and it is the one gg_grep_guard site
# outside lib/. The shim errors that call alone and exits 0, so the `error:`
# line gg_grep_guard reads off stderr is the only thing left that can refuse
# a count which would otherwise read as a clean zero.
new_repo readers-count
mkdir -p "$R/tools"
printf 'fn main() {}\n' >"$R/ok.rs"
printf '#[allow(dead_code)]\nfn b() {}\n' >"$R/bare.rs"
printf 'bare.rs\t1\n' >"$R/tools/suppression-baseline.tsv"
git -C "$R" add -A
run_check suppression-ban
[ "$RC" -eq 0 ] && ok "control: the baselined bare allow passes with the real git" \
  || bad "control: the baselined bare allow passes" "rc=$RC out=$OUT"
SB_COUNT_SHIM="$TMP/git-shim-count"
mkdir -p "$SB_COUNT_SHIM"
printf '#!/usr/bin/env bash\ncase " $* " in *" -acE "*) echo "error: %s: unable to read %s" >&2; exit 0 ;; esac\nexec "%s" "$@"\n' \
  "'phantom.rs'" "0000000000000000000000000000000000000000" "$REAL_GIT" >"$SB_COUNT_SHIM/git"
chmod +x "$SB_COUNT_SHIM/git"
under_shim "$SB_COUNT_SHIM" suppression-ban
refused "a count whose stderr carries an error line is exit 2, never a clean zero" "could not read staged content while counting the bare allows" suppression-ban

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
