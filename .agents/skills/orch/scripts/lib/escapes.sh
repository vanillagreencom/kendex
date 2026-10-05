# shellcheck shell=bash
# The escape count oversee-report's Escapes line prints, so the owner can see
# whether one review cycle before the pull request lets more defects through.
#
# An escape is a pull request merged to the base branch on origin, the one
# scripts/resolve-base-branch names, that within ESCAPE_REACH seconds of its
# merge, the bound included, is named by its number in:
#   - the subject of a revert commit on that branch, a subject starting
#     `Revert` or `revert`, other than the revert's own merge; or
#   - a `Regressed-by` line in the description of a Linear issue labelled
#     bug, in any case, created at or after the merge and neither archived
#     nor trashed, read live through the linear skill. The line starts the description or follows a
#     newline, its key plain (`Regressed-by: #N`) or bold as the issue
#     template writes it (`**Regressed-by**: #N`), and may name several
#     numbers, comma-separated. A number anywhere else in the issue, its
#     title or a Source or Reached by line citing where a finding came from,
#     is not a finding. Where LINEAR_TEAM is set, only an issue in that team
#     counts: the API key reaches every team, and a bare `#N` in another
#     team's bug names another repository's pull request.
# A number names the pull request bare (`#N`) or qualified with this
# repository's own owner/name (`owner/name#N`), the one lib/gh-repo.sh
# resolves; a number qualified with any other repository names that one's.
# A merged pull request is a first-parent commit on the base branch whose
# subject ends `(#N)`, GitHub's squash merge, or starts `Merge pull request
# #N `, its merge commit; a commit the merge brought in on its second parent
# is neither a merge nor a revert of this branch. Each escape counts once, in
# the week of its first finding. Weeks are ISO weeks, Monday 00:00 UTC to
# the next.
#
# Nothing here is stored: every read derives the count from git and Linear
# again.

ESCAPES_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || return 1
# shellcheck source=gh-repo.sh
source "$ESCAPES_LIB_DIR/gh-repo.sh" || return 1

# Weeks the count covers, the current one included; it reaches further back
# to hold ESCAPE_CAP_WEEK.
ESCAPE_WINDOW_WEEKS=6
# How long after its merge a finding still names an escape: 14 days.
ESCAPE_REACH=1209600
# The Monday of the week REVIEW_MAX_CYCLES fell from 4 to 1, the week an
# Escapes line compares against. The same week the setting fell to 1 in every
# consumer repository's own settings, so it is each install's cap week too.
ESCAPE_CAP_WEEK=2026-09-28
# How long the fetch of the base branch, and each Linear read, may run
# before the count reads unread, where `timeout` or `gtimeout` exists.
ESCAPE_FETCH_SECONDS=60
ESCAPE_LINEAR_SECONDS=120

# escapes_bounded BOUND SECONDS COMMAND... — COMMAND under a SECONDS bound
# that BOUND, `timeout` or `gtimeout`, holds, answering 124 where it cuts it
# off. A stalled connection would otherwise hold the whole report. An empty
# BOUND, stock macOS with no coreutils, runs COMMAND unbounded.
escapes_bounded() {
  local bound="$1" seconds="$2"
  shift 2
  if [[ -n "$bound" ]]; then
    "$bound" "$seconds" "$@"
  else
    "$@"
  fi
}

