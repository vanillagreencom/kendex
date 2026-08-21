#!/usr/bin/env bash
# Regression test: shipped project settings must keep the documented
# second-opinion default timeout at 1080s, while caller env overrides still win,
# the retry runs inside that one total budget, and every doc and settings
# surface spells the shipped default.

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
