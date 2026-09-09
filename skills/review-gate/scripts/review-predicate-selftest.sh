#!/usr/bin/env bash
# Selftest for review-predicate.sh — pins the gate's decision table without
# touching the network. This is the engine's portable proof: every consumer's
# CI runs it in a deliberately UNGATED job (a broken predicate approves
# nothing, so a selftest behind the gate could never run when it matters).
#
# Why this exists: the predicate is the single thing standing between
# "reviewed" and "merged", it is only ever exercised in production, and every
# widening of its evidence sources is a place the gate could be made to say
# "approved" when nothing reviewed anything. The dangerous direction is not a
# false `awaiting` — that is visible and annoying — it is a false `approved`,
# which is silent. So every case below that ends in `approved` is paired with
# a near-miss that must NOT.
#
# TWO LAYERS:
#   1. Mechanism layer — env-forced configurations pin every engine behavior
#      with known values: the evidence sources, the trust model near-misses,
#      the skip-pattern (pass-without-analysis) filter, review-object trust,
#      approval non-supersession, fail-loud reads, and config validation.
#   2. Configured layer — the same approve/near-miss discipline re-derived
#      from THIS repo's resolved REVIEW_GATE_* settings (env > .env.local >
#      the settings files > defaults), so a repo trusting a different bot
#      tests its OWN trust list, not someone else's defaults.
#
# Mechanism: a `gh` shim prior on PATH answers from fixtures and applies any
# `--jq` filter with real jq, so the predicate runs unmodified. Run:
#
#   .agents/skills/review-gate/scripts/review-predicate-selftest.sh
#
# Exit 0 = all cases pass. Any failure prints the case, the expectation and
# what the predicate actually said.
set -u
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
predicate="$here/review-predicate.sh"
. "$here/lib/diagnostics.sh" || exit 1
[ -x "$predicate" ] || { rg_message error selftest-predicate-executable "$predicate" "Predicate is not executable." >&2; exit 1; }
. "$here/lib/settings.sh"

# ------------------------------------------------------------ active config ---
# Resolved exactly as the predicate resolves it, from the invoking repo's
# environment/settings. The configured layer generates its cases from these.
# `|| exit 1`: rg_setting fails loud on an unparseable assignment; the
# selftest must not generate cases from a silently-emptied config.
ACTIVE_CONTEXTS="$(rg_setting REVIEW_GATE_TRUSTED_STATUS_CONTEXTS "")" || exit 1
ACTIVE_SKIPS="$(rg_setting REVIEW_GATE_CHECKRUN_SKIP_PATTERNS "rate limited;skipped;queued")" || exit 1
ACTIVE_REVIEWERS="$(rg_setting REVIEW_GATE_COMMENT_REVIEWERS "")" || exit 1
ACTIVE_FLOOR="$(rg_setting REVIEW_GATE_SHA_PREFIX_FLOOR "7")" || exit 1
# Mirrors the predicate's own resolution, so a repo's OWN override context is
# what the configured layer tests rather than the shipped default.
ACTIVE_OUTAGE="$(rg_setting REVIEW_GATE_OVERRIDE_CONTEXT "kendex-reviewer-outage")" || exit 1
ACTIVE_PUBLISHER_REJECT="$(rg_setting REVIEW_GATE_STATUS_PUBLISHER_REJECT "")" || exit 1
ACTIVE_TRUSTED_LOGINS="$(rg_setting REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS "")" || exit 1
ACTIVE_MIN_STATE="$(rg_setting REVIEW_GATE_REVIEW_OBJECT_MIN_STATE "any")" || exit 1
ACTIVE_ERROR_PATTERNS="$(rg_setting REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS "encountered an error and was unable to review")" || exit 1
ACTIVE_GATE_CONTEXT="$(rg_setting REVIEW_GATE_CONTEXT "Review gate")" || exit 1
ACTIVE_THREADS="$(rg_setting REVIEW_GATE_THREADS "enforce")" || exit 1
ACTIVE_API_ATTEMPTS="$(rg_setting REVIEW_GATE_API_ATTEMPTS "1")" || exit 1
# The repo's ACTIVE delay is never copied into behavior cases (reset() pins
# 0 — the delay paces production retries and decides no verdict); one case
# below drives THIS value through the predicate instead.
ACTIVE_API_DELAY="$(rg_setting REVIEW_GATE_API_RETRY_DELAY_SECONDS "2")" || exit 1
ACTIVE_CARRY="$(rg_setting REVIEW_GATE_CARRY_FORWARD "")" || exit 1
ACTIVE_CARRY_EXCLUDE="$(rg_setting REVIEW_GATE_CARRY_FORWARD_EXCLUDE "")" || exit 1
ACTIVE_CARRY_EXCLUDE_PROPHYLACTIC="$(rg_setting REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC "")" || exit 1
ACTIVE_VENDORED_PATHS="$(rg_setting REVIEW_GATE_VENDORED_PATHS "")" || exit 1
# The repo's ACTIVE render set is never copied into behavior cases (reset()
# pins it empty — under a committed set every no-evidence case would read a
# comparison the case never modelled); the configured layer drives THIS
# value through one approve and its near-miss.
ACTIVE_RENDER_PATHS="$(rg_setting REVIEW_GATE_RENDER_PATHS "")" || exit 1
# The repo's ACTIVE mode is validated here but NEVER copied into behavior
# cases (reset() pins enforce — under a committed "off" every awaiting/
# objection case would answer approved and red the required selftest job).
# This standalone check is what catches a committed typo pre-merge: the
# predicate would exit 2 on every live evaluation, but only at runtime.
ACTIVE_GATE_MODE_CHECK="$(rg_setting REVIEW_GATE_MODE "enforce")" || exit 1
case "$ACTIVE_GATE_MODE_CHECK" in
  enforce|off) ;;
  *)
    rg_message error selftest-mode "$ACTIVE_GATE_MODE_CHECK" "review-predicate selftest: FAIL — committed REVIEW_GATE_MODE is '$ACTIVE_GATE_MODE_CHECK' (must be 'enforce' or 'off'); the live predicate will exit 2 on every evaluation" >&2
    exit 1
    ;;
