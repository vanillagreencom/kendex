#!/usr/bin/env bash
# The 'vendored' carry class: a changed file under a kendex render tree
# carries only as kendex's own output, proven by content, never by path.
#
# The proof is the repository's kendex lock (.kendex-lock.json), which
# records every file kendex wrote by repository path with the plain SHA-256
# of its bytes. Read at head and at the carry base through GraphQL blob
# objects — the writer evaluates from a default-branch checkout, so the
# head tree is only ever reachable through the API, and one query resolves
# a hundred objects, where a per-file contents read would spend the hourly
# budget on one refresh. A file the lock at head records must hash to what
# it records; a file the lock at base recorded and head no longer does must
# be gone from the tree; and every hash the lock at head newly records must
# belong to a file this delta wrote and proved. Anything else under a
# recorded path — a hand-edit, a rename, a lock claiming bytes the delta
# never carried — refuses the whole carry, so a recorded file never falls
# through to 'docs' by extension. Paths the lock never named are not this
# class's to judge: they go on to the name-based classes.
#
# Run by review-predicate.sh inside its candidate walk, after the
# control-character scan that makes newline-split names and an inline
# GraphQL query safe to build from them:
#
#   carry-vendored.sh BASE_SHA  < compare-json
#
# with GH_REPO and HEAD_SHA in the environment, and the predicate's own
# gh_read exported (with API_ATTEMPTS and API_RETRY_DELAY) so every read
# here keeps the predicate's retry discipline. Stdout: one proven delta path
# per line. Exit 0 = proven (possibly nothing to prove); 1 = the delta
# touches a recorded path it cannot prove, with the reason as a ::warning —
# the predicate refuses the carry; 2 = a failed read, no verdict.
set -euo pipefail

base="${1:?usage: carry-vendored.sh BASE_SHA < compare-json}"
: "${GH_REPO:?GH_REPO is required}"
: "${HEAD_SHA:?HEAD_SHA is required}"
if ! declare -F gh_read >/dev/null; then
  echo "::error::carry-vendored: gh_read is not exported by the caller" >&2
  exit 2
fi
cmp="$(cat)"

KENDEX_LOCK=".kendex-lock.json"

# rg_blobs SHA PATH... -> a JSON array, one Blob object or null per PATH in
# argument order, read a hundred objects per GraphQL call. A failed,
# empty, malformed or errored read is exit 2: a null read as "absent"
# would prove a removal nothing removed.
rg_blobs() {
  local sha="$1" chunk query page merged='[]'
  shift
  while IFS= read -r chunk; do
    [ -n "$chunk" ] || continue
    query="$(jq -rn --arg sha "$sha" --argjson paths "$chunk" '
      "query($owner:String!,$name:String!){repository(owner:$owner,name:$name){"
      + ([ range(0; $paths | length) as $i
           | "b\($i):object(expression:\(($sha + ":" + $paths[$i]) | @json)){... on Blob{text isBinary isTruncated byteSize}}"
         ] | join(" "))
      + "}}"')" || {
      echo "::error::could not build the blob query for $sha" >&2
      exit 2
    }
    page="$(gh_read graphql -f query="$query" -F owner="${GH_REPO%/*}" -F name="${GH_REPO#*/}")" || {
      echo "::error::could not read the vendored-class blobs at $sha" >&2
      exit 2
    }
    if [ -z "$page" ]; then
      echo "::error::blob read at $sha produced zero bytes (broken read)" >&2
      exit 2
    fi
    merged="$(printf '%s\n%s\n' "$merged" "$page" | jq -s --argjson n "$(jq 'length' <<<"$chunk")" '
      .[0] as $acc | .[1] as $page
      | if (($page.errors // []) | length) > 0 or (($page.data.repository | type) != "object")
        then error("blob page is not a repository object, or carries errors")
        else $acc + [ range(0; $n) as $i | $page.data.repository["b\($i)"] ] end')" || {
      echo "::error::the blob read at $sha is malformed (no repository object, or GraphQL errors)" >&2
      exit 2
    }
  done <<EOF_CHUNKS
$(printf '%s\n' "$@" | jq -R . | jq -c 'def chunks($n): if length <= $n then . else .[0:$n], (.[$n:] | chunks($n)) end; [., inputs] | map(select(length > 0)) | chunks(100)')
EOF_CHUNKS
  printf '%s' "$merged"
}

