#!/usr/bin/env bash
# Contract test for fail-closed reviewer measurements.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ORCH_DIR="$SKILL_DIR/../orch"
CHECK="$ORCH_DIR/scripts/review-artifact-check"
TMP_ROOT=$(mktemp -d)
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
out=""

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

assert_row() {
  table="$1" name="$2" actual="$3" expected="$4"
  if [ "$actual" = "$expected" ]; then
    pass "$table: $name"
  else
    fail "$table: $name" "expected <$expected>, got <$actual>; output: $out"
  fi
}

assert_table_executed() {
  table="$1" rows="$2"
  if [ "$rows" -gt 0 ]; then
    pass "$table: executed rows"
  else
    fail "$table: executed rows" "the table executed no assertion row"
  fi
}

artifact() {
  path="$TMP_ROOT/$1.json"
  printf '%s' "$2" > "$path"
  printf '%s' "$path"
}

read_result() {
  path="$1"
  rc=0
  out=""
  out=$("$CHECK" --file "$path" 2>/dev/null) || rc=$?
  reason=$(jq -r '.reason' <<<"$out" 2>/dev/null) || reason=unparseable
  ok=$(jq -r '.ok' <<<"$out" 2>/dev/null) || ok=unparseable
  declaration=$(jq -r 'if has("measurement_failed") then .measurement_failed else "ABSENT" end' <<<"$out" 2>/dev/null) || declaration=unparseable
  consistent=no
  if { [ "$ok" = true ] && [ "$rc" -eq 0 ]; } || { [ "$ok" = false ] && [ "$rc" -ne 0 ]; }; then
    consistent=yes
  fi
}

echo "=== documentation shape table ==="
# These rows prove token presence only. The behavior table proves enforcement.
documentation_rows=0
while IFS=$'\t' read -r name relative_path token; do
  if grep -Fq -- "$token" "$SKILL_DIR/$relative_path"; then
    actual=present
  else
    actual=missing
  fi
  out="$relative_path lacks $token"
  assert_row "documentation shape" "$name" "$actual" present
  documentation_rows=$((documentation_rows + 1))
done <<'ROWS'
reviewer skill names the declaration	SKILL.md	measurement_failed
schema names the zero-sample rejection	schemas/review-finding.md	zero_sample
schema names the declaration field	schemas/review-finding.md	measurement_failed
schema names an invalid declaration	schemas/review-finding.md	invalid_declaration
schema names accepted undermeasurement	schemas/review-finding.md	valid_undermeasured
ROWS
assert_table_executed "documentation shape" "$documentation_rows"

if [ ! -d "$ORCH_DIR" ]; then
  printf '  skip  artifact tables (sibling skills/orch is not installed)\n'
elif [ ! -x "$CHECK" ]; then
  fail "artifact acceptance table" "skills/orch is installed but review-artifact-check is missing or not executable at $CHECK"
else
  echo "=== artifact acceptance and declaration table ==="
  artifact_rows=0
  while IFS=$'\t' read -r name body probe expected; do
    path=$(artifact "$name" "$body") || {
      fail "artifact acceptance and declaration: $name" "could not write fixture"
      continue
    }
    read_result "$path"
    case "$probe" in
      reason)
        actual="reason=$reason;rc=$rc"
        ;;
      declared)
        actual="reason=$reason;rc=$rc;declaration=$declaration;ok=$ok;consistent=$consistent"
        ;;
      absent-declaration)
        actual="declaration=$declaration;consistent=$consistent"
        ;;
      teaching)
        teaches=$(jq -r '.detail | test("measurement_failed")' <<<"$out" 2>/dev/null) || teaches=unparseable
        actual="teaches=$teaches;consistent=$consistent"
        ;;
      *)
        actual="unknown-probe=$probe"
        ;;
    esac
    assert_row "artifact acceptance and declaration" "$name" "$actual" "$expected"
    artifact_rows=$((artifact_rows + 1))
  done <<'ROWS'
