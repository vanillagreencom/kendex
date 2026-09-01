#!/usr/bin/env bash
# Review-gate predicate — the single source of truth for "is this PR head
# reviewed?". Shipped by the kendex review-gate skill and vendored into
# consumers at .agents/skills/review-gate/scripts/. The authoritative caller
# contract — evidence forms, trust model, settings keys, the carry-forward
# engine, env seams, output, exit codes — is print_usage below: run --help.
set -u
# A merge gate must never let an inherited BASHOPTS decide which paths match.
shopt -u nocasematch nocaseglob extglob 2>/dev/null || true

print_usage() {
  cat <<'USAGE'
Usage: review-predicate.sh [--help | --check-config]   (otherwise env-driven,
                                                        no positional arguments)

The single source of truth for "is this PR head reviewed?". Callers:
review-writer.sh (the single writer, which converges the merge-blocking
commit status to this verdict on its evaluating legs — its merge_group leg
posts success without evaluation, post-approval by construction, and its
fork pull_request_review leg is a read-only no-op) and the repo's ungated
selftest CI job.

Env (required): GH_TOKEN (or ambient gh auth), GH_REPO, PR_NUMBER, HEAD_SHA
Env (optional): PR_AUTHOR — resolved from the PR when empty.

Output: one machine-readable line on stdout:
  verdict=approved|awaiting|threads-open|changes-requested|untracked-claim|
          unreasoned-decline detail=<human text>
(diagnostic detail also echoed for logs).

Exit codes:
  0  evaluated (the verdict line is authoritative)
  2  an evidence read failed or the configuration is invalid; NO verdict was
     reached. Callers must treat this as "take no action", never as awaiting:
     acting on a transient API failure could flip a healthy PR's merge state.

--check-config resolves and validates every setting below, prints one line,
and exits WITHOUT reading any evidence or requiring GH_REPO / PR_NUMBER /
HEAD_SHA: 0 = every value is legal, 2 = a value is not (the ::error names
it). It is the settings half of validate.sh, which adds the repository-tree
and workflow-wiring checks around it. Gate mode is validated, never applied
— "off" reports a valid configuration, it does not short-circuit this flag.

Predicate: review evidence present for the CURRENT head — any of
  (a) a review OBJECT at the exact head from a non-author, non-dismissed,
      trusted login (trust list empty = any non-author) whose body is not
      the reviewer's own errored-run attestation: the reviews API has no
      errored state, so a bot review that ERRORS lands as a normal review
      row (COMMENTED) whose body says the review never ran. Like a
      skip-marked check pass it proves nothing ran — silence, routed to
      NOT-EVIDENCE, never to failure, and never a carry-forward candidate;
  (b) a trusted clean-analysis CHECK-RUN or legacy COMMIT STATUS succeeding
      on this head, whose title/summary/description carries no skip-pattern
      marker (a "pass" that says the analysis was rate limited, skipped, or
      queued proves nothing ran — silence, not approval, NOT-EVIDENCE). On
      BOTH surfaces the NEWEST row/run per name decides (statuses by list
      order, check-runs by run id — kendex#1110): an older clean success
      never outlives its reviewer's newer pending/failed round;
  (c) a trusted comment-form clean pass: an issue comment by a trusted bot
      login whose body binds the evidence to this head's sha;
  (d) the trusted operator-override (reviewer-outage) attestation status —
      substitutes for MISSING evidence only;
AND no STANDING changes-requested (each reviewer's latest decisive review
across the WHOLE PR — GitHub keeps an objection standing across pushes until
re-approval or dismissal, so that reduction is not scoped to the head;
positive evidence stays exact-head) AND zero unresolved review threads.
Changes-requested and unresolved threads always fail closed, even with
evidence present.

TWO THREAD-CONTENT TERMS ride the same read, both failing closed. A thread's
disposition is its newest non-bot reply that is a reply form or carries a
track-word. `untracked-claim` is that reply claiming tracking and naming no
issue. `unreasoned-decline` is that reply declining and naming no mechanism:
the reason is empty, or is nothing but non-reason tokens and filler. The
tokens are the labels and the freeze procedure that answer a finding without
disproving it, plus bare shas, numbers and tracker ids. A token INSIDE a real
reason is untouched, because the test is subtraction: only a reply that was
nothing else reduces to empty. Being vocabulary, it ends where the residue
becomes NAMES — the suite a bare count belongs to, or a label spelled as a
sentence.

THE CORPUS IS THE CONTRACT, NOT THIS LIST. tests/corpus/ holds what the gate
must catch, what it must pass, and that KNOWN LIMIT. Add a label by writing
the reply THERE first, as a person types it, then widen `reason_left` until
the suite is green. Write the punctuated spelling: normalization turns it to
spaces first, so "won't fix" arrives as "won t fix" and an entry spelled
`wont ?fix` never meets it. That shipped.

A DECLINE IS READ BY ITS SHAPE, NOT BY THE COLON. A reply opening with the
word declines, so "Declined, out of scope" fails exactly as the punctuated
form does. Only `unreasoned-decline` reads it that wide. The untracked-claim
term keeps the narrow `Declined:` form, because widening it there would let
"Declined under the cap, tracked separately" clear a tracking claim naming
no issue, which loosens a merge gate. What a decline must say lives in
orch's references/finding-disposition.md.

APPROVAL IS NEVER SUPERSEDED BY A LATER COMMENT. The evidence reduction is
"an accepted review row exists at head" — never "the latest review per
reviewer" — so a reviewer that posts APPROVED and then a trailing COMMENTED
on the same commit still counts as approval. Only a LATER CHANGES_REQUESTED
from the same login withdraws it (and the separate changes-requested term
fails the gate then anyway). The selftest pins this.

Trust model: trust keys on NAMES ONLY GITHUB CONTROLS — the author login of
a review or comment (exact match on the app's bot login) or the exact
context/name of a check/status on repos where every publisher is trusted. A
comment BODY is never trusted to establish trust; it is read only to BIND
the evidence to a specific commit, so a stale comment cannot vouch for a
later push.

Settings (explicit environment > .env.local > .kendex/settings.toml >
kendex.settings.toml [env] > built-in defaults — lib/settings.sh; full
ladder and exceptions in references/settings.md; list values pack with ';'):
  REVIEW_GATE_TRUSTED_STATUS_CONTEXTS       (b) check/status names; empty
                                            disables the source
  REVIEW_GATE_CHECKRUN_SKIP_PATTERNS        (b) pass-without-analysis markers,
                                            case-insensitive substrings
                                            (default 'rate limited;skipped;
                                            queued'); empty disables
  REVIEW_GATE_COMMENT_REVIEWERS             (c) 'login:binding-pattern' pairs
                                            (first ':' splits; pattern is a
                                            literal prefix); empty disables
  REVIEW_GATE_SHA_PREFIX_FLOOR              (c) shortest sha prefix a comment
                                            may bind (4..40; default 7)
  REVIEW_GATE_OVERRIDE_CONTEXT              (d) operator override status
                                            context, v2 name; when present
                                            anywhere — even empty, which
                                            disables the source — it wins
                                            over the legacy name
  REVIEW_GATE_OUTAGE_CONTEXT                (d) LEGACY override-context name
                                            (default kendex-reviewer-outage);
                                            empty disables
  REVIEW_GATE_STATUS_PUBLISHER_REJECT       (b,d) commit-status creator logins
                                            whose statuses are never
                                            evidence; while configured, a
                                            status with NO creator login is
                                            not evidence; empty disables (the
                                            shipped default)
  REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS  (a) trust list; empty = any
                                            non-author
  REVIEW_GATE_REVIEW_OBJECT_MIN_STATE       (a) 'any' counts any accepted
                                            review row; 'approved' requires
                                            an APPROVED row not withdrawn by
                                            a later CHANGES_REQUESTED from
                                            the same login
  REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS  (a) errored-attestation body
                                            markers, case-insensitive
                                            substrings matched at the START
                                            of the body only (first line,
                                            after trimming whitespace and
                                            markdown quote markers) — a
                                            body quoting a pattern in later
                                            text is evidence; a configured
                                            value replaces the default list
                                            ('encountered an error and was
                                            unable to review'); never a
                                            blocker — the changes-requested
                                            reduction ignores this list;
                                            empty disables
  REVIEW_GATE_THREADS                       'enforce' (default) fails closed
                                            on unresolved review threads;
                                            'off' skips the reviewThreads
                                            GraphQL read entirely and never
                                            emits threads-open — only for
                                            repos whose thread hygiene is a
                                            server-side zero-bypass
                                            required_review_thread_resolution
                                            ruleset (the CI-side term is a
                                            latency optimization there, not
                                            the enforcement point of record).
                                            Only the thread term is disabled;
                                            evidence and changes-requested
                                            still fail closed
  REVIEW_GATE_API_ATTEMPTS                  bounded in-predicate retries for
                                            every evidence read (default 1 =
                                            single attempt); a read failing
                                            through the retries is still
                                            exit 2 — fail-loud unchanged
  REVIEW_GATE_API_RETRY_DELAY_SECONDS       delay between retry attempts
                                            (default 2)
  REVIEW_GATE_MODE                          'enforce' (default) or 'off':
                                            'off' answers approved WITHOUT
                                            evaluating any evidence — the
                                            one-switch per-repo gate disable.
                                            The verdict detail carries the
                                            attestation so every posted
                                            status says the gate is disabled,
                                            not that a review happened.
                                            Unknown values are a config error
                                            (exit 2) — a typo must never
                                            silently disable a merge gate

Carry-forward engine:
  REVIEW_GATE_CARRY_FORWARD    Carry-safe delta classes ('docs', 'comments',
      'vendored'; ';' or '|' separated; empty = off — exact-head evidence
      only). When NO evidence exists at head, a qualifying review object at
      an ancestor commit N still satisfies the evidence term if the N->head
      diff classifies ENTIRELY into the enabled classes, or the trees are
      identical. Classes: 'docs' = docs-only files (*.md / *.markdown by
      extension); 'comments' = comment-only changes to code files
      (per-extension comment-token table; added/removed/renamed files,
      patch-less files, and unknown extensions refuse); 'vendored' = files
      under a path REVIEW_GATE_VENDORED_PATHS names, whatever their
      extension or status — the repository's committed kendex render trees,
      trusted as kendex output without review of their bytes (so a
      hand-edit under one rides; keep policy-bearing paths in
      REVIEW_GATE_CARRY_FORWARD_EXCLUDE, which outranks the class). Only
      the NEWEST ancestor candidate decides. A delta at the compare API's
      300-file cap refuses carry. Never a waiver: real evidence must exist,
      and only EXTENDS across a delta a review would not re-examine; code
      changes OUTSIDE the enabled classes require fresh evidence, and
      changes-requested / unresolved threads still fail closed with carried
      evidence. The 'comments' classifier is line-lexical (blind to
      heredocs and multiline strings) — enable it only where that residual
      risk is acceptable.
  REVIEW_GATE_VENDORED_PATHS    Path globs (';'-separated; the exclusion
      grammar and matcher) naming the kendex render trees the 'vendored'
      class carries, e.g. '.agents/*;.claude/skills/*'. Read from the
      default-branch checkout like every setting, so the PR under judgment
      cannot widen it; a rename carries only with BOTH names under the set.
      Configuration errors (exit 2): an unsupported spelling, the class
      enabled over an empty set, an entry naming no literal path ('*/*').
  REVIEW_GATE_CARRY_FORWARD_EXCLUDE    Path globs (';'-separated,
      shell-style; '*' matches '/' too — fnmatch without FNM_PATHNAME) that
      disqualify a carry: any file in the N->head delta matching an
      exclusion forces fresh evidence even when the delta classifies
      carry-safe — for policy-bearing files the classes would otherwise
      carry (AGENTS.md and other agent/reviewer instruction markdown —
      kendex#1115). Empty = no exclusions. Identical-tree carries are
      unaffected (no delta, nothing to exclude). Inert while
      REVIEW_GATE_CARRY_FORWARD is empty. The pattern GRAMMAR is closed:
      path characters plus '*', matched against repository-relative names.
      Anything else is a configuration error (exit 2), here and under
      --check-config — the '[', ']', '\' and '?' metacharacters, and a
      leading '/', a trailing '/', or a '.', '..' or empty path component,
      which no such name carries. The refusal runs before any evaluation, so
      a rejected spelling never reaches the matcher.

Per-invocation env seams (never settings keys):
  REVIEW_GATE_SETTINGS_FILE         Overrides the settings-file path (tests,
      or a caller resolving settings for a different checkout).
  REVIEW_GATE_STATUS_SNAPSHOT_FILE  Path to a status snapshot (JSON object
      with a 'statuses' array and a top-level 'sha' equal to HEAD_SHA)
      supplied by the CALLER; when set, the predicate evaluates
      trusted-context and override evidence against it instead of fetching
      the statuses itself. LIST-ENDPOINT ROWS ONLY: the rows must come from
      the per-commit statuses LIST endpoint (/commits/<sha>/statuses), the
      same endpoint the fetch path uses — full per-context HISTORY, real
      creator.login on every row. The combined endpoint
      (/commits/<sha>/status) is NOT a valid source: it projects
      latest-per-context (masking newer-row supersession) and serializes
      creator as null for App-posted rows, which the publisher-reject rule
      would then silently drop as not-evidence; while that list is
      configured, a row without a creator login is refused AT THE SEAM
      (exit 2). The snapshot must contain the COMPLETE status set for the
      head: a caller that paginated (heads with >100 rows) merges every
      page's rows into one array under one top-level 'sha' — a
      first-page-only snapshot would silently drop later-page evidence.
      Bound to one head at one moment (the 'sha' requirement enforces the
      binding); a snapshot for another head, or an unreadable/malformed one,
      is exit 2.
USAGE
}

# The predicate is env-driven: zero arguments evaluate, exactly one
# -h/--help prints usage, exactly one --check-config validates settings and
# stops, and every other argument list — an explicitly empty argument
# included — is a configuration error with no verdict. A misspelled or stale
# wrapper flag must never fall through to a normal gate evaluation, so
# validation is by argument count, not by position.
CHECK_CONFIG_ONLY=0
if [ "$#" -eq 1 ] && { [ "$1" = "--help" ] || [ "$1" = "-h" ]; }; then
  print_usage
  exit 0
fi
if [ "$#" -eq 1 ] && [ "$1" = "--check-config" ]; then
  CHECK_CONFIG_ONLY=1
  shift
fi
if [ "$#" -gt 0 ]; then
  echo "review-predicate.sh: unknown argument list ($# argument(s), first: '${1}') — env-driven, no positional arguments (run --help)" >&2
  exit 2
fi

script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
. "$script_dir/lib/settings.sh"

# `|| exit 2`: rg_setting fails on a present-but-unparseable assignment, and
# that is a configuration error (no verdict), never an empty value.
TRUSTED_CONTEXTS="$(rg_setting REVIEW_GATE_TRUSTED_STATUS_CONTEXTS "")" || exit 2
SKIP_PATTERNS="$(rg_setting REVIEW_GATE_CHECKRUN_SKIP_PATTERNS "rate limited;skipped;queued")" || exit 2
COMMENT_REVIEWERS="$(rg_setting REVIEW_GATE_COMMENT_REVIEWERS "")" || exit 2
SHA_FLOOR="$(rg_setting REVIEW_GATE_SHA_PREFIX_FLOOR "7")" || exit 2
# Operator override context, v2 name, resolved HERE (not only in the writer):
# every live gate read — the writer, consumers' heavy-job gate jobs, the
# selftest — goes through this predicate, so an adopter who sets only the v2
# key must not silently lose their override. Presence is detected with a
# sentinel default: a key set nowhere leaves the legacy resolution untouched;
# a key set anywhere (even to the empty string, which disables the source)
# wins over the legacy name.
override_sentinel="__review-gate-override-unset__"
OUTAGE_CONTEXT="$(rg_setting REVIEW_GATE_OVERRIDE_CONTEXT "$override_sentinel")" || exit 2
if [ "$OUTAGE_CONTEXT" = "$override_sentinel" ]; then
  OUTAGE_CONTEXT="$(rg_setting REVIEW_GATE_OUTAGE_CONTEXT "kendex-reviewer-outage")" || exit 2
fi
PUBLISHER_REJECT="$(rg_setting REVIEW_GATE_STATUS_PUBLISHER_REJECT "")" || exit 2
TRUSTED_LOGINS="$(rg_setting REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS "")" || exit 2
MIN_STATE="$(rg_setting REVIEW_GATE_REVIEW_OBJECT_MIN_STATE "any")" || exit 2
ERROR_PATTERNS="$(rg_setting REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS "encountered an error and was unable to review")" || exit 2
THREADS_MODE="$(rg_setting REVIEW_GATE_THREADS "enforce")" || exit 2

# ONE parse of each packed trust list, here at the single place the settings
# are resolved. Every consumer below works from these: the configuration
# checks, the evidence reads, and the awaiting label. Entry boundaries and
# emptiness are decided once, so a value like " ; , " cannot be an open trust
# model to one reader and a named list to another.
# pipefail inside, checked at every caller: this decides the trust boundary,
# and the last stage of the pipeline returns 0 on empty output. A `tr` that
# died would leave a RESTRICTED list looking empty, which the evidence read
# takes as "any non-author" — the trust list would open the gate it was set
# to close. A broken pipeline is exit 2 with no verdict instead.
rg_pack() { # RAW SEPARATORS -> one trimmed, non-empty entry per line
  ( set -o pipefail
    printf '%s\n' "$1" | tr "$2" '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//;/^$/d' )
}
# Called OUTSIDE the substitutions below: an `exit` inside `$( )` would leave
# the subshell and the predicate would carry on with the empty value.
rg_pack_failed() { # KEY
  echo "::error::review-predicate: could not normalize $1 (broken pipeline) — no verdict" >&2
  exit 2
}
TRUSTED_LOGINS_N="$(rg_pack "$TRUSTED_LOGINS" ';,')" || rg_pack_failed REVIEW_GATE_REVIEW_OBJECT_TRUSTED_LOGINS
TRUSTED_CONTEXTS_N="$(rg_pack "$TRUSTED_CONTEXTS" ';')" || rg_pack_failed REVIEW_GATE_TRUSTED_STATUS_CONTEXTS
COMMENT_REVIEWERS_N="$(rg_pack "$COMMENT_REVIEWERS" ';')" || rg_pack_failed REVIEW_GATE_COMMENT_REVIEWERS
API_ATTEMPTS="$(rg_setting REVIEW_GATE_API_ATTEMPTS "1")" || exit 2
API_RETRY_DELAY="$(rg_setting REVIEW_GATE_API_RETRY_DELAY_SECONDS "2")" || exit 2
CARRY_FORWARD="$(rg_setting REVIEW_GATE_CARRY_FORWARD "")" || exit 2
CARRY_EXCLUDE="$(rg_setting REVIEW_GATE_CARRY_FORWARD_EXCLUDE "")" || exit 2
VENDORED_PATHS="$(rg_setting REVIEW_GATE_VENDORED_PATHS "")" || exit 2
GATE_MODE="$(rg_setting REVIEW_GATE_MODE "enforce")" || exit 2

# Configuration errors are exit 2 (no verdict), same contract as a failed
# evidence read: a typo in trust config must never quietly widen or narrow
# the gate.
case "$SHA_FLOOR" in
  ''|*[!0-9]*)
    echo "::error::review-predicate: REVIEW_GATE_SHA_PREFIX_FLOOR must be an integer, got '$SHA_FLOOR'" >&2
    exit 2
    ;;
esac
if [ "$SHA_FLOOR" -lt 4 ] || [ "$SHA_FLOOR" -gt 40 ]; then
  echo "::error::review-predicate: REVIEW_GATE_SHA_PREFIX_FLOOR must be 4..40, got '$SHA_FLOOR'" >&2
  exit 2
fi
case "$GATE_MODE" in
  enforce|off) ;;
  *)
    echo "::error::review-predicate: REVIEW_GATE_MODE must be 'enforce' or 'off', got '$GATE_MODE'" >&2
    exit 2
    ;;
esac
case "$MIN_STATE" in
  any|approved) ;;
  *)
    echo "::error::review-predicate: REVIEW_GATE_REVIEW_OBJECT_MIN_STATE must be 'any' or 'approved', got '$MIN_STATE'" >&2
    exit 2
    ;;
