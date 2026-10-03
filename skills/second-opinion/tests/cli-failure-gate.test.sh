#!/usr/bin/env bash
# The CLI-failure gate: when the external CLI produces no review at all (a
# non-zero exit, a timeout, an empty response on a zero exit) a review or
# audit run joins the no-verdict class: exit 5, the partial output and the
# CLI's own cause preserved as <output>.failed.json (or a record in the
# artifact home without --output), the cause echoed on stderr from whichever
# stream carried it; a CLI that died to a signal is a kill, exit 6, the signal
# named in the record and the report; challenge and quick keep the generic
# exit 1. A Claude result envelope is read for its result text; one with no
# result text, or flagged is_error, names its own fields as the cause on the
# first call and the format retry alike. Record
# placement never changes the outcome: a home that cannot be created or
# written falls back to system temp loudly, and when nothing is writable the
# cause is reported inline with the exit class kept. One table, a row per
# scenario.
# shellcheck source=lib/stub-cli-world.bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/stub-cli-world.bash"
# shellcheck source=lib/install.bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/install.bash"

# The must-fail controls, one per rule of the envelope gate. Each control is
# a hermetic copy of the script, scripts/second-opinion-<name>, that keeps one
# line's text and disarms it; every row its label pattern selects turns red.
# A \n in a line is a line break.
# name|the line|its disarmed form|label pattern
CONTROLS='unwrap|    unwrap_result_envelope|    : unwrap_result_envelope|*envelope*
empty-text|if [[ -z "$text" |if [[ -n "" && -z "$text" |a success envelope*
is-error|"$failed" == true ]]; then|"$failed" == never ]]; then|an is_error envelope whose result is API*
cause-order|  if [[ -n "$RESULT_ENVELOPE_CAUSE" ]]; then\n    CLI_FAILURE_CAUSE=|  if [[ -n "$RESULT_ENVELOPE_CAUSE" && ! -s "$STDERR_TMP" ]]; then\n    CLI_FAILURE_CAUSE=|a non-zero exit carrying*
classify|attempt_cause="result-|: attempt_cause="result-|a success envelope*
answer-guard|[[ -z "$RESULT_ENVELOPE_CAUSE" ]] && $REVIEW_LIKE|[[ -z "${RESULT_ENVELOPE_CAUSE:+}" ]] && $REVIEW_LIKE|an is_error envelope whose result is a whole review*
retry-zero|      elif [[ $attempt_cause == result-* ]]; then|      elif false && [[ $attempt_cause == result-* ]]; then|a format retry*exit 0*
retry-exit|        if [[ -n "$RESULT_ENVELOPE_CAUSE" ]]; then|        if false && [[ -n "$RESULT_ENVELOPE_CAUSE" ]]; then|a format retry*exit 1*
gate-cause|  select_cli_failure_cause "$RESULT"\n  print_cli_failure_cause\n  exit 1|  select_cli_failure_cause "$RESULT"\n  : print_cli_failure_cause\n  : exit 1|a *-mode *'
PROJ="$TMP_ROOT/proj"
mkdir -p "$PROJ/skills"
git init -q "$PROJ"
second_opinion_install "$SKILL_DIR" "$PROJ/skills"
SCRIPTS="$PROJ/skills/second-opinion/scripts"
while IFS='|' read -r name old new _; do
  cp -- "$SCRIPTS/second-opinion" "$SCRIPTS/second-opinion-$name"
  python3 - "$SCRIPTS/second-opinion-$name" "${old//\\n/$'\n'}" "${new//\\n/$'\n'}" <<'PY'
import pathlib, sys
path, old, new = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3]
assert not path.is_symlink()
text = path.read_text()
assert text.count(old) == 1, (old, text.count(old))
changed = text.replace(old, new)
assert changed != text
path.write_text(changed)
PY
done <<<"$CONTROLS"
suite_word() {
  case "$1" in
    script:*) W_SCRIPT="$SCRIPTS/second-opinion-${1#script:}" ;;
    *) echo "UNKNOWN-WORD: $1" >&2; exit 2 ;;
  esac
}
# The cause a named envelope records, as a record's row renders it.
result_cause() {
  local cause
  cause="$(envelope "$1-cause")"
  printf '%s' "${cause//$'\n'/;}"
}

# A row's world starts from these: a review writing to the row's output path,
# the CLI exiting 0 with a good review and an empty stderr.
DEFAULTS="output:out rc:0 stdout:good stderr:-"

CLEAN="home=absent tmp=0 dirty=-"
# a preserved sidecar: the reason, the cause's source, the cause
FAILED_EXIT_STDERR="failed(exited with code 1|claude stderr|quota)"

