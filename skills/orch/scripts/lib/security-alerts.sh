# shellcheck shell=bash
# The security-alert pass of oversee-watch: every open Dependabot, code
# scanning and secret scanning alert in each --repo, reported once until the
# overseer records its verdict in the fleet state's `alerts_triaged`. Sourced
# by oversee-watch, and like the rest of its lib/ it reads that script's
# globals (REPOS, PW_SEEN, WORK_DIR, WORKFLOW_STATE, WORKFLOW_STATE_ARGS) and
# calls its `die`, `ow_message` and lane-row helpers.
#
# The lines it prints are protocol the overseer reads under
# ../../references/security-alerts.md:
#   EVENT security-alert <repo> kind=<kind> number=<N> [severity=<s>]
#         <package|rule>=<name> [manifest=<path>] [scope=<scope>]
#         [advisory=<GHSA>] [validity=<v>] url=<url> [pr=<N>]
#   EVENT security-alerts-unread reads=<source>:<cause>[,<source>:<cause>...]
# <kind> is the alert API's own path segment, `dependabot`, `code-scanning` or
# `secret-scanning`; <path> is the manifest's repository path with each `%`
# and white space character percent-encoded (`%25`, `%20`), so a directory
# name with a space stays one word; a source is `<repo>/<kind>`,
# `<repo>/dependabot-prs` (the alert-to-pull-request link) or
# `alerts_triaged`; a cause is one of security_read_cause's or `invalid`.

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
# url, an absent value empty. The manifest is a repository path, which may
# hold a space, so it is percent-encoded here as the header states; GitHub
# writes every other column without white space. Code scanning's severity is
# the security level where its rule has one and the rule's own level
# otherwise; a secret has no severity. Written for gh's own jq as well as jq
# 1.7.1.
security_alert_jq() { # KIND
  local row
  case "$1" in
    dependabot) row='.number, .security_advisory.severity, "package", .dependency.package.name,
      (.dependency.manifest_path // "" | gsub("(?<c>[%\\s])"; .c | @uri)), .dependency.scope, .security_advisory.ghsa_id, null, .html_url' ;;
    code-scanning) row='.number, (.rule.security_severity_level // .rule.severity), "rule", .rule.id,
      null, null, null, null, .html_url' ;;
    secret-scanning) row='.number, null, "rule", .secret_type, null, null, null, .validity, .html_url' ;;
  esac
  printf '.[] | [%s] | map(. // "" | tostring) | join("\u001f")' "$row"
}

# The Dependabot alerts in any state that carry an open Dependabot pull
# request, one `<alert>\t<alert state>\t<pr>` line each. GitHub's GraphQL alert
# record is the one read that links an alert to its pull request; the REST
# alert carries no such field. Every state is read, not only OPEN, so a pull
# request whose alerts were all dismissed or fixed elsewhere is still known as
# a security update: a pull request no alert links, a version update or one
# opened after this read, is never named stale.
SECURITY_PR_QUERY='query($owner: String!, $name: String!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    vulnerabilityAlerts(first: 100, after: $endCursor) {
      pageInfo { hasNextPage endCursor }
      nodes { number state dependabotUpdate { pullRequest { number state } } }
    }
  }
}'
SECURITY_PR_JQ='.data.repository.vulnerabilityAlerts.nodes[]
  | select(.dependabotUpdate.pullRequest.state == "OPEN")
  | "\(.number)\t\(.state)\t\(.dependabotUpdate.pullRequest.number)"'

# The cause a failed read is reported under, the first row whose ERE matches
# what gh printed: `permission`, the credential the watch reads with lacking
# the alert permission, or `feature-off`, the alert feature turned off on the
# repository, which GitHub answers with a 403 or 404 of its own. The words
# each row was written from:
#   Resource not accessible by integration (HTTP 403)          GitHub App
#   Resource not accessible by personal access token (HTTP 403) fine-grained PAT
#   Dependabot alerts are disabled for this repository. (HTTP 403)
#   Secret scanning is disabled on this repository. (HTTP 404)
#   GitHub Code Security or GitHub Advanced Security is not enabled (HTTP 403)
#   Advanced Security must be enabled for this repository to use code scanning. (HTTP 403)
#   no analysis found (HTTP 404)                                code scanning never ran
SECURITY_CAUSES='permission	Resource not accessible by (integration|personal access token)
feature-off	(alerts are|scanning is) disabled
feature-off	Security (is not|must be) enabled
feature-off	no analysis found'

