# shellcheck shell=bash
# The escape count oversee-report's Escapes line prints, so the owner can see
# whether one review cycle before the pull request lets more defects through.
#
# An escape is a pull request merged to origin/main that, within
# ESCAPE_REACH seconds of its merge, is named by its number (`#N`) in:
#   - the subject of a revert commit on origin/main, a subject starting
#     `Revert` or `revert`, other than the revert's own merge; or
#   - the title or description of a Linear issue labelled bug and created
#     at or after the merge, read from the linear skill's cache.
# A merged pull request is a first-parent commit on origin/main whose subject
# ends `(#N)`, GitHub's squash merge, or starts `Merge pull request #N `,
# its merge commit. Each escape counts once, in the week of its first
# finding. Weeks are ISO weeks, Monday 00:00 UTC to the next.
#
# Nothing here is stored: every read derives the count from git and the
# cache again.

# Weeks the count covers, the current one included.
ESCAPE_WINDOW_WEEKS=6
# How long after its merge a finding still names an escape: 14 days.
ESCAPE_REACH=1209600
# The Monday of the week REVIEW_MAX_CYCLES fell from 4 to 1, the week an
# Escapes line compares against.
ESCAPE_CAP_WEEK=2026-09-28

# escapes_read ROOT TRACKER NOW SCRATCH — sets ESCAPE_WEEKS to one
# `YYYY-MM-DD<TAB>COUNT` line per week, oldest first, the date that week's
# Monday, for the ESCAPE_WINDOW_WEEKS weeks ending with the one NOW falls in.
# ROOT is the checkout whose origin/main is read, fetched first so the count
# is not the last fetch's; TRACKER is the Linear CLI; SCRATCH a directory the
# reads are written to. Returns 1 with ESCAPE_UNREAD naming the read that
# failed, and ESCAPE_WEEKS empty: a count missing either source is not
# printed as a number.
ESCAPE_WEEKS=""
ESCAPE_UNREAD=""
escapes_read() {
  local root="$1" tracker="$2" now="$3" scratch="$4" week from since
  ESCAPE_WEEKS=""
  ESCAPE_UNREAD=""
  # 1970-01-05, a Monday, is 345600: the week starts that many seconds past
  # a multiple of 604800.
  week=$((now - (now - 345600) % 604800))
  from=$((week - (ESCAPE_WINDOW_WEEKS - 1) * 604800))
  since=$((from - ESCAPE_REACH))
  if ! git -C "$root" fetch --quiet origin main 2>"$scratch/escapes-git.err"; then
    ESCAPE_UNREAD="git fetch origin main failed"
    return 1
  fi
  if ! git -C "$root" log --first-parent --max-age="$since" --format='%H%x09%ct%x09%s' origin/main \
    >"$scratch/escapes-log.tsv" 2>"$scratch/escapes-git.err"; then
    ESCAPE_UNREAD="git log origin/main failed"
    return 1
  fi
  if [[ ! -x "$tracker" ]]; then
    ESCAPE_UNREAD="no Linear CLI"
    return 1
  fi
  # --format=safe pins the shape against the project's LINEAR_FORMAT.
  if ! "$tracker" cache issues list --all-projects --label bug --max --include-archived --format=safe \
    >"$scratch/escapes-bugs.json" 2>"$scratch/escapes-linear.err"; then
    ESCAPE_UNREAD="Linear cache read failed"
    return 1
  fi
  if ! ESCAPE_WEEKS="$(jq -r -n --rawfile log "$scratch/escapes-log.tsv" --slurpfile bugs "$scratch/escapes-bugs.json" \
    --argjson from "$from" --argjson now "$now" --argjson reach "$ESCAPE_REACH" --argjson weeks "$ESCAPE_WINDOW_WEEKS" '
    def week: . - ((. - 345600) % 604800);
    def numbers: [match("#([0-9]+)"; "g").captures[0].string];
    if ($bugs | length) != 1 or ($bugs[0] | type) != "array" then error("the bug list is not one JSON array") else . end
    | [$log | split("\n")[] | select(length > 0) | split("\t")
        | {sha: .[0], t: (.[1] | tonumber), s: (.[2:] | join("\t"))}] as $commits
    | ([$commits[] | . as $c
        | ((.s | capture("[(]#(?<n>[0-9]+)[)]$")) // (.s | capture("^Merge pull request #(?<n>[0-9]+) ")) // empty)
        | {key: .n, value: {t: $c.t, sha: $c.sha}}] | from_entries) as $merged
    | [($commits[] | select(.s | test("^[Rr]evert")) | {t, sha, ns: (.s | numbers)}),
       ($bugs[0][] | {t: (.created_at | sub("[.][0-9]+Z$"; "Z") | fromdateiso8601), sha: "",
         ns: (((.title // "") + "\n" + (.description // "")) | numbers)})] as $findings
    | [$findings[] as $f | $f.ns[] as $n | $merged[$n] as $m
        | select($m != null and $m.sha != $f.sha and $f.t >= $m.t and $f.t - $m.t <= $reach)
        | {n: $n, t: $f.t}]
    | [group_by(.n)[] | min_by(.t).t | select(. >= $from and . < $now) | week] as $found
    | range(0; $weeks) | ($from + . * 604800) as $w
    | "\($w | todate | .[0:10])\t\([$found[] | select(. == $w)] | length)"' 2>"$scratch/escapes-jq.err")"; then
    ESCAPE_WEEKS=""
    ESCAPE_UNREAD="the git log or the bug list did not parse"
    return 1
  fi
}
