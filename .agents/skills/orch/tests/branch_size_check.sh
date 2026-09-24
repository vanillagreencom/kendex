#!/usr/bin/env bash
# Regression tests for branch-size-check, the submit-time size check that
# measures a branch's added lines against the allowance its issue states:
# the classification of every added line, the one allowance grammar, the
# binding of the record to base and head, and reporting without a size refusal.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# The check reads the issue through the Linear CLI beside its own skill, and
# that CLI refuses Bash 3.2, which the macOS suite leg runs. A stand-in at the
# sibling path answers `cache issues get ID --format=raw` from the fixture's
# cache the way the CLI does: {"issue": row} on stdout, or a stderr line and
# exit 1 when the cache holds no such issue. The check under test is a whole
# copy of scripts/ beside it, the same shape every mutant takes.
mkdir -p "$TMP_ROOT/linear/scripts"
cat > "$TMP_ROOT/linear/scripts/linear.sh" <<'SH'
#!/usr/bin/env bash
set -eu
[[ "${1:-}" == cache && "${2:-}" == issues && "${3:-}" == get ]] \
  || { echo "linear stand-in: unsupported call: $*" >&2; exit 2; }
row="$(jq -c --arg id "$4" '.[] | select(.identifier == $id)' .cache/linear/issues.json)"
[[ -n "$row" ]] || { echo "Error: issue $4 not found in cache" >&2; exit 1; }
jq -n --argjson issue "$row" '{issue: $issue}'
SH
chmod +x "$TMP_ROOT/linear/scripts/linear.sh"
CHECK_BIN="$(copy_scripts live)/branch-size-check"

PASS=0
FAIL=0
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

WT="$TMP_ROOT/wt"
mkdir -p "$WT"
git -C "$WT" init -q -b main
git -C "$WT" config user.email test@example.com
git -C "$WT" config user.name Test
git -C "$WT" config commit.gpgsign false
# Rename detection off in the fixture: the check passes --find-renames itself,
# and a control run under a runner that already enables it proves nothing.
git -C "$WT" config diff.renames false
# Path quoting left at git's default in the fixture: the measurement passes
# core.quotePath=false itself, and the control that strips it must see the
# quoting, which a runner whose global config already turns it off would hide.
git -C "$WT" config core.quotePath true
# On the base branch, so a move of them on the branch is a rename in the
# comparison the check makes, and a rewrite of them has deletions to ignore.
mkdir -p "$WT/src" "$WT/tests"
seq 1 120 > "$WT/src/legacy.txt"
seq 1 30 > "$WT/tests/legacy.sh"
seq 1 50 > "$WT/src/rewritten.txt"
git -C "$WT" add -A
git -C "$WT" commit -q -m base
git -C "$WT" switch -q -c size

# The Linear cache the stand-in answers from.
write_issue() {
  mkdir -p "$WT/.cache/linear"
  jq -n --arg body "$1" '[{identifier: "KEN-SIZE", description: $body}]' \
    > "$WT/.cache/linear/issues.json"
}

mk() { mkdir -p "$(dirname "$WT/$2")"; seq 1 "$1" > "$WT/$2"; }
commit_files() { git -C "$WT" add -A; git -C "$WT" commit -q -m "$1"; }

# Both settings the check reads are pinned here: a value exported by whoever
# runs the suite would otherwise decide its assertions. A case that wants one
# sets it back through its own `env` in the command it passes.
run_check() {
  env -u ORCH_SIZE_RENDER_ROOTS -u ORCH_SIZE_TEST_PATHS ORCH_STATE_DIR="$WT/tmp" \
    "$@" --worktree "$WT" --issue KEN-SIZE
}
# Every capture is guarded: a bare command substitution under errexit ends the
# suite at that line, with no tally and every later assertion unrun.
capture() { local __v="$1"; shift; set +e; printf -v "$__v" '%s' "$("$@" 2>/dev/null)"; set -e; }
rc_of() { local __v="$1"; shift; set +e; "$@" >/dev/null 2>&1; printf -v "$__v" '%s' "$?"; set -e; }

