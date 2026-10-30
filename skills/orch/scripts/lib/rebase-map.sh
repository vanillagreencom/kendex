#!/usr/bin/env bash
# Read-only owner of worktree::append_rebase_hop's kendex-rebase-map grammar
# and ordered, non-chaining SHA projection. Callers own state writes and file
# deletion. Failures leave REBASE_MAP_FAIL_ARGS for each caller's diagnostic.

REBASE_MAP_TEXT=''
REBASE_MAP_FAIL_ARGS=()
REBASE_MAP_HOPS=0
REBASE_MAP_JSON='{}'
REBASE_MAP_PROJECTED=''
REBASE_MAP_STRICT=false
REBASE_MAP_VISITED=''
REBASE_MAP_SOURCE=''

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
    if [[ "$REBASE_MAP_STRICT" == true ]] && jq -e --arg old "$old" 'has($old)' <<<"$REBASE_MAP_JSON" >/dev/null; then
      REBASE_MAP_FAIL_ARGS=(map-ambiguous "sha=$old")
      return 1
    fi
    REBASE_MAP_JSON="$(jq -c --arg o "$old" --arg n "$new" '. + {($o): $n}' <<<"$REBASE_MAP_JSON")" || {
      REBASE_MAP_FAIL_ARGS=(map-build)
      return 1
    }
  done <<<"$lines"
  if [[ "$REBASE_MAP_STRICT" == true ]] && ! jq -e '
      def acyclic($map; $key; $seen): $map[$key] as $next
        | if $next == null or $next == "dropped" or $next == $key then true
          elif ($seen | index($next)) != null then false
          else acyclic($map; $next; $seen + [$next]) end;
      . as $map
      | ([.[] | select(. != "dropped")] | length == (unique | length))
        and all(keys[]; acyclic($map; .; [.]))' <<<"$REBASE_MAP_JSON" >/dev/null; then
    REBASE_MAP_FAIL_ARGS=(map-ambiguous)
    return 1
  fi
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
  local previous="$REBASE_MAP_PROJECTED"
  REBASE_MAP_PROJECTED="$(jq -nr --arg sha "$REBASE_MAP_PROJECTED" --argjson map "$1" \
    "$REBASE_MAP_REMAP_JQ"'$sha | rebase_map_remap($map)')" || {
    REBASE_MAP_FAIL_ARGS=(map-build)
    return 1
  }
  if [[ "$REBASE_MAP_STRICT" == true && "$REBASE_MAP_PROJECTED" != "$previous" ]]; then
    if [[ "$REBASE_MAP_VISITED" == *"|$REBASE_MAP_PROJECTED|"* ]]; then
      REBASE_MAP_FAIL_ARGS=(map-cycle "sha=$REBASE_MAP_PROJECTED")
      return 1
    fi
    REBASE_MAP_VISITED="$REBASE_MAP_VISITED$REBASE_MAP_PROJECTED|"
  fi
}

# Project one SHA through the loaded hops without writing or deleting the map.
# Consumers accept the result only after this returns success for the whole
# file. A dropped SHA remains marked, never a live SHA a later hop can match.
rebase_map_project() {
  REBASE_MAP_PROJECTED="$1"
  REBASE_MAP_VISITED="|$1|"
  rebase_map_each_hop _rebase_map_project_hop
}

_rebase_map_validate_hop() { :; }

# Retention keeps the native snapshot's ordered rows, including hop boundaries.
# It does not derive stronger evidence from the flat publication index.
rebase_map_validate_snapshot() {
  local previous="$REBASE_MAP_STRICT" rc=0
  REBASE_MAP_STRICT=true
  rebase_map_each_hop _rebase_map_validate_hop || rc=$?
  REBASE_MAP_STRICT="$previous"
  return "$rc"
}

