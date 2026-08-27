#!/usr/bin/env bash
# `--check` over a core.hooksPath directory someone wired by hand — the one
# shape the installer's stand-down message prescribes. A whole-file grammar,
# so the pins come in threes: the shape that is armed, the shapes that are
# recognizably not ours, and the shapes outside the grammar, which answer
# "could not determine" rather than guessing in the direction that fails open.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# shellcheck source=lib/install-hooks.bash
. "$TEST_DIR/lib/install-hooks.bash"

echo "=== --check reads only EXECUTABLE wiring in a core.hooksPath directory ==="
# A mention of the entry point that no commit ever runs — a comment, a heredoc
# body, an argument, anything past an unconditional exit — must never read as
# gated: a verification tool that fails open is worse than one that fails shut.
R38="$(new_repo checkhookspathshapes)"
install_in "$R38"
SC38="$R38/.agents/skills/growth-guards/scripts"
mkdir -p "$R38/shapehooks"
git -C "$R38" config core.hooksPath shapehooks
arm_pair() { # PRE_FORMAT MSG_FORMAT — printf formats taking the scripts dir
  printf "$1" "$SC38" >"$R38/shapehooks/pre-commit"
  printf "$2" "$SC38" >"$R38/shapehooks/commit-msg"
  chmod +x "$R38/shapehooks/pre-commit" "$R38/shapehooks/commit-msg"
}
# The invariant every shape below is judged against: exit 0 is claimed ONLY
# where a commit is really gated. A shape the grammar does not recognize is
# exit 2 — "could not determine" — never exit 0, and never exit 1 either,
# because calling a hook that does gate "NOT gated" is the same tool telling
# the same lie in the other direction.
must_fail_shape() { # LABEL — recognizably not ours: exit 1, stated as ungated
  check_in "$R38"
  [ "$RC" -eq 1 ] && ok "must-fail: $1 is not armed" || bad "must-fail: $1 is not armed" "rc=$RC out=$OUT"
  case "$OUT" in
    *"NOT gated"* | *"NOT armed"*) ok "and $1 is stated as ungated" ;;
    *) bad "$1 stated as ungated" "out=$OUT" ;;
  esac
}
unverifiable_shape() { # LABEL — outside the grammar: exit 2, never a verdict
  check_in "$R38"
  [ "$RC" -eq 2 ] && ok "must-fail: $1 is not armed (unverifiable)" \
    || bad "must-fail: $1 is not armed (unverifiable)" "rc=$RC out=$OUT"
  case "$OUT" in
    *"could not determine"*) ok "and $1 is stated as unverifiable, not as a verdict" ;;
    *) bad "$1 stated as unverifiable" "out=$OUT" ;;
  esac
}

arm_pair '#!/bin/sh\n# see %s/pre-commit for what this used to do\nexit 0\n' \
  '#!/bin/sh\n# see %s/commit-msg\nexit 0\n'
must_fail_shape "the entry point named only in a line-2 comment"

arm_pair '#!/bin/sh\nexit 0\nexec %s/pre-commit "$@"\n' \
  '#!/bin/sh\nexit 0\nexec %s/commit-msg "$1"\n'
unverifiable_shape "wiring left unreachable after an unconditional exit"

arm_pair '#!/bin/sh\ncat <<EOF\nexec %s/pre-commit "$@"\nEOF\nexit 0\n' \
  '#!/bin/sh\ncat <<EOF\nexec %s/commit-msg "$1"\nEOF\nexit 0\n'
unverifiable_shape "the entry point inside a heredoc body"

arm_pair '#!/bin/sh\necho "%s/pre-commit"\nexit 0\n' \
  '#!/bin/sh\necho "%s/commit-msg"\nexit 0\n'
unverifiable_shape "the entry point as a quoted argument to another command"

arm_pair '#!/bin/sh\n#%s/pre-commit\n' '#!/bin/sh\n#%s/commit-msg\n'
must_fail_shape "a hook whose only content is the commented entry point"

# The command word being the entry point is not enough: the TAIL decides
# whether running it can still fail the commit. Each of these names the entry
# point in command position and gates nothing.
arm_pair '#!/bin/sh\nexec "%s/pre-commit" --help\n' '#!/bin/sh\nexec "%s/commit-msg" --help\n'
unverifiable_shape "the entry point invoked with --help"

arm_pair '#!/bin/sh\n%s/pre-commit "$@" || true\n' '#!/bin/sh\n%s/commit-msg "$1" || true\n'
unverifiable_shape "the entry point with its status thrown away by || true"