# --- Every classification rule, one file per rule, additions alone ----------
write_issue "**Expected delta**: 40 lines, 20 test lines"
init_growth_state "$STATE" "$WT" KEN-SIZE 1-1 12
printf '.cache/\n' >> "$(git -C "$WT" rev-parse --path-format=absolute --git-path info/exclude)"
mk 10 src/impl.txt                  # production
mk 4  src/testing.rs                # production: a name containing 'test' is not a test
mk 2  crates/core/src/tests.rs      # test by basename only
mk 3  crates/core/src/test_util.rs  # test by basename only
mk 4  tests/plain.sh                # test by directory only
mk 5  ui/src/thing.test.ts          # test by .test. infix only
printf 'x\ny\n' > "$WT/src/rewritten.txt"   # 50 deleted, 2 added: bills 2
commit_files implementation

capture split_json run_check "$CHECK_BIN" --json
# Every paste below names its input as `-`: GNU paste reads stdin when it is
# given no file operand, BSD paste prints its usage and exits 2.
assert_eq "$(jq -r '.production_lines, .test_lines' <<<"$split_json" | paste -sd, -)" "16,14" \
  "each is_test rule classifies alone, a name containing 'test' does not, and a rewrite bills only its additions"
assert_eq "$(jq -r '.production_allowance, .test_allowance, .verdict' <<<"$split_json" | paste -sd, -)" \
  "40,20,pass" "the stated line is the production and test allowance"
assert_eq "$(jq -r '.base_sha, .head_sha' <<<"$split_json" | paste -sd, -)" \
  "$(git -C "$WT" rev-parse main HEAD | paste -sd, -)" \
  "the record is bound to the base and head it measured"
assert_eq "$("$STATE" --state-dir "$WT/tmp" get KEN-SIZE '.pr.size_check.verdict')" "pass" \
  "the verdict is recorded in the workflow state's pr object"

# --- A render pairs with the source it renders, and only with that source ---
mk 6 skills/orch/SKILL.md
mk 6 .agents/skills/orch/SKILL.md          # same path under the render root
mk 3 agents/gen.md
mk 3 .codex/agents/gen.toml                # same stem, different extension
mk 2 hooks/h.sh
mk 2 .pi/kendex/hooks/h.sh                 # nested render root
mk 9 .claude/settings.json                 # renders nothing this diff changed
mk 2 ui/src/stores/settings.ts             # same basename, not its source
mk 2 README.md                             # a root source has no directory to pair on
mk 7 .agents/skills/other/README.md        # so this same-basename render is counted
commit_files renders
capture mirror_json run_check "$CHECK_BIN" --json
assert_eq "$(jq -r '.mirror_lines' <<<"$mirror_json")" "11" \
  "a render pairs with its own source across a changed extension and a nested root, never by basename alone"
assert_eq "$(jq -r '.production_lines' <<<"$mirror_json")" "47" \
  "a render whose source did not change stays in production beside a same-basename source"

PAIR_SCRIPTS="$(copy_scripts pairing-mutant)"
PAIR_LIB="$PAIR_SCRIPTS/lib/branch-growth.sh"
assert_eq "$(grep -Fc 'if (rest_stem == s) return 1' "$PAIR_LIB")" "1" \
  "pairing control finds exactly one live match"
sed -i.bak 's/^      rest_stem = stem_path(rest)$/      rest_stem = stem_path(rest); return 1/' "$PAIR_LIB"
capture pair_mutant_json run_check "$PAIR_SCRIPTS/branch-size-check" --json
assert_eq "$(jq -r '.mirror_lines' <<<"$pair_mutant_json")" "27" \
  "must-fail control: without the pairing every render-root path drops out"

# --- A move a size ratchet forced is a rename, not growth -------------------
git -C "$WT" mv src/legacy.txt src/relocated.txt
git -C "$WT" mv tests/legacy.sh src/moved-out.sh
printf 'a\nb\nc\n' >> "$WT/src/moved-out.sh"
commit_files ratchet-move
capture rename_json run_check "$CHECK_BIN" --json
assert_eq "$(jq -r '.production_lines' <<<"$rename_json")" "50" \
  "a pure rename bills no lines, and an edited move bills only its additions"
assert_eq "$(jq -r '.test_lines' <<<"$rename_json")" "14" \
  "a move out of a test directory is classified by the path it landed on"

