#!/usr/bin/env bash
# Tests for the hosted accounts launch contract.
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


# WHICH CREDENTIAL A HOSTED LAUNCH RUNS ON. The host runs the copy the provider
# put there, which is independent of this machine's copy only where the provider
# installs a secret of its own; a provider that re-seeds the host from the
# account's config dir at every create runs this machine's copy, on a relaunch as
# much as a fresh launch. So the PROVIDER'S ANSWER decides, never the --relaunch
# flag: the answer comes from `lanes host-accounts`, the one reader of that verb,
# and only `held` skips the usage gate.
#
# xclaude carries an expired access token and no refresh token to renew it with,
# so `lanes` reports it `expired`, the login proven dead, and measures no window.
# A client id is configured for every row on it: without one the renewal fails on
# this machine's own setting, which reads `error` and proves nothing about the
# login. Each row below differs from its neighbour in one thing: what the
# provider answers, and whether the launch is a relaunch.
make_dead_lane "$H" xclaude
printf 'account=%s\tharness=claude\n' "$H/.xclaude" > "$TMP_ROOT/hosted-accounts.tsv"
HOSTED_ACCOUNT="LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts.tsv"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=client-1;$HOSTED_ACCOUNT;$CHOICE_CMD" --host "$HOST_STUB" --harness claude \
  --lane "$H/.xclaude" --repo o/r KEN-77
assert_eq "$(observe "rc=1 launched=nolog credentialdead=lane=$H/.xclaude,host=$HOST_STUB unreadable=none")" \
  "rc=1 launched=nolog credentialdead=lane=$H/.xclaude,host=$HOST_STUB unreadable=none" \
  "a fresh hosted launch on an account this machine cannot renew is refused as host-credential-dead"
run_ot "$HARNESS_UP;ORCH_LANES_CLAUDE_CLIENT_ID=client-1;$HOSTED_ACCOUNT;flags=--model fable --effort high" --host "$HOST_STUB" --harness claude \
  --lane "$H/.xclaude" --repo o/r --relaunch KEN-78
assert_eq "$(observe "rc=0 launched=1 credentialdead=none unreadable=none relaunchgate=1")" \
  "rc=0 launched=1 credentialdead=none unreadable=none relaunchgate=1" \
  "a hosted relaunch on that same dead local copy proceeds, and says which credential runs it"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=client-1;$CHOICE_CMD" --host "$HOST_STUB" --harness claude \
  --lane "$H/.xclaude" --repo o/r KEN-79
assert_eq "$(observe "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows")" \
  "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows" \
  "a provider holding no credential for the account leaves the refusal the unread window it was"
# The relaunch's skip is the provider's answer, not the flag. A provider with no
# accounts verb — the shipped reference lane-host-ssh, which copies this
# machine's account files to the host at every create — answers nothing, so the
# relaunch is judged on the local reading it runs on. Silent: the absent verb is
# no news.
RELAUNCH_FLAGS="$HARNESS_UP;flags=--model fable --effort high"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=client-1;LANE_HOST_STUB_NO_ACCOUNTS=1;$RELAUNCH_FLAGS" --host "$HOST_STUB" \
  --harness claude --lane "$H/.xclaude" --repo o/r --relaunch KEN-100
assert_eq "$(observe "rc=1 launched=nolog relaunchgate=0 unanswered=0 credentialdead=none unreadable=lane=$H/.xclaude,model=fable,step=windows")" \
  "rc=1 launched=nolog relaunchgate=0 unanswered=0 credentialdead=none unreadable=lane=$H/.xclaude,model=fable,step=windows" \
  "a hosted relaunch whose provider implements no accounts verb keeps the usage gate, and says nothing about a verb that is absent"

# WHICH unmeasured account gets the login remedy. The remedy is for a credential
# this machine holds and cannot renew, which `lanes` reports as `expired` and
# nothing else; an account that reads fine and simply has no window for the model
# is the unread window it always was. Its own lane, whose one window names a
# model no other row launches, so a pick asking for another model drops it.
make_lane "$H" vclaude 3600
jq -n '{limits: [{kind: "weekly_scoped", percent: 10, resets_at: "2099-08-01T06:00:00Z",
                  scope: {model: {display_name: "Haiku"}}}]}' > "$FIXTURE_DIR/.vclaude.json"
printf 'account=%s\tharness=claude\n' "$H/.vclaude" > "$TMP_ROOT/hosted-accounts-vclaude.tsv"
run_ot "LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-vclaude.tsv;cmd=true --model sonnet --effort high" \
  --host "$HOST_STUB" --harness claude --lane "$H/.vclaude" --repo o/r KEN-110
