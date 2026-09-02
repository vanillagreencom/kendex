#!/usr/bin/env bash
#
# Runs every suite's must-fail control.
#
# A control breaks the one behaviour its suite claims to cover, in a copy of
# the skill, and the suite must go red naming the assertion that covers it. A
# suite with no control is a failure here: an untested control is an untested
# suite. So is a control no suite owns: nothing runs it, so the mutation it
# describes is never applied and the behaviour it claims to prove is unproven.
#
#   skills/linear/tests/must-fail-controls.sh                     # all
#   skills/linear/tests/must-fail-controls.sh estimate-clear      # one, by stem

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TESTS_DIR/.." && pwd)"
CONTROLS_DIR="$TESTS_DIR/controls"
SUITE_TIMEOUT="${CONTROL_TIMEOUT:-60}"

# Controls run concurrently: each one mutates its own copy of the skill and
# runs the suite out of that copy, so no two of them share anything writable.
CONTROL_JOBS="${CONTROL_JOBS:-$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 4)}"

WORK="$(mktemp -d)"
trap 'rm -rf -- "${WORK:?}"' EXIT
# An interrupted run signals the control jobs it launched, and only the pids
# it recorded when it launched them: every lane on this machine runs these
# same suites out of its own worktree, so an argv match would reach theirs
# too. Bash ignores INT in the async children of a shell without job control,
# so Ctrl-C never reaches them on its own; TERM does. The `timeout` child each
# control spawned is a grandchild this does not reach; it retires itself
# within SUITE_TIMEOUT.
# One trap each, so the code a wrapper reads says which signal arrived: an
# interrupt and a kill are the same cleanup but not the same event.
trap 'kill -TERM ${PIDS[@]+"${PIDS[@]}"} 2>/dev/null; exit 130' INT
trap 'kill -TERM ${PIDS[@]+"${PIDS[@]}"} 2>/dev/null; exit 143' TERM

# --- control vocabulary -----------------------------------------------------
# A control script runs with CONTROL_ROOT pointing at its own copy of the
# skill. Every mutation is checked for having landed: a replacement that
# matches nothing, or matches a different number of lines than declared, aborts
# the control instead of reporting a green suite as proof of anything.

die() {
	printf 'must-fail-controls: %s\n' "$*" >&2
	exit 2
}

# A junk width otherwise reaches the batching predicate, where Bash 4.4 and
# newer abort on the unbound name mid-roster and 4.0 through 4.2 read it as 0
# and run every control one at a time. The digit count is part of the grammar:
# 19 digits or more is past what signed 64-bit shell arithmetic holds, and the
# predicate compares against the wrap, which reaps every iteration when it
# lands at or below zero.
[[ "$CONTROL_JOBS" =~ ^[1-9][0-9]{0,17}$ ]] ||
	die "CONTROL_JOBS must be a positive integer, got: $CONTROL_JOBS"

control_die() {
	printf 'control %s: %s\n' "$CONTROL_NAME" "$*" >&2
	exit 2
}

# control_expect STRING — the mutated suite's output must contain STRING. Name
# the assertion description that must fire, so a suite reddening on an earlier,
# unrelated check is not mistaken for a working control.
control_expect() {
	printf '%s\n' "$1" >>"$CONTROL_EXPECT_FILE"
}

# control_replace FILE COUNT OLD NEW — replace exactly COUNT whole lines equal
# to OLD with NEW. Whole-line and literal: no pattern syntax to mis-escape.
control_replace() {
	local rel="$1" want="$2" old="$3" new="$4"
	local path="$CONTROL_ROOT/$rel" hits=0 line out=""

	[[ -f "$path" ]] || control_die "no such file: $rel"
	[[ "$old" != "$new" ]] || control_die "$rel: replacement is identical to the original"

	while IFS= read -r line || [[ -n "$line" ]]; do
		if [[ "$line" == "$old" ]]; then
			hits=$((hits + 1))
			out+="$new"$'\n'
		else
			out+="$line"$'\n'
		fi
	done <"$path"

	[[ "$hits" -eq "$want" ]] ||
		control_die "$rel: matched $hits lines, declared $want, for: $old"

	printf '%s' "$out" >"$path"
}

# control_append FILE TEXT — add TEXT as a final line.
control_append() {
	local path="$CONTROL_ROOT/$1"
	[[ -f "$path" ]] || control_die "no such file: $1"
	printf '%s\n' "$2" >>"$path"
}

# control_write FILE TEXT — replace FILE's whole content.
control_write() {
	local path="$CONTROL_ROOT/$1"
	[[ -f "$path" ]] || control_die "no such file: $1"
	printf '%s\n' "$2" >"$path"
}

# --- runner -----------------------------------------------------------------

PIDS=()
BATCH=()
FAILURES=0

