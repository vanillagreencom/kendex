#!/usr/bin/env bash
# `scope_current_run` lived in TWO places — orch `ci-wait` and github
# `pr-merge.sh` — each carrying a comment that it must stay aligned with the
# other "byte-for-byte". Nothing enforced that, and they drifted: `ci-wait` grew
# substantive-run selection and stale-status rewriting (kendex#607) while
# `pr-merge.sh` kept the original max-run-id version (kendex#492). A merge gate
# and the waiter feeding it were then scoping the same rollup by different rules
# (kendex#876).
#
# These tests (a) pin the shared implementation's behaviour and (b) fail if
# either script grows a local copy again, so the drift cannot silently return.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
LIB="$REPO_ROOT/skills/github/scripts/lib/ci-run-correlation.sh"

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

[[ -f "$LIB" ]] || { echo "FATAL: shared library missing at $LIB"; exit 1; }
# shellcheck source=../scripts/lib/ci-run-correlation.sh
source "$LIB"

echo "=== single implementation ==="

# Three rounds of review found this guard blind to a spelling it had not been
# taught — indentation, then extra whitespace, then a definition split across
# newlines. The common cause is not the patterns: it is that `grep` judges one
# line at a time, while jq and bash read a token stream where a newline is just
# another space. A guard matching lines can only ever chase the next layout.
#
# So the scans do not read lines. Each file is reduced once to a canonical
# form — whole-line comments dropped, then every run of whitespace, newlines
# included, collapsed to a single space — and the patterns match that. One
# transformation closes indentation, whitespace variants and multiline splits
# together, and a fourth layout does not need a fourth pattern.
#
# Two other ways a grep verdict lied about the program, both closed here: it
# exits 2 on a file that is not there, which an `if` reads as "no match", so
# every scan answers `missing` first; and it matches text the language never
# runs, so a `# shellcheck source=...ci-run-correlation.sh` directive used to
# satisfy the check for the `source` command it sits above — exactly when that
# command had been deleted. Comments come out before anything is matched.
#
# What this still cannot see, stated rather than left to be found:
#   - Only WHOLE-LINE comments are removed. Stripping a trailing `#` would
#     maim `${v#prefix}` and any `"#"` in a string, so `x=1  # def bucket:`
#     reads as drift. That is a false alarm, not a miss — it fails closed.
#   - The indirect source check assumes the library path holds no spaces; a
#     path that did would read as `absent`, which fails the suite rather than
#     passing it.
#   - It is text, not a parser. A `source` command or a `def` assembled at
#     runtime through `eval` is invisible to it, as it would be to any
#     static scan.

# A file reduced to one normalized line. Whole-line comments go first, so
# nothing matched here is text the interpreter never runs.
code_text() {
  { grep -vE '^[[:space:]]*#' "$1" || true; } | tr -s '[:space:]' ' '
}

readable() { [[ -f "$1" && -r "$1" ]]; }

# Against the normalized form, jq's `def bucket:` / `def runid:` has exactly
# two shapes left: with and without a space before the colon.
DRIFT_DEF_RE='(^|[^A-Za-z0-9_])def (bucket|runid) ?:'
# Likewise a bash definition of scope_current_run: the `function` keyword form
# and the parenthesized form, the parens optional after the keyword.
SCOPE_FN_RE='(^|[^A-Za-z0-9_])(function scope_current_run( ?\( ?\))? ?\{|scope_current_run ?\( ?\))'
# An executable `source`/`.` command naming the library outright — how
# pr-merge.sh and ci-classify-refusal.sh reach it.
LIB_SOURCE_RE='(^|[^A-Za-z0-9_])(source|\.) [^ ]*ci-run-correlation\.sh'
# An assignment parking the library path in a variable — how ci-wait reaches
# it, one indirection away from the filename.
LIB_ASSIGN_RE='[A-Za-z_][A-Za-z0-9_]*=[^ ]*ci-run-correlation\.sh'

# missing | local | shared
scope_target_state() {
  readable "$1" || { printf 'missing\n'; return; }
  if code_text "$1" | grep -qE "$SCOPE_FN_RE"; then printf 'local\n'; else printf 'shared\n'; fi
}

