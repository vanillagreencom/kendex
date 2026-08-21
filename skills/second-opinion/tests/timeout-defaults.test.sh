#!/usr/bin/env bash
# Regression test: shipped project settings must keep the documented
# second-opinion default timeout at 1080s, while caller env overrides still win,
# the retry runs inside that one total budget, the run refuses when no timeout
# binary can bound it, a CLI that ignores the deadline's TERM is still killed,
# and every doc and settings surface spells the shipped default.

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

# The script refuses to run the external CLI with no deadline, so a host
# without timeout or gtimeout cannot run this suite at all — a skip, not a
# failure. The refusal itself is asserted below, on a fixture PATH.
REAL_TIMEOUT=""
for _t in timeout gtimeout; do
  REAL_TIMEOUT=$(type -P "$_t") && break
  REAL_TIMEOUT=""
done
unset _t
if [[ -z "$REAL_TIMEOUT" ]]; then
  printf 'SKIP: no timeout (or gtimeout) on PATH; the script cannot run here\n'
  exit 0
fi

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
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null 2>"$default_stderr"

assert_contains "$default_stderr" "timeout=1080s" "default timeout resolves to documented 1080s"
assert_contains "$default_stderr" "cmd: timeout 1080s codex" "launch log includes explicit default timeout"

override_stderr="$TMP_ROOT/override.stderr"
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex \
  SECOND_OPINION_TIMEOUT=7 \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null 2>"$override_stderr"

assert_contains "$override_stderr" "timeout=7s" "caller timeout override wins"
assert_contains "$override_stderr" "cmd: timeout 7s codex" "launch log includes explicit override timeout"

# --- Retry runs inside the same total budget ---------------------------------
# The timeout is one lane total: on a malformed first response the retry gets
# TIMEOUT minus the time already spent (floored), never a fresh full window —
# otherwise a valid run could take nearly twice the documented budget and
# outlive every caller that budgets on it.
cat > "$TMP_ROOT/bin/codex-flaky" <<SH
#!/usr/bin/env bash
cat >/dev/null
if [[ -f "$TMP_ROOT/flaky-called" ]]; then
  printf '%s\n' '{"agent":"external-codex","verdict":"pass","summary":"ok","blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}'
else
  touch "$TMP_ROOT/flaky-called"
  sleep 3
  printf 'not json at all\n'
fi
SH
chmod +x "$TMP_ROOT/bin/codex-flaky"

retry_stderr="$TMP_ROOT/retry.stderr"
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex-flaky \
  SECOND_OPINION_TIMEOUT=200 \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null 2>"$retry_stderr"

assert_contains "$retry_stderr" "cmd: timeout 200s codex-flaky" "first invocation gets the full budget"
retry_limit=$(grep -o 'cmd: timeout [0-9]*s' "$retry_stderr" | sed -n '2s/[^0-9]//gp')
if [[ "$retry_limit" =~ ^[0-9]+$ && "$retry_limit" -lt 200 && "$retry_limit" -ge 60 ]]; then
  printf 'PASS: retry gets the remainder of the total budget (%ss)\n' "$retry_limit"
else
  printf 'FAIL: retry gets the remainder of the total budget (second limit: %s)\n' "${retry_limit:-none}" >&2
  sed -n '1,80p' "$retry_stderr" >&2
  exit 1
fi

# A nearly exhausted budget floors rather than handing GNU timeout a zero or a
# negative (zero = wait forever): the first call answers malformed just inside
# its window and leaves at most a second of budget, so the retry runs under
# exactly the floor.
rm -f "$TMP_ROOT/flaky-called"
floor_stderr="$TMP_ROOT/floor.stderr"
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex-flaky \
  SECOND_OPINION_TIMEOUT=4 \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" >/dev/null 2>"$floor_stderr"

assert_contains "$floor_stderr" "cmd: timeout 60s codex-flaky" "exhausted budget floors the retry at 60s"

# A zero-padded override (--timeout 0900) is digits-only but reads as an octal
# literal in arithmetic: unnormalized it survives the first invocation and
# aborts the retry-remainder computation with "value too great for base".
rm -f "$TMP_ROOT/flaky-called"
octal_stderr="$TMP_ROOT/octal.stderr"
octal_rc=0
PATH="$TMP_ROOT/bin:$PATH" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex-flaky \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --timeout 0900 \
  >/dev/null 2>"$octal_stderr" || octal_rc=$?
if [[ "$octal_rc" -eq 0 ]]; then
  printf 'PASS: zero-padded --timeout survives the retry (normalized to base 10)\n'
else
  printf 'FAIL: zero-padded --timeout survives the retry (exit %s)\n' "$octal_rc" >&2
  sed -n '1,40p' "$octal_stderr" >&2
  exit 1
