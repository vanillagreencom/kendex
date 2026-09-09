# shellcheck shell=bash
# Rejected publishers cannot attest a review. A malformed newest publisher
# masks older evidence while rejection is enabled.
# name|verdict|context|override|reject|creator|older clean row
while IFS='|' read -r name want contexts override reject creator older; do
  reset
  CFG_CONTEXTS="$contexts"; CFG_PUBLISHER_REJECT="$reject"
  [ -z "$override" ] || CFG_OUTAGE="$override"
  ctx="$contexts"; [ -n "$ctx" ] || ctx="$override"
  status_ctx "$ctx" success 'analysis complete' "$creator"
  if [ "$older" = yes ]; then
    jq --arg ctx "$ctx" '[{context:$ctx,state:"success",description:"analysis complete",created_at:"2026-01-02T00:00:00Z",creator:null}] + .' \
      "$fixtures/statuses.json" >"$work/statuses.json" || exit 1
    mv "$work/statuses.json" "$fixtures/statuses.json" || exit 1
  fi
  run "$name" "$want"
done <<'CASES'
publisher filter: rejected creator|awaiting|mech-ctx||github-actions[bot]|github-actions[bot]|
publisher filter: accepted creator|approved|mech-ctx||github-actions[bot]|trusted-status-bot|
publisher filter: absent creator|awaiting|mech-ctx||github-actions[bot]||
newest absent creator masks status|awaiting|mech-ctx||github-actions[bot]|trusted-publisher|yes
newest absent creator masks override|awaiting||mech-outage|github-actions[bot]|operator|yes
empty filter accepts newest absent creator|approved|mech-ctx|||trusted-publisher|yes
empty filter accepts Actions status|approved|mech-ctx|||github-actions[bot]|
CASES
