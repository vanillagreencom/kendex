#!/usr/bin/env bash
# `slack setup`: the owners resolved by email, the channel created or found
# by name or adopted by id, the invite, the binding it writes, and the
# refusals a partial configuration, an unknown owner, a public channel, a
# channel the bot is not in, a dead token, an app-level token in
# SLACK_BOT_TOKEN, a refused invite and a rebind over a standing journal get.
# The token-type rule's control is socket.test.sh's `token-type`. The controls at the end plant one mutant per rule:
# the owner lookup no longer mapping users_not_found, the public channel
# taken, the invite refusal tolerated, and the rebind rule gone.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack setup ==="
sk_channel_name() { jq -r .channel_name "$1/tmp/slack/binding.json"; } # ROOT
sk_purpose() { sk_state ".channels[\"$(sk_channel "$1")\"].purpose"; }     # ROOT — its channel's purpose
set_purposes() { sk_state '[.calls[] | select(. == "conversations.setPurpose")] | length'; }

# --- create, bind, invite -----------------------------------------------------
ROOT="$(sk_new_root alpha)"
sk_bind "$ROOT"
assert_eq "$RC" 0 "setup exits 0 on a fresh workspace"
assert_eq "$OUT" "slack: bound=C001 root=$ROOT name=bradm-alpha-local owners=2" "setup prints the binding it wrote"
BINDING="$ROOT/tmp/slack/binding.json"
assert_eq "$(jq -r '[.channel, .channel_name, (.owners | join(",")), .owner_ids["brad@example.test"], .owner_ids["ann@example.test"]] | join(" ")' "$BINDING")" \
  "C001 bradm-alpha-local $OWNERS U001 U002" "the binding holds the channel, the owners list and the ids it resolved"
assert_eq "$(jq -r '.bound_at | tonumber > 1700000000' "$BINDING")" "true" "the binding records its moment as a Slack stamp"
assert_eq "$(sk_state '.channels.C001 | [.name, .is_private, (.members | join(","))] | join(" ")')" \
  "bradm-alpha-local true UBOT,U001,U002" "the channel is private and every owner is invited"

assert_eq "$(set_purposes)=$(sk_state '.channels.C001.purpose')" "1=alpha overseer on a local machine." \
  "a create writes the purpose once; with no origin, gh answer or linear cache it is the lead alone"

# --- a second setup finds the channel and creates nothing -------------------
sk_bind "$ROOT"
assert_eq "$RC=$(sk_state '[.calls[] | select(. == "conversations.create")] | length')" "0=1" \
  "a second setup finds the channel by name and creates none"
assert_eq "$(set_purposes)" "1" "a second setup leaves the purpose it wrote"

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
sk_run SLACK_BOT_TOKEN="$SK_APP_TOKEN" -- setup --root "$ROOT"
assert_eq "$RC=$ERR1" "2=slack: slack-auth-failed=not_allowed_token_type fix=set a live SLACK_BOT_TOKEN and restart the relay" \
  "an app-level token in SLACK_BOT_TOKEN is slack-auth-failed, naming the setting"
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
KAPPA="$(sk_new_root kappa)"
sk_ctl /_test/fault '{"method": "conversations.invite", "error": "cant_invite", "times": 1}' >/dev/null
sk_run -- setup --root "$KAPPA"
assert_eq "$RC=$(printf '%s' "$ERR1" | sed 's/refused=C[0-9]*/refused=CID/')" \
  "2=slack: slack-invite-refused=CID error=cant_invite owners=$OWNERS fix=invite the owners to #bradm-kappa-local in Slack, then run setup again" \
  "an invite Slack refuses is refused with the channel, the owners and the remedy"
assert_eq "$([ -e "$KAPPA/tmp/slack/binding.json" ] && echo present || echo absent)" "absent" "no binding is written after a refused invite"

# --- the default name: <person>-<repo>-<side> ------------------------------------
# One row per input: the side from the root's lane host, the repository from
# origin, the person from KENDEX_USER_HANDLE or the email's local part.
MU="$(sk_new_root mu)"
git -C "$MU" remote add origin "https://github.com/acme/Widget.git"
sk_run ORCH_LANE_HOST="$SK_TMP/provider" SLACK_OWNERS="$OWNER2" -- setup --root "$MU"
assert_eq "$RC=$(sk_channel_name "$MU")" "0=bradm-widget-vm" \
  "a provider lane host names the vm side, the repository from origin, the person from the handle over SLACK_OWNERS"