arm_pair '#!/bin/sh\n%s/pre-commit "$@" &\n' '#!/bin/sh\n%s/commit-msg "$1" &\n'
unverifiable_shape "the entry point backgrounded, so its status never lands"

# The two hooks do not take the same arguments, and swapping them breaks the
# gate rather than loosening it: pre-commit exits 2 on any argument, and a
# bare commit-msg reads inherited stdin and calls every message empty. Both
# reject valid commits while validating nothing, so "armed" describes neither.
arm_pair '#!/bin/sh\nexec %s/pre-commit "$1"\n' '#!/bin/sh\nexec %s/commit-msg "$1"\n'
unverifiable_shape "pre-commit handed an argument it refuses"

arm_pair '#!/bin/sh\nexec %s/pre-commit "$@"\n' '#!/bin/sh\nexec %s/commit-msg\n'
unverifiable_shape "commit-msg without git's message-file argument"

# A path SHAPE is not an entry point. A moved or removed install leaves a
# hook whose command resolves to nothing: git answers every commit, clean
# ones included, with command-not-found instead of a verdict.
mkdir -p "$R38/gone/growth-guards/scripts"
arm_pair "#!/bin/sh\nexec $R38/gone/growth-guards/scripts/pre-commit \"\$@\"\n" \
  "#!/bin/sh\nexec $R38/gone/growth-guards/scripts/commit-msg \"\$1\"\n"
must_fail_shape "an entry-point path with nothing at it"

: >"$R38/gone/growth-guards/scripts/pre-commit"
: >"$R38/gone/growth-guards/scripts/commit-msg"
arm_pair "#!/bin/sh\nexec $R38/gone/growth-guards/scripts/pre-commit \"\$@\"\n" \
  "#!/bin/sh\nexec $R38/gone/growth-guards/scripts/commit-msg \"\$1\"\n"
must_fail_shape "an entry-point path that is not executable"

# A shebang option can stop the body running at all: `sh -n` syntax-checks
# and exits 0, so the hook executes no guard and passes every commit.
arm_pair '#!/bin/sh -n\nexec %s/pre-commit "$@"\n' '#!/bin/sh -n\nexec %s/commit-msg "$1"\n'
unverifiable_shape "a shebang whose option stops the body running"

# The tail rule cuts both ways, and this is the case that proves `2` is not a
# synonym for ungated: a trailing comment leaves the tail outside the
# allowlist, but the hook runs the entry point and really does gate.
arm_pair '#!/bin/sh\nexec %s/pre-commit "$@" # run the guard\n' \
  '#!/bin/sh\nexec %s/commit-msg "$1" # run the guard\n'
unverifiable_shape "a gating hook whose tail carries a trailing comment"
printf '# %s: finish this\n' "$TD" >"$R38/t.py"
git -C "$R38" add t.py
commit_in "$R38" "feat: add t"
[ "$RC" -ne 0 ] && ok "and that unverifiable hook really does gate, so 2 is not 'ungated'" \
  || bad "trailing-comment hook gates" "rc=$RC out=$OUT"
git -C "$R38" rm -q --cached t.py
rm -f "$R38/t.py"

# The accepted-tail comparison is a shell PATTERN, so its metacharacters have
# to be escaped or it matches more than it names: an unescaped `?` made
# `|| exit $#` pass for `|| exit $?`, and git gives pre-commit no arguments,
# so `$#` is 0 and the wrapper swallowed every pre-commit failure.
arm_pair '#!/bin/sh\n%s/pre-commit "$@" || exit $#\n' '#!/bin/sh\n%s/commit-msg "$1" || exit $#\n'
unverifiable_shape "a tail that only resembles || exit \$? under globbing"

arm_pair '#!/bin/sh\n%s/pre-commit "$@" || exit 0\n' '#!/bin/sh\n%s/commit-msg "$1" || exit 0\n'
unverifiable_shape "a tail that exits 0 on failure"

# A path ending in growth-guards/scripts/<hook> identifies the guard only
# while that last component IS the guard: a symlink there passes -f and -x
# while running anything at all.
mkdir -p "$R38/fake/growth-guards/scripts"
ln -sf /bin/true "$R38/fake/growth-guards/scripts/pre-commit"
ln -sf /bin/true "$R38/fake/growth-guards/scripts/commit-msg"
arm_pair "#!/bin/sh\nexec $R38/fake/growth-guards/scripts/pre-commit \"\$@\"\n" \
  "#!/bin/sh\nexec $R38/fake/growth-guards/scripts/commit-msg \"\$1\"\n"
