#!/usr/bin/env bash
# The CLI-failure gate: when the external CLI produces no review at all (a
# non-zero exit, a timeout, an empty response on a zero exit) a review or
# audit run joins the no-verdict class: exit 5, the partial output and the
# CLI's own cause preserved as <output>.failed.json (or a record in the
# artifact home without --output), the cause echoed on stderr from whichever
# stream carried it; a CLI that died to a signal is a kill, exit 6, the signal
# named in the record and the report; challenge and quick keep the generic
# exit 1. Record
# placement never changes the outcome: a home that cannot be created or
# written falls back to system temp loudly, and when nothing is writable the
# cause is reported inline with the exit class kept. One table, a row per
# scenario.
# shellcheck source=lib/stub-cli-world.bash
. "$(dirname "${BASH_SOURCE[0]}")/lib/stub-cli-world.bash"

# A row's world starts from these: a review writing to the row's output path,
# the CLI exiting 0 with a good review and an empty stderr.
DEFAULTS="output:out rc:0 stdout:good stderr:-"

CLEAN="home=absent tmp=0 dirty=-"
# a preserved sidecar: the reason, the cause's source, the cause
FAILED_EXIT_STDERR="failed(exited with code 1|claude stderr|quota)"

# label|world|argv|rc|out|err|calls files home tmp dirty
ROWS="
a non-zero exit with the cause on stderr exits 5, preserves the record with the cause, names it on stderr, and does not retry|rc:1 stdout:- stderr:quota|review|5|-|header:review failed:exit:out:1 cause:stderr preserved:out|calls=1 files=out.failed.json=$FAILED_EXIT_STDERR $CLEAN
an empty response on a zero exit is the same class, with the empty-response reason|rc:0 stdout:- stderr:quota|review|5|-|header:review failed:empty:out cause:stderr preserved:out|calls=1 files=out.failed.json=failed(returned an empty response on a zero exit — check CLI auth and configuration|claude stderr|quota) $CLEAN
a timeout is a CLI failure too, with no cause block|sleep:5 timeout:1|review|5|-|header:review failed:timeout:out:1 preserved:out|calls=1 files=out.failed.json=failed(timed out after 1s|-|-) $CLEAN
a valid response writes the artifact and no sidecar|-|review|0|<out>|header:review written|calls=1 files=out=review:external-claude:Clean $CLEAN
a CLI that dies to a signal is a kill, not a refusal: exit 6, the record and the report name the signal, its last words are the cause|stdout:- stderr:killed signal:TERM|review|6|-|header:review killed:out:SIGTERM:143 cause:stderr:killed preserved:out|calls=1 files=out.failed.json=killed(was killed by SIGTERM (exit 143)|claude stderr|other) $CLEAN
a failure reported on stdout with an empty stderr names the stdout cause|rc:1 stdout:quota stderr:-|review|5|-|header:review failed:exit:out:1 cause:stdout preserved:out|calls=1 files=out.failed.json=failed(exited with code 1|claude stdout|quota) $CLEAN
audit carries the no-verdict contract too|rc:1 stdout:- stderr:quota|audit|5|-|header:audit failed:exit:out:1 cause:stderr preserved:out|calls=1 files=out.failed.json=$FAILED_EXIT_STDERR $CLEAN
a quick-mode CLI failure keeps the generic exit 1 and writes no sidecar|rc:1 stdout:- stderr:quota|quick|1|-|header:quick generic:exit:1|calls=1 files=- $CLEAN
without --output the record lands in the artifact home under --cwd, owner-only and git-ignored, never in TMPDIR|output:- rc:1 stdout:- stderr:quota|review|5|-|header:review failed:exit:home:1 cause:stderr preserved:home|calls=1 files=- home=mode=700,review-claude-failed=$FAILED_EXIT_STDERR,ignore=* tmp=0 dirty=-
an absolute SECOND_OPINION_ARTIFACT_DIR relocates the record and leaves the default home untouched|output:- rc:1 stdout:- stderr:quota home:abs:alt|review|5|-|header:review failed:exit:home:1 cause:stderr preserved:home|calls=1 files=- home=mode=700,review-claude-failed=$FAILED_EXIT_STDERR tmp=0 dirty=-
an uncreatable home falls back to system temp, loudly, with the class and the cause kept|output:- rc:1 stdout:- stderr:quota home:abs:proc|review|5|-|header:review home-not-creatable:/proc/no-such-home/second-opinion temp-fallback failed:exit:tmp:1 cause:stderr preserved:tmp|calls=1 files=- home=absent tmp=1 dirty=-
a home that exists but denies writes falls back the same way, with nothing written into it|output:- rc:1 stdout:- stderr:quota home:abs:unwritable|review|5|-|header:review home-unusable temp-fallback failed:exit:tmp:1 cause:stderr preserved:tmp|calls=1 files=- home=mode=555 tmp=1 dirty=-
no writable location at all keeps the class and reports the cause inline|output:- rc:1 stdout:- stderr:quota home:abs:proc lock|review|5|-|header:review home-not-creatable:/proc/no-such-home/second-opinion no-location failed:exit:none:1 cause:stderr not-preserved rm-denied rm-denied|calls=1 files=- home=absent tmp=2 dirty=-
a record path that refuses the write names the cause and the loss, and keeps the class|rc:1 stdout:- stderr:quota plant-record|review|5|-|header:review unwritable-record failed:exit:none:1 cause:stderr not-preserved|calls=1 files=out.failed.json=dir $CLEAN
"

run_table "the CLI-failure gate" "$DEFAULTS" "$ROWS"
finish
