# shellcheck shell=bash
# merged-sweep.sh's --help text, sourced by it. It lives in its own file for
# the reason the reduction does: the script is at its size ceiling and the
# contract is the longest thing in it, so a correction here never costs the
# code room. This text IS the contract — three review rounds found a claim
# in it that a fix had moved past — so read it against the reduction lib
# whenever an arm changes, not only against the line being edited.

print_usage() {
  cat <<'USAGE'
Usage: merged-sweep.sh [--window SECS] [--limit N] [--no-state]
                       [--state-file PATH]

Sweep recently-merged PRs for reviews and review thread comments that landed
AFTER the merge and carry no disposition reply. One invocation answers: did a
finding arrive too late for anyone to read it?

  --window SECS      only PRs merged within this many seconds (default
                     172800 — 48h); at most 9 digits
  --limit N          how many merged PRs the one query reads (default 20,
                     max 80). The ceiling is where the query still
                     completes, not where GraphQL stops counting: measured
                     2026-09-01 on one busy repo, 40 in ~4s and 80 in ~8s
                     over six runs with none failing, 100 failing once in
                     two. Load-dependent, so re-measure before trusting it
                     elsewhere
  --no-state         report every current finding, deduping nothing — the
                     audit form; the sweep writes no state file
  --state-file PATH  override the per-repo state file (default:
                     <state-dir>/<repo-slug>, the slug being OWNER/REPO with
                     the slash written %2F, which no accepted GH_REPO can
                     contain, so two repositories can never share one file.
                     The state dir is REVIEW_GATE_MERGED_SWEEP_STATE_DIR,
                     default tmp/review-gate-merged-sweep; a relative one is
                     anchored on the REPOSITORY ROOT, not the cwd, so a
                     caller that changes directory keeps its baseline.
                     GITIGNORE it: the default writes inside the repository

Attention kinds (column 3):
  post-merge-findings  a merged PR carries a review, or a review thread
                       COMMENT, whose EFFECTIVE PUBLICATION time is after its
                       mergedAt and which carries no disposition reply, so
                       nothing has read it. That time is submittedAt for a
                       review, publishedAt for a comment, and createdAt only
                       when neither is present: work DRAFTED before the merge
                       and published after it counts, which is the ordinary
                       shape of a reviewer submitting from the merge queue.
                       A disposition is Fixed in <sha>, Declined: <reason>,
                       or a track-word NAMING an issue; a bare track-word and
                       a Declined: with nothing after the colon are both not
                       answers. Approvals and dismissals are not findings,
                       and neither are the PR author's own reviews when that
                       author is identifiable — two deleted accounts are not
                       proof of one. A thread counts on its newest
                       post-merge comment that is not itself a reply form,
                       never on the thread opening: a reviewer re-raising on a
                       line it already flagged lands in a PRE-merge thread, and
                       a thread whose only post-merge comment IS a reply is
                       answered. The STANDING reply is the newest non-bot one
                       in a reply form BY PUBLICATION TIME, as in
                       review-predicate.sh — never the last in the array,
                       which is ordered by creation — so an older canonical
                       reply never outranks a newer bare one; bots are exempt
                       because they quote each other. The two
                       surfaces differ deliberately: INSIDE a thread a human
                       comment that is not a reply form is new content and
                       reopens the finding, while on the PR CONVERSATION the
                       same comment is chatter and the standing disposition
                       holds. What the read cannot prove fails CLOSED: a
                       truncated reviewThreads page (no documented ordering), a
                       review or comment page entirely post-merge, an
                       unparsable timestamp, and a time equal to mergedAt. One
                       gap is invisible and so uncovered: search is eventually
                       consistent, so a PR the index has not caught up with is
                       absent from the page AND uncounted. A loop recovers what
                       one shot misses
  sweep:window-truncated  the window holds more merged PRs than this page
                       read, so the sweep cannot answer for the remainder.
                       Belongs to no single PR, so it carries "-" and
                       "--------" in the first two columns

Dedupe: per-repo state, the same rising-edge mechanism as oversee-watch's
PW_SEEN. A key names what would have to CHANGE for the report to be news: a
late review is keyed by its own node id, a late thread by the node id of the
COMMENT that produced the finding (the thread id only as a fallback, when a
comment carries none), and the per-PR fail-closed arm by a synthetic
<number>:overflow:<causes> naming the conditions that fired, so a second,
distinct cause on the same PR is news rather than a repeat. A key present in
the previous pass is not re-emitted; one that clears and recurs is news. So a
finding surfaces ONCE and stays quiet while unchanged, and silence means
"nothing NEW needs you" — use --no-state to re-read what is still outstanding.
sweep:window-truncated is EXEMPT: a shortfall no reply can clear is a standing
property, not an event, so it carries no key and REPEATS every pass while it
holds. Announce-once there would leave the gap, and a gap that worsens, silent
from the second pass on.

Output: one tab-separated attention line, the same shape pr-watch.sh
emits, so one reducer consumes both:
  <pr-number> <TAB> <head-sha-8> <TAB> <kind> <TAB> <detail>

Exit codes:
  0  nothing new needs attention
  1  at least one attention line
  2  a read or config failure — always GLOBAL (missing or malformed GH_REPO, a
     bad flag, a repository the read could not reach, a broken merged-PR
     listing, an unusable state file). One query answers for the whole sweep,
     so there is no per-PR failure to isolate: exit 2 reports on stderr and
     prints NO lines on stdout at all. Surface stderr, never stdout alone.
     Attention lines are buffered while the new baseline is STAGED, then
     delivered, and only then is the baseline published: a staging failure
     exits 2 before anything is printed, and a delivery that fails leaves the
     OLD baseline, so the next pass repeats rather than going quiet

Env (required): GH_TOKEN (or ambient gh auth), GH_REPO — OWNER/REPO, and
only letters, digits, '.', '_' and '-' either side of the slash, because it
is spliced into the search query where a qualifier would change the set
Settings: REVIEW_GATE_MERGED_SWEEP_STATE_DIR — the directory holding the
per-repo state files, resolved like every other engine key (env >
.env.local > .kendex/settings.toml > kendex.settings.toml > the built-in
tmp/review-gate-merged-sweep), except that the settings FILES are read from
the REPOSITORY ROOT, so the key is anchored the way the path it names is.
USAGE
}
