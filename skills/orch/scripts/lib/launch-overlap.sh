# shellcheck shell=bash
#
# Owner: the file-overlap hold (../../workflows/oversee.md § 2). open-terminal
# refuses a fleet launch on it and oversee-report names the held queue items
# from it, so the report and the launch cannot disagree. Callers source
# lib/lane-state.sh first: a lane record with no tracker takes its item key's.
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

# overlap_prs REPO — OVERLAP_PRS: each open pull request's number, lowercased
# head branch and changed files.
overlap_prs() {
  local list number head files prs="[]"
  [[ -z "$OVERLAP_PRS" ]] || return 0
  [[ -n "$1" ]] || { OVERLAP_UNREAD=repo; return 1; }
  list="$(gh pr list --repo "$1" --state open --limit "$OVERLAP_PR_PAGE" --json number,headRefName \
    | jq -r --argjson page "$OVERLAP_PR_PAGE" 'if length < $page then .[] | "\(.number)\t\(.headRefName)" else error("truncated") end')" \
    || { OVERLAP_UNREAD="pr-list:$1"; return 1; }
  while IFS=$'\t' read -r number head; do
    [[ -n "$number" ]] || continue
    files="$(gh pr diff "$number" --repo "$1" --name-only)" || { OVERLAP_UNREAD="pr:$number"; return 1; }
    prs="$(jq -c --argjson n "$number" --arg head "$head" --arg files "$files" \
      '. + [{number: $n, head: ($head | ascii_downcase), files: [$files | split("\n")[] | select(. != "")]}]' <<<"$prs")" \
      || { OVERLAP_UNREAD="pr:$number"; return 1; }
  done <<<"$list"
  OVERLAP_PRS="$prs"
}

