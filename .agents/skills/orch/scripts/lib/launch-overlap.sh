# shellcheck shell=bash
#
# Owner: the file-overlap hold (../../workflows/oversee.md § 2). open-terminal
# refuses a fleet launch on overlap_judge and oversee-report labels its Next
# rows from it; which queue keys the report judges is its --help Next row's.
# Every JSON value reaches jq on stdin, never argv: a pull request's files or
# a grep's matches can pass the kernel's per-argument limit. Callers source
# lib/lane-state.sh first, whose lane_key_tracker names a lane record's
# tracker where it records none and whose LANE_MERGED_JQ answers which pull
# request is an item's own, and lib/lane-claims.sh, whose LANE_RUNNING_JQ
# answers which lane records are in flight.
#
# Sourced, never run.

OVERLAP_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# A Location header line; item-tier refuses a body with none.
LOCATION_LINE_ERE='^[[:space:]]*([-*+][[:space:]]+)?[*_]*Location[*_]*[[:space:]]*:'
# The open pull requests one list reads; a list that fills it may hide a
# holder past it, and is unread.
OVERLAP_PR_PAGE=500

# overlap_judge's results. OVERLAP_PRS is read once per process.
OVERLAP_TOUCHED=null
OVERLAP_FILE=""
OVERLAP_HOLDER=""
OVERLAP_UNREAD=""
OVERLAP_PRS=""
OVERLAP_SET=""

# overlap_body TRACKER KEY REPO LINEAR_CLI — prints the item's description.
overlap_body() {
  case "$1" in
    linear) "$4" issues get "$2" --format=safe | jq -er '.description // "" | strings' ;;
    github)
      [[ "$2" =~ ^issue-([0-9]+)$ && -n "$3" ]] || return 1
      gh issue view "${BASH_REMATCH[1]}" --repo "$3" --json body | jq -er '.body // "" | strings' ;;
    *) return 1 ;;
  esac
}