# Wait out the launched batch, score one failure per control that reported
# one, then print what that batch found. `wait -n` would keep the pipe full
# instead of draining it in batches, but this skill supports Bash 4.0 and
# newer (README § Setup) and `wait -n` arrived in 4.3.
#
# Printing here rather than after the last batch is what a run killed by CI,
# a wrapper timeout or Ctrl-C leaves behind: the verdicts already reached.
# A batch's pids are in roster order and the batches are too, so incremental
# output is the same order the whole run would have printed.
reap() {
	local pid stem
	for pid in ${PIDS[@]+"${PIDS[@]}"}; do
		wait "$pid" || FAILURES=$((FAILURES + 1))
	done
	for stem in ${BATCH[@]+"${BATCH[@]}"}; do
		cat "$WORK/$stem.log"
	done
	PIDS=()
	BATCH=()
}

run_one() {
	local suite="$1" stem="$2"
	local control="$CONTROLS_DIR/$stem.control.sh"
	local root="$WORK/$stem/linear"
	local out rc

	if [[ ! -f "$control" ]]; then
		printf 'MISSING  %-52s no controls/%s.control.sh\n' "$suite" "$stem"
		return 1
	fi

	mkdir -p "$WORK/$stem"
	cp -R "$SKILL_DIR" "$root"

	# The suite must be green from the staged copy, or its redness under
	# mutation proves nothing about the mutation.
	if ! timeout "$SUITE_TIMEOUT" bash "$root/tests/$suite" >/dev/null 2>&1; then
		printf 'UNSTAGED %-52s suite fails from an unmutated copy\n' "$suite"
		return 1
	fi

	# The control runs in a subshell so a mutation that failed to land ends
	# that control, not the whole run. Its mutations are on disk; only the
	# expectations need carrying back out.
	CONTROL_NAME="$stem"
	CONTROL_ROOT="$root"
	CONTROL_EXPECT_FILE="$WORK/$stem.expect"
	: >"$CONTROL_EXPECT_FILE"
	if ! (
		set -euo pipefail
		# shellcheck disable=SC1090
		source "$control"
	); then
		printf 'BADCTRL  %-52s control did not apply cleanly\n' "$suite"
		return 1
	fi
	CONTROL_EXPECTED=()
	while IFS= read -r expected_line; do
		CONTROL_EXPECTED+=("$expected_line")
	done <"$CONTROL_EXPECT_FILE"

	if [[ ${#CONTROL_EXPECTED[@]} -eq 0 ]]; then
		printf 'NOEXPECT %-52s control declares no expected assertion\n' "$suite"
		return 1
	fi
	if diff -rq "$SKILL_DIR" "$root" >/dev/null 2>&1; then
		printf 'NOOP     %-52s control changed nothing\n' "$suite"
		return 1
	fi

	out="$(timeout "$SUITE_TIMEOUT" bash "$root/tests/$suite" 2>&1)"
	rc=$?
	if [[ "$rc" -eq 0 ]]; then
		printf 'GREEN    %-52s suite passed with its subject broken\n' "$suite"
		return 1
	fi

	local want
	for want in "${CONTROL_EXPECTED[@]}"; do
		if [[ "$out" != *"$want"* ]]; then
			printf 'WRONG    %-52s reddened without: %s\n' "$suite" "$want"
			printf '%s\n' "$out" | sed 's/^/         | /'
			return 1
		fi
	done

	printf 'ok       %s\n' "$suite"
	return 0
}

main() {
	local -a wanted=("$@") stems=()
	local suite_path control_path suite stem want total=0 orphans=0

	for suite_path in "$TESTS_DIR"/*.test.sh; do
		stems+=("$(basename "$suite_path" .test.sh)")
	done
	[[ ${#stems[@]} -gt 0 ]] || die "no suites in $TESTS_DIR"

	# The roster is read whole whatever the selection: a targeted run must
	# not be green while a control sits in the directory unrun.
	for control_path in "$CONTROLS_DIR"/*.control.sh; do
		[[ -f "$control_path" ]] || die "no controls in $CONTROLS_DIR"
		stem="$(basename "$control_path" .control.sh)"
		if [[ " ${stems[*]} " != *" $stem "* ]]; then
			printf 'ORPHAN   %-52s no %s.test.sh owns it\n' \
				"controls/$stem.control.sh" "$stem"
			orphans=$((orphans + 1))
		fi
	done

	# A run that selected nothing is not a clean run: a mistyped stem would
	# otherwise report "0 controls, 0 failing" and exit 0.
	for want in ${wanted[@]+"${wanted[@]}"}; do
		if [[ " ${stems[*]} " != *" $want "* ]]; then
			die "no such suite: $want.test.sh"
		fi
	done

	for stem in "${stems[@]}"; do
		suite="$stem.test.sh"
		if [[ ${#wanted[@]} -gt 0 ]] && [[ " ${wanted[*]} " != *" $stem "* ]]; then
			continue
		fi
		total=$((total + 1))
		run_one "$suite" "$stem" >"$WORK/$stem.log" 2>&1 &
		PIDS+=("$!")
		BATCH+=("$stem")
		[[ ${#PIDS[@]} -lt "$CONTROL_JOBS" ]] || reap
	done
	reap

	[[ "$total" -gt 0 ]] || die "selection matched no suites"

	printf '\n%d controls, %d failing, %d orphaned\n' \
		"$total" "$FAILURES" "$orphans"
	[[ "$FAILURES" -eq 0 && "$orphans" -eq 0 ]]
}

main "$@"