assert_eq "$(observe "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.vclaude,model=sonnet,step=windows")" \
  "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.vclaude,model=sonnet,step=windows" \
  "a hosted account the provider holds, unmeasured for this model but not expired, is the unread window and not a login to renew"
# WHICH account the provider's answer is about. An answer naming other accounts
# of this harness is an answer that does not name this one, so the exact
# comparison is what stands between a held account and a neighbour's.
printf 'account=%s\tharness=claude\n' "$H/.eclaude" > "$TMP_ROOT/hosted-accounts-other.tsv"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=client-1;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-other.tsv;$CHOICE_CMD" \
  --host "$HOST_STUB" --harness claude --lane "$H/.xclaude" --repo o/r KEN-111
assert_eq "$(observe "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows")" \
  "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows" \
  "a provider naming other accounts of this harness holds nothing for this one, so the refusal stays the unread window"

# THE WALL BINDS A HOSTED RELAUNCH TOO. A usage window belongs to the account,
# not to the copy of the credential that reads it, so a window measured at the
# threshold here is the window the sandbox meets; resuming would spend the
# sandbox start, the worktree step and the continuation line to open on a usage
# banner. The local twin is KEN-61 above, refused on the same shape, and the
# provider holds this account — which changes the UNMEASURED answer and nothing
# about the wall. Its own lane, so no row that follows reads this window.
make_lane "$H" wclaude 3600
claude_usage 10 20 95 'Fable 5.1' > "$FIXTURE_DIR/.wclaude.json"
printf 'account=%s\tharness=claude\n' "$H/.wclaude" > "$TMP_ROOT/hosted-accounts-walled.tsv"
run_ot "LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-walled.tsv;$RELAUNCH_FLAGS" --host "$HOST_STUB" \
  --harness claude --lane "$H/.wclaude" --repo o/r --relaunch KEN-107
assert_eq "$(observe "rc=1 launched=nolog creates=nolog relaunchgate=0 walled=lane=$H/.wclaude,model=fable,pct=95,bucket=model,projected-headroom=5")" \
  "rc=1 launched=nolog creates=nolog relaunchgate=0 walled=lane=$H/.wclaude,model=fable,pct=95,bucket=model,projected-headroom=5" \
  "a hosted relaunch onto an account the provider holds meets the wall its local twin meets"

# A verb that exists and fails is the other case: the reader prints the
# provider's own bytes under its keyed line, this launcher adds one of its own,
# and the gate still holds, because no answer establishes nothing.
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=client-1;LANE_HOST_STUB_ACCOUNTS_STATUS=7;$RELAUNCH_FLAGS" --host "$HOST_STUB" \
  --harness claude --lane "$H/.xclaude" --repo o/r --relaunch KEN-101
assert_eq "$(observe "rc=1 launched=nolog relaunchgate=0 unanswered=1 unreadable=lane=$H/.xclaude,model=fable,step=windows") provider=$(said 'lane-host-fixture: accounts-failed') reader=$(grep -c "^lanes: host-accounts-unreadable host=$HOST_STUB exit=7\$" <<<"$OUT" || true)" \
  "rc=1 launched=nolog relaunchgate=0 unanswered=1 unreadable=lane=$H/.xclaude,model=fable,step=windows provider=2 reader=2" \
  "a hosted relaunch whose provider fails the accounts verb keeps the gate, and the provider's and reader's lines appear for the judge's read and the arm's, beside the launcher's line"
# The reader's validation reaches this launcher, which does no matching of its
# own. A row `lanes` drops for a percentage nobody can parse holds no account
# here either, so the refusal is the unread window and not a login remedy the
# owner cannot act on.
printf 'account=%s\tharness=claude\tweekly-pct=999\n' "$H/.xclaude" > "$TMP_ROOT/hosted-accounts-bad.tsv"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=client-1;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-bad.tsv;$CHOICE_CMD" \
  --host "$HOST_STUB" --harness claude --lane "$H/.xclaude" --repo o/r KEN-102
assert_eq "$(observe "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows") dropped=$(grep -c "^lanes: host-account-invalid account=$H/.xclaude field=weekly-pct\$" <<<"$OUT" || true)" \
  "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows dropped=2" \
  "an accounts row the reader drops, once for the judge's read and once for the arm's, holds no account for the launcher either"
# The harness is part of the match, and the reader makes it: a row naming this
# account under the other harness is not this launch's account.
printf 'account=%s\tharness=codex\n' "$H/.xclaude" > "$TMP_ROOT/hosted-accounts-codex.tsv"
run_ot "ORCH_LANES_CLAUDE_CLIENT_ID=client-1;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-codex.tsv;$CHOICE_CMD" \
  --host "$HOST_STUB" --harness claude --lane "$H/.xclaude" --repo o/r KEN-103
