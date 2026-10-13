#!/usr/bin/env bash
# Tests for the hosted cap launch contract.
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


echo "=== a Daytona launch and a cloud landing still need a fleet slot ==="
fleet_cap_case() { # CASE NAME
  local cap_case="$1" CAP_STATE="$TMP_ROOT/fleet-cap-$2" cloud_item=KEN-91 cap_args=()
  "$SCRIPTS_DIR/workflow-state" --state-dir "$CAP_STATE" init oversee >/dev/null
  "$SCRIPTS_DIR/workflow-state" --state-dir "$CAP_STATE" append oversee lanes \
    '{"item":"KEN-90","kind":"ssh","host":"claude-cloud","status":"running","window":"stub:KEN-90"}' >/dev/null
  [[ "$cap_case" != landing ]] || { cloud_item=KEN-3539; cap_args=(--relaunch); }
  "$SCRIPTS_DIR/workflow-state" --state-dir "$CAP_STATE" append oversee lanes \
    '{"item":"'"$cloud_item"'","kind":"claude-cloud","host":"daytona","status":"running","window":"stub:'"$cloud_item"'","over_cap":"cloud"}' >/dev/null
  [[ "${3:-}" != over ]] || cap_args+=(--over-cap)
  run_ot "ORCH_OVERSEER_LANES=1;ORCH_OVERSEER_CLOUD_LANES=10;$CHOICE_CMD $COMPACTION_OFF_ALL" \
    --state-dir "$CAP_STATE" --host "$HOST_STUB" --harness claude --lane "$H/.eclaude" --repo o/r \
    ${cap_args[@]+"${cap_args[@]}"} KEN-3539
  if [[ "${3:-}" == over ]]; then
    assert_eq "rc=$RC record=$("$SCRIPTS_DIR/workflow-state" --state-dir "$CAP_STATE" get oversee '[.lanes[] | select(.item == "KEN-3539")] | first | [.kind, .over_cap, .status] | join(":")')" \
      'rc=0 record=ssh:fleet:running' "a landing exception replaces the cloud exception with the cap it passed"
    return
  fi
  assert_eq "rc=$RC calls=$(host_call) setting=$(awk '$2 == "cap-reached" {for(i=3;i<=NF;i++) if($i ~ /^setting=/) print substr($i,9)}' <<<"$OUT")" \
    "rc=1 calls=accounts setting=ORCH_OVERSEER_LANES" \
    "a $cap_case Daytona launch is refused at the full fleet cap with cloud records present"
}
for cap_case in fresh landing; do
  fleet_cap_case "$cap_case" "$cap_case"
done
CAP_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-cloud-landing-cap/orch lib/lane-cap.sh)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-cloud-landing-cap/orch"
mutate_file "${OPEN_TERMINAL%/*}/lib/lane-cap.sh" \
  'elif ($own | in_flight and same_cap) then "held"' 'elif ($own | in_flight) then "held"'
SAVED_FAIL="$FAIL"
FAIL=0
fleet_cap_case landing control > "$TMP_ROOT/cloud-landing-cap-control.out"
LANDING_CONTROL="$FAIL"
FAIL="$SAVED_FAIL"
assert_eq "$LANDING_CONTROL" 1 "control: reusing a cloud slot for a Daytona landing turns the fleet refusal row red"
OPEN_TERMINAL="$CAP_SHIPPED"
fleet_cap_case landing exception over
OPEN_TERMINAL="$(mutant_scripts ctl-cloud-landing-exception/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-cloud-landing-exception/orch"
mutate_file "$OPEN_TERMINAL" \
  'if $rec.over_cap == null then . else . + {over_cap: $rec.over_cap} end' \
  'if $rec.over_cap == null then . else . end'
SAVED_FAIL="$FAIL"
FAIL=0
fleet_cap_case landing exception-control over > "$TMP_ROOT/cloud-landing-exception-control.out"
LANDING_CONTROL="$FAIL"
FAIL="$SAVED_FAIL"
assert_eq "$LANDING_CONTROL" 1 "control: keeping the earlier cloud exception turns the landing cap assertion red"
OPEN_TERMINAL="$CAP_SHIPPED"