# rg_vendored_check BASE CMP -> the proven delta paths on stdout, one per
# line, and 0; a ::warning and 1 when the delta touches a recorded path it
# cannot prove.
rg_vendored_check() {
  local base="$1" cmp="$2" locks head_lock base_lock plan refuse verify vendored blobs count i path want got
  locks="$(rg_blobs "$HEAD_SHA" "$KENDEX_LOCK")" || exit 2
  head_lock="$(jq -c '.[0]' <<<"$locks")"
  locks="$(rg_blobs "$base" "$KENDEX_LOCK")" || exit 2
  base_lock="$(jq -c '.[0]' <<<"$locks")"
  plan="$(printf '%s\n%s\n%s\n' "$cmp" "$head_lock" "$base_lock" | jq -cs --arg lock "$KENDEX_LOCK" '
    # A Blob (or null) -> the paths it records. ok=false is a lock that
    # exists but cannot be read as one: binary, truncated, not JSON, or
    # two entries recording one path with different bytes.
    def lock_map:
      if . == null then {ok: true, absent: true, map: {}}
      elif (.isBinary // false) or (.isTruncated // false) or ((.text | type) != "string")
      then {ok: false, absent: false, map: {}}
      else ((.text | try fromjson catch null) as $l
        | if ($l | type) != "object" then {ok: false, absent: false, map: {}}
          else ([ ($l.entries // {}) | .[]? | (.renderedFiles // {}) | to_entries[] ] | group_by(.key)) as $g
            | if any($g[]; (map(.value) | unique | length) > 1)
              then {ok: false, absent: false, map: {}}
              else {ok: true, absent: false, map: ($g | map(.[0]) | from_entries)} end
          end)
      end;
    .[0] as $cmp | (.[1] | lock_map) as $head | (.[2] | lock_map) as $base
    | $head.map as $h | $base.map as $b
    | [ $cmp.files[] | {fn: (.filename // ""), status: (.status // ""), prev: (.previous_filename // "")} ] as $files
    | def recorded($f): ($h | has($f)) or ($b | has($f));
    ($files | map(select(.fn == $lock or recorded(.fn) or (.prev != "" and recorded(.prev)))) | length > 0) as $touches
    | if ($touches | not) then {refuse: null, verify: [], vendored: []}
      elif ($base.ok | not) then {refuse: "the kendex lock at the carry base cannot be read as a lock", verify: [], vendored: []}
      elif ($head.ok | not) then {refuse: "the kendex lock at head cannot be read as a lock", verify: [], vendored: []}
      else
        [ $files[] | . as $f
          | if $f.fn == $lock then
              if $head.absent then {refuse: "the kendex lock is gone at head"} else {vendored: $f.fn} end
            elif ($f.prev != "" or $f.status == "renamed" or $f.status == "copied") then
              if recorded($f.fn) or ($f.prev != "" and recorded($f.prev))
              then {refuse: "\($f.fn) is a rename or copy of a recorded path"} else empty end
            elif ($h | has($f.fn)) then
              if $f.status == "added" or $f.status == "modified" then {verify: $f.fn}
              else {refuse: "\($f.fn) is recorded at head but \($f.status) in the delta"} end
            elif ($b | has($f.fn)) then
              if $f.status == "removed" then {vendored: $f.fn}
              else {refuse: "\($f.fn) was recorded at the carry base and is \($f.status) at head with no record"} end
            else empty end
        ] as $rows
        | ($rows | map(.verify // empty)) as $verify
        | { refuse: (
              ($rows | map(.refuse // empty) | first)
              // ([ $h | to_entries[] | select($b[.key] != .value) | .key as $k | $k | select(($verify | index($k)) == null) ] | first
                  | if . == null then null else "the kendex lock at head records \(.), which this delta did not write" end)),
            verify: $verify,
            vendored: ($rows | map(.vendored // empty)) }
      end')" || {
    echo "::error::could not plan the vendored-class check for $base...$HEAD_SHA" >&2
    exit 2
  }
  refuse="$(jq -r '.refuse // ""' <<<"$plan")"
  if [ -n "$refuse" ]; then
    echo "::warning::compare $base...$HEAD_SHA: $refuse; refusing carry-forward (fresh evidence required)" >&2
    return 1
  fi
  verify="$(jq -r '.verify[]' <<<"$plan")"
  vendored="$(jq -r '.vendored[]' <<<"$plan")"
  if [ -n "$verify" ]; then
    blobs="$(rg_blobs "$HEAD_SHA" "$verify")" || exit 2
    count="$(jq 'length' <<<"$blobs")"
    i=0
    while [ "$i" -lt "$count" ]; do
      path="$(jq -r --argjson i "$i" '.verify[$i]' <<<"$plan")"
      # A blob GitHub could not serve whole — binary, truncated, or a text
      # whose byte length is not the object's — proves nothing.
      if [ "$(jq --argjson i "$i" '.[$i] | . != null and (.isBinary | not) and (.isTruncated | not) and ((.text | type) == "string") and ((.text | utf8bytelength) == .byteSize)' <<<"$blobs")" != "true" ]; then
        echo "::warning::compare $base...$HEAD_SHA: $path at head is not a text blob the lock can be checked against; refusing carry-forward (fresh evidence required)" >&2
        return 1
      fi
      want="$(printf '%s\n%s\n' "$head_lock" "$plan" | jq -rs --argjson i "$i" '.[1].verify[$i] as $p | (.[0].text | fromjson) | [ .entries[]? | (.renderedFiles // {})[$p] // empty ] | first')"
      got="$(jq -j --argjson i "$i" '.[$i].text' <<<"$blobs" | sha256sum | cut -d' ' -f1)"
      if [ "$got" != "$want" ]; then
        echo "::warning::compare $base...$HEAD_SHA: $path at head is not the render the kendex lock records (edited by hand?); refusing carry-forward (fresh evidence required)" >&2
        return 1
      fi
      i=$((i + 1))
    done
  fi
  printf '%s\n%s\n' "$vendored" "$verify" | sed '/^$/d'
  return 0
}

rg_vendored_check "$base" "$cmp"
