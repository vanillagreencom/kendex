#!/usr/bin/env bash
# Pins for the code paths that only exist AT A TERMINAL. The runners invoke
# every other suite headless, where `mv` never prompts and plain `mv` measures
# exactly as `mv -f` does — which is how a prompting install shipped green.
# Each case here runs under a pseudo-terminal; the rules a probe of such a
# path must follow, and why, are in lib/pty.bash.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
# shellcheck source=lib/pty.bash
. "$TEST_DIR/lib/pty.bash"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
LIB="$SKILL_DIR/scripts/lib"
COMMON="$LIB/common.sh"
ROOT="$TMP"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }
filemode() { stat -c '%a' "$1" 2>/dev/null || stat -f '%Lp' "$1"; }

R="$ROOT/install-file"
mkdir -p "$R/tools"

# index-reads.test.sh's `call`, with the session's fds on a pty. COMMON is a
# parameter so a mutant copy of the helper can be run through the same probe.
#
# SRC is a parameter for a different reason: every path this helper writes
# goes through %q, and a caller splicing one into the SNIPPET instead would
# put it into a shell script body as syntax. $ROOT descends from TMPDIR,
# which the caller owns, so a directory named with a command substitution
# ran. No call site interpolates a path into its snippet — it names $SRC and
# lets this function quote it, so a later case cannot bring the shape back.
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
pty_call() { # COMMON SRC SNIPPET
  local common="$1" src="$2" snippet="$3" case_file="$ROOT/pty-case.sh"
  {
    printf 'set -euo pipefail\n'
    printf 'cd %q\n' "$R"
    printf 'GG_CHECK=probe\n'
    printf '[ -t 0 ] || { echo NOT-A-TERMINAL; exit 3; }\n'
    printf '[ ! -w tools/dest.tsv ] || { echo DESTINATION-IS-WRITABLE; exit 4; }\n'
    printf 'SRC=%q\n' "$src"
    printf '. %q\n' "$common"
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
  pty_call "$COMMON" "$SRC_TTY" 'gg_tmpdir; gg_install_file "$SRC" tools/dest.tsv "the fixture"'
  [ "$STATE" = ok ] && [ "$RC" -eq 0 ] && [ "$(cat "$R/tools/dest.tsv")" = "REPLACED AT A TERMINAL" ] \
    && [ "$(filemode "$R/tools/dest.tsv")" = 444 ] \
    && ok "the install lands, and the destination keeps its mode" \
    || bad "the install lands, and the destination keeps its mode" "state=$STATE rc=$RC mode=$(filemode "$R/tools/dest.tsv") out=$OUT"
fi

# The control that makes the case above a measurement rather than a
# coincidence: the same probe against a copy of the helper with the `-f` taken
# back out. Every headless assertion over this helper still passes against it.
#
# The WHOLE lib tree is copied, not common.sh alone: common.sh bootstraps
# paths.sh and configured-paths.sh off its own directory, so a mutant sited
# anywhere else dies at its first source line — before gg_install_file exists,
# and while still satisfying a control that only asks for an unreplaced
# destination.
cp -R "$LIB" "$ROOT/lib-no-f"
sed 's/mv -f -- /mv -- /' "$COMMON" >"$ROOT/lib-no-f/common.sh"
cmp -s "$COMMON" "$ROOT/lib-no-f/common.sh" \
  && bad "control: the mutant really drops the -f" "the copy is byte-identical to common.sh" \
  || ok "control: the mutant really drops the -f"

reset_dest "NOT REPLACED"
if premise_denies_write "$R/tools/dest.tsv" "control: without the -f the same probe leaves the destination unreplaced"; then
  pty_call "$ROOT/lib-no-f/common.sh" "$SRC_TTY" 'gg_tmpdir; gg_install_file "$SRC" tools/dest.tsv "the fixture"'
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
  # answers no with exit 0, so the helper reports nothing at all and this
  # claim is only available on the util-linux path.
  if [ "$GG_PTY_FORM" = util-linux ]; then
    [ "$RC" -eq 2 ] && case "$OUT" in
      *"could not replace the fixture"*"overriding mode"*) true ;;
      *) false ;;
    esac \
      && ok "control: and the refusal carries mv's own prompt as its cause" \
      || bad "control: and the refusal carries mv's own prompt as its cause" "rc=$RC out=$OUT"
  fi
fi

echo "=== gg_pty_run: the probe rules the cases above depend on ==="

