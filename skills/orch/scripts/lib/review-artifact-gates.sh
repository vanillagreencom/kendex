#!/usr/bin/env bash
# Content gates for a reviewer's on-disk JSON artifact: the predicates that
# answer "is what this artifact SAYS usable?", as opposed to review-artifact-check's
# own job of locating an artifact, judging its freshness, and dispatching modes.
#
# Every gate runs through gate_predicate/gate_filter, which separate the gate's
# ANSWER from the gate's ability to answer at all. A jq failure — a torn read of
# a non-atomically written artifact, a jq that is broken or missing — is never
# reported as "no problem found": it surfaces as reason `invalid` carrying jq's
# own diagnostic. Silence and cleanliness must never share an encoding here,
# because this file is the thing that decides whether a review counts.
#
# artifact_content_gates is the single entry point; the individual gates below
# are its steps and are not called directly by review-artifact-check.
#
# Sourced by: review-artifact-check.

set -euo pipefail

# jq's own diagnostic when a gate could not run; empty otherwise.
review_artifact_gate_error=""

# The rejecting reason and its detail, set by artifact_content_gates.
review_artifact_reason=""
review_artifact_detail=""

# The artifact's declared instrument-failure marker, set by
# artifact_content_gates; empty when it declares none.
review_artifact_measurement_failed=""

# gate_predicate <json_path> <jq_program>
# 0 = predicate true, 1 = predicate false, 2 = the gate could not run.
# jq exits 1 for a false/null result and >=2 for a usage, compile, or runtime
# error, so the two are distinguishable and must be kept that way.
gate_predicate() {
  local file="$1" program="$2" out rc=0
  review_artifact_gate_error=""
  out="$(jq -e "$program" "$file" 2>&1)" || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *)
      review_artifact_gate_error="gate could not run: jq exited $rc: $(printf '%s' "$out" | tr '\n\t' '  ')"
      return 2
      ;;
  esac
}

# gate_filter <json_path> <jq_program>
# Prints the filter's diagnostic on stdout, empty when the gate found nothing.
# 0 = the gate ran, 2 = the gate could not run — in which case jq's own
# diagnostic is what gets printed. Filters are read through a command
# substitution, whose subshell discards any global the callee sets, so the
# failure message has to travel out the same channel as the answer.
gate_filter() {
  local file="$1" program="$2" out rc=0
  review_artifact_gate_error=""
  out="$(jq -r "$program" "$file" 2>&1)" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    review_artifact_gate_error="gate could not run: jq exited $rc: $(printf '%s' "$out" | tr '\n\t' '  ')"
    printf '%s' "$review_artifact_gate_error"
    return 2
  fi
  printf '%s' "$out"
  return 0
}

