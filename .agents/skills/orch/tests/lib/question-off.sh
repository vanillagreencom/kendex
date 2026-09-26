#!/usr/bin/env bash
# The question-tool words of every harness row, for a suite whose --cmd rows
# judge some other gate and must first clear the question-tool one. Read from
# lib/lane-launch.sh, the table open-terminal judges against, so no suite holds
# a second copy of the words. Appended to a `true` template they run nothing:
# each row's harness finds its own run among them, and the rest are inert.
# open-terminal-question-tool.sh is the suite that judges that gate itself.
#
# Sets QUESTION_OFF_ALL, and exits naming the library when it reads nothing.
QUESTION_OFF_ALL="$(bash -c '
  source "$1" || exit 1
  for row in "${LAUNCH_CHOICE_FLAGS[@]}"; do launch_choice_question_off "${row%%|*}"; done
' _ "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib" && pwd)/lane-launch.sh" | tr '\n' ' ')"
QUESTION_OFF_ALL="${QUESTION_OFF_ALL% }"
[[ -n "$QUESTION_OFF_ALL" ]] || { echo "question-off.sh: lib/lane-launch.sh named no question-tool words" >&2; exit 1; }

# The words that turn every harness row's own compaction off, which a fleet
# --cmd must carry past the fleet gate as it carries the question-tool words;
# open-terminal-harness-gate.sh judges that gate itself.
#
# Sets COMPACTION_OFF_ALL, and exits naming the library when it reads nothing.
COMPACTION_OFF_ALL="$(bash -c '
  source "$1" || exit 1
  for row in "${LAUNCH_CHOICE_FLAGS[@]}"; do launch_choice_compaction_off "${row%%|*}"; done
' _ "$(cd "$(dirname "${BASH_SOURCE[0]}")/../../scripts/lib" && pwd)/lane-launch.sh" | tr '\n' ' ')"
COMPACTION_OFF_ALL="${COMPACTION_OFF_ALL% }"
[[ -n "$COMPACTION_OFF_ALL" ]] || { echo "question-off.sh: lib/lane-launch.sh named no compaction words" >&2; exit 1; }
