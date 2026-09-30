# shellcheck shell=bash
# The security-alert pass of oversee-watch: every open Dependabot, code
# scanning and secret scanning alert in each --repo, reported once until the
# overseer records its verdict in the fleet state's `alerts_triaged`. Sourced
# by oversee-watch, and like the rest of its lib/ it reads that script's
# globals (REPOS, PW_SEEN, WORK_DIR, WORKFLOW_STATE, WORKFLOW_STATE_ARGS) and
# calls its `die`, `ow_message` and lane-row helpers.
#
# The lines it prints are protocol the overseer reads under
# ../../references/oversee-events.md § Event kinds:
#   EVENT security-alert <repo> kind=<kind> number=<N> [severity=<s>]
#         <package|rule>=<name> [manifest=<path>] [scope=<scope>]
#         [advisory=<GHSA>] [validity=<v>] url=<url> [pr=<N>]
#   EVENT security-alerts-unread reads=<source>:<cause>[,<source>:<cause>...]
# <kind> is the alert API's own path segment, `dependabot`, `code-scanning` or
# `secret-scanning`; a source is `<repo>/<kind>` or `alerts_triaged`.

# ORCH_SECURITY_ALERTS, read once at start: `on` (the default) runs the pass,
# `off` lists nothing, and any other value is refused rather than guessed.
SECURITY_ENABLED=0
security_alerts_init() {
  case "${ORCH_SECURITY_ALERTS:-on}" in
    on) SECURITY_ENABLED=1 ;;
    off) SECURITY_ENABLED=0; return 0 ;;
    *) die security-alerts-invalid "" "setting=ORCH_SECURITY_ALERTS" "value=$ORCH_SECURITY_ALERTS" ;;
  esac
  [[ -x "$WORKFLOW_STATE" ]] \
    || die helper-missing "" "path=$WORKFLOW_STATE" "setting=OVERSEE_WATCH_WORKFLOW_STATE"
}

SECURITY_KINDS="dependabot code-scanning secret-scanning"

# One line per alert on a page, the columns fixed across kinds and split by the
# ASCII unit separator, which unlike a tab keeps an empty column in `read`:
# number, severity, subject key, subject, manifest, scope, advisory, validity,
# url, an absent value empty. Code scanning's severity is the security level
# where its rule has one and the rule's own level otherwise; a secret has no
# severity. Written for gh's own jq as well as jq 1.7.1.
security_alert_jq() { # KIND
  local row
  case "$1" in
    dependabot) row='.number, .security_advisory.severity, "package", .dependency.package.name,
      .dependency.manifest_path, .dependency.scope, .security_advisory.ghsa_id, null, .html_url' ;;
    code-scanning) row='.number, (.rule.security_severity_level // .rule.severity), "rule", .rule.id,
      null, null, null, null, .html_url' ;;
    secret-scanning) row='.number, null, "rule", .secret_type, null, null, null, .validity, .html_url' ;;
  esac
  printf '.[] | [%s] | map(. // "" | tostring) | join("\u001f")' "$row"
}

# The open Dependabot alerts that carry an open Dependabot pull request, one
# `<alert>\t<pr>` line each. GitHub's GraphQL alert record is the one read that
# links an alert to its pull request; the REST alert carries no such field.
SECURITY_PR_QUERY='query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    vulnerabilityAlerts(states: OPEN, first: 100, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes { number dependabotUpdate { pullRequest { number state } } }
    }
  }
}'
SECURITY_PR_JQ='.data.repository.vulnerabilityAlerts.nodes[]
  | select(.dependabotUpdate.pullRequest.state == "OPEN")
  | "\(.number)\t\(.dependabotUpdate.pullRequest.number)"'

# The cause a failed read is reported under: GitHub's HTTP status where gh
# names one, the exit status otherwise.
security_read_cause() { # ERR_FILE EXIT
  local detail
  detail="$(cat -- "$1" 2>/dev/null)" || detail=""
  if [[ "$detail" =~ \(HTTP\ ([0-9]{3})\) ]]; then
    printf 'http-%s' "${BASH_REMATCH[1]}"
  else
    printf 'exit-%s' "$2"
  fi
}

# One read that could not be judged: named on stderr with gh's own words, and
# kept for the pass's one security-alerts-unread line.
SECURITY_UNREAD=""
security_unread() { # SOURCE CAUSE [ERR_FILE]
  SECURITY_UNREAD+="${SECURITY_UNREAD:+,}$1:$2"
  ow_message security-alerts-read-failed "source=$1" "cause=$2" >&2
  [[ -z "${3:-}" ]] || cat -- "$3" >&2
}

