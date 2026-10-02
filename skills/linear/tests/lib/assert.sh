# shellcheck shell=bash
#
# Assertions for the linear skill's suites.
#
# Every claim a suite makes runs through a helper here, and sourcing this file
# installs the EXIT trap that turns those claims into the suite's verdict. A
# suite that reaches its end without executing an assertion fails: an exit code
# reports on the process, not on anything that was checked.
#
# Helpers never return non-zero and never exit. A failed assertion is recorded
# and the suite runs on, so one run reports every failure and no assertion can
# be skipped by an errexit abort. `assert_stop` ends the suite where continuing
# would be meaningless.
#
# Cleanup goes through `assert_tmpdir` and `assert_at_exit`. Installing another
# EXIT trap replaces this one and disarms the verdict.

if [[ -n "${ASSERT_LIB_LOADED:-}" ]]; then
	return 0
fi
ASSERT_LIB_LOADED=1

# Key fixtures must not select a developer's app from the process or project.
# OAuth cases pass their own app pair in the child's explicit environment.
export LINEAR_APP_TOKEN="" LINEAR_CLIENT_ID="" LINEAR_CLIENT_SECRET=""

ASSERT_COUNT=0
ASSERT_FAILURES=0
ASSERT_TMPDIRS=()
ASSERT_CLEANUP_CMDS=()
ASSERT_SCRATCH_DIR=""

# A subshell — a command substitution, a pipeline element, a backgrounded or
# parenthesised block — gets its own copy of every variable, so an assertion
# made there increments a counter the suite never sees and records a failure
# nobody reads. The counters alone cannot notice: they are exactly what the
# subshell copied. So every assertion also appends to a file, which a subshell
# shares with its parent, and the verdict compares the two. A count that
# disagrees is the shape, and it is refused rather than left to authors to
# avoid.
printf -v ASSERT_LEDGER '%s' "$(mktemp)"
if [[ -z "$ASSERT_LEDGER" ]]; then
	printf 'FAIL: could not create the assertion ledger\n' >&2
	exit 1
fi

__assert_ran() {
	ASSERT_COUNT=$((ASSERT_COUNT + 1))
	printf 'ran\n' >>"$ASSERT_LEDGER"
}

__assert_failed() {
	local desc="$1" line
	shift
	ASSERT_FAILURES=$((ASSERT_FAILURES + 1))
	printf 'failed\t%s\n' "$desc" >>"$ASSERT_LEDGER"
	printf 'FAIL: %s\n' "$desc" >&2
	for line in "$@"; do
		printf '      %s\n' "$line" >&2
	done
}

# assert_tmpdir VARNAME — make a scratch directory, name it in VARNAME, and
# remove it at exit. Takes a variable name rather than printing the path so the
# registration happens in the suite's own shell.
assert_tmpdir() {
	printf -v "$1" '%s' "$(mktemp -d)"
	# A library cannot impose errexit on its callers, so the one failure mode
	# that matters — mktemp failing and leaving the name empty — is checked
	# here rather than left to the caller's shell options.
	if [[ -z "${!1}" ]]; then
		printf 'FAIL: could not create a scratch directory\n' >&2
		exit 1
	fi
	ASSERT_TMPDIRS+=("${!1}")
}

# assert_at_exit COMMAND — run COMMAND (eval'd) before the scratch directories
# go, for teardown a plain remove cannot do.
assert_at_exit() {
	ASSERT_CLEANUP_CMDS+=("$1")
}