esac
case "$THREADS_MODE" in
  enforce|off) ;;
  *)
    echo "::error::review-predicate: REVIEW_GATE_THREADS must be 'enforce' or 'off', got '$THREADS_MODE'" >&2
    exit 2
    ;;
esac
case "$API_ATTEMPTS" in
  ''|*[!0-9]*|0)
    echo "::error::review-predicate: REVIEW_GATE_API_ATTEMPTS must be an integer >= 1, got '$API_ATTEMPTS'" >&2
    exit 2
    ;;
esac
case "$API_RETRY_DELAY" in
  ''|*[!0-9]*)
    echo "::error::review-predicate: REVIEW_GATE_API_RETRY_DELAY_SECONDS must be a non-negative integer, got '$API_RETRY_DELAY'" >&2
    exit 2
    ;;
esac
# Carry-forward classes: ';' (engine list convention) or '|' (the shape the
# ask was filed with) both split. An unknown class is a config error — a typo
# must never silently widen or narrow what carries.
rg_class_enabled() { # CLASS — 0 when REVIEW_GATE_CARRY_FORWARD lists it
  printf '%s' "$CARRY_FORWARD" | tr ';|' '\n\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | grep -qx -- "$1"
}
while IFS= read -r cls; do
  cls="$(printf '%s' "$cls" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
  [ -z "$cls" ] && continue
  case "$cls" in
    docs|comments|vendored) ;;
    *)
      echo "::error::review-predicate: REVIEW_GATE_CARRY_FORWARD class must be 'docs', 'comments' or 'vendored', got '$cls'" >&2
      exit 2
      ;;
  esac
