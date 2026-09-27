# `kendex refresh` on a terminal: the plan, the write consent answered by
# one key, and the commit offer after the write, left as diffs with Enter.
# Recorded for the owner's review against the gum and Vercel CLIs. Run from
# the repository root with vhs, with git and the kendex under review on
# PATH:
#   vhs crates/cli/tests/tapes/refresh.tape
# The recording lands in tmp/, which git ignores.
Output tmp/refresh.gif

# Every setting comes before the first other command, or vhs ignores it.
Set Shell "bash"
Set FontSize 16
Set Width 1280
Set Height 960
Set Padding 24
Set TypingSpeed 40ms
Env LANG "C.UTF-8"

Hide
# A fixture that fails ends the shell, and the recording with it, rather
# than recording a refresh of whatever home the operator runs in.
Type 'world=$(crates/cli/tests/tapes/refresh-fixture.sh "$(mktemp -d)/world") || exit 1; eval "$world"'
Enter
# The terms notice a first run on a terminal prints, said and recorded here
# rather than in the recording.
Type "kendex list >/dev/null && clear"
Enter
Sleep 1s
Show

Type "kendex refresh --scope project"
Sleep 400ms
Enter
Sleep 3s
# Write the changes.
Type "y"
Sleep 3s
# Leave the files as diffs.
Enter
Sleep 3s

Type "clear && cd ../app-plain && NO_COLOR=1 kendex refresh --scope project"
Sleep 400ms
Enter
Sleep 3s
Type "y"
Sleep 3s
Enter
Sleep 3s
