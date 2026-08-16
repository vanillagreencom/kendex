#!/usr/bin/env bash
# Regression test for second-opinion target selection and multi-lane review.
#
# Cross-model is the guarantee: every mode walks the SECOND_OPINION_MODELS
# roster in priority order, never dispatches to the model this session runs
# (declared identity — SECOND_OPINION_CURRENT_MODEL / SECOND_OPINION_<NAME>_MODEL),
# and refuses when nothing eligible remains. Breadth is opt-in: with
# SECOND_OPINION_COUNT >= 2 the selected lanes run on the same derived scope
# and write one union artifact:
#   - findings deduplicated by normalized location (file + symbol), duplicate
#     findings carry every contributing lane in `sources`;
#   - a suggestion whose location a blocker already covers is dropped;
#   - lane artifacts kept beside the union as <output>.<target>.json;
#   - one failed lane degrades coverage LOUDLY (qa_metadata.coverage,
#     qa_metadata.lanes) instead of failing the run or narrowing silently;
#   - all lanes failed -> no artifact, exit 4/5 (no-verdict class);
#   - SECOND_OPINION_TARGET / --target still force the single-lane path, but
#     never past the self-exclusion guard;
#   - another target is a settings entry (SECOND_OPINION_<NAME>_CMD), not code.
#
# Drives a hermetic copy of the skill (vstack#580) with fake lane CLIs.

set -euo pipefail

# Declare this session as having no model (none), so the cross-model
# guard neither depends on nor is defeated by the harness running the tests.
export SECOND_OPINION_CURRENT_MODEL=none

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
  if [[ ! -e "$file" ]]; then
    pass "$name"
  else
    fail "$name"
    printf '        expected file to NOT exist: %s\n' "$file" >&2
  fi
}

