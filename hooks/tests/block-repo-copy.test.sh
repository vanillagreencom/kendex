#!/usr/bin/env bash
# Tests for the block-repo-copy hook.
#
# The hook refuses a recursive copy of a source carrying repository history or
# a build tree into a temp/scratch destination. These cases pin both halves of
# that predicate independently — an expensive source with a non-scratch
# destination passes, and a scratch destination with an ordinary source passes
# — plus the fast exit that keeps every non-copy Bash call free of subprocess
# work.
#
# Fixtures are marker directories created with mkdir/touch.
#
# HOOK_UNDER_TEST overrides the script under test so the must-fail controls
# (a no-op hook, an always-block hook) can be run against these same
# assertions.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOK="${HOOK_UNDER_TEST:-$(cd "$TEST_DIR/.." && pwd)/block-repo-copy.sh}"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

ERR_FILE="$TMP_ROOT/stderr"
SHIM_LOG="$TMP_ROOT/shim.log"

# --- PATH shims that record every external tool the hook reaches for ---------
# Each wrapper logs its own name and then execs the real binary, so a run's
# behavior is unchanged while the log proves whether any work happened past
# the fast exit. `cat` is deliberately not shimmed: it reads stdin before any
# decision and would log on every call.
BIN_DIR="$TMP_ROOT/bin"
mkdir -p "$BIN_DIR"
for tool in jq sed grep tr git rsync cp tar; do
  real="$(command -v "$tool" 2>/dev/null || true)"
  [ -n "$real" ] || continue
  cat >"$BIN_DIR/$tool" <<EOF
#!/usr/bin/env bash
echo "$tool" >>"\$SHIM_LOG"
exec "$real" "\$@"
EOF
  chmod +x "$BIN_DIR/$tool"
done