# The overseer instruction selects the host. This exception row measures
# the fleet's declared capability and the launch it admits, not the instruction.
CLOUD_CAPABILITIES="$(env ORCH_LANE_HOST=claude-cloud "$SCRIPTS_DIR/lane-host" capabilities)" || exit 1
CLOUD_LAND="$(printf '%s\n' "$CLOUD_CAPABILITIES" | tr '\t' '\n' | sed -n 's/^land=//p')"
assert_eq "$CLOUD_LAND" handoff "only a fleet that declares handoff admits the local landing exception"
printf '/orch merge-pr 4296\n' > "$TMP_ROOT/cloud-only-landing-brief"
run_ot "ORCH_LANE_HOST=claude-cloud;ORCH_LANE_ALIASES=eclaude=work;cmd=true --model opus --effort high {brief}" --host local --harness claude --lane "$H/.eclaude" --repo o/r --relaunch --brief-file "$TMP_ROOT/cloud-only-landing-brief" KEN-3276
assert_eq "$(observe 'rc=0 creates=1 launched=1') calls=$(host_call)" \
  "rc=0 creates=1 launched=1 calls=nolog" \
  "a cloud-only fleet admits the explicit local landing command" "$OUT"
CLOUD_OWNER="$(mutant_scripts ctl-cloud-landing-capability/orch lane-host)/lane-host" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-cloud-landing-capability/orch"
mutate_file "$CLOUD_OWNER" '\tpool=cloud-credit\tland=handoff' '\tpool=cloud-credit\tland=lane'
CLOUD_CAPABILITIES="$(env ORCH_LANE_HOST=claude-cloud "$CLOUD_OWNER" capabilities)" || exit 1
CLOUD_LAND="$(printf '%s\n' "$CLOUD_CAPABILITIES" | tr '\t' '\n' | sed -n 's/^land=//p')"
CLOUD_CONTROL="$(FAIL=0; assert_eq "$CLOUD_LAND" handoff 'local landing exception' > "$TMP_ROOT/cloud-landing-control"; printf '%s' "$FAIL")"
assert_eq "$CLOUD_CONTROL" 1 "control: a fleet that declares lane fails the local landing exception assertion"

# A cloud session pushes its branch without making a fleet sandbox. The
# provider models that first landing sandbox with a real origin-only branch;
# only the relaunch authority permits it to adopt the pushed work.
LANDING_ORIGIN="$TMP_ROOT/landing-origin"
git init -q --bare "$LANDING_ORIGIN" || exit 1
git -C "$LANDING_ORIGIN" config gc.auto 0 || exit 1
git -C "$LANDING_ORIGIN" config maintenance.auto false || exit 1
git init -q "$TMP_ROOT/cloud-source" || exit 1
git -C "$TMP_ROOT/cloud-source" config gc.auto 0 || exit 1
git -C "$TMP_ROOT/cloud-source" config maintenance.auto false || exit 1
git -C "$TMP_ROOT/cloud-source" -c user.name=fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m base || exit 1
git -C "$TMP_ROOT/cloud-source" branch -M main || exit 1
git -C "$TMP_ROOT/cloud-source" remote add origin "$LANDING_ORIGIN" || exit 1
git -C "$TMP_ROOT/cloud-source" push -q origin main || exit 1
git -C "$TMP_ROOT/cloud-source" checkout -q -b ken-3276 || exit 1
git -C "$TMP_ROOT/cloud-source" -c user.name=fixture -c user.email=fixture@example.invalid commit -q --allow-empty -m cloud-work || exit 1
git -C "$TMP_ROOT/cloud-source" push -q origin ken-3276 || exit 1
LANDING_HEAD="$(git -C "$TMP_ROOT/cloud-source" rev-parse HEAD)" || exit 1
LANDING_PROVIDER="$TMP_ROOT/landing-provider"
cat > "$LANDING_PROVIDER" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
if [[ "$1" == create ]]; then
  clone="$LANE_HOST_STUB_DIR/landing-clone"
  tree="$LANE_HOST_STUB_DIR/landing-tree"
  [[ ! -e "$clone" && ! -e "$tree" ]] || exit 1
  git clone -q --single-branch --branch main "$LANDING_ORIGIN" "$clone"
  git -C "$clone" config gc.auto 0
  git -C "$clone" config maintenance.auto false
  local_rc=0
  git -C "$clone" show-ref --verify --quiet refs/heads/ken-3276 || local_rc=$?
  [[ "$local_rc" -eq 1 ]] || exit 1
  remote="$(git -C "$clone" ls-remote --heads origin refs/heads/ken-3276)"
  [[ -n "$remote" ]] || exit 1
  [[ " $* " == *' --relaunch '* ]] || exit 75
  git -C "$clone" fetch -q origin refs/heads/ken-3276:refs/remotes/origin/ken-3276
  git -C "$clone" worktree add -q -b ken-3276 "$tree" origin/ken-3276