# jq over an artifact, with a readable failure
assert_jq() {
  local file="$1" expr="$2" want="$3" name="$4" got
  got="$(jq -r "$expr" "$file" 2>/dev/null || echo "JQ_ERROR")"
  assert_eq "$got" "$want" "$name"
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
HEAD_SHA="$(git -C "$WORK" rev-parse HEAD)"

# --- Lane stubs ---------------------------------------------------------------
# Each stub swallows its prompt, counts invocations in its own counter file,
# and emits its canned response (or fails when the response file is absent).
mkdir -p "$TMP_ROOT/bin"
make_stub() {
  local name="$1"
  cat > "$TMP_ROOT/bin/$name" <<SH
#!/usr/bin/env bash
set -euo pipefail
cat >/dev/null
n=\$(cat "$TMP_ROOT/count-$name" 2>/dev/null || echo 0)
printf '%s' \$((n + 1)) > "$TMP_ROOT/count-$name"
[[ -f "$TMP_ROOT/resp-$name.json" ]] || exit 1
cat "$TMP_ROOT/resp-$name.json"
SH
  chmod +x "$TMP_ROOT/bin/$name"
}
make_stub lane-claude
make_stub lane-codex
make_stub lane-extra

count() { cat "$TMP_ROOT/count-$1" 2>/dev/null || echo 0; }
reset_counts() { rm -f "$TMP_ROOT"/count-*; }

# claude lane: 1 blocker (parse), 1 suggestion (README)
cat > "$TMP_ROOT/resp-lane-claude.json" <<'JSON'
{"agent":"external-claude","timestamp":"2026-01-01T00:00:00Z","verdict":"action_required",
 "summary":"one blocker",
 "blockers":[{"id":1,"title":"Off-by-one in parse","location":"src/app.rs (`parse`)","description":"claude desc","recommendation":"fix","priority":2,"estimate":1}],
 "suggestions":[{"id":1,"title":"Clarify README","location":"README.md","description":"d","recommendation":"r","priority":3,"estimate":1,"category":"fix"}],
 "questions":[],"qa_metadata":{}}
JSON

# codex lane: 2 blockers (parse duplicate + db), 2 suggestions (parse — covered
# by a blocker, must be dropped — and docs/guide.md)
cat > "$TMP_ROOT/resp-lane-codex.json" <<'JSON'
{"agent":"external-codex","timestamp":"2026-01-01T00:00:00Z","verdict":"action_required",
 "summary":"two blockers",
 "blockers":[{"id":1,"title":"Boundary error in parse","location":"src/app.rs (`parse`)","description":"codex desc","recommendation":"fix","priority":1,"estimate":1},
             {"id":2,"title":"Unchecked query result","location":"src/db.rs (`query`)","description":"d","recommendation":"r","priority":2,"estimate":2}],
 "suggestions":[{"id":1,"title":"Simplify parse","location":"src/app.rs (`parse`)","description":"d","recommendation":"r","priority":3,"estimate":1,"category":"fix"},
                {"id":2,"title":"Document guide","location":"docs/guide.md","description":"d","recommendation":"r","priority":3,"estimate":1,"category":"issue"}],
 "questions":[],"qa_metadata":{}}
JSON

cat > "$TMP_ROOT/resp-lane-extra.json" <<'JSON'
{"agent":"external-my-model","timestamp":"2026-01-01T00:00:00Z","verdict":"pass","summary":"clean",
 "blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}
JSON

# run_multi <output> [extra env...] — no SECOND_OPINION_TARGET
run_multi() {
  local out="$1"
  shift
  local rc=0
  set +e
  env SECOND_OPINION_MODELS="codex claude" SECOND_OPINION_COUNT=2 "$@" \
    SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/lane-claude" \
    SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/lane-codex" \
    "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$out" \
    >/dev/null 2>"$TMP_ROOT/last.stderr"
  rc=$?
  set -e
  return "$rc"
}

# --- Scenario 1: dual-lane union with dedupe and provenance -------------------
echo "=== scenario 1: both lanes run; findings unioned, deduped by location ==="
reset_counts
out1="$TMP_ROOT/out1.json"
rc1=0
run_multi "$out1" || rc1=$?
assert_eq "$rc1" "0" "dual-lane review exits 0"
assert_file_exists "$out1" "union artifact written"
assert_eq "$(count lane-claude)" "1" "claude lane invoked exactly once"
assert_eq "$(count lane-codex)" "1" "codex lane invoked exactly once"
assert_jq "$out1" '.agent' "external-union(codex+claude)" "union agent names both lanes"
assert_jq "$out1" '.verdict' "action_required" "union verdict is action_required"
assert_jq "$out1" '.blockers | length' "2" "duplicate parse blocker deduped: 2 unique blockers"
assert_jq "$out1" '[.blockers[] | select(.location == "src/app.rs (`parse`)")][0].sources | sort | join(",")' \
  "claude,codex" "deduped blocker carries both lanes in sources"
assert_jq "$out1" '.suggestions | length' "2" "blocker-covered suggestion dropped: 2 remain"
assert_jq "$out1" '[.suggestions[].location] | sort | join(",")' "README.md,docs/guide.md" \
  "surviving suggestions are the non-blocker locations"
assert_jq "$out1" '.qa_metadata.union' "true" "artifact is marked as a union"
assert_jq "$out1" '.qa_metadata.coverage' "full" "coverage is full when every lane answered"
assert_jq "$out1" '.qa_metadata.lanes | length' "2" "both lanes recorded in qa_metadata.lanes"
assert_jq "$out1" '.qa_metadata.dedupe.blockers_in' "3" "dedupe records 3 blockers in"
assert_jq "$out1" '.qa_metadata.dedupe.suggestions_in' "3" "dedupe records 3 suggestions in"
assert_jq "$out1" '.qa_metadata.reviewed_head' "$HEAD_SHA" "union records the reviewed head"
assert_file_exists "$out1.codex.json" "codex lane artifact kept beside the union"
assert_file_exists "$out1.claude.json" "claude lane artifact kept beside the union"

# --- Scenario 2: one failed lane degrades coverage loudly ---------------------
echo "=== scenario 2: one lane down -> exit 0, coverage degraded, lane recorded ==="
reset_counts
rm -f "$TMP_ROOT/resp-lane-codex.json"   # codex stub now exits 1 -> lane exit 5
out2="$TMP_ROOT/out2.json"
rc2=0
run_multi "$out2" || rc2=$?
assert_eq "$rc2" "0" "surviving lane keeps the run at exit 0"
assert_jq "$out2" '.agent' "external-union(claude)" "union agent lists only surviving lanes"
assert_jq "$out2" '.qa_metadata.coverage' "degraded" "coverage marked degraded"
assert_jq "$out2" '[.qa_metadata.lanes[] | select(.target == "codex")][0].status' "failed" \
  "failed lane recorded in qa_metadata.lanes"
assert_jq "$out2" '[.qa_metadata.lanes[] | select(.target == "codex")][0].exit_code' "5" \
  "failed lane records its exit code"
assert_jq "$out2" '.blockers | length' "1" "union carries the surviving lane findings"

# --- Scenario 3: every lane failed -> no artifact, no-verdict exit ------------
echo "=== scenario 3: all lanes down -> exit 5, no artifact ==="
reset_counts
rm -f "$TMP_ROOT/resp-lane-claude.json"
out3="$TMP_ROOT/out3.json"
rc3=0
run_multi "$out3" || rc3=$?
assert_eq "$rc3" "5" "all lanes failed exits 5"
assert_file_absent "$out3" "no union artifact when every lane failed"

# restore lane responses for the remaining scenarios
cat > "$TMP_ROOT/resp-lane-claude.json" <<'JSON'
{"agent":"external-claude","timestamp":"2026-01-01T00:00:00Z","verdict":"pass","summary":"clean",
 "blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}
JSON

# --- Scenario 4: forced target keeps the single-lane path ---------------------
echo "=== scenario 4: SECOND_OPINION_TARGET forces a single lane ==="
reset_counts
out4="$TMP_ROOT/out4.json"
rc4=0
run_multi "$out4" SECOND_OPINION_TARGET=claude || rc4=$?
assert_eq "$rc4" "0" "forced single-lane review exits 0"
assert_eq "$(count lane-codex)" "0" "forced target never invokes the other lane"
assert_jq "$out4" '.agent' "external-claude" "single-lane artifact keeps the lane agent"
assert_jq "$out4" '.qa_metadata.reviewed_head' "$HEAD_SHA" "single lane also records reviewed head"
assert_file_absent "$out4.codex.json" "no lane sidecars in single-lane mode"

# --- Scenario 5: a third target is a settings entry, not new code -------------
echo "=== scenario 5: custom lane via SECOND_OPINION_MODELS + <NAME>_CMD ==="
reset_counts
out5="$TMP_ROOT/out5.json"
rc5=0
run_multi "$out5" \
  SECOND_OPINION_MODELS="claude my-model" \
  SECOND_OPINION_MY_MODEL_CMD="$TMP_ROOT/bin/lane-extra" || rc5=$?
assert_eq "$rc5" "0" "custom lane review exits 0"
assert_eq "$(count lane-extra)" "1" "custom lane CLI invoked exactly once"
assert_eq "$(count lane-codex)" "0" "lanes outside SECOND_OPINION_MODELS do not run"
assert_jq "$out5" '.agent' "external-union(claude+my-model)" "union agent includes the custom lane"
assert_file_exists "$out5.my-model.json" "custom lane artifact kept beside the union"

echo "=== scenario 6: distinct same-location findings from one lane both survive ==="
# Location alone is not finding identity: one lane reporting two independent
# bugs in the same function must keep both (occurrence-indexed keys), while
# the other lane's single finding there still merges with the first.
reset_counts
cat > "$TMP_ROOT/resp-lane-claude.json" <<'JSON'
{"agent":"external-claude","timestamp":"2026-01-01T00:00:00Z","verdict":"action_required",
 "summary":"one bug in parse",
 "blockers":[{"id":1,"title":"Off-by-one in parse","location":"src/app.rs (`parse`)","description":"claude desc","recommendation":"fix","priority":2,"estimate":1}],
 "suggestions":[],"questions":[],"qa_metadata":{}}
JSON
cat > "$TMP_ROOT/resp-lane-codex.json" <<'JSON'
{"agent":"external-codex","timestamp":"2026-01-01T00:00:00Z","verdict":"action_required",
 "summary":"two distinct bugs in parse",
 "blockers":[{"id":1,"title":"Boundary error in parse","location":"src/app.rs (`parse`)","description":"first distinct bug","recommendation":"fix","priority":1,"estimate":1},
             {"id":2,"title":"Integer overflow in parse","location":"src/app.rs (`parse`)","description":"second distinct bug","recommendation":"fix","priority":2,"estimate":1}],
 "suggestions":[],"questions":[],"qa_metadata":{}}
JSON
out6="$TMP_ROOT/out6.json"
rc6=0
run_multi "$out6" || rc6=$?
assert_eq "$rc6" "0" "distinct-findings review exits 0"
assert_jq "$out6" '[.blockers[] | select(.location == "src/app.rs (`parse`)")] | length' "2" "both same-location blockers survive the union"
assert_jq "$out6" '[.blockers[] | select(.location == "src/app.rs (`parse`)") | .sources] | map(length) | sort | join(",")' "1,2" "first slot merges across lanes; second stays single-lane"

echo "=== scenario 7: duplicate lane names run once ==="
reset_counts
out7="$TMP_ROOT/out7.json"
rc7=0
run_multi "$out7" SECOND_OPINION_MODELS="codex, codex claude" || rc7=$?
assert_eq "$rc7" "0" "duplicate-lane review exits 0"
assert_eq "$(count lane-codex)" "1" "duplicated lane invoked exactly once"
assert_jq "$out7" '.qa_metadata.lanes | length' "2" "lane provenance lists each lane once"
grep -q "skipping codex: same configuration namespace" "$TMP_ROOT/last.stderr" || fail "duplicate skip is not loud"

echo "=== scenario 8: all-lanes failure removes a stale union artifact ==="
reset_counts
out8="$TMP_ROOT/out8.json"
printf '{"verdict":"pass","summary":"STALE ARTIFACT FROM A PREVIOUS RUN"}\n' > "$out8"
rm -f "$TMP_ROOT/resp-lane-claude.json" "$TMP_ROOT/resp-lane-codex.json"
rc8=0
run_multi "$out8" || rc8=$?
[[ "$rc8" -ne 0 ]] && pass "all-lanes failure exits non-zero" || fail "all-lanes failure exited 0"
assert_file_absent "$out8" "stale union artifact is cleared, not left as a fake pass"

echo "=== scenario 9: lanes that ANSWER unusably classify as exit 4, not 5 ==="
# A lane whose model returns non-JSON even after the retry exits 1 — a
# response-level defect, not a provider outage. All lanes failing that way
# must exit 4 per the documented contract.
reset_counts
printf 'this is not json at all\n' > "$TMP_ROOT/resp-lane-claude.json"
printf 'still not json\n' > "$TMP_ROOT/resp-lane-codex.json"
out9="$TMP_ROOT/out9.json"
rc9=0
run_multi "$out9" || rc9=$?
assert_eq "$rc9" "4" "all lanes answering unusably exits 4"
assert_file_absent "$out9" "no artifact when every lane answered unusably"

# --- Cross-model guard --------------------------------------------------------
# run_multi pins SECOND_OPINION_CURRENT_MODEL=none via the export at
# the top; these scenarios override it per call to stand in a real session.
cat > "$TMP_ROOT/resp-lane-claude.json" <<'JSON'
{"agent":"external-claude","timestamp":"2026-01-01T00:00:00Z","verdict":"pass","summary":"clean",
 "blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}
JSON
cat > "$TMP_ROOT/resp-lane-codex.json" <<'JSON'
{"agent":"external-codex","timestamp":"2026-01-01T00:00:00Z","verdict":"pass","summary":"clean",
 "blockers":[],"suggestions":[],"questions":[],"qa_metadata":{}}
JSON

echo "=== scenario 10: default count is ONE opinion, first eligible in priority order ==="
reset_counts
out10="$TMP_ROOT/out10.json"
rc10=0
run_multi "$out10" SECOND_OPINION_COUNT=1 || rc10=$?
assert_eq "$rc10" "0" "single-opinion review exits 0"
assert_eq "$(count lane-codex)" "1" "first roster entry runs"
assert_eq "$(count lane-claude)" "0" "second roster entry does not run at count 1"
assert_jq "$out10" '.agent' "external-codex" "single-opinion artifact is the lane's own, not a union"

echo "=== scenario 11: the session's own model is excluded even at count 2 ==="
reset_counts
out11="$TMP_ROOT/out11.json"
rc11=0
run_multi "$out11" SECOND_OPINION_CURRENT_MODEL=codex || rc11=$?
assert_eq "$rc11" "0" "self-excluded review still exits 0 on the remaining lane"
assert_eq "$(count lane-codex)" "0" "the session's own model is never invoked"
assert_eq "$(count lane-claude)" "1" "the other model runs"
assert_jq "$out11" '.agent' "external-claude" "artifact comes from the cross-model lane only"
grep -q "skipping codex: runs the same model as this session" "$TMP_ROOT/last.stderr" || fail "self-exclusion is not loud"

# A wrapper script named after a harness stands in as the innermost ancestor
# for the detection scenarios (12, 19, 20). Probe first: on platforms where
# `ps -o comm=` reports the interpreter rather than the script, the wrapper is
# invisible and those scenarios cannot run.
mkdir -p "$TMP_ROOT/fake"
for h in claude pi codex cursor-agent cursor codex-wrapper; do
  printf '#!/bin/bash\n"$@"\n' > "$TMP_ROOT/fake/$h"
  chmod +x "$TMP_ROOT/fake/$h"
done
probe=$("$TMP_ROOT/fake/pi" bash -c 'ps -o comm= -p $PPID' 2>/dev/null | tr -d ' ')
probe="${probe##*/}"
ANCESTOR_VISIBLE=false
[[ "$probe" == "pi" ]] && ANCESTOR_VISIBLE=true

# run_under <harness> <args...>: run the script with <harness> as the nearest
# ancestor and NO declared identity, lanes stubbed, both streams captured.
run_under() {
  local h="$1"; shift
  local rc=0
  set +e
  env -u SECOND_OPINION_CURRENT_MODEL \
    SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/lane-claude" \
    SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/lane-codex" \
    "$@" "$TMP_ROOT/fake/$h" "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$TMP_ROOT/out-under.json" \
    >/dev/null 2>"$TMP_ROOT/last.stderr"
  rc=$?
  set -e
  return "$rc"
}

# --- Detached runs (no harness ancestor) --------------------------------------
# Some scenarios need the ancestor walk to see NOTHING — the `unknown` harness
# branch, and the bystander-name checks. Detaching with `setsid --fork` is not
# enough on its own: the fork's parent exit and the child's start are not
# ordered, so the walk can climb through a not-yet-reaped intermediate into the
# test harness and the scenario fails at random under load. The child therefore
# ESTABLISHES the precondition rather than assuming it — it re-walks its own
# ancestors and waits until no harness is visible, and reports DETACH_FAILED if
# that never happens, so an unmet precondition is a printed skip and never a
# red assertion.
DETACH_PRECONDITION='
_so_harness_ancestor() {
  local pid=$$ c
  while pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d " ") \
        && [[ -n "$pid" && "$pid" != "0" && "$pid" != "1" ]]; do
    c=$(ps -o comm= -p "$pid" 2>/dev/null || echo "")
    c="${c##*/}"
    case "$c" in claude|codex|pi|opencode|cursor-agent) printf "%s" "$c"; return 0 ;; esac
  done
  return 1
}
_so_waited=0
while _so_seen=$(_so_harness_ancestor); do
  [[ $_so_waited -lt 200 ]] || break
  sleep 0.05
  _so_waited=$((_so_waited + 1))
done
'

DETACHED_HIDES_ANCESTOR=false
if [[ "$(uname -s)" == "Linux" ]] && command -v setsid >/dev/null 2>&1; then
  {
    printf '#!/usr/bin/env bash\n%s\n' "$DETACH_PRECONDITION"
    printf 'if _so_harness_ancestor > "$1"; then :; else printf none > "$1"; fi\n'
  } > "$TMP_ROOT/ancestor-probe"
  chmod +x "$TMP_ROOT/ancestor-probe"
  rm -f "$TMP_ROOT/ancestor-probe.out"
  setsid --fork "$TMP_ROOT/ancestor-probe" "$TMP_ROOT/ancestor-probe.out" </dev/null >/dev/null 2>&1 || true
  probe_waited=0
  while [[ ! -s "$TMP_ROOT/ancestor-probe.out" && $probe_waited -lt 200 ]]; do
    sleep 0.1; probe_waited=$((probe_waited + 1))
  done
  [[ "$(cat "$TMP_ROOT/ancestor-probe.out" 2>/dev/null || echo miss)" == "none" ]] && DETACHED_HIDES_ANCESTOR=true
fi

# run_detached <wrapper|-> <rc-file> <stderr-file> <env assignments...>: the run
# is reparented away from this process tree, so its exit code comes back through
# a file rather than $?. <wrapper> is an ancestor to interpose (a harness-shaped
# name), or `-` for none — interposed AFTER the precondition is established, so
# the wrapper is the only ancestor the walk can find. Every harness marker is
# unset; a caller assignment can put one back, since env applies assignments
# after its own -u options.
run_detached() {
  local wrapper="$1" rcfile="$2" errfile="$3"; shift 3
  rm -f "$rcfile" "$errfile"
  {
    printf '#!/usr/bin/env bash\n%s\n' "$DETACH_PRECONDITION"
    printf 'if _so_harness_ancestor >/dev/null; then printf DETACH_FAILED > %q; exit 0; fi\n' "$rcfile"
    printf 'env -u CLAUDECODE -u CLAUDE_CODE -u CLAUDE_PROJECT_DIR -u CODEX_SANDBOX \\\n'
    printf '    -u CODEX_SANDBOX_NETWORK_DISABLED \\\n'
    printf '    -u PI_CODING_AGENT_DIR -u OPENCODE -u CURSOR_AGENT -u CURSOR_TRACE_ID \\\n'
    printf '    -u SECOND_OPINION_CURRENT_MODEL \\\n'
    printf '    SECOND_OPINION_CLAUDE_CMD=%q SECOND_OPINION_CODEX_CMD=%q \\\n' \
      "$TMP_ROOT/bin/lane-claude" "$TMP_ROOT/bin/lane-codex"
    local assign
    for assign in "$@"; do printf '    %q \\\n' "$assign"; done
    [[ "$wrapper" == "-" ]] || printf '    %q \\\n' "$TMP_ROOT/fake/$wrapper"
    printf '    %q review --range HEAD --cwd %q --output %q >/dev/null 2>%q\n' \
      "$SECOND_OPINION" "$WORK" "$TMP_ROOT/out30.json" "$errfile"
    printf 'printf %%s $? > %q\n' "$rcfile"
  } > "$TMP_ROOT/detached-run"
  chmod +x "$TMP_ROOT/detached-run"
  setsid --fork "$TMP_ROOT/detached-run" </dev/null >/dev/null 2>&1 || true
  local waited=0
  while [[ ! -s "$rcfile" && $waited -lt 600 ]]; do sleep 0.1; waited=$((waited + 1)); done
}

# True when the last run_detached could not shed its harness ancestors. Callers
# print a skip instead of asserting.
detach_failed() {
  [[ "$(cat "$1" 2>/dev/null || echo)" == "DETACH_FAILED" ]]
}

echo "=== scenario 12: a detected Claude session excludes claude without a declaration ==="
if $ANCESTOR_VISIBLE; then
  reset_counts
  rm -f "$TMP_ROOT/out-under.json"
  rc12=0
  run_under claude SECOND_OPINION_COUNT=1 SECOND_OPINION_MODELS="claude codex" || rc12=$?
  assert_eq "$rc12" "0" "detected-harness review exits 0"
  assert_eq "$(count lane-claude)" "0" "detected claude session never invokes claude"
  assert_eq "$(count lane-codex)" "1" "detected claude session gets codex"
  # control: a declared foreign identity under the same ancestor dispatches to claude
  reset_counts
  run_under claude SECOND_OPINION_CURRENT_MODEL=codex SECOND_OPINION_COUNT=1 SECOND_OPINION_MODELS="claude codex" || true
  assert_eq "$(count lane-claude)" "1" "control: declared identity outranks harness detection"
elif $DETACHED_HIDES_ANCESTOR; then
  # Env-marker route: CLAUDECODE=1 is what Claude Code sets. It only decides
  # anything when the process tree says nothing, so the run has to be detached —
  # under a real harness runner the tree wins, correctly.
  reset_counts
  rm -f "$TMP_ROOT/out30.json"
  run_detached - "$TMP_ROOT/rc12" "$TMP_ROOT/last.stderr" \
    CLAUDECODE=1 SECOND_OPINION_COUNT=1 SECOND_OPINION_MODELS="claude codex"
  if detach_failed "$TMP_ROOT/rc12"; then
    echo "  skip  scenario 12: the run could not shed its harness ancestors"
  else
    assert_eq "$(cat "$TMP_ROOT/rc12" 2>/dev/null || echo TIMEOUT)" "0" "detected-harness review exits 0"
    assert_eq "$(count lane-claude)" "0" "detected claude session never invokes claude"
    assert_eq "$(count lane-codex)" "1" "detected claude session gets codex"
  fi
else
  echo "  skip  scenario 12: no ancestor visibility and no detachment on this platform"
fi

echo "=== scenario 13: forced target equal to the session model is refused ==="
reset_counts
out13="$TMP_ROOT/out13.json"
rc13=0
run_multi "$out13" SECOND_OPINION_CURRENT_MODEL=claude SECOND_OPINION_TARGET=claude || rc13=$?
assert_eq "$rc13" "1" "forced same-model target exits 1"
assert_file_absent "$out13" "refusal writes no artifact"
assert_eq "$(count lane-claude)" "0" "refusal invokes no CLI"
grep -q "refusing to run a second opinion" "$TMP_ROOT/last.stderr" || fail "refusal is not stated"

echo "=== scenario 14: declared <NAME>_MODEL identity is what the guard compares ==="
# my-model is a Pi-style front end declared to run claude: from a claude
# session it is excluded and codex is taken instead; from a codex session
# it is eligible.
reset_counts
out14="$TMP_ROOT/out14.json"
rc14=0
run_multi "$out14" SECOND_OPINION_CURRENT_MODEL=claude SECOND_OPINION_COUNT=1 \
  SECOND_OPINION_MODELS="my-model codex" \
  SECOND_OPINION_MY_MODEL_CMD="$TMP_ROOT/bin/lane-extra" SECOND_OPINION_MY_MODEL_MODEL=claude || rc14=$?
assert_eq "$rc14" "0" "declared-identity review exits 0"
assert_eq "$(count lane-extra)" "0" "target declared as the session's model is excluded"
assert_eq "$(count lane-codex)" "1" "next distinct model in priority order is taken"
reset_counts
run_multi "$out14" SECOND_OPINION_CURRENT_MODEL=codex SECOND_OPINION_COUNT=1 \
  SECOND_OPINION_MODELS="my-model codex" \
  SECOND_OPINION_MY_MODEL_CMD="$TMP_ROOT/bin/lane-extra" SECOND_OPINION_MY_MODEL_MODEL=claude || true
assert_eq "$(count lane-extra)" "1" "control: same target is eligible from a different-model session"

echo "=== scenario 15: two roster entries with one declared model count as one opinion ==="
reset_counts
out15="$TMP_ROOT/out15.json"
rc15=0
run_multi "$out15" SECOND_OPINION_MODELS="claude my-model codex" \
  SECOND_OPINION_MY_MODEL_CMD="$TMP_ROOT/bin/lane-extra" SECOND_OPINION_MY_MODEL_MODEL=claude || rc15=$?
assert_eq "$rc15" "0" "distinct-model review exits 0"
assert_eq "$(count lane-extra)" "0" "a second entry for an already-selected model is skipped"
assert_eq "$(count lane-codex)" "1" "the second opinion is the next DISTINCT model"

echo "=== scenario 16: nothing eligible -> refuse, no artifact, no CLI spend ==="
reset_counts
out16="$TMP_ROOT/out16.json"
rc16=0
run_multi "$out16" SECOND_OPINION_CURRENT_MODEL=claude \
  SECOND_OPINION_MODELS="claude my-model" \
  SECOND_OPINION_MY_MODEL_CMD="$TMP_ROOT/bin/lane-extra" SECOND_OPINION_MY_MODEL_MODEL=claude || rc16=$?
assert_eq "$rc16" "1" "all-same-model roster exits 1"
assert_file_absent "$out16" "refusal writes no artifact"
assert_eq "$(( $(count lane-claude) + $(count lane-extra) ))" "0" "refusal invokes no CLI"
grep -q '"current_model": "claude"' "$TMP_ROOT/last.stderr" || fail "refusal does not name the session model"
grep -q "my-model: runs the same model" "$TMP_ROOT/last.stderr" || fail "refusal does not list every candidate with its reason"

echo "=== scenario 17: quick mode is guarded too ==="
reset_counts
rc17=0
set +e
env SECOND_OPINION_CURRENT_MODEL=codex SECOND_OPINION_MODELS="codex" \
  SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/lane-codex" \
  "$SECOND_OPINION" quick "is this safe?" --cwd "$WORK" >/dev/null 2>"$TMP_ROOT/last.stderr"
rc17=$?
set -e
assert_eq "$rc17" "1" "quick mode refuses a same-model roster"
assert_eq "$(count lane-codex)" "0" "quick mode refusal invokes no CLI"
reset_counts
set +e
env SECOND_OPINION_CURRENT_MODEL=codex SECOND_OPINION_MODELS="codex claude" \
  SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/lane-codex" SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/lane-claude" \
  "$SECOND_OPINION" quick "is this safe?" --cwd "$WORK" >/dev/null 2>"$TMP_ROOT/last.stderr"
rc17b=$?
set -e
assert_eq "$rc17b" "0" "control: quick mode takes the next eligible model"
assert_eq "$(count lane-claude)" "1" "control: quick mode dispatched to the cross-model lane"

echo "=== scenario 18: detect reports the selection and refuses the same way ==="
got18=$(env SECOND_OPINION_CURRENT_MODEL=claude SECOND_OPINION_MODELS="claude codex" \
  SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/lane-codex" SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/lane-claude" \
  "$SECOND_OPINION" detect 2>/dev/null) || true
assert_eq "$got18" "codex" "detect prints the cross-model target"
rc18=0
got18b=$(env SECOND_OPINION_CURRENT_MODEL=claude SECOND_OPINION_MODELS="claude" \
  SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/lane-claude" \
  "$SECOND_OPINION" detect 2>/dev/null) || rc18=$?
assert_eq "$got18b:$rc18" "none:1" "detect prints none and exits 1 when refusing"

echo "=== scenario 19-20: nearest harness ancestor is the identity (skipped where ps hides script names) ==="
if $ANCESTOR_VISIBLE; then
  echo "=== scenario 19: undeclared Pi session refuses — no CLI run, reason names the setting ==="
  reset_counts
  rm -f "$TMP_ROOT/out-under.json"
  rc19=0
  run_under pi SECOND_OPINION_MODELS="codex claude" || rc19=$?
  assert_eq "$rc19" "1" "undeclared Pi session exits 1"
  assert_file_absent "$TMP_ROOT/out-under.json" "undeclared Pi session writes no artifact"
  assert_eq "$(( $(count lane-claude) + $(count lane-codex) ))" "0" "undeclared Pi session invokes no CLI"
  grep -q "model undeclared" "$TMP_ROOT/last.stderr" || fail "refusal does not say the model is undeclared"
  grep -q "SECOND_OPINION_CURRENT_MODEL" "$TMP_ROOT/last.stderr" || fail "refusal does not name the setting"
  grep -q "SECOND_OPINION_TARGET=" "$TMP_ROOT/last.stderr" && fail "undeclared refusal wrongly advises about SECOND_OPINION_TARGET"
  # control: the same Pi session, declared, dispatches cross-model
  reset_counts
  run_under pi SECOND_OPINION_CURRENT_MODEL=claude SECOND_OPINION_MODELS="claude codex" || true
  assert_eq "$(count lane-codex)" "1" "control: declared Pi-on-claude session gets codex"
  assert_eq "$(count lane-claude)" "0" "control: declared Pi-on-claude session never gets claude"
  # undeclared Cursor session: same fail-closed path. `cursor-agent` is the
  # agent's own binary — the bare `cursor` name belongs to the editor and must
  # NOT establish a harness identity (scenario 31).
  reset_counts
  rc19c=0
  run_under cursor-agent SECOND_OPINION_MODELS="codex claude" || rc19c=$?
  assert_eq "$rc19c" "1" "undeclared Cursor session exits 1"
  assert_eq "$(( $(count lane-claude) + $(count lane-codex) ))" "0" "undeclared Cursor session invokes no CLI"
  grep -q "cursor fronts a selectable model" "$TMP_ROOT/last.stderr" || fail "Cursor refusal does not name the harness"
  # undeclared settings-forced target under Pi: refusal is about the identity, not the force
  reset_counts
  run_under pi SECOND_OPINION_TARGET=codex || true
  grep -q "model undeclared" "$TMP_ROOT/last.stderr" || fail "forced+undeclared refusal does not name the identity gap"
  grep -q "without it the roster would select" "$TMP_ROOT/last.stderr" && fail "forced+undeclared refusal gives the SECOND_OPINION_TARGET hint"

  echo "=== scenario 20: conflicting markers — innermost harness wins over an inherited CLAUDECODE ==="
  reset_counts
  run_under codex CLAUDECODE=1 SECOND_OPINION_MODELS="codex claude" || true
  assert_eq "$(count lane-codex)" "0" "codex-under-Claude session never gets codex"
  assert_eq "$(count lane-claude)" "1" "codex-under-Claude session gets claude"
else
  echo "  skip  scenarios 12 (ancestor form), 19-20: ps reports '$probe' for a script ancestor on this platform"
fi

echo "=== scenario 21: SECOND_OPINION_COUNT applies to review only ==="
reset_counts
set +e
env SECOND_OPINION_COUNT=2 SECOND_OPINION_MODELS="codex claude" \
  SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/lane-codex" SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/lane-claude" \
  "$SECOND_OPINION" quick "is this safe?" --cwd "$WORK" >"$TMP_ROOT/out21.txt" 2>"$TMP_ROOT/last.stderr"
rc21=$?
set -e
assert_eq "$rc21" "0" "quick with COUNT=2 exits 0"
assert_eq "$(count lane-codex)" "1" "quick with COUNT=2 invokes exactly one lane"
assert_eq "$(count lane-claude)" "0" "quick with COUNT=2 does not fan out"
grep -q "target=codex mode=quick" "$TMP_ROOT/last.stderr" || fail "quick did not take the single-target path"
grep -q "multi-lane" "$TMP_ROOT/last.stderr" && fail "quick took the multi-lane path"
assert_eq "$(jq -r '.agent' "$TMP_ROOT/out21.txt")" "external-codex" "quick stdout is the lane's own answer"

echo "=== scenario 22: SECOND_OPINION_COUNT is validated ==="
reset_counts
rc22=0
run_multi "$TMP_ROOT/out22.json" SECOND_OPINION_COUNT=0 || rc22=$?
assert_eq "$rc22" "1" "COUNT=0 exits 1"
grep -q "must be a positive integer" "$TMP_ROOT/last.stderr" || fail "COUNT=0 is not diagnosed"
assert_eq "$(( $(count lane-claude) + $(count lane-codex) ))" "0" "COUNT=0 invokes no CLI"
# ...and only where it is consulted: quick never reads a count, so a bad value
# must not fail an invocation it has no bearing on
reset_counts
rc22b=0
set +e
env SECOND_OPINION_COUNT=0 SECOND_OPINION_MODELS="codex claude" \
  SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/lane-codex" \
  "$SECOND_OPINION" quick "is this safe?" --cwd "$WORK" >/dev/null 2>"$TMP_ROOT/last.stderr"
rc22b=$?
set -e
assert_eq "$rc22b" "0" "COUNT=0 does not fail quick, which never reads it"
assert_eq "$(count lane-codex)" "1" "quick still dispatches with an invalid COUNT"

echo "=== scenario 23: a shortfall against the requested count is recorded, not implied away ==="
reset_counts
out23="$TMP_ROOT/out23.json"
rc23=0
run_multi "$out23" SECOND_OPINION_CURRENT_MODEL=codex || rc23=$?
assert_eq "$rc23" "0" "shortfall review exits 0 on the eligible lane"
grep -q "requested 2 opinions, selected 1" "$TMP_ROOT/last.stderr" || fail "shortfall is not stated"
assert_jq "$out23" '.qa_metadata.requested_count' "2" "artifact records the requested count"
assert_jq "$out23" '.qa_metadata.selected_count' "1" "artifact records the selected count"
assert_jq "$out23" '.qa_metadata.coverage' "degraded" "shortfall marks coverage degraded"
# control: full breadth is not degraded and carries the counts too
reset_counts
run_multi "$out23" || true
assert_jq "$out23" '.qa_metadata.coverage' "full" "control: two-of-two is full coverage"
assert_jq "$out23" '.qa_metadata.selected_count' "2" "control: union records selected_count"

echo "=== scenario 24: a declared identity the roster does not spell refuses; model ids normalize ==="
reset_counts
rc24=0
run_multi "$TMP_ROOT/out24.json" SECOND_OPINION_CURRENT_MODEL=clade SECOND_OPINION_COUNT=1 || rc24=$?
assert_eq "$rc24" "1" "unmatched declared identity exits 1"
assert_eq "$(( $(count lane-claude) + $(count lane-codex) ))" "0" "unmatched declared identity invokes no CLI"
grep -q "matches no roster identity" "$TMP_ROOT/last.stderr" || fail "unmatched declared identity is not stated"
assert_file_absent "$TMP_ROOT/out24.json" "unmatched declared identity writes no artifact"
# escape: name the model in the roster (no command needed) — it is then known and excluded
reset_counts
rc24b=0
run_multi "$TMP_ROOT/out24.json" SECOND_OPINION_CURRENT_MODEL=deepseek SECOND_OPINION_MODELS="deepseek codex claude" SECOND_OPINION_COUNT=1 || rc24b=$?
assert_eq "$rc24b" "0" "a roster-named session model proceeds"
assert_eq "$(count lane-codex)" "1" "a roster-named session model dispatches to the next entry"
# normalization: natural model ids compare equal to the built-in identities
reset_counts
run_multi "$TMP_ROOT/out24.json" SECOND_OPINION_CURRENT_MODEL=claude-opus-5 SECOND_OPINION_COUNT=1 || true
assert_eq "$(count lane-claude)" "0" "claude-opus-5 normalizes to claude and is excluded"
assert_eq "$(count lane-codex)" "1" "claude-opus-5 session gets codex"
reset_counts
run_multi "$TMP_ROOT/out24.json" SECOND_OPINION_CURRENT_MODEL=gpt-5.6-sol SECOND_OPINION_COUNT=1 || true
assert_eq "$(count lane-codex)" "0" "gpt-5.6-sol normalizes to codex and is excluded"
assert_eq "$(count lane-claude)" "1" "gpt-5.6-sol session gets claude"
reset_counts
run_multi "$TMP_ROOT/out24.json" SECOND_OPINION_CURRENT_MODEL=Opus SECOND_OPINION_COUNT=1 || true
assert_eq "$(count lane-claude)" "0" "Opus normalizes to claude and is excluded"
# none: the declared absence of a session model matches nothing and is not a typo
reset_counts
run_multi "$TMP_ROOT/out24.json" SECOND_OPINION_CURRENT_MODEL=none SECOND_OPINION_COUNT=1 || true
grep -q "matches no roster identity" "$TMP_ROOT/last.stderr" && fail "control: none is wrongly treated as unmatched"
assert_eq "$(count lane-codex)" "1" "control: none dispatches the roster's first entry"

echo "=== scenario 26: hyphen and underscore names share one configuration and run once ==="
reset_counts
out26="$TMP_ROOT/out26.json"
rc26=0
run_multi "$out26" SECOND_OPINION_MODELS="my-model my_model claude" \
  SECOND_OPINION_MY_MODEL_CMD="$TMP_ROOT/bin/lane-extra" || rc26=$?
assert_eq "$rc26" "0" "namespace-colliding roster exits 0"
assert_eq "$(count lane-extra)" "1" "the shared configuration is invoked once"
assert_jq "$out26" '.qa_metadata.lanes | length' "2" "the collision is not counted as a distinct opinion"
grep -q "skipping my_model: same configuration namespace" "$TMP_ROOT/last.stderr" || fail "namespace collision skip is not loud"

echo "=== scenario 27: a forced target requests exactly one opinion, whatever COUNT says ==="
reset_counts
out27="$TMP_ROOT/out27.json"
run_multi "$out27" SECOND_OPINION_TARGET=claude || true
assert_jq "$out27" '.qa_metadata.requested_count' "1" "forced target records requested_count 1"
assert_jq "$out27" '.qa_metadata.selected_count' "1" "forced target records selected_count 1"
assert_jq "$out27" '.qa_metadata.coverage' "null" "forced target is not degraded"
grep -q "requested 2 opinions" "$TMP_ROOT/last.stderr" && fail "forced target wrongly reports a shortfall"

echo "=== scenario 28: a union that fell short of the requested count is degraded ==="
reset_counts
out28="$TMP_ROOT/out28.json"
run_multi "$out28" SECOND_OPINION_COUNT=3 || true
assert_jq "$out28" '.qa_metadata.coverage' "degraded" "two-of-three union is degraded"
assert_jq "$out28" '.qa_metadata.requested_count' "3" "union records requested_count 3"
assert_jq "$out28" '.qa_metadata.selected_count' "2" "union records selected_count 2"
assert_jq "$out28" '[.qa_metadata.lanes[] | select(.status == "ok")] | length' "2" "both eligible lanes still answered"

echo "=== scenario 25: a settings-forced target that is refused names the roster's pick ==="
reset_counts
rc25=0
run_multi "$TMP_ROOT/out25.json" SECOND_OPINION_CURRENT_MODEL=codex SECOND_OPINION_TARGET=codex || rc25=$?
assert_eq "$rc25" "1" "settings-forced same-model target exits 1"
grep -q "without it the roster would select claude" "$TMP_ROOT/last.stderr" || fail "refusal does not name the roster's pick"

echo "=== scenario 29: a force does not carry a misspelled identity past the roster check ==="
# The unmatched-identity guard is what catches a typo in the one mandatory key.
# A --target naming the very model the typo misspells is exactly the case it
# exists for: `codxe` and `codex` are different strings, so without the check
# ahead of the force branch the session's own model reviews its own work.
reset_counts
rc29=0
set +e
env SECOND_OPINION_CURRENT_MODEL=codxe SECOND_OPINION_MODELS="claude codex" \
  SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/lane-claude" \
  SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/lane-codex" \
  "$SECOND_OPINION" review --target codex --range HEAD --cwd "$WORK" \
  --output "$TMP_ROOT/out29.json" >/dev/null 2>"$TMP_ROOT/last.stderr"
rc29=$?
set -e
assert_eq "$rc29" "1" "forced target under a misspelled identity exits 1"
assert_eq "$(( $(count lane-claude) + $(count lane-codex) ))" "0" "forced target under a misspelled identity invokes no CLI"
assert_file_absent "$TMP_ROOT/out29.json" "forced target under a misspelled identity writes no artifact"
grep -q "matches no roster identity" "$TMP_ROOT/last.stderr" || fail "forced refusal does not name the identity gap"
# detect takes the same path — a forced target must not make it report a target
reset_counts
rc29b=0
got29b=$(env SECOND_OPINION_CURRENT_MODEL=deepseek SECOND_OPINION_MODELS="claude codex" \
  SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/lane-claude" \
  SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/lane-codex" \
  "$SECOND_OPINION" detect --target codex 2>/dev/null) || rc29b=$?
assert_eq "$got29b:$rc29b" "none:1" "detect --target refuses an unspelled identity the same way"
# control: a spelled identity plus a force on a DIFFERENT model still dispatches
reset_counts
rc29c=0
set +e
env SECOND_OPINION_CURRENT_MODEL=claude SECOND_OPINION_MODELS="claude codex" \
  SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/lane-claude" \
  SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/lane-codex" \
  "$SECOND_OPINION" review --target codex --range HEAD --cwd "$WORK" \
  --output "$TMP_ROOT/out29c.json" >/dev/null 2>"$TMP_ROOT/last.stderr"
rc29c=$?
set -e
assert_eq "$rc29c" "0" "control: spelled identity with a cross-model force exits 0"
assert_eq "$(count lane-codex)" "1" "control: the forced cross-model target runs"
assert_eq "$(count lane-claude)" "0" "control: the session's own model still never runs"

echo "=== scenario 29b: an identity refusal never advises about a settings-seeded force ==="
# The hint that names what the roster would have picked is only useful when the
# FORCE is what refused. When the session's own identity is what refused, that
# pick is computed from the same untrustworthy identity, so it must stay silent.
# The force has to come from the environment: with --target the hint branch is
# already disqualified before the identity flag is ever consulted.
reset_counts
rc29d=0
run_multi "$TMP_ROOT/out29d.json" SECOND_OPINION_CURRENT_MODEL=codxe SECOND_OPINION_TARGET=codex || rc29d=$?
assert_eq "$rc29d" "1" "settings-forced target under a misspelled identity exits 1"
assert_eq "$(( $(count lane-claude) + $(count lane-codex) ))" "0" "settings-forced identity refusal invokes no CLI"
grep -q "matches no roster identity" "$TMP_ROOT/last.stderr" || fail "settings-forced refusal does not name the identity gap"
grep -q "without it the roster would select" "$TMP_ROOT/last.stderr" && fail "identity refusal wrongly advises about SECOND_OPINION_TARGET"

echo "=== scenario 29c: a DETECTED identity the roster does not name excludes nothing ==="
# The roster is the priority list of review TARGETS. Naming only the
# cross-model one is the most natural configuration there is, and the
# typo guard — which exists for a value the operator TYPED — must not
# turn it into a refusal.
# The session must be a DETECTED claude one. An env marker cannot establish
# that on its own — the process tree outranks it, correctly, so under a Codex
# contributor's runner CLAUDECODE=1 would lose to the real codex ancestor.
# Use a verified claude wrapper ancestor, else a detached run where the marker
# is the only signal there is.
if $ANCESTOR_VISIBLE; then
  reset_counts
  rm -f "$TMP_ROOT/out-under.json"
  rc29e=0
  run_under claude SECOND_OPINION_MODELS="codex" SECOND_OPINION_COUNT=1 || rc29e=$?
  assert_eq "$rc29e" "0" "target-only roster from a detected session exits 0"
  assert_eq "$(count lane-codex)" "1" "target-only roster dispatches the cross-model target"
  grep -q "matches no roster identity" "$TMP_ROOT/last.stderr" && fail "a detected identity is wrongly held to the roster spelling"
  # forced target from the same session: the force is honoured, not refused
  reset_counts
  rm -f "$TMP_ROOT/out-under.json"
  rc29f=0
  run_under claude SECOND_OPINION_MODELS="codex" SECOND_OPINION_TARGET=codex || rc29f=$?
  assert_eq "$rc29f" "0" "a force under a detected identity the roster omits exits 0"
  assert_eq "$(count lane-codex)" "1" "a force under a detected identity is honoured"
elif $DETACHED_HIDES_ANCESTOR; then
  reset_counts
  rm -f "$TMP_ROOT/out30.json"
  run_detached - "$TMP_ROOT/rc29e" "$TMP_ROOT/last.stderr" \
    CLAUDECODE=1 SECOND_OPINION_MODELS="codex" SECOND_OPINION_COUNT=1
  if detach_failed "$TMP_ROOT/rc29e"; then
    echo "  skip  scenario 29c: the run could not shed its harness ancestors"
  else
    assert_eq "$(cat "$TMP_ROOT/rc29e" 2>/dev/null || echo TIMEOUT)" "0" "target-only roster from a detected session exits 0"
    assert_eq "$(count lane-codex)" "1" "target-only roster dispatches the cross-model target"
  fi
else
  echo "  skip  scenario 29c: no way to establish a detected claude session on this platform"
fi

echo "=== scenario 29d: provider-qualified model ids canonicalize ==="
# Pi and OpenCode show an operator ids like openai-codex/gpt-5.6-sol, and those
# are exactly the operators required to declare an identity. Each must resolve
# to the same identity as its bare form.
for pair in "anthropic/claude-opus-4:claude" "openai/gpt-5.6-sol:codex" "openai-codex/gpt-5.6-sol:codex"; do
  qualified="${pair%%:*}"; expect="${pair##*:}"
  other=codex; [[ "$expect" == "codex" ]] && other=claude
  reset_counts
  run_multi "$TMP_ROOT/out29g.json" SECOND_OPINION_CURRENT_MODEL="$qualified" SECOND_OPINION_COUNT=1 || true
  assert_eq "$(count "lane-$expect")" "0" "$qualified resolves to $expect and is excluded"
  assert_eq "$(count "lane-$other")" "1" "$qualified session gets $other"
done

echo "=== scenario 30: no harness ancestor, no declaration -> the not-detected refusal ==="
# The `unknown` harness has no model, and its refusal is the only one that names
# the CI/plain-terminal escape. Under any harness runner the ancestor walk finds
# that harness, so the branch is unreachable without leaving the process tree:
# run detached, reparented away from every ancestor, with the marker variables
# unset. Probe the same mechanism first — a platform where the detachment does
# not hide the ancestor cannot run the scenario.
if $DETACHED_HIDES_ANCESTOR; then
  reset_counts
  rm -f "$TMP_ROOT/out30.json"
  run_detached - "$TMP_ROOT/rc30" "$TMP_ROOT/last.stderr" \
    SECOND_OPINION_MODELS="claude codex" SECOND_OPINION_COUNT=1
  if detach_failed "$TMP_ROOT/rc30"; then
    echo "  skip  scenario 30: the run could not shed its harness ancestors"
  else
  assert_eq "$(cat "$TMP_ROOT/rc30" 2>/dev/null || echo TIMEOUT)" "1" "undetected session exits 1"
  assert_eq "$(( $(count lane-claude) + $(count lane-codex) ))" "0" "undetected session invokes no CLI"
  assert_file_absent "$TMP_ROOT/out30.json" "undetected session writes no artifact"
  grep -q "harness not detected" "$TMP_ROOT/last.stderr" \
    || fail "undetected refusal does not say the harness was not detected"
  grep -q "or to none when there is no session model" "$TMP_ROOT/last.stderr" \
    || fail "undetected refusal does not name the none escape"
  fi
  # control: the same detached session declaring none dispatches
  reset_counts
  rm -f "$TMP_ROOT/out30.json"
  run_detached - "$TMP_ROOT/rc30b" "$TMP_ROOT/last.stderr" \
    SECOND_OPINION_MODELS="claude codex" SECOND_OPINION_COUNT=1 SECOND_OPINION_CURRENT_MODEL=none
  if detach_failed "$TMP_ROOT/rc30b"; then
    echo "  skip  scenario 30 control: the run could not shed its harness ancestors"
  else
  assert_eq "$(cat "$TMP_ROOT/rc30b" 2>/dev/null || echo TIMEOUT)" "0" "control: none declared in an undetected session exits 0"
  assert_eq "$(count lane-claude)" "1" "control: none dispatches the roster's first entry"
  fi

  echo "=== scenario 31: only a harness's own executable name establishes an identity ==="
  # A prefix match claims the Cursor EDITOR (`cursor`) and any wrapper or
  # monitor sharing a prefix (`codex-wrapper`), turning an ordinary shell into a
  # multi-model harness that refuses until an identity is declared. Detached, so
  # the walk sees the interposed name and nothing else.
  for bystander in cursor codex-wrapper; do
    reset_counts
    rm -f "$TMP_ROOT/out30.json"
    run_detached "$bystander" "$TMP_ROOT/rc31" "$TMP_ROOT/last.stderr" \
      SECOND_OPINION_MODELS="claude codex" SECOND_OPINION_COUNT=1
    if detach_failed "$TMP_ROOT/rc31"; then
      echo "  skip  scenario 31 ($bystander): the run could not shed its harness ancestors"
    else
      # Registered as a pass, not a silent no-op: a scenario that asserts
      # nothing must not read as green.
      if grep -q "harness not detected" "$TMP_ROOT/last.stderr"; then
        pass "an ancestor named $bystander establishes no harness identity"
      else
        fail "an ancestor named $bystander was read as a harness identity"
      fi
      assert_eq "$(cat "$TMP_ROOT/rc31" 2>/dev/null || echo TIMEOUT)" "1" "$bystander bystander still refuses (no identity)"
    fi
  done
  # control: the agent's own binary name still does establish one
  reset_counts
  rm -f "$TMP_ROOT/out30.json"
  run_detached cursor-agent "$TMP_ROOT/rc31b" "$TMP_ROOT/last.stderr" \
    SECOND_OPINION_MODELS="claude codex" SECOND_OPINION_COUNT=1
  if detach_failed "$TMP_ROOT/rc31b"; then
    echo "  skip  scenario 31 control: the run could not shed its harness ancestors"
  else
    assert_eq "$(cat "$TMP_ROOT/rc31b" 2>/dev/null || echo TIMEOUT)" "1" "control: cursor-agent ancestor still refuses"
    if grep -q "cursor fronts a selectable model" "$TMP_ROOT/last.stderr"; then
      pass "control: cursor-agent ancestor is identified as the cursor harness"
    else
      fail "control: cursor-agent ancestor is not identified as the cursor harness"
    fi
  fi

  echo "=== scenario 32: Codex's own markers outrank inherited Claude markers ==="
  # A sandboxed Codex tool process can have no visible Codex ancestor while
  # still carrying CLAUDECODE from an outer session. Reading the inherited
  # marker first would identify the session as claude and dispatch to codex —
  # its own model.
  for codex_marker in CODEX_SANDBOX=seatbelt CODEX_SANDBOX_NETWORK_DISABLED=1; do
    reset_counts
    rm -f "$TMP_ROOT/out30.json"
    run_detached - "$TMP_ROOT/rc32" "$TMP_ROOT/last.stderr" \
      CLAUDECODE=1 "$codex_marker" SECOND_OPINION_MODELS="codex claude" SECOND_OPINION_COUNT=1
    if detach_failed "$TMP_ROOT/rc32"; then
      echo "  skip  scenario 32 ($codex_marker): the run could not shed its harness ancestors"
    else
      assert_eq "$(cat "$TMP_ROOT/rc32" 2>/dev/null || echo TIMEOUT)" "0" "$codex_marker with CLAUDECODE exits 0"
      assert_eq "$(count lane-codex)" "0" "$codex_marker with CLAUDECODE never dispatches to codex"
      assert_eq "$(count lane-claude)" "1" "$codex_marker with CLAUDECODE gets claude"
    fi
  done
  # control: the Claude marker alone still identifies a Claude session
  reset_counts
  rm -f "$TMP_ROOT/out30.json"
  run_detached - "$TMP_ROOT/rc32b" "$TMP_ROOT/last.stderr" \
    CLAUDECODE=1 SECOND_OPINION_MODELS="codex claude" SECOND_OPINION_COUNT=1
  if detach_failed "$TMP_ROOT/rc32b"; then
    echo "  skip  scenario 32 control: the run could not shed its harness ancestors"
  else
    assert_eq "$(count lane-codex)" "1" "control: CLAUDECODE alone gets codex"
    assert_eq "$(count lane-claude)" "0" "control: CLAUDECODE alone never dispatches to claude"
  fi
else
  echo "  skip  scenarios 30-32: no detachment on this platform that hides the harness ancestor"
fi

echo "=== scenario 33: a project-file identity contradicting a detected session is refused ==="
# SECOND_OPINION_CURRENT_MODEL is session-scoped, but vstack.settings.toml is
# read by every session in the repo. A value set to make Pi work therefore
# arrives in Claude Code and Codex sessions too, where it outranks detection
# that was already correct and marks the session's own model cross-model —
# silently, with no skip line and no degraded stamp. The declaration is only
# trusted blindly when it came from the session's OWN environment.
s33_proj="$TMP_ROOT/proj33"
mkdir -p "$s33_proj"
git -C "$s33_proj" init -q
cp -R "$REPO_ROOT/skills/second-opinion" "$s33_proj/second-opinion"
S33="$s33_proj/second-opinion/scripts/second-opinion"
write_s33_settings() {
  printf '[env]\nSECOND_OPINION_CURRENT_MODEL = "%s"\n' "$1" > "$s33_proj/vstack.settings.toml"
}
# run_s33 <wrapper> <extra env...>: the declaration reaches the run ONLY through
# the project settings file — the caller's environment does not carry the key.
run_s33() {
  local h="$1"; shift
  local rc=0
  set +e
  env -u SECOND_OPINION_CURRENT_MODEL \
    SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/lane-claude" \
    SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/lane-codex" \
    "$@" "$TMP_ROOT/fake/$h" "$S33" review --range HEAD --cwd "$WORK" \
    --output "$TMP_ROOT/out33.json" >/dev/null 2>"$TMP_ROOT/last.stderr"
  rc=$?
  set -e
  return "$rc"
}
if $ANCESTOR_VISIBLE; then
  # A Pi-shaped declaration reaching a detected Claude Code session
  reset_counts
  rm -f "$TMP_ROOT/out33.json"
  write_s33_settings codex
  rc33=0
  run_s33 claude SECOND_OPINION_MODELS="claude codex" SECOND_OPINION_COUNT=1 || rc33=$?
  assert_eq "$rc33" "1" "project-file identity contradicting a detected claude session exits 1"
  assert_eq "$(( $(count lane-claude) + $(count lane-codex) ))" "0" "the contradiction invokes no CLI"
  assert_file_absent "$TMP_ROOT/out33.json" "the contradiction writes no artifact"
  grep -q "detected claude harness" "$TMP_ROOT/last.stderr" || fail "the refusal does not name the detected harness"
  grep -q "declare model codex" "$TMP_ROOT/last.stderr" || fail "the refusal does not name the declared model"
  # `none` is a contradiction too: in a detected Claude session it would make
  # claude eligible, which is the whole failure mode
  reset_counts
  write_s33_settings none
  rc33b=0
  run_s33 claude SECOND_OPINION_MODELS="claude codex" SECOND_OPINION_COUNT=1 || rc33b=$?
  assert_eq "$rc33b" "1" "a project-file none in a detected claude session exits 1"
  assert_eq "$(count lane-claude)" "0" "a project-file none never makes the session's own model eligible"
  # (an undetectable session with a project-sourced value is scenario 33b)
  # control 2: the SESSION's own environment still outranks detection
  reset_counts
  write_s33_settings codex
  rc33d=0
  set +e
  env SECOND_OPINION_CURRENT_MODEL=codex \
    SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/lane-claude" \
    SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/lane-codex" \
    SECOND_OPINION_MODELS="claude codex" SECOND_OPINION_COUNT=1 \
    "$TMP_ROOT/fake/claude" "$S33" review --range HEAD --cwd "$WORK" \
    --output "$TMP_ROOT/out33.json" >/dev/null 2>"$TMP_ROOT/last.stderr"
  rc33d=$?
  set -e
  assert_eq "$rc33d" "0" "control: a session-environment declaration is not second-guessed"
  assert_eq "$(count lane-claude)" "1" "control: the session-environment declaration still selects the target"
  # control 3: a project value AGREEING with detection is not a contradiction
  reset_counts
  write_s33_settings claude
  rc33e=0
  run_s33 claude SECOND_OPINION_MODELS="claude codex" SECOND_OPINION_COUNT=1 || rc33e=$?
  assert_eq "$rc33e" "0" "control: a project value agreeing with detection proceeds"
  assert_eq "$(count lane-codex)" "1" "control: the agreeing session still gets the cross-model target"
  # ...and it carries NO roster-spelling requirement, because the operator never
  # typed it for this session: it only repeats what detection already knew. A
  # roster naming just the cross-model target is the most natural configuration
  # there is and must work — the same regression already fixed for plain
  # detection, re-entering through the project-sourced path.
  reset_counts
  rm -f "$TMP_ROOT/out33.json"
  write_s33_settings claude
  rc33m=0
  run_s33 claude SECOND_OPINION_MODELS="codex" SECOND_OPINION_COUNT=1 || rc33m=$?
  assert_eq "$rc33m" "0" "an agreeing project value with a target-only roster exits 0"
  assert_eq "$(count lane-codex)" "1" "an agreeing project value with a target-only roster dispatches codex"
  assert_eq "$(count lane-claude)" "0" "the session's own model is still never dispatched to"
  grep -q "matches no roster identity" "$TMP_ROOT/last.stderr" \
    && fail "an agreeing project value is wrongly held to the roster spelling"
  # the mirrored harness, so the agreement path is pinned on both arms
  reset_counts
  rm -f "$TMP_ROOT/out33.json"
  write_s33_settings codex
  rc33n=0
  run_s33 codex SECOND_OPINION_MODELS="claude" SECOND_OPINION_COUNT=1 || rc33n=$?
  assert_eq "$rc33n" "0" "an agreeing project value in a detected codex session exits 0"
  assert_eq "$(count lane-claude)" "1" "an agreeing project value in a detected codex session dispatches claude"
  # the mirrored detected harness: the codex arm of the cross-check is its own
  # case and would otherwise be unpinned by a suite that only ever runs claude
  reset_counts
  rm -f "$TMP_ROOT/out33.json"
  write_s33_settings claude
  rc33f=0
  run_s33 codex SECOND_OPINION_MODELS="claude codex" SECOND_OPINION_COUNT=1 || rc33f=$?
  assert_eq "$rc33f" "1" "project-file identity contradicting a detected codex session exits 1"
  assert_eq "$(( $(count lane-claude) + $(count lane-codex) ))" "0" "the codex-side contradiction invokes no CLI"
  assert_file_absent "$TMP_ROOT/out33.json" "the codex-side contradiction writes no artifact"
  grep -q "detected codex harness" "$TMP_ROOT/last.stderr" || fail "the refusal does not name the detected codex harness"

  # A harness detection CANNOT arbitrate is the case the key exists for — and
  # the case where a stale project value has nothing to check it against, so
  # believing it is a silent same-model review with no detection to catch it.
  echo "=== scenario 33b: a project-sourced identity is refused in an undetectable session too ==="
  for s33_h in pi cursor-agent; do
    reset_counts
    rm -f "$TMP_ROOT/out33.json"
    write_s33_settings codex
    rc33g=0
    run_s33 "$s33_h" SECOND_OPINION_MODELS="claude codex" SECOND_OPINION_COUNT=1 || rc33g=$?
    assert_eq "$rc33g" "1" "($s33_h) a project-sourced identity exits 1"
    assert_eq "$(( $(count lane-claude) + $(count lane-codex) ))" "0" "($s33_h) a project-sourced identity invokes no CLI"
    assert_file_absent "$TMP_ROOT/out33.json" "($s33_h) a project-sourced identity writes no artifact"
    grep -q "comes from project settings" "$TMP_ROOT/last.stderr" \
      || fail "($s33_h) the refusal does not say the value came from project settings"
    grep -q "$s33_proj/vstack.settings.toml" "$TMP_ROOT/last.stderr" \
      || fail "($s33_h) the refusal does not name the file the value came from"
  done
  # control: the SAME value exported in the session's own environment is a real
  # declaration for that session and is honoured
  reset_counts
  write_s33_settings codex
  rc33h=0
  set +e
  env SECOND_OPINION_CURRENT_MODEL=codex \
    SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/lane-claude" \
    SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/lane-codex" \
    SECOND_OPINION_MODELS="claude codex" SECOND_OPINION_COUNT=1 \
    "$TMP_ROOT/fake/pi" "$S33" review --range HEAD --cwd "$WORK" \
    --output "$TMP_ROOT/out33.json" >/dev/null 2>"$TMP_ROOT/last.stderr"
  rc33h=$?
  set -e
  assert_eq "$rc33h" "0" "control: a session-exported identity is honoured in a Pi session"
  assert_eq "$(count lane-claude)" "1" "control: the Pi-on-codex session gets claude"
  assert_eq "$(count lane-codex)" "0" "control: the Pi-on-codex session never gets codex"
  # A set-but-EMPTY caller value is not a declaration. It still does its job —
  # vstack_load_project_env re-asserts it over the project file — which is
  # exactly why nothing is declared afterwards, so the run must take the
  # UNDECLARED path, not the project-sourced one and not a session-scoped one.
  reset_counts
  rm -f "$TMP_ROOT/out33.json"
  write_s33_settings codex
  rc33j=0
  set +e
  env SECOND_OPINION_CURRENT_MODEL= \
    SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/lane-claude" \
    SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/lane-codex" \
    SECOND_OPINION_MODELS="claude codex" SECOND_OPINION_COUNT=1 \
    "$TMP_ROOT/fake/pi" "$S33" review --range HEAD --cwd "$WORK" \
    --output "$TMP_ROOT/out33.json" >/dev/null 2>"$TMP_ROOT/last.stderr"
  rc33j=$?
  set -e
  assert_eq "$rc33j" "1" "an empty caller value takes the undeclared path (exit 1)"
  assert_eq "$(( $(count lane-claude) + $(count lane-codex) ))" "0" "an empty caller value invokes no CLI"
  grep -q "model undeclared" "$TMP_ROOT/last.stderr" \
    || fail "an empty caller value is not reported as undeclared"
  grep -q "comes from project settings" "$TMP_ROOT/last.stderr" \
    && fail "an empty caller value is wrongly treated as the project file's declaration"
  # control: the same session with the value actually exported proceeds
  reset_counts
  rc33k=0
  set +e
  env SECOND_OPINION_CURRENT_MODEL=codex \
    SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/lane-claude" \
    SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/lane-codex" \
    SECOND_OPINION_MODELS="claude codex" SECOND_OPINION_COUNT=1 \
    "$TMP_ROOT/fake/pi" "$S33" review --range HEAD --cwd "$WORK" \
    --output "$TMP_ROOT/out33.json" >/dev/null 2>"$TMP_ROOT/last.stderr"
  rc33k=$?
  set -e
  assert_eq "$rc33k" "0" "control: a non-empty exported value is a declaration"

  # every project source is covered, not just the settings file
  for s33_file in .env .env.local .vstack/settings.toml; do
    reset_counts
    rm -f "$s33_proj/vstack.settings.toml"
    mkdir -p "$s33_proj/.vstack"
    case "$s33_file" in
      *.toml) printf '[env]\nSECOND_OPINION_CURRENT_MODEL = "codex"\n' > "$s33_proj/$s33_file" ;;
      *)      printf 'export SECOND_OPINION_CURRENT_MODEL=codex\n' > "$s33_proj/$s33_file" ;;
    esac
    rc33i=0
    run_s33 pi SECOND_OPINION_MODELS="claude codex" SECOND_OPINION_COUNT=1 || rc33i=$?
    assert_eq "$rc33i" "1" "($s33_file) a project-sourced identity exits 1"
    grep -q "$s33_proj/$s33_file" "$TMP_ROOT/last.stderr" || fail "($s33_file) the refusal does not name this file"
    rm -f "$s33_proj/$s33_file"
  done
else
  echo "  skip  scenario 33: ps hides script ancestors on this platform"
fi

echo "=== scenario 34: an explicitly empty roster refuses instead of silently defaulting ==="
# `${VAR:-default}` would treat an emptied roster as unset and dispatch to the
# very models the operator just removed.
reset_counts
rc34=0
run_multi "$TMP_ROOT/out34.json" SECOND_OPINION_MODELS= || rc34=$?
assert_eq "$rc34" "1" "an empty roster exits 1"
assert_eq "$(( $(count lane-claude) + $(count lane-codex) ))" "0" "an empty roster invokes no CLI"
assert_file_absent "$TMP_ROOT/out34.json" "an empty roster writes no artifact"
grep -q "SECOND_OPINION_MODELS is set but empty" "$TMP_ROOT/last.stderr" || fail "the empty roster is not diagnosed"
# control: unset still gets the default roster
reset_counts
rc34b=0
set +e
env -u SECOND_OPINION_MODELS SECOND_OPINION_CURRENT_MODEL=none SECOND_OPINION_COUNT=1 \
  SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/lane-claude" \
  SECOND_OPINION_CODEX_CMD="$TMP_ROOT/bin/lane-codex" \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$TMP_ROOT/out34b.json" \
  >/dev/null 2>"$TMP_ROOT/last.stderr"
rc34b=$?
set -e
assert_eq "$rc34b" "0" "control: an unset roster still uses the default"
assert_eq "$(count lane-claude)" "1" "control: the default roster's first entry runs"

echo "=== scenario 35: a refusal names availability vs identity as its cause ==="
# Sending an operator whose CLIs are simply not installed to check their model
# identity points at a setting that is not wrong.
reset_counts
rc35=0
set +e
env SECOND_OPINION_CURRENT_MODEL=none SECOND_OPINION_MODELS="claude codex" \
  SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/no-such-cli-claude" \
  SECOND_OPINION_CODEX_CMD="$TMP_ROOT/no-such-cli-codex" \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$TMP_ROOT/out35.json" \
  >/dev/null 2>"$TMP_ROOT/last.stderr"
rc35=$?
set -e
assert_eq "$rc35" "1" "an all-unavailable roster exits 1"
grep -q "skipped for availability, not identity" "$TMP_ROOT/last.stderr" \
  || fail "the refusal does not name availability as the cause"
grep -q "SECOND_OPINION_<NAME>_CMD" "$TMP_ROOT/last.stderr" || fail "the refusal does not name the per-target command key"
# control: an identity refusal does NOT claim availability
reset_counts
run_multi "$TMP_ROOT/out35b.json" SECOND_OPINION_CURRENT_MODEL=claude SECOND_OPINION_MODELS="claude" || true
grep -q "skipped for availability" "$TMP_ROOT/last.stderr" && fail "an identity refusal wrongly blames availability"
grep -q "runs the same model as this session" "$TMP_ROOT/last.stderr" || fail "the identity refusal lost its own reason"
# mixed causes: one candidate excluded for identity, the other unavailable. The
# availability-only line would be wrong here — the roster DID lose a candidate
# to identity — so both skip reasons must stand on their own with no verdict on
# top. This is the case the `! $SKIPPED_SAME_MODEL` conjunct exists for.
reset_counts
rc35c=0
set +e
env SECOND_OPINION_CURRENT_MODEL=claude SECOND_OPINION_MODELS="claude codex" \
  SECOND_OPINION_CLAUDE_CMD="$TMP_ROOT/bin/lane-claude" \
  SECOND_OPINION_CODEX_CMD="$TMP_ROOT/no-such-cli-codex" \
  "$SECOND_OPINION" review --range HEAD --cwd "$WORK" --output "$TMP_ROOT/out35c.json" \
  >/dev/null 2>"$TMP_ROOT/last.stderr"
rc35c=$?
set -e
assert_eq "$rc35c" "1" "a mixed-cause roster exits 1"
assert_eq "$(count lane-claude)" "0" "a mixed-cause refusal invokes no CLI"
grep -q "runs the same model as this session" "$TMP_ROOT/last.stderr" || fail "the mixed-cause refusal lost the identity skip"
grep -q "CLI not found" "$TMP_ROOT/last.stderr" || fail "the mixed-cause refusal lost the availability skip"
grep -q "skipped for availability, not identity" "$TMP_ROOT/last.stderr" \
  && fail "a mixed-cause refusal wrongly claims availability was the only cause" \
  || pass "a mixed-cause refusal does not claim availability was the only cause"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
