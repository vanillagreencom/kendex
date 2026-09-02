#!/usr/bin/env bash
# Regression tests for dev-round-live, the one owner of "is a fix round in
# flight here". Both rebase paths ask it, so an arm lost here is a branch
# rebased out from under a delegated agent, and the arms that matter are the
# ones a prose restatement kept dropping.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
LIVE="$REPO_ROOT/skills/orch/scripts/dev-round-live"
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

rc_of() {
  local rc=0
  "$@" >/dev/null 2>&1 || rc=$?
  printf '%s' "$rc"
}

echo "=== dev-round-live ==="

wt="$TMP_ROOT/wt"
mkdir -p "$wt/tmp"
ask=("$LIVE" --worktree "$wt" --issue KEN-1 --state-dir "$wt/tmp")

assert_eq "$(rc_of "${ask[@]}")" "0" "no workflow state is no round in flight"
"$STATE" --state-dir "$wt/tmp" init KEN-1 --worktree "$wt" --branch test >/dev/null
assert_eq "$(rc_of "${ask[@]}")" "0" "a state file recording no round is no round in flight"

"$STATE" --state-dir "$wt/tmp" set KEN-1 dev_round_id 9-9 >/dev/null
assert_eq "$([[ -e "$wt/tmp/dev-round-KEN-1-9-9.json" ]] && echo present || echo absent)" "absent" \
  "control: the token names no record on disk"
assert_eq "$(rc_of "${ask[@]}")" "0" "a token with no record is no round in flight"

printf '{}\n' > "$wt/tmp/dev-round-KEN-1-9-9.json"
assert_eq "$(rc_of "${ask[@]}")" "3" "a record with no receipt is a live round"
assert_eq "$(grep -cF 'fix round 9-9 is live' <<<"$("${ask[@]}" 2>&1 >/dev/null || true)")" "1" \
  "the refusal names the round it refuses for"

# Only the ACTIVE token is read, so a landed receipt ends the round and a
# leftover record from an earlier one does not block.
printf '{}\n' > "$wt/tmp/dev-return-KEN-1-9-9.json"
assert_eq "$(rc_of "${ask[@]}")" "0" "the receipt landing ends the round"
"$STATE" --state-dir "$wt/tmp" set KEN-1 dev_round_id 10-10 >/dev/null
assert_eq "$(rc_of "${ask[@]}")" "0" "an earlier round's leftover record does not block a fresh token"

# One stub answers both state reads from the environment, so each case changes
# one answer and `env` keeps no setting past its own case.
mutant_root="$TMP_ROOT/mutant"
mkdir -p "$mutant_root"
cp -R "$REPO_ROOT/skills/orch/scripts" "$mutant_root/"
mutant_ask=("$mutant_root/scripts/dev-round-live" --worktree "$wt" --issue KEN-1 --state-dir "$wt/tmp")
cat > "$mutant_root/scripts/workflow-state" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
  exists)
    [[ "${STUB_EXISTS:-}" == fail ]] && exit 7
    printf '%s\n' "${STUB_EXISTS_JSON:-{\"path\":\"/x\",\"exists\":true\}}"
    exit 0
    ;;
  get)
    [[ "${STUB_GET:-}" == fail ]] && exit 5
    printf '\n'
    exit 0
    ;;
  esac
done
exit 0
EOF
chmod +x "$mutant_root/scripts/workflow-state"

assert_eq "$(rc_of env "${mutant_ask[@]}")" "0" \
  "control: an honest stub answering no round proceeds"
assert_eq "$(rc_of env STUB_EXISTS=fail "${mutant_ask[@]}")" "1" \
  "a failing exists hands back rather than proceeding"
assert_eq "$(rc_of env STUB_EXISTS_JSON='{"path":"/x","exists":"maybe"}' "${mutant_ask[@]}")" "1" \
  "an answer that is neither yes nor no hands back"
assert_eq "$(rc_of env STUB_GET=fail "${mutant_ask[@]}")" "1" \
  "a failing round read hands back rather than proceeding"

# Usage failures are their own exit code, never mistaken for an answer.
assert_eq "$(rc_of "$LIVE" --worktree "$wt" --issue ../escape)" "2" "a path-unsafe issue id is a usage error"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
