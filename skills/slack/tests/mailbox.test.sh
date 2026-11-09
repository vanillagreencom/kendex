#!/usr/bin/env bash
# LaneMail answer failures, event field validation, a read directive from an
# older producer, and root-error isolation.
# Controls keep the malformed producer and remove each reader rule.
set -uo pipefail
. "$(dirname "$0")/lib/harness.sh"

# The driver imports the production runner. Its parent bounds even a pump
# that never yields; the target's completion marker proves excess was drained.
cat > "$SK_TMP/runner-check.py" <<'PY'
import json, os, pathlib, signal, socket, subprocess, sys, time, tracemalloc
sys.path.insert(0, sys.argv[1])
from mailbox import LaneMail, RunTimeout, run_bounded
import mailbox
root, row = pathlib.Path(sys.argv[2]), sys.argv[3]
C = 52096
if row == "capture":
    marker = root / "drained"
    if marker.exists(): marker.unlink()
    program = '''import os, pathlib, sys, threading
chunk = b'x' * 4096
barrier = threading.Barrier(2)
def emit(fd):
    barrier.wait()
    for _ in range(4096):
        os.write(fd, chunk)
t = threading.Thread(target=emit, args=(2,))
t.start()
emit(1)
t.join()
pathlib.Path(sys.argv[1]).write_text('drained')
'''
    tracemalloc.start()
    tracemalloc.reset_peak()
    result = run_bounded([sys.executable, "-c", program, str(marker)], root, 5, command_output_limit=C)
    _, peak = tracemalloc.get_traced_memory()
    tracemalloc.stop()
    assert result.returncode == 0 and marker.read_text() == "drained"
    assert result.stdout == result.stderr == "x" * C
    assert result.stdout_cut and result.stderr_cut
    print("capture: peak=%d bound=2723872 retained=104192" % peak, flush=True)
    assert peak <= 2723872, "pre-accumulation allocation bound"
