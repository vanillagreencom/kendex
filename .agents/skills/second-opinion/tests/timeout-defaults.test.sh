#!/usr/bin/env bash
# Regression test for the script's timeout handling: the built-in default is
# 1080s, a caller env override wins, --timeout 0 is refused, and a host
# without a timeout binary warns and still runs.
#
# What the launch does to the CLI's process tree is process-tree.test.sh's,
# which builds a CLI with a child of its own and asserts the whole tree goes.

set -euo pipefail

# Declare this session as having no model (none), so the cross-model
# guard neither depends on nor is defeated by the harness running the tests.
export SECOND_OPINION_CURRENT_MODEL=none

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
# shellcheck source=lib/path-farm.bash
. "$SCRIPT_DIR/lib/path-farm.bash"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# --- Deterministic harness-free session -------------------------------------
# A positively detected single-model harness now beats any contradicting
# declaration, whatever its source — so a suite can no longer neutralize the
# harness that runs it by exporting an identity. It has to actually not have
# one. This `ps` stand-in reports the first parent as init, so the ancestor walk
# finds nothing and the declared identity below is what the script uses. It also
# makes these suites independent of where they run: same result under Claude
# Code, under Codex, and in CI.
_PSBIN="$TMP_ROOT/psbin"
mkdir -p "$_PSBIN"
cat > "$_PSBIN/ps" <<'PSSH'
#!/usr/bin/env bash
mode=""; while [[ $# -gt 0 ]]; do case "$1" in -o) mode="$2"; shift 2 ;; *) shift ;; esac; done
case "$mode" in ppid=) printf '1\n' ;; comm=) printf 'bash\n' ;; esac
PSSH
chmod +x "$_PSBIN/ps"
PATH="$_PSBIN:$PATH"
export PATH
# The process tree is only half the signal; the environment markers are the
# other half, and this session's are inherited. Drop them too.
unset CLAUDECODE CLAUDE_CODE CLAUDE_PROJECT_DIR CODEX_SANDBOX \
      CODEX_SANDBOX_NETWORK_DISABLED PI_CODING_AGENT_DIR OPENCODE \
      CURSOR_AGENT CURSOR_TRACE_ID

# Hermetic copy: the script resolves PROJECT_ROOT from its own location and
# loads that project's settings files, so running the in-repo copy leaks the
# repository's committed kendex.settings.toml (e.g. SECOND_OPINION_TIMEOUT)
# into a test that pins the BUILT-IN default (kendex#580). Copy the skill to
# a temp root with no git repo and no settings so only defaults + caller env
# apply.
mkdir -p "$TMP_ROOT/proj/skills"
git init -q "$TMP_ROOT/proj"
cp -R "$REPO_ROOT/skills/second-opinion" "$TMP_ROOT/proj/skills/second-opinion"
SECOND_OPINION="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion"

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/work"

# The scope gate (kendex#652) needs a git worktree with a non-empty diff, so
# review runs use `--range HEAD` over an uncommitted change.
WORK="$TMP_ROOT/work"
git -C "$WORK" init -q
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name test
printf 'hello\n' > "$WORK/file.txt"
git -C "$WORK" add file.txt
git -C "$WORK" -c commit.gpgsign=false commit -q -m init
printf 'world\n' >> "$WORK/file.txt"

cat > "$TMP_ROOT/bin/codex" <<'SH'
#!/usr/bin/env bash
cat >/dev/null
printf '%s\n' '{"agent":"external-codex","verdict":"pass","summary":"ok","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}'
SH
chmod +x "$TMP_ROOT/bin/codex"

assert_contains() {
  local file="$1" expected="$2" label="$3"
  if grep -Fq "$expected" "$file"; then
    printf 'PASS: %s\n' "$label"
  else
    printf 'FAIL: %s\n  expected to find: %s\n  in: %s\n' "$label" "$expected" "$file" >&2
    sed -n '1,80p' "$file" >&2 || true
    exit 1
  fi
}

default_stderr="$TMP_ROOT/default.stderr"
resolved_timeout="$(command -v timeout || command -v gtimeout || true)"
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null 2>"$default_stderr"

assert_contains "$default_stderr" "timeout=1080s" "default timeout resolves to documented 1080s"
if [[ -n "$resolved_timeout" ]]; then
  assert_contains "$default_stderr" "cmd: $resolved_timeout --foreground -k 30 1080s " "launch log includes resolved default timeout"
  assert_contains "$default_stderr" "second-opinion-runtime group-run" "launch log includes CLI process-group ownership"
else
  assert_contains "$default_stderr" "cmd: direct " "launch log names direct default execution"
  assert_contains "$default_stderr" "second-opinion-runtime group-run" "direct execution still owns the CLI process group"
fi

override_stderr="$TMP_ROOT/override.stderr"
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex \
  SECOND_OPINION_TIMEOUT=7 \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null 2>"$override_stderr"

assert_contains "$override_stderr" "timeout=7s" "caller timeout override wins"
if [[ -n "$resolved_timeout" ]]; then
  assert_contains "$override_stderr" "cmd: $resolved_timeout --foreground -k 30 7s " "launch log includes resolved override timeout"
  if ! grep -Eq -- '--foreground -k 30 7s .*group-run .* codex$' "$override_stderr"; then
    sed -n '1,80p' "$override_stderr" >&2 || true
    printf 'FAIL: override launch puts codex last, after the timeout and group-run arguments\n' >&2
    exit 1
  fi
  printf 'PASS: override launch puts codex last, after the timeout and group-run arguments\n'
else
  assert_contains "$override_stderr" "cmd: direct " "launch log names direct override execution"
fi

# GNU timeout reads 0 as "no limit at all", so --timeout 0 must be refused
# rather than silently disabling the deadline.
zero_stderr="$TMP_ROOT/zero.stderr"
zero_rc=0
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --timeout 0 >/dev/null 2>"$zero_stderr" || zero_rc=$?
if [[ $zero_rc -eq 0 ]]; then
  printf 'FAIL: --timeout 0 must exit non-zero\n' >&2
  exit 1
fi
assert_contains "$zero_stderr" "must be a positive integer" "--timeout 0 is refused"

# A host without timeout/gtimeout (stock macOS) still runs the review — with a
# warning, not a refusal. Hide both binaries behind a symlink farm of the rest
# of PATH.
NOTIMEOUT="$TMP_ROOT/notimeout"
path_farm_without "$NOTIMEOUT" timeout gtimeout

notimeout_stderr="$TMP_ROOT/notimeout.stderr"
PATH="$TMP_ROOT/bin:$NOTIMEOUT" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null 2>"$notimeout_stderr"

assert_contains "$notimeout_stderr" "run without a time limit" "missing timeout binary warns instead of refusing"
assert_contains "$notimeout_stderr" "cmd: direct " "missing timeout binary logs direct execution"
assert_contains "$notimeout_stderr" "second-opinion-runtime group-run" "missing timeout binary still owns the CLI process group"
assert_contains "$notimeout_stderr" "Response received" "review still runs without a timeout binary"

notimeout_override_stderr="$TMP_ROOT/notimeout-override.stderr"
PATH="$TMP_ROOT/bin:$NOTIMEOUT" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex \
  SECOND_OPINION_TIMEOUT=7 \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null \
    2>"$notimeout_override_stderr"
assert_contains "$notimeout_override_stderr" "timeout=7s" \
  "missing-timeout mode preserves the caller override"
assert_contains "$notimeout_override_stderr" "cmd: direct " \
  "missing-timeout override uses direct execution"
