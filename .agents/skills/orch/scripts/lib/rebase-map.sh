#!/usr/bin/env bash
# Read-only owner of worktree::append_rebase_hop's kendex-rebase-map grammar
# and ordered, non-chaining SHA projection. Callers own state writes and file
# deletion. Failures leave REBASE_MAP_FAIL_ARGS for each caller's diagnostic.

REBASE_MAP_TEXT=''
REBASE_MAP_FAIL_ARGS=()
REBASE_MAP_HOPS=0
REBASE_MAP_JSON='{}'
REBASE_MAP_PROJECTED=''

# Both completion's full SHA and workflow state's recorded prefixes use this
# rule. Each row compares against the hop's starting SHA, not another row's
# output. Sequential hops compare against the previous hop's output.
REBASE_MAP_REMAP_JQ='
  def rebase_map_remap($map): . as $sha
    | reduce ($map | to_entries[]) as $e ($sha;
        if ($e.key | startswith($sha))
        then (if $e.value == "dropped" then "dropped:" + $sha else $e.value[0:($sha | length)] end)
        else . end);
'

# Load a file snapshot without consuming it. Check pending rewrites before
# delivering any hop: no mapping repairs a rewrite whose map is unknown.
# The sentinel preserves trailing blank lines so grammar checks see them.
rebase_map_load() {
  local file="$1" line unmapped=''
  REBASE_MAP_TEXT=''
  REBASE_MAP_FAIL_ARGS=()
  REBASE_MAP_HOPS=0
  REBASE_MAP_TEXT="$(cat -- "$file" && printf '.')" || {
    REBASE_MAP_FAIL_ARGS=(map-read)
    return 1
  }
  REBASE_MAP_TEXT="${REBASE_MAP_TEXT%.}"
  REBASE_MAP_TEXT="${REBASE_MAP_TEXT%$'\n'}"
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      'rebase-unmapped: '*) unmapped="${line#rebase-unmapped: }" ;;
    esac
  done <<<"$REBASE_MAP_TEXT"
  if [[ -n "$unmapped" ]]; then
    REBASE_MAP_FAIL_ARGS=(rebase-unmapped "head=$unmapped")
    return 1
  fi
}

# Assemble one hop into REBASE_MAP_JSON. Duplicate old SHAs take the last
# row, as in the producer's existing consumer. Never merge different hops.
rebase_map_parse_hop() {
  local lines="$1" old='' new='' sha_grammar='^[0-9a-f]{40}$'
  REBASE_MAP_JSON='{}'
  while IFS=' ' read -r _ old new; do
    if [[ ! "$old" =~ $sha_grammar ]]; then
      REBASE_MAP_FAIL_ARGS=(map-sha field=old "sha=$old")
      return 1
    fi
    if [[ "$new" != dropped && ! "$new" =~ $sha_grammar ]]; then
      REBASE_MAP_FAIL_ARGS=(map-sha field=new "sha=$new")
      return 1
    fi
    REBASE_MAP_JSON="$(jq -c --arg o "$old" --arg n "$new" '. + {($o): $n}' <<<"$REBASE_MAP_JSON")" || {
      REBASE_MAP_FAIL_ARGS=(map-build)
      return 1
    }
  done <<<"$lines"
}

_rebase_map_deliver_hop() {
  local callback="$1" lines="$2"
  [[ -n "$lines" ]] || { REBASE_MAP_FAIL_ARGS=(restack-map-grammar); return 1; }
  rebase_map_parse_hop "$lines" || return 1
  "$callback" "$REBASE_MAP_JSON" || return 1
  REBASE_MAP_HOPS=$((REBASE_MAP_HOPS + 1))
}

# Deliver each complete hop to CALLBACK with its JSON object. A later malformed
# hop does not undo an earlier delivery. REBASE_MAP_HOPS counts successful
# deliveries, including when a caller refuses a later state write.
rebase_map_each_hop() {
  local callback="$1" line lines='' open=false
  REBASE_MAP_HOPS=0
  while IFS= read -r line || [[ -n "$line" ]]; do
    case "$line" in
      'rebase-hop:')
        if [[ "$open" == true ]]; then
          _rebase_map_deliver_hop "$callback" "$lines" || return 1
        fi
        open=true
        lines=''
        ;;
      'rebase-map: '*)
        [[ "$open" == true ]] || { REBASE_MAP_FAIL_ARGS=(restack-map-grammar); return 1; }
        lines="${lines:+$lines$'\n'}$line"
        ;;
      *) REBASE_MAP_FAIL_ARGS=(restack-map-grammar); return 1 ;;
    esac
  done <<<"$REBASE_MAP_TEXT"
  [[ "$open" == true ]] || { REBASE_MAP_FAIL_ARGS=(restack-map-grammar); return 1; }
  _rebase_map_deliver_hop "$callback" "$lines"
}

_rebase_map_project_hop() {
  REBASE_MAP_PROJECTED="$(jq -nr --arg sha "$REBASE_MAP_PROJECTED" --argjson map "$1" \
    "$REBASE_MAP_REMAP_JQ"'$sha | rebase_map_remap($map)')" || {
    REBASE_MAP_FAIL_ARGS=(map-build)
    return 1
  }
}

# Project one SHA through the loaded hops without writing or deleting the map.
# Consumers accept the result only after this returns success for the whole
# file. A dropped SHA remains marked, never a live SHA a later hop can match.
rebase_map_project() {
  REBASE_MAP_PROJECTED="$1"
  rebase_map_each_hop _rebase_map_project_hop
}
