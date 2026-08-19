#!/usr/bin/env bash
# Content gates for a reviewer's on-disk JSON artifact: the predicates that
# answer "is what this artifact SAYS usable?", as opposed to review-artifact-check's
# own job of locating an artifact, judging its freshness, and dispatching modes.
#
# THREE CHANNELS, NEVER SHARED. Every gate runs through gate_filter, which keeps
# them apart: the gate's ANSWER is stdout, jq's DIAGNOSTIC is a file the parent
# reads, and whether the gate ran at all is the exit status. They were shared
# before and each sharing became a way to read green — an empty answer meaning
# both "clean" and "could not run", then jq's stderr merged into stdout and read
# as a finding (and echoed as a fabricated instrument-failure declaration) by any
# diagnostic that leaves the exit status alone. A gate that cannot answer says so
# on its own channel; nothing it writes can be mistaken for what it found.
#
# artifact_content_gates is the single entry point; the individual gates below
# are its steps and are not called directly by review-artifact-check.
#
# Sourced by: review-artifact-check.

set -euo pipefail

# Last-resort emitter: no jq, no substitution, nothing that can fail. It lives
# here rather than in review-artifact-check because the error channel below is
# created at SOURCE time, before any of the script's own helpers are guaranteed
# to be reachable — a failure there used to exit empty with status 1, which is
# the status a legitimate rejection uses, so a caller reading .ok got an empty
# parse and a caller reading the status read "artifact rejected".
emit_unavailable() {
  local detail="${1:-review-artifact-check could not run, so no artifact could be validated}"
  detail="${detail//\\/}"
  detail="${detail//\"/}"
  printf '{"ok":false,"path":null,"reason":"invalid","detail":"%s"}\n' "$detail"
}

# jq's stderr lands here and is read only when the gate's exit status says the
# gate failed. Never printed as an answer.
review_artifact_gate_err="$(mktemp 2>/dev/null)" || {
  emit_unavailable "review-artifact-check could not create its temporary error channel (mktemp failed; check TMPDIR and free space), so no artifact could be validated"
  exit 1
}
review_artifact_gate_cleanup() { rm -f "$review_artifact_gate_err"; }
# INT/TERM as well as EXIT: this orchestrator arms backgrounded --wait
# watchdogs on every round and kills them at their deadline, and an untrapped
# signal leaks the file.
trap 'review_artifact_gate_cleanup' EXIT
trap 'review_artifact_gate_cleanup; exit 130' INT
trap 'review_artifact_gate_cleanup; exit 143' TERM

# The rejecting reason and its detail, set by artifact_content_gates. Every
# rejection carries a detail: a reason with no cause is a dead end for the agent
# that has to fix it, which review-pr.md § 3.1 spends its one re-delegation on.
review_artifact_reason=""
review_artifact_detail=""

# Whether glob mode may answer this rejection with an older sibling.
#
# THE RULE, stated once here instead of as a list of reason names elsewhere: a
# rejection that is the artifact's SELF-REPORT ABOUT THIS RUN is terminal — no
# earlier file answers "did this review happen, did it measure anything, are
# these findings routable", and the reviewer's own self-check is prescribed with
# boundary 0, which makes every prior artifact fresh by construction. Only a
# rejection that could be an artifact of a TORN OR TRUNCATED WRITE justifies
# looking at a sibling, because there the older file may be the same review
# written intact.
#
# Reason names cannot carry this: qa_shaped_incomplete (arrays lost wholesale —
# a truncated write) and finding_item_detail (items using wrong field names —
# this run's output shape) both reject as `incomplete` and fall on opposite
# sides of the rule. The disposition is therefore a property of the GATE, chosen
# at the rejection site through the two helpers below, and a gate added later
# has to state it rather than inheriting a list edit somebody forgot.
review_artifact_disposition=""

# reject_terminal <reason> <detail>   — a self-report about THIS run.
# reject_torn_write <reason> <detail> — could be this write being damaged.
# Both return 1 so a gate reads `reject_terminal ... ; return 1` at its site.
reject_terminal() {
  review_artifact_disposition="terminal"
  review_artifact_reason="$1"
  review_artifact_detail="$2"
}
reject_torn_write() {
  review_artifact_disposition="torn_write"
  review_artifact_reason="$1"
  review_artifact_detail="$2"
}

# The artifact's validated instrument-failure declaration; empty when it makes
# none.
review_artifact_measurement_failed=""