# Run the hook with a Bash tool-call payload on stdin. The temp roots are
# pinned so scratch classification does not depend on the caller's
# environment; individual cases re-add a root via extra VAR=value args.
# Captures stderr in $err and the exit code in $rc.
run_hook() {
  local command_json
  command_json=$(printf '%s' "$1" | sed 's/\\/\\\\/g; s/"/\\"/g')
  shift
  : >"$SHIM_LOG"
  set +e
  env -u CLAUDE_CODE_TMPDIR TMPDIR=/tmp PATH="$BIN_DIR:$PATH" SHIM_LOG="$SHIM_LOG" "$@" \
    bash "$HOOK" <<<"{\"tool_name\":\"Bash\",\"tool_input\":{\"command\":\"$command_json\"}}" \
    >/dev/null 2>"$ERR_FILE"
  rc=$?
  set -e
  err="$(cat "$ERR_FILE")"
  shims="$(cat "$SHIM_LOG" 2>/dev/null || true)"
}

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
  local got="$1" needle="$2" name="$3"
  if [[ "$got" == *"$needle"* ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected to contain: %s\n        got:      %s\n' "$name" "$needle" "$got"
  fi
}

# --- Fixtures ----------------------------------------------------------------
FIX="$TMP_ROOT/fixtures"
# A git repository.
mkdir -p "$FIX/gitrepo/src"
mkdir -p "$FIX/gitrepo/.git"
touch "$FIX/gitrepo/src/main.rs"
# A Rust build tree, no repository history.
mkdir -p "$FIX/buildtree/target" "$FIX/buildtree/src"
touch "$FIX/buildtree/src/lib.rs"
# A Node dependency tree.
mkdir -p "$FIX/nodetree/node_modules" "$FIX/nodetree/src"
# A git worktree: `.git` is a FILE pointing at the common dir, not a directory.
mkdir -p "$FIX/worktree/src"
printf 'gitdir: /elsewhere/.git/worktrees/wt\n' >"$FIX/worktree/.git"
# The same shape with none of the markers.
mkdir -p "$FIX/plain/docs"
touch "$FIX/plain/docs/notes.md" "$FIX/plain/README.md"
# A subdirectory OF a repository, itself carrying no markers.
SUBDIR="$FIX/gitrepo/src"

SCRATCH=/tmp/block-repo-copy-dest
NON_SCRATCH=/srv/archive/keepme

echo "=== block-repo-copy: blocked copy shapes ==="

run_hook "cp -r $FIX/gitrepo $SCRATCH"
assert_eq "$rc" "2" "cp -r of a git repo into /tmp is refused"

run_hook "cp -R $FIX/buildtree $SCRATCH"
assert_eq "$rc" "2" "cp -R of a build tree into /tmp is refused"

run_hook "cp -a $FIX/nodetree $SCRATCH"
assert_eq "$rc" "2" "cp -a of a node_modules tree into /tmp is refused"

run_hook "cp -rv $FIX/gitrepo $SCRATCH"
assert_eq "$rc" "2" "a combined short-flag cluster still counts as recursive"

run_hook "rsync -a $FIX/gitrepo/ $SCRATCH"
assert_eq "$rc" "2" "rsync -a of a git repo into /tmp is refused"

run_hook "rsync --archive $FIX/buildtree $SCRATCH"
assert_eq "$rc" "2" "rsync --archive of a build tree into /tmp is refused"

run_hook "git clone $FIX/gitrepo $SCRATCH"
assert_eq "$rc" "2" "git clone of a local repo into /tmp is refused"

run_hook "tar -cf - -C $FIX gitrepo | tar -xf - -C $SCRATCH"
assert_eq "$rc" "2" "a tar create-to-extract pipe into /tmp is refused"

run_hook "(cd $FIX && tar cf - buildtree) | (cd $SCRATCH && tar xf -)"
assert_eq "$rc" "2" "a tar pipe using cd for both ends is refused"

run_hook "mkdir -p $SCRATCH && cp -a $FIX/gitrepo $SCRATCH"
assert_eq "$rc" "2" "the copy is found in a chained command"

run_hook "cp -r $FIX/worktree $SCRATCH"
assert_eq "$rc" "2" "a worktree whose .git is a file is still a repository"

echo "=== block-repo-copy: scratch destination forms ==="

run_hook "cp -r $FIX/gitrepo /var/tmp/keep"
assert_eq "$rc" "2" "/var/tmp is a scratch destination"

run_hook 'cp -r '"$FIX"'/gitrepo $TMPDIR/keep'
assert_eq "$rc" "2" "an unexpanded \$TMPDIR destination is a scratch destination"

run_hook 'cp -r '"$FIX"'/gitrepo $(mktemp -d)'
assert_eq "$rc" "2" "a mktemp -d destination is a scratch destination"

run_hook "cp -r $FIX/gitrepo /home/agent/scratchpad/copy"
assert_eq "$rc" "2" "a path containing scratchpad is a scratch destination"

run_hook "cp -r $FIX/gitrepo /srv/agent-tmp/copy" CLAUDE_CODE_TMPDIR=/srv/agent-tmp
assert_eq "$rc" "2" "CLAUDE_CODE_TMPDIR names a scratch root"

echo "=== block-repo-copy: the refusal names the cause and the alternatives ==="

run_hook "cp -r $FIX/buildtree $SCRATCH"
assert_contains "$err" "$FIX/buildtree (contains target)" "the refusal names the source and the marker that made it expensive"
assert_contains "$err" "$SCRATCH (temp/scratch)" "the refusal names the destination"
assert_contains "$err" "ENOSPC" "the refusal names the failure the copy causes"
assert_contains "$err" "Read the source in place" "the refusal offers reading in place"
assert_contains "$err" "MINIMAL synthetic fixture" "the refusal offers a minimal fixture"
assert_contains "$err" 'mktemp -d' "the refusal shows how to build the fixture"

echo "=== block-repo-copy: commands that must pass ==="

# Same destination, same command shape, source without any marker: the source
# half of the predicate is what decides.
run_hook "cp -r $FIX/plain $SCRATCH"
assert_eq "$rc" "0" "a source with no repository or build tree is copied freely"

# Same source, same command shape, ordinary destination: the destination half
# of the predicate is what decides.
run_hook "cp -r $FIX/buildtree $NON_SCRATCH"
assert_eq "$rc" "0" "a build tree copied to a non-scratch destination is allowed"

run_hook "cp -r $SUBDIR $SCRATCH"
assert_eq "$rc" "0" "a repository subdirectory carrying no markers is not treated as the repository"

run_hook "cp $FIX/plain/README.md $SCRATCH/README.md"
assert_eq "$rc" "0" "a non-recursive single-file copy is allowed"

run_hook "cp -r $FIX/plain/docs $SCRATCH/docs"
assert_eq "$rc" "0" "a small legitimate directory copy into scratch is allowed"

run_hook "rsync -R $FIX/gitrepo $SCRATCH"
assert_eq "$rc" "0" "rsync -R is --relative, not recursion, so it is not a tree copy"

run_hook "git status --short"
assert_eq "$rc" "0" "a non-copy command passes"

run_hook "ls -la $FIX/gitrepo $SCRATCH"
assert_eq "$rc" "0" "reading a repository next to a scratch path is not a copy"

echo "=== block-repo-copy: the fast exit does no work ==="

# A non-copy command must reach no external tool at all. The shim log is the
# instrument; the case below proves it records when work does happen.
run_hook "git status --short"
assert_eq "$shims" "" "a non-copy command invokes no external tool"

run_hook "cp -r $FIX/gitrepo $SCRATCH"
if [ -n "$shims" ]; then
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "the shim log records tool use when the hook does evaluate a copy"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "the shim log records tool use when the hook does evaluate a copy"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
