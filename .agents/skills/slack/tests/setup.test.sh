#!/usr/bin/env bash
# `slack setup`: the owners resolved by email, the channel created or found
# by name or adopted by id, the invite, the binding it writes, and the
# refusals a partial configuration, an unknown owner, a public channel, a
# channel the bot is not in, a dead token, a refused invite and a rebind over
# a standing journal get. The controls at the end plant one mutant per rule:
# the owner lookup no longer mapping users_not_found, the public channel
# taken, the invite refusal tolerated, and the rebind rule gone.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack setup ==="

# --- create, bind, invite -----------------------------------------------------
ROOT="$(sk_new_root alpha)"
sk_bind "$ROOT"
assert_eq "$RC" 0 "setup exits 0 on a fresh workspace"
assert_eq "$OUT" "slack: bound=C001 root=$ROOT name=alpha-brad owners=2" "setup prints the binding it wrote"
BINDING="$ROOT/tmp/slack/binding.json"
assert_eq "$(jq -r '[.channel, .channel_name, (.owners | join(",")), .owner_ids["brad@example.test"], .owner_ids["ann@example.test"]] | join(" ")' "$BINDING")" \
  "C001 alpha-brad $OWNERS U001 U002" "the binding holds the channel, the owners list and the ids it resolved"
assert_eq "$(jq -r '.bound_at | tonumber > 1700000000' "$BINDING")" "true" "the binding records its moment as a Slack stamp"
assert_eq "$(sk_state '.channels.C001 | [.name, .is_private, (.members | join(","))] | join(" ")')" \
  "alpha-brad true UBOT,U001,U002" "the channel is private and every owner is invited"

# --- a second setup finds the channel and creates nothing -------------------
sk_bind "$ROOT"
assert_eq "$RC=$(sk_state '[.calls[] | select(. == "conversations.create")] | length')" "0=1" \
  "a second setup finds the channel by name and creates none"

# --- --name and --take ---------------------------------------------------------
BETA="$(sk_new_root beta)"
sk_run -- setup --root "$BETA" --name kendex-brad-local
assert_eq "$RC=$(jq -r .channel_name "$BETA/tmp/slack/binding.json")" "0=kendex-brad-local" "--name names the channel"
sk_ctl /_test/channel '{"id": "C900", "name": "moved-here"}' >/dev/null
sk_run -- setup --root "$BETA" --take C900
assert_eq "$RC=$(jq -r '[.channel, .channel_name] | join(" ")' "$BETA/tmp/slack/binding.json")" "0=C900 moved-here" \
  "--take adopts an existing channel by id"
sk_ctl /_test/channel '{"id": "C901", "name": "not-ours", "members": ["U001"]}' >/dev/null
sk_run -- setup --root "$BETA" --take C901
assert_eq "$RC=$ERR1" "2=slack: slack-channel-unjoined=C901 fix=invite the app to the channel, then run setup again" \
  "a channel the bot is not in is refused with the remedy"
sk_ctl /_test/channel '{"id": "C902", "name": "everyone", "is_private": false}' >/dev/null
sk_run -- setup --root "$BETA" --take C902
assert_eq "$RC=$ERR1=$(sk_channel "$BETA")" "2=slack: slack-channel-public=C902 fix=take a private channel, or run setup without --take=C900" \
  "a public channel is refused with the remedy and the binding stands"
sk_run -- setup --root "$BETA" --name x --take C900
assert_eq "$RC=${ERR1%%=*}" "2=slack: usage" "--name with --take is a usage refusal"

# --- refusals, one row per rule --------------------------------------------------
sk_run SLACK_BOT_TOKEN= SLACK_OWNERS= -- setup --root "$ROOT"
assert_eq "$RC=$(printf '%s\n' "$ERR" | sed -n '1,2p' | tr '\n' ' ')" \
  "2=slack: setting-missing=SLACK_BOT_TOKEN slack: setting-missing=SLACK_OWNERS " \
  "a partial configuration is refused with one keyed line per missing key"
sk_run SLACK_OWNERS= KENDEX_USER_EMAIL="$OWNER2" -- setup --root "$ROOT"
assert_eq "$RC=$(jq -r '.owners | join(",")' "$BINDING")" "0=$OWNER2" "SLACK_OWNERS defaults to KENDEX_USER_EMAIL"
sk_run SLACK_OWNERS="nobody@example.test" -- setup --root "$ROOT"
assert_eq "$RC=$ERR1" "2=slack: slack-owner-unknown=nobody@example.test fix=set SLACK_OWNERS to addresses this workspace knows" \
  "an address the workspace does not know is refused by email"