done <<EOF_CARRY_CFG
$(printf '%s' "$CARRY_FORWARD" | tr ';|' '\n\n')
EOF_CARRY_CFG

# Every evidence read goes through here: up to REVIEW_GATE_API_ATTEMPTS tries
# with REVIEW_GATE_API_RETRY_DELAY_SECONDS between them, so a single transient
# 5xx can survive in-process instead of deferring the verdict to the caller's
# next pass. The default (1 attempt) is exactly today's single try, and a read
# that fails through every attempt still returns nonzero — callers keep the
# fail-loud exit-2 contract unchanged.
gh_read() {
  gh_read_attempt=1
  while :; do
    if gh_read_out="$(gh api "$@")"; then
      printf '%s' "$gh_read_out"
      return 0
    fi
    if [ "$gh_read_attempt" -ge "$API_ATTEMPTS" ]; then
      return 1
    fi
    gh_read_attempt=$((gh_read_attempt + 1))
    echo "::warning::review-predicate: read failed; retry $gh_read_attempt/$API_ATTEMPTS after ${API_RETRY_DELAY}s" >&2
    sleep "$API_RETRY_DELAY"
  done
}

# The gate's own posted status must never be review evidence: with
# REVIEW_GATE_CONTEXT listed as a trusted status context (or naming the
# outage attestation), a previously posted gate success would satisfy the
# predicate by itself — once green, the gate could never close again even
# after the real review evidence is withdrawn. Fail configuration instead.
GATE_CONTEXT_SELF="$(rg_setting REVIEW_GATE_CONTEXT "Review gate")" || exit 2
# Unlike the disable-able evidence sources, the gate context has no empty
# form: it names the required status the CI wiring posts, so "" would make
# that post malformed and leave the gate absent. Same refusal as the refire.
if [ -z "$GATE_CONTEXT_SELF" ]; then
  echo "::error::review-predicate: REVIEW_GATE_CONTEXT must not be empty" >&2
  exit 2
fi
if [ "$OUTAGE_CONTEXT" = "$GATE_CONTEXT_SELF" ]; then
  echo "::error::review-predicate: REVIEW_GATE_OUTAGE_CONTEXT equals REVIEW_GATE_CONTEXT ('$GATE_CONTEXT_SELF') — the gate's own status cannot attest a reviewer outage to itself" >&2
  exit 2
fi
while IFS= read -r ctx; do
  [ -z "$ctx" ] && continue
  if [ "$ctx" = "$GATE_CONTEXT_SELF" ]; then
    echo "::error::review-predicate: REVIEW_GATE_TRUSTED_STATUS_CONTEXTS includes REVIEW_GATE_CONTEXT ('$GATE_CONTEXT_SELF') — the gate's own status cannot be its own review evidence" >&2
    exit 2
  fi
done <<EOF_GATE_CTX
$TRUSTED_CONTEXTS_N
EOF_GATE_CTX

# The exclusion pattern GRAMMAR, and the one judge of it. Callers that need
# the verdict ask for it (`--check-config`) rather than keeping a second
# grammar that drifts from this one.
#
# CLOSED, not a list of refusals: a pattern is path characters plus '*', and
# every other spelling is unsupported. That is what ends the equivalence
# hunt. `case` offers three more metacharacters — '[', ']', '\' and '?' —
# and each can respell a component this refuses: '[.]' and '\.' are the '.'
# component written differently, and the next equivalence would be the next
# round. Refusing the spelling outright means there is no equivalence to
# analyse.
#
# The refusal runs in the configuration phase, ahead of every evaluation, so
# the matcher below never sees a spelling this rejected — the grammar and
# what actually matches cannot diverge.
rg_unsupported_pattern() { # PATTERN — the reason on stdout when it is refused
  local rest="$1" comp
  case "$1" in
    *'['* | *']'* | *'\'* | *'?'*)
      printf '%s' "a character outside the grammar (path characters and '*')"
      return 0
      ;;
    /*) printf '%s' "a leading '/'"; return 0 ;;
    */) printf '%s' "a trailing '/'"; return 0 ;;
  esac
  while [ -n "$rest" ]; do
    comp="${rest%%/*}"
    case "$comp" in
      "") printf '%s' "an empty path component"; return 0 ;;
      . | ..) printf '%s' "a '$comp' path component"; return 0 ;;
    esac
    case "$rest" in
      */*) rest="${rest#*/}" ;;
      *) rest="" ;;
    esac
  done
  return 1
}

rg_check_patterns() { # KEY PACKED — exit 2 on the first refused pattern
  local pat why
  while IFS= read -r pat; do
    pat="$(printf '%s' "$pat" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$pat" ] && continue
    why="$(rg_unsupported_pattern "$pat")" || continue
    echo "::error::review-predicate: $1 pattern '$pat' is not supported — the grammar is path characters plus '*' matched against repository-relative names, and this carries $why" >&2
    exit 2
  done <<EOF_PATTERNS
$(printf '%s' "$2" | tr ';' '\n')
EOF_PATTERNS
}

# The prophylactic ledger is acted on by no evidence path here; it is read so
# its patterns face the same one judge as the live exclusions.
CARRY_EXCLUDE_PROPHYLACTIC="$(rg_setting REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC "")" || exit 2
rg_check_patterns REVIEW_GATE_CARRY_FORWARD_EXCLUDE "$CARRY_EXCLUDE"
rg_check_patterns REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC "$CARRY_EXCLUDE_PROPHYLACTIC"
# The vendored path set is judged by the same grammar and by two rules of
# its own: no empty set under an enabled class, and no entry without literal
# path text — an unbounded class by either spelling. Both hold whether or not
# the class is on, so a set written ahead of enabling it is checked at once.
rg_check_patterns REVIEW_GATE_VENDORED_PATHS "$VENDORED_PATHS"
VENDORED_PATHS_N="$(rg_pack "$VENDORED_PATHS" ';')" || rg_pack_failed REVIEW_GATE_VENDORED_PATHS
if rg_class_enabled vendored && [ -z "$VENDORED_PATHS_N" ]; then
  echo "::error::review-predicate: REVIEW_GATE_CARRY_FORWARD enables 'vendored' but REVIEW_GATE_VENDORED_PATHS names no path — the class carries only what the committed path set names" >&2
  exit 2
fi
# A literal NAME character, not merely one that is not '*': `case` globbing
# crosses '/', so '*/*' matches nearly every nested path; only a name bounds.
while IFS= read -r vp; do
  [ -z "$vp" ] && continue
  case "$vp" in
    *[[:alnum:]]*) ;;
    *)
      echo "::error::review-predicate: REVIEW_GATE_VENDORED_PATHS entry '$vp' names no literal path text — '*' crosses '/', so it would carry nearly every file; name the render tree" >&2
      exit 2
      ;;
  esac
done <<EOF_VENDORED_PATHS
$VENDORED_PATHS_N
EOF_VENDORED_PATHS

# Comment-reviewer GRAMMAR, validated with every other setting rather than at
# the moment the evidence loop first reads a pair. A malformed entry is a
# configuration error, and a configuration error has to be answerable without
# a PR to evaluate — otherwise --check-config reports a legal configuration
# that the next live run exits 2 on.
while IFS= read -r cfg_pair; do
  [ -z "$cfg_pair" ] && continue
  cfg_login="${cfg_pair%%:*}"
  cfg_pattern="${cfg_pair#*:}"
  if [ -z "$cfg_login" ] || [ -z "$cfg_pattern" ] || [ "$cfg_login" = "$cfg_pair" ]; then
    echo "::error::review-predicate: malformed REVIEW_GATE_COMMENT_REVIEWERS entry '$cfg_pair' (need 'login:binding-pattern')" >&2
    exit 2
  fi
done <<EOF_COMMENT_CFG
$COMMENT_REVIEWERS_N
EOF_COMMENT_CFG

# Every configuration rule above has now run, and --check-config stops HERE:
# the last point before the predicate needs a PR. A rule moved below this
# statement is a visible edit, not a silent hole in what the flag covers.
if [ "$CHECK_CONFIG_ONLY" = "1" ]; then
  echo "review-predicate: configuration is valid"
  exit 0
fi

for required in GH_REPO PR_NUMBER HEAD_SHA; do
  if [ -z "$(eval "echo \${$required:-}")" ]; then
    echo "::error::review-predicate: $required is required" >&2
    exit 2
  fi
done

# The one-switch gate disable (owner decision 2026-08-08): mode "off" answers
# approved BEFORE any evidence read — no API calls, no evidence model, no
# thread term. The detail line is an attestation, not a review claim: every
# status the writer converges from this verdict says the gate is disabled.
# Required env is still validated above (a caller that cannot even name the
# PR is misconfigured regardless of mode), and an invalid mode value already
# exited 2 — the switch can turn the gate off, a typo cannot.
if [ "$GATE_MODE" = "off" ]; then
  echo "verdict=approved detail=review gate disabled by settings (REVIEW_GATE_MODE=off)"
  exit 0
fi

if [ -z "${PR_AUTHOR:-}" ]; then
  PR_AUTHOR="$(gh_read "repos/$GH_REPO/pulls/$PR_NUMBER" --jq .user.login)" || {
    echo "::error::could not resolve PR #$PR_NUMBER author" >&2
    exit 2
  }
  if [ -z "$PR_AUTHOR" ]; then
    echo "::error::PR #$PR_NUMBER author resolved to an empty login" >&2
    exit 2
  fi
