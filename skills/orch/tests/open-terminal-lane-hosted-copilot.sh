#!/usr/bin/env bash
# Tests for the hosted copilot launch contract.
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# Physical: on macOS the temp root sits under /var -> /private/var, and the
# scripts print the resolved path.
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-lane-hosted: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-lane-hosted: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-lane-hosted: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
# shellcheck source=lib/open-terminal-hosted-world.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/open-terminal-hosted-world.sh"


# A hosted copilot launch: the account holds its login and a pool with room,
# the provider is handed --harness copilot, and the remote line runs copilot
# under the launch policy lib/lane-launch.sh's lane_copilot_env prints, the
# skills tree named by the host's own $HOME, with no local COPILOT_HOME: the
# provider's prefix sets that.
mkdir -p "$H/.1copilot"
printf '{"copilot_tokens":"gho_fixture"}\n' > "$H/.1copilot/config.json"
printf '%s\n' '{"quota_snapshots":{"premium_interactions":{"entitlement":1000,"remaining":900}}}' > "$FIXTURE_DIR/.1copilot.json"
COPILOT_HOSTED="flags=--model claude-opus-5 --reasoning-effort high --allow-all"
run_ot "$COPILOT_HOSTED" --host "$HOST_STUB" --harness copilot --lane "$H/.1copilot" --repo o/r KEN-1935
COPILOT_REMOTE="exec bash -lc 'cd /srv/lane && export KENDEX_LANE_ORIGIN=${Q}/srv/lane$Q && $SCRUB_UNSET export KENDEX_USER_EMAIL=$Q$Q && exec env -u COPILOT_GITHUB_TOKEN COPILOT_SKILLS_DIRS=\"\$HOME/.agents/skills\" COPILOT_ALLOW_ALL=true copilot $Q--autopilot$Q"
assert_eq "$(observe "rc=0 launched=1") create=$(host_call | tr ';' '\n' | grep -c '^create,--item,KEN-1935,--repo,o/r,--harness,copilot,--account,1copilot$') remote=$(typed "$COPILOT_REMOTE") local=$(typed COPILOT_HOME=)" \
  "rc=0 launched=1 create=1 remote=1 local=0" \
  "a hosted copilot launch creates with --harness copilot and runs copilot under the launch policy, the provider setting COPILOT_HOME"
# The provider can hold a Copilot login while its usage query returns 403.
# The admitted relaunch must still charge the monthly pool once readings return.
COPILOT_CLAIM_ROWS="$TMP_ROOT/copilot-claim-rows.tsv"
copilot_claim_case() { # READING ROUTE [HOST_POOL]
  local reading="$1" route="$2" account="$H/.1copilot" pick_rc=0 picked launch_rc pool capabilities
  local route_args=()
  capabilities="$(printf 'kind=ssh\tlaunch=ssh\tchannel=mailbox\tfiles=verb\tstatus=verb\tstop=verb\trelaunch=resume\tpark=none\taccounts=none\tpool=%s\tland=lane' "${3:-plan}")"
  [[ "$route" != relaunch ]] || route_args=(--relaunch)
  case "$reading" in
    room) printf 'account=%s\tharness=copilot\tmonthly-pct=40\n' "$account" > "$COPILOT_CLAIM_ROWS" ;;
    refused) printf 'account=%s\tharness=copilot\tstatus=refused\tdetail=http-403-permission_error\n' "$account" > "$COPILOT_CLAIM_ROWS" ;;
    absent)
      account="$TMP_ROOT/named-copilot"
      mkdir -p "$account"
      printf '{"copilot_tokens":"fixture-token"}\n' > "$account/config.json"
      : > "$COPILOT_CLAIM_ROWS"
      ;;
  esac
  run_ot "cwd=$NOSETTINGS;LANE_HOST_STUB_CAPABILITIES=$capabilities;LANE_HOST_STUB_ACCOUNTS=$COPILOT_CLAIM_ROWS;$COPILOT_HOSTED" \
    --host "$HOST_STUB" --harness copilot --lane "$account" --repo o/r ${route_args[@]+"${route_args[@]}"} KEN-3747
  launch_rc="$RC"
  pool="$(awk -F'\t' '{print $9}' "$RUN"/state/claims/*.claim 2>/dev/null)"
  printf 'account=%s\tharness=copilot\tmonthly-pct=94\n' "$account" > "$COPILOT_CLAIM_ROWS"
  picked="$(cd "$NOSETTINGS" && env GIT_CEILING_DIRECTORIES="$TMP_ROOT" LANES_HOME="$H" \
    ORCH_LANE_HOST="$HOST_STUB" LANE_HOST_STUB_ACCOUNTS="$COPILOT_CLAIM_ROWS" \
    LANE_HOST_STUB_CAPABILITIES="$capabilities" \
    LANE_HOST_STUB_LOG="$RUN/host.log" OVERSEE_WATCH_STATE_DIR="$RUN/state" \
    OT_TMUX_SERVER_PID="$$" OT_TMUX_PANES="$RUN/panes" OT_TMUX_LOG="$RUN/tmux.log" \
    PATH="$OT_STUB_BIN:$PATH" "$SCRIPTS_DIR/lanes" pick --lane "$account" --harness copilot --model claude-opus-5 --projected --json --no-cache)" || pick_rc=$?
  assert_eq "launch=$launch_rc pool=$pool pick=$pick_rc charged=$(jq -c '[.claims, .pool, (.projected_headroom_pct < 6)]' <<<"$picked")" \
    'launch=0 pool=copilot pick=0 charged=[1,"copilot",true]' \
    "a $route Copilot launch with $reading usage charges its live pane when readings return"
}
while IFS='|' read -r reading route host_pool; do
  copilot_claim_case "$reading" "$route" "$host_pool"