# --- cache isolation --------------------------------------------------------
#
# The scripts under test resolve their cache and attachment store from the
# repository the process is standing in, which for a suite is the developer's
# own kendex checkout. A suite that creates a comment or completes an issue
# therefore wrote its fixture identifiers into the real .cache/linear, where
# `cache issues list` and any audit can see them.
#
# The redirect is installed here, once, for every suite that sources this file:
# no suite has to remember it, and each suite is isolated before its first line
# runs. LINEAR_CACHE_ROOT outranks the git root in the scripts under test, and
# the scratch root goes with the suite's other scratch directories at exit — on
# success, on a failed assertion, and on an abort alike, taking any lock file
# written under it.
#
# A suite that stands up its own project root re-points LINEAR_CACHE_ROOT at
# that root, which must still be scratch it registered. The verdict refuses
# anything else: a suite that unsets the variable, or aims it at a directory it
# does not own, is a suite writing to the real cache again.
#
# A suite whose subject IS the root resolution cannot do that — the redirect
# outranks the git root, so pointing it anywhere answers the question under
# test. Such a suite keeps this default and drops the variable per invocation
# with `env -u LINEAR_CACHE_ROOT`, standing in scratch of its own so nothing
# reaches the real cache. cache-root-git-worktree.test.sh is the example.
assert_tmpdir ASSERT_CACHE_ROOT
mkdir -p "$ASSERT_CACHE_ROOT/.cache/linear/comments"
export LINEAR_CACHE_ROOT="$ASSERT_CACHE_ROOT"