unverifiable_shape "an entry-point path that is a symlink to another program"

# And the same name worn by a REGULAR executable. A path is a name, not an
# identity: this one passes every file test and is not a symlink either.
rm -f "$R38/fake/growth-guards/scripts/pre-commit" "$R38/fake/growth-guards/scripts/commit-msg"
cp /bin/true "$R38/fake/growth-guards/scripts/pre-commit"
cp /bin/true "$R38/fake/growth-guards/scripts/commit-msg"
chmod +x "$R38/fake/growth-guards/scripts/pre-commit" "$R38/fake/growth-guards/scripts/commit-msg"
arm_pair "#!/bin/sh\nexec $R38/fake/growth-guards/scripts/pre-commit \"\$@\"\n" \
  "#!/bin/sh\nexec $R38/fake/growth-guards/scripts/commit-msg \"\$1\"\n"
must_fail_shape "another program wearing the entry point's name"
printf '# %s: finish this\n' "$TD" >"$R38/im.py"
git -C "$R38" add im.py
commit_in "$R38" "feat: add im"
[ "$RC" -eq 0 ] && ok "and that impostor really does let a violation through" \
  || bad "impostor bypasses" "rc=$RC out=$OUT"
git -C "$R38" rm -q --cached im.py
rm -f "$R38/im.py"
printf '# %s: finish this\n' "$TD" >"$R38/sl.py"
git -C "$R38" add sl.py
commit_in "$R38" "feat: add sl"
[ "$RC" -eq 0 ] && ok "and that wiring really does bypass the guard, which is why it is never armed" \
  || bad "symlinked entry point bypasses" "rc=$RC out=$OUT"
git -C "$R38" rm -q --cached sl.py
rm -f "$R38/sl.py"

# A tail must be SEPARATED from the command by a real blank. The shell
# concatenates `"…/commit-msg""$1"` into one word, so reading it as
# command-plus-tail describes a hook git cannot run at all.
arm_pair '#!/bin/sh\nexec "%s/pre-commit""$@"\n' '#!/bin/sh\nexec "%s/commit-msg""$1"\n'
must_fail_shape "a quoted command with no separator before its tail"

# Only blanks are trimmed. `[[:space:]]` would eat a trailing CR that the
# shell keeps as part of the word, so a CRLF hook would be accepted for a
# tail the shell never sees.
arm_pair '#!/bin/sh\nexec %s/pre-commit "$@"\r\n' '#!/bin/sh\nexec %s/commit-msg "$1"\r\n'
unverifiable_shape "a hook whose command line ends in a carriage return"

# `exec -a NAME cmd` runs cmd under another argv[0]: the command word is two
# tokens further along, and reading the option as the command would report a
# hook that gates perfectly well as NOT gated — the false negative this
# grammar reserves exit 2 for.
# `#!/bin/bash` deliberately: `exec -a` is a bash extension, and /bin/sh is
# dash on the CI runner, where this hook would fail to run at all rather than
# demonstrate the case.
arm_pair '#!/bin/bash\nexec -a guard %s/pre-commit "$@"\n' '#!/bin/bash\nexec -a guard %s/commit-msg "$1"\n'
unverifiable_shape "wiring behind an exec option"
printf 'clean\n' >"$R38/ea.txt"
git -C "$R38" add ea.txt
commit_in "$R38" "feat: add ea"
[ "$RC" -eq 0 ] && ok "and that hook really does gate, so it is not called ungated" \
  || bad "exec -a hook gates" "rc=$RC out=$OUT"
git -C "$R38" rm -q --cached ea.txt
rm -f "$R38/ea.txt"

# A carriage return in the SHEBANG is not trailing whitespace: the kernel
# looks for an interpreter named `/bin/sh\r`, and git cannot run the hook at
# all — a clean commit dies with "cannot exec".
arm_pair '#!/bin/sh\r\nexec %s/pre-commit "$@"\n' '#!/bin/sh\r\nexec %s/commit-msg "$1"\n'
must_fail_shape "a shebang line ending in a carriage return"

# The interpreter is identified by FULL PATH, not by basename: an executable
# named `sh` anywhere at all can be a copy of /bin/true, and then git runs
# true, ignores the hook body, and nothing is gated.
mkdir -p "$R38/fakebin"
cp /bin/true "$R38/fakebin/sh"
chmod +x "$R38/fakebin/sh"
arm_pair "#!$R38/fakebin/sh\nexec %s/pre-commit \"\$@\"\n" \
  "#!$R38/fakebin/sh\nexec %s/commit-msg \"\$1\"\n"