# The session's fds really are a terminal — the premise every case here rests
# on, asserted rather than assumed.
printf '[ -t 0 ] && [ -t 1 ] && [ -t 2 ] && echo ALL-THREE\n' >"$ROOT/tty-case.sh"
gg_pty_run 20 "$ROOT/tty-case.sh" && [ "$GG_PTY_STATE" = ok ] && [ "$GG_PTY_RC" -eq 0 ] \
  && [ "$GG_PTY_OUT" = "ALL-THREE" ] \
  && ok "stdin, stdout and stderr are all on the pty" \
  || bad "stdin, stdout and stderr are all on the pty" "state=$GG_PTY_STATE rc=$GG_PTY_RC out=$GG_PTY_OUT"

# A prompt inside the session is answered by EOF, because the SPAWNER reads
# /dev/null. Without that redirect this read is the wedge, not a result.
printf 'read -r answer </dev/tty && echo "READ $answer" || echo EOF-AT-THE-PROMPT\n' >"$ROOT/prompt-case.sh"
gg_pty_run 20 "$ROOT/prompt-case.sh" && [ "$GG_PTY_OUT" = "EOF-AT-THE-PROMPT" ] \
  && ok "a read from the terminal gets EOF instead of waiting" \
  || bad "a read from the terminal gets EOF instead of waiting" "state=$GG_PTY_STATE out=$GG_PTY_OUT"

# The cap, and what it must leave behind: nothing. The body ignores SIGHUP, so
# the pty closing behind the killed spawner cannot stand in for the reap, and
# it records the pid of the process that must be gone. Killing the spawner
# alone leaves that pid alive, holding fds inside the scratch tree the helper
# has already removed, while the caller is told the cap worked.
printf 'trap "" HUP\necho STARTED\nsleep 300 &\necho "$!" >%q\nwait\n' "$ROOT/orphan.pid" >"$ROOT/hang-case.sh"
rm -f "$ROOT/orphan.pid"
gg_pty_run 2 "$ROOT/hang-case.sh" && [ "$GG_PTY_STATE" = capped ] && [ -z "$GG_PTY_RC" ] \
  && [ "$GG_PTY_OUT" = "STARTED" ] \
  && ok "control: a session that never returns is capped, reported, and its output kept" \
  || bad "control: a session that never returns is capped, reported, and its output kept" "state=$GG_PTY_STATE rc=$GG_PTY_RC out=$GG_PTY_OUT"
orphan="$(cat "$ROOT/orphan.pid" 2>/dev/null || true)"
[ -n "$orphan" ] \
  && ok "control: the capped session really did start the child the reap must take" \
  || bad "control: the capped session really did start the child the reap must take" "no pid recorded; state=$GG_PTY_STATE err=$GG_PTY_ERR out=$GG_PTY_OUT"
[ -n "$orphan" ] && ! kill -0 "$orphan" 2>/dev/null \
  && ok "control: and the cap left no process of it behind" \
  || bad "control: and the cap left no process of it behind" "pid $orphan is still running; state=$GG_PTY_STATE reaped=$GG_PTY_REAPED err=$GG_PTY_ERR"

# The status is the SESSION's own, not the spawner's: BSD `script` relays none.
printf 'exit 7\n' >"$ROOT/status-case.sh"
gg_pty_run 20 "$ROOT/status-case.sh" && [ "$GG_PTY_STATE" = ok ] && [ "$GG_PTY_RC" -eq 7 ] \
  && ok "control: a session's own exit status survives the spawner" \
  || bad "control: a session's own exit status survives the spawner" "state=$GG_PTY_STATE rc=$GG_PTY_RC"

# A session killed before its own last line is `gone`, and carries no status
# at all: a value invented here would be indistinguishable from one a probe
# returned, and every status is one a probe may return.
printf 'echo ABOUT-TO-DIE\nkill -9 "$PPID"\nsleep 5\n' >"$ROOT/die-case.sh"
gg_pty_run 20 "$ROOT/die-case.sh" && [ "$GG_PTY_STATE" = gone ] && [ -z "$GG_PTY_RC" ] \
  && ok "control: a session that dies before its last line reports no status" \
  || bad "control: a session that dies before its last line reports no status" "state=$GG_PTY_STATE rc=$GG_PTY_RC out=$GG_PTY_OUT"

# A reap that could not learn the session's group says so. gg_pty_bounded is
# called directly with a session that writes no group file and a sid path that
# does not exist, which is what a host whose ps answers no -o pgid= leaves
# behind: only the spawner's group is taken, and reporting that as a clean cap
# is the leak the reap exists to name.
printf 'sleep 300\n' >"$ROOT/nosid-body.sh"
{
  printf 'echo GG-PTY-BEGIN\n'
  printf 'bash %q\n' "$ROOT/nosid-body.sh"
} >"$ROOT/nosid-session.sh"
printf -v nosid_cmd '/bin/sh %q' "$ROOT/nosid-session.sh"
gg_pty_bounded 2 "$GG_PTY_FORM" "$nosid_cmd" "$ROOT/absent-sid" "$ROOT/nosid.out"
[ "$GG_PTY_CAPPED" = 1 ] && [ "$GG_PTY_REAPED" = no-group ] \
  && ok "control: a reap with no group to take reports it rather than passing as a cap" \
  || bad "control: a reap with no group to take reports it rather than passing as a cap" "capped=$GG_PTY_CAPPED reaped=$GG_PTY_REAPED"