# The cause for a read no row matches: GitHub's HTTP status where gh names
# one, `http-<status>`, the exit status otherwise, `exit-<N>`.
security_read_cause() { # ERR_FILE EXIT
  local detail cause pattern
  detail="$(cat -- "$1" 2>/dev/null)" || detail=""
  while IFS=$'\t' read -r cause pattern; do
    if [[ "$detail" =~ $pattern ]]; then
      printf '%s' "$cause"
      return 0
    fi
  done <<<"$SECURITY_CAUSES"
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
# and one per open Dependabot pull request any alert links, naming its open
# alerts, or `none` once every alert that links it has left the open list:
#   bot-fix<TAB><repo>#<pr><TAB><alert>[,<alert>...]|none
# A pull request no longer open, or that no alert links, has no row.
# And, while any read fails:
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
  local manifest scope advisory validity url pr fields row alerts source query keys=() fix_keys=() fix_rows=""
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
      rc=0 source="$repo/$kind" query="state=open&per_page=100"
      # A secret's plaintext value is in the list unless GitHub is told to
      # leave it out, and the check never reads it.
      [[ "$kind" != secret-scanning ]] || query+="&hide_secret=true"
      out="$(gh api --paginate "repos/$repo/$kind/alerts?$query" \
        --jq "$(security_alert_jq "$kind")" 2>"$errf")" || rc=$?
      [[ "$rc" != 0 ]] || security_lines_valid "$kind" "$out" "" || rc=invalid
      prs=""
      if [[ "$rc" == 0 && "$kind" == dependabot ]]; then
        source="$repo/dependabot-prs"
        prs="$(gh api graphql --paginate -f owner="${repo%%/*}" -f name="${repo#*/}" \
          -f query="$SECURITY_PR_QUERY" --jq "$SECURITY_PR_JQ" 2>"$errf")" || rc=$?
        [[ "$rc" != 0 ]] || security_lines_valid "$kind" "" "$prs" || rc=invalid
      fi
      if [[ "$rc" != 0 ]]; then
        if [[ "$rc" == invalid ]]; then security_unread "$source" invalid
        else security_unread "$source" "$(security_read_cause "$errf" "$rc")" "$errf"; fi
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
          !($3 in list) { order[++n] = $3; list[$3] = "" }
          $2 == "OPEN" { list[$3] = list[$3] (list[$3] == "" ? "" : ",") $1 }
          END { for (i = 1; i <= n; i++) print order[i] "\t" (list[order[i]] == "" ? "none" : list[order[i]]) }')
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
        pr="$(awk -F'\t' -v n="$number" '$1 == n { print $3; exit }' <<<"$prs")"
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

# Every column a line may carry is one word, the manifest once
# security_alert_jq has encoded it: a line whose number is not a whole number,
# that names no subject or URL, that lacks a severity where its kind has one,
# or that holds a value with white space in it, is not a list this pass can
# report from. The same for the pull request lines.
security_lines_valid() { # KIND LIST PRS
  local number severity subject_key subject manifest scope advisory validity url value alert alert_state pr
  while IFS=$'\x1f' read -r number severity subject_key subject manifest scope advisory validity url; do
    [[ -n "$number$severity$subject_key$subject$manifest$scope$advisory$validity$url" ]] || continue
    [[ "$number" =~ ^[0-9]+$ && -n "$subject" && -n "$url" ]] || return 1
    [[ "$1" == secret-scanning || -n "$severity" ]] || return 1
    for value in "$severity" "$subject_key" "$subject" "$manifest" "$scope" "$advisory" "$validity" "$url"; do
      [[ -z "$value" || "$value" =~ ^[^[:space:]]+$ ]] || return 1
    done
  done <<<"$2"
  while IFS=$'\t' read -r alert alert_state pr; do
    [[ -n "$alert$alert_state$pr" ]] || continue
    [[ "$alert" =~ ^[0-9]+$ && "$alert_state" =~ ^[A-Z_]+$ && "$pr" =~ ^[0-9]+$ ]] || return 1
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

# The heartbeat's open pull request list, one `<number>\t<head>\t<title>` line
# each, with `\tapp/dependabot` after a Dependabot pull request's for
# security_mark_open to read.
SECURITY_OPEN_JQ='.[] | "\(.number)\t\(.headRefName)\t\(.title)"
  + (if .author.login == "app/dependabot" then "\t\(.author.login)" else "" end)'

# One repository's open pull request lines as the heartbeat prints them. With
# the check on, a Dependabot pull request the last long pass's bot-fix row
# names reads `bot-fix pr=<N> alert=<alerts|none>`; any other, a version
# update or one opened after that pass, keeps its plain line, as every
# Dependabot pull request does with the check off. Fails where the baseline
# cannot be read.
security_mark_open() { # BASELINE REPO OPEN
  local line number alerts marked=""
  while IFS= read -r line; do
    if [[ "$line" == *$'\t'app/dependabot ]]; then
      line="${line%$'\t'app/dependabot}"
      if [[ "$SECURITY_ENABLED" -eq 1 ]]; then
        number="${line%%$'\t'*}"
        alerts="$(lane_row_get bot-fix "$1" "$2#$number")" || return 1
        [[ -z "$alerts" ]] || line="bot-fix pr=$number alert=$alerts"
      fi
    fi
    marked+="$line"$'\n'
  done <<<"$3"
  printf '%s' "${marked%$'\n'}"
}
