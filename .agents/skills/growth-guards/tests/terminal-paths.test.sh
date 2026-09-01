#!/usr/bin/env bash
# Pins for the code paths that only exist AT A TERMINAL. The runners invoke
# every other suite headless, where `mv` never prompts and plain `mv` measures
# exactly as `mv -f` does — which is how a prompting install shipped green.
# Each case here runs under a pseudo-terminal. What a call sets is in
# lib/pty.bash; the rules such a probe follows, and why, are in
# DEVELOPMENT.md § Probing a terminal-only code path.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# shellcheck source=lib/pty.bash
. "$TEST_DIR/lib/pty.bash"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
LIB="$SKILL_DIR/scripts/lib"
# gg_install_file lives in atomic-install.sh, which needs common.sh sourced
# first; a session below therefore takes the lib DIRECTORY and sources both.
INSTALL="$LIB/atomic-install.sh"
ROOT="$TMP"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }
filemode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

R="$ROOT/install-file"
mkdir -p "$R/tools"

# index-reads.test.sh's `call`, with the session's fds on a pty. LIB is a
# parameter so a mutant copy of the tree can be run through the same probe.
#
# SRC is a parameter for a different reason: every path this helper writes
# goes through %q, and a caller splicing one into the SNIPPET instead would
# put it into a shell script body as syntax. $ROOT descends from TMPDIR,
# which the caller owns, so a directory named with a command substitution
# ran. No call site interpolates a path into its snippet — it names $SRC and
# lets this function quote it, so a later case cannot bring the shape back.
#
# %q is the right quoting HERE, where pty.bash's spawn string cannot use it:
# this file is run by `bash`, which is the shell %q quotes for, so the
# ANSI-C form it emits for a control byte is a form its reader parses.
#
# What the session refuses to measure, each with a status of its own, so a
# case that never reached the code under test cannot satisfy a negative
# assertion about it:
#   3  the session's stdin is not a terminal
#   4  the destination is writable, so `mv` has nothing to prompt about
#      (which is every run at euid 0, where mode 0444 is not enforced, and
#      which premise_denies_write also refuses from the suite side before a
#      session is started at all)
# The REACHED marker is the separate positive half: it carries no status, and
# it is the evidence that the call under test was entered.
pty_call() { # LIB SRC SNIPPET
  # The case file goes BESIDE the source, not in $ROOT: gg_pty_run writes it
  # into the session as `bash %q`, so siting it under a hostile SRC is what
  # drives that line's quoting too. Everything else about it is unchanged —
  # $ROOT/tty.tsv puts it back where it always was.
  # Two statements, not one `local`: a builtin's arguments are all expanded
  # before any of its assignments take effect, so case_file cannot read src
  # on the same line.
  local lib="$1" src="$2" snippet="$3" case_file
  case_file="${src%/*}/pty-case.sh"
  {
    printf 'set -euo pipefail\n'
    printf 'cd %q\n' "$R"
    printf 'GG_CHECK=probe\n'
    # The session speaks C, because a case below matches mv's own prompt and
    # coreutils translates it — 46 catalogs on a stock host, fr, de and es
    # among those carrying `overriding mode`. The environment reaches the
    # session through `script`, so a contributor whose shell has a localized
    # message locale would red a healthy tree. common.sh forces LC_ALL=C on
    # every grep whose match depends on tool wording, for this reason.
    printf 'export LC_ALL=C\n'
    printf '[ -t 0 ] || { echo NOT-A-TERMINAL; exit 3; }\n'
    printf '[ ! -w tools/dest.tsv ] || { echo DESTINATION-IS-WRITABLE; exit 4; }\n'
    printf 'SRC=%q\n' "$src"
    printf '. %q\n' "$lib/common.sh"
    printf '. %q\n' "$lib/atomic-install.sh"
    printf 'echo REACHED\n'
    printf '%s\n' "$snippet"
  } >"$case_file"
  OUT=""
  RC=""
  STATE=""
  if ! gg_pty_run 20 "$case_file"; then
    STATE=unstarted
    OUT="$GG_PTY_ERR"
    return 0
  fi
  STATE="$GG_PTY_STATE"
  OUT="$GG_PTY_OUT"
  RC="$GG_PTY_RC"
}

# A case whose premise is a permission denial measures nothing where the
# denial is not enforced: at euid 0 neither 0444 nor 0500 stops anything. One
# helper for every such case, so a later one gets the refusal by construction
# rather than by its author remembering — and so the report names euid 0
# instead of accusing the code under test of a fault that is not there.
premise_denies_write() { # PATH CASE_NAME — 0 when the denial really holds here
  [ ! -w "$1" ] && return 0
  bad "$2" "premise unmet: $1 is writable to this process (euid $(id -u)), so a permission denial is not enforced and this case cannot measure its branch"
  return 1
}

reset_dest() { # CONTENT — a read-only destination carrying CONTENT
  chmod 644 "$R/tools/dest.tsv" 2>/dev/null || true
  printf '%s\n' "$1" >"$R/tools/dest.tsv"
  chmod 444 "$R/tools/dest.tsv"
}

