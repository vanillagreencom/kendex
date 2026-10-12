# Shared judgement for the watch and the read-only reconciliation pass.
# Each caller supplies merge evidence from its existing pull request read.
set -euo pipefail

verifying_error() { # KEY [FIELDS...]
  printf '%s' "$1" >&2
  shift
  printf ' %s' "$@" >&2
  printf '\n' >&2
}

verifying_parse() { # SAFE_ROW
  local record id desc parsed boxes
  # One read for both fields: an issue ID holds no unit separator, and the
  # final dot keeps the description's trailing newlines through substitution.
  record="$(jq -r '"\(.id)\u001f\(.description // "")."' <<<"$1")" || return 1
  id="${record%%$'\037'*}"
  desc="${record#*$'\037'}"
  parsed="$(done_when_parse "${desc%.}" '[]')" || return 1
  boxes="$(jq -c 'if (.errors | length) == 0 and all(.boxes[]; .checked or .post_merge)
    then [.boxes[] | select(.post_merge and (.checked | not))] else empty end' <<<"$parsed")" || boxes=""
  if [[ -z "$boxes" ]]; then
    verifying_error verifying-invalid "issue=$id"
    printf '%s\n' "$parsed" >&2
    return 1
  fi
  printf '%s\n' "$boxes"
}

verifying_judge() { # SAFE_ROW MERGE_EPOCH MERGED_REPOS NOW BOXES ERR_FILE LIMIT GH_CLI [PASS_READ_DIR]
  # GH_CLI follows reconciliation's existing command-word contract.
  local row="$1" merged="$2" merged_repos="$3" now="$4" boxes="$5" errf="$6" release_limit="$7" gh_cli="$8"
  local records id number repo oid glob releases resolved at compare_tag tag comparison read_file fired_at=""
  # The issue ID, then one record per release box. The glob comes last, so
  # read keeps any separator it holds; an oid of `invalid` is a merge row
  # whose commit is not a full hexadecimal object name.
  records="$(jq -r --argjson row "$row" --argjson repos "$merged_repos" '
    $row.id, (.[] | select(.trigger_kind == "release")
      | ($repos[.release_repo | ascii_downcase]
          | if . == null then "" else (try (.mergeCommit.oid | select(type == "string") | select(test("^[0-9a-fA-F]{40}$"))) catch null) // "invalid" end) as $oid
      | "\(.number)\u001f\(.release_repo)\u001f\($oid)\u001f\(.release_glob)")' <<<"$boxes")" || return 1
  id="${records%%$'\n'*}"
  if [[ "$records" == *$'\n'* ]]; then
    [[ "$merged" != null ]] || { verifying_error verifying-merge-unread "issue=$id"; return 2; }
    while IFS=$'\037' read -r number repo oid glob; do
      [[ "$oid" != invalid ]] || { verifying_error verifying-release-unread "" "issue=$id" "repo=$repo"; return 2; }
      read_file=""
      if [[ -n "${9:-}" ]]; then
        read_file="$9/$(printf '%s' "${repo//\//%}" | tr '[:upper:]' '[:lower:]').releases"
      fi
      if [[ -n "$read_file" && -f "$read_file" ]]; then
        releases="$(cat "$read_file")" || { verifying_error verifying-release-unread "" "issue=$id" "repo=$repo"; return 2; }
      else
      releases="$($gh_cli release list --repo "$repo" --limit "$release_limit" --json tagName,publishedAt,isDraft 2>"$errf")" \
        || { verifying_error verifying-release-unread "$(cat "$errf")" "issue=$id" "repo=$repo"; return 2; }
      [[ -z "$read_file" ]] || printf '%s\n' "$releases" >"$read_file" \
        || { verifying_error verifying-release-unread "" "issue=$id" "repo=$repo"; return 2; }
      fi
      # One record per candidate after the merge: its epoch, the tag as a
      # URL path segment, then the tag itself.
      releases="$(jq -r --argjson merged "$merged" --argjson limit "$release_limit" '
        if type != "array" or length >= $limit then error("release-list-incomplete") else . end
        | map(if (.isDraft | type) != "boolean" then error("release-fields") else . end
            | select(.isDraft == false) | .publishedAt as $stamp
            | if (.tagName | type) != "string" or (try ($stamp | fromdateiso8601 | todateiso8601 == $stamp) catch false) != true
              then error("release-fields") else . end)
        | map(. + {at: (.publishedAt | fromdateiso8601)} | select(.at > $merged)) | sort_by(.at)[]
        | "\(.at)\u001f\(.tagName | @uri)\u001f\(.tagName)"' <<<"$releases" 2>"$errf")" \
        || { verifying_error verifying-release-unread "$(cat "$errf")" "issue=$id" "repo=$repo"; return 2; }
      resolved=null
      while IFS=$'\037' read -r at compare_tag tag; do
        [[ -n "$at" ]] || continue
        # The tracker supplies a tag glob, not a literal tag.
        # shellcheck disable=SC2053
        [[ "$tag" == $glob ]] || continue
        # GitHub can publish a tag built before the item's merge. Compare only
        # within that merge's repository; another repository has no such commit.
        if [[ -n "$oid" ]]; then
          comparison="$($gh_cli api "repos/$repo/compare/$oid...$compare_tag" --jq .status 2>"$errf")" \
            || { verifying_error verifying-release-unread "$(cat "$errf")" "issue=$id" "repo=$repo" "tag=$tag"; return 2; }
          case "$comparison" in
            ahead|identical) ;;
            behind|diverged) continue ;;
            *) verifying_error verifying-release-unread "issue=$id" "repo=$repo" "tag=$tag" "status=$comparison"; return 2 ;;
          esac
        fi
        resolved="$at"
        break
      done <<<"$releases"
      fired_at+="${fired_at:+,}\"$number\":$resolved"
    done <<<"${records#*$'\n'}"
  fi
  # Every box result in one pass: release boxes take their resolved
  # publication, then each box takes its status on this pass's clock.
  boxes="$(jq -c --argjson row "$row" --argjson now "$now" --argjson merged "$merged" --argjson fired_at "{$fired_at}" '
    (($row.blocked_by_open // []) | length > 0) as $blocked
    | map((.number | tostring) as $number
      | if $fired_at | has($number) then $fired_at[$number] as $fired
          | .trigger_epoch = $fired | .merged = ($merged | todateiso8601)
          | .deadline_epoch = (if $fired == null then null else $fired + (.deadline_hours * 3600) end)
          | .deadline = (if .deadline_epoch == null then null else .deadline_epoch | todateiso8601 end)
        else . end
      | .status = (if .deadline_epoch != null and .deadline_epoch <= $now then "overdue"
        elif $blocked then "blocked"
        elif .trigger_kind != "merge" and (.trigger_epoch == null or .trigger_epoch > $now) then "waiting"
        else "due" end))' <<<"$boxes")" || { verifying_error verifying-invalid "issue=$id"; return 1; }
  printf '%s\n' "$boxes"
}

# Both operational readers consume this machine-read line.
VERIFYING_LINE_JQ='def verifying_line($id; $row):
  ($row.blocked_by_open // [] | if length == 0 then "-" else join(",") end) as $blocked
  | "verifying \($id) box=\(.number) trigger=\(.trigger | tojson) status=\(.status) deadline=\(.deadline // "-")\(if .merged then " merged=\(.merged)" else "" end) blocked_by=\($blocked) reading=\(.reading | tojson) where=\(.where | tojson) why=\(.why | tojson)";'
verifying_lines() { # ITEM BOXES SAFE_ROW
  jq -r --arg id "$1" --argjson row "$3" "$VERIFYING_LINE_JQ"' .[] | verifying_line($id; $row)' <<<"$2"
}