elif row == "contracts":
    for n in (0, C - 1, C, C + 1):
        result = run_bounded([sys.executable, "-c", "import os,sys; n=int(sys.argv[1]); os.write(1,b'x'*n); os.write(2,b'y'*n)", str(n)], root, 5, command_output_limit=C)
        assert (result.stdout, result.stderr, result.stdout_cut, result.stderr_cut) == ("x" * min(n,C), "y" * min(n,C), n > C, n > C)
    result = run_bounded([sys.executable, "-c", "import os; os.write(1,b'a\\r\\n\\xff\\rb')"], root, 5, command_output_limit=C)
    assert result.stdout == "a\n\ufffd\nb"
    args = ["", "; not shell", "caf\u00e9", "bad\udcff"]
    program = "import json,os,sys; print(json.dumps([sys.argv[1:],os.getcwd(),sys.stdin.read(),os.environ['EXACT']]))"
    result = run_bounded([sys.executable, "-c", program, *args], root, 5, env={"EXACT":"caller", "LC_CTYPE":"C", "PATH":os.defpath}, command_output_limit=C)
    assert json.loads(result.stdout) == [args, str(root), "", "caller"]
    # Larger than pipe capacity: request writes and child reads must progress
    # together, preserving the original environment rather than Python's copy.
    exact = {"EXACT": "z" * 60000, "LC_CTYPE":"C", "PATH":os.defpath}
    import shutil
    result = run_bounded([shutil.which("env")],root,5,env=exact,command_output_limit=100000)
    assert dict(line.split("=",1) for line in result.stdout.splitlines()) == exact
    for command, code in (("raise SystemExit(3)",3), ("import os,signal; os.kill(os.getpid(),signal.SIGTERM)",-15), ("import os,signal; os.kill(os.getpid(),signal.SIGKILL)",-9)):
        result = run_bounded([sys.executable,"-c",command],root,5,command_output_limit=C)
        assert result.returncode == code
    for path in (root / "missing", root / "non-executable"):
        if path.name == "non-executable":
            path.write_text("no exec")
        try:
            run_bounded([str(path)],root,5,command_output_limit=C)
        except OSError as error:
            assert error.operation == "exec" and error.errno in (2,13)
        else:
            raise AssertionError("exec error became target exit")
    # LaneMail uses whole output, including the final receipt after the cap.
    script = root / ".agents/skills/mailbox/scripts/lane-mail"
    script.parent.mkdir(parents=True)
    script.write_text('#!' + sys.executable + '\nprint("x" * 60000 + " id=final")\n')
    script.chmod(0o755)
    code, out, err = LaneMail(root)._run("events")
    assert code == 0 and len(out) > C and out.endswith("id=final\n") and err == ""
    # The configured command's descendant ignores TERM and holds both pipes
    # after its leader exits. Its connection closes only on process exit;
    # a one-byte release lets the test clean up a surviving control safely.
    program = '''import os, signal, socket, sys, time
if os.fork() == 0:
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    time.sleep(float(sys.argv[2]))
    hold = socket.create_connection(('127.0.0.1', int(sys.argv[1])))
    os.write(1, b'descendant-ready\\n')
    os.write(2, b'descendant-ready\\n')
    hold.sendall(b'R')
    hold.recv(1)
    os._exit(0)
'''
    mailbox.LANE_MAIL_CLEANUP_SECONDS = .05
    with socket.socket() as listener:
        listener.bind(('127.0.0.1', 0))
        listener.listen()
        listener.settimeout(max(0, float(sys.argv[4]) - time.monotonic()))
        original_read, original_clock = mailbox.os.read, time.monotonic
        started, ready = original_clock(), False
        # Freeze bootstrap timing, then await the target's readiness before
        # checking the run budget. The parent's deadline bounds startup.
        mailbox.time.monotonic = lambda: original_clock() if ready else started
        def ready_read(fd, n):
            global hold
            global ready
            value = original_read(fd, n)
            if value[:1] == b'P':
                ready = True
                hold = listener.accept()[0]
                hold.settimeout(max(0, float(sys.argv[4]) - original_clock()))
                assert hold.recv(1) == b'R', "descendant readiness"
            return value
        timeout_error = None
        mailbox.os.read = ready_read
        try:
            run_bounded([sys.executable,"-c",program,str(listener.getsockname()[1]),sys.argv[5]],root,.2,command_output_limit=C)
        except RunTimeout as error:
            timeout_error = error
        finally:
            mailbox.os.read, mailbox.time.monotonic = original_read, original_clock
        with hold:
            hold.settimeout(1)
            ended = False
            try:
                assert timeout_error is not None, "descendant pipe hold never timed out"
                assert timeout_error.output == timeout_error.stderr == 'descendant-ready\n'
                try:
                    ended = hold.recv(1) == b''
                except socket.timeout:
                    pass
                assert ended, "descendant survived runner cleanup"
            finally:
                if not ended:
                    hold.sendall(b'x')
                    assert hold.recv(1) == b'', "descendant fixture teardown"
elif row == "deadline":
    # Inject setup elapsed time at prepared status, without a real-clock wait.
    clock = [0.0]
    original_read = mailbox.os.read
    original_clock = mailbox.time.monotonic
    def read(fd, n):
        value = original_read(fd,n)
        if value[:1] == b"P": clock[0] = 11.0
        return value
    mailbox.time.monotonic = lambda: clock[0]
    mailbox.os.read = read
    try:
        try:
            run_bounded([sys.executable,"-c","print('deadline')"],root,10,command_output_limit=C)
        except RunTimeout as error:
            assert error.cmd[0] == sys.executable and error.timeout == 10
        else:
            raise AssertionError("bootstrap elapsed time renewed target deadline")
    finally:
        mailbox.time.monotonic = original_clock
        mailbox.os.read = original_read
    print("contracts: passed")
