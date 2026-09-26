# `kendex check` on a terminal, the first verb built from the CLI design
# system, recorded for the owner's review against the gum and Vercel CLIs.
# Run from the repository root with vhs, with git and the kendex under
# review on PATH:
#   vhs crates/cli/tests/tapes/check.tape
# The recording lands in tmp/, which git ignores.
Output tmp/check.gif

Set Shell "bash"
Env LANG "C.UTF-8"
Set FontSize 16
Set Width 1280
Set Height 640
Set Padding 24
Set TypingSpeed 40ms

Hide
Type 'source <(crates/cli/tests/tapes/check-fixture.sh "$(mktemp -d)/world")'
Enter
# The terms notice a first run on a terminal prints, said and recorded here
# rather than in the recording.
Type "kendex list >/dev/null && clear"
Enter
Sleep 1s
Show

Type "kendex check"
Sleep 400ms
Enter
Sleep 3s

Type "clear && NO_COLOR=1 kendex check"
Sleep 400ms
Enter
Sleep 3s