fi

# Two steps, not a pipe: `--paginate` emits ONE ARRAY PER PAGE, which the
# count filters below would evaluate per-array (multi-line counts that can
# never equal "0" past 100 reviews), and a mid-pipe gh failure must fail
# loudly rather than hand jq a truncated page set. ZERO BYTES from a
# successful producer is a broken read too (truncated stream, empty response
# body): `jq -s 'add // []'` would silently turn it into [], and for the
# reviews read specifically an empty result can erase a standing
# CHANGES_REQUESTED while other evidence still satisfies the positive side —
# a false approved. An intentionally empty page set from a real API response
# is a NON-EMPTY `[]` body, so only a bytes-empty producer is refused — and
# the merge validates page SHAPE, not just parse success: a whitespace-only
# body passes the zero-byte check yet slurps to [] (vacuously "no reviews"),
# and an error-object page would collapse through `add` — both erase a
# standing CHANGES_REQUESTED. A broken read is exit 2, never empty evidence.
raw_reviews="$(gh_read "repos/$GH_REPO/pulls/$PR_NUMBER/reviews?per_page=100" --paginate)" || {
  echo "::error::could not read reviews for PR #$PR_NUMBER" >&2
  exit 2
}
if [ -z "$raw_reviews" ]; then
  echo "::error::reviews read for PR #$PR_NUMBER produced zero bytes (broken read, not an empty page set)" >&2
  exit 2