PY
runner_check() {
  python3 - "$SK_TMP/runner-check.py" "${SK_BIN%/*}/lib" "$SK_TMP/runner-${2:-$1}" "$1" "${3:-0}" <<'PY'
import os, pathlib, signal, subprocess, sys, time
pathlib.Path(sys.argv[3]).mkdir(exist_ok=True)
proc = subprocess.Popen([sys.executable, *sys.argv[1:5], str(time.monotonic() + 20), sys.argv[5]], start_new_session=True)
try:
    sys.exit(proc.wait(timeout=20))
except subprocess.TimeoutExpired:
    os.killpg(proc.pid, signal.SIGKILL)
    proc.wait()
    sys.exit("runner-check: parent deadline")
PY
}
runner_check capture
assert_eq "$?" 0 'both streams stay within the traced capture envelope while the producer completes'
runner_check contracts
assert_eq "$?" 0 'runner preserves target inputs, direct receipts and exit evidence'
runner_check contracts slow-start 1.1
assert_eq "$?" 0 'runner cleanup waits for a descendant that starts beyond the old accept window'
python3 - "$SK_TMP/runner-check.py" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = 'listener.settimeout(max(0, float(sys.argv[4]) - time.monotonic()))'
assert s.count(old) == 1
p.with_name('runner-check-ready.py').write_text(s)
p.write_text(s.replace(old, 'listener.settimeout(1)'))
PY
runner_check contracts slow-control 1.1 > "$SK_TMP/slow-control.out" 2>&1
assert_eq "$?" 1 'control: the fixed accept window rejects a slow descendant'
assert_has "$(cat "$SK_TMP/slow-control.out")" 'TimeoutError: timed out' 'the slow-start control reaches the accept deadline'
mv "$SK_TMP/runner-check-ready.py" "$SK_TMP/runner-check.py"
runner_check deadline
assert_eq "$?" 0 'bootstrap setup consumes the original execution deadline'
sk_mutant cleanup-no-kill mailbox.py 'os\.killpg\(proc\.pid, sig\)' 'os.killpg(proc.pid, sig) if sig != signal.SIGKILL else None'
runner_check contracts cleanup-control > "$SK_TMP/cleanup-control.out" 2>&1
assert_eq "$?" 1 'control: omitting KILL fails the descendant cleanup assertion before test teardown'
assert_has "$(cat "$SK_TMP/cleanup-control.out")" 'AssertionError: descendant survived runner cleanup' 'the cleanup control reaches the descendant EOF assertion'
sk_bin_reset
# A pump-only renewal is still refused by finish's entry-deadline check.
# Give the mutant a fresh full budget after preparation at BOTH observations;
# keep the real pump/exec operations and the same independent timeout assertion.
sk_copy deadline-renew
python3 - "${SK_BIN%/*}/lib/mailbox.py" <<'PY'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = 'until - time.monotonic()'
assert s.count(old) == 2
new = s.replace(old, '(timeout if status[:1] == b"P" else until - time.monotonic())')
assert new != s
p.write_text(new)
PY
runner_check deadline > "$SK_TMP/deadline-control.out" 2>&1
assert_eq "$?" 1 'control: renewing the target deadline fails the same injected-time assertion'
assert_has "$(cat "$SK_TMP/deadline-control.out")" 'bootstrap elapsed time renewed target deadline' 'the deadline control reaches the original-deadline assertion'
sk_bin_reset
sk_mutant capture-late mailbox.py '    def add\(self, chunk: bytes\) -> None:[\s\S]*?\n    def text' '    def add(self, chunk: bytes) -> None:\n        if self.used == 0:\n            self.data = bytearray()\n        self.data.extend(chunk)\n        self.used = min(len(self.data), self.limit)\n        self.cut = len(self.data) > self.limit\n\n    def text'
runner_check capture > "$SK_TMP/capture-control.out" 2>&1
assert_eq "$?" 1 'control: whole-output accumulation fails the same traced allocation assertion'
assert_has "$(cat "$SK_TMP/capture-control.out")" 'pre-accumulation allocation bound' 'the capture control fails on allocation, not final lengths or completion'
sk_bin_reset

sk_fake_start --page 2
echo "=== slack mailbox events ==="