# And gg_pty_run does not dress that up as a cap. `ps` is shadowed for this
# call alone, which is the host whose ps has no -o pgid=: the session writes
# no group, so only the spawner's is taken. The state says leaked, the cause
# is named, and the scratch tree a live session may hold fds in is left where
# it is rather than deleted out from under it.
mkdir -p "$ROOT/nops"
printf '#!/bin/sh\nexit 1\n' >"$ROOT/nops/ps"
chmod +x "$ROOT/nops/ps"
printf 'trap "" HUP\necho STARTED\nsleep 300 &\necho "$!" >%q\nwait\n' "$ROOT/leak.pid" >"$ROOT/leak-case.sh"
rm -f "$ROOT/leak.pid"
PATH="$ROOT/nops:$PATH" gg_pty_run 2 "$ROOT/leak-case.sh"
[ "$GG_PTY_STATE" = leaked ] && case "$GG_PTY_ERR" in
  *"never recorded its process group"*) true ;;
  *) false ;;
esac \
  && ok "control: a cap whose reap never learned the group is leaked, not capped" \
  || bad "control: a cap whose reap never learned the group is leaked, not capped" "state=$GG_PTY_STATE err=$GG_PTY_ERR"
leaked_dir="${GG_PTY_ERR##*left in place at }"
[ -n "$leaked_dir" ] && [ -d "$leaked_dir" ] \
  && ok "control: and its scratch directory is held back rather than removed" \
  || bad "control: and its scratch directory is held back rather than removed" "dir=$leaked_dir err=$GG_PTY_ERR"
leak_pid="$(cat "$ROOT/leak.pid" 2>/dev/null || true)"
[ -n "$leak_pid" ] && kill -9 -- "-$leak_pid" 2>/dev/null || kill -9 "$leak_pid" 2>/dev/null || true

# A typescript with no marker is handed back whole. Emptying it here would
# turn a spawner that died before the session's first line into a clean,
# quiet, empty pass.
printf 'NOTHING RAN\n' >"$ROOT/no-marker.txt"
gg_pty_capture "$ROOT/no-marker.txt"
[ "$GG_PTY_OUT" = "NOTHING RAN" ] \
  && ok "control: a capture with no marker keeps the whole typescript" \
  || bad "control: a capture with no marker keeps the whole typescript" "out=$GG_PTY_OUT"


# Every path this suite hands to a shell — the spawn strings pty.bash builds
# and the case body pty_call writes — goes through %q. The proof is a scratch
# root whose NAME is a space and a command substitution: unquoted anywhere on
# either layer, the substitution runs. TMPDIR covers pty.bash's two spawn
# sites; SRC covers pty_call's, which is the layer %q at the spawn sites alone
# does not reach.
hostile="$ROOT/a q\$(touch $ROOT/PWNED)x dir"
mkdir -p "$hostile"
printf 'FROM A HOSTILE PATH\n' >"$hostile/src.tsv"
rm -f "$ROOT/PWNED"
if premise_denies_write "$R/tools/dest.tsv" "control: a path that is a space and a command substitution stays a path"; then
  reset_dest ORIGINAL
  TMPDIR="$hostile" pty_call "$COMMON" "$hostile/src.tsv" 'gg_tmpdir; gg_install_file "$SRC" tools/dest.tsv "the fixture"'
  [ "$STATE" = ok ] && [ "$RC" -eq 0 ] && [ "$(cat "$R/tools/dest.tsv")" = "FROM A HOSTILE PATH" ] \
    && ok "control: a path that is a space and a command substitution stays a path" \
    || bad "control: a path that is a space and a command substitution stays a path" "state=$STATE rc=$RC out=$OUT content=$(cat "$R/tools/dest.tsv")"
fi
[ ! -e "$ROOT/PWNED" ] \
  && ok "control: and nothing inside that name was executed" \
  || bad "control: and nothing inside that name was executed" "the substitution ran; $ROOT/PWNED exists"