# missing | absent | sources — an executable source of the library, direct or
# through a variable holding its path. A mention in a comment is not one.
lib_source_state() {
  readable "$1" || { printf 'missing\n'; return; }
  local text var
  text="$(code_text "$1")"
  if grep -qE "$LIB_SOURCE_RE" <<<"$text"; then printf 'sources\n'; return; fi
  while read -r var; do
    [[ -n "$var" ]] || continue
    if grep -qE '(^|[^A-Za-z0-9_])(source|\.) [^ ]*\$\{?'"$var"'([^A-Za-z0-9_]|$)' <<<"$text"; then
      printf 'sources\n'
      return
    fi
  done < <(grep -oE "$LIB_ASSIGN_RE" <<<"$text" | sed -E 's/=.*//')
  printf 'absent\n'
}

# missing | drift | clean
local_defs_state() {
  readable "$1" || { printf 'missing\n'; return; }
  if code_text "$1" | grep -qE "$DRIFT_DEF_RE"; then printf 'drift\n'; else printf 'clean\n'; fi
}

missing_target() { fail "$1 is missing or unreadable at $2 (scan target moved or the path is a typo)"; }

for script in "$REPO_ROOT/skills/orch/scripts/ci-wait" \
              "$REPO_ROOT/skills/github/scripts/commands/pr-merge.sh" \
              "$REPO_ROOT/skills/github/scripts/commands/ci-classify-refusal.sh"; do
  name="$(basename "$script")"
  case "$(scope_target_state "$script")" in
    missing) missing_target "$name" "$script" ;;
    local)   fail "$name defines its own scope_current_run (drift reintroduced — source the shared library instead)" ;;
    shared)  pass "$name does not define its own scope_current_run" ;;
  esac
  case "$(lib_source_state "$script")" in
    missing) missing_target "$name" "$script" ;;
    sources) pass "$name sources the shared library" ;;
    absent)  fail "$name sources the shared library" ;;
  esac
done

