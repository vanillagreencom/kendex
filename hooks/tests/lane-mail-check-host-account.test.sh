#!/usr/bin/env bash
# Hosted Claude and Pi account ownership. The existing native launch record
# identifies the host; its unlisted sandbox directory supplies no usage reading.
# Context remains the hook's own mark. Inputs: lane-mail-check, lane-marker,
# lanes and the mailbox/context helpers reached through lib/lane-mail-world.sh.
set -euo pipefail
case "$(uname -s)" in MINGW*|MSYS*) export MSYS=winsymlinks:nativestrict ;; esac

# shellcheck source=lib/lane-mail-world.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lane-mail-world.sh"

# The Pi rows run on a Pi root no provider row names, so a sandbox account
# lookup reaches `lanes pick --lane` and is refused there as unmeasured.
UNLISTED_PI_ROOT="$TMP_ROOT/unlisted-pi-root"
mkdir -p "$UNLISTED_PI_ROOT"
printf '%s\n' '{"compaction":{"enabled":false}}' > "$UNLISTED_PI_ROOT/settings.json"

# NAME|HARNESS|LAUNCH RECORD|TOKENS|STATUS|KEY
HOST_ACCOUNT_ROWS='hosted|claude|native|1000|0|account=host-measured
context|claude|native|600000|2|context=600000
unlisted|claude|none|1000|0|account=unlisted
local-record|claude|model|1000|0|account=unlisted
hosted-pi|pi|native-model|1000|0|account=host-measured
context-pi|pi|native-model|600000|2|context=600000
local-pi|pi|model|1000|0|account=unmeasured'
host_account_rows() { # HOOK [ROWS]
  local name harness launch tokens status key record
  while IFS='|' read -r name harness launch tokens status key; do
    new_lane "${name}_${1##*/}" ken-4296
    record='{}'
    case "$launch" in
      native) record=$(jq -nc --arg f "$LANE/.git/lane-host-pid" '{identity_file:$f}') ;;
      # The record a hosted Daytona Pi lane's create writes (FLT-1391).
      native-model)
        record=$(jq -nc --arg f "$LANE/.git/lane-host-pid" '{identity_file:$f,model:"anthropic/claude-opus-5-5"}')
        ;;
      model) record='{"model":"claude-opus-5-5"}' ;;
    esac
    if [ "$launch" = none ]; then
      "$REPO_ROOT/skills/orch/scripts/lane-marker" "$LANE" KEN-4296
    else
      "$REPO_ROOT/skills/orch/scripts/lane-marker" --launch-record "$record" "$LANE" KEN-4296
    fi
    (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init KEN-4296 >/dev/null)
    REPORT_ITEM=KEN-4296
    case "$harness" in
      claude)
        install_hook "$1" "$LANE/.claude/hooks/lane-mail-check.sh"
        write_transcript "$TMP_ROOT/transcript.jsonl" "$tokens"
        stop_at "$TMP_ROOT/transcript.jsonl" false "CLAUDE_CONFIG_DIR=$OFFLINE_HOME/.claude"
        ;;
      pi)
        install_hook "$1" "$LANE/.pi/kendex/hooks/lane-mail-check.sh"
        usage_line pi "$tokens" |
          jq -c '.message.provider = "anthropic" | .message.model = "claude-opus-5-5"' > "$TMP_ROOT/transcript.jsonl"
        run_payload "$(jq -nc --arg p "$TMP_ROOT/transcript.jsonl" \
          '{session_id:"s1",stop_hook_active:false,transcript_path:$p,context_window:1000000}')" \
          "PI_CODING_AGENT_DIR=$UNLISTED_PI_ROOT"
        ;;
    esac
    expect "$status" "lane-mail-check: $key" "$name selects its account owner and context mark"
    if [ "$key" = account=host-measured ]; then
      assert_eq "$(grep -cE '^lane-mail-check: account=(unlisted|unmeasured)$|cloud-credit-refused' "$ERR_FILE" || true)" 0 \
        "a hosted account is never reported as unlisted or unmeasured, nor looked up in the sandbox"
    fi
    if [ "$name" = local-pi ]; then
      assert_eq "$(grep -c '^lanes: cloud-credit-refused .*cause=api-credit' "$ERR_FILE" || true)" 1 \
        "a Pi lane with no native identity is judged by lanes pick --lane"
    fi
    if [ "$status" = 2 ]; then
      assert_eq "$(grep -cF ' set KEN-4296 handoff ' "$ERR_FILE" || true)" 1 \
        "the hosted context mark still requires a handoff record"
    fi
  done <<< "${2:-$HOST_ACCOUNT_ROWS}"
}

host_account_rows "$HOOK"
[ "$FAIL" -eq 0 ] || exit 1

# Keep the hosted classification and its output in the copy, but disable its
# return. The same fixtures must reject the resulting local account lookup.
wake_mutant host-account-unreturned \
  '        0) message account host-measured; return 0 ;;' \
  '        0) : ;; # message account host-measured; return 0'
row=$(grep -m 1 '^hosted' <<< "$HOST_ACCOUNT_ROWS")
control_status=0
(
  FAIL=0
  host_account_rows "$MUTANT_PATH" "$row"
  [ "$FAIL" -eq 0 ]
) > "$TMP_ROOT/host-account.control.log" || control_status=$?
assert_eq "$control_status" 1 "control: the ${row%%|*} row rejects a sandbox account lookup"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
