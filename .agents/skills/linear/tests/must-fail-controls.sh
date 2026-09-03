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
# Every mutation a control declares is staged and run on its own copy, and it
# names the assertion it must redden, whole: the name is matched against one
# line of the suite's output, not searched for inside it, so a control naming
# a prefix of an assertion is naming an assertion the suite does not have.
# Every declared assertion belongs to
# exactly one mutation, and that mutation's own run must redden it. A mutation
# applied alongside others reports as proof of whatever they broke; one that
# reddened on a harness verdict rather than on the assertion it named proves
# nothing at all; and one with no assertion left to claim, because every one it
# reddens is already another mutation's, has nothing to say for itself. One
# rule refuses all three.
#
# What it does not refuse is a mutation whose failures happen to sit inside
# another's under an assertion nobody else claims. Refusing that would take
# legitimate evidence with it: in controls/mutation-isolation.control.sh
# mutation 5's failures sit wholly inside mutation 8's, and mutation 5 is the
# only thing that reddens the TIMEOUT case.
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

# Mutations are numbered in the order the control applies them, and the runner
# sources the control once per mutation, applying only the one numbered
# CONTROL_MUTATION_ONLY. Zero applies none, which is how the runner counts them
# before it starts. Each mutation therefore lands on a pristine copy, so a
# control cannot chain one onto the line another leaves behind: write every
# mutation against the file as it ships.
CONTROL_MUTATION_ONLY=0
CONTROL_MUTATION_INDEX=0
CONTROL_COUNT_FILE=""
CONTROL_PENDING_FILE=""

# Numbers this mutation, claims the expectations declared since the last one,
# and answers whether this run applies it. The count and expectation files
# carry both back out of the control's subshell.
control_mutation_wanted() {
	CONTROL_MUTATION_INDEX=$((CONTROL_MUTATION_INDEX + 1))
	printf '%s\n' "$CONTROL_MUTATION_INDEX" >"$CONTROL_COUNT_FILE"
	if [[ -s "$CONTROL_PENDING_FILE" ]]; then
		sed "s/^/$CONTROL_MUTATION_INDEX	/" "$CONTROL_PENDING_FILE" \
			>>"$CONTROL_EXPECT_FILE"
		: >"$CONTROL_PENDING_FILE"
	fi
	[[ "$CONTROL_MUTATION_INDEX" -eq "$CONTROL_MUTATION_ONLY" ]]
}

# control_expect STRING — the assertion the next mutation must redden. Name the
# assertion description, so a suite reddening on an earlier, unrelated check —
# or on one of the harness verdicts in tests/lib/assert.sh, which carry the
# same FAIL: prefix — is not mistaken for a working mutation.
#
# The expectation belongs to the mutation declared after it, which is where
# every control already puts it. Two mutations may not name the same assertion:
# one of them would be leaning on what the other answers for.
control_expect() {
	printf '%s\n' "$1" >>"$CONTROL_PENDING_FILE"
}

# control_replace FILE COUNT OLD NEW — replace exactly COUNT whole lines equal
# to OLD with NEW. Whole-line and literal: no pattern syntax to mis-escape.
control_replace() {
	local rel="$1" want="$2" old="$3" new="$4"
	local path="$CONTROL_ROOT/$rel" hits=0 line out=""

	control_mutation_wanted || return 0

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
	control_mutation_wanted || return 0
	[[ -f "$path" ]] || control_die "no such file: $1"
	printf '%s\n' "$2" >>"$path"
}

