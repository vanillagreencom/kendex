#!/usr/bin/env bash
# Regression test for second-opinion multi-lane review (VST-124).
#
# GH-bot parity: model diversity has different blind spots, so a review with no
# forced target runs EVERY available lane in SECOND_OPINION_REVIEW_TARGETS on
# the same derived scope and writes one union artifact:
#   - findings deduplicated by normalized location (file + symbol), duplicate
#     findings carry every contributing lane in `sources`;
#   - a suggestion whose location a blocker already covers is dropped;
#   - lane artifacts kept beside the union as <output>.<target>.json;
#   - one failed lane degrades coverage LOUDLY (qa_metadata.coverage,
#     qa_metadata.lanes) instead of failing the run or narrowing silently;
#   - all lanes failed -> no artifact, exit 4/5 (no-verdict class);
#   - SECOND_OPINION_TARGET / --target still force the single-lane path;
#   - a third target is a settings entry (SECOND_OPINION_<NAME>_CMD), not code.
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
  env "$@" \
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
echo "=== scenario 5: custom lane via SECOND_OPINION_REVIEW_TARGETS + <NAME>_CMD ==="
reset_counts
out5="$TMP_ROOT/out5.json"
rc5=0
run_multi "$out5" \
  SECOND_OPINION_REVIEW_TARGETS="claude my-model" \
  SECOND_OPINION_MY_MODEL_CMD="$TMP_ROOT/bin/lane-extra" || rc5=$?
assert_eq "$rc5" "0" "custom lane review exits 0"
assert_eq "$(count lane-extra)" "1" "custom lane CLI invoked exactly once"
assert_eq "$(count lane-codex)" "0" "lanes outside SECOND_OPINION_REVIEW_TARGETS do not run"
assert_jq "$out5" '.agent' "external-union(claude+my-model)" "union agent includes the custom lane"
assert_file_exists "$out5.my-model.json" "custom lane artifact kept beside the union"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
