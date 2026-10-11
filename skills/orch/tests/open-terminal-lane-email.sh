#!/usr/bin/env bash
# Lane launch suppresses the operator email in the child process, including
# addresses in project files. Exercise the built local and hosted commands.
# Inputs: skills/linear/scripts/*
set -uo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-lane-email: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-lane-email: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-lane-email: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
source "$(dirname "${BASH_SOURCE[0]}")/lib/open-terminal-lane-world.sh"

# macOS's orch shard runs Bash 3.2; Linear's own runtime requires Bash 4.
LINEAR_SUPPORTED=true
[[ "${BASH_VERSINFO[0]}" -ge 4 ]] || LINEAR_SUPPORTED=false

SANDBOX="$TMP_ROOT/lane"
mkdir -p "$SANDBOX/.agents/skills/linear" "$SANDBOX/.agents/skills/orch" "$SANDBOX/bin"
cp -R "$TEST_DIR/../../linear/scripts" "$SANDBOX/.agents/skills/linear/"
ln -s "$SCRIPTS_DIR" "$SANDBOX/.agents/skills/orch/scripts"
orch_fixture_shared_libs "$SANDBOX/.agents/skills/orch"
git -C "$SANDBOX" init -q
git -C "$SANDBOX" config gc.auto 0
git -C "$SANDBOX" config maintenance.auto false
printf '%s\n' '[env]' 'KENDEX_USER_EMAIL = "settings@example.com"' > "$SANDBOX/kendex.settings.toml"
printf '%s\n' 'KENDEX_USER_EMAIL=owner@example.com' > "$SANDBOX/.env.local"

cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
config="$(cat)"
payload="$(sed -n 's/^data = //p' <<<"$config" | jq -r)"
query="$(jq -r '.query' <<<"$payload")"
printf '%s\n' "$payload" >> "$EMAIL_PAYLOAD_LOG"
case "$query" in
  *'teams(filter:'*) reply='{"teams":{"nodes":[{"id":"team-id","key":"CC","name":"Test"}],"pageInfo":{"hasNextPage":false}}}' ;;
  *'workflowStates(filter:'*) reply='{"workflowStates":{"nodes":[{"id":"state-in-progress"}],"pageInfo":{"hasNextPage":false}}}' ;;
  *'issue(id:'*) reply='{"issue":{"id":"issue-id","identifier":"CC-760","assignee":null,"team":{"id":"team-id","key":"CC","name":"Test"},"labels":{"nodes":[],"pageInfo":{"hasNextPage":false}}}}' ;;
  *'users(filter:'*) reply='{"users":{"nodes":[{"id":"11111111-2222-3333-4444-555555555555","name":"Owner","email":"owner@example.com"}],"pageInfo":{"hasNextPage":false}}}' ;;
  *'issueUpdate(id:'*) reply='{"issueUpdate":{"success":true,"issue":{"id":"issue-id","identifier":"CC-760"}}}' ;;
  *) exit 1 ;;
esac
printf '{"data":%s}___HTTP_CODE___200' "$reply"
STUB
cat > "$SANDBOX/probe" <<'PROBE'
#!/usr/bin/env bash
set -euo pipefail
printf '%s' "${KENDEX_USER_EMAIL-}" > "$EMAIL_RUN/inherited"
.agents/skills/orch/scripts/orch-env KENDEX_USER_EMAIL "" > "$EMAIL_RUN/loaded"
[[ "$EMAIL_ACTIVATE" == true ]] || exit 0
exec .agents/skills/linear/scripts/linear.sh issues activate CC-760
PROBE
chmod +x "$SANDBOX/bin/curl" "$SANDBOX/probe"