unverifiable_shape "a shebang naming an untrusted interpreter"
printf '# %s: finish this\n' "$TD" >"$R38/fi.py"
git -C "$R38" add fi.py
commit_in "$R38" "feat: add fi"
[ "$RC" -eq 0 ] && ok "and that interpreter really does swallow the hook body" \
  || bad "fake interpreter bypasses" "rc=$RC out=$OUT"
git -C "$R38" rm -q --cached fi.py
rm -f "$R38/fi.py"

# `env` resolves the interpreter through PATH, which is no more knowable than
# a custom path — unverifiable, even though such a hook usually does gate.
arm_pair '#!/usr/bin/env bash\nexec %s/pre-commit "$@"\n' '#!/usr/bin/env bash\nexec %s/commit-msg "$1"\n'
unverifiable_shape "a shebang resolving its interpreter through env"

# The delegating shape resolves its helper in the redirected directory, and
# outside the installer-owned hooks directory that helper is a copy someone
# made. The marker is a comment anyone can type.
cp "$R38/.git/hooks/pre-commit" "$R38/.git/hooks/commit-msg" "$R38/shapehooks/"
printf '#!/bin/sh\n# kendex growth-guards git hooks\nexit 0\n' >"$R38/shapehooks/kendex-guards"
chmod +x "$R38/shapehooks/kendex-guards"
unverifiable_shape "a helper carrying the marker but none of the behaviour"
printf '# %s: finish this\n' "$TD" >"$R38/fh.py"
git -C "$R38" add fh.py
commit_in "$R38" "feat: add fh"
[ "$RC" -eq 0 ] && ok "and that helper really does bypass every guard" \
  || bad "fake helper bypasses" "rc=$RC out=$OUT"
git -C "$R38" rm -q --cached fh.py
rm -f "$R38/fh.py"
# Control: the helper this installer actually wrote, copied across, is armed.
cp "$R38/.git/hooks/kendex-guards" "$R38/shapehooks/"
check_in "$R38"
[ "$RC" -eq 0 ] && ok "control: the installer's own helper, copied across, is armed" \
  || bad "copied real helper armed" "rc=$RC out=$OUT"
rm -f "$R38/shapehooks/kendex-guards" "$R38/shapehooks/pre-commit" "$R38/shapehooks/commit-msg"

# On the trusted list is not on the disk. Pick whichever listed shell this
# host lacks; if it has all of them the case cannot arise here and is
# reported as skipped rather than silently dropped.
GG_ABSENT_SH=""
for gg_c in /bin/dash /bin/ksh /bin/zsh /usr/bin/dash /usr/bin/ksh; do
  if [ ! -x "$gg_c" ]; then GG_ABSENT_SH="$gg_c"; break; fi
done
if [ -n "$GG_ABSENT_SH" ]; then
  arm_pair "#!$GG_ABSENT_SH\nexec %s/pre-commit \"\$@\"\n" "#!$GG_ABSENT_SH\nexec %s/commit-msg \"\$1\"\n"
  unverifiable_shape "a trusted interpreter path that is absent on this host"
  printf 'clean\n' >"$R38/ai.txt"
  git -C "$R38" add ai.txt
  commit_in "$R38" "feat: add ai"
  [ "$RC" -ne 0 ] && ok "and git really cannot exec that hook, so even a clean commit fails" \
    || bad "absent interpreter blocks" "rc=$RC out=$OUT"
  git -C "$R38" rm -q --cached ai.txt
  rm -f "$R38/ai.txt"
else
  printf '  skip  a trusted interpreter path that is absent on this host (all are installed)\n'
fi

# The word the SHELL runs, not the one written down. A checkout path that
# literally contains `$slot` passes every file test while /bin/sh expands it
# at commit time — so the same bytes name a different program.
mkdir -p "$R38/dollar/\$slot"
# A LINK to the real install, so the physical-location test still resolves
# and the only thing under examination is the spelling.
ln -s "$SC38" "$R38/dollar/\$slot/scripts"
arm_pair "#!/bin/sh\nexec \"$R38/dollar/\$slot/scripts/pre-commit\" \"\$@\"\n" \
  "#!/bin/sh\nexec \"$R38/dollar/\$slot/scripts/commit-msg\" \"\$1\"\n"