# control_write FILE TEXT — replace FILE's whole content.
control_write() {
	local path="$CONTROL_ROOT/$1"
	control_mutation_wanted || return 0
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

# stage_copy ROOT — a fresh, unmutated copy of the skill at ROOT.
stage_copy() {
	mkdir -p "$(dirname "$1")"
	cp -R "$SKILL_DIR" "$1"
}

# apply_control ROOT ONLY — source the control against ROOT, applying only
# mutation number ONLY (0 applies none and just counts them). The control runs
# in a subshell so a mutation that failed to land ends that control, not the
# whole run. Its mutation is on disk; only the expectations and the mutation
# count need carrying back out.
#
# One expectation file, not one per mutation: control_expect is ungated, so
# every pass writes the same set, and the runner reads it once from the
# counting pass. A per-mutation file would name an expectation model this
# runner does not have.
apply_control() {
	CONTROL_ROOT="$1"
	CONTROL_MUTATION_ONLY="$2"
	: >"$CONTROL_EXPECT_FILE"
	: >"$CONTROL_COUNT_FILE"
	: >"$CONTROL_PENDING_FILE"
	(
		set -euo pipefail
		CONTROL_MUTATION_INDEX=0
		# shellcheck disable=SC1090
		source "$CONTROL_PATH"
	)
}

# fail_set OUTPUT FILE — the assertion descriptions the suite reddened, one
# per line, sorted and deduplicated, into FILE. `FAIL: ` is what
# tests/lib/assert.sh prints for a failed assertion, and also what it prints
# for the harness verdicts that refuse a suite outright, which is why a
# mutation is measured against the assertion it named rather than against the
# set being non-empty.
fail_set() {
	printf '%s\n' "$1" | sed -n 's/^FAIL: //p' | LC_ALL=C sort -u >"$2"
}

run_one() {
	local suite="$1" stem="$2"
	local control="$CONTROLS_DIR/$stem.control.sh"
	local root="$WORK/$stem/linear"
	local out rc mutations k want shared trailing snapshot="$WORK/$stem/staged"

	if [[ ! -f "$control" ]]; then
		printf 'MISSING  %-52s no controls/%s.control.sh\n' "$suite" "$stem"
		return 1
	fi

	stage_copy "$root"

	# The suite must be green from the staged copy, or its redness under
	# mutation proves nothing about the mutation.
	if ! timeout "$SUITE_TIMEOUT" bash "$root/tests/$suite" >/dev/null 2>&1; then
		printf 'UNSTAGED %-52s suite fails from an unmutated copy\n' "$suite"
		return 1
	fi

	# What the copy holds now, the suite's own residue included: a suite that
	# writes a scratch or a lock file under its own tree is doing its job,
	# and the source is not what this copy should be measured against once
	# it has run. Taken here rather than before that run for the same
	# reason: a snapshot older than the residue reports the residue.
	cp -R "$root" "$snapshot"

	# A pass that applies nothing, for the expectations and the count.
	CONTROL_NAME="$stem"
	CONTROL_PATH="$control"
	CONTROL_COUNT_FILE="$WORK/$stem.count"
	CONTROL_EXPECT_FILE="$WORK/$stem.expect"
	CONTROL_PENDING_FILE="$WORK/$stem.pending"
	if ! apply_control "$root" 0; then
		printf 'BADCTRL  %-52s control did not apply cleanly\n' "$suite"
		return 1
	fi

	# A control is arbitrary bash with CONTROL_ROOT set, so an edit made
	# outside the numbered helpers lands on the counting pass and on every
	# mutation pass alike: never counted, never isolated, never diffed
	# against. Nothing about the copy proves it stayed pristine, so this
	# asks it, against the snapshot taken a moment ago rather than against
	# the source: the only thing to have touched the copy since is the pass
	# that applies no mutation, so any difference is the control's.
	#
	# An unconditional edit, which is what an author writes by mistake. An
	# edit a control makes only while a mutation is being applied leaves
	# this pass clean and lands in the mutation passes, where the NOOP check
	# expects a difference and nothing attributes it to a helper. Refusing
	# that needs attribution this runner does not have, and it is not
	# claimed anywhere.
	if ! diff -rq "$snapshot" "$root" >/dev/null 2>&1; then
		printf 'UNGATED  %-52s control edits its copy outside a numbered mutation\n' \
			"$suite"
		return 1
	fi
	mutations="$(cat "$WORK/$stem.count")"
	mutations="${mutations:-0}"

	if [[ "$mutations" -eq 0 ]]; then
		printf 'NOOP     %-52s control changed nothing\n' "$suite"
		return 1
	fi
	# An expectation is claimed by the mutation declared after it, so one with
	# no mutation after it is claimed by nothing: control_mutation_wanted
	# never drains it and the next pass truncates it. Named here, since
	# declaring the expectation after its mutation reads naturally and is
	# what this roster did until they were bound to each other.
	trailing="$(cat "$CONTROL_PENDING_FILE")"
	if [[ -n "$trailing" ]]; then
		printf 'NOEXPECT %-52s an expectation follows the last mutation and names none: %s\n' \
			"$suite" "$(printf '%s' "$trailing" | sed -n 1p)"
		return 1
	fi
	for ((k = 1; k <= mutations; k++)); do
		if ! grep -q "^$k	" "$CONTROL_EXPECT_FILE"; then
			printf 'NOEXPECT %-52s mutation %d names no assertion\n' "$suite" "$k"
			return 1
		fi
	done
	# Two mutations naming one assertion is the same failure the per-mutation
	# check catches, one step removed: whichever of them the other's redness
	# already accounts for is not evidence, and asking each in isolation
	# cannot see it.
	shared="$(cut -f2- "$CONTROL_EXPECT_FILE" | LC_ALL=C sort | uniq -d)"
	if [[ -n "$shared" ]]; then
		printf 'SHARED   %-52s two mutations name one assertion: %s\n' \
			"$suite" "$(printf '%s' "$shared" | head -n 1)"
		return 1
	fi

	# Every mutation gets a copy no suite has run in, mutation 1 included:
	# the counting pass's copy is the one the green check ran the suite out
	# of, and residue left there would read as the mutation to the NOOP
	# check below and would put mutation 1's failures on a different footing
	# from the sets they are measured against.
	for ((k = 1; k <= mutations; k++)); do
		root="$WORK/$stem/mutation$k/linear"
		stage_copy "$root"
		if ! apply_control "$root" "$k"; then
			printf 'BADCTRL  %-52s mutation %d did not apply cleanly\n' "$suite" "$k"
			return 1
		fi
		if diff -rq "$SKILL_DIR" "$root" >/dev/null 2>&1; then
			printf 'NOOP     %-52s mutation %d changed nothing\n' "$suite" "$k"
			return 1
		fi

		out="$(timeout "$SUITE_TIMEOUT" bash "$root/tests/$suite" 2>&1)"
		rc=$?
		if [[ "$rc" -eq 0 ]]; then
			printf 'GREEN    %-52s suite passed with mutation %d, its only break\n' \
				"$suite" "$k"
			return 1
		fi
		# A killed run reddened on the clock, not on the mutation, and it
		# names nothing. Reported as the kill rather than left to the
		# check below, which would say the mutation did not redden its
		# assertion and send its author looking at the mutation.
		if [[ "$rc" -eq 124 ]]; then
			printf 'TIMEOUT  %-52s mutation %d hit the %ss cap having measured nothing\n' \
				"$suite" "$k" "$SUITE_TIMEOUT"
			return 1
		fi
		# The whole verdict on a mutation: its own run reddened the
		# assertion it named. A run that reddened on a harness verdict
		# instead, or on nothing the suite could name, fails here alike;
		# a mutation with no assertion of its own to claim failed
		# earlier, where the expectations were read.
		fail_set "$out" "$WORK/$stem.fails.$k"
		while IFS= read -r want; do
			if ! grep -qxF -- "$want" "$WORK/$stem.fails.$k"; then
				printf 'WRONG    %-52s mutation %d did not redden: %s\n' \
					"$suite" "$k" "$want"
				printf '%s\n' "$out" | sed 's/^/         | /'
				return 1
			fi
		done < <(grep "^$k	" "$CONTROL_EXPECT_FILE" | cut -f2-)
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
