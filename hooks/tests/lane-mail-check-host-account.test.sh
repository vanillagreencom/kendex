#!/usr/bin/env bash
# Hosted Claude account ownership. The existing native launch record identifies
# the host; its unlisted sandbox directory supplies no usage reading. Context
# remains the hook's own mark. Inputs: lane-mail-check, lane-marker and the
# mailbox/context helpers reached through lib/lane-mail-world.sh.
set -euo pipefail
case "$(uname -s)" in MINGW*|MSYS*) export MSYS=winsymlinks:nativestrict ;; esac

# shellcheck source=lib/lane-mail-world.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/lane-mail-world.sh"

# NAME|LAUNCH RECORD|TOKENS|STATUS|KEY
HOST_ACCOUNT_ROWS='hosted|native|1000|0|account=host-measured
context|native|600000|2|context=600000
unlisted|none|1000|0|account=unlisted
local-record|model|1000|0|account=unlisted'
host_account_rows() { # HOOK
  local name launch tokens status key record
  while IFS='|' read -r name launch tokens status key; do
    new_lane "${name}_${1##*/}" ken-4296
    install_hook "$1" "$LANE/.claude/hooks/lane-mail-check.sh"
    record='{}'
    case "$launch" in
      native) record=$(jq -nc --arg f "$LANE/.git/lane-host-pid" '{identity_file:$f}') ;;
      model) record='{"model":"claude-opus-5-5"}' ;;
    esac
    if [ "$launch" = none ]; then
      "$REPO_ROOT/skills/orch/scripts/lane-marker" "$LANE" KEN-4296
    else
      "$REPO_ROOT/skills/orch/scripts/lane-marker" --launch-record "$record" "$LANE" KEN-4296
    fi
    (cd "$LANE" && "$REPO_ROOT/skills/orch/scripts/workflow-state" init KEN-4296 >/dev/null)
    REPORT_ITEM=KEN-4296
    write_transcript "$TMP_ROOT/transcript.jsonl" "$tokens"
    stop_at "$TMP_ROOT/transcript.jsonl" false "CLAUDE_CONFIG_DIR=$OFFLINE_HOME/.claude"
    expect "$status" "lane-mail-check: $key" "$name selects its account owner and context mark"
    if [ "$key" = account=host-measured ]; then
      assert_eq "$(grep -c '^lane-mail-check: account=unlisted$' "$ERR_FILE" || true)" 0 \
        "a hosted account is never reported as unlisted"
    fi
    if [ "$status" = 2 ]; then
      assert_eq "$(grep -cF ' set KEN-4296 handoff ' "$ERR_FILE" || true)" 1 \
        "the hosted context mark still requires a handoff record"
    fi
  done <<< "$HOST_ACCOUNT_ROWS"
}

host_account_rows "$HOOK"
[ "$FAIL" -eq 0 ] || exit 1

# Keep the hosted classification and its output in the copy, but disable its
# return. The same fixtures must reject the resulting local account lookup.
wake_mutant host-account-unreturned \
  '        0) message account host-measured; return 0 ;;' \
  '        0) : ;; # message account host-measured; return 0'
control_status=0
(
  FAIL=0
  host_account_rows "$MUTANT_PATH"
  [ "$FAIL" -eq 0 ]
) > "$TMP_ROOT/host-account.control.log" || control_status=$?
assert_eq "$control_status" 1 "control: the hosted rows reject a sandbox account lookup"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