fi
assert_contains "$octal_stderr" "cmd: timeout 900s codex-flaky" "zero-padded timeout normalizes to 900s"

# Zero is digits but not a limit — GNU timeout reads 0 as "no timeout", so a
# zero override must be refused outright, zero-padded spellings included.
for zero in 0 000; do
  zero_stderr="$TMP_ROOT/zero-$zero.stderr"
  zero_rc=0
  PATH="$TMP_ROOT/bin:$PATH" \
    SECOND_OPINION_TARGET=codex \
    SECOND_OPINION_CODEX_CMD=codex \
    "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --timeout "$zero" \
    >/dev/null 2>"$zero_stderr" || zero_rc=$?
  if [[ "$zero_rc" -ne 0 ]] && grep -q "greater than zero" "$zero_stderr"; then
    printf 'PASS: --timeout %s is refused\n' "$zero"
  else
    printf 'FAIL: --timeout %s is refused (exit %s)\n' "$zero" "$zero_rc" >&2
    sed -n '1,20p' "$zero_stderr" >&2
    exit 1
  fi
done

# --- No timeout binary: fail closed ------------------------------------------
# Stock macOS ships neither timeout nor gtimeout, and at an 18-minute default
# silently dropping the deadline would run the external CLI unbounded — the
# run must refuse, naming the fix, before any CLI invocation. The fixture PATH
# carries everything the script reaches before the gate, and nothing else.
NOTIMEOUT_BIN="$TMP_ROOT/notimeout-bin"
mkdir -p "$NOTIMEOUT_BIN"
for tool in bash sh git jq grep sed tr cat rm mkdir rmdir head tail ps mktemp \
            cut sort uniq wc date dirname basename env printf ls cp mv chmod \
            touch awk find readlink od stat; do
  tool_path=$(command -v "$tool" 2>/dev/null) || continue
  ln -s "$tool_path" "$NOTIMEOUT_BIN/$tool"
done
cat > "$NOTIMEOUT_BIN/codex" <<SH
#!/usr/bin/env bash
touch "$TMP_ROOT/codex-invoked"
cat >/dev/null
printf 'should never run\n'
SH
chmod +x "$NOTIMEOUT_BIN/codex"

notimeout_stderr="$TMP_ROOT/notimeout.stderr"
notimeout_rc=0
PATH="$NOTIMEOUT_BIN" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" \
  >/dev/null 2>"$notimeout_stderr" || notimeout_rc=$?
if [[ "$notimeout_rc" -eq 1 ]] && grep -q "no timeout implementation" "$notimeout_stderr" \
   && grep -q "brew install coreutils" "$notimeout_stderr" \
   && [[ ! -f "$TMP_ROOT/codex-invoked" ]]; then
  printf 'PASS: a PATH without timeout/gtimeout refuses before any CLI invocation\n'
else
  printf 'FAIL: a PATH without timeout/gtimeout refuses before any CLI invocation (exit %s, invoked=%s)\n' \
    "$notimeout_rc" "$([[ -f "$TMP_ROOT/codex-invoked" ]] && echo yes || echo no)" >&2
  sed -n '1,40p' "$notimeout_stderr" >&2
  exit 1
fi

# Only an external executable counts: an exported shell function named timeout
# would let a caller's environment decide what bounds the CLI, so the same
# fixture PATH plus such a function must still refuse.
fn_stderr="$TMP_ROOT/fntimeout.stderr"
fn_rc=0
# shellcheck disable=SC2317
timeout() { "$REAL_TIMEOUT" "$@"; }
export -f timeout
PATH="$NOTIMEOUT_BIN" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" \
  >/dev/null 2>"$fn_stderr" || fn_rc=$?
unset -f timeout
if [[ "$fn_rc" -eq 1 ]] && grep -q "no timeout implementation" "$fn_stderr" \
   && [[ ! -e "$TMP_ROOT/codex-invoked" ]]; then
  printf 'PASS: an exported timeout function does not satisfy the probe\n'
else
  printf 'FAIL: an exported timeout function does not satisfy the probe (exit %s, invoked: %s)\n' \
    "$fn_rc" "$([[ -e "$TMP_ROOT/codex-invoked" ]] && echo yes || echo no)" >&2
  sed -n '1,20p' "$fn_stderr" >&2
  exit 1
fi