# A real send stalls in jq under orch's directory mutex. Only the existing
# lock owner's TERM/EXIT handlers may release it before the next delivery.
for variant in normal hard-kill no-timeout; do
  LOCKED="$(sk_new_root "mutex-timeout-$variant")"
  sk_bind "$LOCKED"
  sk_poll "$LOCKED"
  LOCKED_CH="$(sk_channel "$LOCKED")"
  LOCKED_TS="$(sk_inject "$LOCKED_CH" U001 'After the stalled scan.')"
  sk_stall_delivery "$LOCKED"
  if [ "$variant" = hard-kill ]; then
    sk_mutant mail-hard-kill mailbox.py '\(signal.SIGTERM, signal.SIGKILL\)' '(signal.SIGKILL,)'
  elif [ "$variant" = no-timeout ]; then
    sk_mutant mail-timeout mailbox.py 'self\.root, LANE_MAIL_TIMEOUT_SECONDS\)' 'self.root, None)'
  fi
  sk_poll "$LOCKED" # Real wait: timeout after the shipped send holds its mutex.
  if [ "$variant" = no-timeout ]; then
    sk_assert_red "$RC=$ERR1" "1=slack: lane-mail-failed=timeout=30 command=send root=$LOCKED" 'control: removing the bound lets the stalled send finish'
    sk_bin_reset
    continue
  fi
  assert_eq "$RC=$ERR1" "1=slack: lane-mail-failed=timeout=30 command=send root=$LOCKED" "$variant: stalled send keeps its named timeout"
  assert_eq "$(cat "$LOCKED/tmp/scan-locked")" "locked" "$variant: the guard reached the real directory mutex without flock"
  MUTEX="$(sk_box "$LOCKED")/to-lane.jsonl.d"
  RELEASED=no
  [ -d "$MUTEX" ] || RELEASED=yes
  sk_poll "$LOCKED"
  DELIVERIES="$(jq -s --arg key "$LOCKED_CH:$LOCKED_TS" '[.[] | select(.delivery_id == $key)] | length' "$(sk_box "$LOCKED")/to-lane.jsonl")"
  printf 'mailbox: mutex-recovery=%s=%s=%s variant=%s\n' "$RELEASED" "$RC" "$DELIVERIES" "$variant"
  if [ "$RC" -ne 0 ]; then
    printf 'mailbox: recovery-poll-failed=%s variant=%s\n%s\n' "$RC" "$variant" "$ERR" >&2
  fi
  if [ "$variant" = normal ]; then
    assert_eq "$RELEASED=$RC=$DELIVERIES" "yes=0=1" 'timeout releases the mutex and the next poll acquires it to deliver once'
  else
    sk_assert_red "$RELEASED=$RC=$DELIVERIES" "yes=0=1" 'control: immediate hard kill fails the same mutex recovery assertion'
  fi
  sk_bin_reset
done

# A failed jq closure scan must stop a real owner answer, not turn it into
# a directive. The wrapper leaves the ask read and all envelope writes real.
SCAN="$(sk_new_root closure-scan)"
sk_bind "$SCAN"
sk_lm "$SCAN" ask --item overseer --to owner --file "$(sk_text scan 'Scan?')" --options a,b --recommend a >/dev/null
sk_poll "$SCAN"
SCAN_CH="$(sk_channel "$SCAN")"
SCAN_TS="$(sk_state ".messages.${SCAN_CH}[-1].ts")"
mkdir -p "$SCAN/tmp/fault-bin"
REAL_JQ="$(command -v jq)" || exit 1
python3 - "$SCAN" "$REAL_JQ" "$SK_LANE_MAIL" <<'PY'
import pathlib, shlex, sys
root, jq, mail = pathlib.Path(sys.argv[1]), shlex.quote(sys.argv[2]), shlex.quote(sys.argv[3])
fault = root / "tmp/fault-bin/jq"
fault.write_text('#!/usr/bin/env bash\nset -euo pipefail\nfor arg in "$@"; do\ncase "$arg" in\n*\'select(overseer_mail_class == "close"\'*) printf "jq-fault=closure\\n" >&2; exit 5 ;;\nesac\ndone\nexec ' + jq + ' "$@"\n')
fault.chmod(0o755)
scripts = root / ".agents/skills/mailbox/scripts"
scripts.unlink()
scripts.mkdir()
entry = scripts / "lane-mail"
entry.write_text('#!/usr/bin/env bash\nset -euo pipefail\nexec env PATH=' + shlex.quote(str(fault.parent)) + ':"$PATH" ' + mail + ' "$@"\n')
entry.chmod(0o755)
PY
sk_store_fixture "$SCAN" ""
SCAN_REPLY="$(sk_inject "$SCAN_CH" U001 b "$SCAN_TS")"
sk_poll "$SCAN"
assert_eq "$RC=$ERR1" "1=slack: lane-mail-failed=lane-mail: mail-read-failed=overseer" "a failed closure scan stops owner delivery"
assert_has "$ERR" "jq-fault=closure" "the relay retains the closure scan diagnostic"
assert_eq "$(jq -s --arg key "$SCAN_CH:$SCAN_REPLY" '[.[] | select(.delivery_id == $key)] | length' "$(sk_box "$SCAN")/to-lane.jsonl")" "0" "a scan failure delivers neither an answer nor a directive"
sk_mutant answer-diagnostic mailbox.py '(return "resolved-already", first.rsplit\("id=", 1\)\[1\].strip\(\)\n        )raise Refusal\("lane-mail-failed", err.strip\(\) or first\)' '\1raise Refusal("lane-mail-failed", first)'
sk_poll "$SCAN"
CONTROL_FAIL="$SK_FAIL"
CONTROL_RC=0
CONTROL_OUT="$(
  assert_has "$ERR" "jq-fault=closure" "the relay retains the closure scan diagnostic"
  [ "$SK_FAIL" = "$CONTROL_FAIL" ]
)" || CONTROL_RC=$?
assert_eq "$CONTROL_RC" "1" "control: truncating the guard failure loses its dependency diagnostic"
sk_bin_reset

