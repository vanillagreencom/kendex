# Fix workflows produce location headers, optional Owner lines and patch entries.
# Shared keys keep the stamp and the recorded-round count on the same local rule.
def cause_key:
  if type == "string" then
    sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; "")
    | select(. != "" and . != "TBD" and . != "general")
  else empty end;

def cause_keys:
  (if has("text") then
    (.text | split("\n")) as $lines
    | {location: ($lines[0] | split("|") | .[2:] | join("|")),
       owner: (first($lines[1:][] | select(startswith("Owner:")) | ltrimstr("Owner:")) // null)}
  else . end)
  | [(.location, .owner) | cause_key] | unique;

def shared_cause_key($a; $b):
  ($a | cause_keys) as $keys
  | first($b | cause_keys | .[] | select(. as $key | $keys | index($key))) // empty;

# Disposition supplies verified review items; completion receipts publish checks.
# Missing bindings are coverage gaps, never another spelling of a class.
def occurrence_class:
  if .kind == "review" then {kind, location} + (if .owner then {owner} else {} end)
  elif .kind == "validation" then {kind, check}
  else error("finding-kind") end;

def occurrence_bound:
  (.source.round_id | type == "string" and length > 0)
  and (.source.identity | type == "array" and length > 0)
  and (if .kind == "review" then
    (cause_keys | length > 0) and (.source.artifact | type == "string" and length > 0)
  elif .kind == "validation" then
    (.check | type == "string" and length > 0)
    and (.source.receipt | type == "string" and length > 0)
  else false end);

def record_occurrences($batch):
  .finding_occurrences //= {prior: "unknown", records: []}
  | if $batch.unknown == true then .finding_occurrences.prior = "unknown" else . end
  | reduce $batch.records[] as $record (.;
      if ($record | occurrence_bound) then
        [.finding_occurrences.records[] | select(.source.identity == $record.source.identity)] as $old
        | if ($old | length) == 0 then .finding_occurrences.records += [$record]
          elif all($old[]; occurrence_class == ($record | occurrence_class)) then .
          else error("finding-source-conflict") end
      else .finding_occurrences.prior = "unknown" end);

def validation_occurrences($artifact; $receipt):
  if ($artifact.validate | startswith("FAILING:")) then
    ($artifact.validate | ltrimstr("FAILING:") | split(",")
      | map(sub("^[[:space:]]+"; "") | sub("[[:space:]]+$"; ""))) as $checks
    | if any($checks[]; . == "") then {unknown: true, records: []}
      else {records: [$checks | unique | .[] | . as $check
        | {kind: "validation", check: $check,
           source: {round_id: $artifact.round_id, receipt: $receipt,
             identity: ["receipt", $artifact.round_id, $receipt, $check]}}]} end
  else {records: []} end;

# Requested classes come from the proposed fix's review items or exact receipt
# check names. Reports omit requests and use the same query over known classes.
def finding_summary($requests):
  (.finding_occurrences // {prior: "unknown", records: []}) as $history
  | {prior: $history.prior, classes:
      [($requests // ($history.records | map(occurrence_class) | unique))[] as $request
       | (if $request.kind == "review" then ($request | cause_keys | length) > 0
          else ($request.check | type == "string" and length > 0) end) as $bound
       | [$history.records[] | select(.kind == $request.kind)
          | select(if .kind == "review" then ([shared_cause_key(.; $request)] | length) > 0
                   else .check == $request.check end)] as $matches
       | {class: ($request | occurrence_class), observed_count: (if $bound then ($matches | length) else null end),
          prior: (if $bound then $history.prior else "unknown" end), sources: ($matches | map(.source))}]};
