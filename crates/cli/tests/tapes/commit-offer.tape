# The commit offer on a terminal, after `kendex apply --yes` writes a newly
# declared skill: the files, the keyed choices, a push picked with `p`, and
# a message typed after `e`. Recorded for the owner's review against the
# gum and Vercel CLIs. Run from the repository root with vhs, with git and
# the kendex under review on PATH:
#   vhs crates/cli/tests/tapes/commit-offer.tape
# The recording lands in tmp/, which git ignores.
Output tmp/commit-offer.gif

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
# than recording an apply in whatever home the operator runs in.
Type 'world=$(crates/cli/tests/tapes/commit-offer-fixture.sh "$(mktemp -d)/world") || exit 1; eval "$world"'
Enter
# The terms notice a first run on a terminal prints, said and recorded here
# rather than in the recording.
Type "kendex list >/dev/null && clear"
Enter
Sleep 1s
Show

Type "kendex apply --yes"
Sleep 400ms
Enter
Sleep 3s
# Commit and push.
Type "p"
Sleep 2s
# Type a different message.
Type "e"
Sleep 1s
Type "chore: add commit-guards"
Sleep 400ms
Enter
Sleep 4s

Type "clear && cd ../app-plain && NO_COLOR=1 kendex apply --yes"
Sleep 400ms
Enter
Sleep 3s
Type "p"
Sleep 2s
Type "e"
Sleep 1s
Type "chore: add commit-guards"
Sleep 400ms
Enter
Sleep 4s
