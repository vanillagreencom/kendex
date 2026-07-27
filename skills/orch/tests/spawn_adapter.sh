#!/usr/bin/env bash
# Tests for `spawn-adapter` (vstack#900).
#
# These replace two >1,500-character prose blocks in orch/SKILL.md that every
# orchestrator had to re-read and re-derive. The assertions below are the
# behaviours that prose was trying to enforce — which is the point of the
# exercise: a rule a tool applies cannot be re-fumbled, and a rule a test pins
# cannot silently drift.
set -uo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="$(cd "$TEST_DIR/.." && pwd)/scripts/spawn-adapter"
SKILL="$(cd "$TEST_DIR/.." && pwd)/SKILL.md"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then pass "$name"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"; fi
}
assert_contains() {
  local hay="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$hay"; then pass "$name"
  else FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        wanted: %s\n        in: %s\n' "$name" "$needle" "$hay"; fi
}

echo "=== spawn: task_name translation (vstack#751) ==="

OUT="$("$ADAPTER" spawn reviewer-arch)"
assert_eq "$(jq -r '.spawn.task_name' <<<"$OUT")" "reviewer_arch" \
  "hyphens become underscores in the runtime task_name"
assert_eq "$(jq -r '.spawn.agent_type' <<<"$OUT")" "reviewer-arch" \
  "agent_type keeps the canonical hyphenated name"
assert_eq "$(jq -r '.spawn.fork_context' <<<"$OUT")" "false" \
  "fork_context is false"

# The identity rule: everything orch RECORDS keys on the canonical name. This is
# the mistake the prose kept having to re-teach — state keyed on the runtime
# spelling.
assert_eq "$(jq -r '.record.identity_key' <<<"$OUT")" "reviewer-arch" \
  "the record identity key is the canonical name, never the runtime one"
assert_eq "$(jq -r '.record.runtime_metadata.task_name' <<<"$OUT")" "reviewer_arch" \
  "the runtime spelling is confined to runtime_metadata"
assert_eq "$(jq -r '.canonical' <<<"$OUT")" "reviewer-arch" "canonical is echoed for the caller"

# A name that is already translated means the caller is about to key state on
# the runtime spelling — refuse rather than silently accept it.
err="$("$ADAPTER" spawn reviewer_arch 2>&1)"; rc=$?
assert_eq "$rc" "2" "an already-translated name is rejected"
assert_contains "$err" "canonical hyphenated agent name" "the refusal says what to pass instead"

"$ADAPTER" spawn "bad name!" >/dev/null 2>&1
assert_eq "$?" "2" "an invalid agent name is rejected"
"$ADAPTER" spawn >/dev/null 2>&1
assert_eq "$?" "2" "spawn requires an agent name"

echo "=== spawn: worker fallback ==="

# Translation is NOT a fallback: a task_name schema rejection is a naming
# mismatch, not a missing agent type. The fallback is a separate, explicit,
# reason-carrying decision.
OUT="$("$ADAPTER" spawn reviewer-safety --fallback-reason "runtime does not expose this agent_type")"
assert_eq "$(jq -r '.spawn.agent_type' <<<"$OUT")" "worker" "an explicit fallback resolves agent_type to worker"
assert_eq "$(jq -r '.fallback' <<<"$OUT")" "true" "the fallback is flagged"
assert_eq "$(jq -r '.record.identity_key' <<<"$OUT")" "reviewer-safety" \
  "a fallback still records the canonical identity, not worker"
assert_eq "$(jq -r '.record.runtime_metadata.agent_type' <<<"$OUT")" "worker" \
  "worker is recorded as runtime metadata"
assert_contains "$(jq -r '.record.runtime_metadata.fallback_reason' <<<"$OUT")" "does not expose" \
  "the fallback reason is recorded"
assert_eq "$(jq -r '.spawn.task_name' <<<"$OUT")" "reviewer_safety" \
  "a fallback still carries the translated task_name"

