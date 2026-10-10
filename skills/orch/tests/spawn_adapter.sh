#!/usr/bin/env bash
# Tests for `spawn-adapter`.
#
# These replace two >1,500-character prose blocks in orch/SKILL.md that every
# orchestrator had to re-read and re-derive. The assertions below are the
# behaviours that prose was trying to enforce — which is the point of the
# exercise: a rule a tool applies cannot be re-fumbled, and a rule a test pins
# cannot silently drift.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ADAPTER="$(cd "$TEST_DIR/.." && pwd)/scripts/spawn-adapter"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

echo "=== spawn: task_name translation (kendex#751) ==="

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
assert_eq "${err%%$'\n'*}" "spawn-adapter: translated-name canonical=reviewer_arch" "the refusal identifies the translated name"

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
assert_eq "$(jq -r '.record.runtime_metadata.fallback_reason' <<<"$OUT")" "runtime does not expose this agent_type" \
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
assert_eq "$(jq -r '.warning | split("\n")[0]' <<<"$OUT")" "legacy-ignored value=12 effective=4" \
  "the warning identifies the ignored value and effective cap"

OUT="$(cfg '[features.multi_agent_v2]
max_concurrent_threads_per_session = 6
[agents]
max_threads = 12
')"
assert_eq "$(jq -r '.effective_cap' <<<"$OUT")" "6" "the v2 key wins when both are set"
assert_eq "$(jq -r '.warning | split("\n")[0]' <<<"$OUT")" "legacy-conflict value=12 effective=6" "a disagreement is reported"

OUT="$("$ADAPTER" slots --config "$TMP_ROOT/nope.toml")"
assert_eq "$(jq -r '.config_present' <<<"$OUT")" "false" "a missing config is reported as absent"
assert_eq "$(jq -r '.effective_cap' <<<"$OUT")" "4" "a missing config falls back to the runtime default"

# A running session keeps its old cap until restarted — easy to forget after a
# config edit, so the tool always says it.
assert_eq "$(jq -r '.note | split("\n")[0]' <<<"$OUT")" "restart-required value=true" "the restart caveat is always reported"

echo
rc=0
"$ADAPTER" >/dev/null 2>"$TMP_ROOT/arguments.err" || rc=$?
assert_eq "$rc:$(sed -n '1p' "$TMP_ROOT/arguments.err")" "2:spawn-adapter: missing-subcommand count=0" "missing subcommand identifies the argument count"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