# What a declaration has to say for the gate to accept it. Named once so the
# rejection and the documentation cannot drift apart.
REVIEW_DECLARATION_BAR="a declaration must name the instrument and what it did — at least 20 characters and 3 words, not a null token (n/a, none, unknown, ...) or bare punctuation"

# Appended to a zero-sample FINDING when it is the reason for a rejection. Kept
# apart from the finding itself so the same finding can be reported as
# suppressed-by-declaration without carrying instructions for a rejection that
# did not happen.
REVIEW_ZERO_SAMPLE_REMEDY="a measurement that produced no samples, or whose measuring pipeline exited nonzero, is instrument failure, not a result. If the instrument was YOURS, keep the evidence and declare it: set the TOP-LEVEL measurement_failed to a string naming the instrument and what it did. If you are QUOTING someone else's zeroed run, put it in the blocker or suggestion it belongs to — only the summary and qa_metadata count as your own measurement."

# What a declaration silenced, when it silenced something. A blanket suppression
# that nobody can see is the shape this issue is about.
review_artifact_measurement_suppressed=""

# gate_filter <json_path> <jq_program>
# stdout: the gate's answer, and nothing else. Empty means the gate found
# nothing wrong. Exit 0 = the gate ran; any other status is jq's OWN, passed
# through rather than collapsed to a sentinel — a filter has no third answer to
# reserve a code for, and a sentinel meant every gate failure was reported as
# jq's 2 ("usage or system error") whatever really happened. Callers invoke this
# through a command substitution, whose subshell discards globals, so the status
# is the only signal that crosses back — which is why the diagnostic must not
# ride on stdout.
gate_filter() {
  local file="$1" program="$2" out rc=0
  out="$(jq -r "$program" "$file" 2>"$review_artifact_gate_err")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    return "$rc"
  fi
  printf '%s' "$out"
  return 0
}

# gate_failure_detail <jq_exit_code>
# The diagnostic for a gate that could not run, read from the error channel.
gate_failure_detail() {
  local rc="$1" err=""
  err="$(tr '\n\t' '  ' < "$review_artifact_gate_err" 2>/dev/null || printf '')"
  printf 'gate could not run: jq exited %s%s' "$rc" "${err:+: $err}"
}

# disposition_allows_fallback
# True only for an explicit torn_write. An unset or unrecognised disposition is
# terminal: a gate added later that forgets to classify itself must fail closed,
# never hand an older artifact back as this run's answer.
disposition_allows_fallback() {
  [[ "${review_artifact_disposition:-}" == "torn_write" ]]
}

# shellcheck source=review-artifact-measurement.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/review-artifact-measurement.sh"

