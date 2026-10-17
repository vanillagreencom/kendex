# Shared judgement for the watch and the read-only reconciliation pass.
# Each caller supplies merge evidence from its existing pull request read.
set -euo pipefail
# shellcheck source=branch-growth.sh
source "$(dirname "${BASH_SOURCE[0]}")/branch-growth.sh"

verifying_error() { # KEY [FIELDS...]
  printf '%s' "$1" >&2
  shift
  printf ' %s' "$@" >&2
  printf '\n' >&2
}

# Callers supply live parents and their direct child state facts.
# Completed children make their container outcome due for its holder, never Done.
verifying_containers() { # SAFE_ITEMS
  local candidates row description
  candidates="$(jq -c '
    . as $live
    | map(select(.parent_id != null and .parent_id != "")) | group_by(.parent_id)[]
    | .[0].parent_id as $pid
    | map(select(.state_type != "canceled"))
    | select(length > 0 and all(.[]; .state_type == "completed"))
    | ($live[] | select(.id == $pid))
    | select(.state_type != "completed" and .state_type != "canceled")
    | select((.title // "") | test("\\(one PR\\)"; "i") | not)
    | . + {container: true}' <<<"$1")" || return 1
  while IFS= read -r row; do
    [[ -n "$row" ]] || continue
    description="$(jq -r '.description // ""' <<<"$row")" || return 1
    expected_delta_read "$description" || EXPECTED_DELTA_PRODUCTION=""
    [[ -z "$EXPECTED_DELTA_PRODUCTION" || "$EXPECTED_DELTA_PRODUCTION" == 0 ]] || continue
    printf '%s\n' "$row"
  done <<<"$candidates"
}

verifying_parse() { # SAFE_ROW
  local record id desc parsed boxes role
  # One read for the ID, role and description: an ID holds no unit separator, and the
  # final dot keeps the description's trailing newlines through substitution.
  record="$(jq -r '"\(.id)\u001f\(if .container then "container" else "issue" end)\u001f\(.description // "")."' <<<"$1")" || return 1
  id="${record%%$'\037'*}"
  desc="${record#*$'\037'}"
  role="${desc%%$'\037'*}"
  desc="${desc#*$'\037'}"
  parsed="$(done_when_parse "${desc%.}" '[]' '' '{}' "$role")" || return 1
  boxes="$(jq -c --argjson row "$1" '
    if $row.container == true then
      .missing_evidence_boxes as $missing
      | (if .missing_outcome_box then
          [{number: 0, text: .outcome_remedy}]
         else [.boxes[] | select((.checked | not) or ((.number as $n | $missing | index($n)) != null))] end)
      | map(
        . + {trigger: "outcome", trigger_kind: "outcome", trigger_epoch: null,
               deadline_epoch: null, deadline_hours: null, deadline: null, reading: .text, where: "-", why: "-"})
    else if (.errors | length) == 0 and all(.boxes[]; .checked or .post_merge)
    then [.boxes[] | select(.post_merge and (.checked | not))] else empty end end
    # A release box and a merge box with +Nh need the merge read: the release
    # to find its publication after merge, the merge box to count its hours from it.
    | map(. + {needs_merge: (.trigger_kind == "release" or (.trigger_kind == "merge" and .deadline_hours != null))})' <<<"$parsed")" || boxes=""
  if [[ -z "$boxes" ]]; then
    verifying_error verifying-invalid "issue=$id"
    printf '%s\n' "$parsed" >&2
    return 1
  fi
  printf '%s\n' "$boxes"
}

verifying_judge() { # SAFE_ROW MERGE_EPOCH MERGED_REPOS NOW BOXES ERR_FILE GH_CLI [PASS_READ_DIR]
  # GH_CLI follows reconciliation's existing command-word contract.
  local row="$1" merged="$2" merged_repos="$3" now="$4" boxes="$5" errf="$6" gh_cli="$7"
  local records id needs_merge number repo oid glob releases resolved at compare_tag tag comparison read_file page page_data fired_at=""
  # The issue ID and whether any box needs the merge, then one record per
  # release box. The glob comes last, so read keeps any separator it holds;
  # an oid of `invalid` is a merge row whose commit is not a full
  # hexadecimal object name.
  records="$(jq -r --argjson row "$row" --argjson repos "$merged_repos" '
    "\($row.id)\u001f\(any(.[]; .needs_merge))", (.[] | select(.trigger_kind == "release")
      | ($repos[.release_repo | ascii_downcase]
          | if . == null then "" else (try (.mergeCommit.oid | select(type == "string") | select(test("^[0-9a-fA-F]{40}$"))) catch null) // "invalid" end) as $oid
      | "\(.number)\u001f\(.release_repo)\u001f\($oid)\u001f\(.release_glob)")' <<<"$boxes")" || return 1
  id="${records%%$'\n'*}"
  needs_merge="${id##*$'\037'}"
  id="${id%$'\037'*}"
  [[ "$needs_merge" == false || "$merged" != null ]] || { verifying_error verifying-merge-unread "issue=$id"; return 2; }
  if [[ "$records" == *$'\n'* ]]; then
    while IFS=$'\037' read -r number repo oid glob; do
      [[ "$oid" != invalid ]] || { verifying_error verifying-release-unread "" "issue=$id" "repo=$repo"; return 2; }
      releases="" page=1
      while :; do
        read_file=""
        # Share complete history within the pass. GitHub's release list has
        # no publication-time ordering guarantee: old drafts can publish later.
        if [[ -n "${8:-}" ]]; then
          read_file="$8/$(printf '%s' "${repo//\//%}" | tr '[:upper:]' '[:lower:]').releases.$page"
        fi
        if [[ -n "$read_file" && -f "$read_file" ]]; then
          page_data="$(cat "$read_file")" || { verifying_error verifying-release-unread "" "issue=$id" "repo=$repo"; return 2; }
        else
          page_data="$($gh_cli api "repos/$repo/releases?per_page=100&page=$page" 2>"$errf")" \
            || { verifying_error verifying-release-unread "$(cat "$errf")" "issue=$id" "repo=$repo"; return 2; }
          [[ -z "$read_file" ]] || printf '%s\n' "$page_data" >"$read_file" \
            || { verifying_error verifying-release-unread "" "issue=$id" "repo=$repo"; return 2; }
        fi
        page_data="$(jq -r '
          if type != "array" then error("release-fields") else . end
          | map({tagName: .tag_name, publishedAt: .published_at, isDraft: .draft}
              | if (.isDraft | type) != "boolean" then error("release-fields") else . end
              | if .isDraft then . else .publishedAt as $stamp
                | if (.tagName | type) != "string" or (try ($stamp | fromdateiso8601 | todateiso8601 == $stamp) catch false) != true
                  then error("release-fields") else . end end)
          | "\(length < 100)\u001f\(tojson)"' <<<"$page_data" 2>"$errf")" \
          || { verifying_error verifying-release-unread "$(cat "$errf")" "issue=$id" "repo=$repo"; return 2; }
        releases+="${releases:+$'\n'}${page_data#*$'\037'}"
        [[ "${page_data%%$'\037'*}" != true ]] || break
        page=$((page + 1))
      done
      # One record per candidate after the merge: its epoch, the tag as a
      # URL path segment, then the tag itself.
      releases="$(jq -rs --argjson merged "$merged" '
        add | map(select(.isDraft == false))
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
  # publication, a +Nh deadline counts from its trigger, then each box takes
  # its status on this pass's clock.
  boxes="$(jq -c --argjson row "$row" --argjson now "$now" --argjson merged "$merged" --argjson fired_at "{$fired_at}" '
    (($row.blocked_by_open // []) | length > 0) as $blocked
    | map((.number | tostring) as $number
      | if $fired_at | has($number) then $fired_at[$number] as $fired
          | .trigger_epoch = $fired | .merged = ($merged | todateiso8601)
        else . end
      | if .deadline_hours != null then
          (if .trigger_kind == "merge" then $merged else .trigger_epoch end) as $fired
          | .deadline_epoch = (if $fired == null then null else $fired + (.deadline_hours * 3600) end)
          | .deadline = (if .deadline_epoch == null then null else .deadline_epoch | todateiso8601 end)
        else . end
      | .status = (if .deadline_epoch != null and .deadline_epoch <= $now then "overdue"
        elif $blocked then "blocked"
        elif .trigger_kind != "merge" and .trigger_kind != "outcome" and (.trigger_epoch == null or .trigger_epoch > $now) then "waiting"
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