assert_eq "$(observe "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows")" \
  "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xclaude,model=opus,step=windows" \
  "an accounts row naming this account under another harness holds nothing for this launch"
# host-credential-dead is `expired` and no wider. A codex account whose usage
# read this machine could not make is the unread window, never the login
# remedy; one whose expired token `lanes` cannot renew, here for want of a
# refresh token, so no Codex CLI is started, reads `expired` and takes it.
make_codex_lane "$H/.xcodex"
printf 'account=%s\tharness=codex\n' "$H/.xcodex" > "$TMP_ROOT/hosted-accounts-xcodex.tsv"
run_ot "LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-xcodex.tsv;cmd=true -m gpt-6-astra -c model_reasoning_effort=high" \
  --host "$HOST_STUB" --harness codex --lane "$H/.xcodex" --repo o/r KEN-104
assert_eq "$(observe "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xcodex,model=gpt-6-astra,step=windows")" \
  "rc=1 launched=nolog credentialdead=none unreadable=lane=$H/.xcodex,model=gpt-6-astra,step=windows" \
  "a codex lane this machine cannot measure is the unread window, never the login remedy"
make_codex_token_lane "$H/.ycodex" -60
printf 'account=%s\tharness=codex\n' "$H/.ycodex" > "$TMP_ROOT/hosted-accounts-ycodex.tsv"
run_ot "LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-ycodex.tsv;cmd=true -m gpt-6-astra -c model_reasoning_effort=high" \
  --host "$HOST_STUB" --harness codex --lane "$H/.ycodex" --repo o/r KEN-105
assert_eq "$(observe "rc=1 launched=nolog credentialdead=lane=$H/.ycodex,host=$HOST_STUB unreadable=none")" \
  "rc=1 launched=nolog credentialdead=lane=$H/.ycodex,host=$HOST_STUB unreadable=none" \
  "a codex lane whose expired token cannot be renewed is refused as host-credential-dead"
# A folder whose credential only the provider holds: no local credentials file,
# and a provider row carrying its windows. The judge runs under the host this
# launch resolved, --host here with no ORCH_LANE_HOST, so the account is judged
# on the provider's row and launches.
mkdir -p "$H/.tokclaude"
printf '{}\n' > "$H/.tokclaude/.claude.json"
printf 'account=%s\tharness=claude\tsession-5h-pct=10\tweekly-pct=20\tmodel-pct=5\tmodel-label=Opus\n' \
  "$H/.tokclaude" > "$TMP_ROOT/hosted-accounts-token.tsv"
TOKEN_ROW="LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-token.tsv;$CHOICE_CMD"
run_ot "$TOKEN_ROW" --host "$HOST_STUB" --harness claude --lane "$H/.tokclaude" --repo o/r KEN-120
assert_eq "$(observe "rc=0 launched=1 unreadable=none")" "rc=0 launched=1 unreadable=none" \
  "a --host launch on a token-only folder the provider measures is judged on the provider's row and launches"
# A relaunch onto a host row that measured nothing proceeds on the provider's
# answer that it holds the account. The unmeasured arm asks that fresh, beside
# the judge's own read, so the provider is asked twice.
printf 'account=%s\tharness=claude\tstatus=unreachable\n' "$H/.tokclaude" > "$TMP_ROOT/hosted-accounts-token-dark.tsv"
: > "$TMP_ROOT/hosted-accounts-none.tsv"
TOKEN_STATE="$TMP_ROOT/token-state"
run_ot "OVERSEE_WATCH_STATE_DIR=$TOKEN_STATE;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-token-dark.tsv;$RELAUNCH_FLAGS" --host "$HOST_STUB" \
  --harness claude --lane "$H/.tokclaude" --repo o/r --relaunch KEN-122
assert_eq "$(observe "rc=0 launched=1 relaunchgate=1") accounts=$(grep -c '^accounts' "$RUN/host.log" || true)" \
  "rc=0 launched=1 relaunchgate=1 accounts=2" \
  "a relaunch onto a host row that measured nothing proceeds on the arm's own accounts read"
# The judge's read is served from the answer the run above cached, which still
# names the account after the provider has dropped it. The arm's uncached read
# says it is gone, so the relaunch is refused as the unread window it is. That
# read also refreshes the cache, so the control below warms a state of its own.
run_ot "OVERSEE_WATCH_STATE_DIR=$TOKEN_STATE;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-none.tsv;$RELAUNCH_FLAGS" \
  --host "$HOST_STUB" --harness claude --lane "$H/.tokclaude" --repo o/r --relaunch KEN-123