# --- older event producers and malformed envelope fields ----------------------
# lane-mail's older events output lacks positions. Corrupt mailbox objects
# can also reach the relay because lane-mail filters JSON syntax, not fields.
while IFS='|' read -r name field expression posted; do
  R="$(sk_new_root "field-$name")"
  sk_bind "$R"
  sk_poll "$R"
  sk_lm "$R" notice --item overseer --to owner --file "$(sk_text "$name-bad" 'Malformed field.')" >/dev/null
  BAD_ID="$(tail -n 1 "$(sk_box "$R")/to-overseer.jsonl" | jq -r .id)"
  sk_lm "$R" notice --item overseer --to owner --file "$(sk_text "$name-good" 'Healthy envelope.')" >/dev/null
  sk_event_filter "$R" "if .text == \"Malformed field.\" then $expression else . end"
  if [ "$field" = line ] || [ "$field" = count ]; then
    sk_jarvis_read "$R" 1
    printf '{"t":"hold","at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$(sk_journal "$R")"
  fi
  sk_poll "$R"
  CH="$(sk_channel "$R")"
  [ "$field" != id ] || BAD_ID=unknown
  assert_eq "$RC=$(asks "$CH" 'Malformed field.')=$(asks "$CH" 'Healthy envelope.')=$ERR" \
    "0=$posted=1=slack: envelope-field=$R id=$BAD_ID field=$field" "$name: only the invalid envelope field degrades or skips; the next envelope posts"
done <<'ROWS'
missing-line|line|del(.line)|1
bad-line|line|.line = "one"|1
missing-count|count|del(.count)|1
bad-count|count|.count = []|1
missing-id|id|del(.id)|0
missing-at|at|del(.at)|0
bad-at|at|.at = "not-a-date"|0
missing-text|text|del(.text)|0
bad-text|text|.text = 17|0
bad-kind|kind|.kind = []|0
bad-box|box|.box = {}|0
unknown-kind|kind|.kind = "unknown"|0
unknown-box|box|.box = "unknown"|0
bad-options|options|.options = [17]|0
bad-deadline|deadline|.deadline = "not-a-date"|0
bad-draft|draft|.draft = "Ship it."|0
draft-no-text|draft|.draft = {recipient: "a@example.com", medium: "email"}|0
draft-empty-text|draft|.draft = {recipient: "a@example.com", medium: "email", text: ""}|0
ROWS

LEGACY="$(sk_new_root legacy-events)"
HEALTHY="$(sk_new_root healthy-events)"
for R in "$LEGACY" "$HEALTHY"; do
  sk_bind "$R"
  sk_poll "$R"
  sk_lm "$R" notice --item overseer --to owner --file "$(sk_text "$(basename "$R")" 'Multi-root notice.')" >/dev/null
done
sk_event_filter "$LEGACY" 'del(.line, .count)'
sk_run -- listen --once --root "$LEGACY" --root "$HEALTHY"
assert_eq "$RC=$(asks "$(sk_channel "$LEGACY")" 'Multi-root notice.')=$(asks "$(sk_channel "$HEALTHY")" 'Multi-root notice.')" \
  "0=1=1" "a legacy root without line or count and a healthy root both post"
LEGACY_ID="$(jq -r .id "$(sk_box "$LEGACY")/to-overseer.jsonl")" || exit 1
printf -v LEGACY_WARNINGS 'slack: envelope-field=%s id=%s field=line\nslack: envelope-field=%s id=%s field=count' \
  "$LEGACY" "$LEGACY_ID" "$LEGACY" "$LEGACY_ID"
HELP_RC=0
sk_help_field || HELP_RC=$?
assert_eq "$HELP_RC" "0" "help advertises the envelope-field diagnostic reached by legacy events"
RC=0
WARNINGS="$(sk_legacy_warnings "$LEGACY" "$LEGACY_WARNINGS")" || RC=$?
assert_eq "$RC=$WARNINGS" "0=$LEGACY_WARNINGS" "reading legacy events twice through one LaneMail warns once per root, id and field"