# overlap_touched DESCRIPTION DIR REPO — OVERLAP_SET: the touched set, as a
# JSON array. Its Location paths, plus every file tracked in DIR's checkout
# that names a path a body line deletes or renames, on the base and on each
# open pull request's head. changelog.d/ paths never count.
overlap_touched() {
  local paths moved path rev base out rc
  paths="$(jq -Rsc --arg loc "$LOCATION_LINE_ERE" '
    def ticks: [scan("`([^`[:space:]]+)`")[0]];
    gsub("\r\n"; "\n") | split("\n")
    | {location: [.[] | select(test($loc)) | ticks[]],
       moved: [.[] | select(test("\\b(delet|renam)(e|es|ed|ing)\\b"; "i")) | ticks[]]}' <<<"$1")" \
    || { OVERLAP_UNREAD=body; return 1; }
  moved="$(jq -r '.moved[]' <<<"$paths")" || { OVERLAP_UNREAD=body; return 1; }
  if [[ -n "$moved" ]]; then
    base="$("$OVERLAP_SCRIPTS/resolve-base-branch" "$2")" || { OVERLAP_UNREAD=base; return 1; }
    overlap_prs "$3" || return 1
    for rev in "origin/$base" $(jq -r '.[].number' <<<"$OVERLAP_PRS"); do
      if [[ "$rev" != origin/* ]]; then
        GIT_TERMINAL_PROMPT=0 git -C "$2" fetch -q origin "pull/$rev/head" || { OVERLAP_UNREAD="pull/$rev/head"; return 1; }
        rev=FETCH_HEAD
      fi
      while IFS= read -r path; do
        rc=0
        out="$(git -C "$2" grep -l -F -e "$path" "$rev" --)" || rc=$?
        [[ "$rc" -le 1 ]] || { OVERLAP_UNREAD="grep:$rev"; return 1; }
        paths="$(jq -c --arg rev "$rev:" --arg out "$out" \
          '.location += [$out | split("\n")[] | select(. != "") | ltrimstr($rev)]' <<<"$paths")" \
          || { OVERLAP_UNREAD="grep:$rev"; return 1; }
      done <<<"$moved"
    done
  fi
  OVERLAP_SET="$(jq -c '[.location[] | select(startswith("changelog.d/") | not)] | unique' <<<"$paths")" \
    || { OVERLAP_UNREAD=body; return 1; }
}

# overlap_judge KEY TRACKER REPO DIR LINEAR_CLI LANES IN_SCOPE — judges item
# KEY against each other held lane in LANES (the fleet state's lanes[]) and
# each open pull request but KEY's own branch. A lane's touched set is the one
# its record keeps, else its item's, read now. IN_SCOPE lists the files the
# brief names in scope. Returns 0 with OVERLAP_TOUCHED, 1 with OVERLAP_FILE and
# OVERLAP_HOLDER (a lane item or #N), 2 with OVERLAP_UNREAD.
overlap_judge() {
  local key="$1" tracker="$2" repo="$3" dir="$4" linear="$5" lanes="$6" scope="$7"
  local body holders records item lane_tracker lane_repo files row
  OVERLAP_TOUCHED=null OVERLAP_FILE="" OVERLAP_HOLDER="" OVERLAP_UNREAD=""
  body="$(overlap_body "$tracker" "$key" "$repo" "$linear")" || { OVERLAP_UNREAD="item:$key"; return 2; }
  overlap_touched "$body" "$dir" "$repo" || return 2
  OVERLAP_TOUCHED="$OVERLAP_SET"
  [[ "$OVERLAP_TOUCHED" != "[]" ]] || return 0
  overlap_prs "$repo" || return 2
  holders="$(jq -c --arg head "$(printf '%s' "$key" | tr '[:upper:]' '[:lower:]')" \
    '[.[] | select(.head != $head) | {holder: "#\(.number)", files}]' <<<"$OVERLAP_PRS")" \
    || { OVERLAP_UNREAD=pr-list; return 2; }
  records="$(jq -r --arg key "$key" '.[] | select(.item != $key and (.status | IN("running", "preparing", "parked")))
    | [.item, (.tracker // ""), (.repo // ""), (.touched // null | tojson)] | join("\u001f")' <<<"$lanes")" \
    || { OVERLAP_UNREAD=state; return 2; }
  # A unit separator, not a tab: IFS whitespace would fold an empty field.
  while IFS=$'\x1f' read -r item lane_tracker lane_repo files; do
    [[ -n "$item" ]] || continue
    if [[ "$files" == null ]]; then
      [[ -n "$lane_tracker" ]] || lane_tracker="$(lane_key_tracker "$item")"
      body="$(overlap_body "$lane_tracker" "$item" "${lane_repo:-$repo}" "$linear")" \
        || { OVERLAP_UNREAD="lane:$item"; return 2; }
      overlap_touched "$body" "$dir" "$repo" || return 2
      files="$OVERLAP_SET"
    fi
    holders="$(jq -c --arg item "$item" --argjson files "$files" '. + [{holder: $item, files: $files}]' <<<"$holders")" \
      || { OVERLAP_UNREAD="lane:$item"; return 2; }
  done <<<"$records"
  row="$(jq -rn --argjson touched "$OVERLAP_TOUCHED" --argjson holders "$holders" --argjson scope "$scope" '
    def meets($a; $b): $a == $b or (($a | endswith("/")) and ($b | startswith($a)))
      or (($b | endswith("/")) and ($a | startswith($b)));
    first($holders[] as $h | $touched[] as $a | ($h.files[] | select(startswith("changelog.d/") | not)) as $b
      | select(meets($a; $b)) | ([$a, $b] | max_by(length)) as $f
      | select(any($scope[]; . == $f or (endswith("/") and ($f | startswith(.)))) | not)
      | "\($h.holder)\t\($f)") // empty')" || { OVERLAP_UNREAD=compare; return 2; }
  [[ -n "$row" ]] || return 0
  IFS=$'\t' read -r OVERLAP_HOLDER OVERLAP_FILE <<<"$row"
  return 1
}