# --- A CLI that ignores TERM is still reaped ---------------------------------
# The deadline sends TERM, and TERM can be caught. A CLI that ignores it would
# outlive its own deadline and keep running — and billing — long after the
# lane it belonged to was resolved, so the deadline carries --kill-after and
# the KILL is what finally ends such a CLI. Its exit is 137 rather than 124,
# and the run must classify that as the deadline it is.
#
# The stub caps its own life so a regression costs the suite a bounded wait
# instead of hanging it.
make_stubborn_cli() {
  local bin_dir="$1" pid_file="$2"
  mkdir -p "$bin_dir"
  cat > "$bin_dir/codex" <<SH
#!/usr/bin/env bash
trap '' TERM
cat >/dev/null
printf '%s' "\$\$" > "$pid_file"
end=\$(( SECONDS + 120 ))
while (( SECONDS < end )); do sleep 1; done
SH
  chmod +x "$bin_dir/codex"
}

# The control runs the same stub against a copy of the script with the flag
# stripped, and it runs alongside the real one: proving the CLI is NOT reaped
# means outwaiting the grace, and doing that twice in sequence would double
# the suite's wall time for no extra evidence.
NOKILL_ROOT="$TMP_ROOT/nokill"
cp -R "$TMP_ROOT/proj" "$NOKILL_ROOT"
NOKILL_SCRIPT="$NOKILL_ROOT/skills/second-opinion/scripts/second-opinion"
sed 's/ --kill-after="\$KILL_AFTER"//' "$SECOND_OPINION" > "$NOKILL_SCRIPT"
chmod +x "$NOKILL_SCRIPT"
if grep -q -- '--kill-after' "$NOKILL_SCRIPT" || ! grep -q -- '--kill-after' "$SECOND_OPINION"; then
  printf 'FAIL: control setup did not strip --kill-after from the script copy\n' >&2
  exit 1
fi

# Its own worktree: both runs preserve a failure artifact under --cwd.
WORK_NOKILL="$TMP_ROOT/work-nokill"
cp -R "$WORK" "$WORK_NOKILL"

NOKILL_PID_FILE="$TMP_ROOT/stubborn-nokill.pid"
make_stubborn_cli "$TMP_ROOT/bin-nokill" "$NOKILL_PID_FILE"
nokill_started="$SECONDS"
PATH="$TMP_ROOT/bin-nokill:$PATH" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex \
  SECOND_OPINION_TIMEOUT=1 \
  "$NOKILL_SCRIPT" review --range HEAD --cwd "$WORK_NOKILL" \
  >/dev/null 2>"$TMP_ROOT/nokill.stderr" &
NOKILL_JOB=$!

KILL_PID_FILE="$TMP_ROOT/stubborn.pid"
make_stubborn_cli "$TMP_ROOT/bin-stubborn" "$KILL_PID_FILE"
stubborn_started="$SECONDS"
stubborn_rc=0
PATH="$TMP_ROOT/bin-stubborn:$PATH" \
  SECOND_OPINION_TARGET=codex \
  SECOND_OPINION_CODEX_CMD=codex \
  SECOND_OPINION_TIMEOUT=1 \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" \
  >/dev/null 2>"$TMP_ROOT/stubborn.stderr" || stubborn_rc=$?
stubborn_elapsed=$(( SECONDS - stubborn_started ))

stubborn_pid=$(cat "$KILL_PID_FILE" 2>/dev/null || true)
if [[ -n "$stubborn_pid" ]] && ! kill -0 "$stubborn_pid" 2>/dev/null \
   && [[ "$stubborn_rc" -eq 5 ]] && [[ "$stubborn_elapsed" -lt 90 ]] \
   && grep -q "timed out" "$TMP_ROOT/stubborn.stderr"; then
  printf 'PASS: a TERM-ignoring CLI is killed at the deadline and read as a timeout (%ss)\n' \
    "$stubborn_elapsed"
else
  printf 'FAIL: a TERM-ignoring CLI is killed at the deadline and read as a timeout (exit %s, %ss, pid %s)\n' \
    "$stubborn_rc" "$stubborn_elapsed" "${stubborn_pid:-none}" >&2
  sed -n '1,20p' "$TMP_ROOT/stubborn.stderr" >&2
  exit 1
fi

# Read the control only once its own grace window has passed, so "still alive"
# cannot mean "not killed yet".
while (( SECONDS - nokill_started < 40 )); do sleep 1; done
nokill_pid=$(cat "$NOKILL_PID_FILE" 2>/dev/null || true)
if [[ -n "$nokill_pid" ]] && kill -0 "$nokill_pid" 2>/dev/null; then
  printf 'PASS: control — without --kill-after the same CLI is still running\n'
  nokill_ok=true
else
  printf 'FAIL: control — without --kill-after the same CLI is still running (pid %s)\n' \
    "${nokill_pid:-none}" >&2
  nokill_ok=false
fi
[[ -z "$nokill_pid" ]] || kill -9 "$nokill_pid" 2>/dev/null || true
wait "$NOKILL_JOB" 2>/dev/null || true
$nokill_ok || exit 1