# vstack#652: a schema-valid artifact can carry verdict "pass" while its
# qa_metadata admits no review happened (external second-opinion invoked with
# no scope). Such a self-reported no-review is rejected regardless of verdict.
# Artifacts without qa_metadata (internal reviewers) are unaffected.
self_reports_no_review() {
  gate_predicate "$1" '
    # gate:no-review
    (.qa_metadata? // {}) as $qa
    | (($qa | type) == "object")
      and (($qa.review_performed == false)
           or ((($qa.reason // "") | tostring)
               | test("no[ _-]?(scope|review)|not[ _-]?reviewed"; "i")))
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
  gate_predicate "$1" '
    # gate:qa-shape
    ((.qa_metadata? | type) == "object")
      and (((.blockers? | type) != "array")
           or ((.suggestions? | type) != "array"))
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

# The artifact's declared instrument-failure marker: a non-empty
# qa_metadata.measurement_failed string naming the instrument and what it did.
# Prints it, or the empty string when the artifact declares none.
measurement_failed_marker() {
  gate_filter "$1" '
    # gate:measurement-marker
    ((.qa_metadata? // {}) | if type == "object" then (.measurement_failed? // null) else null end)
    | if (type == "string") and ((gsub("\\s"; "")) != "") then . else "" end
  '
}

# vstack#1497: a measurement instrument that produced no samples still emits a
# number, and a zero reads as green. Two shapes are refused.
#
# The SAMPLE COUNT — the denominator of the reviewer skill's fixed citation
# format (`mutation: killed X/X; stability: Y/N at T threads`) and its thread
# count. Only the count: `stability: 0/10` is ten runs of which none passed, a
# fully measured concurrency failure that SKILL.md calls "never a pass" and
# this gate must therefore let through as a finding. Reading the numerator
# would suppress exactly that.
#
# The PERF PAYLOAD — checked by requiring evidence rather than by detecting its
# absence, because absence has too many spellings (missing key, [], null
# leaves, "0ms" strings) and every one of them is what a harness that produced
# nothing most naturally emits. A perf_qa payload must carry a percentiles
# block with at least one numeric leaf above zero.
#
# Scanned over every string leaf, so a citation counts wherever the reviewer put
# it, and — unlike the qa-shape gates above — gated on nothing, because the
# pairing binds every reviewer. The escape is a declaration, not an omission:
# qa_metadata.measurement_failed suppresses this gate, so a reviewer whose
# instrument died keeps its numbers as evidence and the failure becomes visible
# to the orchestrator instead of being deleted to get past a rejection.
zero_sample_detail() {
  gate_filter "$1" '
    # gate:zero-sample
    def declared_failure:
      ((.qa_metadata? // {}) | if type == "object" then (.measurement_failed? // null) else null end)
      | (type == "string") and ((gsub("\\s"; "")) != "") ;

    def cites:
      [ .. | strings ]
      | map(
          ( [ scan("(?i)killed\\s*([0-9]+)\\s*/\\s*([0-9]+)") ]
            | map({kind: "mutation",
                   label: ("killed " + .[0] + "/" + .[1]),
                   den: (.[1] | tonumber),
                   threads: null}) )
          + ( [ scan("(?i)stability:\\s*([0-9]+)\\s*/\\s*([0-9]+)(?:\\s*at\\s*([0-9]+)\\s*threads?)?") ]
            | map({kind: "stability",
                   label: ("stability: " + .[0] + "/" + .[1]),
                   den: (.[1] | tonumber),
                   threads: (if .[2] == null then null else (.[2] | tonumber) end)}) )
        )
      | (add // []) ;

    def perf_zero:
      ((.qa_metadata? // {}) | if type == "object" then (.perf_qa? // null) else null end) as $pq
      | if ($pq == null) then []
        elif (($pq | type) != "object")
          then ["qa_metadata.perf_qa is not an object, so it carries no benchmark evidence"]
        else ($pq.percentiles?) as $p
          | if ($p == null)
              then ["qa_metadata.perf_qa declares no percentiles block (a required field)"]
            elif ((($p | type) != "object") and (($p | type) != "array"))
              then ["qa_metadata.perf_qa.percentiles is neither an object nor an array"]
            elif (($p | length) == 0)
              then ["qa_metadata.perf_qa.percentiles is empty"]
            elif (([$p | .. | numbers | select(. > 0)] | length) == 0)
              then ["qa_metadata.perf_qa.percentiles carries no measured value above zero"]
            else [] end
        end ;

    if declared_failure then "" else
      ( [ cites[] | select(.den == 0)
          | "\(.kind) citation \"\(.label)\" reports zero samples" ]
        + [ cites[] | select(.threads != null and .threads == 0)
          | "stability citation \"\(.label)\" reports zero threads" ]
        + perf_zero )
      | (first(.[]) // "")
      | if . == "" then ""
        else . + " — a measurement that produced no samples, or whose measuring"
               + " pipeline exited nonzero, is instrument failure, not a result."
               + " Keep the evidence and declare it: set"
               + " qa_metadata.measurement_failed to a non-empty string naming"
               + " the instrument and what it did. Never report a zero-sample"
               + " run as a number, a zero, or a pass."
        end
    end
  '
}

# artifact_content_gates <json_path>
# Runs every content gate in precedence order and reports the first rejection
# through review_artifact_reason / review_artifact_detail; both are empty when
# the artifact passes. review_artifact_measurement_failed carries the
# artifact's declared instrument-failure marker either way.
# Returns 0 when the artifact passes every gate, 1 when one rejected it.
artifact_content_gates() {
  local file="$1" rc detail
  review_artifact_reason=""
  review_artifact_detail=""
  review_artifact_measurement_failed=""

  rc=0; detail="$(measurement_failed_marker "$file")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    review_artifact_reason="invalid"
    review_artifact_detail="$detail"
    return 1
  fi
  review_artifact_measurement_failed="$detail"

  rc=0; self_reports_no_review "$file" || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    review_artifact_reason="invalid"
    review_artifact_detail="$review_artifact_gate_error"
    return 1
  fi
  if [[ "$rc" -eq 0 ]]; then
    review_artifact_reason="no_review"
    return 1
  fi

  rc=0; qa_shaped_incomplete "$file" || rc=$?
  if [[ "$rc" -eq 2 ]]; then
    review_artifact_reason="invalid"
    review_artifact_detail="$review_artifact_gate_error"
    return 1
  fi
  if [[ "$rc" -eq 0 ]]; then
    review_artifact_reason="incomplete"
    return 1
  fi

  rc=0; detail="$(finding_item_detail "$file")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    review_artifact_reason="invalid"
    review_artifact_detail="$detail"
    return 1
  fi
  if [[ -n "$detail" ]]; then
    review_artifact_reason="incomplete"
    review_artifact_detail="$detail"
    return 1
  fi

  rc=0; detail="$(zero_sample_detail "$file")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    review_artifact_reason="invalid"
    review_artifact_detail="$detail"
    return 1
  fi
  if [[ -n "$detail" ]]; then
    review_artifact_reason="zero_sample"
    review_artifact_detail="$detail"
    return 1
  fi

  return 0
}
