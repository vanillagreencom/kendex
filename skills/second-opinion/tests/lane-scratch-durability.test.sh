#!/usr/bin/env bash
# Regression test for multi-lane scratch durability (VST-221).
#
# The multi-lane parent kept two things in one `mktemp -d` scratch directory:
# each lane's captured stderr, and a `wrap-<lane>.json` re-wrap of the lane's
# review that the union merge read back at the end. Anything that removed that
# directory mid-run — the reviewed repo's own agent CLI, a sandbox, a tmp
# reaper — made the parent report BOTH healthy lanes as "unparseable" and exit
# 4 with no external verdict, even though both lane artifacts sat intact and
# valid beside the union path. Without --output the lane artifacts lived in
# that same directory, so clearing it dropped a lane's real findings and the
# union still published a pass.
#
# Contract pinned here:
#   * The parent creates exactly one directory under TMPDIR and everything in
#     it is disposable — losing it costs the stderr replay and nothing else, in
#     BOTH --output and stdout mode. Each lane's review is held in memory from
#     the moment that lane is reaped.
#   * An artifact that holds no JSON value at all is unusable, not a healthy
#     lane contributing nothing (jq exits 0 and prints nothing for it).
#   * A lane that exits 0 without a usable artifact is reported with a truthful
#     lane-failure code, never a bare "exit 0" — and that class must not flip
#     the all-lanes-failed aggregate from 5 (nobody answered) to 4 (somebody
#     answered unusably).
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