# label|world|argv|rc|out|err|calls files home tmp dirty
ROWS="
a non-zero exit with the cause on stderr exits 5, preserves the record with the cause, names it on stderr, and does not retry|rc:1 stdout:- stderr:quota|review|5|-|header:review failed:exit:out:1 cause:stderr preserved:out|calls=1 files=out.failed.json=$FAILED_EXIT_STDERR $CLEAN
an empty response on a zero exit is the same class, with the empty-response reason|rc:0 stdout:- stderr:-|review|5|-|header:review failed:empty:out preserved:out|calls=1 files=out.failed.json=failed(returned an empty response on a zero exit — check CLI auth and configuration|-|-) $CLEAN
a Claude result envelope with no result text names its subtype and turn count as the cause|stdout:envelope:error|review|5|-|header:review failed:result:out:error_during_execution cause:result:error preserved:out|calls=1 files=out.failed.json=failed(ended without a review on a zero exit (claude result subtype=error_during_execution)|claude result|$(result_cause error)|result-error_during_execution) $CLEAN
an is_error envelope whose result is API error text fails with every field of the cause, the text included|stdout:envelope:api-error|review|5|-|header:review failed:result:out:success cause:result:api-error preserved:out|calls=1 files=out.failed.json=failed(ended without a review on a zero exit (claude result subtype=success)|claude result|$(result_cause api-error)|result-success) $CLEAN
a success envelope with no result text fails the same way, naming subtype=success|stdout:envelope:empty-success|review|5|-|header:review failed:result:out:success cause:result:empty-success preserved:out|calls=1 files=out.failed.json=failed(ended without a review on a zero exit (claude result subtype=success)|claude result|$(result_cause empty-success)|result-success) $CLEAN
an is_error envelope whose result is a whole review still fails|stdout:envelope:flagged-review|review|5|-|header:review failed:result:out:success cause:result:flagged-review preserved:out|calls=1 files=out.failed.json=failed(ended without a review on a zero exit (claude result subtype=success)|claude result|$(result_cause flagged-review)|result-success) $CLEAN
a non-zero exit carrying an error envelope takes its cause from the envelope ahead of stderr|rc:1 stdout:envelope:error stderr:quota|review|5|-|header:review failed:exit:out:1 cause:result:error preserved:out|calls=1 files=out.failed.json=failed(exited with code 1|claude result|$(result_cause error)|exit-1) $CLEAN
a format retry that ends on an error envelope at exit 0 fails with the envelope's reason and cause, the raw first response kept|stdout:prose:delivered stdout2:envelope:error|review|5|-|header:review retrying:unparseable raw-kept failed:result:out:error_during_execution cause:result:error preserved:out|calls=2 files=out.failed.json=failed(ended without a review on a zero exit (claude result subtype=error_during_execution)|claude result|$(result_cause error)|answered,result-error_during_execution),out.raw.txt=prose:delivered $CLEAN
a format retry that ends on an error envelope at exit 1 fails with the retry's exit and the envelope's cause|stdout:prose:delivered stdout2:envelope:error rc2:1|review|5|-|header:review retrying:unparseable raw-kept failed:retry-exit:out:1 cause:result:error preserved:out|calls=2 files=out.failed.json=failed(exited with code 1 during the recovery retry|claude result|$(result_cause error)|answered,exit-1),out.raw.txt=prose:delivered $CLEAN
a Claude result envelope whose result is a review writes that review|stdout:envelope:good|review|0|<out>|header:review written|calls=1 files=out=review:external-claude:Clean $CLEAN
a quick-mode envelope with no result text keeps the generic exit 1 and names the cause|stdout:envelope:error|quick|1|-|header:quick generic:result:error_during_execution cause:result:error|calls=1 files=- $CLEAN
a timeout is a CLI failure too, with no cause block|sleep:5 timeout:1|review|5|-|header:review failed:timeout:out:1 preserved:out|calls=1 files=out.failed.json=failed(timed out after 1s|-|-) $CLEAN
a valid response writes the artifact and no sidecar|-|review|0|<out>|header:review written|calls=1 files=out=review:external-claude:Clean $CLEAN
a CLI that dies to a signal is a kill, not a refusal: exit 6, the record and the report name the signal, its last words are the cause|stdout:- stderr:killed signal:TERM|review|6|-|header:review killed:out:SIGTERM:143 cause:stderr:killed preserved:out|calls=1 files=out.failed.json=killed(was killed by SIGTERM (exit 143)|claude stderr|other) $CLEAN
a failure reported on stdout with an empty stderr names the stdout cause|rc:1 stdout:quota stderr:-|review|5|-|header:review failed:exit:out:1 cause:stdout preserved:out|calls=1 files=out.failed.json=failed(exited with code 1|claude stdout|quota) $CLEAN
audit carries the no-verdict contract too|rc:1 stdout:- stderr:quota|audit|5|-|header:audit failed:exit:out:1 cause:stderr preserved:out|calls=1 files=out.failed.json=$FAILED_EXIT_STDERR $CLEAN
a quick-mode non-zero exit carrying an error envelope with an empty stderr names the envelope's cause|rc:1 stdout:envelope:error|quick|1|-|header:quick generic:exit:1 cause:result:error|calls=1 files=- $CLEAN
a quick-mode CLI failure keeps the generic exit 1 and writes no sidecar|rc:1 stdout:- stderr:quota|quick|1|-|header:quick generic:exit:1 cause:stderr|calls=1 files=- $CLEAN
a quick-mode empty response on a zero exit fails with the generic exit 1 and no cause when no stream carried one|rc:0 stdout:- stderr:-|quick|1|-|header:quick generic:empty|calls=1 files=- $CLEAN
a challenge-mode empty response on a zero exit fails the same way|rc:0 stdout:- stderr:-|challenge|1|-|header:challenge generic:empty|calls=1 files=- $CLEAN
a quick-mode empty response on a zero exit names the cause stderr carried|rc:0 stdout:- stderr:killed|quick|1|-|header:quick generic:empty cause:stderr:killed|calls=1 files=- $CLEAN
without --output the record lands in the artifact home under --cwd, owner-only and git-ignored, never in TMPDIR|output:- rc:1 stdout:- stderr:quota|review|5|-|header:review failed:exit:home:1 cause:stderr preserved:home|calls=1 files=- home=mode=700,review-claude-failed=$FAILED_EXIT_STDERR,ignore=* tmp=0 dirty=-
an absolute SECOND_OPINION_ARTIFACT_DIR relocates the record and leaves the default home untouched|output:- rc:1 stdout:- stderr:quota home:abs:alt|review|5|-|header:review failed:exit:home:1 cause:stderr preserved:home|calls=1 files=- home=mode=700,review-claude-failed=$FAILED_EXIT_STDERR tmp=0 dirty=-
an uncreatable home falls back to system temp, loudly, with the class and the cause kept|output:- rc:1 stdout:- stderr:quota home:abs:proc|review|5|-|header:review home-not-creatable:/proc/no-such-home/second-opinion temp-fallback failed:exit:tmp:1 cause:stderr preserved:tmp|calls=1 files=- home=absent tmp=1 dirty=-
a home that exists but denies writes falls back the same way, with nothing written into it|output:- rc:1 stdout:- stderr:quota home:abs:unwritable|review|5|-|header:review home-unusable temp-fallback failed:exit:tmp:1 cause:stderr preserved:tmp|calls=1 files=- home=mode=555 tmp=1 dirty=-
no writable location at all keeps the class and reports the cause inline|output:- rc:1 stdout:- stderr:quota home:abs:proc lock|review|5|-|header:review home-not-creatable:/proc/no-such-home/second-opinion no-location failed:exit:none:1 cause:stderr not-preserved rm-denied rm-denied|calls=1 files=- home=absent tmp=2 dirty=-
a record path that refuses the write names the cause and the loss, and keeps the class|rc:1 stdout:- stderr:quota plant-record|review|5|-|header:review unwritable-record failed:exit:none:1 cause:stderr not-preserved|calls=1 files=out.failed.json=dir $CLEAN
"

run_table "the CLI-failure gate" "$DEFAULTS" "$ROWS"

# The controls: under each one, every row its label pattern selects no longer
# matches its expected record or report. The rows reuse the table's row
# directories, so the table's are removed first.
while IFS='|' read -r name _ _ pattern; do
  selected=0
  while IFS= read -r row; do
    # shellcheck disable=SC2053 # the pattern is a glob
    [[ -n "$row" && "${row%%|*}" == $pattern ]] || continue
    selected=$((selected + 1))
    control_rc=0
    (
      chmod -R u+rwX "${TMP_ROOT:?}"/row-* && rm -rf -- "${TMP_ROOT:?}"/row-* || exit 3
      PASS=0 FAIL=0
      run_table "control $name: ${row%%|*}" "$DEFAULTS script:$name" "$row"
      [[ "$FAIL" -eq 0 ]]
    ) >"$TMP_ROOT/control.log" 2>&1 || control_rc=$?
    assert_eq "$control_rc" 1 "control $name turns red: ${row%%|*}"
  done <<<"$ROWS"
  assert_eq "$((selected > 0))" 1 "control $name selects a row"
done <<<"$CONTROLS"
finish