# The diagnostic for a cache root that left the sandbox, or the empty string
# when it did not. Read by the exit verdict before cleanup removes the
# directories it is checked against.
__assert_cache_root_escape() {
	local dir
	if [[ -z "${LINEAR_CACHE_ROOT:-}" ]]; then
		printf 'LINEAR_CACHE_ROOT was unset by the suite'
		return 0
	fi
	for dir in ${ASSERT_TMPDIRS[@]+"${ASSERT_TMPDIRS[@]}"}; do
		if [[ "$LINEAR_CACHE_ROOT" == "$dir" || "$LINEAR_CACHE_ROOT" == "$dir"/* ]]; then
			return 0
		fi
	done
	printf 'LINEAR_CACHE_ROOT points outside every scratch directory this suite registered: %s' \
		"$LINEAR_CACHE_ROOT"
}

# assert DESC CMD [ARG...] — CMD must exit zero. The command's own output is
# captured, not printed: redirecting an assertion at the call site would
# silence the failure report too.
assert() {
	local desc="$1" out="" rc=0
	shift
	__assert_ran
	out="$("$@" 2>&1)" || rc=$?
	if ((rc == 0)); then
		return 0
	fi
	__assert_failed "$desc" "command failed with status $rc: $*" ${out:+"output: $out"}
}

# assert_not DESC CMD [ARG...] — CMD must exit non-zero.
assert_not() {
	local desc="$1" out="" rc=0
	shift
	__assert_ran
	out="$("$@" 2>&1)" || rc=$?
	if ((rc != 0)); then
		return 0
	fi
	__assert_failed "$desc" "command unexpectedly succeeded: $*" ${out:+"output: $out"}
}

# assert_eq DESC GOT WANT
assert_eq() {
	__assert_ran
	if [[ "$2" == "$3" ]]; then
		return 0
	fi
	__assert_failed "$1" "want: $3" "got:  $2"
}

# assert_ne DESC GOT UNWANTED
assert_ne() {
	__assert_ran
	if [[ "$2" != "$3" ]]; then
		return 0
	fi
	__assert_failed "$1" "got the value it must not have: $3"
}

# assert_contains DESC HAYSTACK NEEDLE
assert_contains() {
	__assert_ran
	if [[ "$2" == *"$3"* ]]; then
		return 0
	fi
	__assert_failed "$1" "missing substring: $3" "in: $2"
}

# assert_not_contains DESC HAYSTACK NEEDLE
assert_not_contains() {
	__assert_ran
	if [[ "$2" != *"$3"* ]]; then
		return 0
	fi
	__assert_failed "$1" "forbidden substring: $3" "in: $2"
}

# assert_matches DESC SUBJECT ERE
assert_matches() {
	__assert_ran
	if [[ "$2" =~ $3 ]]; then
		return 0
	fi
	__assert_failed "$1" "no match for: $3" "in: $2"
}

# assert_jq DESC JSON FILTER — FILTER must select a true, non-null value.
assert_jq() {
	__assert_ran
	if jq -e "$3" >/dev/null 2>&1 <<<"$2"; then
		return 0
	fi
	__assert_failed "$1" "filter: $3" "json: $2"
}

# assert_file_contains DESC PATH NEEDLE — NEEDLE is a literal, not a pattern.
assert_file_contains() {
	__assert_ran
	if [[ ! -f "$2" ]]; then
		__assert_failed "$1" "no such file: $2"
		return 0
	fi
	if grep -qF -- "$3" "$2"; then
		return 0
	fi
	__assert_failed "$1" "missing substring: $3" "in file: $2"
}

# assert_file_lacks DESC PATH NEEDLE
assert_file_lacks() {
	__assert_ran
	if [[ ! -f "$2" ]]; then
		__assert_failed "$1" "no such file: $2"
		return 0
	fi
	if grep -qF -- "$3" "$2"; then
		__assert_failed "$1" "forbidden substring: $3" "in file: $2"
		return 0
	fi
	return 0
}

# assert_fail DESC [DIAGNOSTIC...] — an unconditional failure, for a branch the
# suite must not reach.
assert_fail() {
	__assert_ran
	__assert_failed "$@"
}

# Run the OAuth suite's fixture command with an explicit environment and clock.
run_oauth_request() {
	local command="$PROJECT/request" action=()
	if [[ "$1" == auth-check ]]; then command="$LINEAR"; action=(auth-check); fi
	if [[ "$1" == auth-mint ]]; then command="$LINEAR"; action=(auth-mint); fi
	if [[ "$1" == cache-fetch ]]; then command="$LINEAR"; action=(cache attachments fetch TEAM-1); fi
	if [[ "$1" == cache-read ]]; then command="$LINEAR"; action=(cache attachments list TEAM-1); fi
	shift
	OUT=$(cd -- "$PROJECT" && env -i PATH="$PROJECT/bin:$PATH" HOME="$TMP_ROOT" \
		LINEAR_CACHE_ROOT="$PROJECT" LOG="$LOG" NOW="$NOW" REAL_JQ="$REAL_JQ" LINEAR_RETRY_BASE_DELAY=0 \
		"$@" bash "$command" "${action[@]}" 2>"$LOG/error") && RC=0 || RC=$?
}

# Run the OAuth fixture setup with repository redirects emitted by Git for
# normal and linked caller worktrees. The child stops before OAuth requests,
# whose explicit environment already removes the caller's Git redirects.
run_oauth_git_redirects() {
	local suite="$1" root="$2" kind caller base git_dir common_dir work_tree index_file rc
	local before after
	for kind in normal linked; do
		base="$root/$kind/base"
		mkdir -p "$base"
		git -C "$base" init -q -b main
		git -C "$base" config gc.auto 0
		git -C "$base" config maintenance.auto false
		printf 'caller data\n' >"$base/tracked"
		git -C "$base" add tracked
		git -C "$base" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm base
		caller="$base"
		if [[ "$kind" == linked ]]; then
			caller="$root/$kind/worktree"
			git -C "$base" worktree add -q -b caller "$caller"
		fi
		# rev-parse supplies the same redirects Git hooks inherit; resolving
		# relative outputs keeps the child's working directory out of their meaning.
		git_dir=$(git -C "$caller" rev-parse --absolute-git-dir)
		common_dir=$(git -C "$caller" rev-parse --git-common-dir)
		common_dir=$(cd -- "$caller" && cd -- "$common_dir" && pwd -P)
		work_tree=$(git -C "$caller" rev-parse --show-toplevel)
		index_file=$(git -C "$caller" rev-parse --git-path index)
		[[ "$index_file" == /* ]] || index_file="$caller/$index_file"
		cp -- "$common_dir/config" "$root/$kind/config.before"
		cp -- "$index_file" "$root/$kind/index.before"
		before=$(git -C "$caller" rev-parse HEAD)
		env -i PATH="$PATH" HOME="$root" OAUTH_GIT_REDIRECT_CHILD=1 \
			GIT_DIR="$git_dir" GIT_COMMON_DIR="$common_dir" GIT_WORK_TREE="$work_tree" \
			GIT_INDEX_FILE="$index_file" bash "$suite" >"$root/$kind/suite.log" 2>&1 && rc=0 || rc=$?
		assert_eq "$kind Git redirects: OAuth suite succeeds" "$rc" 0
		if [[ "$rc" != 0 ]]; then cat -- "$root/$kind/suite.log"; fi
		assert "$kind Git redirects: caller config stays unchanged" \
			cmp -s -- "$root/$kind/config.before" "$common_dir/config"
		assert "$kind Git redirects: caller index stays unchanged" \
			cmp -s -- "$root/$kind/index.before" "$index_file"
		after=$(git -C "$caller" rev-parse HEAD)
		assert_eq "$kind Git redirects: caller HEAD stays unchanged" "$after" "$before"
	done
}

# Install the recorded Linear issue and label responses for both label-write
# commands. The curl fixture applies only filters the request actually sends,
# so an unscoped lookup returns the other team's same-name label first.
install_label_team_fixture() {
	local project="$1"
	mkdir -p "$project/bin" "$project/.cache/linear"
	jq '[.issueLabels.nodes[] | select(.team.name == "fleet")]' \
		"$SKILL_DIR/tests/lib/fixtures/issue-team-labels.json" >"$project/.cache/linear/labels.json"
	cat >"$project/bin/curl" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
config=$(cat)
payload=$(sed -n 's/^data = //p' <<<"$config" | jq -r)
query=$(jq -r '.query' <<<"$payload")
printf '%s\n' "$payload" >>"${CURL_LOG:?}"
case "$query" in
*"issueLabels(filter:"*)
  if [[ "$FIXTURE_FAIL" == labels ]]; then
    printf '%s' '{"errors":[{"message":"label service unavailable"}]}___HTTP_CODE___200'
    exit 0
  fi
  scoped=false workspace=false
  [[ "$query" != *'team: {name: {eq: $teamName}}'* ]] || scoped=true
  [[ "$query" != *'team: {null: true}'* ]] || workspace=true
  jq -cj --argjson payload "$payload" --argjson scoped "$scoped" --argjson workspace "$workspace" '
    {data: {issueLabels: {nodes: [.issueLabels.nodes[]
      | select(.name == $payload.variables.name)
      | select(($scoped | not) or .team.name == $payload.variables.teamName
        or ($workspace and .team == null))
      | {id}]}}}' "$FIXTURE_DIR/issue-team-labels.json"
  ;;
*"issue(id:"*)
  if [[ "$FIXTURE_FAIL" == issue ]]; then
    printf '%s' '{"errors":[{"message":"issue service unavailable"}]}___HTTP_CODE___200'
    exit 0
  fi
  jq -cj --arg fail "$FIXTURE_FAIL" \
    '{data: (if $fail == "team" then del(.issue.team) else . end)}' "$FIXTURE_DIR/label-team-issue.json"
  ;;
*"teams(filter:"*)
  printf '%s' '{"data":{"teams":{"nodes":[{"id":"team-uuid"}]}}}'
  ;;
*"workflowStates(filter:"*)
  printf '%s' '{"data":{"workflowStates":{"nodes":[{"id":"state-in-progress"}]}}}'
  ;;
*"issueUpdate(id:"*)
  jq -cj '{data: {issueUpdate: {success: true, issue: .issue}}}' "$FIXTURE_DIR/label-team-issue.json"
  ;;
*)
  printf '%s' '{"errors":[{"message":"unexpected fixture query"}]}'
  ;;
esac
printf '%s' '___HTTP_CODE___200'
SH
	chmod +x "$project/bin/curl"
}

# Each request has its own payload log and failure input. The configured team
# differs from the recorded issue's team, and the cache holds fleet-only IDs.
run_label_team_request() {
	local project="$1" name="$2" fail="$3"
	shift 3
	: >"$TMP_ROOT/$name.jsonl"
	(cd -- "$project" && env -i HOME="$TMP_ROOT" PATH="$project/bin:$PATH" \
		LINEAR_API_KEY_OVERRIDE=stub LINEAR_TEAM=vsys KENDEX_USER_EMAIL= \
		LINEAR_CACHE_ROOT="$project" FIXTURE_FAIL="$fail" \
		FIXTURE_DIR="$SKILL_DIR/tests/lib/fixtures" CURL_LOG="$TMP_ROOT/$name.jsonl" \
		"$BASH" "$project/.agents/skills/linear/scripts/linear.sh" issues "$@") \
		>"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err"
}

# assert_stop DESC [DIAGNOSTIC...] — assert_fail, then end the suite.
assert_stop() {
	assert_fail "$@"
	exit 1
}

# run_status VARNAME CMD [ARG...] — run CMD and put its exit status in VARNAME.
#
# bash suspends errexit for the whole body of a command whose status is being
# tested — an `if` condition, a `&&`/`||` operand, a `!` — and the suspension
# reaches into a shell function called there and into every function it calls.
# `func || rc=$?` therefore reports 0 for a function that relied on errexit and
# was meant to abort partway: the exact fail-open this suite family exists to
# catch. Neither `set +e` around the call nor an explicit `set -e` inside a
# subshell restores it.
#
# So the subject is never put in a tested position. It runs in a background
# subshell, forked before any test, and `wait` reports the status it already
# finished with.
run_status() {
	local __var="$1" __rc=0
	shift

	# The suspension is inherited by a background subshell too, so errexit is
	# proved in force rather than assumed: under errexit this canary dies at
	# `false`, and only where errexit is suspended — or absent — does it live
	# to reach `exit 0`.
	( false; exit 0 ) &
	if wait $!; then
		assert_stop "run_status needs errexit in force at the call site" \
			"it is suspended inside an if condition, a &&/|| operand or a !," \
			"and absent in a suite that does not set -e"
	fi

	( "$@" ) &
	wait $! || __rc=$?
	printf -v "$__var" '%s' "$__rc"
}

# run_output OUTVAR RCVAR CMD [ARG...] — run_status, plus CMD's stdout in
# OUTVAR. Command substitution cannot be used for this: `out=$(func) || rc=$?`
# puts the subject back in a tested position, which is what run_status exists
# to avoid. The output goes through a file the background subshell writes.
run_output() {
	local __out_var="$1" __rc_var="$2" __file
	shift 2
	if [[ -z "$ASSERT_SCRATCH_DIR" ]]; then
		assert_tmpdir ASSERT_SCRATCH_DIR
	fi
	__file="$ASSERT_SCRATCH_DIR/run-output"

	run_status "$__rc_var" "$@" >"$__file"

	printf -v "$__out_var" '%s' "$(cat "$__file")"
}

__assert_on_exit() {
	local rc=$? cmd dir ledger_ran=0 ledger_failed=0 lost=0 outstanding="" cache_escape=""

	# A background job still running has not finished writing to the ledger, so
	# the totals below would be computed over a record that is still being
# updated — and the ledger is removed a few lines later, so what the job
	# writes afterwards goes nowhere. Waiting on it is the other option and it
	# can hang forever on a job that never exits, so the verdict fails closed
	# on the job's presence instead: a suite that leaves work outstanding has
	# not finished being a suite.
	outstanding="$(jobs -pr | tr '\n' ' ')"
	if [[ -n "${outstanding// /}" ]]; then
		printf 'FAIL: the suite ended with background job(s) still running: %s\n' "$outstanding" >&2
		printf '      an assertion made there would land after this verdict, so it would be\n' >&2
		printf '      discarded — wait for the job and assert on what it produced\n' >&2
		rm -f -- "${ASSERT_LEDGER:?}"
		exit 1
	fi

	# The ledger is read before cleanup removes it, and it is the true count:
	# it survives the subshells the counters do not.
	if [[ -f "$ASSERT_LEDGER" ]]; then
		ledger_ran="$(grep -c '^ran$' "$ASSERT_LEDGER" || true)"
		ledger_failed="$(grep -c '^failed' "$ASSERT_LEDGER" || true)"
	fi
	lost=$((ledger_ran - ASSERT_COUNT))
	cache_escape="$(__assert_cache_root_escape)"

	for cmd in ${ASSERT_CLEANUP_CMDS[@]+"${ASSERT_CLEANUP_CMDS[@]}"}; do
		eval "$cmd" || true
	done
	for dir in ${ASSERT_TMPDIRS[@]+"${ASSERT_TMPDIRS[@]}"}; do
		rm -rf -- "${dir:?}"
	done
	rm -f -- "${ASSERT_LEDGER:?}"

	if [[ -n "$cache_escape" ]]; then
		printf 'FAIL: %s\n' "$cache_escape" >&2
		printf '      the scripts under test would have resolved their cache from the enclosing\n' >&2
		printf '      repository and written fixture ids into the real .cache/linear — point it\n' >&2
		printf '      at a directory from assert_tmpdir instead\n' >&2
		exit 1
	fi
	if ((lost > 0)); then
		printf 'FAIL: %d assertion(s) ran in a subshell, where the suite cannot see them\n' "$lost" >&2
		printf '      a command substitution, pipeline element, backgrounded or parenthesised\n' >&2
		printf '      block gets its own copy of the counters, so the result is discarded —\n' >&2
		printf '      capture the status in the suite and assert on it there\n' >&2
		exit 1
	fi
	if ((ledger_failed > 0)); then
		printf '%d of %d assertions failed\n' "$ledger_failed" "$ledger_ran" >&2
		exit 1
	fi
	if ((rc != 0)); then
		printf 'suite aborted with status %d after %d assertions\n' "$rc" "$ledger_ran" >&2
		exit "$rc"
	fi
	if ((ledger_ran == 0)); then
		printf 'FAIL: suite ended without executing an assertion\n' >&2
		exit 1
	fi
	printf 'ok: %d assertions\n' "$ledger_ran"
	exit 0
}

# Exercise pages.sh with synthetic GraphQL replies and an explicit child env.
# The dependency selects replies by owner and cursor. Child continuation
# replies carry only selected fields. The suite supplies independent counts.
pages_case() {
	local name="$1" mode="$2" limit=0 budget line hits=0 child_mode=bundle
	[[ "$name" != bounded ]] || limit=1
	[[ "$name" != children-recursive ]] || child_mode=recursive
	jq -cn --arg name "$name" '
		def conn($rows; $more; $cursor): {nodes:$rows,pageInfo:{hasNextPage:$more,endCursor:$cursor}};
		def issue($id; $size): {id:$id,identifier:"FIX-1",title:"synthetic",description:("s" * $size),
			archivedAt:null,assignee:null,createdAt:"synthetic",cycle:null,estimate:null,
			inverseRelations:conn([];false;null),labels:conn([];false;null),parent:null,
			priority:0,project:null,projectMilestone:null,relations:conn([];false;null),
			sortOrder:0,state:{name:"synthetic",type:"started"},trashed:false,updatedAt:"synthetic",url:"https://example.invalid"};
		def reply($id; $after; $response): {id:$id,after:$after,response:$response};
		def root($rows; $more; $cursor): {issues:conn($rows;$more;$cursor)};
		def owner: issue("owner";180000) | .labels=conn([{name:("n" * 180000)}];true;"l1");
		def labelReply($id): reply($id;"l1";{issue:{id:$id,labels:conn([{name:("n" * 180000)}];false;null)}});
		if $name == "shape" then
			{initial:root([range(75)|issue("synthetic";4500)];true;"c1"),
			 replies:[reply(null;"c1";root([issue("last-a";1),issue("last-b";1)];false;null))]}
		elif $name == "single" then {initial:root([issue("owner";180000)];false;null),replies:[]}
		elif $name == "cumulative" then
			{initial:root([issue("first";60000)];true;"c1"),replies:[range(1;4) as $n |
			 reply(null;("c"+($n|tostring));root([issue(($n|tostring);60000)];$n<3;("c"+(($n+1)|tostring))))]}
		elif $name == "entity" or $name == "nested" then {initial:{issue:owner},replies:[labelReply("owner")]}
		elif $name == "create" or $name == "update" then
			{initial:{("issue"+(if $name == "create" then "Create" else "Update" end)):{success:true,issue:owner}},replies:[labelReply("owner")]}
		elif $name == "root-rows" then
			{initial:root([issue("first";180000),issue("second";180000)];false;null),replies:[]}
		elif $name == "absent" then {initial:{issue:{id:"owner",description:"short"},project:null},replies:[]}
		elif $name == "children" or $name == "children-recursive" or $name == "children-failure" then
			{initial:{issue:(issue("parent";180000) | .children=conn([
				issue("child-a";180000) | .labels=conn([{name:("n"*180000)}];true;"l1")];true;"ch1"))},
			 replies:[labelReply("child-a"),
			 reply("parent";"ch1";{issue:{id:"parent",children:conn([
				issue("child-b";180000) | .children=conn([issue("grand-a";180000)];true;"g1")];false;null)}}),
			 reply("child-b";"g1";{issue:{id:"child-b",children:conn([issue("grand-b";180000)];false;null)}})]}
		elif $name == "nested-metadata" then
			{initial:{issue:(issue("owner";1)|.labels={nodes:[]})},replies:[]}
		elif $name == "nested-malformed" then
			{initial:{issue:(issue("owner";1)|.labels.pageInfo.hasNextPage=null)},replies:[]}
		elif $name == "nested-missing-nodes" then
			{initial:{issue:(issue("owner";1)|del(.labels.nodes))},replies:[]}
		elif $name == "nested-failure" then {initial:{issue:owner},replies:[]}
		elif $name == "cap" then
			{initial:root([];true;"c1"),replies:[range(1;401) as $n |
			 reply(null;("c"+($n|tostring));root([];$n<400;("c"+(($n+1)|tostring))))]}
		else {initial:root([issue("first";1)];true;"c1"),replies:[reply(null;"c1";root([issue("last";1)];false;null))]}
		end |
		if $name == "missing-metadata" then del(.initial.issues.pageInfo)
		elif $name == "malformed-metadata" then .initial.issues.pageInfo.hasNextPage="true"
		elif $name == "malformed-nodes" then .initial.issues.nodes={}
		elif $name == "missing-cursor" then .initial.issues.pageInfo.endCursor=null
		elif $name == "repeated-cursor" then .replies[0].response.issues.pageInfo={hasNextPage:true,endCursor:"c1"}
		elif $name == "later-page" then .replies=[]
		elif $name == "children-failure" then .replies |= map(select(.after != "g1"))
		else . end
	' >"$PAGE_ROOT/fixture.json" || { assert_fail "$name: fixture generation"; return; }
	# A fixture permits its reply pages and each open connection's initial page.
	# Count across subshells, so recursive initial-page reuse also spends pages.
	# The cap fixture still permits its terminal page beyond the production cap.
	budget=$(jq '1 + (.replies | length) +
		([.initial, .replies[].response | .. | objects |
		  select(.pageInfo.hasNextPage == true)] | length)' "$PAGE_ROOT/fixture.json") || {
		assert_fail "$name: fixture page budget"; return;
	}
	printf '0\n' >"$PAGE_ROOT/page-count"
	# Instrument only this disposable runtime copy. The fixture step is inside
	# the real pager's loop, including walks that never make another request.
	: >"$PAGE_ROOT/pages.sh"
	while IFS= read -r line || [[ -n "$line" ]]; do
		printf '%s\n' "$line" >>"$PAGE_ROOT/pages.sh"
		if [[ "$line" == '    while true; do' ]]; then
			hits=$((hits + 1))
			printf '        pages_step || return 1\n' >>"$PAGE_ROOT/pages.sh"
		fi
	done <"$SKILL_DIR/scripts/lib/pages.sh"
	if (( hits != 1 )); then
		assert_fail "$name: fixture page instrument" "want: one pager loop; got: $hits"
		return
	fi
	cat >"$PAGE_ROOT/subject" <<'SUBJECT'
#!/bin/bash
set -euo pipefail
source "$1"
fixture="$2" mode="$3" limit="$4" log="$5" budget="$6" page_count="$7"
pages_step() {
    local count
    IFS= read -r count <"$page_count" || return 1
    count=$((count + 1))
    printf '%s\n' "$count" >"$page_count" || return 1
    if (( count > budget )); then
        printf 'fixture: page-budget=%s count=%s\n' "$budget" "$count" >&2
        return 1
    fi
}
fixture_data=$(cat -- "$fixture") || exit 1
LINEAR_CHILD_DEPTH=2
LINEAR_ISSUE_CHILD_MODE="$9"
source "$8"
graphql_request() {
    local query="$1" variables="$2" response
    jq -c --arg query "$query" '{query:$query,variables:.}' <<<"$variables" >>"$log" || return 1
    response=$(jq -cs --arg query "$query" '
        def child($depth):
            with_entries(select(.key as $key | $query | test("\\b" + $key + "\\b"))) |
            if $depth <= 1 then del(.children)
            elif has("children") then .children.nodes |= map(child($depth - 1))
            else . end |
            reduce ["relations", "inverseRelations"][] as $field (. ;
                if $query | test("\\b" + $field + "(?:\\([^)]*\\))?\\s*\\{\\s*pageInfo\\b")
                then . else del(.[$field].pageInfo) end);
        .[0] as $vars | .[1] |
        if ($vars.after // null) == null then .initial
        else [.replies[] | select(.id == ($vars.id // null) and .after == $vars.after) | .response][0] end |
        select(. != null) |
        if ($query | startswith("query ContinueConnection")) and ($query | test("\\bchildren\\(")) then
            ($query | [scan("\\bchildren\\(")] | length) as $depth |
            .issue |= {id, children} | .issue.children.nodes |= map(child($depth))
        else . end' <<<"$variables"$'\n'"$fixture_data") || return 1
    if [[ -z "$response" ]]; then
        printf 'fixture: later page failed\n' >&2
        return 1
    fi
    printf '%s\n' "$response"
}
case "$mode" in
pages) graphql_pages 'fixture query' '{}' issues "$limit" ;;
entity)
    data=$(jq -c '.initial.issue' "$fixture") || exit 1
    linear_complete_entity issue "$data" ;;
query) graphql_query 'fixture query' '{}' ;;
*) exit 2 ;;
esac
SUBJECT
	: >"$PAGE_ROOT/requests"
	PAGE_OUT=$(env -i PATH="$PATH" HOME="$PAGE_ROOT" bash "$PAGE_ROOT/subject" \
		"$PAGE_ROOT/pages.sh" "$PAGE_ROOT/fixture.json" "$mode" "$limit" \
		"$PAGE_ROOT/requests" "$budget" "$PAGE_ROOT/page-count" "$SKILL_DIR/scripts/lib/formatters.sh" "$child_mode" \
		2>"$PAGE_ROOT/error") && PAGE_RC=0 || PAGE_RC=$?
	assert_file_lacks "$name: page walk budget" "$PAGE_ROOT/error" 'fixture: page-budget='
}

trap __assert_on_exit EXIT