# --- The one allowance grammar, and what falls outside it -------------------
# Row: the header line as the issue states it | allowance,test allowance,verdict | exit
while IFS='|' read -r line want_fields want_rc; do
  write_issue "$line"
  set +e
  row_json="$(run_check "$CHECK_BIN" --json 2>/dev/null)"
  row_rc=$?
  set -e
  assert_eq "$row_rc" "$want_rc" "exit for: $line"
  [[ "$want_rc" != 0 ]] || assert_eq \
    "$(jq -r '.production_lines, .test_lines, .production_allowance, .test_allowance, .verdict' <<<"$row_json" | paste -sd, -)" \
    "50,14,$want_fields" "record for: $line"
done <<'ROWS'
**Expected delta**: 250 lines|250,null,pass|0
**Expected delta**: 250 lines, 120 test lines|250,120,pass|0
**Expected delta**: 40 lines, 20 test lines|40,20,over|0
**Expected delta**: 1 line|1,null,over|0
**Expected delta**: 1 line, 1 test line|1,1,over|0
**Expected delta**: 1 lines||3
**Expected delta**: 1 lines, 1 test line||3
**Expected delta**: 2 line||3
**Expected delta**: 2 line, 2 test line||3
**Expected delta**: 250 line||3
**Expected delta**: 250 line, 120 test line||3
**Expected delta**: about 250 lines||3
**Expected delta**: 200-300 lines||3
**Expected delta**: -250 lines||3
**Expected delta**: 1 lien||3
A sentence about an expected delta of 9 lines somewhere.|null,null,allowance_missing|0
ROWS

write_issue "no header line at all"
set +e
missing_error="$(run_check "$CHECK_BIN" 2>&1 >/dev/null)"
missing_rc=$?
set -e
assert_eq "$missing_rc" "0" "an issue stating no allowance is reported, not refused and not defaulted"
assert_eq "$([[ "${missing_error%%$'\n'*}" == "branch-size-check: allowance_missing production=50 tests=14 mirror="*" allowance=none test-allowance=none" ]] && echo yes)" \
  "yes" "the report names the missing line and the counts measured"
assert_eq "$(printf '%s\n' "$missing_error" | sed -n 2p)" \
  "No allowance was stated. Report the measured counts for review." \
  "an issue that was read and states no line keeps its own sentence"
assert_eq "$("$STATE" --state-dir "$WT/tmp" get KEN-SIZE '.pr.size_check.verdict, .pr.size_check.production_allowance' | paste -sd, -)" \
  "allowance_missing,null" "the record says nothing was judged and invents no allowance"

# --- Past the production allowance ------------------------------------------
write_issue "**Expected delta**: 40 lines, 20 test lines"
mk 60 src/impl.txt
commit_files production-growth
set +e
prod_error="$(run_check "$CHECK_BIN" 2>&1 >/dev/null)"
prod_rc=$?
set -e
assert_eq "$prod_rc" "0" "a branch past its production allowance reports and continues"
assert_eq "$([[ "${prod_error%%$'\n'*}" == "branch-size-check: over production=100 tests="*" allowance=40 test-allowance=20" ]] && echo yes)" \
  "yes" "the production report prints the count and the allowance"
assert_eq "$("$STATE" --state-dir "$WT/tmp" get KEN-SIZE '.pr.size_check.verdict')" "over" \
  "the over verdict is recorded with its reason"

# --- Past the test allowance -------------------------------------------------
write_issue "**Expected delta**: 50 lines, 20 test lines"
mk 10 src/impl.txt
mk 40 tests/plain.sh
commit_files test-growth
set +e
test_error="$(run_check "$CHECK_BIN" 2>&1 >/dev/null)"
test_rc=$?
set -e
assert_eq "$test_rc" "0" "a branch past its test allowance reports and continues"
assert_eq "$([[ "${test_error%%$'\n'*}" == "branch-size-check: over production="*" tests=50 mirror="*" test-allowance=20" ]] && echo yes)" \
  "yes" "the test report prints the count and the allowance"

