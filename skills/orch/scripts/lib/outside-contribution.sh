# shellcheck shell=bash
# The outside-contribution pass of oversee-watch: every open pull request in
# each --repo, and every open issue in the first, whose author is outside the
# fleet, reported once, and a pull request again on each new head. Sourced by
# oversee-watch, and like the rest of its lib/ it reads that script's globals
# (REPOS, PW_SEEN, WORK_DIR) and calls its `die`, `ow_message` and lane-row
# helpers.
#
# The fleet is who GitHub itself says belongs to the repository: an app or bot
# account, the lanes app and the review bots among them, and a login GitHub
# associates with the repository as its OWNER, a MEMBER of its organization or
# a COLLABORATOR, which the owner and an overseer acting on a person's login
# are. Every other author is outside. GitHub answers that association on each
# item, so no setting lists the fleet's logins.

# ORCH_EXTERNAL_TRIAGE, read once at start: `on` (the default) runs the pass,
# `off` lists nothing, and any other value is refused rather than guessed.
OUTSIDE_ENABLED=0
outside_contribution_init() {
  case "${ORCH_EXTERNAL_TRIAGE:-on}" in
    on) OUTSIDE_ENABLED=1 ;;
    off) OUTSIDE_ENABLED=0 ;;
    *) die external-triage-invalid "" "setting=ORCH_EXTERNAL_TRIAGE" "value=$ORCH_EXTERNAL_TRIAGE" ;;
  esac
}

# One line per outside item on a page: `<number>\t<pr|issue>\t<login>\t<head>`.
# Pull requests come from the pulls endpoint, the one list that carries each
# head commit; issues from the issues endpoint, which lists pull requests too,
# marked with `pull_request`, so those are dropped there and an issue's head is
# `-`. A deleted account has no user; it is outside, under GitHub's `ghost`
# name. Written for gh's own jq as well as jq 1.7.1, so it uses no builtin
# gojq lacks.
OUTSIDE_AUTHOR_JQ='select((.user.type? // "") != "Bot")
  | select((.author_association // "") as $a
      | ($a == "OWNER" or $a == "MEMBER" or $a == "COLLABORATOR") | not)'
OUTSIDE_PR_JQ=".[] | $OUTSIDE_AUTHOR_JQ"'
  | "\(.number)\tpr\t\(.user.login? // "ghost")\t\(.head.sha? // "")"'
OUTSIDE_ISSUE_JQ=".[] | select(.pull_request | not) | $OUTSIDE_AUTHOR_JQ"'
  | "\(.number)\tissue\t\(.user.login? // "ghost")\t-"'

# One row per contribution reported, in the first repository's baseline:
#   outside-contribution<TAB><repo>#<number><TAB><pr HEAD_SHA|issue>
# A row stands while its item stays open and outside, so no later pass reports
# it again until a pull request's listed head differs from the one its row
# holds. An item that leaves the list takes its row with it, and a reopened
# one is news again. The event lines print before the rows are committed, so a
# failed commit repeats an event and never loses one.
check_outside_contribution() {
  [[ "$OUTSIDE_ENABLED" -eq 1 ]] || return 0
  local errf="$WORK_DIR/outside.err" i repo out rc number kind login head key prior value endpoint
  local state="${PW_SEEN[0]}" events="" keys=() lists
  for i in "${!REPOS[@]}"; do
    repo="${REPOS[$i]}"
    # Issues are read in the first repository alone: the fleet's other
    # repositories are watched for the pull requests their lanes open.
    lists="pulls"
    [[ "$i" -ne 0 ]] || lists="pulls issues"
    for endpoint in $lists; do
      rc=0
      if [[ "$endpoint" == pulls ]]; then
        out="$(gh api --paginate "repos/$repo/pulls?state=open&per_page=100" --jq "$OUTSIDE_PR_JQ" 2>"$errf")" || rc=$?
      else
        out="$(gh api --paginate "repos/$repo/issues?state=open&per_page=100" --jq "$OUTSIDE_ISSUE_JQ" 2>"$errf")" || rc=$?
      fi
      [[ "$rc" -eq 0 ]] || die outside-list-failed "$(cat "$errf")" "repo=$repo" "list=$endpoint" "exit=$rc"
      while IFS=$'\t' read -r number kind login head; do
        [[ -n "$number" ]] || continue
        [[ "$number" =~ ^[0-9]+$ && "$login" =~ ^[A-Za-z0-9._-]+$ \
          && ( ( "$kind" == pr && "$head" =~ ^[0-9a-f]{40}$ ) || ( "$kind" == issue && "$head" == - ) ) ]] \
          || die outside-list-invalid "" "repo=$repo" "list=$endpoint" "line=$number $kind $login $head"
        key="$repo#$number"
        keys+=("$key")
        value="$kind"
        [[ "$kind" == issue ]] || value="pr $head"
        prior="$(lane_row_get outside-contribution "$state" "$key")" \
          || die state-read-failed "" "row=outside-contribution" "item=$key"
        [[ "$prior" != "$value" ]] || continue
        events+="EVENT outside-contribution $key kind=$kind author=$login"
        [[ "$kind" == issue ]] || events+=" head=$head"
        events+=$'\n'
        state="$(lane_row_set outside-contribution "$state" "$key" "$value")"
      done <<<"$out"
    done
  done
  state="$(lane_row_prune outside-contribution "$state" ${keys[@]+"${keys[@]}"})"
  if [[ -n "$events" ]]; then
    printf '%s' "$events"
    PASS_EVENT=1
  fi
  lane_row_commit "$state"
}