# vstack#652: a schema-valid artifact can carry verdict "pass" while its
# qa_metadata admits no review happened (external second-opinion invoked with
# no scope). Such a self-reported no-review is rejected regardless of verdict.
# Artifacts without qa_metadata (internal reviewers) are unaffected.
self_reports_no_review() {
  gate_filter "$1" '
    # gate:no-review
    (.qa_metadata? // {}) as $qa
    | if (($qa | type) == "object") then
        if ($qa.review_performed == false)
          then "qa_metadata.review_performed is false — the artifact states no review happened, which no verdict overrides"
        elif ((($qa.reason // "") | tostring) | test("no[ _-]?(scope|review)|not[ _-]?reviewed"; "i"))
          then "qa_metadata.reason admits no review happened: \"\($qa.reason)\""
        else "" end
      else "" end
  '
}

# vstack#678: a truncated write can produce an artifact whose verdict/summary
# survived while the finding arrays were silently lost — schema-valid on the
# `.verdict` gate, but the actual blockers/suggestions are gone. Artifacts
# that DECLARE the qa/second-opinion shape (a qa_metadata object — the
# second-opinion producer always emits one, and QA reviewers are contractually
# required to per reviewer qa-review.md) must therefore also carry blockers[]
# and suggestions[]. Artifacts WITHOUT qa_metadata (internal reviewers,
# pre-existing tolerance documented in reviewer review-finding.md) validate as
# before. questions[] is not required here: it is PR-comment-triage-only and
# the QA standard fields omit it.
qa_shaped_incomplete() {
  gate_filter "$1" '
    # gate:qa-shape
    def shape($k): (.[$k]? | type) as $t
      | if $t == "array" then empty
        elif $t == "null" then "\($k)[] is absent"
        else "\($k)[] is \($t), not an array" end ;
    if ((.qa_metadata? | type) == "object") then
      ( [ shape("blockers"), shape("suggestions") ] ) as $bad
      | if ($bad | length) > 0
        then "\($bad | join("; ")) — declaring qa_metadata commits the artifact to both finding"
             + " arrays, empty ones included: a review with nothing to say writes []. An artifact"
             + " with no qa_metadata does not have to carry them."
        else "" end
    else "" end
  '
}

# vstack#810: qa_shaped_incomplete only catches arrays that were lost wholesale.
# An artifact can instead carry present, non-empty blockers[]/suggestions[]
# whose ITEMS omit the required review-finding fields — e.g. {title, location,
# detail, severity} instead of the schema's {id, title, location, description,
# recommendation, priority, estimate[, category]}. Such an item is present in
# prose but unroutable: the orchestrator routes suggestions on `category`
# (fix -> dev, issue -> audit), so a category-less item matches neither filter
# and every finding is silently dropped. The required set is derived from
# reviewer/schemas/review-finding.md § "Item Fields (blockers/suggestions)"
# (all seven marked Required=Yes for both arrays; `category` additionally
# Required for suggestions, and constrained to {fix,issue} because routing keys
# on it; `priority` must be a number in 1..4 and `estimate` a number in 1..5
# per the schema's field table, so a present-but-out-of-range value is caught
# too). Gated on the qa_metadata declaration for parity with
# qa_shaped_incomplete: artifacts without qa_metadata keep the pre-existing
# tolerance documented in reviewer review-finding.md. Empty arrays carry no
# items and stay valid. Prints the first offending item's diagnostic on stdout
# (array[index] + the missing/invalid fields), empty string when every item is
# well-formed or the artifact is not qa-shaped.
finding_item_detail() {
  gate_filter "$1" '
    # gate:finding-items
    if ((.qa_metadata? | type) == "object") then
      ( ["id","title","location","description","recommendation","priority","estimate"]
        as $base
      | ( [ (.blockers?    | if type == "array" then . else [] end
              | to_entries[] | {arr: "blockers",    i: .key, item: .value}),
            (.suggestions? | if type == "array" then . else [] end
              | to_entries[] | {arr: "suggestions", i: .key, item: .value}) ]
          | map(
              .arr as $arr | .i as $i | .item as $item
              # category:issue items additionally require a non-empty `impact` —
              # the one-line who-hits-this statement the filing bar adjudicates.
              # An issue candidate without it is unroutable at the audit gate.
              | ($base
                 + (if $arr == "suggestions" then ["category"] else [] end)
                 + (if $arr == "suggestions" and (($item | type) == "object")
                       and ($item.category == "issue")
                    then ["impact"] else [] end))
                as $req
              | [ $req[] | select((($item | type) != "object") or ($item[.] == null)) ]
                as $missing
              | ( if ($arr == "suggestions")
                     and (($item | type) == "object")
                     and ($item.category != null)
                     and ((["fix","issue"] | index($item.category | tostring)) == null)
                  then ["category(not fix|issue)"] else [] end )
                as $badcat
              # A present-but-blank impact is as unroutable as a missing one:
              # the filing bar adjudicates its text.
              | ( if ($arr == "suggestions")
                     and (($item | type) == "object")
                     and ($item.category == "issue")
                     and ($item.impact != null)
                     and ((($item.impact | type) != "string") or (($item.impact | tostring | gsub("\\s";"")) == ""))
                  then ["impact(blank)"] else [] end )
                as $blankimpact
              # priority in 1..4, estimate in 1..5 per review-finding.md — a present
              # but non-numeric or out-of-range value is unusable, not just the
              # null case $missing already covers (vstack#810). Only checked when
              # the field is present (a null value already falls under $missing)
              # and the item is an object (a non-object is fully flagged there too).
              | ( if (($item | type) == "object")
                  then ( [ {f:"priority", v:$item.priority, lo:1, hi:4},
                           {f:"estimate", v:$item.estimate, lo:1, hi:5} ]
                         | map(select(.v != null
                             and (((.v | type) != "number") or (.v < .lo) or (.v > .hi))))
                         | map("\(.f)(not \(.lo)..\(.hi))") )
                  else [] end )
                as $badnum
              | ($missing + $badcat + $blankimpact + $badnum) as $problems
              # Name the expected set, not just what is wrong. The rejection is
              # relayed verbatim to the agent that has to redo the artifact, and
              # a bare "missing id, description, estimate, category" does not
              # tell it that `detail` should have been `description` or that
              # priority stops at 4 — so the same agent reaches for `priority: 5`
              # or a plausible-but-wrong field name again (vstack#885).
              | if ($problems | length) > 0
                then "\($arr)[\($i)]: missing/invalid \($problems | join(", "))"
                     + " — every blockers[]/suggestions[] item requires:"
                     + " id, title, location (path plus symbol, no line numbers),"
                     + " description, recommendation, priority (integer 1-4),"
                     + " estimate (1-5); suggestions also category (fix|issue),"
                     + " and category:issue also impact (who hits this, on what real path)"
                else empty end
            )
          | (first(.[]) // "") ) )
    else "" end
  '
}

# artifact_content_gates <json_path>
# Runs every content gate and reports the first rejection through
# review_artifact_reason / review_artifact_detail / review_artifact_disposition;
# reason is "valid" or "valid_undermeasured" when the artifact passes.
# review_artifact_measurement_failed carries a validated declaration.
# Returns 0 when the artifact passes every gate, 1 when one rejected it.
#
# GATE ORDER IS NOT LOAD-BEARING. The declaration is adjudicated in one place
# but suppresses exactly ONE gate, and it does so through a flag consumed at
# that gate rather than by returning early. Short-circuiting made the escape's
# blast radius a function of where its block happened to sit: hoisting it turned
# `review_performed: false` into an accepted verdict, and the bypass arrived as
# a legitimate-looking `valid_undermeasured` rather than as an anomaly. A flag
# cannot reach past the gate that reads it, wherever the block moves.
artifact_content_gates() {
  local file="$1" rc out declared=""
  review_artifact_reason=""
  review_artifact_detail=""
  review_artifact_disposition=""
  review_artifact_measurement_failed=""
  review_artifact_measurement_suppressed=""

  # A gate that could not run at all is the torn-read shape the lib header
  # names, so it is the one failure that may still be answered by a sibling.
  rc=0; out="$(self_reports_no_review "$file")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    reject_torn_write "invalid" "$(gate_failure_detail "$rc")"
    return 1
  fi
  if [[ -n "$out" ]]; then
    reject_terminal "no_review" "$out"
    return 1
  fi

  # Also terminal, though it was filed as the truncated-write shape until the
  # argument was checked: a truncated JSON object is not a JSON object, so every
  # torn or partial write fails the `.verdict` parse before any content gate
  # runs. What reaches this gate is always well-formed JSON the writer produced
  # — arrays absent, or present with the wrong type — which is this run's output
  # shape and is not answered by an older artifact.
  rc=0; out="$(qa_shaped_incomplete "$file")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    reject_torn_write "invalid" "$(gate_failure_detail "$rc")"
    return 1
  fi
  if [[ -n "$out" ]]; then
    reject_terminal "incomplete" "$out"
    return 1
  fi

  # Same reason word, opposite disposition: a truncated write does not rename
  # fields. Items carrying `detail`/`severity` instead of the schema's names are
  # what this run produced, and no earlier artifact answers for them.
  rc=0; out="$(finding_item_detail "$file")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    reject_torn_write "invalid" "$(gate_failure_detail "$rc")"
    return 1
  fi
  if [[ -n "$out" ]]; then
    reject_terminal "incomplete" "$out"
    return 1
  fi

  rc=0; out="$(measurement_declaration "$file")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    reject_torn_write "invalid" "$(gate_failure_detail "$rc")"
    return 1
  fi
  case "$out" in
    invalid:*)
      reject_terminal "invalid_declaration" "${out#invalid:} — $REVIEW_DECLARATION_BAR"
      return 1
      ;;
    declared:*)
      declared="${out#declared:}"
      ;;
  esac

  # The declaration's entire blast radius: this gate. It runs either way — a
  # declaration converts its finding from a rejection into a recorded
  # suppression rather than deleting it, because one declaration covers whatever
  # this gate would have said, including a perf payload the named instrument has
  # nothing to do with. Silencing a measurement is allowed; silencing it
  # invisibly is the shape this whole issue is about.
  rc=0; out="$(zero_sample_detail "$file")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    reject_torn_write "invalid" "$(gate_failure_detail "$rc")"
    return 1
  fi
  if [[ -n "$out" ]]; then
    if [[ -z "$declared" ]]; then
      reject_terminal "zero_sample" "$out — $REVIEW_ZERO_SAMPLE_REMEDY"
      return 1
    fi
    review_artifact_measurement_suppressed="$out"
  fi

  if [[ -n "$declared" ]]; then
    review_artifact_measurement_failed="$declared"
    review_artifact_reason="valid_undermeasured"
  else
    review_artifact_reason="valid"
  fi
  return 0
}