assert_eq "$(observe "rc=1 launched=0 relaunchgate=0 unreadable=lane=$H/.tokclaude,model=fable,step=windows")" \
  "rc=1 launched=0 relaunchgate=0 unreadable=lane=$H/.tokclaude,model=fable,step=windows" \
  "a relaunch whose cached host row the provider has since dropped is refused on the arm's fresh read"
# Control: an arm that takes the judge's host record as the provider holding
# the account relaunches onto the dropped account.
TOKEN_CTL_STATE="$TMP_ROOT/token-state-ctl"
run_ot "OVERSEE_WATCH_STATE_DIR=$TOKEN_CTL_STATE;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-token-dark.tsv;$RELAUNCH_FLAGS" \
  --host "$HOST_STUB" --harness claude --lane "$H/.tokclaude" --repo o/r --relaunch KEN-124
assert_eq "$RC" "0" "control warm-up: the relaunch caches the provider's row naming the account"
TOKEN_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-held-cached/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-held-cached/orch"
mutate_file "$OPEN_TERMINAL" '[[ "$LANE_HOST" == local || "$LAUNCH_HARNESS" == pi ]] || host_account_read "${LANE_ENV#*=}" "$LAUNCH_HARNESS"' \
  '[[ "$LANE_HOST" == local || "$LAUNCH_HARNESS" == pi ]] || { [[ "$(jq -r .measured_through <<<"$lane_record")" == host ]] && HOST_ACCOUNT=held; } || host_account_read "${LANE_ENV#*=}" "$LAUNCH_HARNESS"'
run_ot "OVERSEE_WATCH_STATE_DIR=$TOKEN_CTL_STATE;LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-none.tsv;$RELAUNCH_FLAGS" \
  --host "$HOST_STUB" --harness claude --lane "$H/.tokclaude" --repo o/r --relaunch KEN-125
assert_eq "$(observe "rc=0 launched=1 relaunchgate=1")" "rc=0 launched=1 relaunchgate=1" \
  "control: an arm trusting the judge's cached host row relaunches onto an account the provider dropped"
OPEN_TERMINAL="$TOKEN_OT_SHIPPED"
# A provider row the provider could not read, for an account this machine
# holds a live copy of and measures fresh: the judge takes this machine's
# reading, says so, and the fresh launch proceeds. The same row for a folder
# nothing measures, and for one whose local figure is past the TTL, leaves the
# unread window and the refusal it always had.
printf 'account=%s\tharness=claude\tstatus=unreachable\n' "$H/.claude" > "$TMP_ROOT/hosted-accounts-claude-dark.tsv"
CLAUDE_DARK="LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-claude-dark.tsv;$CHOICE_CMD"
run_ot "$CLAUDE_DARK" --host "$HOST_STUB" --harness claude --lane "$H/.claude" --repo o/r KEN-126
assert_eq "$(observe "rc=0 launched=1 unreadable=none localreading=1")" "rc=0 launched=1 unreadable=none localreading=1" \
  "a fresh --host launch on an account the provider cannot read is judged on this machine's fresh reading, under its keyed line, and launches"
run_ot "LANE_HOST_STUB_ACCOUNTS=$TMP_ROOT/hosted-accounts-token-dark.tsv;$CHOICE_CMD" --host "$HOST_STUB" --harness claude --lane "$H/.tokclaude" --repo o/r KEN-127
assert_eq "$(observe "rc=1 launched=nolog localreading=0 unreadable=lane=$H/.tokclaude,model=opus,step=windows")" \
  "rc=1 launched=nolog localreading=0 unreadable=lane=$H/.tokclaude,model=opus,step=windows" \
  "the same row for a folder this machine holds no credentials for stays the unread window on a fresh launch"
# The figure the first launch measured is aged past the default TTL and the
# endpoint set to refuse, so the second launch's refresh serves that old figure
# as rate_limited: measured, but not fresh.
DARK_STATE="$TMP_ROOT/claude-dark-state"
run_ot "OVERSEE_WATCH_STATE_DIR=$DARK_STATE;$CLAUDE_DARK" --host "$HOST_STUB" --harness claude --lane "$H/.claude" --repo o/r KEN-128
assert_eq "$RC" "0" "warm-up: the launch under its own state measures the account fresh"
age_usage_record "$DARK_STATE" "$H/.claude" 600
printf '429 0\n' > "$FIXTURE_DIR/.claude.status"
run_ot "OVERSEE_WATCH_STATE_DIR=$DARK_STATE;$CLAUDE_DARK" --host "$HOST_STUB" --harness claude --lane "$H/.claude" --repo o/r KEN-129
assert_eq "$(observe "rc=1 launched=0 localreading=0 unreadable=lane=$H/.claude,model=opus,step=windows")" \
  "rc=1 launched=0 localreading=0 unreadable=lane=$H/.claude,model=opus,step=windows" \
  "a local figure older than the TTL does not stand in for the unreachable row, so the fresh launch is refused"