# One shared reader composes retained native snapshots and a still-private
# suffix. The supplied state comes from workflow-state's existing path owner;
# archives retain that whole state, but an absent active state supplies no proof.
rebase_map_project_bound() { # WORKTREE ISSUE ORIGINAL TARGET [STATE_FILE]
  local REBASE_MAP_STRICT="$REBASE_MAP_STRICT"
  local worktree="$1" issue="$2" original="$3" target="$4" state="${5:-}"
  local records='[]' entry text='' private='' last_text='' last_head='' before after phase previous='' projected combined='' started=false saved_strict="$REBASE_MAP_STRICT"
  REBASE_MAP_FAIL_ARGS=()
  if [[ -z "$state" ]]; then
    state="$(cd -- "$worktree" && "$(dirname -- "${BASH_SOURCE[0]}")/../workflow-state" path "$issue" 2>/dev/null)" \
      || { REBASE_MAP_FAIL_ARGS=(provenance-unreadable); return 1; }
  fi
  REBASE_MAP_SOURCE="$state"
  if [[ -n "$state" && ( -e "$state" || -L "$state" ) ]]; then
    [[ -f "$state" && ! -L "$state" ]] || { REBASE_MAP_FAIL_ARGS=(provenance-unreadable); return 1; }
    records="$(jq -ce --arg issue "$issue" --arg worktree "$worktree" '
      select(.issue_id == $issue)
      | (.rebase_provenance // [])
      | select(type == "array" and all(.[];
          type == "object" and (keys | sort) == ["after_head","before_head","hops","source","worktree"]
          and .worktree == $worktree
          and ([.before_head,.after_head] | all(.[]; type == "string" and test("\\A[0-9a-f]{40}\\z")))
          and (.hops | type == "string" and length > 0 and (contains("\u0000") | not))
          and (.source | type == "object" and (keys | sort) == ["kind","path","phase","status"]
            and .kind == "worktree-push" and (.path | type == "string" and startswith("/") and endswith("/kendex-rebase-map"))
            and (.phase == "pending" or .phase == "prepare" or .phase == "push")
            and (if .phase == "pending" then .status == null
                 else (.status | type == "number" and . == floor and . >= 0 and . <= 255) end))))' "$state")" \
      || { REBASE_MAP_FAIL_ARGS=(provenance-unreadable); return 1; }
  fi
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    text="$(jq -jr '.hops, "."' <<<"$entry")" || return 1
    text="${text%.}"
    before="$(jq -r .before_head <<<"$entry")" || return 1
    after="$(jq -r .after_head <<<"$entry")" || return 1
    phase="$(jq -r .source.phase <<<"$entry")" || return 1
    [[ "$(git -C "$worktree" cat-file -t "$before" 2>/dev/null)" == commit \
      && "$(git -C "$worktree" cat-file -t "$after" 2>/dev/null)" == commit ]] \
      || { REBASE_MAP_FAIL_ARGS=(provenance-incomplete); return 1; }
    if [[ "$text" == "$last_text" && "$after" == "$last_head" ]]; then
      REBASE_MAP_FAIL_ARGS=(map-ambiguous); return 1
    fi
    REBASE_MAP_TEXT="$text"
    rebase_map_validate_snapshot || return 1
    REBASE_MAP_STRICT=true
    if [[ "$started" == false ]]; then
      # An earlier unbound snapshot cannot supply a missing historical
      # operation. It is irrelevant only when this actual operation still
      # contains the original input before any correspondence is applied.
      if [[ "$phase" != pending ]] && git -C "$worktree" merge-base --is-ancestor "$original" "$before" 2>/dev/null; then
        started=true
      else
        continue
      fi
    fi
    if [[ "$phase" == pending ]]; then
      REBASE_MAP_FAIL_ARGS=(provenance-operation-unbound); return 1
    elif ! rebase_map_project "$before" || [[ "$REBASE_MAP_PROJECTED" != "$after" ]]; then
      REBASE_MAP_FAIL_ARGS=(provenance-incomplete); return 1
    fi
    if [[ -n "$previous" ]]; then
      rebase_map_project "$previous" || return 1
      projected="$REBASE_MAP_PROJECTED"
      [[ "$projected" =~ ^[0-9a-f]{40}$ ]] && git -C "$worktree" merge-base --is-ancestor "$projected" "$after" 2>/dev/null \
        || { REBASE_MAP_FAIL_ARGS=(provenance-incomplete); return 1; }
    fi
    combined="${combined:+$combined$'\n'}$text"
    previous="$after" last_head="$after" last_text="$text"
  done < <(jq -c '.[]' <<<"$records")
  private="$(git -C "$worktree" rev-parse --git-path kendex-rebase-map)" || return 1
  [[ "$private" == /* ]] || private="$worktree/$private"
  if [[ -e "$private" || -L "$private" ]]; then
    REBASE_MAP_SOURCE="$private"
    rebase_map_load "$private" || return 1
    text="$REBASE_MAP_TEXT"
    if [[ "$text" == "$last_text" ]]; then
      # Persistence may have succeeded while removal of its private copy failed.
      :
    elif [[ -n "$last_text" && "$text" == "$last_text"$'\n'* ]]; then
      REBASE_MAP_FAIL_ARGS=(provenance-incomplete); return 1
    else
      if [[ -n "$last_head" ]]; then
        REBASE_MAP_STRICT=true
        rebase_map_project "$last_head" || return 1
        last_head="$REBASE_MAP_PROJECTED"
      fi
      combined="${combined:+$combined$'\n'}$text"
    fi
  fi
  if [[ -z "$combined" ]]; then
    if [[ "$records" == '[]' ]]; then REBASE_MAP_FAIL_ARGS=(provenance-unavailable)
    else REBASE_MAP_FAIL_ARGS=(provenance-operation-unbound)
    fi
    return 1
  fi
  if [[ -n "$last_head" ]]; then
    [[ "$last_head" =~ ^[0-9a-f]{40}$ ]] && git -C "$worktree" merge-base --is-ancestor "$last_head" "$target" 2>/dev/null \
      || { REBASE_MAP_FAIL_ARGS=(provenance-incomplete); return 1; }
  fi
  REBASE_MAP_TEXT="$combined"
  REBASE_MAP_STRICT=true
  local rc=0
  rebase_map_project "$original" || rc=$?
  REBASE_MAP_STRICT="$saved_strict"
  (( rc == 0 )) && [[ "$REBASE_MAP_PROJECTED" =~ ^[0-9a-f]{40}$ ]] \
    || { [[ ${#REBASE_MAP_FAIL_ARGS[@]} -gt 0 ]] || REBASE_MAP_FAIL_ARGS=(provenance-dropped); return 1; }
}