echo "=== gg_install_file: a read-only destination is replaced at a terminal too ==="

SRC_TTY="$ROOT/tty.tsv"
printf 'REPLACED AT A TERMINAL\n' >"$SRC_TTY"
reset_dest ORIGINAL
if premise_denies_write "$R/tools/dest.tsv" "the install lands, and the destination keeps its mode"; then
  pty_call "$LIB" "$SRC_TTY" 'gg_tmpdir; gg_install_file "$SRC" tools/dest.tsv "the fixture"'
  [ "$STATE" = ok ] && [ "$RC" -eq 0 ] && [ "$(cat "$R/tools/dest.tsv")" = "REPLACED AT A TERMINAL" ] \
    && [ "$(filemode "$R/tools/dest.tsv")" = 444 ] \
    && ok "the install lands, and the destination keeps its mode" \
    || bad "the install lands, and the destination keeps its mode" "state=$STATE rc=$RC mode=$(filemode "$R/tools/dest.tsv") out=$OUT"
fi

# The control that makes the case above a measurement rather than a
# coincidence: the same probe against a copy of the helper with the `-f` taken
# back out. Every headless assertion over this helper still passes against it.
#
# The WHOLE lib tree is copied, not atomic-install.sh alone: it needs
# common.sh sourced first, and common.sh bootstraps paths.sh and
# configured-paths.sh off its own directory, so a mutant sited anywhere else
# dies at its first source line — before gg_install_file exists, and while
# still satisfying a control that only asks for an unreplaced destination.
cp -R "$LIB" "$ROOT/lib-no-f"
sed 's/mv -f -- /mv -- /' "$INSTALL" >"$ROOT/lib-no-f/atomic-install.sh"
cmp -s "$INSTALL" "$ROOT/lib-no-f/atomic-install.sh" \
  && bad "control: the mutant really drops the -f" "the copy is byte-identical to atomic-install.sh" \
  || ok "control: the mutant really drops the -f"

reset_dest "NOT REPLACED"
if premise_denies_write "$R/tools/dest.tsv" "control: without the -f the same probe leaves the destination unreplaced"; then
  pty_call "$ROOT/lib-no-f" "$SRC_TTY" 'gg_tmpdir; gg_install_file "$SRC" tools/dest.tsv "the fixture"'
  # The session must have REACHED the call and finished on its own, and its
  # status must be one gg_install_file itself produces: 0, or the 2 of a
  # collection error. A session that refused its premise (3, 4), was capped,
  # or died is a probe failure, and an unreplaced destination is what all of
  # those leave behind too.
  case "$OUT" in *REACHED*) reached=yes ;; *) reached=no ;; esac
  [ "$STATE" = ok ] && [ "$reached" = yes ] && { [ "$RC" -eq 0 ] || [ "$RC" -eq 2 ]; } \
    && [ "$(cat "$R/tools/dest.tsv")" = "NOT REPLACED" ] \
    && [ "$(filemode "$R/tools/dest.tsv")" = 444 ] \
    && ok "control: without the -f the same probe leaves the destination unreplaced" \
    || bad "control: without the -f the same probe leaves the destination unreplaced" "state=$STATE reached=$reached rc=$RC content=$(cat "$R/tools/dest.tsv") out=$OUT"

  # Where mv reports the decline, the decline's own words are the evidence.
  # `could not replace the fixture` alone is gg_collection_error's frame,
  # which it prints whether or not gg_install_why relayed anything — so the
  # match reaches for mv's prompt too, which is the half this case is named
  # for. GNU mv exits 1 and gg_install_why folds that prompt in; BSD mv
  # answers no with exit 0 and nothing to relay, so there is no refusal to
  # read there and this half of the claim is not available. Keyed on uname,
  # the same way the grammar is chosen.
  if [ "$(uname -s)" != Darwin ]; then
    [ "$STATE" = ok ] && [ "$RC" -eq 2 ] && case "$OUT" in
      *"could not replace the fixture"*"overriding mode"*) true ;;
      *) false ;;
    esac \
      && ok "control: and the refusal carries mv's own prompt as its cause" \
      || bad "control: and the refusal carries mv's own prompt as its cause" "state=$STATE rc=$RC out=$OUT"
  fi
fi

echo "=== gg_pty_run: the probe rules the cases above depend on ==="

# The session's fds really are a terminal — the premise every case here rests
# on, asserted rather than assumed.
printf '[ -t 0 ] && [ -t 1 ] && [ -t 2 ] && echo ALL-THREE\n' >"$ROOT/tty-case.sh"
gg_pty_run 20 "$ROOT/tty-case.sh" && [ "$GG_PTY_STATE" = ok ] && [ "$GG_PTY_RC" -eq 0 ] \
  && [ "$GG_PTY_OUT" = "ALL-THREE" ] \
  && ok "stdin, stdout and stderr are all on the pty" \
  || bad "stdin, stdout and stderr are all on the pty" "state=$GG_PTY_STATE rc=$GG_PTY_RC out=$GG_PTY_OUT err=$GG_PTY_ERR"

