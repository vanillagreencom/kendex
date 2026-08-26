#!/usr/bin/env bash
# Index-parse contract: the INDEX Link cell resolves each decision's document,
# and `get` enriches from that document.
#
# A Link cell the parser cannot resolve yields an empty path, and an empty path
# makes body search skip the decision and `get` report an unknown date — a miss
# indistinguishable from "no decision governs this area". The three cell shapes
# below all appear in indexes written from this skill's row template, so all
# three must resolve.
#
# Teeth: each check is re-run against a mutated copy of the script that breaks
# the behavior under test, and must catch it.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
DECISIONS="$SKILL_DIR/scripts/decisions"

PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# --- Fixture: one decision per supported Link cell shape ---------------------

REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/docs/decisions"

cat >"$REPO/docs/decisions/INDEX.md" <<'EOF'
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-01-01 | D001 | PROJ-1 | Markdown link cell | Reason one | Never | Active | [Full](D001-md-link.md) |
| 2026-01-02 | D002 | PROJ-2 | Backticked cell | Reason two | Never | Active | Full -> `D002-backtick.md` |
| 2026-01-03 | D003 | PROJ-3 | Bare filename cell | Reason three | Never | Active | Full -> D003-bare.md |
| 2026-01-04 | D004 | PROJ-4 | No document yet | Reason four | Never | Active | pending |
EOF

printf '# D001\n\n**Date**: 2026-01-01\n\nGoverns tokenone handling.\n' \
  >"$REPO/docs/decisions/D001-md-link.md"
printf '# D002\n\n**Date**: 2026-01-02\n\nGoverns tokentwo handling.\n' \
  >"$REPO/docs/decisions/D002-backtick.md"
printf '# D003\n\n**Date**:2026-01-03\n\nGoverns tokenthree handling.\n' \
  >"$REPO/docs/decisions/D003-bare.md"

# run <script> <args...> — stdout only, from inside the fixture repo.
run() {
  local script="$1"
  shift
  (cd "$REPO" && DECISIONS_DIR="$REPO/docs/decisions" "$script" "$@" 2>/dev/null)
}

# check_parse <script>
# Prints the name of every failed expectation (empty output = all held).
check_parse() {
  local script="$1" broken=""

  # Each shape resolves to its document, so a body-only keyword finds it.
  [[ "$(run "$script" search tokenone | jq -r '[.[].id] | join(",")')" == "D001" ]] \
    || broken="$broken md-link-body"
  [[ "$(run "$script" search tokentwo | jq -r '[.[].id] | join(",")')" == "D002" ]] \
    || broken="$broken backtick-body"
  [[ "$(run "$script" search tokenthree | jq -r '[.[].id] | join(",")')" == "D003" ]] \
    || broken="$broken bare-body"

  # get resolves the same path and reads the date out of the document.
  [[ "$(run "$script" get D001 | jq -r '.path')" == "$REPO/docs/decisions/D001-md-link.md" ]] \
    || broken="$broken md-link-path"
  [[ "$(run "$script" get D002 | jq -r '.path')" == "$REPO/docs/decisions/D002-backtick.md" ]] \
    || broken="$broken backtick-path"
  [[ "$(run "$script" get D001 | jq -r '.date')" == "2026-01-01" ]] \
    || broken="$broken date-enrichment"
  # The date label tolerates no space after the colon.
  [[ "$(run "$script" get D003 | jq -r '.date')" == "2026-01-03" ]] \
    || broken="$broken date-unspaced"

  # A cell naming no document resolves to nothing rather than a wrong path.
  [[ "$(run "$script" get D004 | jq -r '.path')" == "" ]] \
    || broken="$broken empty-cell-path"
  [[ "$(run "$script" get D004 | jq -r '.date')" == "unknown" ]] \
    || broken="$broken empty-cell-date"

  printf '%s' "$broken"
}

# mutate <name> <sed-script> — copies scripts/ and patches the entry point.
mutate() {
  local dir="$TMP_ROOT/mutant-$1"
  mkdir -p "$dir"
  cp -R "$SKILL_DIR/scripts/lib" "$dir/lib"
  sed "$2" "$DECISIONS" >"$dir/decisions"
  chmod +x "$dir/decisions"
  printf '%s' "$dir/decisions"
}

