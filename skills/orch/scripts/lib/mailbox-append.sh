# shellcheck shell=bash
# KEN-3740 removes this compatibility path after consumer callers move.
if [ -t 2 ]; then
  printf '%s\n' 'lane-mail: moved=.agents/skills/mailbox/scripts/lane-mail' >&2
fi
# shellcheck source=../../../mailbox/scripts/lib/mailbox-append.sh
. "${BASH_SOURCE[0]%/*}/../../../mailbox/scripts/lib/mailbox-append.sh"