# Keep HELP and the runtime diagnostic intact; conceal only its help output.
sk_mutant help-field main.py 'sys\.stdout\.write\(HELP\)' 'sys.stdout.write(HELP.replace("envelope-field=ROOT id=ID field=FIELD", ""))'
HELP_RC=0
sk_help_field || HELP_RC=$?
assert_eq "$HELP_RC" "1" "control: concealing the help key fails the help assertion while diagnostics remain"
RC=0
WARNINGS="$(sk_legacy_warnings "$LEGACY" "$LEGACY_WARNINGS")" || RC=$?
assert_eq "$RC=$WARNINGS" "0=$LEGACY_WARNINGS" "control: the hidden help key leaves legacy envelope diagnostics unchanged"
sk_bin_reset

# A real mailbox byte read can fail outside envelope validation. The healthy
# root must post even when the first root has invalid UTF-8 data.
BROKEN="$(sk_new_root broken-events)"
sk_bind "$BROKEN"
sk_poll "$BROKEN"
mkdir -p "$(sk_box "$BROKEN")"
touch "$(sk_box "$BROKEN")/to-overseer.jsonl"
printf '\377\n' > "$(sk_box "$BROKEN")/to-overseer.jsonl.numbering"
rm -- "$BROKEN/tmp/slack/status.json"
mkdir "$BROKEN/tmp/slack/status.json"
sk_lm "$HEALTHY" notice --item overseer --to owner --file "$(sk_text root-error 'Healthy after root error.')" >/dev/null
sk_run -- listen --once --root "$BROKEN" --root "$HEALTHY"
assert_eq "$RC=$(asks "$(sk_channel "$HEALTHY")" 'Healthy after root error.')=$(printf '%s\n' "$ERR" | grep -c '^slack: lane-mail-failed=')" \
  "1=1=1" "a root read error reports once and does not stop healthy-root routing"
assert_has "$ERR1" "slack: lane-mail-failed=" "the root error keeps the mailbox read refusal"
assert_has "$ERR1" "root=$BROKEN" "the root error names the failed root"

sk_mutant repeated-fields mailbox.py 'if pair not in self\.reported_fields:' 'if True:'
RC=0
WARNINGS="$(sk_legacy_warnings "$LEGACY" "$LEGACY_WARNINGS")" || RC=$?
assert_eq "$RC=$WARNINGS" "1=$LEGACY_WARNINGS"$'\n'"$LEGACY_WARNINGS" \
  "control: bypassing the repeat check keeps diagnostics and fails the once-per-field assertion"
sk_bin_reset

sk_mutant missing-line relay.py 'envelope\["line"\] is not None and ' ''
sk_lm "$LEGACY" notice --item overseer --to owner --file "$(sk_text line-control 'Line control.')" >/dev/null
sk_poll "$LEGACY"
assert_eq "$RC=$(asks "$(sk_channel "$LEGACY")" 'Line control.')" "1=0" "control: requiring line again fails the legacy notice poll"
sk_bin_reset

# An older producer's directive, its event without line, swaps for a check by
# its receipts row once the overseer's inbox reads it, and the poll that swaps
# it still posts a notice. Controls: the line guard gone fails that poll, and
# the receipts rows unread leave the read directive at eyes.
while IFS='|' read -r mode want; do
  R="$(sk_new_root "legacy-read-$mode")"
  sk_bind "$R"
  sk_poll "$R"
  sk_event_filter "$R" 'del(.line, .count)'
  CH="$(sk_channel "$R")"
  DIRECTIVE="$(sk_inject "$CH" U001 'Legacy directive.')"
  sk_poll "$R"
  SEEN="$(sk_reactions "$CH" "$DIRECTIVE")"
  sk_lm "$R" inbox --item overseer >/dev/null
  sk_lm "$R" notice --item overseer --to owner --file "$(sk_text "legacy-read-$mode" 'Legacy read notice.')" >/dev/null
  case "$mode" in
    line-guard) sk_mutant legacy-line-guard relay.py '\be\["line"\] is not None and ' '' ;;
    receipts) sk_mutant legacy-receipts relay.py 'return read \| \{e\["id"\]' 'return {e["id"]' ;;
  esac
  sk_poll "$R"
  assert_eq "$RC=$SEEN=$(sk_reactions "$CH" "$DIRECTIVE")=$(asks "$CH" 'Legacy read notice.')" "$want" \
    "$mode: a read directive from a producer without line swaps by its receipts row, and its poll posts"
  sk_bin_reset
