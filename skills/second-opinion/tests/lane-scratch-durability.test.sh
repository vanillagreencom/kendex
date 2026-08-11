#!/usr/bin/env bash
# Regression test for multi-lane scratch durability (VST-221).
#
# The multi-lane parent kept two things in one `mktemp -d` scratch directory:
# each lane's captured stderr, and a `wrap-<lane>.json` re-wrap of the lane's
# review that the union merge read back at the end. Anything that removed that
# directory mid-run — the reviewed repo's own agent CLI, a sandbox, a tmp
# reaper — made the parent report BOTH healthy lanes as "unparseable" and exit
# 4 with no external verdict, even though both lane artifacts sat intact and
# valid beside the union path.
#
# Contract pinned here: once a lane is reaped, its review is held in memory, so
# the union no longer depends on any scratch file surviving; losing scratch
# costs the stderr replay and nothing else. And a lane that exits 0 without a
# usable artifact is reported with a truthful lane-failure code, never a bare
# "exit 0".
#
# Drives a hermetic copy of the skill (vstack#580) with fake lane CLIs.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

mkdir -p "$TMP_ROOT/proj/skills"
git init -q "$TMP_ROOT/proj"
cp -R "$REPO_ROOT/skills/second-opinion" "$TMP_ROOT/proj/skills/second-opinion"
SECOND_OPINION="$TMP_ROOT/proj/skills/second-opinion/scripts/second-opinion"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1" >&2; }

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    pass "$name"
  else
    fail "$name"
    printf '        expected: %s\n        got:      %s\n' "$want" "$got" >&2
  fi
}

assert_file_exists() {
  local file="$1" name="$2"
  if [[ -f "$file" ]]; then
    pass "$name"
  else
    fail "$name"
    printf '        expected file to exist: %s\n' "$file" >&2
  fi
}

assert_jq() {
  local file="$1" expr="$2" want="$3" name="$4" got
  got="$(jq -r "$expr" "$file" 2>/dev/null || echo "JQ_ERROR")"
  assert_eq "$got" "$want" "$name"
}

assert_stderr_has() {
  local needle="$1" name="$2"
  if grep -qF "$needle" "$TMP_ROOT/last.stderr"; then
    pass "$name"
  else
    fail "$name"
    printf '        expected stderr to contain: %s\n' "$needle" >&2
  fi
}

assert_stderr_lacks() {
  local needle="$1" name="$2"
  if grep -qF "$needle" "$TMP_ROOT/last.stderr"; then
    fail "$name"
    printf '        expected stderr NOT to contain: %s\n' "$needle" >&2
  else
    pass "$name"
  fi
}

# --- Reviewed repo ------------------------------------------------------------
WORK="$TMP_ROOT/work"
mkdir -p "$WORK"
git -C "$WORK" init -q
git -C "$WORK" config user.email test@example.com
git -C "$WORK" config user.name test
printf 'hello\n' > "$WORK/file.txt"
git -C "$WORK" add file.txt
git -C "$WORK" -c commit.gpgsign=false commit -q -m init
printf 'world\n' >> "$WORK/file.txt"

# --- Scratch sandbox ----------------------------------------------------------
# TMPDIR is pointed at a directory this test owns, so the reaper stub below can
# remove exactly the parent's `mktemp -d` scratch directory (the only directory
# there; every other temp entry the script makes is a plain file) instead of
# touching the ambient /tmp.
SCRATCH="$TMP_ROOT/scratch"
mkdir -p "$SCRATCH"

mkdir -p "$TMP_ROOT/bin"

# Lane stub that answers normally.
cat > "$TMP_ROOT/bin/lane-claude" <<SH
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
cat "$TMP_ROOT/resp-claude.json"
SH

# Lane stub that answers normally AND removes the parent's scratch directory
# before exiting — the reviewed repo's own agent CLI cleaning temp space under
# the parent, which is what the field report showed. The parent cannot reap
# this lane until the stub exits, so the removal always lands before the union
# step reads anything back.
cat > "$TMP_ROOT/bin/lane-codex-scratch" <<SH
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
cat "$TMP_ROOT/resp-codex.json"
find "$SCRATCH" -mindepth 1 -maxdepth 1 -type d -name 'tmp.*' -exec rm -rf {} + 2>/dev/null || true
SH