# One row per alert reported and not yet recorded, in the first repository's
# baseline:
#   security-alert<TAB><repo>#<kind>/<number><TAB>reported
# and one per open Dependabot pull request an open alert names:
#   bot-fix<TAB><repo>#<pr><TAB><alert>[,<alert>...]
# and, while any read fails:
#   security-alerts-unread<TAB>fleet<TAB><the reads= value>
# An alert whose verdict `alerts_triaged` records has no row and no line; one
# that leaves the open list takes its row with it. A read that fails keeps
# every row of its source, so a failure never reports its alerts again nor
# drops a pull request's mapping. The unread line goes out on every pass a
# read fails, and ends the run only when the set of failed reads changes: a
# standing failure rides each pass's output without holding the heartbeat
# off. The event lines print before the rows are committed, so a failed commit
# repeats an event and never loses one.
check_security_alerts() {
  [[ "$SECURITY_ENABLED" -eq 1 ]] || return 0
  local errf="$WORK_DIR/security.err" state="${PW_SEEN[0]}" events="" new_rows="" rc
  local recorded="" reported repo kind out prs line key number severity subject_key subject
  local manifest scope advisory validity url pr fields row alerts keys=() fix_keys=() fix_rows=""
  SECURITY_UNREAD=""
  reported=$'\n'"$(awk -F'\t' '$1 == "security-alert" && NF == 3 { print $2 }' <<<"$state")"$'\n'

  # The verdicts first: without them nothing is judged, and every row stands.
  # A fleet with no state yet has recorded none.
  rc=0
  "$WORKFLOW_STATE" ${WORKFLOW_STATE_ARGS[@]+"${WORKFLOW_STATE_ARGS[@]}"} exists oversee >/dev/null 2>"$errf" || rc=$?
  case "$rc" in
    0)
      recorded="$("$WORKFLOW_STATE" ${WORKFLOW_STATE_ARGS[@]+"${WORKFLOW_STATE_ARGS[@]}"} get oversee \
        '.alerts_triaged // [] | .[] | "\(.repo)\t\(.kind)\t\(.number)"' 2>"$errf")" || rc=$?
      [[ "$rc" -ne 0 ]] || recorded="$(tr '[:upper:]' '[:lower:]' <<<"$recorded")" || rc=$? ;;
    1) rc=0 ;;
  esac
  if [[ "$rc" -ne 0 ]]; then
    security_unread alerts_triaged "exit-$rc" "$errf"
    security_unread_commit "$state"
    return 0
  fi
  while IFS=$'\t' read -r repo kind number; do
    [[ -n "$repo$kind$number" ]] || continue
    [[ "$repo" =~ ^[a-z0-9._-]+/[a-z0-9._-]+$ && " $SECURITY_KINDS " == *" $kind "* && "$number" =~ ^[0-9]+$ ]] \
      && continue
    security_unread alerts_triaged invalid
    security_unread_commit "$state"
    return 0
  done <<<"$recorded"
  recorded=$'\n'"$(awk -F'\t' 'NF == 3 { print $1 "#" $2 "/" $3 }' <<<"$recorded")"$'\n'

  for repo in "${REPOS[@]}"; do
    for kind in $SECURITY_KINDS; do
      rc=0
      out="$(gh api --paginate "repos/$repo/$kind/alerts?state=open&per_page=100" \
        --jq "$(security_alert_jq "$kind")" 2>"$errf")" || rc=$?
      prs=""
      if [[ "$rc" -eq 0 && "$kind" == dependabot ]]; then
        prs="$(gh api graphql --paginate -f owner="${repo%%/*}" -f name="${repo#*/}" \
          -f query="$SECURITY_PR_QUERY" --jq "$SECURITY_PR_JQ" 2>"$errf")" || rc=$?
      fi
      if [[ "$rc" -eq 0 ]] && ! security_lines_valid "$kind" "$out" "$prs"; then
        rc=invalid
      fi
      if [[ "$rc" != 0 ]]; then
        if [[ "$rc" == invalid ]]; then security_unread "$repo/$kind" invalid
        else security_unread "$repo/$kind" "$(security_read_cause "$errf" "$rc")" "$errf"; fi
        while IFS= read -r key; do
          [[ -z "$key" ]] || keys+=("$key")
        done < <(awk -F'\t' -v p="$repo#$kind/" '$1 == "security-alert" && index($2, p) == 1 { print $2 }' <<<"$state")
        if [[ "$kind" == dependabot ]]; then
          while IFS= read -r key; do
            [[ -z "$key" ]] || fix_keys+=("$key")
          done < <(awk -F'\t' -v p="$repo#" '$1 == "bot-fix" && index($2, p) == 1 { print $2 }' <<<"$state")
        fi
        continue
      fi
      if [[ -n "$prs" ]]; then
        while IFS=$'\t' read -r pr fields; do
          fix_keys+=("$repo#$pr")
          fix_rows+="bot-fix"$'\t'"$repo#$pr"$'\t'"$fields"$'\n'
        done < <(sort -n <<<"$prs" | awk -F'\t' '
          { if ($2 in list) list[$2] = list[$2] "," $1; else { order[++n] = $2; list[$2] = $1 } }
          END { for (i = 1; i <= n; i++) print order[i] "\t" list[order[i]] }')
      fi
      while IFS=$'\x1f' read -r number severity subject_key subject manifest scope advisory validity url; do
        [[ -n "$number" ]] || continue
        key="$repo#$kind/$number"
        [[ "$recorded" != *$'\n'"$key"$'\n'* ]] || continue
        keys+=("$key")
        [[ "$reported" != *$'\n'"$key"$'\n'* ]] || continue
        line="EVENT security-alert $repo kind=$kind number=$number"
        [[ -z "$severity" ]] || line+=" severity=$severity"
        line+=" $subject_key=$subject"
        for fields in "manifest=$manifest" "scope=$scope" "advisory=$advisory" "validity=$validity"; do
          [[ -z "${fields#*=}" ]] || line+=" $fields"
        done
        line+=" url=$url"
        pr="$(awk -F'\t' -v n="$number" '$1 == n { print $2; exit }' <<<"$prs")"
        [[ -z "$pr" ]] || line+=" pr=$pr"
        events+="$line"$'\n'
        new_rows+="security-alert"$'\t'"$key"$'\t'"reported"$'\n'
      done <<<"$out"
    done
  done

  state="$(lane_row_prune security-alert "$state" ${keys[@]+"${keys[@]}"})"
  state="$(lane_row_prune bot-fix "$state" ${fix_keys[@]+"${fix_keys[@]}"})"
  while IFS=$'\t' read -r row key alerts; do
    [[ -n "$key" ]] || continue
    state="$(lane_row_set "$row" "$state" "$key" "$alerts")"
  done <<<"$fix_rows"
  [[ -z "$new_rows" ]] || state="$(printf '%s\n%s' "$state" "${new_rows%$'\n'}" | awk 'NF')"
  if [[ -n "$events" ]]; then
    printf '%s' "$events"
    PASS_EVENT=1
  fi
  security_unread_commit "$state"
}