"$ADAPTER" spawn reviewer-arch --fallback-reason "" >/dev/null 2>&1
assert_eq "$?" "2" "an empty fallback reason is rejected — it is recorded, not decorative"

echo "=== slots: the silently-ignored legacy key (openai/codex#33447, #33039) ==="

cfg() { printf '%s' "$1" > "$TMP_ROOT/c.toml"; "$ADAPTER" slots --config "$TMP_ROOT/c.toml"; }

OUT="$(cfg '[features.multi_agent_v2]
max_concurrent_threads_per_session = 8
')"
assert_eq "$(jq -r '.effective_cap' <<<"$OUT")" "8" "the v2 key sets the effective cap"
assert_eq "$(jq -r '.recommended_reviewer_slot_budget' <<<"$OUT")" "8" \
  "the recommended budget is the cap, which counts the primary session"
assert_eq "$(jq -r '.warning' <<<"$OUT")" "null" "no warning when only the authoritative key is set"

# THE trap: raising only the legacy key changes nothing. Reporting the real cap
# plus why is the whole reason this subcommand exists.
OUT="$(cfg '[agents]
max_threads = 12
')"
assert_eq "$(jq -r '.effective_cap' <<<"$OUT")" "4" \
  "the legacy key alone does NOT raise the cap"
assert_contains "$(jq -r '.warning' <<<"$OUT")" "MultiAgentV2 ignores it" \
  "the warning names the silent-ignore explicitly"
assert_contains "$(jq -r '.warning' <<<"$OUT")" "max_concurrent_threads_per_session" \
  "the warning names the key that would actually work"

OUT="$(cfg '[features.multi_agent_v2]
max_concurrent_threads_per_session = 6
[agents]
max_threads = 12
')"
assert_eq "$(jq -r '.effective_cap' <<<"$OUT")" "6" "the v2 key wins when both are set"
assert_contains "$(jq -r '.warning' <<<"$OUT")" "v2 key wins" "a disagreement is reported"

OUT="$("$ADAPTER" slots --config "$TMP_ROOT/nope.toml")"
assert_eq "$(jq -r '.config_present' <<<"$OUT")" "false" "a missing config is reported as absent"
assert_eq "$(jq -r '.effective_cap' <<<"$OUT")" "4" "a missing config falls back to the runtime default"

# A running session keeps its old cap until restarted — easy to forget after a
# config edit, so the tool always says it.
assert_contains "$(jq -r '.note' <<<"$OUT")" "until restarted" "the restart caveat is always reported"

echo "=== the prose actually collapsed ==="

# The point of the issue was removing hand-executed choreography from SKILL.md,
# not adding a helper beside it. Guard both directions.
assert_contains "$(cat "$SKILL")" "spawn-adapter" "SKILL.md points at the adapter"

# Measure the TWO blocks this issue named, by content, rather than the longest
# blockquote in the file. Other dense blocks exist (the Codex shell
# control-syntax rules, for one) and are a separate audit item — a test that
# conflated them would fail for work this change never claimed to do.
block_len() { grep -o "^> .*$1.*" "$SKILL" | awk '{ print length }' | sort -rn | head -1; }
spawn_len=$(block_len "spawn-adapter spawn")
slots_len=$(block_len "spawn-adapter slots")
for probe in "task_name/worker-fallback:$spawn_len" "thread-cap:$slots_len"; do
  name="${probe%%:*}"; len="${probe#*:}"
  if [[ -n "$len" && "$len" -lt 1200 ]]; then
    pass "the $name block is collapsed to intent ($len chars, was >1150)"
  else
    fail "the $name block is collapsed to intent (got: ${len:-not found})"
  fi
done
if grep -q 'reviewer-arch. → .task_name=reviewer_arch' "$SKILL"; then
  fail "the hand-translation example is gone from SKILL.md"
else
  pass "the hand-translation example is gone from SKILL.md"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