# --- Every surface spells the script's default ------------------------------
# The script's DEFAULT_TIMEOUT is the single source; the settings files and doc
# tables repeat the number for readers, so a bump that misses one leaves a doc
# telling users the wrong deadline — the exact drift this issue fixed. Read the
# source once and require every other surface to carry it.
DEFAULT=$(sed -n 's/^DEFAULT_TIMEOUT=\([0-9]\{1,\}\)$/\1/p' "$SECOND_OPINION")
if [[ ! "$DEFAULT" =~ ^[0-9]+$ ]]; then
  printf 'FAIL: could not read DEFAULT_TIMEOUT from the script\n' >&2
  exit 1
fi
printf 'PASS: script declares DEFAULT_TIMEOUT=%s\n' "$DEFAULT"

# Settings files get an anchored check, not assert_contains: a substring grep
# is satisfied by a commented-out line, so a drifted active value hiding under
# `# SECOND_OPINION_TIMEOUT = "1080"` would pass. Require an active line with
# the default AND no active line with any other value.
assert_settings_default() {
  local file="$1" label="$2"
  if grep -Eq "^SECOND_OPINION_TIMEOUT = \"$DEFAULT\"\$" "$file" \
     && ! grep -E '^SECOND_OPINION_TIMEOUT = ' "$file" | grep -Fvq "\"$DEFAULT\""; then
    printf 'PASS: %s\n' "$label"
  else
    printf 'FAIL: %s\n  expected exactly: SECOND_OPINION_TIMEOUT = "%s" on an active line\n  in: %s\n' \
      "$label" "$DEFAULT" "$file" >&2
    grep -n 'SECOND_OPINION_TIMEOUT' "$file" >&2 || true
    exit 1
  fi
}

SKILL_DIR="$REPO_ROOT/skills/second-opinion"
assert_settings_default "$SKILL_DIR/kendex.settings.toml.example" \
  "skill settings example seeds the default"
assert_contains "$SKILL_DIR/SKILL.md" "| \`SECOND_OPINION_TIMEOUT\` | \`$DEFAULT\` |" \
  "SKILL.md config table documents the default"
assert_contains "$SKILL_DIR/SKILL.md" "default: $DEFAULT" \
  "SKILL.md options table documents the default"
assert_contains "$SKILL_DIR/SKILL.md" "default ${DEFAULT}s" \
  "SKILL.md exit-code table documents the default"
assert_contains "$SKILL_DIR/README.md" "| \`SECOND_OPINION_TIMEOUT\` | \`\"$DEFAULT\"\` |" \
  "README working-example table documents the default"
assert_contains "$SKILL_DIR/README.md" "| \`SECOND_OPINION_TIMEOUT\` | \`$DEFAULT\` |" \
  "README config table documents the default"

# The workflow documents that quote the default as an operational number —
# each backgrounding instruction, and review-pr.md's watchdog fallback, which
# budgets the external lane on it. This skill's own workflows are mandatory;
# the orch workflows are pinned when installed beside us (kendex itself; a
# vendored install without orch still passes).
for wf_doc in "$SKILL_DIR/workflows/review.md" "$SKILL_DIR/workflows/audit.md" \
              "$SKILL_DIR/workflows/challenge.md" "$SKILL_DIR/workflows/quick.md"; do
  assert_contains "$wf_doc" "(\`SECOND_OPINION_TIMEOUT\`, ${DEFAULT}s)" \
    "$(basename "$wf_doc") quotes the shipped default"
done
for wf_doc in "$REPO_ROOT/skills/orch/workflows/review-pr.md" \
              "$REPO_ROOT/skills/orch/workflows/submit-pr.md"; do
  [[ -f "$wf_doc" ]] || continue
  assert_contains "$wf_doc" "(\`SECOND_OPINION_TIMEOUT\`, ${DEFAULT}s)" \
    "$(basename "$wf_doc") quotes the shipped default"
done
if [[ -f "$REPO_ROOT/skills/orch/workflows/review-pr.md" ]]; then
  assert_contains "$REPO_ROOT/skills/orch/workflows/review-pr.md" \
    "the script's ${DEFAULT}s default" \
    "review-pr.md watchdog fallback quotes the shipped default"
fi

# The host repo's committed settings and example, when this skill lives in one
# that carries them (kendex itself does; a vendored install without the root
# files still passes). A file that EXISTS must carry the assignment: a deleted
# key silently hands the timeout back to whatever the script ships, which is
# exactly the drift this pin exists to catch.
for host_file in "$REPO_ROOT/kendex.settings.toml" "$REPO_ROOT/kendex.settings.toml.example"; do
  [[ -f "$host_file" ]] || continue
  assert_settings_default "$host_file" \
    "$(basename "$host_file") carries the shipped default"
done