fi
exec "$LANDING_STUB" "$@"
STUB
chmod +x "$LANDING_PROVIDER" || exit 1
printf '/orch merge-pr 4296\n' > "$TMP_ROOT/landing-brief"
LANDING_ENV="ORCH_LANE_ALIASES=eclaude=work;LANDING_ORIGIN=$LANDING_ORIGIN;LANDING_STUB=$HOST_STUB;cmd=true --model opus --effort high {brief}"
run_ot "$LANDING_ENV" --host "$LANDING_PROVIDER" --harness claude --lane "$H/.eclaude" --repo o/r --relaunch --brief-file "$TMP_ROOT/landing-brief" KEN-3276
assert_eq "$(observe 'rc=0 creates=nolog launched=1')" "rc=0 creates=nolog launched=1" \
  "a hosted landing relaunch admits an origin-only branch without an earlier sandbox"
LANDING_BRANCH="$(git -C "$RUN/remote/landing-tree" branch --show-current)" || exit 1
LANDED_HEAD="$(git -C "$RUN/remote/landing-tree" rev-parse HEAD)" || exit 1
assert_eq "$LANDING_BRANCH $LANDED_HEAD" "ken-3276 $LANDING_HEAD" \
  "the hosted provider adopts the cloud session's pushed branch and head"
assert_contains "$(host_call)" 'create,--item,KEN-3276,--repo,o/r,--harness,claude,--account,eclaude,--relaunch' \
  "the landing provider receives the relaunch authority for the same item"
LANDING_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-landing-authority/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-landing-authority/orch"
mutate_file "$OPEN_TERMINAL" '[[ "$RELAUNCH" != true ]] || host_args+=(--relaunch)' '[[ "$RELAUNCH" != true ]] || :'
run_ot "$LANDING_ENV" --host "$LANDING_PROVIDER" --harness claude --lane "$H/.eclaude" --repo o/r --relaunch --brief-file "$TMP_ROOT/landing-brief" KEN-3276
assert_eq "$(observe 'rc=75 creates=nolog launched=nolog') tree=$([[ -e "$RUN/remote/landing-tree" ]] && echo present || echo absent)" \
  "rc=75 creates=nolog launched=nolog tree=absent" \
  "control: removing hosted relaunch authority refuses the origin-only landing before a window opens"
OPEN_TERMINAL="$LANDING_SHIPPED"

run_ot "ORCH_LANE_HOST=$HOST_STUB;ORCH_LANE_ALIASES=eclaude=work;$CHOICE_CMD" --harness claude --lane "$H/.eclaude" --repo o/r --lane-refresh KEN-40
assert_eq "rc=$RC refresh=$(hosted_refresh)" "rc=0 refresh=[/srv/lane]" "a hosted --lane-refresh launch puts the lane's root in the refresh record"

lane_suite_end
