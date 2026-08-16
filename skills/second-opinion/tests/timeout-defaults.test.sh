#!/usr/bin/env bash
# Regression test: shipped project settings must keep the documented
# second-opinion default timeout at 300s, while caller env overrides still win.

set -euo pipefail

# Declare this session as having no model (none), so the cross-model
# guard neither depends on nor is defeated by the harness running the tests.
export SECOND_OPINION_CURRENT_MODEL=none

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
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
# repository's committed vstack.settings.toml (e.g. SECOND_OPINION_TIMEOUT)
# into a test that pins the BUILT-IN default (vstack#580). Copy the skill to
# a temp root with no git repo and no settings so only defaults + caller env
# apply.
mkdir -p "$TMP_ROOT/proj/skills"
git init -q "$TMP_ROOT/proj"
cp -R "$REPO_ROOT/skills/second-opinion" "$TMP_ROOT/proj/skills/second-opinion"
SECOND_OPINION="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion"

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/work"

# The scope gate (vstack#652) needs a git worktree with a non-empty diff, so
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
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null 2>"$default_stderr"

assert_contains "$default_stderr" "timeout=300s" "default timeout resolves to documented 300s"
assert_contains "$default_stderr" "cmd: timeout 300s codex" "launch log includes explicit default timeout"

override_stderr="$TMP_ROOT/override.stderr"
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex \
  SECOND_OPINION_TIMEOUT=7 \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null 2>"$override_stderr"

assert_contains "$override_stderr" "timeout=7s" "caller timeout override wins"
assert_contains "$override_stderr" "cmd: timeout 7s codex" "launch log includes explicit override timeout"