# A prompt inside the session is answered by EOF, because the SPAWNER reads
# /dev/null. Without that redirect this read is the wedge, not a result.
printf 'read -r answer </dev/tty && echo "READ $answer" || echo EOF-AT-THE-PROMPT\n' >"$ROOT/prompt-case.sh"
gg_pty_run 20 "$ROOT/prompt-case.sh" && [ "$GG_PTY_OUT" = "EOF-AT-THE-PROMPT" ] \
  && ok "a read from the terminal gets EOF instead of waiting" \
  || bad "a read from the terminal gets EOF instead of waiting" "state=$GG_PTY_STATE out=$GG_PTY_OUT err=$GG_PTY_ERR"

# The cap, and what it must leave behind: nothing. The body ignores SIGHUP, so
# the pty closing behind the killed spawner cannot stand in for the reap, and
# it records the pid of the process that must be gone. Killing the spawner
# alone leaves that pid alive while the caller is told the cap worked.
printf 'trap "" HUP\necho STARTED\nsleep 300 &\necho "$!" >%q\nwait\n' "$ROOT/orphan.pid" >"$ROOT/hang-case.sh"
rm -f "$ROOT/orphan.pid"
gg_pty_run 2 "$ROOT/hang-case.sh" && [ "$GG_PTY_STATE" = capped ] && [ -z "$GG_PTY_RC" ] \
  && [ "$GG_PTY_OUT" = "STARTED" ] \
  && ok "control: a session that never returns is capped, reported, and its output kept" \
  || bad "control: a session that never returns is capped, reported, and its output kept" "state=$GG_PTY_STATE rc=$GG_PTY_RC out=$GG_PTY_OUT err=$GG_PTY_ERR"
orphan="$(cat "$ROOT/orphan.pid" 2>/dev/null || true)"
[ -n "$orphan" ] \
  && ok "control: the capped session really did start the child the reap must take" \
  || bad "control: the capped session really did start the child the reap must take" "no pid recorded; state=$GG_PTY_STATE err=$GG_PTY_ERR out=$GG_PTY_OUT"
[ -n "$orphan" ] && ! kill -0 "$orphan" 2>/dev/null \
  && ok "control: and the cap left no process of it behind" \
  || bad "control: and the cap left no process of it behind" "pid $orphan is still running; state=$GG_PTY_STATE err=$GG_PTY_ERR"

# The status is the SESSION's own, read from the file it wrote rather than
# from the spawner, which reports on its own account.
printf 'exit 7\n' >"$ROOT/status-case.sh"
gg_pty_run 20 "$ROOT/status-case.sh" && [ "$GG_PTY_STATE" = ok ] && [ "$GG_PTY_RC" -eq 7 ] \
  && ok "control: a session's own exit status survives the spawner" \
  || bad "control: a session's own exit status survives the spawner" "state=$GG_PTY_STATE rc=$GG_PTY_RC err=$GG_PTY_ERR"

# A session killed before its own last line is `gone`, and carries no status
# at all: a value invented here would be indistinguishable from one a probe
# returned, and every status is one a probe may return.
printf 'echo ABOUT-TO-DIE\nkill -9 "$PPID"\nsleep 5\n' >"$ROOT/die-case.sh"
gg_pty_run 20 "$ROOT/die-case.sh" && [ "$GG_PTY_STATE" = gone ] && [ -z "$GG_PTY_RC" ] \
  && ok "control: a session that dies before its last line reports no status" \
  || bad "control: a session that dies before its last line reports no status" "state=$GG_PTY_STATE rc=$GG_PTY_RC out=$GG_PTY_OUT err=$GG_PTY_ERR"

# A scratch root and a source whose NAMES are a space and a command
# substitution, run end to end. pty.bash hands the spawner a constant command
# and passes its paths in the environment, so there is nothing to quote on
# that side; what this drives is the case body pty_call writes, which bash
# reads, and the paths gg_pty_run exports reaching the session as values.
# Unquoted at either, the substitution runs.
hostile="$ROOT/a q\$(touch $ROOT/PWNED)x dir"
mkdir -p "$hostile"
printf 'FROM A HOSTILE PATH\n' >"$hostile/src.tsv"
rm -f "$ROOT/PWNED"
if premise_denies_write "$R/tools/dest.tsv" "control: a path that is a space and a command substitution stays a path"; then
  reset_dest ORIGINAL
  cp -R "$LIB" "$hostile/lib"
  TMPDIR="$hostile" pty_call "$hostile/lib" "$hostile/src.tsv" 'gg_tmpdir; gg_install_file "$SRC" tools/dest.tsv "the fixture"'
  [ "$STATE" = ok ] && [ "$RC" -eq 0 ] && [ "$(cat "$R/tools/dest.tsv")" = "FROM A HOSTILE PATH" ] \
    && ok "control: a path that is a space and a command substitution stays a path" \
    || bad "control: a path that is a space and a command substitution stays a path" "state=$STATE rc=$RC out=$OUT content=$(cat "$R/tools/dest.tsv")"
fi
[ ! -e "$ROOT/PWNED" ] \
  && ok "control: and nothing inside that name was executed" \
  || bad "control: and nothing inside that name was executed" "the substitution ran; $ROOT/PWNED exists"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