email_case() { # HOST
  local host="$1" line replay_rc=0 args=()
  [[ "$host" == local ]] || args=(--host "$TEST_DIR/fixtures/lane-host" --lane "$H/.eclaude" --repo o/r)
  run_ot "KENDEX_USER_EMAIL=owner@example.com;cmd=$SANDBOX/probe --model opus --effort high" \
    --harness claude ${args[@]+"${args[@]}"} CC-760
  assert_eq "$RC" 0 "$host launch succeeds"
  if [[ "$host" == local ]]; then
    line="$(sed -n 's/^clear; //p' "$RUN/tmux.log")" || return 1
  else
    line="$(grep -m1 '^exec bash -lc ' "$RUN/tmux.log")" || return 1
    # The host fixture names /srv/lane. Replay its shell command in our
    # sandbox, without a login profile that could alter the fixture PATH.
    line="${line/#exec bash -lc /$BASH -c }"
    line="${line//\/srv\/lane/$SANDBOX}"
  fi
  [[ -n "$line" ]] || return 1
  : > "$RUN/payloads"
  (cd "$SANDBOX" && env -i HOME="$SANDBOX" PATH="$SANDBOX/bin:$PATH" \
    KENDEX_USER_EMAIL=owner@example.com LINEAR_TEAM=CC LINEAR_API_KEY_OVERRIDE=test-token \
    EMAIL_RUN="$RUN" EMAIL_PAYLOAD_LOG="$RUN/payloads" EMAIL_ACTIVATE="$LINEAR_SUPPORTED" \
    "$BASH" -c "$line") > "$RUN/activate.out" 2> "$RUN/activate.err" || replay_rc=$?
  assert_eq "$replay_rc" 0 "$host built command activates the issue" "$RUN/activate.err"
  assert_eq "$(cat "$RUN/inherited")" "" "$host child has no operator email"
  assert_eq "$(cat "$RUN/loaded")" "" "$host private file cannot restore the operator email"
  [[ "$LINEAR_SUPPORTED" == true ]] || { printf '  skip  Linear activation requires Bash 4\n'; return; }
  assert_eq "$(grep -cx 'assignee-skipped cause=unset' "$RUN/activate.err" || true)" 1 \
    "$host activation reports its structured unset outcome"
  assert_eq "$(jq -r '.assignee' "$RUN/activate.out")" skipped "$host activation skips assignment"
  assert_eq "$(jq -s '[.[] | select(.query | contains("issueUpdate")) | .variables.input] | length == 1 and .[0].stateId == "state-in-progress" and (.[0] | has("assigneeId") | not)' "$RUN/payloads")" true \
    "$host activation changes state without an assignee"
}

SHIPPED="$OPEN_TERMINAL"
for host in local hosted; do
  email_case "$host"
done

# Preserve a nonempty address in each real command construction. The same
# assertions must fail after the real Linear CLI assigns the fixture owner.
OPEN_TERMINAL="$(mutant_scripts email-control/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/email-control/orch"
mutate_file "$OPEN_TERMINAL" 'run="export KENDEX_USER_EMAIL='\'''\'' && $run"' \
  'run="export KENDEX_USER_EMAIL='\''owner@example.com'\'' && $run"'
mutate_file "$OPEN_TERMINAL" 'cmd="export KENDEX_USER_EMAIL='\'''\'' && $cmd"' \
  'cmd="export KENDEX_USER_EMAIL='\''owner@example.com'\'' && $cmd"'
for host in local hosted; do
  saved_fail="$FAIL"
  FAIL=0
  email_case "$host" > "$TMP_ROOT/$host-control.log" 2>&1
  control_fail="$FAIL"
  FAIL="$saved_fail"
  if [[ "$LINEAR_SUPPORTED" == true ]]; then
    assert_eq "$(jq -r '.success == true and .assignee == "set"' "$RUN/activate.out")" true \
      "$host control reaches successful owner assignment"
    assert_eq "$(jq -s '[.[] | select(.query | contains("issueUpdate")) | .variables.input.assigneeId] == ["11111111-2222-3333-4444-555555555555"]' "$RUN/payloads")" true \
      "$host control sends the owner assignee"
  else
    assert_eq "$(cat "$RUN/inherited")" owner@example.com "$host control reaches the child with an owner email"
  fi
  [[ "$control_fail" -gt 0 ]] && pass "$host control fails the unchanged email assertions" \
    || fail "$host control must fail the unchanged email assertions"
done
OPEN_TERMINAL="$SHIPPED"

# The overseer resolves owner asks in its own process, outside either command.
owner_email="$(cd "$SANDBOX" && env -i HOME="$SANDBOX" PATH="$PATH" \
  KENDEX_USER_EMAIL=owner@example.com ORCH_OWNER_EMAIL= \
  ORCH_OWNER_ASK_LABEL=owner-gated LINEAR_TEAM=CC \
  "$BASH" -c 'source "$1/lib/mailbox-append.sh"; owner_tracker_settings "$1"; printf "%s" "$OWNER_TRACKER_EMAIL"' \
  owner-settings "$SCRIPTS_DIR")" || exit 1
assert_eq "$owner_email" owner@example.com "the overseer still resolves its owner email"

lane_suite_end