# Every column a line may carry is one word: a line whose number is not a
# whole number, that names no subject or URL, that lacks a severity where its
# kind has one, or that holds a value with white space in it, is not a list
# this pass can report from. The same for the pull request lines.
security_lines_valid() { # KIND LIST PRS
  local number severity subject_key subject manifest scope advisory validity url value alert pr
  while IFS=$'\x1f' read -r number severity subject_key subject manifest scope advisory validity url; do
    [[ -n "$number$severity$subject_key$subject$manifest$scope$advisory$validity$url" ]] || continue
    [[ "$number" =~ ^[0-9]+$ && -n "$subject" && -n "$url" ]] || return 1
    [[ "$1" == secret-scanning || -n "$severity" ]] || return 1
    for value in "$severity" "$subject_key" "$subject" "$manifest" "$scope" "$advisory" "$validity" "$url"; do
      [[ -z "$value" || "$value" =~ ^[^[:space:]]+$ ]] || return 1
    done
  done <<<"$2"
  while IFS=$'\t' read -r alert pr; do
    [[ -n "$alert$pr" ]] || continue
    [[ "$alert" =~ ^[0-9]+$ && "$pr" =~ ^[0-9]+$ ]] || return 1
  done <<<"$3"
}

# The pass's one security-alerts-unread line, and the row that says whether
# its set of failed reads is news.
security_unread_commit() { # STATE
  local state="$1" prior
  prior="$(lane_row_get security-alerts-unread "$state" fleet)" \
    || die state-read-failed "" "row=security-alerts-unread"
  if [[ -n "$SECURITY_UNREAD" ]]; then
    echo "EVENT security-alerts-unread reads=$SECURITY_UNREAD"
    [[ "$prior" == "$SECURITY_UNREAD" ]] || PASS_EVENT=1
    state="$(lane_row_set security-alerts-unread "$state" fleet "$SECURITY_UNREAD")"
  else
    state="$(lane_row_clear security-alerts-unread "$state" fleet)"
  fi
  lane_row_commit "$state"
}

# The alert list a heartbeat names a Dependabot pull request with, from the
# baseline the last long pass committed: its bot-fix row; `unread` where it
# has none and that pass could not read the repository's Dependabot alerts or
# the verdicts, so a pull request it never saw is not called stale; and
# `none` where no open alert names it, an alert dismissed or fixed elsewhere.
security_bot_fix_alerts() { # BASELINE REPO PR
  local alerts unread
  alerts="$(lane_row_get bot-fix "$1" "$2#$3")" || return 1
  if [[ -z "$alerts" ]]; then
    unread="$(lane_row_get security-alerts-unread "$1" fleet)" || return 1
    alerts=none
    [[ ",$unread" != *",$2/dependabot:"* && ",$unread" != *",alerts_triaged:"* ]] || alerts=unread
  fi
  printf '%s' "$alerts"
}