# overlap_prs REPO — OVERLAP_PRS: each open same-repository pull request's
# list row, with its changed files as `files`, a rename's previous path
# included. A fork's pull request is someone else's work, never a holder. The
# files come from the files endpoint, which serves up to 3000 files, each row
# with its patch, so gh keeps only the names; a list shorter than changedFiles
# is unread.
overlap_prs() {
  local list number rows
  [[ -z "$OVERLAP_PRS" ]] || return 0
  [[ -n "$1" ]] || { OVERLAP_UNREAD=repo; return 1; }
  list="$(gh pr list --repo "$1" --state open --limit "$OVERLAP_PR_PAGE" \
      --json number,headRefName,headRefOid,headRepositoryOwner,isCrossRepository,changedFiles,title,body \
    | jq -c --argjson page "$OVERLAP_PR_PAGE" \
      'if length < $page then [.[] | select(.isCrossRepository | not)] else error("truncated") end')" \
    || { OVERLAP_UNREAD="pr-list:$1"; return 1; }
  for number in $(jq -r '.[].number' <<<"$list"); do
    rows="$(gh api "repos/$1/pulls/$number/files?per_page=100" --paginate \
        --jq '.[] | [.filename, .previous_filename] | @json')" \
      || { OVERLAP_UNREAD="pr:$number"; return 1; }
    list="$(jq -cn --argjson n "$number" '
      input as $list | [inputs] as $rows
      | if all($rows[]; (.[0] | type) == "string") then . else error("filename") end
      | $list | map(if .number != $n then .
        elif ($rows | length) == .changedFiles then . + {files: [$rows[] | .[0], (.[1] // empty)]}
        else error("partial") end)' <<<"$list"$'\n'"$rows")" \
      || { OVERLAP_UNREAD="pr:$number"; return 1; }
  done
  OVERLAP_PRS="$list"
}

# overlap_touched DESCRIPTION DIR REPO — OVERLAP_SET: the touched set, as a
# JSON array. Its Location paths, plus every file tracked in DIR's checkout
# that names a path a body line deletes or renames, on the base and on each
# open pull request's head. A path is a backticked token, less a `:N` or
# `:N-M` line suffix; a deleted or renamed token counts only where the base
# tracks it as a file, so a symbol beside it or a directory a move lands in
# adds nothing. A Location line
# naming no path is unread. changelog.d/ paths never count.
overlap_touched() {
  local paths moved="" found="" token path rev base out rc
  paths="$(jq -Rsc --arg loc "$LOCATION_LINE_ERE" '
    def ticks: [scan("`([^`[:space:]]+)`")[0] | sub(":[0-9]+(-[0-9]+)?$"; "")];
    gsub("\r\n"; "\n") | split("\n")
    | {located: any(.[]; test($loc)),
       location: [.[] | select(test($loc)) | ticks[]],
       moved: [.[] | select(test("\\b(delet|renam)(e|es|ed|ing)\\b"; "i")) | ticks[]] | unique}' <<<"$1")" \
    || { OVERLAP_UNREAD=body; return 1; }
  jq -e '.located and .location == [] | not' <<<"$paths" >/dev/null || { OVERLAP_UNREAD=location; return 1; }
  if jq -e '.moved != []' <<<"$paths" >/dev/null; then
    base="$("$OVERLAP_SCRIPTS/resolve-base-branch" "$2")" || { OVERLAP_UNREAD=base; return 1; }
    git -C "$2" cat-file -e "origin/$base^{commit}" 2>/dev/null || { OVERLAP_UNREAD=base; return 1; }
    while IFS= read -r token; do
      [[ "$(git -C "$2" cat-file -t "origin/$base:$token" 2>/dev/null)" == blob ]] || continue
      moved+="$token"$'\n'
    done < <(jq -r '.moved[]' <<<"$paths")
  fi
  if [[ -n "$moved" ]]; then
    overlap_prs "$3" || return 1
    for rev in "origin/$base" $(jq -r '.[] | "\(.number):\(.headRefOid)"' <<<"$OVERLAP_PRS"); do
      # A pull request head is read by the oid the list named, never through
      # FETCH_HEAD, which any concurrent fetch in this checkout rewrites; a
      # head that moved since the list is unread.
      if [[ "$rev" != origin/* ]]; then
        if ! git -C "$2" cat-file -e "${rev#*:}^{commit}" 2>/dev/null; then
          GIT_TERMINAL_PROMPT=0 git -C "$2" fetch -q --no-write-fetch-head origin "pull/${rev%%:*}/head" \
            && git -C "$2" cat-file -e "${rev#*:}^{commit}" 2>/dev/null \
            || { OVERLAP_UNREAD="pull/${rev%%:*}/head"; return 1; }
        fi
        rev="${rev#*:}"
      fi
      while IFS= read -r path; do
        [[ -n "$path" ]] || continue
        rc=0
        out="$(git -C "$2" grep -l -F -e "$path" "$rev" --)" || rc=$?
        [[ "$rc" -le 1 ]] || { OVERLAP_UNREAD="grep:$rev"; return 1; }
        found+="$(jq -Rc --arg rev "$rev:" 'select(. != "") | ltrimstr($rev)' <<<"$out")"$'\n' \
          || { OVERLAP_UNREAD="grep:$rev"; return 1; }
      done <<<"$moved"
    done
  fi
  OVERLAP_SET="$(jq -sc '[.[0].location[], .[1:][] | select(startswith("changelog.d/") | not)] | unique' <<<"$paths"$'\n'"$found")" \
    || { OVERLAP_UNREAD=body; return 1; }
}

# overlap_judge KEY TRACKER REPO DIR LINEAR_CLI LANES IN_SCOPE NULL_REPO —
# judges item KEY of repository REPO, checked out at DIR, against each other
# in-flight lane of REPO in LANES (the fleet state's lanes[]) and each open
# pull request but KEY's own. A lane record's repo names its repository;
# one with none is NULL_REPO's, the overseer's own, which is empty for a
# connected launch, since a connected lane records its repository. Touched
# paths are relative to each lane's own repository, so a lane of another one
# holds nothing here. A lane's touched set is the one its record keeps, else
# its item's, read now. IN_SCOPE lists the files the brief names in scope.
# Returns 0 with OVERLAP_TOUCHED, 1 with OVERLAP_FILE and OVERLAP_HOLDER (a
# lane item or #N), 2 with OVERLAP_UNREAD. A read a held lane's item needs
# names that lane: lane:ITEM for its body, lane:ITEM:READ for its touched set.
overlap_judge() {
  local key="$1" tracker="$2" repo="$3" dir="$4" linear="$5" lanes="$6" scope="$7" null_repo="$8"
  local body holders records item lane_tracker files row
  OVERLAP_TOUCHED=null OVERLAP_FILE="" OVERLAP_HOLDER="" OVERLAP_UNREAD=""
  body="$(overlap_body "$tracker" "$key" "$repo" "$linear")" || { OVERLAP_UNREAD="item:$key"; return 2; }
  overlap_touched "$body" "$dir" "$repo" || return 2
  OVERLAP_TOUCHED="$OVERLAP_SET"
  [[ "$OVERLAP_TOUCHED" != "[]" ]] || return 0
  overlap_prs "$repo" || return 2
  holders="$(jq -c --arg key "$key" --arg owner "${repo%%/*}" "$LANE_MERGED_JQ"'
    .[] | select([lane_own($key; $owner; null)] == []) | {holder: "#\(.number)", files}' <<<"$OVERLAP_PRS")" \
    || { OVERLAP_UNREAD=pr-list; return 2; }
  records="$(jq -r --arg key "$key" --arg repo "$repo" --arg null_repo "$null_repo" "$LANE_RUNNING_JQ"'
    .[] | select(in_flight and .item != $key and ((.repo // $null_repo) | ascii_downcase) == ($repo | ascii_downcase))
    | [.item, (.tracker // ""), (.touched // null | tojson)] | join("\u001f")' <<<"$lanes")" \
    || { OVERLAP_UNREAD=state; return 2; }
  # A unit separator, not a tab: IFS whitespace would fold an empty field.
  while IFS=$'\x1f' read -r item lane_tracker files; do
    [[ -n "$item" ]] || continue
    if [[ "$files" == null ]]; then
      [[ -n "$lane_tracker" ]] || lane_tracker="$(lane_key_tracker "$item")"
      if ! body="$(overlap_body "$lane_tracker" "$item" "$repo" "$linear")" || ! overlap_touched "$body" "$dir" "$repo"; then
        OVERLAP_UNREAD="lane:$item${OVERLAP_UNREAD:+:$OVERLAP_UNREAD}"
        return 2
      fi
      files="$OVERLAP_SET"
    fi
    holders+=$'\n'"$(jq -c --arg item "$item" '{holder: $item, files: .}' <<<"$files")" \
      || { OVERLAP_UNREAD="lane:$item"; return 2; }
  done <<<"$records"
  row="$(jq -rn '
    def meets($a; $b): $a == $b or (($a | endswith("/")) and ($b | startswith($a)))
      or (($b | endswith("/")) and ($a | startswith($b)));
    input as $touched | input as $scope | [inputs] as $holders
    | first($holders[] as $h | $touched[] as $a | ($h.files[] | select(startswith("changelog.d/") | not)) as $b
      | select(meets($a; $b)) | ([$a, $b] | max_by(length)) as $f
      | select(any($scope[]; . as $s | $s == $f or (($s | endswith("/")) and ($f | startswith($s)))) | not)
      | "\($h.holder)\t\($f)") // empty' <<<"$OVERLAP_TOUCHED"$'\n'"$scope"$'\n'"$holders")" || { OVERLAP_UNREAD=compare; return 2; }
  [[ -n "$row" ]] || return 0
  IFS=$'\t' read -r OVERLAP_HOLDER OVERLAP_FILE <<<"$row"
  return 1
}
