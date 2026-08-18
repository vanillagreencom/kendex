#!/usr/bin/env bash
# Content gates for a reviewer's on-disk JSON artifact: the predicates that
# answer "is what this artifact SAYS usable?", as opposed to review-artifact-check's
# own job of locating an artifact, judging its freshness, and dispatching modes.
# Every gate reads one JSON path and answers on exit status or on stdout; none
# of them print JSON or exit the process, so the caller owns reason precedence.
#
# Sourced by: review-artifact-check.

set -euo pipefail

# vstack#652: a schema-valid artifact can carry verdict "pass" while its
# qa_metadata admits no review happened (external second-opinion invoked with
# no scope). Such a self-reported no-review is rejected regardless of verdict.
# Artifacts without qa_metadata (internal reviewers) are unaffected.
self_reports_no_review() {
  jq -e '
    (.qa_metadata? // {}) as $qa
    | (($qa | type) == "object")
      and (($qa.review_performed == false)
           or ((($qa.reason // "") | tostring)
               | test("no[ _-]?(scope|review)|not[ _-]?reviewed"; "i")))
  ' "$1" >/dev/null 2>&1
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
  jq -e '
    ((.qa_metadata? | type) == "object")
      and (((.blockers? | type) != "array")
           or ((.suggestions? | type) != "array"))
  ' "$1" >/dev/null 2>&1
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
  jq -r '
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
  ' "$1" 2>/dev/null
}

# vstack#1497: a measurement instrument that produced no samples still emits a
# number, and a zero reads as green. The reviewer skill fixes the citation
# format for mutation/stability evidence (`mutation: killed X/X; stability: Y/N
# at T threads`) and the perf QA payload carries benchmark percentiles; in both,
# a zero sample count, a zero thread count, or an empty/all-zero percentile
# block means the instrument measured nothing. Scanned over every string leaf so
# the citation is caught wherever the reviewer put it (summary, blocker
# description, qa_metadata), and — unlike the qa-shape checks above — gated on
# nothing, because the pairing binds every reviewer, not only qa-shaped ones.
# Prints the first offending diagnostic on stdout, empty string when no
# measurement is zero-sample.
zero_sample_detail() {
  jq -r '
    def cites:
      [ .. | strings ]
      | map(
          ( [ scan("(?i)killed[ \t]*([0-9]+)[ \t]*/[ \t]*([0-9]+)") ]
            | map({kind: "mutation",
                   label: ("killed " + .[0] + "/" + .[1]),
                   den: (.[1] | tonumber),
                   threads: null}) )
          + ( [ scan("(?i)stability:[ \t]*([0-9]+)[ \t]*/[ \t]*([0-9]+)(?:[ \t]*at[ \t]*([0-9]+)[ \t]*threads?)?") ]
            | map({kind: "stability",
                   label: ("stability: " + .[0] + "/" + .[1]),
                   den: (.[1] | tonumber),
                   threads: (if .[2] == null then null else (.[2] | tonumber) end)}) )
        )
      | (add // []) ;

    def perf_zero:
      ((.qa_metadata? // {}) | if type == "object" then (.perf_qa? // null) else null end) as $pq
      | if ($pq | type) == "object" and (($pq.percentiles? | type) == "object")
        then ($pq.percentiles) as $p
          | if ($p | length) == 0 then ["benchmark percentiles block is empty"]
            else ([$p | .. | numbers]) as $nums
              | if (($nums | length) > 0) and ($nums | all(. == 0))
                then ["benchmark percentiles are all zero"] else [] end
            end
        else [] end ;

    ( [ cites[] | select(.den == 0)
        | "\(.kind) citation \"\(.label)\" reports zero samples" ]
      + [ cites[] | select(.threads != null and .threads == 0)
        | "stability citation \"\(.label)\" reports zero threads" ]
      + perf_zero )
    | (first(.[]) // "")
    | if . == "" then ""
      else . + " — a measurement that produced no samples, or whose measuring"
             + " pipeline exited nonzero, is instrument failure: report the"
             + " failure, never a number, a zero, or a pass"
      end
  ' "$1" 2>/dev/null
}