rm -f -- "${FIXTURE_DIR:?}/.claude.status"
# Control: a judge that does not pass the resolved host reads this machine's
# no_credentials and refuses the unread window.
TOKEN_OT_SHIPPED="$OPEN_TERMINAL"
OPEN_TERMINAL="$(mutant_scripts ctl-judge-host/orch open-terminal)/open-terminal" || exit 1
orch_fixture_shared_libs "$TMP_ROOT/ctl-judge-host/orch"
mutate_file "$OPEN_TERMINAL" 'lane_record="$(ORCH_LANE_HOST="$LANE_HOST" "$LANES_CLI" pick --lane' 'lane_record="$("$LANES_CLI" pick --lane'
run_ot "$TOKEN_ROW" --host "$HOST_STUB" --harness claude --lane "$H/.tokclaude" --repo o/r KEN-121
assert_eq "$(observe "rc=1 launched=nolog unreadable=lane=$H/.tokclaude,model=opus,step=windows")" \
  "rc=1 launched=nolog unreadable=lane=$H/.tokclaude,model=opus,step=windows" \
  "control: a judge run without the resolved host refuses the token-only folder as an unread window"
OPEN_TERMINAL="$TOKEN_OT_SHIPPED"
run_ot "LANE_HOST_STUB_STATUS=75;$CHOICE_CMD" --host "$HOST_STUB" --harness claude --lane auto --repo o/r KEN-42
assert_eq "$(observe "rc= launched=") owned=$(awk '$2 == "item-owned" { print $3 }' <<<"$OUT")" "rc=75 launched=nolog owned=item=KEN-42" \
  "a hosted create exit 75 skips the item as owned by another session"
run_ot "LANE_HOST_STUB_STATUS=1;$CHOICE_CMD" --host "$HOST_STUB" --harness claude --lane auto --repo o/r KEN-43
assert_eq "$(observe "rc= launched= creates=") failed=$(said "open-terminal: host-create-failed item=KEN-43 exit=1")" "rc=1 launched=nolog creates=nolog failed=1" \
  "a hosted create failure is host-create-failed and opens no window"
run_ot "" --host "$HOST_STUB" --lane "$H/.eclaude" --repo o/r --cmd true KEN-44
assert_eq "$(observe "rc= launched= creates=") create=$(host_call) invalid=$(awk '$2 == "host-invalid" { print $NF }' <<<"$OUT")" "rc=1 launched=nolog creates=nolog create=nolog invalid=harness=" \
  "a hosted launch without a host-protocol harness is host-invalid before any create"
run_ot "" --host "$HOST_STUB" --harness claude --wake KEN-45
assert_eq "$(observe "rc=") create=$(host_call) wake=$(awk '$2 == "wake-invalid"' <<<"$OUT" | wc -l | tr -d '[:space:]')" "rc=1 create=nolog wake=1" \
  "a hosted wake is wake-invalid before any create"
run_ot "LANE_HOST_STUB_CREATE_LINE=ssh-target=lane.example"$'\t'"path=/srv/lane;$CHOICE_CMD" --host "$HOST_STUB" --harness claude --lane auto --repo o/r KEN-46
assert_eq "$(observe "rc= launched=") invalid=$(said "open-terminal: host-line-invalid item=KEN-46")" "rc=1 launched=nolog invalid=1" \
  "a create line missing its remote prefix is host-line-invalid and opens no window"
# lane-host create writes the hosted lane's marker on its host. A local one
# would bind the caller's own checkout, which would then pose as a lane.
HOSTCALLER="$TMP_ROOT/hostcaller"; mkdir -p "$HOSTCALLER"; git -C "$HOSTCALLER" init -q; git -C "$HOSTCALLER" config gc.auto 0; git -C "$HOSTCALLER" config maintenance.auto false
run_ot "cwd=$HOSTCALLER;$CHOICE_CMD" --host "$HOST_STUB" --harness claude --lane auto --repo o/r KEN-47
assert_eq "$(observe "rc= launched=") local_marker=$([[ -e "$HOSTCALLER/.git/lane-mail" ]] && echo present || echo absent)" "rc=0 launched=1 local_marker=absent" \
  "a hosted launch writes no lane marker into the caller's own checkout"


lane_suite_end