# Restore the size refusal in a private copy: the same over-allowance input
# must make the report-and-continue assertion fail.
REPORT_SCRIPTS="$(copy_scripts report-mutant)"
REPORT_MUTANT="$REPORT_SCRIPTS/branch-size-check"
assert_eq "$(grep -c '^exit 0$' "$REPORT_MUTANT")" "1" "control finds the measured exit"
sed -i.bak 's/^exit 0$/exit 3/' "$REPORT_MUTANT"
assert_eq "$([[ ! -L "$REPORT_MUTANT" ]] && ! cmp -s "$REPORT_MUTANT" "$CHECK_BIN" && echo changed)" "changed" "control changes the private script"
rc_of mutant_report_rc run_check "$REPORT_MUTANT"
assert_eq "$mutant_report_rc" "3" "control: the size refusal rejects the report-and-continue case"

write_issue "**Expected delta**: 50 lines"
rc_of unjudged_rc run_check "$CHECK_BIN"
assert_eq "$unjudged_rc" "0" "with no test count the test lines are shown and not judged"

# --- A GitHub-tracked issue reads the same line from its body ---------------
GH_STUB="$TMP_ROOT/bin"
mkdir -p "$GH_STUB"
printf '#!/usr/bin/env bash\nprintf "%%s" "**Expected delta**: 50 lines, 60 test lines"\n' > "$GH_STUB/gh"
chmod +x "$GH_STUB/gh"
"$STATE" --state-dir "$WT/tmp" init issue-77 --worktree "$WT" --branch size >/dev/null
capture gh_json env PATH="$GH_STUB:$PATH" ORCH_STATE_DIR="$WT/tmp" \
  "$CHECK_BIN" --worktree "$WT" --issue issue-77 --json
assert_eq "$(jq -r '.production_allowance, .test_allowance, .verdict' <<<"$gh_json" | paste -sd, -)" \
  "50,60,pass" "a GitHub issue body supplies the same allowance"

# --- An issue the tracker cannot give is an environment failure -------------
jq -n '[{identifier: "KEN-OTHER", description: "another issue"}]' > "$WT/.cache/linear/issues.json"
rc_of unread_rc run_check "$CHECK_BIN"
assert_eq "$unread_rc" "2" "an issue absent from the cache exits 2 rather than judging by nothing"

# --- A pr-N key names no issue: measured, not refused ------------------------
# The repository-local fallback for a branch carrying no issue id. The cache
# here holds no such row, so a key that reached the tracker would exit 2.
"$STATE" --state-dir "$WT/tmp" init pr-51 --worktree "$WT" --branch size >/dev/null
run_pr_check() {
  env -u ORCH_SIZE_RENDER_ROOTS -u ORCH_SIZE_TEST_PATHS ORCH_STATE_DIR="$WT/tmp" \
    "$@" --worktree "$WT" --issue pr-51
}
capture pr_json run_pr_check "$CHECK_BIN" --json
assert_eq "$(jq -r '.verdict, .production_allowance, .test_allowance, .production_lines, .test_lines' <<<"$pr_json" | paste -sd, -)" \
  "allowance_missing,null,null,50,50" \
  "a pr-N key is measured under allowance_missing, with no allowance invented"
# The mirror count is not this case's subject, so it is matched loosely, the
# way the sibling allowance_missing report line is.
assert_eq "$([[ "$(jq -r '.reason' <<<"$pr_json")" == "'pr-51' names no issue, so no allowance was read; 50 production, 50 test and "*" render-mirror lines added, none judged" ]] && echo yes)" \
  "yes" "the reason names the no-issue cause, not an issue that states no line"
assert_eq "$("$STATE" --state-dir "$WT/tmp" get pr-51 '.pr.size_check.verdict')" "allowance_missing" \
  "the pr-N verdict is recorded in the workflow state's pr object"
set +e
pr_error="$(run_pr_check "$CHECK_BIN" 2>&1 >/dev/null)"
set -e
assert_eq "$(printf '%s\n' "$pr_error" | sed -n 2p)" \
  "The key names no issue, so no allowance was read. Report the measured counts for review." \
  "the report's sentence names the no-issue cause"

# A near-miss key is not the fallback: it reaches the tracker and refuses.
"$STATE" --state-dir "$WT/tmp" init pr-51x --worktree "$WT" --branch size >/dev/null
rc_of near_miss_rc env -u ORCH_SIZE_RENDER_ROOTS -u ORCH_SIZE_TEST_PATHS ORCH_STATE_DIR="$WT/tmp" \
  "$CHECK_BIN" --worktree "$WT" --issue pr-51x