# A setup failure names its own cause. Everything above has resolved the
# spawner already, so this reaches the scratch-directory branch rather than
# the spawner one, and an operator told "no pty spawner" over an unwritable
# TMPDIR goes looking at devpts for a problem that is not there.
mkdir -p "$ROOT/sealed"
chmod 500 "$ROOT/sealed"
printf 'echo NEVER\n' >"$ROOT/never.sh"
if premise_denies_write "$ROOT/sealed" "control: an unwritable scratch root names the scratch root, not the spawner"; then
  if TMPDIR="$ROOT/sealed" gg_pty_run 20 "$ROOT/never.sh"; then
    bad "control: an unwritable scratch root names the scratch root, not the spawner" "gg_pty_run returned 0; state=$GG_PTY_STATE err=$GG_PTY_ERR"
  else
    case "$GG_PTY_ERR" in
      *"scratch directory"*) ok "control: an unwritable scratch root names the scratch root, not the spawner" ;;
      *) bad "control: an unwritable scratch root names the scratch root, not the spawner" "err=$GG_PTY_ERR" ;;
    esac
  fi
fi

# The same sealed root on the FIRST call, before any grammar is resolved.
# That is gg_pty_form's own scratch failure, a third return site the case
# above cannot reach: it runs after the memo is set, so it only ever reaches
# gg_pty_run's. The memo is cleared and restored around it, because a form
# recorded from a scratch fault would answer for the rest of the run.
if premise_denies_write "$ROOT/sealed" "control: a sealed scratch root on the first call names the scratch root too"; then
  gg_form_memo="$GG_PTY_FORM"
  GG_PTY_FORM=""
  if TMPDIR="$ROOT/sealed" gg_pty_run 20 "$ROOT/never.sh"; then
    bad "control: a sealed scratch root on the first call names the scratch root too" "gg_pty_run returned 0; state=$GG_PTY_STATE err=$GG_PTY_ERR"
  else
    case "$GG_PTY_ERR" in
      *"scratch directory"*) ok "control: a sealed scratch root on the first call names the scratch root too" ;;
      *) bad "control: a sealed scratch root on the first call names the scratch root too" "err=$GG_PTY_ERR" ;;
    esac
  fi
  # And no memo was recorded for it: a scratch fault is not the spawner's
  # answer, so a later call with TMPDIR working probes again.
  [ -z "$GG_PTY_FORM" ] \
    && ok "control: and records no spawner verdict for a fault that is not the spawner's" \
    || bad "control: and records no spawner verdict for a fault that is not the spawner's" "GG_PTY_FORM=$GG_PTY_FORM err=$GG_PTY_ERR"
  GG_PTY_FORM="$gg_form_memo"
fi
chmod 700 "$ROOT/sealed"

# The form probe runs under the same cap as every other spawn here. A `script`
# that blocks allocating a pty rather than failing would otherwise wedge the
# whole suite before a single case ran — the rule this file states, dropped by
# the code that decides whether the file can run at all.
#
# The stub blocks on the util-linux grammar and fails fast on the BSD one, so
# the probe costs one cap. The bound around it belongs to the CASE, not to the
# helper: without it a helper that lost its cap would hang here instead of
# reporting, which is the shape this whole suite exists to refuse.
mkdir -p "$ROOT/stub"
cat >"$ROOT/stub/script" <<'STUB'
#!/bin/sh
case "$1" in -qec) exec sleep 300 ;; esac
exit 1
STUB
chmod +x "$ROOT/stub/script"
set -m
env PATH="$ROOT/stub:$PATH" bash -c '
  . "$1"
  . "$2"
  gg_pty_form || true
  printf "%s\n" "$GG_PTY_FORM"
' _ "$TEST_DIR/lib/harness.bash" "$TEST_DIR/lib/pty.bash" >"$ROOT/form-probe.out" 2>&1 &
probe_pid=$!
set +m
waited=0
while kill -0 "$probe_pid" 2>/dev/null && [ "$waited" -lt 300 ]; do
  sleep 0.1
  waited=$((waited + 1))
done
if kill -0 "$probe_pid" 2>/dev/null; then
  kill -9 -- "-$probe_pid" 2>/dev/null || kill -9 "$probe_pid" 2>/dev/null || true
  wait "$probe_pid" 2>/dev/null || true
  bad "control: a spawner that blocks resolves to none inside the cap" "the probe was still running after 30s; out=$(cat "$ROOT/form-probe.out")"
else
  wait "$probe_pid" 2>/dev/null || true
  [ "$(tail -n 1 "$ROOT/form-probe.out")" = none ] \
    && ok "control: a spawner that blocks resolves to none inside the cap" \
    || bad "control: a spawner that blocks resolves to none inside the cap" "$(cat "$ROOT/form-probe.out")"
fi

printf '\n%d passed, %d failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
