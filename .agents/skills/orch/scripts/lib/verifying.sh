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
  local row="$1" id desc parsed
  id="$(jq -r '.id' <<<"$row")" || return 1
  desc="$(jq -r '(.description // "") + "."' <<<"$row")" || return 1
  parsed="$(done_when_parse "${desc%.}" '[]')" || return 1
  if ! jq -e '(.errors | length) == 0 and all(.boxes[]; .checked or .post_merge)' <<<"$parsed" >/dev/null; then
    verifying_error verifying-invalid "issue=$id"
    printf '%s\n' "$parsed" >&2
    return 1
  fi
  jq -c '[.boxes[] | select(.post_merge and (.checked | not))]' <<<"$parsed"
}

verifying_judge() { # SAFE_ROW MERGE_EPOCH MERGED_REPOS NOW BOXES ERR_FILE LIMIT GH_CLI
  # GH_CLI follows reconciliation's existing command-word contract.
  local row="$1" merged="$2" merged_repos="$3" now="$4" boxes="$5" errf="$6" release_limit="$7" gh_cli="$8"
  local id blocked release_rows repo glob merge_row oid releases resolved release tag compare_tag comparison box
  id="$(jq -r '.id' <<<"$row")" || return 1
  blocked="$(jq -c '(.blocked_by_open // [] | length) > 0' <<<"$row")" || return 1
  if jq -e 'any(.[]; .trigger_kind == "release")' <<<"$boxes" >/dev/null; then
    # The parser bounds a fired release at 72 hours. The same bound dates an
    # unfired trigger from merge, so waiting cannot hide it indefinitely.
    [[ "$merged" != null ]] || { verifying_error verifying-merge-unread "issue=$id"; return 2; }
    release_rows="$(jq -c '.[] | select(.trigger_kind == "release")' <<<"$boxes")" || { verifying_error verifying-invalid "issue=$id"; return 1; }
    while IFS= read -r box; do
      repo="$(jq -r .release_repo <<<"$box")" || { verifying_error verifying-invalid "issue=$id"; return 1; }
      glob="$(jq -r .release_glob <<<"$box")" || { verifying_error verifying-invalid "issue=$id"; return 1; }
      merge_row="$(jq -c --arg repo "$repo" '.[$repo | ascii_downcase]' <<<"$merged_repos")" || { verifying_error verifying-invalid "issue=$id"; return 1; }
      oid=""
      if [[ "$merge_row" != null ]]; then
        oid="$(jq -er '.mergeCommit.oid | select(type == "string") | select(test("^[0-9a-fA-F]{40}$"))' <<<"$merge_row" 2>"$errf")" \
          || { verifying_error verifying-release-unread "$(cat "$errf")" "issue=$id" "repo=$repo"; return 2; }
      fi
      releases="$($gh_cli release list --repo "$repo" --limit "$release_limit" --json tagName,publishedAt,isDraft 2>"$errf")" \
        || { verifying_error verifying-release-unread "$(cat "$errf")" "issue=$id" "repo=$repo"; return 2; }
      releases="$(jq -c --argjson merged "$merged" --argjson limit "$release_limit" '
        if type != "array" or length >= $limit then error("release-list-incomplete") else . end
        | map(if (.isDraft | type) != "boolean" then error("release-fields") else . end
            | select(.isDraft == false) | .publishedAt as $stamp
            | if (.tagName | type) != "string" or (try ($stamp | fromdateiso8601 | todateiso8601 == $stamp) catch false) != true
              then error("release-fields") else . end)
        | map(. + {at: (.publishedAt | fromdateiso8601)} | select(.at > $merged)) | sort_by(.at)[]' <<<"$releases" 2>"$errf")" \
        || { verifying_error verifying-release-unread "$(cat "$errf")" "issue=$id" "repo=$repo"; return 2; }
      resolved=null
      while IFS= read -r release; do
        [[ -n "$release" ]] || continue
        tag="$(jq -r .tagName <<<"$release")" || { verifying_error verifying-invalid "issue=$id"; return 1; }
        # The tracker supplies a tag glob, not a literal tag.
        # shellcheck disable=SC2053
        [[ "$tag" == $glob ]] || continue
        # GitHub can publish a tag built before the item's merge. Compare only
        # within that merge's repository; another repository has no such commit.
        if [[ -n "$oid" ]]; then
          compare_tag="$(jq -rn --arg tag "$tag" '$tag | @uri')" || { verifying_error verifying-invalid "issue=$id"; return 1; }
          comparison="$($gh_cli api "repos/$repo/compare/$oid...$compare_tag" --jq .status 2>"$errf")" \
            || { verifying_error verifying-release-unread "$(cat "$errf")" "issue=$id" "repo=$repo" "tag=$tag"; return 2; }
          case "$comparison" in
            ahead|identical) ;;
            behind|diverged) continue ;;
            *) verifying_error verifying-release-unread "issue=$id" "repo=$repo" "tag=$tag" "status=$comparison"; return 2 ;;
          esac
        fi
        resolved="$(jq -c '.publishedAt | fromdateiso8601' <<<"$release")" || { verifying_error verifying-invalid "issue=$id"; return 1; }
        break
      done <<<"$releases"
      boxes="$(jq -c --argjson box "$box" --argjson fired "$resolved" --argjson merged "$merged" '
        map(if .number == $box.number then .trigger_epoch = $fired
            | .deadline_epoch = (if $fired == null then $merged + 259200 else $fired + (.deadline_hours * 3600) end)
            | if .deadline_epoch == null then . else .deadline = (.deadline_epoch | todateiso8601) end
            else . end)' <<<"$boxes")" || { verifying_error verifying-invalid "issue=$id"; return 1; }
    done <<<"$release_rows"
  fi
  boxes="$(jq -c --argjson now "$now" --argjson blocked "$blocked" '
    map(.status = (if .deadline_epoch <= $now then "overdue"
        elif $blocked then "blocked"
        elif .trigger_kind != "merge" and (.trigger_epoch == null or .trigger_epoch > $now) then "waiting"
        else "due" end))' <<<"$boxes")" || { verifying_error verifying-invalid "issue=$id"; return 1; }
  printf '%s\n' "$boxes"
}

# Both operational readers consume this machine-read line.
verifying_lines() { # ITEM BOXES SAFE_ROW
  jq -r --arg id "$1" --argjson row "$3" '
    ($row.blocked_by_open // [] | if length == 0 then "-" else join(",") end) as $blocked
    | .[] | "verifying \($id) box=\(.number) trigger=\(.trigger | tojson) status=\(.status) deadline=\(.deadline) blocked_by=\($blocked) reading=\(.reading | tojson) where=\(.where | tojson) why=\(.why | tojson)"' <<<"$2"
}
