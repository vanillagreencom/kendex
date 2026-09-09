# shellcheck shell=bash
# The override replaces missing evidence; its publisher and newest state decide.
# name|verdict|context|row context|state|reject|creator|older success|unresolved
while IFS='|' read -r name want context row_context state reject creator older unresolved; do
  reset
  CFG_OUTAGE="$context"; CFG_PUBLISHER_REJECT="$reject"
  [ "$reject" != ACTIVE ] || CFG_PUBLISHER_REJECT="$ACTIVE_PUBLISHER_REJECT"
  status_ctx "$row_context" "$state" 'reviewer outage attested' "$creator"
  if [ "$older" = yes ]; then
    jq '. + [.[0] | .state="success" | .created_at="2026-01-01T00:00:00Z"] | .[0].created_at="2026-01-02T00:00:00Z"' \
      "$fixtures/statuses.json" >"$work/statuses.json" || exit 1
    mv "$work/statuses.json" "$fixtures/statuses.json" || exit 1
  fi
  if [ "$unresolved" = yes ]; then CFG_THREADS=enforce; threads false >"$fixtures/graphql.json"; fi
  run "$name" "$want"
done <<'CASES'
outage attestation counts|approved|mech-outage|mech-outage|success|ACTIVE|trusted-publisher||
pending attestation does not count|awaiting|mech-outage|mech-outage|pending|ACTIVE|trusted-publisher||
newer pending withdraws success|awaiting|mech-outage|mech-outage|pending|ACTIVE|trusted-publisher|yes|
override retains thread term|threads-open|mech-outage|mech-outage|success|ACTIVE|trusted-publisher||yes
empty context disables override|awaiting||kendex-reviewer-outage|success|ACTIVE|trusted-publisher||
rejected override publisher|awaiting|mech-outage|mech-outage|success|github-actions[bot]|github-actions[bot]||
accepted override publisher|approved|mech-outage|mech-outage|success|github-actions[bot]|trusted-orchestrator||
absent override publisher|awaiting|mech-outage|mech-outage|success|github-actions[bot]|||
empty filter accepts Actions override|approved|mech-outage|mech-outage|success||github-actions[bot]||
CASES
