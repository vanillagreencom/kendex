#!/usr/bin/env bash
# An owner ask carrying a draft, through the real relay and lane-mail: the
# posted ask shows the draft's recipient, medium and whole text between the
# question and its options. An ask with no draft is listen.test.sh's. The
# control drops the draft block from the posted ask.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

sk_fake_start
echo "=== slack draft ask ==="

DRAFT='{"recipient": "release-list@example.com", "medium": "email", "text": "Hello,\n\nThe release ships Friday.", "text_hash": "sha256:0f"}'
WANT='Send this email?

Draft to release-list@example.com by email:

Hello,

The release ships Friday.

Options: approve, deny. Recommended: deny.'

draft_ask() { # NAME — one draft ask posted from a fresh root; prints its posted text
  local root
  root="$(sk_new_root "$1")"
  sk_bind "$root"
  sk_lm "$root" ask --item overseer --to owner --file "$(sk_text "$1" 'Send this email?')" --options approve,deny --recommend deny >/dev/null
  sk_event_filter "$root" "if .kind == \"ask\" then .draft = $DRAFT else . end"
  sk_poll "$root"
  sk_state ".messages.$(sk_channel "$root")[] | select(.text | contains(\"Send this email?\")) | .text"
}

assert_has "$(draft_ask draft)" "$WANT" "a draft ask shows the recipient, medium and whole text before its options"

sk_mutant draft-block relay.py 'if draft:' 'if draft and False:'
CONTROL="$(draft_ask control)"
assert_has "$CONTROL" "Send this email?" "control probe: the ask still posts"
assert_lacks "$CONTROL" "Draft to release-list@example.com by email:" "control: the draft block dropped, the ask shows no draft"
sk_bin_reset

sk_summary