# expect_caught <clause> <mutant> <description>
expect_caught() {
  local clause="$1" mutant="$2" desc="$3" out
  out="$(check_parse "$mutant")"
  if [[ "$out" == *"$clause"* ]]; then
    pass "$desc"
  else
    fail "$desc (check output: '$out')"
  fi
}

echo "=== decisions INDEX link-cell and get enrichment ==="

broken="$(check_parse "$DECISIONS")"
if [[ -z "$broken" ]]; then
  pass "every Link cell shape resolves and get enriches from the document"
else
  fail "index parse contract broken:$broken"
fi

echo "=== malformed rows are named, not silently dropped ==="

# A row that opens like a decision but misses the eight-cell contract is skipped
# by the parser. Skipped silently, a mistyped row reads downstream as a decision
# that was never recorded — the index says one thing, every consumer says
# another, and nothing points at the row to fix.
BADREPO="$TMP_ROOT/badrepo"
mkdir -p "$BADREPO/docs/decisions"
cat >"$BADREPO/docs/decisions/INDEX.md" <<'EOF'
# Architectural Decision Log

| Date | ID | Research | Decision | Rationale | Revisit When | Status | Link |
|------|----|----------|----------|-----------|--------------|--------|------|
| 2026-02-01 | D101 | PROJ-1 | Well-formed row | Reason one | Never | Active | [Full](D101.md) |
| 2026-02-02 | D102 | PROJ-2 | Truncated row | Active |
| 2026-02-03 | D103 | PROJ-3 | Second well-formed | Reason three | Never | Active | [Full](D103.md) |
EOF

run_bad() { (cd "$BADREPO" && DECISIONS_DIR="$BADREPO/docs/decisions" "$DECISIONS" "$@"); }

bad_stdout="$(run_bad list 2>/dev/null)"
bad_stderr="$(run_bad list 2>&1 >/dev/null)"

# stdout contract is unchanged: the parseable rows, and only those.
if [[ "$(jq -r '[.[].id] | join(",")' <<<"$bad_stdout")" == "D101,D103" ]]; then
  pass "stdout still carries exactly the rows that parse"
else
  fail "stdout contract changed (got: $bad_stdout)"
fi

if grep -q 'D102\|:6:' <<<"$bad_stderr"; then
  pass "the malformed row is named on stderr"
else
  fail "the malformed row was dropped without a diagnostic (stderr: $bad_stderr)"
fi

if grep -q ':6:' <<<"$bad_stderr"; then
  pass "the diagnostic cites the row's line in the index"
else
  fail "the diagnostic does not cite the index line (stderr: $bad_stderr)"
fi

# The diagnostic must not fire for a healthy index, or it is just noise.
if [[ -z "$( (cd "$REPO" && DECISIONS_DIR="$REPO/docs/decisions" "$DECISIONS" list 2>&1 >/dev/null) )" ]]; then
  pass "a well-formed index emits no warning"
else
  fail "a well-formed index emitted a spurious warning"
fi

echo "=== teeth ==="

# Drop the non-markdown-link fallbacks: only [text](path) cells resolve.
expect_caught backtick-body \
  "$(mutate no-fallback 's/+ \[ \$cell | scan/+ [ empty | scan/g')" \
  "losing the backticked-filename fallback is caught"

expect_caught bare-body \
  "$(mutate no-fallback2 's/+ \[ \$cell | scan/+ [ empty | scan/g')" \
  "losing the bare-filename fallback is caught"

# Stop get from adopting the date parsed out of the document.
expect_caught date-enrichment \
  "$(mutate no-date 's/date="\$parsed"/date="mutated"/')" \
  "losing get's date enrichment is caught"

# Drop the malformed-row diagnostic: the rows still vanish, but nothing says so.
silent="$(mutate no-warn 's/| select((.value | split("|") | length) < 9)/| select(false)/')"
if [[ -z "$( (cd "$BADREPO" && DECISIONS_DIR="$BADREPO/docs/decisions" "$silent" list 2>&1 >/dev/null) )" ]]; then
  pass "losing the malformed-row diagnostic is caught"
else
  fail "the no-warn mutant still emitted a diagnostic"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