zero mutants	{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0; stability: 10/10 at 16 threads"}	reason	reason=zero_sample;rc=1
zero stability runs	{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 0/0 at 16 threads"}	reason	reason=zero_sample;rc=1
zero threads	{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 0 threads"}	reason	reason=zero_sample;rc=1
wrapped citation	{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/\n0"}	reason	reason=zero_sample;rc=1
zero percentiles	{"agent":"reviewer-perf","verdict":"pass","summary":"s","blockers":[],"suggestions":[],"qa_metadata":{"perf_qa":{"percentiles":{"p50":0,"p99":0}}}}	reason	reason=zero_sample;rc=1
absent percentiles	{"agent":"reviewer-perf","verdict":"pass","summary":"s","blockers":[],"suggestions":[],"qa_metadata":{"perf_qa":{"regression_pct":0}}}	reason	reason=zero_sample;rc=1
measured stability failure	{"agent":"reviewer-test","verdict":"action_required","summary":"mutation: killed 3/3; stability: 0/10 at 16 threads"}	reason	reason=valid;rc=0
surviving mutants	{"agent":"reviewer-test","verdict":"action_required","summary":"mutation: killed 0/3; stability: 10/10 at 16 threads"}	reason	reason=valid;rc=0
measured citation	{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads"}	reason	reason=valid;rc=0
measured percentiles	{"agent":"reviewer-perf","verdict":"pass","summary":"s","blockers":[],"suggestions":[],"qa_metadata":{"perf_qa":{"percentiles":{"p50":0,"p99":4.2}}}}	reason	reason=valid;rc=0
uncited artifact	{"agent":"reviewer-quality","verdict":"pass","summary":"no measurement in scope for this domain"}	reason	reason=valid;rc=0
quoted in blocker	{"agent":"reviewer-test","verdict":"action_required","summary":"reviewed the gate","blockers":[{"id":1,"title":"t","location":"tests/x.sh","description":"the fixture uses mutation: killed 0/0 to prove the gate rejects","recommendation":"r","priority":3,"estimate":1}],"suggestions":[],"qa_metadata":{}}	reason	reason=valid;rc=0
same text in summary	{"agent":"reviewer-test","verdict":"pass","summary":"the fixture uses mutation: killed 0/0 to prove the gate rejects","blockers":[],"suggestions":[],"qa_metadata":{}}	reason	reason=zero_sample;rc=1
declared failure	{"agent":"reviewer-test","verdict":"action_required","summary":"harness produced nothing: mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":"cargo-mutants selected 0 mutants for the changed file"}	declared	reason=valid_undermeasured;rc=0;declaration=cargo-mutants selected 0 mutants for the changed file;ok=true;consistent=yes
tolerant shape adopts declaration	{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","measurement_failed":"cargo-mutants selected 0 mutants for this module"}	reason	reason=valid_undermeasured;rc=0
pass verdict with declaration	{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":"cargo-mutants selected 0 mutants for the changed file"}	reason	reason=valid_undermeasured;rc=0
period declaration	{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":"."}	reason	reason=invalid_declaration;rc=1
n-a declaration	{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":"n/a"}	reason	reason=invalid_declaration;rc=1
none declaration	{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":"none"}	reason	reason=invalid_declaration;rc=1
unknown declaration	{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":"unknown"}	reason	reason=invalid_declaration;rc=1
whitespace declaration	{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":"   "}	reason	reason=invalid_declaration;rc=1
dashes declaration	{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":"---"}	reason	reason=invalid_declaration;rc=1
boolean declaration	{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":true}	reason	reason=invalid_declaration;rc=1
numeric declaration	{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0","blockers":[],"suggestions":[],"measurement_failed":0}	reason	reason=invalid_declaration;rc=1
undeclared field stays absent	{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads"}	absent-declaration	declaration=ABSENT;consistent=yes
rejection teaches declaration	{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 0/0"}	teaching	teaches=true;consistent=yes
ROWS
  assert_table_executed "artifact acceptance and declaration" "$artifact_rows"

  real_jq=$(command -v jq)
  chatty_dir="$TMP_ROOT/jq-chatty"
  broken_dir="$TMP_ROOT/jq-broken"
  mkdir -p "$chatty_dir" "$broken_dir"
  cat > "$chatty_dir/jq" <<SHIM
#!/usr/bin/env bash
echo "chatty jq diagnostic" >&2
exec "$real_jq" "\$@"
SHIM
  cat > "$broken_dir/jq" <<SHIM
#!/usr/bin/env bash
for arg in "\$@"; do
  case "\$arg" in
    *"gate:zero-sample"*) echo "jq: error: simulated torn read" >&2; exit 5 ;;
  esac
done
exec "$real_jq" "\$@"
SHIM
  chmod +x "$chatty_dir/jq" "$broken_dir/jq"
  clean=$(artifact clean-channel '{"agent":"reviewer-test","verdict":"pass","summary":"mutation: killed 3/3; stability: 10/10 at 16 threads"}')

  echo "=== jq output channel table ==="
  channel_rows=0
  while IFS=$'\t' read -r name shim expected; do
    case "$shim" in
      chatty) shim_path="$chatty_dir:$PATH" ;;
      broken) shim_path="$broken_dir:$PATH" ;;
      *) shim_path="$PATH" ;;
    esac
    rc=0
    out=""
    out=$(PATH="$shim_path" "$CHECK" --file "$clean" 2>/dev/null) || rc=$?
    reason=$("$real_jq" -r '.reason' <<<"$out" 2>/dev/null) || reason=unparseable
    declaration=$("$real_jq" -r 'if has("measurement_failed") then "present" else "absent" end' <<<"$out" 2>/dev/null) || declaration=unparseable
    case "$shim" in
      chatty) actual="reason=$reason;rc=$rc;declaration=$declaration" ;;
      broken)
        nonzero=no
        [ "$rc" -eq 0 ] || nonzero=yes
        actual="reason=$reason;nonzero=$nonzero"
        ;;
    esac
    assert_row "jq output channel" "$name" "$actual" "$expected"
    channel_rows=$((channel_rows + 1))
  done <<'ROWS'
successful stderr is not a finding	chatty	reason=valid;rc=0;declaration=absent
broken gate fails closed	broken	reason=invalid;nonzero=yes
ROWS
  assert_table_executed "jq output channel" "$channel_rows"
fi

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