unverifiable_shape "a double-quoted command that the shell would expand"

# Control: the SAME literal path, single-quoted, survives evaluation
# unchanged — so it is verifiable and stays armed.
arm_pair "#!/bin/sh\nexec '$R38/dollar/\$slot/scripts/pre-commit' \"\$@\"\n" \
  "#!/bin/sh\nexec '$R38/dollar/\$slot/scripts/commit-msg' \"\$1\"\n"
check_in "$R38"
[ "$RC" -eq 0 ] && ok "control: single-quoting the same path keeps it verifiable" \
  || bad "single-quoted dollar path armed" "rc=$RC out=$OUT"

# An unquoted word globs as well, so a glob character is unverifiable too.
arm_pair '#!/bin/sh\nexec %s/pre-comm?t "$@"\n' '#!/bin/sh\nexec %s/commit-ms? "$1"\n'
unverifiable_shape "an unquoted command carrying a glob character"

# Indentation is BLANKS. A line starting with CR runs a command named
# `\rexec`, so normalizing it away would accept a hook that git cannot run.
arm_pair '#!/bin/sh\n\rexec %s/pre-commit "$@"\n' '#!/bin/sh\n\rexec %s/commit-msg "$1"\n'
unverifiable_shape "a command line beginning with a carriage return"

# A line this function cannot read still RUNS. Counting it only after
# classification let an unreadable line be skipped silently, leaving a later
# entry point looking like the only command in the file.
arm_pair "#!/bin/sh\nexit\t0\nexec %s/pre-commit \"\$@\"\n" "#!/bin/sh\nexit\t0\nexec %s/commit-msg \"\$1\"\n"
unverifiable_shape "an unreadable line before the entry point"
printf '# %s: finish this\n' "$TD" >"$R38/tb.py"
git -C "$R38" add tb.py
commit_in "$R38" "feat: add tb"
[ "$RC" -eq 0 ] && ok "and that hook really does exit before the guard runs" \
  || bad "tab-exit hook bypasses" "rc=$RC out=$OUT"
git -C "$R38" rm -q --cached tb.py
rm -f "$R38/tb.py"

# Control: a TAB is an ordinary separator, not a control character — this
# hook gates, and must not be swept up by the rule above.
arm_pair '#!/bin/sh\nexec\t%s/pre-commit "$@"\n' '#!/bin/sh\nexec\t%s/commit-msg "$1"\n'
check_in "$R38"
[ "$RC" -eq 0 ] && ok "control: a tab between exec and the entry point is armed" \
  || bad "tab-separated entry point armed" "rc=$RC out=$OUT"

# `NAME=value cmd` really runs cmd; reading the assignment as the command
# reported a gating hook as NOT gated.
arm_pair '#!/bin/sh\nFLAG=1 %s/pre-commit "$@"\n' '#!/bin/sh\nFLAG=1 %s/commit-msg "$1"\n'
unverifiable_shape "an environment assignment before the entry point"
printf 'clean\n' >"$R38/ap.txt"
git -C "$R38" add ap.txt
commit_in "$R38" "feat: add ap"
[ "$RC" -eq 0 ] && ok "and that hook really does gate, so it is not called ungated" \
  || bad "assignment-prefixed hook gates" "rc=$RC out=$OUT"
git -C "$R38" rm -q --cached ap.txt
rm -f "$R38/ap.txt"

# One passing control per shape the check does accept.
arm_pair '#!/bin/sh\n%s/pre-commit "$@" || exit $?\n' \
  '#!/bin/sh\n%s/commit-msg "$1" || exit $?\n'
check_in "$R38"
[ "$RC" -eq 0 ] && ok "control: a bare invocation of the entry point is armed" \
  || bad "bare invocation armed" "rc=$RC out=$OUT"

arm_pair '#!/bin/sh\nexec "%s/pre-commit" "$@"\n' '#!/bin/sh\nexec "%s/commit-msg" "$1"\n'
check_in "$R38"
[ "$RC" -eq 0 ] && ok "control: a quoted exec of the entry point is armed" \
  || bad "quoted exec armed" "rc=$RC out=$OUT"

# Reachability is the line this tool does not cross. These three all run the
# entry point in a shell, and a lexical reader cannot separate the two that
# never execute from the one that does — so none of them is answered.
arm_pair '#!/bin/sh\nif false; then\nexec %s/pre-commit "$@"\nfi\nexit 0\n' \
  '#!/bin/sh\nif false; then\nexec %s/commit-msg "$1"\nfi\nexit 0\n'