done <<'ROWS'
room|fresh
room|relaunch
refused|relaunch
absent|fresh
absent|fresh|cloud-credit
ROWS
COPILOT_CLAIM_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-copilot-claim-pool/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-copilot-claim-pool/orch"
mutate_file "$OPEN_TERMINAL" \
  'claim_pool="$(lane_pick_pool "$LAUNCH_HARNESS" "$LAUNCH_MODEL" "$claim_pool")"' \
  'claim_pool="$(jq -r '\''.pool // "plan"'\'' <<<"${LANE_PICK_RECORD:-null}")"'
COPILOT_SAVED_FAIL="$FAIL"; FAIL=0
copilot_claim_case refused relaunch > "$TMP_ROOT/copilot-claim-pool-control.out"
COPILOT_CLAIM_CONTROL="$FAIL"; FAIL="$COPILOT_SAVED_FAIL"; OPEN_TERMINAL="$COPILOT_CLAIM_SHIPPED"
assert_eq "$COPILOT_CLAIM_CONTROL" 1 'control: the usage-dependent fallback loses the live Copilot relaunch claim'
COPILOT_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-copilot-host/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-copilot-host/orch"
mutate_file "$OPEN_TERMINAL" '"$HARNESS" =~ ^(claude|codex|pi|copilot)$ ]] || host_launch_ready=false' '"$HARNESS" =~ ^(claude|codex|pi)$ ]] || host_launch_ready=false'
run_ot "$COPILOT_HOSTED" --host "$HOST_STUB" --harness copilot --lane "$H/.1copilot" --repo o/r KEN-1935
assert_eq "$(observe "rc=1 launched=nolog") invalid=$(awk '$2 == "host-invalid" { print $NF }' <<<"$OUT")" "rc=1 launched=nolog invalid=harness=copilot" \
  "control: without copilot in the host protocol's harnesses a hosted copilot launch is host-invalid"
OPEN_TERMINAL="$COPILOT_OT_SHIPPED"
OPEN_TERMINAL="$(mutant_scripts ctl-copilot-policy/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-copilot-policy/orch"
mutate_file "$OPEN_TERMINAL" '[[ "$HARNESS" != copilot ]] || cmd="$(lane_copilot_env' '[[ "$HARNESS" == copilot ]] || cmd="$(lane_copilot_env'
run_ot "$COPILOT_HOSTED" --host "$HOST_STUB" --harness copilot --lane "$H/.1copilot" --repo o/r KEN-1936
assert_eq "$(observe "rc=0 launched=1") policy=$(typed "COPILOT_ALLOW_ALL=true copilot")" "rc=0 launched=1 policy=0" \
  "control: without the hosted policy a hosted copilot lane keeps the COPILOT_GITHUB_TOKEN its host exports"
OPEN_TERMINAL="$COPILOT_OT_SHIPPED"

lane_suite_end