fi
reviews="$(jq -s 'if (length > 0) and all(type == "array")
                  then add
                  else error("review pages are not arrays") end' <<<"$raw_reviews" 2>/dev/null)" || {
  echo "::error::reviews read for PR #$PR_NUMBER returned non-array pages or a vacuous body (broken read)" >&2
  exit 2
}
# Changes-requested reduces each reviewer over their DECISIVE states only
# (APPROVED / CHANGES_REQUESTED, ordered by submitted_at) across the WHOLE
# PR — never scoped to the head: GitHub keeps an objection standing when the
# author pushes new commits, so a head-scoped reduction would let any
# evidence source on the fresh head open the gate past a standing human
# objection. A later APPROVED from the same reviewer (on any commit) clears
# it, so a superseded CR can't pin the PR red forever — but a trailing
# COMMENTED row never withdraws one (GitHub itself keeps requested changes
# standing until re-approval or dismissal), the mirror of the header's
# approval-is-never-superseded-by-a-comment rule. Deliberately unfiltered by
# the trust list: anyone's standing objection fails the gate closed. PENDING
# rows (unsubmitted drafts, visible when the token authored them) are
# excluded EVERYWHERE: a draft is not a review event — it must neither clear
# a standing CR here nor count as evidence below.
cr="$(jq '[.[] | select(.state != "DISMISSED" and .state != "PENDING") | select(.state == "APPROVED" or .state == "CHANGES_REQUESTED")] | group_by(.user.login) | map(sort_by(.submitted_at // "") | .[-1]) | map(select(.state == "CHANGES_REQUESTED")) | length' <<<"$reviews")" || {
  echo "::error::could not evaluate changes-requested reviews for PR #$PR_NUMBER" >&2
  exit 2
}
# An ERRORED bot review is a normal review ROW: the reviews API has no
# errored state, so the failure lives only in the row's body — the
# reviewer's own attestation that the review never ran (live shape:
# "Copilot encountered an error and was unable to review this pull
# request."). Such a row is the review-object mirror of a skip-marked check
# pass: NOT-EVIDENCE, never a failure — it must not satisfy the gate, not
# mask other rows, and not seed a carry. The body is read only to WITHDRAW
# its own row toward silence (the fail-closed direction), never to
# establish trust, so the trust model is unchanged. The markers come from
# REVIEW_GATE_REVIEW_OBJECT_ERROR_PATTERNS — case-insensitive substrings,
# ';'-separated, the same shape as the check-run skip patterns, but matched
# at the START of the body only: its first line, after trimming leading
# whitespace and markdown quote markers. An attestation IS the body, while a
# review that merely quotes a pattern in later text — any PR that edits the
# setting itself — is genuine evidence and must not be dropped. A configured
# value replaces the default list, and empty disables the filter (an explicit
# choice to count errored rows as evidence). Deliberately NOT applied to the
# changes-requested reduction above: body text that could erase a standing
# objection would be a fail-open lever, and an errored row can never block
# anyway (it is not CHANGES_REQUESTED).
#
# Defined ONCE and concatenated in front of BOTH jq programs that accept
# review rows — head evidence here, carry candidates below — because
# attestation semantics must never drift between them, and two hand-kept
# copies of the fragment would part ways silently. The body is bound BEFORE
# testing containment: inside contains(.) the dot would rebind, the same trap
# as the skip-pattern filter. $mk is the lowercased pattern list each program
# builds from $errmarks.
ATTESTATION_DEF='def not_errored_attestation($mk):
  (((.body // "") | ascii_downcase
    | sub("^[\\s>]+"; "") | split("\n") | (.[0] // "")) as $b
   | [ $mk[] | . as $p | select($b | contains($p)) ] | length) == 0;'

# Review-object evidence. NOT a latest-review-per-reviewer reduction (see the
# header): in "any" mode every accepted row counts; in "approved" mode a
# login contributes evidence when its newest APPROVED at head is not followed
# by a newer CHANGES_REQUESTED from that same login — a trailing COMMENTED
# never withdraws an approval.
got="$(jq --arg sha "$HEAD_SHA" --arg author "$PR_AUTHOR" \
        --arg trusted "$TRUSTED_LOGINS_N" --arg minstate "$MIN_STATE" \
        --arg errmarks "$ERROR_PATTERNS" "$ATTESTATION_DEF"'
  ($trusted | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $t
  | ($errmarks | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | map(ascii_downcase)) as $mk
  | [ .[]
      | select(.commit_id == $sha and .state != "DISMISSED" and .state != "PENDING" and .user.login != $author)
      | select(($t | length) == 0 or (.user.login as $l | ($t | index($l)) != null))
      | select(not_errored_attestation($mk))
    ]
  | if $minstate == "approved" then
      group_by(.user.login)
      | map(sort_by(.submitted_at // ""))
      | map(select(
          ([.[] | select(.state == "APPROVED")] | length) > 0
          and (
            ([.[] | select(.state == "CHANGES_REQUESTED")] | length) == 0
            or (([.[] | select(.state == "APPROVED")] | last | .submitted_at // "") >
                ([.[] | select(.state == "CHANGES_REQUESTED")] | last | .submitted_at // ""))
          )
        ))
      | length
    else
      length
    end' <<<"$reviews")" || {
  echo "::error::could not evaluate review-object evidence for PR #$PR_NUMBER" >&2
  exit 2
}

# Clean-analysis evidence: bots that submit a review OBJECT only when they
# have findings pass their trusted check on a clean re-analysis and post no
# review, so "review at head" would be forever unsatisfiable after a push
# that fixes everything. Accept the trusted check-run OR legacy commit status
# succeeding on THIS head (evidence lives in EITHER API depending on the
# bot/repo; query both, either counts) — but only when the pass PROVES
# ANALYSIS RAN: a success whose title/summary/description matches a skip
# pattern (e.g. "Review rate limited") performed no review, so it is filtered
# to not-evidence — the same as absent, never a failure. A read FAILURE here
# must fail LOUDLY: treating it as absent evidence could flip a healthy PR's
# merge state on a transient API hiccup.
# The statuses LIST endpoint paginates (100 rows per page here), so fetch
# EVERY page (fail loud) and merge them into one snapshot — each trusted
# context and the outage attestation below evaluate against it. Fetch and
# merge are SEPARATE steps for the same reason as the check-runs read: a
# pipe would replace gh's exit status with jq's and turn a read failure
# into an empty-success (fail-open). A caller that already holds the
# LIST-endpoint rows (a converge-style sweep projecting required statuses
# per head) hands them in via REVIEW_GATE_STATUS_SNAPSHOT_FILE instead
# (wrapped {sha, statuses} per the header contract), and this read is
# skipped entirely.
if [ -n "${REVIEW_GATE_STATUS_SNAPSHOT_FILE:-}" ]; then
  # The snapshot substitutes for a READ, so it gets the read contract: not a
  # file, zero bytes, unparseable, missing the statuses array, or not bound
  # to THIS head (top-level sha != HEAD_SHA — a snapshot for another head
  # would pass shape validation and evaluate stale evidence) is exit 2 —
  # never an empty-evidence verdict. A single-page API response carries the
  # head sha at top level and satisfies the binding as-is; paginating
  # callers must merge all pages' statuses into the one array first (a
  # first-page-only snapshot silently drops later-page evidence).
  #
  # Slurped, requiring exactly ONE value: a caller that hands over
  # concatenated page responses would otherwise yield one normalized object
  # per value, and every downstream per-value jq read would emit multi-line
  # counts ("0\n0") that fail the string comparisons in the verdict logic —
  # with no trusted contexts configured that fell through to an approval
  # with zero evidence (kendex#1086). Slurping also makes a zero-value
  # (empty or whitespace-only) file hit the error branch instead of jq's
  # silent empty-output success.
  #
  # LIST-endpoint rows only (see the env contract in the header): while the
  # publisher reject list is configured, every row must carry a real
  # creator login — on the LIST endpoint every real publisher has one, and
  # the downstream anomaly rule drops login-less rows as not-evidence. A
  # combined-endpoint snapshot (null creators on App rows) under a
  # configured reject list would therefore silently erase real evidence;
  # refusing it here turns that erasure into a loud contract error. With
  # the reject list empty (the shipped default) the filter is off and no
  # creator requirement applies.
  status_resp="$(jq -s --arg sha "$HEAD_SHA" --arg reject "$PUBLISHER_REJECT" '
                     ($reject | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $rj
                     | if (length == 1) and (.[0]
                        | (type == "object") and ((.statuses | type) == "array")
                          and (.sha == $sha)
                          and (($rj | length) == 0
                               or (.statuses | all(
                                    ((.creator | type) == "object")
                                    and ((.creator.login | type) == "string")
                                    and ((.creator.login | length) > 0)))))
                     then {statuses: .[0].statuses}
                     else error("not a single list-endpoint status snapshot for this head") end' \
                    "$REVIEW_GATE_STATUS_SNAPSHOT_FILE" 2>/dev/null)" || {
    echo "::error::REVIEW_GATE_STATUS_SNAPSHOT_FILE '$REVIEW_GATE_STATUS_SNAPSHOT_FILE' is not a readable list-endpoint status snapshot bound to $HEAD_SHA (exactly one JSON object with a statuses array and top-level sha == HEAD_SHA; with REVIEW_GATE_STATUS_PUBLISHER_REJECT configured every row must carry a creator login — combined-endpoint snapshots null App creators and are not a valid source)" >&2
    exit 2
  }
else
  # THE STATUSES LIST, NOT THE COMBINED STATUS — this is a security
  # requirement, not a style choice. The combined endpoint
  # (/commits/<sha>/status) serializes `creator` as NULL for every
  # App-posted status, and GITHUB_TOKEN in any PR workflow IS the GitHub
  # Actions app. Reading it made REVIEW_GATE_STATUS_PUBLISHER_REJECT
  # inert: PR-controlled code could mint a trusted context (or the operator
  # override) and no login entry could ever match it. The LIST endpoint
  # (/commits/<sha>/statuses) reports the real creator login, so the
  # reject-list works as documented. Caught live by sandbox scenario 6.
  status_pages="$(gh_read "repos/$GH_REPO/commits/$HEAD_SHA/statuses?per_page=100" --paginate)" || {
    echo "::error::could not read commit statuses for $HEAD_SHA" >&2
    exit 2
  }
  if [ -z "$status_pages" ]; then
    echo "::error::commit-statuses read for $HEAD_SHA produced zero bytes (broken read)" >&2
    exit 2
  fi
  # Validate every page BEFORE merging: a nonempty non-array page (an error
  # object, a truncated body) would survive the zero-byte guard and then
  # collapse to an empty status list, letting the predicate reach a verdict
  # on broken evidence. A broken read is exit 2, never an empty-evidence
  # verdict. `length > 0` guards the vacuous case: a whitespace-only
  # response passes the -z check yet slurps to [], where all(...) is
  # trivially true (kendex#1086).
  status_resp="$(jq -s 'if (length > 0) and all(type == "array")
                        then {statuses: (add // [])}
                        else error("not a statuses page") end' \
                    <<<"$status_pages" 2>/dev/null)" || {
    echo "::error::could not merge the commit-status pages for $HEAD_SHA (each page must be a JSON array)" >&2
    exit 2
  }
fi
check=0
while IFS= read -r ctx; do
  [ -z "$ctx" ] && continue
  ctx_uri="$(jq -rn --arg s "$ctx" '$s|@uri')"
  # --paginate emits one OBJECT per page for this endpoint; jq -s merges the
  # pages' check_runs arrays so a success beyond the first page still counts
  # (a missed run strands the gate at awaiting — wrong direction to lose).
  # Fetch and merge are SEPARATE steps: a pipe would replace gh's exit status
  # with jq's and turn a read failure into an empty-success (fail-open).
  checkruns_pages="$(gh_read "repos/$GH_REPO/commits/$HEAD_SHA/check-runs?check_name=$ctx_uri&per_page=100" --paginate)" || {
    echo "::error::could not read '$ctx' check-runs" >&2
    exit 2
  }
  if [ -z "$checkruns_pages" ]; then
    echo "::error::'$ctx' check-runs read produced zero bytes (broken read)" >&2
    exit 2
  fi
  # Page-shape validation, same reasoning as the reviews read: a
  # whitespace-only body slurps to [] and a non-object page (or one with no
  # check_runs array) would collapse to an empty run set — silence built
  # from a broken read. Exit 2 instead.
  checkruns_resp="$(jq -s 'if (length > 0) and all((type == "object") and ((.check_runs | type) == "array"))
                           then {check_runs: (map(.check_runs) | add)}
                           else error("check-run pages are malformed") end' <<<"$checkruns_pages" 2>/dev/null)" || {
    echo "::error::'$ctx' check-run pages are malformed or vacuous (broken read)" >&2
    exit 2
  }
  # Bind each skip pattern to a variable BEFORE testing containment: inside
  # `select($text | contains(.))` the dot would rebind to $text itself, so
  # every clean pass would "match" and be filtered to not-evidence. Same
  # rebinding trap as the comment-sha binding below; the selftest's
  # genuine-clean-pass case is what catches it.
  # Check-runs are matched by NAME, but names are not reserved: any PR
  # workflow with `checks: write` can publish a check run under ANY name
  # through the shared `github-actions` app — trusted reviewer bots publish
  # under their own app slug. A github-actions-published name-match is
  # therefore never clean-analysis evidence (VST-19); rejecting it here is
  # the mechanical half of the settings doc's "only names produced by
  # trusted bots" precondition.
  #
  # SUPERSESSION IS PER SURFACE, deliberately: the check-run and commit-
  # status surfaces are independent evidence sources ("either counts" is the
  # documented contract), so a newer run on one surface does not withdraw an
  # older row on the OTHER. Cross-surface ordering has no sound key — run
  # ids and status ids live in different id spaces, and timestamps carry the
  # one-second-tie hazard both projections were built to avoid — and no
  # known reviewer publishes both surfaces under one name on one head (the
  # migration case lands as a name change or a repo settings change, both of
  # which reset trust config). A repo listing a name its reviewer publishes
  # on both surfaces accepts that either surface's newest clean row
  # satisfies the term.
  #
  # NEWEST RUN DECIDES, per name (kendex#1110) — the check-run mirror of the
  # status branch's newest-row projection below. Counting "any clean
  # success" would let a reviewer's older clean run outlive its own NEWER
  # in-progress/failed round on the same head (a bot starting a fresh
  # analysis creates a new run; the default filter=latest projects per
  # check SUITE, and a fresh analysis is a fresh suite) and open the gate
  # on stale evidence. Ordering keys on the run id — assigned monotonically
  # at creation, present on every real API row, and immune to the
  # one-second created_at ties the status branch documents; started_at is
  # NOT used (null on queued runs, which would sort a queued fresh round
  # oldest and revive the stale success). Mirroring the status branch's
  # publisher handling: github-actions-published rows are dropped BEFORE
  # the projection (the one identity PR content can wield — a minted newer
  # row must not mask real rows, not even toward closed), while rows with
  # NO app slug at all are KEPT in the sequence — an anomalous newest row
  # reads as silence, and dropping it pre-projection would revive an older
  # success from malformed current evidence. PR content cannot produce a
  # slugless row (its runs carry the github-actions slug). The newest
  # accepted row must then itself be a clean, non-skip-filtered success;
  # anything else — in-progress (null conclusion), failure, a skip-marked
  # "pass", or a slugless anomaly — is silence, never a gate failure. The
  # ordering key is VALIDATED, not defaulted: a retained row without a
  # positive numeric id would sort as the OLDEST row, so a malformed newest
  # round could revive the older success it should mask — every real API
  # row carries the id, so its absence is a broken read (exit 2), the same
  # posture as every page-shape guard. Rows dropped for the github-actions
  # slug are excluded BEFORE validation: a minted row cannot fail the read.
  check_runs="$(jq --arg ctx "$ctx" --arg skips "$SKIP_PATTERNS" '
      ($skips | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | map(ascii_downcase)) as $sk
      | [ .check_runs[]
          | select(.name == $ctx)
          | select((.app.slug // "") != "github-actions")
        ]
      | if any(.[]; ((.id // null) | type) != "number" or (.id < 1))
        then error("check-run row without a positive run id (broken read)")
        else . end
      | sort_by(.id) | last
      | if . == null then 0
        elif ((.app.slug // "") == "") then 0
        elif (.conclusion == "success")
             and ((((.output.title // "") + " " + (.output.summary // "")) | ascii_downcase) as $text
                  | ([ $sk[] | . as $p | select($text | contains($p)) ] | length) == 0)
        then 1 else 0 end' <<<"$checkruns_resp")" || {
    echo "::error::could not evaluate '$ctx' check-runs" >&2
    exit 2
  }
  # Commit statuses carry no app slug to reject on, but the LIST endpoint
  # carries a real creator login (the combined endpoint does not — see the
  # read above). On repos whose PR-triggered workflows hold statuses:write,
  # PR content can mint a status under ANY context through
  # github-actions[bot] — the one publisher identity PR code can wield. The
  # OPT-IN REVIEW_GATE_STATUS_PUBLISHER_REJECT list is the status-side
  # mirror of the check-run app rejection above: a status whose creator
  # login is listed is never evidence.
  #
  # A status with NO creator login is not evidence either WHEN THE LIST IS
  # CONFIGURED: on this endpoint every real publisher has a login, so a
  # missing one is an anomaly, and treating anomalies as trusted is the
  # fail-open direction this engine exists to avoid. With the list empty
  # (the shipped default) the filter is off entirely and behavior is
  # unchanged.
  # NEWEST ROW DECIDES, per context. The LIST endpoint returns the full
  # status HISTORY, not the combined endpoint's latest-per-context
  # projection — filtering for "any success" would let an old success
  # outlive a NEWER pending/failure on the same context and open the gate
  # on stale evidence (a reviewer starting a fresh round posts pending over
  # its own earlier success). Publisher-rejected rows are dropped BEFORE
  # choosing the newest — a rejected creator is "not evidence either way",
  # and letting a minted row mask real rows would hand PR content a
  # close-the-gate lever it should not have (only toward closed, but still
  # not its call). Login-less ANOMALY rows are the opposite: they are NOT
  # dropped from the sequence — dropped-before-newest they would revive an
  # OLDER success (stale approval from malformed current evidence); kept,
  # an anomalous NEWEST row reads as silence. Safe against the minting
  # lever because PR content cannot produce a login-less row (its statuses
  # carry github-actions[bot], which is what the reject list names), and a
  # GitHub-side anomaly (a ghost/deleted creator) masks toward CLOSED, and
  # only until a real row supersedes it. The newest ACCEPTED row must then
  # itself be a clean success: a newest row that is pending/failure, a
  # skip-filtered success ("rate limited"), or — while the reject list is
  # configured — a login-less anomaly, is silence — exactly what the
  # combined endpoint's projection used to yield.
  check_status="$(jq --arg ctx "$ctx" --arg skips "$SKIP_PATTERNS" --arg reject "$PUBLISHER_REJECT" '
      ($skips | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | map(ascii_downcase)) as $sk
      | ($reject | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $rj
      | [ .statuses[]
          | select(.context == $ctx)
          # Bind the login BEFORE index(): inside index(...) the dot rebinds
          # to $rj, so `.creator` would index the reject ARRAY, not the
          # status. Same rebinding trap the comment-form matcher documents.
          # Only LISTED creators are dropped; login-less rows stay in the
          # sequence (see the anomaly rationale above).
          | (.creator.login // "") as $cl
          | select(($rj | length) == 0 or ($cl == "") or (($cl | type) != "string") or (($rj | index($cl)) == null))
        ]
      # FIRST accepted row, not sort_by(created_at)|last: the API lists
      # statuses newest-first (the writer and driver already rely on it),
      # and created_at has one-second precision — jq sort is stable, so two
      # rows tied within a second would sort with the OLDER one last and
      # reintroduce exactly the stale-evidence read this projection closes.
      | first
      | if . == null then 0
        elif ($rj | length) > 0
             and (((.creator | type) != "object")
                  or ((.creator.login | type) != "string")
                  or ((.creator.login | length) == 0))
        then 0
        elif .state == "success"
             and ((((.description // "") | ascii_downcase) as $text
                   | [ $sk[] | . as $p | select($text | contains($p)) ] | length) == 0)
        then 1 else 0 end' <<<"$status_resp")" || {
    echo "::error::could not evaluate '$ctx' commit status" >&2
    exit 2
  }
  check=$((check + check_runs + check_status))
done <<EOF
$TRUSTED_CONTEXTS_N
EOF

# Comment-form clean-pass evidence: some reviewers post NEITHER a review
# object NOR a check/status on a clean pass — only an issue comment on the PR
# conversation ("... Reviewed commit: `<sha>`"). Trust keys on the AUTHOR
# LOGIN (exact match; only GitHub can set it) — and the PR author is
# excluded even when configured as a comment reviewer, or a bot could
# self-approve its own update PR; the body is read ONLY to bind the
# evidence to a commit. The bound sha may be the full sha or a short prefix
# (bare or backtick-quoted — decoration between the binding pattern and the
# sha is ignored as non-hex): the match is "HEAD_SHA starts with the bound
# sha", case-insensitively, with a floor so a degenerate prefix cannot
# match every head. The trust anchor is the author login plus the LITERAL
# binding pattern immediately preceding the sha slot, not the quoting.
comment_hits=0
if [ -n "$COMMENT_REVIEWERS_N" ]; then
  # Two steps, not a pipe — same pagination/fail-loud/zero-byte reasons as
  # the reviews read above.
  raw_comments="$(gh_read "repos/$GH_REPO/issues/$PR_NUMBER/comments?per_page=100" --paginate)" || {
    echo "::error::could not read issue comments for PR #$PR_NUMBER" >&2
    exit 2
  }
  if [ -z "$raw_comments" ]; then
    echo "::error::issue-comments read for PR #$PR_NUMBER produced zero bytes (broken read, not an empty page set)" >&2
    exit 2
  fi
  # Same page-shape validation as the reviews read: whitespace slurps to
  # [] and an error-object page collapses through `add` — either would
  # vaporize comment-form evidence (wrong direction: strands at awaiting)
  # on a broken read that should be exit 2.
  comments="$(jq -s 'if (length > 0) and all(type == "array")
                     then add
                     else error("comment pages are not arrays") end' <<<"$raw_comments" 2>/dev/null)" || {
    echo "::error::issue-comments read for PR #$PR_NUMBER returned non-array pages or a vacuous body (broken read)" >&2
    exit 2
  }
  while IFS= read -r pair; do
    [ -z "$pair" ] && continue
    # Grammar was proved in the configuration phase above, which is the one
    # site for it; this loop only splits what that pass accepted.
    login="${pair%%:*}"
    pattern="${pair#*:}"
    # The binding pattern is a LITERAL prefix (regex-quoted here), not a
    # regex: trust config must not be able to smuggle in a permissive match.
    hits="$(jq --arg sha "$HEAD_SHA" --arg bot "$login" --arg author "$PR_AUTHOR" \
               --arg pat "$pattern" --arg floor "$SHA_FLOOR" '
      def requote: gsub("(?<c>[.^$|?*+()\\[\\]{}\\\\-])"; "\\" + .c);
      (($pat | requote) + "[^0-9a-fA-F]*([0-9a-fA-F]{" + $floor + ",40})") as $re
      | [ .[]
          | select(.user.login == $bot and .user.login != $author)
          | (.body // "")
          | scan($re)
          # Bind the claimed sha BEFORE comparing. Piping the head into
          # startswith and referring to the scanned value as dot rebinds dot
          # to the head inside that pipe, so every comment matches itself and
          # ANY sha is accepted. That is a false approved, the only direction
          # of this gate that fails silently; the different-sha case in the
          # selftest is what caught it.
          | (.[0] | ascii_downcase) as $claimed
          | select(($sha | ascii_downcase) | startswith($claimed))
        ] | length' <<<"$comments")" || {
      echo "::error::could not evaluate '$login' review comments for PR #$PR_NUMBER" >&2
      exit 2
    }
    comment_hits=$((comment_hits + hits))
  done <<EOF
$COMMENT_REVIEWERS_N
EOF
fi

# Reviewer-outage attestation: a trusted orchestrator posts this context on
# the head ONLY on genuine total reviewer silence (zero unresolved threads,
# no review/check/status engagement, head re-confirmed at emit). It
# substitutes for MISSING review evidence only — changes-requested and
# unresolved threads still fail closed. SECURITY: deliberate, bounded
# relaxation; trusted-publisher model identical to the trusted status
# contexts above. See orch DEVELOPMENT.md "Reviewer-outage recognition".
outageok=0
outage_reason=""
if [ -n "$OUTAGE_CONTEXT" ]; then
  # The publisher reject-list applies here too — the outage relaxation is
  # the highest-value status to forge, so a listed creator (typically
  # github-actions[bot] where PR workflows hold statuses:write) must not be
  # able to mint it. Same null-creator semantics as the trusted-context
  # read above: on the LIST endpoint every real publisher (Apps included)
  # carries a creator login, so while the reject list is configured a
  # status with NO login is an anomaly and is not evidence — trusting
  # anomalies is the fail-open direction. And same SEQUENCE semantics:
  # anomaly rows stay in the newest-row selection (an anomalous newest row
  # is silence, never a hole an older success shines through), only listed
  # creators are dropped before it. List empty (the default) = filter
  # off = unchanged behavior.
  # The REASON is mandatory (plan Change 2, finding 9, carried from the
  # outage semantics): an override with an empty description is not an
  # attestation, it is an unexplained relaxation — and it is the
  # highest-value status in the system to forge. Enforced here, not merely
  # documented. The reason rides out in the verdict detail below, flattened
  # at the source because it is API text travelling through a one-line
  # contract and a one-line status description.
  # Same newest-accepted-row semantics as the trusted-context read above
  # (the LIST endpoint is a history): an operator withdrawing an override
  # by posting pending/failure on the same context must actually withdraw
  # it — an older success may not outlive the newer row.
  outageok_out="$(jq -r --arg ctx "$OUTAGE_CONTEXT" --arg reject "$PUBLISHER_REJECT" '
    ($reject | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $rj
    | [ .statuses[]
        | select(.context == $ctx)
        | (.creator.login // "") as $cl
        | select(($rj | length) == 0 or ($cl == "") or (($cl | type) != "string") or (($rj | index($cl)) == null))
      ]
    # FIRST accepted row — same newest-first API-order reliance and
    # second-precision tie rationale as the trusted-context read above.
    | first
    | if . == null then "0\t"
      elif ($rj | length) > 0
           and (((.creator | type) != "object")
                or ((.creator.login | type) != "string")
                or ((.creator.login | length) == 0))
      then "0\t"
      elif .state == "success"
           and (((.description // "") | gsub("^\\s+|\\s+$"; "") | length) > 0)
      then "1\t\((.description // "") | gsub("[\n\r\t]"; " "))"
      else "0\t" end' <<<"$status_resp")" || {
    echo "::error::could not evaluate the operator-override status" >&2
    exit 2
  }
  outageok_out="$(head -n 1 <<<"$outageok_out")"
  outageok="$(cut -f1 <<<"$outageok_out")"
  outage_reason="$(cut -f2- <<<"$outageok_out")"
fi

# Evidence carry-forward across carry-safe deltas (VST-57). Evidence is
# review at the EXACT head, so every push — including one that changes no
# executable behavior (review-servicing prose, comment rewording) — discards
# existing evidence and restarts the full bot-review wait. When NO evidence
# exists at head and REVIEW_GATE_CARRY_FORWARD enables it, a qualifying
# review OBJECT at an ancestor commit N still satisfies the evidence term if
# the N→head diff classifies ENTIRELY into the enabled carry-safe classes:
#   docs      every changed file is documentation BY EXTENSION
#             (*.md/*.markdown; a docs/-directory rule would carry
#             executable files like docs/conf.py)
#   comments  every changed file is a MODIFIED code file whose patch touches
#             only full-line comments (per a conservative per-extension
#             comment-token table; unknown extensions refuse)
# and an IDENTICAL tree (rebase residue, empty commits — the VST-58 shape)
# always carries once any class is enabled. This is NOT the retired
# docs-only waiver: real evidence must exist, and only EXTENDS across a
# delta review would not re-examine — code changes OUTSIDE the enabled
# classes require fresh evidence, and changes-requested and threads still
# fail closed with carried evidence. Only the NEWEST ancestor decides: an
# older candidate's delta is a superset, walking back only widens carry.
carried=0
carry_base=""
carry_kind=""
if [ -n "$CARRY_FORWARD" ] && [ "$got" = "0" ] && [ "$check" = "0" ] \
   && [ "$comment_hits" = "0" ] && [ "$outageok" = "0" ]; then
  # Candidate commits: accepted review rows (same trust filters as head
  # evidence — errored-attestation rows excluded here too, or an errored
  # ancestor review would seed a carry nothing ever reviewed;
  # min_state=approved accepts only APPROVED rows — a later
  # withdrawal by the same login is a standing CR and fails the gate before
  # carry could matter), newest-first, distinct, never the head itself,
  # bounded so a force-push-heavy PR cannot turn the walk into an API storm.
  carry_candidates="$(jq -r --arg sha "$HEAD_SHA" --arg author "$PR_AUTHOR" \
      --arg trusted "$TRUSTED_LOGINS_N" --arg minstate "$MIN_STATE" \
      --arg errmarks "$ERROR_PATTERNS" "$ATTESTATION_DEF"'
    ($trusted | split("\n") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $t
    | ($errmarks | split(";") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0)) | map(ascii_downcase)) as $mk
    | [ .[]
        | select(.state != "DISMISSED" and .state != "PENDING" and .user.login != $author)
        | select(($t | length) == 0 or (.user.login as $l | ($t | index($l)) != null))
        | select(not_errored_attestation($mk))
        | select($minstate != "approved" or .state == "APPROVED")
        | select((.commit_id // "") != "" and .commit_id != $sha)
      ]
    | sort_by(.submitted_at // "") | reverse | map(.commit_id)
    | reduce .[] as $c ([]; if (index($c) != null) then . else . + [$c] end)
    | .[0:10] | .[]' <<<"$reviews")" || {
    echo "::error::could not derive carry-forward candidates for PR #$PR_NUMBER" >&2
    exit 2
  }
  while IFS= read -r base; do
    [ -z "$base" ] && continue
    # The compare read is the ancestry check AND the delta: status "ahead"
    # means base is an ancestor of head; "identical" is the empty diff;
    # "behind"/"diverged" (superseded pre-force-push shas) are skipped. A
    # failed or zero-byte read is exit 2 like every other evidence read —
    # deciding carry from a truncated file list is the fail-open this
    # predicate exists to prevent.
    cmp_pages="$(gh_read "repos/$GH_REPO/compare/$base...$HEAD_SHA?per_page=100" --paginate)" || {
      echo "::error::could not read the comparison $base...$HEAD_SHA" >&2
      exit 2
    }
    if [ -z "$cmp_pages" ]; then
      echo "::error::comparison $base...$HEAD_SHA produced zero bytes (broken read)" >&2
      exit 2
    fi
    # THE FILES LIST RIDES PAGE ONE ONLY: compare pagination paginates the
    # COMMITS array — later pages are healthy objects that carry no files
    # (demanding one there, as the first kendex#1097 fix did, made every
    # multi-page compare exit 2 and hard-failed the predicate). So: page
    # one must be an object WITH a files array (a page-one without it is a
    # malformed or truncated response — defaulting to [] would carry an
    # approval from a broken read), later pages need only be objects, and
    # the classification reads files from page one alone. The 300-entry
    # API cap still refuses carry below (completeness unprovable at the
    # cap). Same exit-2 contract as every other evidence read.
    cmp="$(jq -s 'if (length > 0) and all(type == "object") and ((.[0].files | type) == "array")
                  then {status: (.[0].status // ""), files: .[0].files}
                  else error("malformed compare page") end' \
              <<<"$cmp_pages" 2>/dev/null)" || {
      echo "::error::could not merge the comparison pages for $base...$HEAD_SHA (non-object page, or page one without a files array)" >&2
      exit 2
    }
    cmp_status="$(jq -r .status <<<"$cmp")"
    case "$cmp_status" in
      identical)
        carried=1; carry_base="$base"; carry_kind="identical tree"
        break
        ;;
      ahead) ;;
      *) continue ;;
    esac
    cmp_file_count="$(jq '.files | length' <<<"$cmp")"
    if [ "$cmp_file_count" = "0" ]; then
      # Ahead by commits that change no file: the trees are equal.
      carried=1; carry_base="$base"; carry_kind="identical tree"
      break
    fi
    # The compare API caps the returned file list at 300 entries, so a list
    # AT the cap cannot prove the delta is complete — an omitted 301st file
    # could be code, and classifying only what was returned would be the
    # fail-open this predicate exists to prevent. The read itself is
    # healthy, so this refuses the carry (fresh review required) rather
    # than exit 2; older candidates' deltas are supersets, so stop walking.
    if [ "$cmp_file_count" -ge 300 ]; then
      echo "::warning::compare $base...$HEAD_SHA returned $cmp_file_count files (the API caps the list at 300): the delta cannot be proven complete; refusing carry-forward" >&2
      break
    fi
    # Path exclusions (kendex#1115): a delta that classifies carry-safe can
    # still change agent behavior — AGENTS.md and other instruction markdown
    # are "docs" by extension yet are obeyed mechanically, so a push editing
    # them deserves fresh review. Any changed file matching an exclusion glob
    # refuses the whole carry; older candidates' deltas are supersets, so
    # stop walking, and identical-tree carries never reach here. Matching is
    # shell-style via `case` ('*' crosses '/', so '*AGENTS.md' covers the
    # file at any depth) and never touches the filesystem. It is also line-
    # based, and a git filename MAY legally embed a newline: split across
    # lines such a name dodges a compound glob (`skills/*.md` misses
    # `skills/foo\nbar.md` read as two records) while the classifier carries
    # it intact — so any control character in any filename refuses the carry,
    # the completeness posture of the 300-entry cap. The vendored class reads
    # the same list and needs the same boundaries. A RENAME contributes BOTH
    # names (GitHub reports the source in .previous_filename): a rename out
    # of an excluded path relocates the very file the exclusion holds back.
    delta_files=""
    if [ -n "$CARRY_EXCLUDE" ] || rg_class_enabled vendored; then
      # \p{Cc} (the Unicode control category), NOT a class range written
      # with \uNNNN escapes: jq's Oniguruma mis-handles those inside [...]
      # (observed on jq 1.8.2: such a class matches plain ASCII names), and
      # a scan that matches everything would silently disable carry-forward
      # wherever exclusions are configured. The selftest's surgical
      # non-match case pins the false-positive direction.
      ctrl_hit="$(jq '[.files[] | ((.filename // ""), (.previous_filename // "")) | test("\\p{Cc}")] | any' <<<"$cmp")" || {
        echo "::error::could not scan the $base...$HEAD_SHA delta filenames for control characters" >&2
        exit 2
      }
      if [ "$ctrl_hit" = "true" ]; then
        echo "::warning::compare $base...$HEAD_SHA contains a filename with control characters: exclusion matching cannot be proven; refusing carry-forward" >&2
        break
      fi
      delta_files="$(jq -r '.files[] | (.filename // ""), (.previous_filename // "")' <<<"$cmp")" || {
        echo "::error::could not list the $base...$HEAD_SHA delta files for exclusion matching" >&2
        exit 2
      }
    fi
    if [ -n "$CARRY_EXCLUDE" ]; then
      excluded=""
      while IFS= read -r fn; do
        [ -z "$fn" ] && continue
        while IFS= read -r pat; do
          pat="$(printf '%s' "$pat" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
          [ -z "$pat" ] && continue
          case "$fn" in
            $pat) excluded="$fn"; break ;;
          esac
        done <<EOF_EXCL_PATS
$(printf '%s' "$CARRY_EXCLUDE" | tr ';' '\n')
EOF_EXCL_PATS
        [ -n "$excluded" ] && break
      done <<EOF_EXCL_FILES
$delta_files
EOF_EXCL_FILES
      if [ -n "$excluded" ]; then
        echo "::warning::compare $base...$HEAD_SHA touches '$excluded', matched by REVIEW_GATE_CARRY_FORWARD_EXCLUDE; refusing carry-forward (fresh evidence required)" >&2
        break
      fi
    fi
    # The vendored class (KEN-666): a delta file under a path the repository
    # committed in REVIEW_GATE_VENDORED_PATHS is kendex's own render, and
    # carries whatever its extension or status — under the trust model the
    # exclusions already rely on (the settings are read from the default
    # branch, so the PR under judgment cannot widen the set). Matching is
    # the exclusion matcher's, and an exclusion on the same path has already
    # refused above: the deny list outranks the class. A rename needs BOTH
    # names in the set; a source outside it, or none given at all, refuses.
    VENDORED_FILES=""
    if rg_class_enabled vendored; then
      while IFS= read -r fn; do
        [ -z "$fn" ] && continue
        while IFS= read -r pat; do
          [ -z "$pat" ] && continue
          case "$fn" in
            $pat) VENDORED_FILES="$VENDORED_FILES$fn
"; break ;;
          esac
        done <<EOF_VENDORED_PATS
$VENDORED_PATHS_N
EOF_VENDORED_PATS
      done <<EOF_VENDORED_FILES
$delta_files
EOF_VENDORED_FILES
    fi
    # Classify every changed file into an ENABLED class; anything else —
    # code lines, added/removed/renamed files under "comments", binary or
    # patch-less files, unknown extensions — refuses the whole carry.
    carry_ok="$(jq -r --arg classes "$CARRY_FORWARD" --arg vendored "$VENDORED_FILES" '
      ($classes | split("[;|]"; "") | map(gsub("^\\s+|\\s+$"; "")) | map(select(length > 0))) as $cl
      | def comment_token:
          if test("\\.(sh|bash|py|rb|toml|yml|yaml)$") then "#"
          elif test("\\.(js|mjs|cjs|ts|tsx|jsx|rs|go|c|h|cc|cpp|hpp|java|kt|swift)$") then "//"
          else null end;
      ($vendored | split("\n") | map(select(length > 0))) as $vf
      | [ .files[]
        | . as $f
        | (.filename // "") as $fn
        | if ($vf | index($fn)) != null and (($f.previous_filename // "") as $p | ($f.status != "renamed" and $p == "") or ($p != "" and ($vf | index($p)) != null))
          then "vendored"
          elif (($cl | index("docs")) != null)
             and ($f.status != "renamed")
             and (($f.previous_filename // "") == "")
             and ($fn | test("\\.(md|markdown)$"))
          then "docs"
          elif (($cl | index("comments")) != null)
               and ($f.status == "modified")
               and (($f.patch // "") != "")
               and (($fn | comment_token) != null)
          then ( ($fn | comment_token) as $tok
                 | ($f.patch | split("\n")
                    | map(select(test("^[+-]")))
                    | map(sub("^[+-][[:space:]]*"; ""))
                    | map(select(length > 0))) as $chg
                 | if ($chg | all(startswith($tok) and (startswith("#!") | not)))
                   then "comments" else "refuse" end )
          else "refuse" end
      ] | all(. != "refuse")' <<<"$cmp")" || {
      echo "::error::could not classify the $base...$HEAD_SHA delta" >&2
      exit 2
    }
    if [ "$carry_ok" = "true" ]; then
      carried=1; carry_base="$base"; carry_kind="carry-safe delta ($CARRY_FORWARD)"
    fi
    break
  done <<EOF_CARRY
$carry_candidates
EOF_CARRY
fi

# A genuine GraphQL failure must NOT fall through as unresolved threads — fail
# loudly instead. Thread pages are WALKED and summed (100 per page, 20-page/
# 2000-thread bound); past the bound, or on a truthy hasNextPage whose cursor
# cannot advance, the count reports "overflow" and fails closed to
# threads-open. Same posture for a thread node whose isResolved is not a
# boolean ("malformed"): null/missing nodes must never count as resolved —
# that direction is a false approval on a merge gate.
#
# REVIEW_GATE_THREADS=off skips this read ENTIRELY and the predicate never
# emits threads-open: on repos whose thread hygiene is a server-side
# zero-bypass ruleset (required_review_thread_resolution), the CI-side term
# is a latency optimization that costs a GraphQL read per evaluation for a
# verdict the merge-time gate already enforces — and forces every caller to
# reinterpret threads-open in its own adapter. The narrowing is bounded:
# only the thread term is disabled; evidence and changes-requested still
# fail closed exactly as before.
unresolved=0
untracked=0
unreasoned=0
if [ "$THREADS_MODE" = "enforce" ]; then
# A thread's disposition is its newest non-bot comment that is a Fixed in
# <sha>/Declined: reply or carries a track-word; other comments never move
# it. It is an untracked claim when it is not such a reply and names no
# issue (ABC-123 or #123); resolving the thread does not clear it, since the
# claimant is also the resolver. Bot comments are exempt (they quote each
# other); a missing comments field reads as none. A thread past 50 comments
# cannot be fully read in this page shape, so it fails closed as malformed.
#
# The reply forms are spelled once, above both reductions, so a change to
# what a decline is reaches both. They read different sets on purpose.
# `disposition` is the canonical colon form, and the untracked-claim term is
# the only thing it may mean: widening it there would let "Declined under the
# cap, tracked separately" clear a tracking claim naming no issue, which
# loosens a merge gate. `declined` is wider, matching any reply opening with
# the word, because the replies the second term exists to catch had no colon.
#
# A decline is a disposition only when it says what it disproves, so the
# second reduction subtracts. `reason_left` strips the reply form, the
# non-reason tokens and the words carrying no content alone; a reply whose
# reason strips to nothing is counted, which is what leaves a token INSIDE a
# real reason harmless. Widen this list from tests/corpus/, never alone.
# Punctuation normalization keeps every letter and number, not only ASCII:
# the word lists are ASCII, so a reason written in another script survives
# whole, and surviving text is residue, which is a stated reason.
#
# Tracker ids go first, while each is still one token and still uppercase:
# punctuation normalization would otherwise leave the letters behind, and
# `Declined: KEN-881` would read as a stated reason of "ken". The shape is
# the untracked-claim term's, so the two cannot disagree about what an id is.
t_threads_page_jq='def disposition: test("^\\s*(fixed in [0-9a-f]{7,40}\\b|declined:)"; "i");
  def declined: test("^\\s*declined\\b"; "i");
  def tracking: test("(?i)\\btrack(ed|ing|s)?\\b");
  def replies: [(.comments.nodes // [])[] | select((.author.__typename // "User") != "Bot") | (.body // "")];
  def standing: [replies[] | select(disposition or tracking)] | last // empty;
  def standing_decline: [replies[] | select(disposition or declined or tracking)] | last // empty;
  def reason_left:
    sub("(?i)^\\s*declined\\b"; "")
    | gsub("[A-Z][A-Z0-9]+-[0-9]+|#[0-9]+"; " ")
    | ascii_downcase
    | gsub("[^\\p{L}\\p{N}]+"; " ")
    | gsub("\\b(frozen|freezes?|freezing|cap|capped|round [0-9]+|round|rounds|tests?|suites?|pass|passes|passed|passing|green|count|checks?|checking|ci|builds?|building|built|compiles?|compiled|pipelines?|lints?|linter|linting|workflows?|jobs?|typechecks?|validation|coverage|everything|fine|clean|out of scope|scope|pre existing|preexisting|existing|flagged separately|flagged|separately|as discussed|discussed|noted|won ?t ?fix|false positives?|by design|design|not applicable|n a|actionable|no change|nothing to do|later|known|intentional|deliberate|works as intended|as intended|intended|owners?|instruction(s|ed)?|previous|pushe[sd]?|push|last|head|disposition(ed|s)?|findings?|fix(es|ed)?|track(s|ed|ing|er)?|filed|filing|logged)\\b"; " ")
    | gsub("\\b[0-9a-f]{7,40}\\b"; " ")
    | gsub("\\b[0-9]+\\b"; " ")
    | gsub("\\b(a|an|the|this|that|these|those|it|its|is|are|was|were|be|been|for|in|on|at|to|of|and|or|but|so|we|i|you|your|pr|prs|here|now|all|full|whole|entire|complete|still|already|yes|no|not|do|does|did|has|have|had|under|per|within|as|after|rather|than|see|every|set|s|t)\\b"; " ")
    | gsub("^ +| +$"; "");
  if ((.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage | type) != "boolean")
    or ([.data.repository.pullRequest.reviewThreads.nodes[] | select((.isResolved | type) != "boolean")] | length) > 0
  then "malformed"
  elif ([.data.repository.pullRequest.reviewThreads.nodes[] | select(.comments.pageInfo.hasNextPage == true)] | length) > 0
  then "malformed"
  else ([.data.repository.pullRequest.reviewThreads.nodes[] | select(.isResolved == false)] | length | tostring)
    + " " + ([.data.repository.pullRequest.reviewThreads.nodes[]
        | standing
        | select(disposition | not)
        | select(test("([A-Z][A-Z0-9]+-[0-9]+|#[0-9]+)\\b") | not)] | length | tostring)
    + " " + ([.data.repository.pullRequest.reviewThreads.nodes[]
        | standing_decline
        | select(declined)
        | select(reason_left == "")] | length | tostring)
    + " " + (.data.repository.pullRequest.reviewThreads.pageInfo.hasNextPage | tostring)
    + " " + (.data.repository.pullRequest.reviewThreads.pageInfo.endCursor // "END")
  end'
t_cursor=""
t_pages=0
while :; do
  t_pages=$((t_pages + 1))
  if [ "$t_pages" -gt 20 ]; then
    unresolved="overflow"
    break
  fi
  if [ -n "$t_cursor" ]; then
    t_page="$(gh_read graphql \
      -f query='query($owner:String!,$repo:String!,$number:Int!,$after:String){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewThreads(first:100,after:$after){pageInfo{hasNextPage endCursor} nodes{isResolved comments(first:50){pageInfo{hasNextPage} nodes{body author{__typename}}}}}}}}' \
      -F owner="${GH_REPO%/*}" -F repo="${GH_REPO#*/}" -F number="$PR_NUMBER" -f after="$t_cursor" \
      --jq "$t_threads_page_jq")" || {
      echo "::error::could not read review threads" >&2
      exit 2
    }
  else
    t_page="$(gh_read graphql \
      -f query='query($owner:String!,$repo:String!,$number:Int!){repository(owner:$owner,name:$repo){pullRequest(number:$number){reviewThreads(first:100){pageInfo{hasNextPage endCursor} nodes{isResolved comments(first:50){pageInfo{hasNextPage} nodes{body author{__typename}}}}}}}}' \
      -F owner="${GH_REPO%/*}" -F repo="${GH_REPO#*/}" -F number="$PR_NUMBER" \
      --jq "$t_threads_page_jq")" || {
      echo "::error::could not read review threads" >&2
      exit 2
    }
  fi
  if [ -z "$t_page" ]; then
    # A successful call that produced zero bytes is a broken read, not a
    # verdict input — same read-failure contract as a failed gh call
    # (pr-watch parity), never an authoritative threads-open.
    echo "::error::review thread read produced zero bytes (broken read)" >&2
    exit 2
  fi
  if [ "$t_page" = "malformed" ]; then
    unresolved="malformed"
    break
  fi
  t_count="${t_page%% *}"
  t_rest="${t_page#* }"
  t_claim="${t_rest%% *}"
  t_rest="${t_rest#* }"
  t_bare="${t_rest%% *}"
  t_rest="${t_rest#* }"
  t_next="${t_rest%% *}"
  t_cursor_next="${t_rest#* }"
  case "$t_count$t_claim$t_bare" in
    '' | *[!0-9]*)
      unresolved="malformed"
      break
      ;;
  esac
  unresolved=$((unresolved + t_count))
  untracked=$((untracked + t_claim))
  unreasoned=$((unreasoned + t_bare))
  [ "$t_next" = "true" ] || break
  if [ "$t_cursor_next" = "END" ] || [ -z "$t_cursor_next" ] || [ "$t_cursor_next" = "$t_cursor" ]; then
    # hasNextPage with no ADVANCING cursor (missing, or identical to the
    # page just read): cannot verify the remainder — fail closed now
    # instead of burning the page budget on re-reads of the same page.
    unresolved="overflow"
    break
  fi
  t_cursor="$t_cursor_next"
done
fi

echo "PR #$PR_NUMBER head $HEAD_SHA: reviews=$got clean-analysis=$check comment-form=$comment_hits outage-marker=$outageok carried=$carried changes-requested=$cr unresolved-threads=$unresolved untracked-claims=$untracked unreasoned-declines=$unreasoned (threads=$THREADS_MODE)" >&2

if [ "$cr" != "0" ]; then
  echo "verdict=changes-requested detail=standing review changes requested (persists across pushes until re-approval or dismissal)"
elif [ "$untracked" != "0" ]; then
  echo "verdict=untracked-claim detail=$untracked tracking claim(s) name no issue — write Declined: <reason>, or add the tracker/#id"
elif [ "$unreasoned" != "0" ]; then
  echo "verdict=unreasoned-decline detail=$unreasoned decline(s) name no mechanism — give a passing state, a false premise, or an excluded class with the fact that puts it there"
elif [ "$got" = "0" ] && [ "$check" = "0" ] && [ "$comment_hits" = "0" ] && [ "$outageok" = "0" ] && [ "$carried" = "0" ]; then
  # One line, no source list. Which sources could open the gate is the repo's
  # own settings (references/settings.md), not a status description GitHub
  # keeps 140 characters of.
  echo "verdict=awaiting detail=no review evidence at $HEAD_SHA yet"
elif [ "$unresolved" != "0" ]; then
  echo "verdict=threads-open detail=$unresolved unresolved review thread(s)"
elif [ "$carried" = "1" ]; then
  echo "verdict=approved detail=review evidence at $carry_base carried to head across a $carry_kind"
elif [ "$outageok" != "0" ] && [ "$got" = "0" ] && [ "$check" = "0" ] && [ "$comment_hits" = "0" ]; then
  # The override is SUBSTITUTING for missing evidence (its only sanctioned
  # use), so the attested reason is the verdict — it belongs in the gate
  # status, where a reader sees why this PR merged without a review.
  echo "verdict=approved detail=operator override ($OUTAGE_CONTEXT): $outage_reason"
else
  echo "verdict=approved detail=reviewed at head with no unresolved threads"
fi
