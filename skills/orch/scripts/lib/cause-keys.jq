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
