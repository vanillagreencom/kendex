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

# jq's stderr lands here and is read only when the gate's exit status says the
# gate failed. Never printed as an answer.
review_artifact_gate_err="$(mktemp)"
trap 'rm -f "$review_artifact_gate_err"' EXIT

# The rejecting reason and its detail, set by artifact_content_gates. Every
# rejection carries a detail: a reason with no cause is a dead end for the agent
# that has to fix it, which review-pr.md § 3.1 spends its one re-delegation on.
review_artifact_reason=""
review_artifact_detail=""

# The artifact's validated instrument-failure declaration; empty when it makes
# none.
review_artifact_measurement_failed=""

# What a declaration has to say for the gate to accept it. Named once so the
# rejection and the documentation cannot drift apart.
REVIEW_DECLARATION_BAR="a declaration must name the instrument and what it did — at least 20 characters and 3 words, not a null token (n/a, none, unknown, ...) or bare punctuation"

# gate_filter <json_path> <jq_program>
# stdout: the gate's answer, and nothing else. Empty means the gate found
# nothing wrong. Exit 0 = the gate ran, 2 = it could not; on 2 the caller reads
# gate_failure_detail. Callers invoke this through a command substitution, whose
# subshell discards globals, so the exit status is the only signal that crosses
# back — which is exactly why the diagnostic must not ride on stdout.
gate_filter() {
  local file="$1" program="$2" out rc=0
  out="$(jq -r "$program" "$file" 2>"$review_artifact_gate_err")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    return 2
  fi
  printf '%s' "$out"
  return 0
}

# gate_failure_detail <exit_code>
# The diagnostic for a gate that could not run, read from the error channel.
gate_failure_detail() {
  local rc="$1" err=""
  err="$(tr '\n\t' '  ' < "$review_artifact_gate_err" 2>/dev/null || printf '')"
  printf 'gate could not run: jq exited %s%s' "$rc" "${err:+: $err}"
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
    if ((.qa_metadata? | type) == "object") then
      ( [ (if (.blockers? | type) != "array" then "blockers[]" else empty end),
          (if (.suggestions? | type) != "array" then "suggestions[]" else empty end) ] ) as $missing
      | if ($missing | length) > 0
        then "\($missing | join(" and ")) missing or not an array — declaring qa_metadata commits the"
             + " artifact to both finding arrays, empty ones included. An artifact with no qa_metadata"
             + " does not have to carry them."
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
# Runs every content gate in precedence order and reports the first rejection
# through review_artifact_reason / review_artifact_detail; reason is
# "valid" or "valid_undermeasured" when the artifact passes.
# review_artifact_measurement_failed carries a validated declaration.
# Returns 0 when the artifact passes every gate, 1 when one rejected it.
artifact_content_gates() {
  local file="$1" rc out
  review_artifact_reason=""
  review_artifact_detail=""
  review_artifact_measurement_failed=""

  rc=0; out="$(self_reports_no_review "$file")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    review_artifact_reason="invalid"
    review_artifact_detail="$(gate_failure_detail "$rc")"
    return 1
  fi
  if [[ -n "$out" ]]; then
    review_artifact_reason="no_review"
    review_artifact_detail="$out"
    return 1
  fi

  rc=0; out="$(qa_shaped_incomplete "$file")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    review_artifact_reason="invalid"
    review_artifact_detail="$(gate_failure_detail "$rc")"
    return 1
  fi
  if [[ -n "$out" ]]; then
    review_artifact_reason="incomplete"
    review_artifact_detail="$out"
    return 1
  fi

  rc=0; out="$(finding_item_detail "$file")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    review_artifact_reason="invalid"
    review_artifact_detail="$(gate_failure_detail "$rc")"
    return 1
  fi
  if [[ -n "$out" ]]; then
    review_artifact_reason="incomplete"
    review_artifact_detail="$out"
    return 1
  fi

  rc=0; out="$(measurement_declaration "$file")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    review_artifact_reason="invalid"
    review_artifact_detail="$(gate_failure_detail "$rc")"
    return 1
  fi
  case "$out" in
    invalid:*)
      review_artifact_reason="invalid_declaration"
      review_artifact_detail="${out#invalid:} — $REVIEW_DECLARATION_BAR"
      return 1
      ;;
    declared:*)
      # An adjudicated declaration replaces the zero-sample gate rather than
      # being re-read inside it, and the accepting reason says so: a caller
      # branching on reason cannot record an undermeasured domain as clean.
      review_artifact_measurement_failed="${out#declared:}"
      review_artifact_reason="valid_undermeasured"
      return 0
      ;;
  esac

  rc=0; out="$(zero_sample_detail "$file")" || rc=$?
  if [[ "$rc" -ne 0 ]]; then
    review_artifact_reason="invalid"
    review_artifact_detail="$(gate_failure_detail "$rc")"
    return 1
  fi
  if [[ -n "$out" ]]; then
    review_artifact_reason="zero_sample"
    review_artifact_detail="$out"
    return 1
  fi

  review_artifact_reason="valid"
  return 0
}
