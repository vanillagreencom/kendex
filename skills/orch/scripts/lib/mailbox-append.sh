# shellcheck shell=bash
# Removed at kendex 2.0, once consumer callers run the mailbox path.
if [ -t 2 ]; then
  printf '%s\n' 'lane-mail: moved=.agents/skills/mailbox/scripts/lane-mail' >&2
fi
# shellcheck source=../../../mailbox/scripts/lib/mailbox-append.sh
. "${BASH_SOURCE[0]%/*}/../../../mailbox/scripts/lib/mailbox-append.sh"