# The bucket taxonomy and run-id capture are exported as CI_RUN_JQ_DEFS; a
# consumer inlining its own `def bucket`/`def runid` copy is the same drift one
# layer down. Covers orch `ci-wait` as well as the GitHub commands.
for script in "$REPO_ROOT/skills/orch/scripts/ci-wait" \
              "$REPO_ROOT"/skills/github/scripts/commands/*.sh; do
  name="$(basename "$script")"
  case "$(local_defs_state "$script")" in
    missing) missing_target "$name" "$script" ;;
    drift)   fail "$name inlines its own def bucket/def runid (prepend CI_RUN_JQ_DEFS from the shared library instead)" ;;
    clean)   pass "$name has no local def bucket/def runid copy" ;;
  esac
done

echo "=== scan guards ==="

# A scan is only worth its green if it goes red on what it exists to catch and
# stays green on what it does not. Every state helper above is put to both.
FIXTURES="$(mktemp -d)"
trap 'rm -rf "$FIXTURES"' EXIT

state_is() {
  local want="$1" got="$2" what="$3"
  if [[ "$got" == "$want" ]]; then pass "$what"; else fail "$what (got $got, want $want)"; fi
}

# (1) A target that is not there is never a clean scan.
GONE="$REPO_ROOT/skills/orch/scripts/ci-waitX"
state_is missing "$(local_defs_state "$GONE")"    "a mistyped scan path reports missing, not clean"
state_is missing "$(scope_target_state "$GONE")"  "a mistyped scope-scan path reports missing, not shared"
state_is missing "$(lib_source_state "$GONE")"    "a mistyped library-source path reports missing, not absent"
state_is missing "$(local_defs_state "$FIXTURES")" "a directory in place of a script reports missing"

# (2) The drift scan takes every jq spelling, layout included, and only
# executable ones.
printf 'def bucket:\n' > "$FIXTURES/plain.sh"
state_is drift "$(local_defs_state "$FIXTURES/plain.sh")" "a plain def bucket copy is caught"

printf 'def  bucket :\n' > "$FIXTURES/spaced.sh"
state_is drift "$(local_defs_state "$FIXTURES/spaced.sh")" "a whitespace-variant def bucket copy is caught"

printf '  def\trunid  :\n' > "$FIXTURES/tabbed.sh"
state_is drift "$(local_defs_state "$FIXTURES/tabbed.sh")" "a tab-separated def runid copy is caught"

printf 'jq -r %s\n  def\n  bucket\n  :\n  1;\n  bucket\n%s\n' "'" "'" > "$FIXTURES/multiline.sh"
state_is drift "$(local_defs_state "$FIXTURES/multiline.sh")" "a def split across newlines is caught"

printf '# a local `def bucket:` copy is the drift this library kills\n' > "$FIXTURES/commented-def.sh"
state_is clean "$(local_defs_state "$FIXTURES/commented-def.sh")" "a def bucket inside a comment is not drift"

printf 'x=$(undef bucketing:1)\n' > "$FIXTURES/near-miss.sh"
state_is clean "$(local_defs_state "$FIXTURES/near-miss.sh")" "a word ending in def, and a name starting with bucket, are not drift"

# (3) The scope scan takes every bash spelling, layout included, and only
# executable ones.
printf 'scope_current_run() {\n  :\n}\n' > "$FIXTURES/fn-plain.sh"
state_is local "$(scope_target_state "$FIXTURES/fn-plain.sh")" "a column-1 scope_current_run definition is caught"

printf '  scope_current_run () {\n    :\n  }\n' > "$FIXTURES/fn-indented.sh"
state_is local "$(scope_target_state "$FIXTURES/fn-indented.sh")" "an indented scope_current_run definition is caught"

printf 'function scope_current_run {\n  :\n}\n' > "$FIXTURES/fn-keyword.sh"
state_is local "$(scope_target_state "$FIXTURES/fn-keyword.sh")" "a function-keyword scope_current_run definition is caught"

# The brace may sit on its own line, and after the `function` keyword so may
# everything else; both parse.
printf 'scope_current_run ()\n{\n  :\n}\n' > "$FIXTURES/fn-multiline.sh"
state_is local "$(scope_target_state "$FIXTURES/fn-multiline.sh")" "a definition whose brace is on the next line is caught"

printf 'function scope_current_run\n{\n  :\n}\n' > "$FIXTURES/fn-kw-multiline.sh"
state_is local "$(scope_target_state "$FIXTURES/fn-kw-multiline.sh")" "a function-keyword definition split across newlines is caught"

printf '# scope_current_run() { the old local copy, deleted\n' > "$FIXTURES/fn-commented.sh"
state_is shared "$(scope_target_state "$FIXTURES/fn-commented.sh")" "a commented-out scope_current_run is not a local copy"

printf 'checks | scope_current_run | jq .\n' > "$FIXTURES/fn-call.sh"
state_is shared "$(scope_target_state "$FIXTURES/fn-call.sh")" "calling scope_current_run is not defining it"

# (4) The library-source scan wants the command, not the shellcheck directive
# that sits above it — the mention outlives the command it documents.
printf '# shellcheck source=../lib/ci-run-correlation.sh\nsource "$DIR/../lib/ci-run-correlation.sh"\n' > "$FIXTURES/src-direct.sh"
state_is sources "$(lib_source_state "$FIXTURES/src-direct.sh")" "a direct source of the library is seen"

printf 'LIB="$DIR/../lib/ci-run-correlation.sh"\n# shellcheck source=../lib/ci-run-correlation.sh\nsource "$LIB"\n' > "$FIXTURES/src-var.sh"
state_is sources "$(lib_source_state "$FIXTURES/src-var.sh")" "a source through a variable holding the path is seen"

printf 'LIB="$DIR/../lib/ci-run-correlation.sh"\n. "$LIB"\n' > "$FIXTURES/src-dot.sh"
state_is sources "$(lib_source_state "$FIXTURES/src-dot.sh")" "a dot-command source is seen"

printf '# shellcheck source=../lib/ci-run-correlation.sh\n# source "$DIR/../lib/ci-run-correlation.sh"\n' > "$FIXTURES/src-gone.sh"
state_is absent "$(lib_source_state "$FIXTURES/src-gone.sh")" "a deleted source command is absent even with the shellcheck directive left behind"

printf 'LIB="$DIR/../lib/ci-run-correlation.sh"\necho "$LIB"\n' > "$FIXTURES/src-mention.sh"
state_is absent "$(lib_source_state "$FIXTURES/src-mention.sh")" "naming the library without sourcing it is absent"

# (5) A script that only sources the library is clean on both drift scans.
printf 'source lib/ci-run-correlation.sh\n' > "$FIXTURES/clean.sh"
state_is clean  "$(local_defs_state "$FIXTURES/clean.sh")"   "a library-sourcing script scans clean"
state_is shared "$(scope_target_state "$FIXTURES/clean.sh")" "a library-sourcing script defines no scope_current_run"

echo "=== scoping behaviour ==="

run_scope() { scope_current_run <<<"$1"; }
names_of() { jq -r '[.[] | .name] | sort | join(",")' <<<"$1"; }

# An approval-gated repo can dispatch an all-SKIPPED no-op run AFTER the
# substantive one. The newer run must not win just because its id is higher.
NOOP='[
 {"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"https://x/actions/runs/100/job/1"},
 {"name":"build","state":"SKIPPED","bucket":"skipping","workflow":"CI","startedAt":"2026-07-26T10:06:00Z","link":"https://x/actions/runs/200/job/2"}
]'
OUT="$(run_scope "$NOOP")"
if [[ "$(jq -r '.[0].link' <<<"$OUT")" == *"/runs/100/"* ]] && [[ "$(jq 'length' <<<"$OUT")" == 1 ]]; then
  pass "a later all-skipped run does not supersede the substantive one"
else
  fail "a later all-skipped run does not supersede the substantive one (got $OUT)"
fi

# Checks with no parseable run id are always kept, deduped by name on startedAt.
NORUN='[
 {"name":"external","state":"SUCCESS","bucket":"pass","workflow":"","startedAt":"2026-07-26T10:00:00Z","link":""},
 {"name":"external","state":"FAILURE","bucket":"fail","workflow":"","startedAt":"2026-07-26T10:09:00Z","link":""}
]'
OUT="$(run_scope "$NORUN")"
if [[ "$(jq 'length' <<<"$OUT")" == 1 ]] && [[ "$(jq -r '.[0].state' <<<"$OUT")" == "FAILURE" ]]; then
  pass "run-less checks dedupe by name keeping the latest startedAt"
else
  fail "run-less checks dedupe by name keeping the latest startedAt (got $OUT)"
fi

# Distinct workflows are never collapsed into one another.
TWO='[
 {"name":"a","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"https://x/actions/runs/100/job/1"},
 {"name":"b","state":"SUCCESS","bucket":"pass","workflow":"Guard","startedAt":"2026-07-26T10:00:00Z","link":"https://x/actions/runs/50/job/2"}
]'
OUT="$(run_scope "$TWO")"
[[ "$(names_of "$OUT")" == "a,b" ]] \
  && pass "distinct workflows are both preserved" \
  || fail "distinct workflows are both preserved (got $(names_of "$OUT"))"

echo "=== kendex#876 reported shape ==="

# The reported rollup, with the run ids and job `startedAt` values taken from
# the real head (vanillagreencom/hyprtrade#419 @ 1d9b5e7):
#
#   run 30201902682  pull_request_review, attempt 1, CANCELLED by concurrency
#                    jobs 12:21:43-12:21:56 — the "zero-second failures"
#   run 30201726860  pull_request, attempt 2 (a RERUN), SUCCESS
#                    jobs 12:22:07-12:23:31, `CI Required` published 12:28:48
#
# The rerun carries the LOWER run id because a new attempt reuses the original
# run's id, so max-run-id picked the cancelled run and leaked its artifacts into
# `pr-merge --check` while `ci-wait` — already rerun-aware via kendex#699 —
# reported pass. Ranking on when the checks actually ran resolves that: the
# rerun's jobs start after the cancelled run's.
DUP='[
 {"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T12:22:11Z","link":"https://x/actions/runs/30201726860/job/1"},
 {"name":"CI Gate Publisher","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T12:23:26Z","link":"https://x/actions/runs/30201726860/job/2"},
 {"name":"CI Required","state":"SUCCESS","bucket":"pass","workflow":"","startedAt":"2026-07-26T12:28:48Z","link":"https://x/actions/runs/30201726860"},
 {"name":"CI Gate Publisher","state":"FAILURE","bucket":"fail","workflow":"CI","startedAt":"2026-07-26T12:21:56Z","link":"https://x/actions/runs/30201902682/job/9"},
 {"name":"build","state":"CANCELLED","bucket":"cancel","workflow":"CI","startedAt":"2026-07-26T12:21:45Z","link":"https://x/actions/runs/30201902682/job/10"}
]'
OUT="$(run_scope "$DUP")"
if jq -e '[.[] | select(.state == "FAILURE" or .state == "CANCELLED")] | length == 0' >/dev/null <<<"$OUT"; then
  pass "the cancelled duplicate run's failures are scoped out (#876)"
else
  fail "the cancelled duplicate run's failures are scoped out (#876) (got $OUT)"
fi
if jq -e '[.[] | select(.name == "CI Required" and .state == "SUCCESS")] | length == 1' >/dev/null <<<"$OUT"; then
  pass "the required aggregate stays green and is not rewritten"
else
  fail "the required aggregate stays green and is not rewritten (got $OUT)"
fi
if jq -e 'all(.[]; (.link | test("/runs/30201902682/") | not))' >/dev/null <<<"$OUT"; then
  pass "no check from the cancelled run reaches the merge gate"
else
  fail "no check from the cancelled run reaches the merge gate (got $OUT)"
fi

echo "=== rank ordering guardrails ==="

# Fail-closed must survive the switch away from run-id order. A newer run that
# is still QUEUED has no usable timestamp; it must NOT lose to a completed older
# run, or a merge could proceed while replacement work is in flight.
QUEUED='[
 {"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"https://x/actions/runs/100/job/1"},
 {"name":"build","state":"QUEUED","bucket":"pending","workflow":"CI","startedAt":"0001-01-01T00:00:00Z","link":"https://x/actions/runs/200/job/2"}
]'
OUT="$(run_scope "$QUEUED")"
if [[ "$(jq -r '.[0].link' <<<"$OUT")" == *"/runs/200/"* ]] && [[ "$(jq 'length' <<<"$OUT")" == 1 ]]; then
  pass "a queued newer run with no timestamp still wins (run-id fallback)"
else
  fail "a queued newer run with no timestamp still wins (run-id fallback) (got $OUT)"
fi

# A genuinely later run that failed is still a failure — time ordering must not
# become a way for an older green run to mask a real regression.
LATERFAIL='[
 {"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"https://x/actions/runs/100/job/1"},
 {"name":"build","state":"FAILURE","bucket":"fail","workflow":"CI","startedAt":"2026-07-26T10:30:00Z","link":"https://x/actions/runs/200/job/2"}
]'
OUT="$(run_scope "$LATERFAIL")"
if [[ "$(jq -r '.[0].state' <<<"$OUT")" == "FAILURE" ]] && [[ "$(jq 'length' <<<"$OUT")" == 1 ]]; then
  pass "a later failing run stays terminal"
else
  fail "a later failing run stays terminal (got $OUT)"
fi

# The stale-aggregate rewrite follows the same ordering as run selection.
STALE='[
 {"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"https://x/actions/runs/100/job/1"},
 {"name":"CI Required","state":"SUCCESS","bucket":"pass","workflow":"","startedAt":"2026-07-26T10:01:00Z","link":"https://x/actions/runs/100"},
 {"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:30:00Z","link":"https://x/actions/runs/200/job/2"}
]'
OUT="$(run_scope "$STALE")"
if jq -e '[.[] | select(.name == "CI Required" and .state == "EXPECTED")] | length == 1' >/dev/null <<<"$OUT"; then
  pass "an aggregate pointing at a superseded run is held pending"
else
  fail "an aggregate pointing at a superseded run is held pending (got $OUT)"
fi
if [[ "$(jq -r "$CI_RUN_JQ_DEFS"'head_runs | join(",")' <<<"$OUT")" == "200" ]]; then
  pass "a status held EXPECTED keeps its retired run out of head_runs"
else
  fail "a status held EXPECTED keeps its retired run out of head_runs (got $(jq -c "$CI_RUN_JQ_DEFS"'head_runs' <<<"$OUT"))"
fi

echo "=== head_runs run scope ==="

# A custom commit status linking a run of its own is first-class scope: on a
# mixed head its run id appears BESIDE the workflow's, so a status failure's
# fail: line never cites a run head-run: omits.
MIXED='[
 {"name":"build","state":"SUCCESS","bucket":"pass","workflow":"CI","startedAt":"2026-07-26T10:00:00Z","link":"https://x/actions/runs/100/job/1"},
 {"name":"CI Required","state":"FAILURE","bucket":"fail","workflow":"","link":"https://x/actions/runs/200"}
]'
OUT="$(run_scope "$MIXED")"
if [[ "$(jq -r "$CI_RUN_JQ_DEFS"'head_runs | join(",")' <<<"$OUT")" == "100,200" ]]; then
  pass "a mixed head names the status-linked run beside the workflow run"
else
  fail "a mixed head names the status-linked run beside the workflow run (got $(jq -c "$CI_RUN_JQ_DEFS"'head_runs' <<<"$OUT"))"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
