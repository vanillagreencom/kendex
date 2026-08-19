#!/usr/bin/env bash
# The MEASUREMENT gates: did the artifact's own measurements produce samples,
# and does it declare an instrument that did not? Separate from
# review-artifact-gates.sh, which asks whether the review happened at all and
# whether its findings are routable — a different question about a different
# part of the artifact.
#
# Both gates run through review-artifact-gates.sh's gate_filter and obey its
# three-channel rule: answer on stdout, diagnostic on the error file, ran-or-not
# on the exit status.
#
# Sourced by: review-artifact-gates.sh.

set -euo pipefail

# The artifact's instrument-failure declaration, read ONCE and adjudicated here.
# Prints "absent:", "declared:<text>", or "invalid:<why>" — one reading of the
# field, so the echoed value and the decision to suppress the zero-sample gate
# cannot disagree about the same artifact.
#
# Top-level, not under qa_metadata: a declaration is a statement about the RUN,
# like verdict, and burying it in the QA payload made reaching it require
# adopting the qa shape (and its finding-array contract), so a tolerant-shape
# reviewer following the rejection's own instruction hit a second refusal.
# Keeping it out of qa_metadata also keeps it out of the citation scan, so a
# declaration that names the zeros it observed cannot trip the gate it exists
# to release.
measurement_declaration() {
  gate_filter "$1" '
    # gate:measurement-declaration
    def trimmed: tostring | sub("^\\s+"; "") | sub("\\s+$"; "") ;
    def words: [ splits("\\s+") | select(test("[A-Za-z0-9]{2}")) ] | length ;

    .measurement_failed as $m
    | if $m == null then "absent:"
      elif ($m | type) != "string"
        then "invalid:measurement_failed must be a string, got \($m | type)"
      else ($m | trimmed) as $t
        | if ($t | length) == 0
            then "invalid:measurement_failed is blank"
          elif ($t | ascii_downcase | test("^(n/?a|none|null|nil|nothing|unknown|unavailable|tbd|failed|error|yes|no)[.!]*$"))
            then "invalid:measurement_failed is a null token (\"\($t)\") and names no instrument"
          elif (($t | test("[A-Za-z]")) | not)
            then "invalid:measurement_failed is punctuation only and names no instrument"
          elif ($t | length) < 20
            then "invalid:measurement_failed is \($t | length) characters and names no instrument"
          elif ($t | words) < 3
            then "invalid:measurement_failed is \($t | words) word(s) and names no instrument"
          else "declared:" + $t
          end
      end
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
# CARRIERS: `.summary` and `.qa_metadata` only — the places an artifact states
# its OWN evidence. blockers[]/suggestions[]/questions[] describe the code under
# review, so a reviewer quoting a fixture, a log line, or another tool's zeroed
# run puts it there and the gate stays out of its way. Scanning every leaf left
# no honest route for that: the reviewer had to delete its evidence or declare
# an instrument failure that was not its own.
#
# The declaration escape is NOT read here. measurement_declaration adjudicates
# it once and artifact_content_gates skips this gate outright, so there is one
# reading of the field rather than two that can drift.
zero_sample_detail() {
  gate_filter "$1" '
    # gate:zero-sample
    def carriers:
      [ (.summary? | strings) ] + [ (.qa_metadata? // {}) | .. | strings ] ;

    def cites:
      carriers
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

    ( [ cites[] | select(.den == 0)
        | "\(.kind) citation \"\(.label)\" in the summary or qa_metadata reports zero samples" ]
      + [ cites[] | select(.threads != null and .threads == 0)
        | "stability citation \"\(.label)\" in the summary or qa_metadata reports zero threads" ]
      + perf_zero )
    | (first(.[]) // "")
  '
}