sk_run SLACK_OWNERS="not-an-email" -- setup --root "$ROOT"
assert_eq "$RC=$ERR1" "2=slack: setting-invalid=SLACK_OWNERS=not-an-email" "an owner that is no email is refused"
sk_run SLACK_POLL_SECONDS=soon -- setup --root "$ROOT"
assert_eq "$RC=$ERR1" "2=slack: setting-invalid=SLACK_POLL_SECONDS=soon" "a poll interval that is no number is refused"
sk_run SLACK_BOT_TOKEN=wrong -- setup --root "$ROOT"
assert_eq "$RC=$ERR1" "2=slack: slack-auth-failed=invalid_auth fix=set a live SLACK_BOT_TOKEN and restart the relay" \
  "a token Slack refuses is slack-auth-failed with its remedy"
sk_run -- setup --root "$SK_TMP/nowhere"
assert_eq "$RC=$ERR1" "2=slack: root-unreadable=$SK_TMP/nowhere" "a root that is no directory is refused"
IOTA="$(sk_new_root iota)"
sk_bind "$IOTA"
IOTA_CH="$(sk_channel "$IOTA")"
sk_poll "$IOTA"
sk_run -- setup --root "$IOTA" --take C900
assert_eq "$RC=$ERR1" "2=slack: channel-changed=$IOTA channel=$IOTA_CH new=C900 fix=stop the relay and move tmp/slack/journal.jsonl aside, then run setup again" \
  "a rebind to another channel while a journal stands is refused with the remedy"
assert_eq "$(sk_channel "$IOTA")" "$IOTA_CH" "the binding keeps its channel"
sk_bind "$IOTA"
assert_eq "$RC=$(sk_channel "$IOTA")" "0=$IOTA_CH" "a setup to the same channel with a journal is allowed"
KAPPA="$(sk_new_root kappa)"
sk_ctl /_test/fault '{"method": "conversations.invite", "error": "cant_invite", "times": 1}' >/dev/null
sk_run -- setup --root "$KAPPA"
assert_eq "$RC=$(printf '%s' "$ERR1" | sed 's/refused=C[0-9]*/refused=CID/')" \
  "2=slack: slack-invite-refused=CID error=cant_invite owners=$OWNERS fix=invite the owners to #kappa-brad in Slack, then run setup again" \
  "an invite Slack refuses is refused with the channel, the owners and the remedy"
assert_eq "$([ -e "$KAPPA/tmp/slack/binding.json" ] && echo present || echo absent)" "absent" "no binding is written after a refused invite"

# --- controls, one mutant per rule ---------------------------------------------
sk_mutant owner relay.py 'err\.error == "users_not_found"' 'err.error == "never_this"'
sk_run SLACK_OWNERS="nobody@example.test" -- setup --root "$ROOT"
assert_eq "${ERR1%%=*}" "slack: slack-api-failed" "control: the mapping removed, the unknown owner is a bare API failure"
sk_bin_reset

sk_mutant public verbs.py 'if not info\.get\("is_private"\):' 'if not info.get("is_private") and False:'
sk_run -- setup --root "$BETA" --take C902
assert_eq "$RC=$(sk_channel "$BETA")" "0=C902" "control: the privacy rule gone, a public channel is bound"
sk_bin_reset

sk_mutant invite verbs.py 'TOLERATED_INVITE = \{"already_in_channel", "cant_invite_self"\}' 'TOLERATED_INVITE = {"already_in_channel", "cant_invite_self", "cant_invite"}'
sk_ctl /_test/fault '{"method": "conversations.invite", "error": "cant_invite", "times": 1}' >/dev/null
sk_run -- setup --root "$KAPPA"
assert_eq "$RC=$([ -e "$KAPPA/tmp/slack/binding.json" ] && echo present || echo absent)" "0=present" \
  "control: the refusal tolerated, setup binds a channel the owners are not in"
sk_bin_reset

sk_mutant rebind verbs.py 'bound_before\.channel != channel:' 'bound_before.channel != channel and False:'
sk_run -- setup --root "$IOTA" --take C900
assert_eq "$RC=$(sk_channel "$IOTA")" "0=C900" "control: the rebind rule gone, a journaled root is bound to another channel"
sk_bin_reset

sk_summary