esac

work="$(mktemp -d)" || exit 1
trap 'rm -rf -- "${work:?}"' EXIT

HEAD='a1b2c3d4e5f60718293a4b5c6d7e8f9012345678'
OTHER='ffffffffffffffffffffffffffffffffffffffff'
BASE='0000000000000000000000000000000000000001'
AUTHOR='author-under-test'

fixtures="$work/fixtures"
shim="$work/bin"
mkdir -p "$fixtures" "$shim"

# The shim: dispatch on the request, honour --jq, and obey a failure switch so
# the fail-loud path is testable too. Extras the retry/pagination cases need:
#   GH_SHIM_FAIL_TIMES=N   with GH_SHIM_FAIL: fail only the first N calls for
#                          that endpoint (counter file), then serve — drives
#                          the bounded in-predicate retries
#   GH_SHIM_EMPTY=name     exit 0 with ZERO output bytes for that endpoint —
#                          the broken-producer shape the zero-byte guard
#                          refuses
#   <name>.page2.json      with --paginate: served CONCATENATED after the
#                          first page, exactly gh's multi-page output shape,
#                          so the `jq -s` page merges are actually driven
# Every request URL is appended to .urls.log so cases can pin read shapes
# (per_page, endpoints skipped).
cp "$here/../tests/lib/gh-shim.sh" "$shim/gh"
chmod +x "$shim/gh"

# ------------------------------------------------------------------ helpers ---
# The fixture writers, shared with the suites under tests/. They
# write into $fixtures and bind to $HEAD, both set above.
. "$here/../tests/lib/selftest-fixtures.sh"