unverifiable_shape "wiring guarded by a condition that is never true"

arm_pair '#!/bin/sh\nunused() {\nexec %s/pre-commit "$@"\n}\nexit 0\n' \
  '#!/bin/sh\nunused() {\nexec %s/commit-msg "$1"\n}\nexit 0\n'
unverifiable_shape "wiring inside a function nothing calls"

arm_pair '#!/bin/sh\ncat <<-EOF\n\t%s/pre-commit\n\tEOF\nexit 0\n' \
  '#!/bin/sh\ncat <<-EOF\n\t%s/commit-msg\n\tEOF\nexit 0\n'
unverifiable_shape "the entry point in a <<- heredoc with an indented terminator"

# And the same answer for a hook that DOES gate but says more than the one
# command: unverifiable is not a synonym for ungated.
arm_pair '#!/bin/sh\nset -e\nexec %s/pre-commit "$@"\n' \
  '#!/bin/sh\nset -e\nexec %s/commit-msg "$1"\n'
unverifiable_shape "a hook that gates but runs another command first"
check_in "$R38"
printf '# %s: finish this\n' "$TD" >"$R38/s.py"
git -C "$R38" add s.py
commit_in "$R38" "feat: add s"
[ "$RC" -ne 0 ] && ok "and that unverifiable hook really does gate, which is why it is not called ungated" \
  || bad "unverifiable-but-gating hook blocks" "rc=$RC out=$OUT"
git -C "$R38" rm -q --cached s.py
rm -f "$R38/s.py"

# A second install elsewhere on disk: the generic entry-point shape, wired to
# scripts that really run, so "armed" is proved against an actual commit.
mkdir -p "$TMP/elsewhere/growth-guards"
ln -s "$SC38" "$TMP/elsewhere/growth-guards/scripts"
printf '#!/bin/sh\nexec %s/elsewhere/growth-guards/scripts/pre-commit "$@"\n' "$TMP" >"$R38/shapehooks/pre-commit"
printf '#!/bin/sh\nexec %s/elsewhere/growth-guards/scripts/commit-msg "$1"\n' "$TMP" >"$R38/shapehooks/commit-msg"
chmod +x "$R38/shapehooks/pre-commit" "$R38/shapehooks/commit-msg"
check_in "$R38"
[ "$RC" -eq 0 ] && ok "control: an entry point from another install on disk is armed" \
  || bad "other-install entry point armed" "rc=$RC out=$OUT"
printf '# %s: finish this\n' "$TD" >"$R38/s.py"
git -C "$R38" add s.py
commit_in "$R38" "feat: add s"
[ "$RC" -ne 0 ] && ok "and a violation is really blocked through it" || bad "other-install wiring blocks" "rc=$RC out=$OUT"
git -C "$R38" rm -q --cached s.py
rm -f "$R38/s.py"
# Armed has to mean the gate JUDGES, not that it refuses everything: a
# mis-wired hook blocks a clean commit too, and only this half tells them
# apart.
printf 'clean\n' >"$R38/clean.txt"
git -C "$R38" add clean.txt
commit_in "$R38" "feat: add a clean file"
[ "$RC" -eq 0 ] && ok "and a clean commit still passes through it" \
  || bad "clean commit passes armed wiring" "rc=$RC out=$OUT"

# The delegating line resolves its helper with `git rev-parse --git-path
# hooks`, which under core.hooksPath is this directory — so the helper has to
# be here, and a copy without it is not gated.
cp "$R38/.git/hooks/pre-commit" "$R38/.git/hooks/commit-msg" "$R38/.git/hooks/kendex-guards" "$R38/shapehooks/"
check_in "$R38"
[ "$RC" -eq 0 ] && ok "control: the delegating line beside its helper is armed" \
  || bad "delegating line with helper armed" "rc=$RC out=$OUT"
rm -f "$R38/shapehooks/kendex-guards"
check_in "$R38"
[ "$RC" -eq 1 ] && ok "must-fail: the delegating line without its helper is not armed" \
  || bad "delegating line without helper" "rc=$RC out=$OUT"