assert_eq "$near_miss_rc" "2" "a key outside the pr-N shape still reaches the tracker"

PR_MUTANT_SCRIPTS="$(copy_scripts pr-key-mutant)"
PR_MUTANT="$PR_MUTANT_SCRIPTS/branch-size-check"
mutate_file "$PR_MUTANT" 'NO_ISSUE_KEY_GRAMMAR='"'"'^pr-[0-9]+$'"'"'' 'NO_ISSUE_KEY_GRAMMAR='"'"'^$'"'"''
set +e
pr_mutant_error="$(run_pr_check "$PR_MUTANT" 2>&1 >/dev/null)"
pr_mutant_rc=$?
set -e
assert_eq "$pr_mutant_rc,${pr_mutant_error%%$'\n'*}" "2,branch-size-check: linear-read issue=pr-51" \
  "control: without the no-issue key the same run is a tracker-read refusal"

# --- A cut retry on a pr-N key is judged against its recorded comparison -----
# review-pr-comments keys a branch with no issue id pr-N, and a cut chosen
# there retries through --cut-from-round. The comparison, not the key, states
# the allowance.
CUT_ROUND="$TMP_ROOT/pr-cut-round.json"
jq -n '{issue: "pr-51", cut: true,
        cut_comparison: {production_lines: 9, test_lines: 9,
                         production_allowance: 9, test_allowance: 9}}' > "$CUT_ROUND"
capture pr_cut_json run_pr_check "$CHECK_BIN" --cut-from-round "$CUT_ROUND" --json
assert_eq "$(jq -r '.production_allowance, .test_allowance, .verdict' <<<"$pr_cut_json" | paste -sd, -)" \
  "9,9,over" "a pr-N cut retry is judged against the comparison's allowance, not left unjudged"

# The cut source also carries the round record's validation, which a no-issue
# key must not skip.
BAD_CUT_ROUND="$TMP_ROOT/pr-cut-round-bad.json"
jq -n '{issue: "pr-51", cut: true, cut_comparison: "not an object"}' > "$BAD_CUT_ROUND"
set +e
bad_cut_error="$(run_pr_check "$CHECK_BIN" --cut-from-round "$BAD_CUT_ROUND" 2>&1 >/dev/null)"
bad_cut_rc=$?
set -e
assert_eq "$bad_cut_rc,${bad_cut_error%%$'\n'*}" "2,branch-size-check: invalid-round path=$BAD_CUT_ROUND" \
  "a pr-N cut retry still refuses a round record it cannot read"

# Control: clear the cut source for a no-issue key. Both the allowance and the
# record's validation are read from it, so the one mutation drops them
# together, which is what pins the comparison rather than the key as the
# allowance these two rows measure against.
CUT_SOURCE_SCRIPTS="$(copy_scripts pr-cut-source-mutant)"
CUT_SOURCE_MUTANT="$CUT_SOURCE_SCRIPTS/branch-size-check"
mutate_file "$CUT_SOURCE_MUTANT" 'no_issue=false' \
  'if [[ "$issue" =~ $NO_ISSUE_KEY_GRAMMAR ]]; then no_issue=true; cut_from_round=""; else no_issue=; fi'
capture cut_source_json run_pr_check "$CUT_SOURCE_MUTANT" --cut-from-round "$CUT_ROUND" --json
assert_eq "$(jq -r '.verdict' <<<"$cut_source_json")" "allowance_missing" \
  "control: a no-issue key with its cut source cleared loses the comparison's allowance"
rc_of cut_source_rc run_pr_check "$CUT_SOURCE_MUTANT" --cut-from-round "$BAD_CUT_ROUND"
assert_eq "$cut_source_rc" "0" \
  "control: the same cleared source skips the round record's validation"

# --- The state file is the one named, not the one the caller stands in ------
write_issue "**Expected delta**: 50 lines"
STATE_DIR="$TMP_ROOT/elsewhere"
mkdir -p "$STATE_DIR"
"$STATE" --state-dir "$STATE_DIR" init KEN-SIZE --worktree "$WT" --branch size >/dev/null
set +e
(cd "$TMP_ROOT" && env -u ORCH_STATE_DIR "$CHECK_BIN" --worktree "$WT" --issue KEN-SIZE --state-dir "$STATE_DIR" >/dev/null 2>&1)
set -e
assert_eq "$("$STATE" --state-dir "$STATE_DIR" get KEN-SIZE '.pr.size_check.verdict')" "pass" \
  "--state-dir decides which state is read and written, not the caller's directory"