# escapes_read ROOT TRACKER NOW SCRATCH — sets ESCAPE_WEEKS to one
# `YYYY-MM-DD<TAB>COUNT` line per week, oldest first, the date that week's
# Monday, for the ESCAPE_WINDOW_WEEKS weeks ending with the one NOW falls in,
# or from ESCAPE_CAP_WEEK where that week is older. ROOT is the checkout
# whose base branch is read, fetched first so the count is not the last
# fetch's; TRACKER is the Linear CLI, read live; SCRATCH a directory the
# reads are written to. LINEAR_TEAM, the project's own, narrows the issue
# read where set.
# Returns 1 with ESCAPE_UNREAD naming the read that failed, and ESCAPE_WEEKS
# empty: a count missing either source is not printed as a number.
ESCAPE_WEEKS=""
ESCAPE_UNREAD=""
escapes_read() {
  local root="$1" tracker="$2" now="$3" scratch="$4" week cap from since base repo bug_labels rc=0 cut="" bound="" candidate
  ESCAPE_WEEKS=""
  ESCAPE_UNREAD=""
  # 1970-01-05, a Monday, is 345600: the week starts that many seconds past
  # a multiple of 604800.
  week=$((now - (now - 345600) % 604800))
  if ! cap="$(jq -rn --arg d "$ESCAPE_CAP_WEEK" '"\($d)T00:00:00Z" | fromdateiso8601')"; then
    ESCAPE_UNREAD="the cap week $ESCAPE_CAP_WEEK is not a date"
    return 1
  fi
  if ((cap > week)); then
    ESCAPE_UNREAD="the clock reads before the cap week $ESCAPE_CAP_WEEK"
    return 1
  fi
  from=$((week - (ESCAPE_WINDOW_WEEKS - 1) * 604800))
  ((cap >= from)) || from=$cap
  since=$((from - ESCAPE_REACH))
  if ! base="$("$ESCAPES_LIB_DIR/../resolve-base-branch" "$root" 2>"$scratch/escapes-base.err")"; then
    ESCAPE_UNREAD="the base branch did not resolve"
    return 1
  fi
  # `gtimeout` is the name a Homebrew coreutils install gives `timeout`. Only
  # the bound answers 124 here: neither git nor the Linear CLI exits so.
  for candidate in timeout gtimeout; do
    if command -v "$candidate" >/dev/null 2>&1; then
      bound="$candidate"
      cut=124
      break
    fi
  done
  # A credential prompt would hold the report as a stall does: git never
  # prompts here.
  escapes_bounded "$bound" "$ESCAPE_FETCH_SECONDS" env GIT_TERMINAL_PROMPT=0 git -C "$root" fetch --quiet origin "$base" \
    2>"$scratch/escapes-git.err" || rc=$?
  if [[ "$rc" == "$cut" ]]; then
    ESCAPE_UNREAD="git fetch origin $base timed out"
    return 1
  elif ((rc != 0)); then
    ESCAPE_UNREAD="git fetch origin $base failed"
    return 1
  fi
  if ! git -C "$root" log --first-parent --max-age="$since" --format='%H%x09%ct%x09%s' "refs/remotes/origin/$base" \
    >"$scratch/escapes-log.tsv" 2>"$scratch/escapes-git.err"; then
    ESCAPE_UNREAD="git log origin/$base failed"
    return 1
  fi
  if ! repo="$(cd -- "$root" && orch_resolve_gh_repo "$root" 2>"$scratch/escapes-repo.err")"; then
    ESCAPE_UNREAD="the repository's owner/name did not resolve"
    return 1
  fi
  if [[ ! -x "$tracker" ]]; then
    ESCAPE_UNREAD="no Linear CLI"
    return 1
  fi
  # --format=safe pins the shapes against the project's LINEAR_FORMAT. A
  # workspace spells the label `bug` or `Bug`, and one with neither never
  # read a bug half, so it reads unread rather than 0.
  escapes_bounded "$bound" "$ESCAPE_LINEAR_SECONDS" "$tracker" labels list --max --format=safe \
    >"$scratch/escapes-labels.json" 2>"$scratch/escapes-linear.err" || rc=$?
  if [[ "$rc" == "$cut" ]]; then
    ESCAPE_UNREAD="Linear read timed out"
    return 1
  elif ((rc != 0)); then
    ESCAPE_UNREAD="Linear read failed"
    return 1
  fi
  if ! bug_labels="$(jq -r 'if type != "array" then error("the label list is not one JSON array") else
      [.[] | (.name // "") | select(ascii_downcase == "bug")] | unique | .[] end' "$scratch/escapes-labels.json" 2>"$scratch/escapes-jq.err")"; then
    ESCAPE_UNREAD="the Linear label list did not parse"
    return 1
  fi
  if [[ -z "$bug_labels" ]]; then
    ESCAPE_UNREAD="no Linear label named bug"
    return 1
  fi
  # Only a bug created after the window's earliest merge can name an escape,
  # so the read asks Linear for those bugs alone, one read per spelling of the
  # label. An unset LINEAR_TEAM sends no --team, which the CLI refuses empty.
  # --created-since counts days back from the clock the CLI reads, which is
  # NOW for a report of the present week; the span runs from NOW to the
  # window's reach, a day of margin either side. Linear leaves archived and
  # trashed issues out of a read that does not ask for them.
  local days label
  days=$(((now - since) / 86400 + 2))
  : >"$scratch/escapes-issues.jsonl"
  while IFS= read -r label; do
    escapes_bounded "$bound" "$ESCAPE_LINEAR_SECONDS" "$tracker" issues list --label "$label" \
      --created-since "${days}d" --max ${LINEAR_TEAM:+--team "$LINEAR_TEAM"} --format=safe \
      >>"$scratch/escapes-issues.jsonl" 2>"$scratch/escapes-linear.err" || rc=$?
    if [[ "$rc" == "$cut" ]]; then
      ESCAPE_UNREAD="Linear read timed out"
      return 1
    elif ((rc != 0)); then
      ESCAPE_UNREAD="Linear read failed"
      return 1
    fi
  done <<<"$bug_labels"
  if ! jq -s 'if all(.[]; type == "array") then add // [] | unique_by(.uuid // .id) else error("not arrays") end' \
    "$scratch/escapes-issues.jsonl" >"$scratch/escapes-issues.json" 2>"$scratch/escapes-jq.err"; then
    ESCAPE_UNREAD="the bug list did not parse"
    return 1
  fi
  if ! ESCAPE_WEEKS="$(jq -r -n --rawfile log "$scratch/escapes-log.tsv" --slurpfile issues "$scratch/escapes-issues.json" \
    --arg repo "$repo" --argjson from "$from" --argjson week "$week" --argjson now "$now" --argjson reach "$ESCAPE_REACH" '
    def week: . - ((. - 345600) % 604800);
    def numbers: [match("(?<repo>[A-Za-z0-9-]+/[A-Za-z0-9._-]+)?#(?<n>[0-9]+)"; "g")
      | (.captures | map({key: .name, value: .string}) | from_entries)
      | select(.repo == null or (.repo | ascii_downcase) == ($repo | ascii_downcase)) | .n];
    def regressed: [split("\n")[] | capture("^(?:[*][*]Regressed-by[*][*]|Regressed-by):(?<v>.*)$").v | numbers[]];
    if ($issues | length) != 1 or ($issues[0] | type) != "array" then error("the issue list is not one JSON array") else . end
    | [$log | split("\n")[] | select(length > 0) | split("\t")
        | {sha: .[0], t: (.[1] | tonumber), s: (.[2:] | join("\t"))}] as $commits
    | ([$commits[] | . as $c
        | ((.s | capture("[(]#(?<n>[0-9]+)[)]$")) // (.s | capture("^Merge pull request #(?<n>[0-9]+) ")) // empty)
        | {key: .n, value: {t: $c.t, sha: $c.sha}}] | from_entries) as $merged
    | [($commits[] | select(.s | test("^[Rr]evert")) | {t, sha, ns: (.s | numbers)}),
       ($issues[0][]
         | {t: (.created_at | sub("[.][0-9]+Z$"; "Z") | fromdateiso8601), sha: "",
            ns: ((.description // "") | regressed)})] as $findings
    | [$findings[] as $f | $f.ns[] as $n | $merged[$n] as $m
        | select($m != null and $m.sha != $f.sha and $f.t >= $m.t and $f.t - $m.t <= $reach)
        | {n: $n, t: $f.t}]
    | [group_by(.n)[] | min_by(.t).t | select(. >= $from and . < $now) | week] as $found
    | range($from; $week + 1; 604800) as $w
    | "\($w | todate | .[0:10])\t\([$found[] | select(. == $w)] | length)"' 2>"$scratch/escapes-jq.err")"; then
    ESCAPE_WEEKS=""
    ESCAPE_UNREAD="the git log or the bug list did not parse"
    return 1
  fi
}