echo "=== a relative hand-wired command resolves against the work tree ==="
# git runs a hook from the work tree's top level, so that is what a relative
# command word in a hand-wired hook means. Resolving it against this
# process's directory answers about a different file, and the same valid
# wiring then reads armed from inside the repository and unarmed from
# anywhere else — a verdict that depends on where the question was asked.
R50="$(new_repo relcmd)"
mkdir -p "$R50/customhooks"
git -C "$R50" config core.hooksPath customhooks
REL=".agents/skills/growth-guards/scripts"
printf '#!/bin/sh\nexec %s/pre-commit\n' "$REL" >"$R50/customhooks/pre-commit"
printf '#!/bin/sh\nexec %s/commit-msg "$1"\n' "$REL" >"$R50/customhooks/commit-msg"
chmod +x "$R50/customhooks/pre-commit" "$R50/customhooks/commit-msg"

check_from "$R50" "$R50"
[ "$RC" -eq 0 ] && ok "a relative command reads armed from inside the repository" \
  || bad "relative command armed from inside" "rc=$RC out=$OUT"

# The same repository, asked from somewhere with no such path under it.
OUT=""; RC=0
OUT="$(cd "$TMP" && "$R50/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R50" --check 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "and the same, asked from outside it" \
  || bad "relative command armed from outside" "rc=$RC out=$OUT"

# The must-fail control: a relative command that resolves nowhere under the
# work tree is still not armed, so the pins above are not passing on a
# resolution that accepts anything.
R51="$(new_repo relcmd-absent)"
mkdir -p "$R51/customhooks"
git -C "$R51" config core.hooksPath customhooks
printf '#!/bin/sh\nexec nowhere/pre-commit\n' >"$R51/customhooks/pre-commit"
chmod +x "$R51/customhooks/pre-commit"
OUT=""; RC=0
OUT="$(cd "$TMP" && "$R51/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R51" --check 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && ok "must-fail: a relative command resolving nowhere is not armed" \
  || bad "absent relative command read armed" "rc=$RC out=$OUT"

echo "=== a hook that only quotes a marker is not ours ==="
# The ownership question and the shape question fail in opposite directions,
# and these are the ownership one. Every site that asks whether a file is
# ours asks it the same way — the marker CLOSING a line, or the created
# marker as a line whole — so a consumer hook that mentions either in a
# sentence is somebody else's file at every one of them.
QUOTE_CREATED="# kendex-guards-hook created this file"
QUOTE_SENTINEL="# kendex-guards-hook"

# Install refuses a hook it cannot verify unless THIS installer wrote it.
# A consumer hook under an interpreter we do not vouch for, mentioning the
# created marker mid-sentence, is not ours — and rewriting its shebang, as
# a substring read would, changes which interpreter someone else's hook
# runs under.
R52="$(new_repo quoter-shebang)"
FOREIGN="$R52/.git/hooks/pre-commit"
# A shell shebang the checker will not vouch for: an interpreter outside
# /bin and /usr/bin, which is what reaches the created-marker question.
printf '#!/usr/local/bin/bash\n# not %s, just talking about it\nexit 0\n' \
  "$QUOTE_CREATED" >"$FOREIGN"
chmod +x "$FOREIGN"
BEFORE="$(cat "$FOREIGN")"
install_in "$R52"
[ "$(head -n 1 "$FOREIGN")" = "#!/usr/local/bin/bash" ] \
  && ok "install leaves the shebang of a hook that only quotes the created marker" \
  || bad "the quoting hook's shebang was rewritten" "$(cat "$FOREIGN")"
[ "$(cat "$FOREIGN")" = "$BEFORE" ] && ok "and the file is byte for byte what it was" \
  || bad "the quoting hook was edited" "$(cat "$FOREIGN")"
case "$OUT" in
  *"cannot be verified"*) ok "and the install says the guard is NOT installed there" ;;
  *) bad "install did not announce the refusal" "$OUT" ;;
esac

# The symlink branch asks the same question of a target it must not edit.
R53="$(new_repo quoter-symlink)"
install_in "$R53"
printf '#!/bin/sh\n# ours end in %s, this one does not\necho mine\n' \
  "$QUOTE_SENTINEL" >"$TMP/foreign-target"
chmod +x "$TMP/foreign-target"
rm -f "$R53/.git/hooks/commit-msg"
ln -s "$TMP/foreign-target" "$R53/.git/hooks/commit-msg"
OUT=""; RC=0
OUT="$("$R53/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R53" --uninstall 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "uninstall succeeds beside a symlink to a hook that quotes the marker" \
  || bad "uninstall failed" "rc=$RC out=$OUT"
case "$OUT" in
  *"symlink carrying the guard line"*)
    bad "a quoting symlink target was claimed as ours" "$OUT" ;;
  *) ok "and does not claim the quoting target as ours" ;;