done <<'ROWS'
production|0=eyes=white_check_mark=1
line-guard|1=eyes=eyes=0
receipts|0=eyes=eyes=1
ROWS

sk_mutant invalid-field mailbox.py 'if invalid:' 'if False:'
sk_poll "$SK_TMP/field-bad-at"
assert_eq "$RC" "1" "control: routing a malformed field again fails the envelope poll"
sk_bin_reset

sk_mutant field-type mailbox.py 'if not isinstance\(value, str\) or \(field != "text" and required and not value\):' 'if False:'
sk_poll "$SK_TMP/field-bad-text"
assert_eq "$RC" "1" "control: accepting a malformed text type again fails the poll"
sk_bin_reset

sk_mutant field-date mailbox.py 'except ValueError:\n                        self.bad_field\(envelope.get\("id"\), field\)\n                        invalid = True' 'except ValueError:\n                        self.bad_field(envelope.get("id"), field)\n                        invalid = False'
sk_poll "$SK_TMP/field-bad-at"
assert_eq "$RC" "1" "control: accepting a malformed timestamp again fails the poll"
sk_bin_reset

sk_mutant field-options mailbox.py 'if not isinstance\(options, list\) or not all\(isinstance\(option, str\) for option in options\):' 'if False:'
sk_poll "$SK_TMP/field-bad-options"
assert_eq "$(asks "$(sk_channel "$SK_TMP/field-bad-options")" 'Malformed field.')" "1" "control: accepting malformed options posts the invalid envelope"
sk_bin_reset

sk_mutant field-draft mailbox.py 'if "draft" in envelope and not \(' 'if False and not ('
sk_poll "$SK_TMP/field-bad-draft"
assert_eq "$(asks "$(sk_channel "$SK_TMP/field-bad-draft")" 'Malformed field.')" "1" "control: accepting a malformed draft posts the invalid envelope"
sk_bin_reset

sk_mutant field-draft-keys mailbox.py 'all\(isinstance\(draft\.get\(key\), str\) and draft\[key\] for key in \("recipient", "medium", "text"\)\)' 'True'
for name in draft-no-text draft-empty-text; do
  sk_poll "$SK_TMP/field-$name"
  assert_eq "$(asks "$(sk_channel "$SK_TMP/field-$name")" 'Malformed field.')" "1" "control: a draft object missing a key or holding an empty one posts the invalid envelope ($name)"
done
sk_bin_reset

sk_mutant missing-count relay.py 'if None in counts:' 'if False:'
sk_jarvis_read "$SK_TMP/field-missing-count" 1
printf '{"t":"hold","at":"%s"}\n' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >> "$(sk_journal "$SK_TMP/field-missing-count")"
sk_poll "$SK_TMP/field-missing-count"
assert_eq "$RC" "1" "control: requiring count again fails a legacy resume poll"
sk_bin_reset

sk_mutant field-choice mailbox.py 'FIELD_CHOICES = .*' 'FIELD_CHOICES = {}'
sk_poll "$SK_TMP/field-unknown-kind"
assert_eq "$ERR" "" "control: unknown field choices no longer get a keyed diagnostic"
sk_bin_reset

sk_mutant root-isolation relay.py '(    def poll_once\(self\) -> bool:[\s\S]*?\n            )except Exception as err:\n                self.root_failed\(root, err\)\n                clean = False' '\1except Exception as err:\n                raise err'
sk_lm "$HEALTHY" notice --item overseer --to owner --file "$(sk_text root-control 'Root control.')" >/dev/null
sk_run -- listen --once --root "$BROKEN" --root "$HEALTHY"
assert_eq "$RC=$(asks "$(sk_channel "$HEALTHY")" 'Root control.')" "2=0" "control: the root error escapes and prevents the healthy root from posting"
sk_bin_reset

sk_mutant status-isolation relay.py 'except Exception as status_err:' 'except Refusal as status_err:'
sk_run -- listen --once --root "$BROKEN" --root "$HEALTHY"
assert_eq "$RC=$(asks "$(sk_channel "$HEALTHY")" 'Root control.')" "1=0" "control: a failed error-status write prevents the healthy root from posting"
sk_bin_reset

sk_summary