cases=0
failures=0
run() { # case-name, expected-verdict, expected-exit
  local name="$1" want="$2" want_exit="${3:-0}" line rc verdict
  cases=$((cases + 1))
  line="$(PATH="$shim:$PATH" GH_SHIM_FIXTURES="$fixtures" \
    REVIEW_GATE_SETTINGS_FILE=/dev/null \
    REVIEW_GATE_TRUSTED_STATUS_CONTEXTS="$CFG_CONTEXTS" \
    REVIEW_GATE_CHECKRUN_SKIP_PATTERNS="$CFG_SKIPS" \
    REVIEW_GATE_COMMENT_REVIEWERS="$CFG_REVIEWERS" \
    REVIEW_GATE_SHA_PREFIX_FLOOR="$CFG_FLOOR" \
    REVIEW_GATE_OVERRIDE_CONTEXT="$CFG_OUTAGE" \
    REVIEW_GATE_STATUS_PUBLISHER_REJECT="$CFG_PUBLISHER_REJECT" \
    REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS="$CFG_TRUSTED_LOGINS" \
    REVIEW_GATE_REVIEW_OBJECT_MIN_STATE="$CFG_MIN_STATE" \
    REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS="$CFG_ERROR_PATTERNS" \
    REVIEW_GATE_CONTEXT="$CFG_GATE_CONTEXT" \
    REVIEW_GATE_THREADS="$CFG_THREADS" \
    REVIEW_GATE_API_ATTEMPTS="$CFG_API_ATTEMPTS" \
    REVIEW_GATE_API_RETRY_DELAY_SECONDS="$CFG_API_DELAY" \
    REVIEW_GATE_STATUS_SNAPSHOT_FILE="$CFG_SNAPSHOT" \
    REVIEW_GATE_CARRY_FORWARD="$CFG_CARRY" \
    REVIEW_GATE_CARRY_FORWARD_EXCLUDE="$CFG_CARRY_EXCLUDE" \
    REVIEW_GATE_VENDORED_PATHS="$CFG_VENDORED_PATHS" \
    REVIEW_GATE_RENDER_PATHS="$CFG_RENDER_PATHS" \
    REVIEW_GATE_MODE="$CFG_GATE_MODE" \
    GH_REPO="owner/repo" PR_NUMBER=1 HEAD_SHA="$HEAD" PR_AUTHOR="$CFG_PR_AUTHOR" \
    "$predicate" 2>"$work/stderr")"
  rc=$?
  LAST_ERROR="$(cat "$work/stderr")"
  LAST_LINE="$line"; verdict="${line#verdict=}"; verdict="${verdict%% *}"
  if [ "$rc" != "$want_exit" ]; then
    rg_message error selftest-case-exit "$name" "FAIL  $name: exit $rc, wanted $want_exit" >&2
    failures=$((failures + 1))
    return
  fi
  if [ "$want_exit" != "0" ] && [ -n "$line" ]; then
    rg_message error selftest-refusal-output "$name" "FAIL  $name: refusal emitted stdout: $line" >&2
    failures=$((failures + 1))
    return
  fi
  if [ "$want_exit" = "0" ] && [ "$verdict" != "$want" ]; then
    rg_message error selftest-case-verdict "$name" "FAIL  $name: verdict=$verdict, wanted $want" >&2
    failures=$((failures + 1))
    return
  fi
  echo "ok    $name ($want)"
}
reset() {
  printf '[]\n' >"$fixtures/reviews.json"
  printf '[]\n' >"$fixtures/comments.json"
  printf '{"check_runs":[]}\n' >"$fixtures/checkruns.json"
  printf '[]\n' >"$fixtures/statuses.json"
  threads >"$fixtures/graphql.json"
  jq -n --arg a "$AUTHOR" --arg base "$BASE" '{user:{login:$a},base:{sha:$base}}' >"$fixtures/pull.json"
  rm -f "$fixtures"/*.page2.json "$fixtures"/graphql.cursor-*.json "$fixtures"/.failcount.* "$fixtures"/.urls.log
  unset GH_SHIM_FAIL GH_SHIM_FAIL_TIMES GH_SHIM_EMPTY || true
  CFG_THREADS="$ACTIVE_THREADS"
  CFG_API_ATTEMPTS="$ACTIVE_API_ATTEMPTS"
  # PINNED to 0, never the repo's ACTIVE value: the delay paces production
  # retries and decides no verdict, while under a committed attempts>1 every
  # fail-loud case would sleep it out per retry. The retry cases below set
  # their own attempts/delay explicitly.
  CFG_API_DELAY="0"
  CFG_CARRY="$ACTIVE_CARRY"
  CFG_CARRY_EXCLUDE="$ACTIVE_CARRY_EXCLUDE"
  CFG_VENDORED_PATHS="$ACTIVE_VENDORED_PATHS"
  CFG_RENDER_PATHS=""
  # PINNED to enforce, never the repo's ACTIVE value: mode "off" is a bypass
  # switch, not a trust surface — under it every behavior case would answer
  # approved and the suite would fail, turning a deliberately disabled gate
  # into a red required CI job. The off/invalid arms are exercised by their
  # own explicit cases below.
  CFG_GATE_MODE="enforce"
  CFG_SNAPSHOT=""
  rm -f "$fixtures/compare.json"
  CFG_PR_AUTHOR="$AUTHOR"
  CFG_CONTEXTS="$ACTIVE_CONTEXTS"
  CFG_SKIPS="$ACTIVE_SKIPS"
  CFG_REVIEWERS="$ACTIVE_REVIEWERS"
  CFG_FLOOR="$ACTIVE_FLOOR"
  CFG_OUTAGE="$ACTIVE_OUTAGE"
  CFG_PUBLISHER_REJECT="$ACTIVE_PUBLISHER_REJECT"
  CFG_TRUSTED_LOGINS="$ACTIVE_TRUSTED_LOGINS"
  CFG_MIN_STATE="$ACTIVE_MIN_STATE"
  CFG_ERROR_PATTERNS="$ACTIVE_ERROR_PATTERNS"
  CFG_GATE_CONTEXT="$ACTIVE_GATE_CONTEXT"
}

# A review login that the ACTIVE config accepts as review-object evidence.
trusted_reviewer() {
  if [ -n "$ACTIVE_TRUSTED_LOGINS" ]; then first_item "$ACTIVE_TRUSTED_LOGINS"; else echo "reviewer"; fi
}

# The full comment-form battery for one 'login:pattern' pair. Every approving
# case is paired with the near-misses that decide whether the carve-out is a
# trust model or a grep.
comment_battery() { # login, pattern, floor
  local login="$1" pattern="$2" floor="$3" prefix short rows name author body want effect
  prefix="$(printf '%.*s' "$floor" "$HEAD")"
  short="$(printf '%.*s' "$((floor - 1))" "$HEAD")"
  local thread_verdict=threads-open
  [ "$ACTIVE_THREADS" != off ] || thread_verdict=approved
  # JSON rows preserve literal separators and newline text in configured bindings.
  comment_row() { # NAME AUTHOR BODY VERDICT EFFECT
    jq -cn --arg name "$1" --arg author "$2" --arg body "$3" --arg want "$4" --arg effect "$5" \
      '{name:$name,author:$author,body:$body,want:$want,effect:$effect}'
  }
  rows="$(
    set -e
    comment_row 'floor sha' "$login" "$pattern \`$prefix\`" approved ''
    comment_row 'full sha' "$login" "$pattern $HEAD" approved ''
    comment_row 'markdown binding' "$login" "**Clean pass.** **$pattern** \`$prefix\`" approved ''
    comment_row 'wrong author' mallory "$pattern \`$prefix\`" awaiting ''
    comment_row 'PR author' "$AUTHOR" "$pattern \`$prefix\`" awaiting ''
    comment_row 'different sha' "$login" "$pattern \`$(printf '%.*s' "$floor" "$OTHER")\`" awaiting ''
    comment_row 'no binding' "$login" 'Clean pass, no binding line here.' awaiting ''
    comment_row 'sub-floor sha' "$login" "$pattern \`$short\`" awaiting ''
    comment_row 'unresolved thread' "$login" "$pattern \`$prefix\`" "$thread_verdict" thread
    comment_row 'standing objection' "$login" "$pattern \`$prefix\`" changes-requested objection
    comment_row 'read failure' "$login" '' '' read
  )" || exit 1
  local row
  while IFS= read -r row; do
    name="$(jq -r .name <<<"$row")" || exit 1
    author="$(jq -r .author <<<"$row")" || exit 1
    body="$(jq -r .body <<<"$row")" || exit 1
    want="$(jq -r .want <<<"$row")" || exit 1
    effect="$(jq -r .effect <<<"$row")" || exit 1
    reset
    CFG_REVIEWERS="$login:$pattern"; CFG_FLOOR="$floor"
    comment "$author" "$body" >"$fixtures/comments.json"
    case "$effect" in
      thread) threads false >"$fixtures/graphql.json" ;;
      objection) reviews_set "$(review reviewer CHANGES_REQUESTED)" ;;
      read) export GH_SHIM_FAIL=comments ;;
      '') : ;;
      *) exit 1 ;;
    esac
    local expected_exit=0
    [ "$effect" != read ] || expected_exit=2
    run "[$login] comment: $name" "$want" "$expected_exit"
  done <<<"$rows"
}

# Approve/near-miss battery for one trusted check/status context, including
# the pass-without-analysis (skip-pattern) filter.
context_battery() { # trusted context
  local ctx="$1" rows row name kind context state body publisher older want pat
  context_row() { # NAME KIND CONTEXT STATE BODY PUBLISHER OLDER_STATE VERDICT
    jq -cn --arg name "$1" --arg kind "$2" --arg context "$3" --arg state "$4" \
      --arg body "$5" --arg publisher "$6" --arg older "$7" --arg want "$8" \
      '{name:$name,kind:$kind,context:$context,state:$state,body:$body,publisher:$publisher,older:$older,want:$want}'
  }
  rows="$(
    set -e
    context_row 'clean status' status "$ctx" success 'analysis complete' trusted-publisher '' approved
    context_row 'different status context' status "$ctx (untrusted twin)" success 'analysis complete' trusted-publisher '' awaiting
    if [ -n "$ACTIVE_PUBLISHER_REJECT" ]; then
      context_row 'rejected status publisher' status "$ctx" success 'analysis complete' "$(first_item "$ACTIVE_PUBLISHER_REJECT")" '' awaiting
    fi
    context_row 'pending status' status "$ctx" pending 'still running' trusted-publisher '' awaiting
    context_row 'newer failure masks success' status "$ctx" failure 'issues found' trusted-publisher success awaiting
    context_row 'newer success masks failure' status "$ctx" success 'analysis complete' trusted-publisher failure approved
    context_row 'clean check run' check "$ctx" success '0 findings' trusted-reviewer-app '' approved
    context_row 'different check name' check "$ctx (untrusted twin)" success '0 findings' trusted-reviewer-app '' awaiting
    context_row 'neutral check run' check "$ctx" neutral 'analysis skipped' trusted-reviewer-app '' awaiting
    while IFS= read -r pat; do
      [ -n "$pat" ] || continue
      context_row "skipped check: $pat" check "$ctx" success "Review $pat" trusted-reviewer-app '' awaiting
      context_row "skipped status: $pat" status "$ctx" success "Review $pat" trusted-publisher '' awaiting
    done <<EOF
$(list_items "$ACTIVE_SKIPS")
EOF
  )" || exit 1
  while IFS= read -r row; do
    reset
    name="$(jq -r .name <<<"$row")" || exit 1
    kind="$(jq -r .kind <<<"$row")" || exit 1
    context="$(jq -r .context <<<"$row")" || exit 1
    state="$(jq -r .state <<<"$row")" || exit 1
    body="$(jq -r .body <<<"$row")" || exit 1
    publisher="$(jq -r .publisher <<<"$row")" || exit 1
    older="$(jq -r .older <<<"$row")" || exit 1
    want="$(jq -r .want <<<"$row")" || exit 1
    case "$kind" in
      check) checkrun "$context" "$state" "$body" "$publisher" ;;
      status)
        status_ctx "$context" "$state" "$body" "$publisher"
        if [ -n "$older" ]; then
          jq --arg older "$older" '. + [.[0] | .state=$older] | .[0].created_at="2026-01-02T00:00:00Z"' \
            "$fixtures/statuses.json" >"$work/statuses.json" || exit 1
          mv "$work/statuses.json" "$fixtures/statuses.json" || exit 1
        fi ;;
      *) exit 1 ;;
    esac
    run "[$ctx] $name" "$want"
  done <<<"$rows"
}

# ================================================================ mechanism ===
# Env-forced configurations: these pin every engine behavior regardless of the
# invoking repo's own trust settings.
echo "--- mechanism layer (forced configuration)"

for selftest_table in \
  predicate-fixture-integrity.sh predicate-reads.sh predicate-checkruns.sh \
  predicate-statuses.sh predicate-threads.sh predicate-review-objects.sh \
  predicate-checkrun-skips.sh predicate-comments.sh predicate-override.sh \
  predicate-configuration.sh predicate-thread-mode.sh predicate-retries.sh \
  predicate-pagination.sh predicate-author.sh predicate-read-shapes.sh \
  predicate-snapshot.sh predicate-request-shape.sh predicate-mode.sh \
  predicate-carry.sh predicate-configured.sh; do
  selftest_table_path="$here/../tests/lib/predicate-selftest/$selftest_table"
  if [ ! -r "$selftest_table_path" ]; then
    rg_message error selftest-table-load "$selftest_table_path" "Could not load predicate selftest table $selftest_table." >&2
    exit 1
  fi
  . "$selftest_table_path" || {
    rg_message error selftest-table-load "$selftest_table_path" "Could not load predicate selftest table $selftest_table." >&2
    exit 1
  }
done

if [ "$failures" -ne 0 ]; then
  rg_message error selftest-failed "$failures" "review-predicate selftest: $failures of $cases case(s) FAILED" >&2
  exit 1
fi
rg_message notice selftest-complete "$cases" "review-predicate selftest: $cases case(s), all pass"