esac
[ -L "$R53/.git/hooks/commit-msg" ] && ok "and the symlink is left in place" \
  || bad "the symlink went" "out=$OUT"

# The must-fail control: a symlink to a target that really carries our line
# IS claimed, so the pins above are not passing on a predicate that never
# matches anything.
R54="$(new_repo real-symlink)"
install_in "$R54"
cp "$R54/.git/hooks/pre-commit" "$TMP/real-target"
rm -f "$R54/.git/hooks/commit-msg"
ln -s "$TMP/real-target" "$R54/.git/hooks/commit-msg"
OUT=""; RC=0
OUT="$("$R54/.agents/skills/growth-guards/scripts/install-git-hooks" --repo "$R54" --uninstall 2>&1)" || RC=$?
case "$OUT" in
  *"symlink carrying the guard line"*)
    ok "must-fail: a symlink to a target that does carry our line is claimed" ;;
  *) bad "a real guard line in a symlink target was missed" "$OUT" ;;
esac

echo "=== an empty core.hooksPath is hooks off, in this checker too ==="
# The third file this has come up in. Empty switches hooks off, and
# rev-parse reports ./ for it, so measuring that directory answers about the
# repository root — armed, if the root happens to hold the right shapes.
R62="$(new_repo hooks-off)"
install_in "$R62"
check_in "$R62"
[ "$RC" -eq 0 ] && ok "the control: armed before the value is set" \
  || bad "control not armed" "rc=$RC out=$OUT"
git -C "$R62" config core.hooksPath ""
cp "$R62/.git/hooks/kendex-guards" "$R62/kendex-guards"
cp "$R62/.git/hooks/pre-commit" "$R62/pre-commit"
cp "$R62/.git/hooks/commit-msg" "$R62/commit-msg"
check_in "$R62"
[ "$RC" -eq 1 ] && ok "an empty value reads NOT armed, not armed-at-the-root" \
  || bad "empty hooksPath verdict" "rc=$RC out=$OUT"
case "$OUT" in
  *"switches git hooks off"*) ok "and says what is actually wrong" ;;
  *) bad "the verdict does not name the cause" "$OUT" ;;
esac
case "$OUT" in
  *"git config --unset core.hooksPath"*) ok "and leads with the remedy that works" ;;
  *) bad "no unset in the remedy" "$OUT" ;;
esac
install_in "$R62"
case "$OUT" in
  *"switches git hooks off"*) ok "and install says the same rather than writing" ;;
  *) bad "install did not name the empty value" "$OUT" ;;
esac

echo "=== core.hooksPath set at all is a stand-down ==="
# Whether the configured directory is in fact this repository's own used to
# be worked out here — resolved on disk, `..` folded on paper, a relative
# value absolutized against the work tree. Every one of those was another
# way to be subtly wrong, and two of them were. Set is set: the installer
# writes nothing git might not read, and says how to wire that directory by
# hand. It costs an arming; it never costs a repository that reads armed
# and gates nothing.
for spelling in default-relative default-absolute elsewhere empty; do
  R70="$(new_repo "set-$spelling")"
  case "$spelling" in
    default-relative) VALUE=".git/hooks" ;;
    default-absolute) VALUE="$R70/.git/hooks" ;;
    elsewhere) VALUE="$R70/otherhooks" ;;
    empty) VALUE="" ;;
  esac
  git -C "$R70" config core.hooksPath "$VALUE"
  install_in "$R70"
  [ -e "$R70/.git/hooks/kendex-guards" ] \
    && bad "installed under core.hooksPath ($spelling)" "out=$OUT" \
    || ok "core.hooksPath set stands the install down ($spelling)"
  case "$spelling" in
    empty) case "$OUT" in
      *"switches git hooks off"*) ok "and empty is told apart in the message" ;;
      *) bad "empty was not named" "$OUT" ;;
    esac ;;
    *) case "$OUT" in
      *"Have that directory's pre-commit run"*) ok "and a path is told how to wire it ($spelling)" ;;
      *) bad "no wiring instruction ($spelling)" "$OUT" ;;
    esac ;;
  esac
done

# The must-fail control: with nothing set, the same repository arms.
R71="$(new_repo unset-arms)"
install_in "$R71"
[ -x "$R71/.git/hooks/kendex-guards" ] \
  && ok "must-fail: with core.hooksPath unset the install arms" \
  || bad "unset did not arm" "out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