NU="$(sk_new_root nu)"
git -C "$NU" remote add origin "git@github.com:acme/gadget.git"
sk_run -- setup --root "$NU"
assert_eq "$RC=$(sk_channel_name "$NU")" "0=bradm-gadget-local" "a local lane host names the local side"
XI="$SK_TMP/xi"
mkdir -p "$XI" && git -C "$XI" init -q
sk_run ORCH_LANE_HOST=claude-cloud -- setup --root "$XI"
assert_eq "$RC=$(sk_channel_name "$XI")" "0=bradm-xi-local" "a root with no orch skill names local, the checkout name standing in for origin"
OMICRON="$(sk_new_root omicron)"
sk_run KENDEX_USER_HANDLE= KENDEX_USER_EMAIL="$OWNER2" -- setup --root "$OMICRON"
assert_eq "$RC=$(sk_channel_name "$OMICRON")=$(printf '%s\n' "$ERR" | grep -c '^slack: handle-from-email=ann$')" "0=ann-omicron-local=1" \
  "with no handle the email's local part stands in, said once on stderr"
sk_run KENDEX_USER_HANDLE= -- setup --root "$OMICRON"
assert_eq "$RC=$ERR1" "2=slack: setting-missing=KENDEX_USER_EMAIL" "with neither the handle nor the email setup is refused"

# --- the purpose: written once, never over one already set -----------------------
# A gh stub answers the description from GH_DESCRIPTION; the root sets the
# Linear team and holds a cached issue url naming the workspace.
mkdir -p "$SK_TMP/gh-bin"
printf '#!/bin/sh\n[ -n "$GH_DESCRIPTION" ] || exit 1\nprintf "%%s\\n" "$GH_DESCRIPTION"\n' > "$SK_TMP/gh-bin/gh"
chmod +x "$SK_TMP/gh-bin/gh"
PI="$(sk_new_root pi)"
git -C "$PI" remote add origin "https://someone:secret@github.com/acme/widget.git"
printf '[env]\nLINEAR_TEAM_PREFIX = "WID"\n' > "$PI/kendex.settings.toml"
mkdir -p "$PI/.cache/linear"
printf '[{"url": "https://linear.app/acme/issue/WID-1/a-title"}]\n' > "$PI/.cache/linear/issues.json"
sk_run PATH="$SK_TMP/gh-bin:$PATH" GH_DESCRIPTION="Widgets for everyone. Built with care." -- setup --root "$PI"
assert_eq "$RC=$(sk_purpose "$PI")" \
  "0=widget overseer on a local machine. Widgets for everyone. Repo: https://github.com/acme/widget | Board: https://linear.app/acme/team/WID" \
  "the purpose holds the side, the description's first sentence, the origin without credentials and the board"
RHO="$(sk_new_root rho)"
git -C "$RHO" remote add origin "https://github.com/acme/widget.git"
cp -R "$PI/kendex.settings.toml" "$PI/.cache" "$RHO/"
# 160 characters: the line fits with the sentence alone or the board alone, not both.
LONG="$(printf 'w%.0s' $(seq 1 159))."
sk_run PATH="$SK_TMP/gh-bin:$PATH" GH_DESCRIPTION="$LONG" -- setup --root "$RHO" --name rho-long
assert_eq "$RC=$(sk_purpose "$RHO")" \
  "0=widget overseer on a local machine. Repo: https://github.com/acme/widget | Board: https://linear.app/acme/team/WID" \
  "a line over 250 characters drops the description sentence first"
sk_ctl /_test/channel '{"id": "C950", "name": "hand-set", "purpose": "Set by hand."}' >/dev/null
sk_ctl /_test/calls-reset >/dev/null
SIGMA="$(sk_new_root sigma)"
sk_run -- setup --root "$SIGMA" --take C950
assert_eq "$RC=$(set_purposes)=$(sk_purpose "$SIGMA")" "0=0=Set by hand." "a bound channel's purpose already set is never overwritten"
sk_ctl /_test/channel '{"id": "C951", "name": "empty-purpose"}' >/dev/null
TAU="$(sk_new_root tau)"
sk_run -- setup --root "$TAU" --take C951
assert_eq "$RC=$(sk_purpose "$TAU")" "0=tau overseer on a local machine." "a bound channel with an empty purpose gets one"
UPSILON="$(sk_new_root upsilon)"
sk_ctl /_test/fault '{"method": "conversations.setPurpose", "error": "restricted_action", "times": 1}' >/dev/null
sk_run -- setup --root "$UPSILON"
assert_eq "$RC=$(printf '%s\n' "$ERR" | sed -n 's/^slack: purpose-unset=C[0-9]* //p')" "0=error=restricted_action" \
  "a refused setPurpose is a purpose-unset notice and setup still binds"