# --- ORCH_SIZE_TEST_PATHS adds to the built-in test rule --------------------
# A suite the repository keeps at a production path: no built-in rule names it,
# so the setting is the only thing that can move its lines to the test count.
mk 7 scripts/check-helper.py
mk 3 scripts/check-helperXpy        # the glob's dot is literal, so not this
mk 2 scripts/probe-a.sh             # one character where the glob's ? sits
mk 4 scripts/probe-ab.sh            # two, so a ? read as * moves this one too
mk 6 scripts/star-x.py              # what a backslash-stripped star would take
mk 5 scripts/check-nested/deep.py   # only a star spanning a slash reaches this
mk 8 vendor/scripts/probe-z.sh      # carries a glob, so only the anchors refuse it
commit_files repo-test-path
capture declared_json run_check \
  env ORCH_SIZE_TEST_PATHS='scripts/check-*.py scripts/probe-?.sh' "$CHECK_BIN" --json
assert_eq "$(jq -r '.production_lines, .test_lines' <<<"$declared_json" | paste -sd, -)" "71,64" \
  "a declared glob moves the paths it names alone, its dot matching a dot, its ? one character, its star a slash, and its whole-path anchors refusing a path that merely carries it"
capture undeclared_json run_check "$CHECK_BIN" --json
assert_eq "$(jq -r '.production_lines, .test_lines' <<<"$undeclared_json" | paste -sd, -)" "85,50" \
  "must-fail control: with the setting unset the same lines are production"
# The globs reach the classifier through the environment, where awk performs no
# escape processing on them. Carried by a -v assignment instead, gawk would
# strip the backslash below and the bare star would take star-x.py, while mawk
# would leave the same setting matching nothing.
capture escaped_json run_check \
  env ORCH_SIZE_TEST_PATHS='scripts/probe-a.sh scripts/star-\*.py' "$CHECK_BIN" --json
assert_eq "$(jq -r '.production_lines, .test_lines' <<<"$escaped_json" | paste -sd, -)" "83,52" \
  "a backslash arrives as itself, so a glob carrying one names a path with a backslash and moves none of these"

# --- A non-ASCII test path is classified by its rule, not by git's quoting ---
# git wraps a path holding a non-ASCII byte in double quotes and escapes the
# byte unless core.quotePath is off. The leading quote moves the path's first
# segment away from `tests`, so the built-in test rule stops naming it.
mk 9 'tests/prüf.py'
commit_files non-ascii-test-path
capture non_ascii_json run_check "$CHECK_BIN" --json
assert_eq "$(jq -r '.production_lines, .test_lines' <<<"$non_ascii_json" | paste -sd, -)" "85,59" \
  "a test path holding a non-ASCII character counts as a test path"

QUOTE_SCRIPTS="$(copy_scripts quotepath-mutant)"
QUOTE_LIB="$QUOTE_SCRIPTS/lib/branch-growth.sh"
assert_eq "$(grep -Fc -e '-c core.quotePath=false' "$QUOTE_LIB")" "1" \
  "quoting control finds exactly one live setting"
sed -i.bak 's/ -c core\.quotePath=false//' "$QUOTE_LIB"
capture quote_mutant_json run_check "$QUOTE_SCRIPTS/branch-size-check" --json
assert_eq "$(jq -r '.production_lines, .test_lines' <<<"$quote_mutant_json" | paste -sd, -)" "94,50" \
  "must-fail control: without that setting the quoted path scores as production"

# --- A private env file that prints leaves stdout to the record -------------
# Untracked, so the measurement is unchanged; KENDEX_ENV_FILE is unset so the
# loader reads this file and not one the runner names.
printf 'echo env-file-output\n' > "$WT/.env.local"
capture noisy_env_json run_check env -u KENDEX_ENV_FILE "$CHECK_BIN" --json
assert_eq "$(jq -r 'type' <<<"$noisy_env_json" 2>&1)" "object" \
  "an env file that prints leaves --json stdout one parseable record"

rm -f -- "$WT/.env.local"

printf '\npass: %d  fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
