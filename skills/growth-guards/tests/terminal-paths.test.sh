#!/usr/bin/env bash
# Pins for the code paths that only exist AT A TERMINAL. Every other suite
# here runs with stdin off a pipe, where `mv` never prompts and plain `mv`
# measures exactly as `mv -f` does — which is how a prompting install shipped
# green. Each case runs under a pseudo-terminal; the rules a probe of such a
# path must follow are in lib/harness.bash and DEVELOPMENT.md.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
COMMON="$SKILL_DIR/scripts/lib/common.sh"
ROOT="$TMP"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }
filemode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

R="$ROOT/install-file"
mkdir -p "$R/tools"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test

# index-reads.test.sh's `call`, with the session's fds on a pty. COMMON is a
# parameter so a mutant copy of the helper can be run through the same probe.
pty_call() { # COMMON SNIPPET
  local common="$1" snippet="$2" case_file="$ROOT/pty-case.sh"
  {
    printf 'set -euo pipefail\n'
    printf 'cd %q\n' "$R"
    printf 'GG_CHECK=probe\n'
    # The session proves its own terminal before it measures anything: a
    # spawner that handed back a pipe would otherwise run every case below
    # headless and pass, which is the blindness this suite exists to end.
    printf '[ -t 0 ] || { echo NOT-A-TERMINAL; exit 3; }\n'
    printf '. %q\n' "$common"
    printf '%s\n' "$snippet"
  } >"$case_file"
  OUT=""
  RC=0
  gg_pty_run 20 "$case_file" || { OUT="no pty spawner on this host"; RC=126; return 0; }
  OUT="$GG_PTY_OUT"
  RC="$GG_PTY_RC"
}

reset_dest() { # CONTENT — a read-only destination carrying CONTENT
  chmod 644 "$R/tools/dest.tsv" 2>/dev/null || true
  printf '%s\n' "$1" >"$R/tools/dest.tsv"
  chmod 444 "$R/tools/dest.tsv"
}

echo "=== gg_install_file: a read-only destination is replaced at a terminal too ==="

printf 'REPLACED AT A TERMINAL\n' >"$ROOT/tty.tsv"
reset_dest ORIGINAL
pty_call "$COMMON" 'gg_tmpdir; gg_install_file "'"$ROOT"'/tty.tsv" tools/dest.tsv "the fixture"'
[ "$RC" -eq 0 ] && [ "$(cat "$R/tools/dest.tsv")" = "REPLACED AT A TERMINAL" ] \
  && [ "$(filemode "$R/tools/dest.tsv")" = 444 ] \
  && ok "the install lands, and the destination keeps its mode" \
  || bad "the install lands, and the destination keeps its mode" "rc=$RC mode=$(filemode "$R/tools/dest.tsv") out=$OUT"

# The control that makes the case above a measurement rather than a
# coincidence: the same probe against common.sh with the `-f` taken back out.
# Every headless assertion over this helper still passes against this mutant.
sed 's/mv -f -- /mv -- /' "$COMMON" >"$ROOT/common-no-f.sh"
cmp -s "$COMMON" "$ROOT/common-no-f.sh" \
  && bad "control: the mutant really drops the -f" "the copy is byte-identical to common.sh" \
  || ok "control: the mutant really drops the -f"

reset_dest "NOT REPLACED"
pty_call "$ROOT/common-no-f.sh" 'gg_tmpdir; gg_install_file "'"$ROOT"'/tty.tsv" tools/dest.tsv "the fixture"'
# Content, not the exit status: a `mv` answered no reports 1 on GNU and 0 on
# BSD, while the install either happened or it did not. `!= 124` is the
# separate claim that the probe FAILED rather than wedged — a hung probe
# measures nothing and scores as "not killed" in a mutation run.
[ "$RC" -ne 124 ] && [ "$(cat "$R/tools/dest.tsv")" = "NOT REPLACED" ] \
  && ok "control: without the -f the same probe leaves the destination unreplaced" \
  || bad "control: without the -f the same probe leaves the destination unreplaced" "rc=$RC content=$(cat "$R/tools/dest.tsv")"

echo "=== gg_pty_run: the probe rules the cases above depend on ==="

# The session's fds really are a terminal — the premise every case here rests
# on, asserted rather than assumed.
printf '[ -t 0 ] && [ -t 1 ] && [ -t 2 ] && echo ALL-THREE\n' >"$ROOT/tty-case.sh"
gg_pty_run 20 "$ROOT/tty-case.sh" && [ "$GG_PTY_RC" -eq 0 ] && [ "$GG_PTY_OUT" = "ALL-THREE" ] \
  && ok "stdin, stdout and stderr are all on the pty" \
  || bad "stdin, stdout and stderr are all on the pty" "rc=$GG_PTY_RC out=$GG_PTY_OUT"

# A prompt inside the session is answered by EOF, because the SPAWNER reads
# /dev/null. Without that redirect this read is the wedge, not a result.
printf 'read -r answer </dev/tty && echo "READ $answer" || echo EOF-AT-THE-PROMPT\n' >"$ROOT/prompt-case.sh"
gg_pty_run 20 "$ROOT/prompt-case.sh" && [ "$GG_PTY_OUT" = "EOF-AT-THE-PROMPT" ] \
  && ok "a read from the terminal gets EOF instead of waiting" \
  || bad "a read from the terminal gets EOF instead of waiting" "rc=$GG_PTY_RC out=$GG_PTY_OUT"

# The cap. A probe of a terminal-only path is exactly the thing that hangs, so
# a session that never returns must come back as 124 on its own rather than
# wait for somebody to find it and kill it by pid.
printf 'echo STARTED\nsleep 300\n' >"$ROOT/hang-case.sh"
gg_pty_run 2 "$ROOT/hang-case.sh" && [ "$GG_PTY_RC" -eq 124 ] && [ "$GG_PTY_OUT" = "STARTED" ] \
  && ok "control: a session that never returns is capped, reported, and its output kept" \
  || bad "control: a session that never returns is capped, reported, and its output kept" "rc=$GG_PTY_RC out=$GG_PTY_OUT"

# The status is the SCRIPT's own, not the spawner's: BSD `script` relays none.
printf 'exit 7\n' >"$ROOT/status-case.sh"
gg_pty_run 20 "$ROOT/status-case.sh" && [ "$GG_PTY_RC" -eq 7 ] \
  && ok "control: a session's own exit status survives the spawner" \
  || bad "control: a session's own exit status survives the spawner" "rc=$GG_PTY_RC"

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