# --- the private env file alone ------------------------------------------------
# No SLACK_BOT_TOKEN or SLACK_OWNERS in the process environment: run from the
# root, as the installed unit does, so the launcher loads that root's file.
sk_run_private() { # ROOT ARGS...
  local root="$1"
  shift
  RC=0
  OUT="$(cd "$root" && env -i PATH="$PATH" HOME="$SK_TMP/home" LANG=C SLACK_API_URL="$SK_URL" \
    "$SK_BIN" "$@" 2>"$SK_TMP/err")" || RC=$?
  ERR="$(cat "$SK_TMP/err")"
  ERR1="$(sed -n '1p' "$SK_TMP/err")"
}
LAMBDA="$(sk_new_root lambda)"
sk_run_private "$LAMBDA" setup --root "$LAMBDA"
assert_eq "$RC=$(printf '%s\n' "$ERR" | sed -n '1,2p' | tr '\n' ' ')" \
  "2=slack: setting-missing=SLACK_BOT_TOKEN slack: setting-missing=SLACK_OWNERS " \
  "with neither the process environment nor a private env file, setup is refused setting-missing"
printf 'SLACK_BOT_TOKEN=%s\nSLACK_OWNERS=%s\nKENDEX_USER_HANDLE=%s\n' "$SK_TOKEN" "$OWNERS" "$HANDLE" > "$LAMBDA/.env.local"
sk_run_private "$LAMBDA" setup --root "$LAMBDA"
assert_eq "$RC=$(jq -r '.owners | join(",")' "$LAMBDA/tmp/slack/binding.json")" "0=$OWNERS" \
  "the private env file alone carries the token and the owners to the relay"
assert_eq "$(jq -r .channel_name "$LAMBDA/tmp/slack/binding.json")" "bradm-lambda-local" \
  "the private env file carries KENDEX_USER_HANDLE to the default name"

# --- controls, one mutant per rule ---------------------------------------------
sk_copy unexported
if ! python3 - "$SK_BIN" <<'PY'
import sys
path = sys.argv[1]
text = open(path).read()
new = text.replace("set -a\n", "", 1)
if text.count("set -a\n") != 1 or new == text:
    sys.exit(1)
open(path, "w").write(new)
PY
then
  printf 'mutant unexported: pattern did not match exactly once\n' >&2
  exit 1
fi
rm -rf -- "${LAMBDA:?}/tmp/slack"
sk_run_private "$LAMBDA" setup --root "$LAMBDA"
assert_eq "$RC=$ERR1" "2=slack: setting-missing=SLACK_BOT_TOKEN" \
  "control: the load unexported, the private env file's token never reaches the relay"
sk_bin_reset

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

sk_mutant shape verbs.py 'f"\{person\}-\{repo_name\(root\)\}-\{side\}"' 'f"{root.name}-{person}"'
NU2="$(sk_new_root nu2)"
sk_run -- setup --root "$NU2"
assert_eq "$RC=$(sk_channel_name "$NU2")" "0=nu2-bradm" "control: the old <checkout>-<owner> shape fails the name row"
sk_bin_reset

sk_mutant side verbs.py 'return "local" if host == "local" else "vm"' 'return "local"'
MU2="$(sk_new_root mu2)"
sk_run ORCH_LANE_HOST="$SK_TMP/provider" -- setup --root "$MU2"
assert_eq "$RC=$(sk_channel_name "$MU2")" "0=bradm-mu2-local" "control: the side read gone, a hosted fleet's channel is named local"
sk_bin_reset

sk_mutant keep verbs.py 'if not purpose\.get\("value"\):' 'if True:'
sk_run -- setup --root "$SIGMA" --take C950
assert_eq "$RC=$(sk_purpose "$SIGMA")" "0=sigma overseer on a local machine." "control: the empty-purpose rule gone, the hand-set text is overwritten"
sk_bin_reset

sk_mutant drop verbs.py '\(\(True, True\), \(False, True\), \(False, False\)\)' '((True, True), (True, False), (False, False))'
sk_ctl /_test/channel '{"id": "C952", "name": "drop-order"}' >/dev/null
PHI="$(sk_new_root phi)"
cp -R "$PI/kendex.settings.toml" "$PI/.cache" "$PHI/"
git -C "$PHI" remote add origin "https://github.com/acme/widget.git"
sk_run PATH="$SK_TMP/gh-bin:$PATH" GH_DESCRIPTION="$LONG" -- setup --root "$PHI" --take C952
assert_eq "$RC=$(sk_purpose "$PHI")" "0=widget overseer on a local machine. $LONG Repo: https://github.com/acme/widget" \
  "control: the board dropped before the sentence, the description stands and the board goes"
sk_bin_reset

sk_summary