# Lane stub that waits for the OTHER lane's artifact to appear, deletes it, and
# only then answers — a deterministic handshake for "the lane exited 0 but its
# artifact is not on disk", with no sleep-based timing assumption.
cat > "$TMP_ROOT/bin/lane-codex-steal" <<SH
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
target="\$(cat "$TMP_ROOT/steal-target")"
waited=0
while [[ ! -f "\$target" && \$waited -lt 300 ]]; do
  sleep 0.1
  waited=\$((waited + 1))
done
rm -f "\$target"
cat "$TMP_ROOT/resp-codex.json"
SH
chmod +x "$TMP_ROOT/bin/lane-claude" "$TMP_ROOT/bin/lane-codex-scratch" "$TMP_ROOT/bin/lane-codex-steal"

cat > "$TMP_ROOT/resp-claude.json" <<'JSON'
{"agent":"external-claude","timestamp":"2026-01-01T00:00:00Z","verdict":"action_required",
 "summary":"one blocker",
 "blockers":[{"id":1,"title":"Off-by-one in parse","location":"src/app.rs (`parse`)","description":"d","recommendation":"r","priority":2,"estimate":1}],
 "suggestions":[],"questions":[],"qa_metadata":{}}
JSON

cat > "$TMP_ROOT/resp-codex.json" <<'JSON'
{"agent":"external-codex","timestamp":"2026-01-01T00:00:00Z","verdict":"pass","summary":"clean",
 "blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}
JSON

# run_multi <codex-stub> [args...] — always under the sandboxed TMPDIR.
run_multi() {
  local codex_stub="$1"
  shift
  local rc=0
  set +e
  env TMPDIR="$SCRATCH" \
    SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/lane-claude" \
    SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/$codex_stub" \
    "$SECOND_OPINION" review --range HEAD --cwd "$WORK" "$@" \
    >/dev/null 2>"$TMP_ROOT/last.stderr"
  rc=$?
  set -e
  return "$rc"
}

# --- Scenario 1: scratch removed mid-run still unions both lanes --------------
echo "=== scenario 1: scratch dir removed mid-run -> union still written ==="
out1="$TMP_ROOT/out1.json"
rc1=0
run_multi lane-codex-scratch --output "$out1" || rc1=$?
assert_eq "$rc1" "0" "losing scratch does not fail the run"
assert_file_exists "$out1" "union artifact written despite lost scratch"
assert_jq "$out1" '.agent' "external-union(codex+claude)" "both lanes present in the union"
assert_jq "$out1" '.qa_metadata.coverage' "full" "coverage stays full — no lane actually failed"
assert_jq "$out1" '.qa_metadata.lanes | length' "2" "both lanes recorded in qa_metadata.lanes"
assert_jq "$out1" '.blockers | length' "1" "the answering lane's finding survives into the union"
assert_stderr_lacks "unparseable artifact" "a lost scratch file is not called an unparseable artifact"
assert_stderr_has "lane stderr unavailable" "the lost stderr replay is reported honestly"
assert_file_exists "$out1.codex.json" "codex lane artifact kept beside the union"
assert_file_exists "$out1.claude.json" "claude lane artifact kept beside the union"

# --- Scenario 2: clean exit with no usable artifact is not "exit 0" -----------
# A lane whose artifact is gone by the time it is reaped never delivered an
# answer — a lane-level failure. It must be recorded with a truthful code, not
# the bare "exit 0" the reaped child happened to return.
echo "=== scenario 2: lane exits 0 with no artifact -> truthful failure code ==="
out2="$TMP_ROOT/out2.json"
printf '%s\n' "$out2.claude.json" > "$TMP_ROOT/steal-target"
rc2=0
run_multi lane-codex-steal --output "$out2" || rc2=$?
assert_eq "$rc2" "0" "the surviving lane keeps the run at exit 0"
assert_jq "$out2" '.qa_metadata.coverage' "degraded" "the lost lane degrades coverage"
assert_jq "$out2" '[.qa_metadata.lanes[] | select(.target == "claude")][0].exit_code' "5" \
  "the lost lane records the never-answered code, not 0"
assert_stderr_has "without a usable artifact" "the missing artifact is named as the cause"
assert_stderr_lacks "(exit 0)" "a failed lane is never reported as exit 0"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