assert_file_absent() {
  local file="$1" name="$2"
  if [[ -e "$file" ]]; then
    fail "$name"
    printf '        expected file NOT to exist: %s\n' "$file" >&2
  else
    pass "$name"
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

# No lane review may be left behind in temp space: in stdout mode the parent
# creates the lane artifacts itself, so it owns their removal too.
assert_no_leftover_lane_artifact() {
  local name="$1" f leftover=""
  for f in $(find "$SCRATCH" -type f 2>/dev/null); do
    if jq -e '.agent // "" | startswith("external-")' "$f" >/dev/null 2>&1; then
      leftover="$f"
      break
    fi
  done
  if [[ -n "$leftover" ]]; then
    fail "$name"
    printf '        lane review left in temp space: %s\n' "$leftover" >&2
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
# clear the parent's scratch directory instead of touching the ambient /tmp.
SCRATCH="$TMP_ROOT/scratch"
mkdir -p "$SCRATCH"

mkdir -p "$TMP_ROOT/bin"

# Lane stub that answers with the response file named by $1.
cat > "$TMP_ROOT/bin/lane-answer" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
cat "$1"
SH

# Lane stub that answers with $1 and then removes every directory under the
# sandboxed TMPDIR — the reviewed repo's own agent CLI cleaning temp space
# under the parent, which is what the field report showed. The parent cannot
# reap this lane until the stub exits, so the removal always lands before the
# union step reads anything back.
#
# No -name filter: the parent's promise is that it creates exactly ONE
# directory here and that everything in it is disposable, so the stub tests
# that promise directly. It also must not assume GNU coreutils' `tmp.*`
# mktemp naming, which macOS does not guarantee (this repo supports Bash 3.2 /
# macOS system bash).
#
# $2, when given, is a lane agent name to wait for: the reaper holds until that
# lane's review has landed somewhere in temp space, making "cleared after the
# sibling lane wrote its review, before the parent reaped it" deterministic
# instead of a race. It finds that review wherever the parent chose to put it,
# so the handshake works against the old layout and the new one alike.
cat > "$TMP_ROOT/bin/lane-reap" <<SH
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
cat "\$1"
if [[ \$# -ge 2 ]]; then
  waited=0
  found=""
  while [[ -z "\$found" && \$waited -lt 300 ]]; do
    for f in \$(find "$SCRATCH" -type f 2>/dev/null); do
      if jq -e --arg a "\$2" '.agent == \$a' "\$f" >/dev/null 2>&1; then
        found=1
        break
      fi
    done
    [[ -n "\$found" ]] && break
    sleep 0.1
    waited=\$((waited + 1))
  done
fi
find "$SCRATCH" -mindepth 1 -maxdepth 1 -type d -exec rm -rf {} + 2>/dev/null || true
SH

# Lane stub that waits for the sibling lane's artifact ($2) to hold valid JSON,
# sabotages it ($3: steal removes it, blank leaves an artifact that passes a
# non-empty test but holds no JSON value), and only then answers with $1 — or
# exits $4 without answering, for the every-lane-failed cases. Waiting on the
# artifact's own content is a deterministic handshake, with no sleep-based
# timing assumption and no window where the sibling rewrites what was
# sabotaged.
cat > "$TMP_ROOT/bin/lane-sabotage" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
resp="$1"; target="$2"; action="$3"; rc="$4"
waited=0
while ! jq -e . "$target" >/dev/null 2>&1 && [[ $waited -lt 300 ]]; do
  sleep 0.1
  waited=$((waited + 1))
done
case "$action" in
  steal) rm -f "$target" ;;
  blank) printf '   \n' > "$target" ;;
esac
[[ "$rc" -eq 0 ]] || exit "$rc"
cat "$resp"
SH
chmod +x "$TMP_ROOT/bin/lane-answer" "$TMP_ROOT/bin/lane-reap" "$TMP_ROOT/bin/lane-sabotage"

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

cat > "$TMP_ROOT/resp-codex-blocker.json" <<'JSON'
{"agent":"external-codex","timestamp":"2026-01-01T00:00:00Z","verdict":"action_required",
 "summary":"one blocker",
 "blockers":[{"id":1,"title":"Unchecked index","location":"src/lib.rs (`get`)","description":"d","recommendation":"r","priority":2,"estimate":1}],
 "suggestions":[],"questions":[],"qa_metadata":{}}
JSON

ANSWER_CLAUDE="$TMP_ROOT/bin/lane-answer $TMP_ROOT/resp-claude.json"

# run_lanes <claude-cmd> <codex-cmd> [args...] — always under the sandboxed
# TMPDIR, with both streams captured so stdout-mode unions can be asserted.
run_lanes() {
  local claude_cmd="$1" codex_cmd="$2"
  shift 2
  local rc=0
  set +e
  env TMPDIR="$SCRATCH" \
    SECOND_OPINION_CLAUDE_CMD="$claude_cmd" \
    SECOND_OPINION_CODEX_CMD="$codex_cmd" \
    "$SECOND_OPINION" review --range HEAD --cwd "$WORK" "$@" \
    >"$TMP_ROOT/last.stdout" 2>"$TMP_ROOT/last.stderr"
  rc=$?
  set -e
  return "$rc"
}

# --- Scenario 1: scratch removed mid-run, --output mode -----------------------
echo "=== scenario 1: scratch dir removed mid-run (--output) -> union still written ==="
out1="$TMP_ROOT/out1.json"
rc1=0
run_lanes "$ANSWER_CLAUDE" "$TMP_ROOT/bin/lane-reap $TMP_ROOT/resp-codex.json" --output "$out1" || rc1=$?
assert_eq "$rc1" "0" "losing scratch does not fail the run"
assert_file_exists "$out1" "union artifact written despite lost scratch"
assert_jq "$out1" '.agent' "external-union(codex+claude)" "both lanes present in the union"
assert_jq "$out1" '.qa_metadata.coverage' "full" "coverage stays full — no lane actually failed"
assert_jq "$out1" '.qa_metadata.lanes | length' "2" "both lanes recorded in qa_metadata.lanes"
assert_jq "$out1" '.blockers | length' "1" "the answering lane's finding survives into the union"
assert_stderr_lacks "unparseable artifact" "a lost scratch file is not called an unparseable artifact"
assert_stderr_has "lane stderr replay unavailable" "the lost stderr replay is reported honestly"
assert_stderr_has "(union of 2 lanes)" "the reported lane count comes from the artifact's own ok lanes"
assert_file_exists "$out1.codex.json" "codex lane artifact kept beside the union"
assert_file_exists "$out1.claude.json" "claude lane artifact kept beside the union"

# --- Scenario 2: scratch removed mid-run, stdout mode -------------------------
# Same durability contract with no --output: the lane reviews must not live in
# the directory the parent advertises as disposable, or clearing it drops a
# model's real findings while the union still publishes a verdict.
echo "=== scenario 2: scratch dir removed mid-run (stdout) -> union still printed ==="
rc2=0
run_lanes "$ANSWER_CLAUDE" \
  "$TMP_ROOT/bin/lane-reap $TMP_ROOT/resp-codex.json external-claude" || rc2=$?
union2="$TMP_ROOT/last.stdout"
assert_eq "$rc2" "0" "stdout mode survives losing scratch"
assert_jq "$union2" '.agent' "external-union(codex+claude)" "stdout union carries both lanes"
assert_jq "$union2" '.qa_metadata.coverage' "full" "stdout union coverage stays full"
assert_jq "$union2" '.blockers | length' "1" "stdout union keeps the answering lane's blocker"
assert_jq "$union2" '.verdict' "action_required" "stdout union verdict follows the surviving blocker"
assert_stderr_lacks "unparseable artifact" "stdout mode does not call a lost scratch file unparseable"
assert_no_leftover_lane_artifact "stdout-mode lane artifacts are cleaned up, not leaked"

# --- Scenario 3: clean exit with no usable artifact is not "exit 0" -----------
# A lane whose artifact is gone by the time it is reaped never delivered an
# answer — a lane-level failure. It must be recorded with a truthful code, not
# the bare "exit 0" the reaped child happened to return.
echo "=== scenario 3: lane exits 0 with no artifact -> truthful failure code ==="
out3="$TMP_ROOT/out3.json"
rc3=0
run_lanes "$ANSWER_CLAUDE" \
  "$TMP_ROOT/bin/lane-sabotage $TMP_ROOT/resp-codex.json $out3.claude.json steal 0" \
  --output "$out3" || rc3=$?
assert_eq "$rc3" "0" "the surviving lane keeps the run at exit 0"
assert_jq "$out3" '.qa_metadata.coverage' "degraded" "the lost lane degrades coverage"
assert_jq "$out3" '[.qa_metadata.lanes[] | select(.target == "claude")][0].exit_code' "5" \
  "the lost lane records the never-answered code, not 0"
assert_stderr_has "without a usable artifact" "the missing artifact is named as the cause"
assert_stderr_lacks "(exit 0)" "a failed lane is never reported as exit 0"
assert_stderr_has "(union of 1 lanes)" "the reported count drops the failed lane"

# --- Scenario 4: an artifact holding no JSON value is unusable ----------------
# jq exits 0 and prints NOTHING for a whitespace-only artifact, which passes a
# non-empty file test. Accepting that as a lane would count it healthy while it
# contributes no findings — the union would publish a pass over a real blocker.
echo "=== scenario 4: blanked artifact -> unusable lane, surviving findings kept ==="
out4="$TMP_ROOT/out4.json"
rc4=0
run_lanes "$ANSWER_CLAUDE" \
  "$TMP_ROOT/bin/lane-sabotage $TMP_ROOT/resp-codex-blocker.json $out4.claude.json blank 0" \
  --output "$out4" || rc4=$?
assert_eq "$rc4" "0" "one unusable lane does not fail the run"
assert_file_exists "$out4" "union artifact still written"
assert_jq "$out4" '.qa_metadata.coverage' "degraded" "the valueless artifact degrades coverage"
assert_jq "$out4" '[.qa_metadata.lanes[] | select(.target == "claude")][0].exit_code' "4" \
  "a lane that answered unusably records 4"
assert_jq "$out4" '.qa_metadata.lanes | length' "2" "the unusable lane is still accounted for"
assert_jq "$out4" '.blockers | length' "1" "the surviving lane's blocker reaches the union"
assert_jq "$out4" '.verdict' "action_required" "the union verdict follows the surviving blocker"
assert_stderr_has "unparseable artifact: claude" "the valueless artifact is named unusable"
assert_stderr_has "no JSON value in artifact" "the unusable artifact's cause is reported"
assert_stderr_has "(union of 1 lanes)" "the count matches the one lane the artifact carries"

# --- Scenario 5: every lane fails, none ever answered -> exit 5 ---------------
# The aggregate exit code is decided by whether any lane ANSWERED unusably. A
# lane that exited 0 with no artifact never answered, so it must leave the
# aggregate at 5 — repointing that branch to 4 would silently change this
# contract with every other test still green.
echo "=== scenario 5: no lane ever answered -> exit 5, no artifact ==="
out5="$TMP_ROOT/out5.json"
rc5=0
run_lanes "$ANSWER_CLAUDE" \
  "$TMP_ROOT/bin/lane-sabotage $TMP_ROOT/resp-codex.json $out5.claude.json steal 1" \
  --output "$out5" || rc5=$?
assert_eq "$rc5" "5" "all lanes lost with none answering exits 5"
assert_file_absent "$out5" "no union artifact when every lane failed"
assert_stderr_has "every review lane failed" "the no-verdict condition is reported"
assert_stderr_has "lane failed: codex (exit 5)" "the failed CLI lane records 5"
assert_stderr_has "lane failed: claude (exit 5)" "the artifact-less lane records 5"

# --- Scenario 6: every lane fails, one answered unusably -> exit 4 ------------
echo "=== scenario 6: some lane answered unusably -> exit 4, no artifact ==="
out6="$TMP_ROOT/out6.json"
rc6=0
run_lanes "$ANSWER_CLAUDE" \
  "$TMP_ROOT/bin/lane-sabotage $TMP_ROOT/resp-codex.json $out6.claude.json blank 1" \
  --output "$out6" || rc6=$?
assert_eq "$rc6" "4" "an unusable answer moves the aggregate to 4"
assert_file_absent "$out6" "no union artifact when every lane failed"
assert_stderr_has "lane failed: claude (exit 4)" "the unusable lane records 4"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
