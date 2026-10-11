#!/usr/bin/env bash
# check-review-replies — read one pull request's review replies live and judge
# what they say. GitHub's approval and thread resolution prove that a reply
# exists, never what it says, and a reply can change without a push, so this
# reads the current replies on every call. Read-only: it makes GET requests
# and GraphQL queries through the shared readers in lib/github-api.sh and
# writes nothing. A caller runs it as `github.sh check-review-replies <N>`,
# which loads the project env and selects the token first, as orch
# submit-pr.md's final review gate does. pr-merge's readiness check runs this
# file directly and inherits the environment the same router set for it. The
# stdout lines below are the protocol pr-merge reads; the contract is
# print_usage.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

print_usage() {
  cat <<'EOF'
Usage: check-review-replies <PR_NUMBER>

Reads the pull request's review threads, its review bodies at the current
head and, when a review body holds findings, its PR-level comments. The
repository is GH_REPO, else the checkout's GitHub remote. Writes nothing.

Rules (each fails on its own):
  untracked-claim     A thread's standing reply claims tracking and names
                      no issue (KEN-123, #123).
  unreasoned-decline  A thread's standing decline names no mechanism.
  thread-replies      A thread holds more comments than one read returns,
                      so its replies cannot be judged.
  suppressed-findings A review at the head lists findings in its body under
                      `Suppressed comments (N)` or `Previously missed (N)`
                      (a markdown heading or a <details> summary), and no
                      counted reply answers each one. A ccr-overview-v2
                      `Changes recommended` verdict also counts as one
                      body finding, keyed by `review:<REST review id>`.

Whose words count:
  A finding source, a review body, counts when its author is a bot or has
  author association OWNER, MEMBER or COLLABORATOR, and is not the PR
  author. A reply counts when its author is the PR author or the identity
  this check runs as (the token's GraphQL viewer), whatever its actor type,
  or has one of those associations. An account is its numeric id (REST
  user.id, GraphQL databaseId), never its login: an account named like an
  app is not the app. Anyone else's review or reply is read as if it were
  not there.

A thread's first comment is the finding it opens, never a reply. Its
standing reply is its newest counted later comment that is
`Fixed in <sha>`, `Declined: ...` or carries a track word. A decline
opening with the word without the colon is still a decline for
unreasoned-decline. What a decline must say is reviewer conduct:
.agents/skills/orch/references/finding-disposition.md § Decision flow.

A body finding is answered by a counted PR-level comment whose first
non-blank line opens `Dispositions at <sha>`, <sha> being 7 to 40 hex
characters the current head starts with, and a line per finding opening
with its `file:line` or `review:<ID>` token, bare, bold or backticked,
then the reply:

  Dispositions at 1a2b3c4:
  `src/a.ts:12` - Declined: the caller rejects the empty case first.
  `src/b.ts:40` - Tracked: KEN-123
  review:123456789 - Fixed in 1a2b3c4

The reply is read by the thread grammar, so a label-only decline or a
tracking claim naming no issue answers nothing. A comment bound to an
earlier head answers nothing at this one, and so does a comment with any
other line opening `Dispositions at <sha>`, fenced or not. The newest line
naming an entry decides.

Output, stdout:
  review-replies: pass head=<sha>
  review-replies: fail head=<sha>
followed on fail by one line per failing rule, and for an unanswered body
finding one line per entry:
  untracked-claim count=<n>
  unreasoned-decline count=<n>
  thread-replies state=truncated threads=<n>
  suppressed-findings count=<n>
  suppressed-findings state=unparsed
  suppressed-findings state=mismatch sections=<n>
  suppressed-entry <file:line|review:ID> (one per unanswered finding)
`sections` counts the findings sections, across every review body read,
whose own count differs from the entries parsed under that section.
stderr explains each line. On `suppressed-findings count=<n>`, stderr
also names, once per login, each author who does not count and wrote a
head-bound disposition comment with a line naming any finding a review body
lists, answered or not:
  suppressed-findings: ignored-author login=<login>
A thread reply that does not count adds no line.

Exit codes:
  0  every rule passes
  1  a rule fails
  2  usage error, or a read failed or named no account id for the PR
     author or the viewer: no verdict. The first stderr line is
     `check-review-replies: <key> pr=<n>`; take no action on it.
EOF
}

case "$#:${1:-}" in
  1:-h | 1:--help)
    print_usage
    exit 0
    ;;
esac

# shellcheck source=../lib/github-api.sh
source "$SCRIPT_DIR/../lib/github-api.sh"

# The one place each refusal's text is written. KEY is the stable first
# token, VALUE the thing acted on.
refuse() { # KEY VALUE DETAIL
  printf 'check-review-replies: %s pr=%s\n  %s\n' "$1" "$2" "$3" >&2
  exit 2
}

# The shared readers report a failure on stderr. It is held here and replayed
# under the refusal's key line, so the key line stays the first one printed.
READ_ERR=""
reader_said() {
  local said
  said=$(jq -r '.error // empty' "$READ_ERR" 2>/dev/null) || said=""
  [ -n "$said" ] || said=$(grep -m 1 -v '^[[:space:]]*$' "$READ_ERR") || said="no diagnostic"
  printf '%s' "$said"
}

# THE REPLY FORMS, spelled once above both reductions that read one: the two
# thread rules, and the suppressed-finding disposition read further down,
# which answers a body finding in a PR comment because no thread carries it.
# A change to what a decline is reaches all three. They read different sets
# on purpose.
# `disposition` is the canonical colon form, and the untracked-claim rule is
# the only thing it may mean: widening it there would let "Declined under the
# cap, tracked separately" clear a tracking claim naming no issue. `declined`
# is wider, matching any reply opening with the word, because the replies the
# second rule exists to catch had no colon.
#
# A decline is a disposition only when it says what it disproves, so the
# second reduction subtracts. `reason_left` strips the reply form, the
# non-reason tokens and the words carrying no content alone; a reply whose
# reason strips to nothing is counted, which is what leaves a token INSIDE a
# real reason harmless. Widen this list from ../tests/corpus/, never alone.
# Punctuation normalization keeps every letter and number, not only ASCII:
# the word lists are ASCII, so a reason written in another script survives
# whole, and surviving text is residue, which is a stated reason.
#
# Tracker ids go first, while each is still one token and still uppercase:
# punctuation normalization would otherwise leave the letters behind, and
# `Declined: KEN-881` would read as a stated reason of "ken". The shape is
# `names_issue`'s, the one spelling of a tracker id, so no reduction can
# disagree about what an id is.
#
# Two NAME strips ride after BOTH word lists, and both are positional rather
# than a vocabulary: no set of names is read or listed anywhere. A count
# takes the non-space run immediately in front of it, because that run is
# what was counted: "lifecycle 104/104" is one phrase and neither half says
# anything about the finding. A slash-joined token is a path, and a path is a
# name: "tools/guard" goes whole.
#
# BOTH WORD LISTS RUN FIRST, and that is load-bearing. A strip eats a whole
# run, so in front of a list it eats the TAIL of a phrase and strands the
# head: "out of scope 3/3" leaves "out" and "lifecycle is green at 104/104"
# leaves "lifecycle", and a decline this rule exists to catch passes by
# appending a count. A word the rule deletes never shields the name behind
# it; each list has its own section of ../tests/corpus/declines-unreasoned.txt
# and its own must-fail probe.
#
# The punctuation pass therefore runs ahead of both lists, so the lists read
# normalized text; but it HOLDS a dot, underscore or hyphen sitting between
# two alphanumerics, so a name is still one run when the strips look and
# "merge-queue 12/12" does not leave "merge". Every multi-word list entry
# accepts those separators for the same reason, and what the strips leave is
# flattened afterwards. Widening that hold to the apostrophe would break
# "won't fix", which the lists read as "won t fix".
#
# Both lists are bounded on ALPHANUMERICS rather than on \b for the same
# reason, so a held separator is a boundary for them as it is for the
# strips: `\b` reads `_` as a word character. `word_strip` spells that
# boundary by consuming the reason in run-aligned pieces (a separator run, a
# listed word plus the one character ending it, or an unlisted run), so every
# match starts where the last ended, at a run start. The space padded onto
# the END is how a word in the last position meets that one-character
# boundary; the closing trim takes both pads back.
#
# Position is the only thing that separates a suite name from prose: both
# are ordinary English, so any SET of names is a word ban on whatever the
# repo happens to name its files after, and "the guard refuses this path" is
# a real reason written in three of them. What position does not reach is
# pinned in ../tests/corpus/declines-known-limit.txt: a name standing after
# the count, a count not spelled N/N, a path whose own segments are listed
# words, and a slash written inside a multi-word entry.
REPLY_FORMS_DEF='def disposition: test("^\\s*(fixed in [0-9a-f]{7,40}\\b|declined:)"; "i");
  def declined: test("^\\s*declined\\b"; "i");
  def tracking: test("(?i)\\btrack(ed|ing|s)?\\b");
  def names_issue: test("([A-Z][A-Z0-9]+-[0-9]+|#[0-9]+)\\b");
  def word_strip($list):
    gsub("(?<s>[^\\p{L}\\p{N}]+)|(?<w>" + $list + ")(?<b>[^\\p{L}\\p{N}])|(?<r>[\\p{L}\\p{N}]+)";
      if .w != null then " " + .b elif .s != null then .s else .r end);
  def reason_left:
    sub("(?i)^\\s*declined\\b"; "")
    | gsub("[A-Z][A-Z0-9]+-[0-9]+|#[0-9]+"; " ")
    | ascii_downcase
    | gsub("(?<w>[\\p{L}\\p{N}]+([._-][\\p{L}\\p{N}]+)*)|(?<k>/)|[\\s\\S]"; "\(.w // .k // " ")")
    | " " + . + " "
    | word_strip("frozen|freezes?|freezing|cap|capped|round[ ._-][0-9]+|round|rounds|tests?|suites?|pass|passes|passed|passing|green|count|checks?|checking|ci|runs?|builds?|building|built|compiles?|compiled|pipelines?|lints?|linter|linting|workflows?|jobs?|typechecks?|validation|coverage|everything|fine|clean|out[ ._-]of[ ._-]scope|scope|pre[ ._-]existing|preexisting|existing|flagged[ ._-]separately|flagged|separately|as[ ._-]discussed|discussed|noted|won[ ._-]?t[ ._-]?fix|false[ ._-]positives?|by[ ._-]design|design|not[ ._-]applicable|n[ /._-]a|actionable|no[ ._-]change|nothing[ ._-]to[ ._-]do|later|known|intentional|deliberate|works[ ._-]as[ ._-]intended|as[ ._-]intended|intended|owners?|instruction(s|ed)?|previous|pushe[sd]?|push|last|head|disposition(ed|s)?|findings?|fix(es|ed)?|track(s|ed|ing|er)?|filed|filing|logged")
    | word_strip("a|an|the|this|that|these|those|it|its|is|are|was|were|be|been|for|in|on|at|to|of|and|or|but|so|we|i|you|your|pr|prs|here|now|all|full|whole|entire|complete|still|already|yes|no|not|do|does|did|has|have|had|under|per|within|as|after|rather|than|see|every|set|s|t")
    | gsub("\\S+\\s+[0-9]+\\s*/\\s*[0-9]+"; " ")
    | gsub("[a-z0-9][a-z0-9._-]*(/[a-z0-9][a-z0-9._-]*)+"; " ")
    | gsub("[/._-]"; " ")
    | gsub("\\b[0-9a-f]{7,40}\\b"; " ")
    | gsub("\\b[0-9]+\\b"; " ")
    | gsub("^ +| +$"; "");
  # The two rules over one reply, composed here for every reader: a tracking
  # claim that is no disposition and names no issue, and a decline whose
  # reason strips to nothing.
  def untracked_claim: tracking and (disposition | not) and (names_issue | not);
  def unreasoned_decline: declined and (reason_left == "");
'

# WHO COUNTS, spelled once for every reader: the thread rules, the review
# body scan and the disposition read. On a public repository an account
# with no standing can review and reply; read as the author's, its
# `Fixed in` would clear a failing reply, and read as a reviewer's, its
# review body would block the merge. GitHub's author association is the
# repository role the platform itself reports on every comment and review.
#
# A finding source counts when it is a bot or a repository member, and is
# not the PR author: a review bot such as Copilot reviews with association
# NONE, and an installed app is the only bot that can post one. A reply
# counts when it is the PR author's or the viewer's, whatever its actor
# type, or a repository member's. The viewer is the identity this check
# reads as, which the router selected and post-reply and post-comment
# answer under: a lane answers a PR a person opened as its GitHub App, a
# Bot with association CONTRIBUTOR or NONE, and its replies may also be
# posted under a maintainer's own login.
#
# AN ACCOUNT IS ITS NUMERIC ID, the one key every identity test compares:
# REST `user.id`, GraphQL `databaseId`, which name the same account on both
# surfaces. A login is a name anyone can register: a User account named like
# an app's slug is not the app, whatever case or [bot] suffix either spelling
# carries. $author and $viewer are accounts, `{id, login}`; the login rides
# along only as the name a diagnostic prints. An actor with no id (a deleted
# account) is nobody's. Each surface spells the actor its own way, so each
# has an accessor and the rules read only the normalized actor.
AUTHOR_TRUST_DEF='def rest_actor: {id: (.user.id // null), login: (.user.login // ""), bot: ((.user.type // "") == "Bot"), association: (.author_association // "")};
  def graphql_actor: {id: (.author.databaseId // null), login: (.author.login // ""), bot: ((.author.__typename // "") == "Bot"), association: (.authorAssociation // "")};
  def member: .association == "OWNER" or .association == "MEMBER" or .association == "COLLABORATOR";
  def same_account($account): .id != null and .id == $account.id;
  def finding_source($author): (same_account($author) | not) and (.bot or member);
  def reply_source($author; $viewer): same_account($author) or same_account($viewer) or member;
'

# The two thread rules, over every review thread node the reader returned:
# `truncated untracked unreasoned`. A thread's first comment is the finding
# it opens: a member's finding that says "tracked" is not a claim anyone
# answered with. Only the later comments are replies; the truncation test
# still counts every node. A thread's disposition is its newest counted reply
# that is a Fixed in <sha>/Declined: reply or carries a track-word; other
# comments never move it. Resolving the thread does not
# clear an untracked claim, since the claimant is also the resolver. A
# comment that does not count is skipped: a review bot quoting a reply is
# not one. A thread holding more comments than the read returned cannot be
# judged, so it is counted as truncated and fails.
THREAD_RULES_JQ="$REPLY_FORMS_DEF$AUTHOR_TRUST_DEF"'
  def replies: [.comments.nodes[1:][] | select(graphql_actor | reply_source($author; $viewer)) | (.body // "")];
  def standing: [replies[] | select(disposition or tracking)] | last // empty;
  def standing_decline: [replies[] | select(disposition or declined or tracking)] | last // empty;
  def readable: (.comments.nodes | type) == "array"
    and (.comments.totalCount | type) == "number"
    and .comments.totalCount <= (.comments.nodes | length);
  if type != "array" then error("thread nodes are not an array") else . end
  | "\([.[] | select(readable | not)] | length)"
    + " " + ([.[] | select(readable) | standing | select(untracked_claim)] | length | tostring)
    + " " + ([.[] | select(readable) | standing_decline | select(unreasoned_decline)] | length | tostring)'

# The suppressed-finding scan and the disposition read identify a finding by
# EXACT STRING EQUALITY between a token the scan extracted and a token the
# author's comment carries. Anything either one strips or admits, the other
# must too, so each such rule is spelled ONCE here and passed into both.
#
# display_strip drops what a rendered review carries and neither surface
# means: a CR from a body written on Windows, and the zero-width space Copilot
# writes into a path to break it across lines for display. A character
# dropped on one side and kept on the other is an entry no reply can ever
# answer, because the difference is invisible in both surfaces.
SUPP_NORMALIZE_DEF='def display_strip: gsub("\r"; "") | gsub("\u200b"; "");
'
# entry_marks is the decoration the review body wraps an entry token in. The
# scan reads a line so decorated and the disposition read answers a reply so
# decorated: a mark only one of them knew is an entry the author cannot clear.
SUPP_ENTRY_DEF='def entry_marks: ["**", "`"];
'
# A reviewer that judges a finding to be in code the current diff did not
# change writes it into the review BODY, under a `Suppressed comments (N)` or
# `Previously missed (N)` section, and posts no review comment, so no thread
# carries it and GitHub's thread resolution never sees it.
#
# The parse is line-anchored and refuses in every direction it cannot read:
# a title whose count is not a number (`unparsed`) and a count disagreeing
# with the entries extracted under it (`mismatch`). The count is judged PER
# SECTION: a section that under-parses and another that over-parses would
# cancel in a sum, leaving a finding no entry names. Known limit: a body that
# quotes the title at the start of a line counts as a real block. That
# direction is visible and clears with the next review; the opposite is a
# silent merge.
#
# The block ends at the next heading of any level, or at the `</details>`
# that closes the section the title opened, so the `- **Files reviewed:**`
# trailer Copilot writes after the entries is outside it. The close is
# DEPTH-COUNTED because the summary-titled shape wraps each entry in its own
# `<details>`: ending at the first `</details>` would keep one entry and drop
# the rest. Lines inside a fenced snippet are skipped: the code a reviewer
# pastes under an entry is full of `#` comment lines, and one of those read as
# a heading would end the block. The fence records its opening delimiter's
# character and length and closes only on a run of the same character at that
# length or longer with nothing after it, per CommonMark.
#
# THE SECTION TITLE IS THE SENTINEL, read whatever the fence state says. Both
# title arms run before the fence arm and close any fence they find open, so
# no run of fence-looking lines EARLIER in the body can swallow the block that
# follows. It errs toward finding a block, never toward missing one.
#
# A section closes where the block ends, at the next title, and at the end of
# the body. A section whose title carries no count is the unparsed rule's and
# has no count to compare.
#
# `capture` emits NOTHING on a non-match, not null, and a reduce update that
# emits nothing sets the accumulator to null. Hence the `// null`.
SUPP_SCAN_DEF='
    # The sentinel text of a line, whichever surface carries it: a markdown
    # heading, or the <summary> of a <details> section. ONE extractor feeds
    # both title tests rather than a regex per spelling. Inner tags go on the
    # summary arm: a section title arrives wrapped in <strong>.
    def block_title:
      if test("^#{1,6}[ \t]+") then sub("^#{1,6}[ \t]+"; "")
      elif test("^<summary[^>]*>.*</summary>[ \t]*$")
      then sub("^<summary[^>]*>"; "") | sub("</summary>[ \t]*$"; "") | gsub("<[^>]*>"; "")
      else "" end
      | sub("^[ \t]+"; "") | sub("[ \t]+$"; "");
    def close_section:
      if .section != null and .section.declared != .section.parsed then .mismatched += 1 else . end
      | .section = null;
    # The entry token a whole line carries, or nothing. A line is one of the
    # shared entry_marks, the token, the SAME mark again, and trailing blanks:
    # `path:line`, where the line number is what makes a token and the path may
    # hold any character but a mark. Iterating the list rather than branching
    # per decoration keeps this in step with the disposition read, which
    # iterates the same list.
    def entry_token:
      sub("[ \t]+$"; "") as $l
      | first(
          entry_marks[]
          | . as $d
          | ($d | length) as $dn
          | select(($l | length) > (2 * $dn))
          | select(($l | startswith($d)) and ($l | endswith($d)))
          | $l[$dn:(($l | length) - $dn)]
          | select(test("^[^*`]+:[0-9]+$")));
    # Copilot uses a status symbol on overview verdicts. Older overview
    # headings such as "Needs a closer look" introduce counted sections,
    # rather than a verdict. Generic headings must not become verdicts.
    def overview_verdict:
      if contains("<!-- ccr-overview-v2 -->") then
        [split("\n")[] | block_title
          | select(test("^(\\p{So}\\p{M}*[ \t]+|Approved$|Changes recommended$)"))
          | sub("^[^\\p{L}\\p{N}]+"; "")][0] // ""
      else "" end;
    def suppressed_scan($id):
      ((. // "") | display_strip) as $body
      | ($body | overview_verdict) as $verdict
      | reduce ($body | split("\n"))[] as $l
        ({entries: 0, unparsed: 0, mismatched: 0, section: null, inblock: false, depth: 0, fchar: "", flen: 0, list: []};
          ($l | capture("^[ \t]{0,3}(?<f>`{3,}|~{3,})(?<rest>.*)$") // null) as $fx
          | ($l | block_title) as $title
          | (($l | entry_token) // "") as $entry
          | if ($title | test("^(Suppressed comments|Previously missed)[ \t]*\\([0-9]+\\)$")) then
            close_section
            | .section = {declared: ($title | capture("\\((?<n>[0-9]+)\\)") | .n | tonumber), parsed: 0}
            | .inblock = true | .depth = 0 | .fchar = "" | .flen = 0
          elif ($title | test("^(Suppressed comments|Previously missed)([ \t]|$)")) then
            close_section | .unparsed += 1 | .inblock = true | .depth = 0 | .fchar = "" | .flen = 0
          elif .fchar != "" then
            if ($fx != null and ($fx.f[0:1] == .fchar)
                and (($fx.f | length) >= .flen) and ($fx.rest | test("^[ \t]*$")))
            then .fchar = "" | .flen = 0
            else . end
          elif $fx != null then
            .fchar = ($fx.f[0:1]) | .flen = ($fx.f | length)
          elif ($l | test("^<details([ \t>]|$)")) then
            if .inblock then .depth += 1 else . end
          elif ($l | test("^</details>")) then
            if .inblock and .depth > 0 then .depth -= 1
            else close_section | .inblock = false | .depth = 0 end
          elif ($l | test("^#{1,6}[ \t]")) then
            close_section | .inblock = false | .depth = 0
          elif .inblock and $entry != "" then
            .entries += 1 | .list += [$entry]
            | if .section != null then .section.parsed += 1 else . end
          else . end)
        | close_section
        | if $verdict == "Changes recommended" then
            .entries += 1 | .list += ["review:\($id)"]
          elif $verdict == "" or $verdict == "Approved" then .
          else .unparsed += 1 end;
'
# The scan reads every submitted review at the head from a finding source:
# `entries unparsed mismatched`, then one entry token per line. A dismissed
# review no longer stands and a pending one was never submitted.
SUPP_ROWS_JQ="$SUPP_NORMALIZE_DEF$SUPP_ENTRY_DEF$SUPP_SCAN_DEF$AUTHOR_TRUST_DEF"'
    [ .[]
      | select(.commit_id == $sha and .state != "DISMISSED" and .state != "PENDING")
      | select(rest_actor | finding_source($author))
      | .id as $id | (.body // "") | suppressed_scan($id)
    ] as $rows
    | (([$rows[] | .entries] | add) // 0) as $entries
    | (([$rows[] | .unparsed] | add) // 0) as $unparsed
    | (([$rows[] | .mismatched] | add) // 0) as $mismatched
    | "\($entries) \($unparsed) \($mismatched)\n" + ([$rows[] | .list[]] | join("\n"))'

# THE DISPOSITION READ: a body finding is answered the way a thread finding
# is. No thread carries it, so the reply is a PR comment by an author whose
# reply counts, that binds this head and opens a line with the entry's own `file:line` token,
# which this output prints bare and the review body prints bold or
# backticked, followed by the reply. EVERY SPELLING IS READ and NONE is the
# anchor: the token's equality with a scanned entry identifies the finding.
# The reply is judged by the SHARED reply forms: a reply that is neither a
# disposition nor a tracking claim, a tracking claim naming no issue, and a
# decline whose reason strips to nothing all leave the entry standing. Prints
# the count left followed on its line by the logins of head-bound comments
# naming an entry whose author does not count, then one entry per line.
#
# THE COMMENT BINDS THE HEAD BY SAYING SO: its first non-blank line opening
# `Dispositions at <sha>`. Nothing else in it binds. A sha-shaped run
# asserts no commit (the one a `Fixed in <sha>` names, a tracking claim's
# `#1234567`, a path that opens with hex), yet while any of them could bind,
# a comment written for an earlier head bound itself to this one and carried
# its other replies across a diff no reviewer re-read. A marker cannot be
# written by accident.
SUPP_DISPOSITION_JQ="$SUPP_NORMALIZE_DEF$SUPP_ENTRY_DEF$REPLY_FORMS_DEF$AUTHOR_TRUST_DEF"'
      def unanswered: ((disposition or tracking) | not) or untracked_claim or unreasoned_decline;
      # The sha a line opening `Dispositions at <sha>` names, or null.
      def marker_sha($floor):
        [ capture("^[ \t]*dispositions[ \t]+at[^0-9a-fA-F]*(?<c>[0-9a-fA-F]{" + $floor + ",40})"; "i")
          | .c | ascii_downcase ][0];
      # THE MARKER IS THE FIRST NON-BLANK LINE, AND THE ONLY ONE. A marker
      # below it, quoted from another pull request or inside a fenced example,
      # is not the author asserting which commit this comment answers. A
      # comment holding a second marker carries a section per head, and
      # binding it would carry the older section replies onto this head, so it
      # binds nothing. The claimed sha is a variable in the comparison, since
      # dot inside startswith would be the head and accept any sha.
      def head_bound($sha; $floor):
        [ split("\n")[] | select(test("\\S")) | marker_sha($floor) ] as $marks
        | $marks[0] != null and ($sha | ascii_downcase | startswith($marks[0])) and ([$marks[] | values] | length == 1);
      # A line names an entry by EQUALITY with one the scan extracted, never by
      # a token pattern of its own: the scan is the one definition of what an
      # entry token is. The decorated arm ITERATES entry_marks for the same
      # reason the scan does.
      #
      # The bare arm requires the character after the entry to be no letter or
      # digit, so `a/b.ts:1` cannot claim the line `a/b.ts:12 ...`. A path may
      # hold a colon of its own, though, and then one entry is a prefix of
      # another at a separator the test allows: `src/foo:1` opens the line of
      # `src/foo:1.ts:2`. A LINE NAMES ONE ENTRY, the longest it opens with:
      # the list arrives ordered by length and the first match wins.
      def line_reply($by_length):
        sub("^[ \t]*([-*+][ \t]+)?"; "") as $l
        | first(
            $by_length[]
            | . as $e
            | ($e | length) as $n
            | ( ( entry_marks[]
                  | . as $d
                  | select($l | startswith($d + $e + $d))
                  | {entry: $e, r: ($l[($n + 2 * ($d | length)):])} ),
                ( select(($l | startswith($e))
                         and (($l[$n:] | test("^[\\p{L}\\p{N}]")) | not))
                  | {entry: $e, r: ($l[$n:])} ) ))
        # The separator run between the token and the reply is what the author
        # wrote there: a dash, a colon, an em dash, nothing at all.
        | .r |= sub("^[^\\p{L}\\p{N}]*"; "");
      # The answers a comment gives: the lines naming an entry, when it binds
      # this head.
      def answers($by_length):
        (.body // "" | display_strip)
        | if head_bound($sha; $floor) then split("\n")[] | line_reply($by_length) else empty end;
      ($entries | split("\n") | map(select(length > 0))) as $wanted
      | ($wanted | sort_by(-length)) as $by_length
      | [ .[] | select(rest_actor | reply_source($author; $viewer)) | answers($by_length) ] as $said
      | [ .[] | select(rest_actor | reply_source($author; $viewer) | not)
          | select([answers($by_length)] | length > 0) | rest_actor | .login ] as $ignored
      # The NEWEST line naming an entry decides, whatever it says. The standing
      # reply of a thread skips a comment that is no disposition or claim, but a
      # line naming the entry is always an answer to it, so an author who
      # answers and then writes something else about the same entry has
      # withdrawn the answer.
      | [ $wanted[]
          | . as $e
          | ([ $said[] | select(.entry == $e) ] | last) as $reply
          | select($reply == null or ($reply.r | unanswered))
        ]
      | "\([length | tostring] + ($ignored | unique) | join(" "))\n" + join("\n")'

# The shortest head prefix a `Dispositions at <sha>` line may name.
SHA_FLOOR=7

# The PR author and the viewer as AUTHOR_TRUST_DEF's accounts, from a REST
# user, whose id is `id`, or the GraphQL viewer, whose id is `databaseId`.
# Prints the account, then on a second line the name a diagnostic prints. A
# read naming no positive integer id is no verdict, never an account nobody
# matches: every reply's standing turns on it.
ACCOUNT_DEF='def account($id): {id: $id, login: (.login // "" | strings)}
    | if (.id | type) == "number" and .id > 0 and .id == (.id | floor)
      then tojson, "\(.login) id \(.id)" else error("no account id") end;
'

# One REST collection, every page merged into one array; an empty one would
# erase findings, so a read gh_rest_all calls broken refuses.
read_collection() { # WHAT ENDPOINT
  local pages rc=0
  pages=$(gh_rest_all "$2" 2>"$READ_ERR") || rc=$?
  case "$rc" in
    0) printf '%s' "$pages" ;;
    2) refuse "read-malformed" "$PR_NUMBER" "the $1 read: $(reader_said)" ;;
    *) refuse "read-failed" "$PR_NUMBER" "the $1 read failed: $(reader_said)" ;;
  esac
}

[ "$#" -eq 1 ] && [[ "$1" =~ ^[1-9][0-9]*$ ]] ||
  refuse "usage" "${1:-}" "check-review-replies takes one PR number; see --help"
PR_NUMBER="$1"
READ_ERR=$(mktemp "${TMPDIR:-/tmp}/check-review-replies.XXXXXX") ||
  refuse "scratch-failed" "$PR_NUMBER" "could not create a temporary file for the readers' diagnostics"
trap 'rm -f -- "${READ_ERR:?}"' EXIT

repo_info=$(get_repo_info 2>"$READ_ERR") || refuse "repo-unresolved" "$PR_NUMBER" "$(reader_said)"
OWNER=$(get_owner "$repo_info") || refuse "repo-unresolved" "$PR_NUMBER" "the resolved repository names no owner"
NAME=$(get_repo "$repo_info") || refuse "repo-unresolved" "$PR_NUMBER" "the resolved repository names no name"
SLUG="$OWNER/$NAME"

pr_json=$(gh_rest "repos/$SLUG/pulls/$PR_NUMBER" 2>"$READ_ERR") ||
  refuse "read-failed" "$PR_NUMBER" "the pull request read failed: $(reader_said)"
HEAD_SHA=$(jq -r '.head.sha // "" | strings' <<<"$pr_json" 2>/dev/null) || HEAD_SHA=""
[ -n "$HEAD_SHA" ] || refuse "read-malformed" "$PR_NUMBER" "the pull request read named no head commit"
author_read=$(jq -r "$ACCOUNT_DEF"'.user | account(.id)' <<<"$pr_json" 2>/dev/null) ||
  refuse "read-malformed" "$PR_NUMBER" "the pull request read named no author account id"
AUTHOR_ACCOUNT="${author_read%%$'\n'*}"
AUTHOR_NAMED="${author_read#*$'\n'}"

viewer_json=$(gh_viewer 2>"$READ_ERR") ||
  refuse "read-failed" "$PR_NUMBER" "the viewer identity read failed: $(reader_said)"
viewer_read=$(jq -r "$ACCOUNT_DEF"'account(.databaseId)' <<<"$viewer_json" 2>/dev/null) ||
  refuse "read-malformed" "$PR_NUMBER" "the viewer identity read named no account id"
VIEWER_ACCOUNT="${viewer_read%%$'\n'*}"
VIEWER_NAMED="${viewer_read#*$'\n'}"

threads=$(gh_graphql_threads "$OWNER" "$NAME" "$PR_NUMBER" '
                          comments(first: 100) { totalCount nodes { author { login __typename ... on User { databaseId } ... on Bot { databaseId } } authorAssociation body } }' 2>"$READ_ERR") ||
  refuse "read-failed" "$PR_NUMBER" "the review thread read failed: $(reader_said)"
thread_counts=$(jq -r --argjson author "$AUTHOR_ACCOUNT" --argjson viewer "$VIEWER_ACCOUNT" "$THREAD_RULES_JQ" <<<"$threads" 2>/dev/null) ||
  refuse "read-malformed" "$PR_NUMBER" "the review thread read could not be judged"
read -r truncated untracked unreasoned <<<"$thread_counts"
case "$truncated:$untracked:$unreasoned" in
  *[!0-9:]* | :* | *:: | *:) refuse "read-malformed" "$PR_NUMBER" "the review thread rules produced no counts" ;;
esac

reviews=$(read_collection reviews "repos/$SLUG/pulls/$PR_NUMBER/reviews?per_page=100") || exit 2
supp_raw=$(jq -r --arg sha "$HEAD_SHA" --argjson author "$AUTHOR_ACCOUNT" "$SUPP_ROWS_JQ" <<<"$reviews" 2>/dev/null) ||
  refuse "read-malformed" "$PR_NUMBER" "the review bodies could not be scanned"
supp_head="${supp_raw%%$'\n'*}"
supp_list=""
case "$supp_raw" in *$'\n'*) supp_list="${supp_raw#*$'\n'}" ;; esac
read -r supp_entries supp_unparsed supp_mismatched <<<"$supp_head"
case "$supp_entries:$supp_unparsed:$supp_mismatched" in
  *[!0-9:]* | :* | *:: | *:) refuse "read-malformed" "$PR_NUMBER" "the review body scan produced no counts" ;;
esac

supp_state=ok
supp_ignored=""
if [ "$supp_unparsed" != 0 ]; then
  supp_state=unparsed
elif [ "$supp_mismatched" != 0 ]; then
  supp_state=mismatch
elif [ "$supp_entries" != 0 ]; then
  comments=$(read_collection "issue comments" "repos/$SLUG/issues/$PR_NUMBER/comments?per_page=100") || exit 2
  supp_disp=$(jq -r --arg sha "$HEAD_SHA" --argjson author "$AUTHOR_ACCOUNT" --argjson viewer "$VIEWER_ACCOUNT" --arg floor "$SHA_FLOOR" \
    --arg entries "$supp_list" "$SUPP_DISPOSITION_JQ" <<<"$comments" 2>/dev/null) ||
    refuse "read-malformed" "$PR_NUMBER" "the disposition comments could not be read"
  read -r supp_entries supp_ignored <<<"${supp_disp%%$'\n'*}"
  case "$supp_entries" in
    '' | *[!0-9]*) refuse "read-malformed" "$PR_NUMBER" "the disposition read produced no count" ;;
  esac
  supp_list=""
  case "$supp_disp" in *$'\n'*) supp_list="${supp_disp#*$'\n'}" ;; esac
fi

lines=()
[ "$untracked" = 0 ] || {
  lines+=("untracked-claim count=$untracked")
  echo "untracked-claim: $untracked thread reply(s) claim tracking and name no issue; reply Tracked: <issue id>, or Declined: <reason>" >&2
}
[ "$unreasoned" = 0 ] || {
  lines+=("unreasoned-decline count=$unreasoned")
  echo "unreasoned-decline: $unreasoned thread decline(s) name no mechanism; give the passing state, the false premise, or the excluded class with the fact that puts the finding there" >&2
}
[ "$truncated" = 0 ] || {
  lines+=("thread-replies state=truncated threads=$truncated")
  echo "thread-replies: $truncated thread(s) hold more comments than one read returns, so their replies cannot be judged" >&2
}
case "$supp_state" in
  unparsed)
    lines+=("suppressed-findings state=unparsed")
    echo "suppressed-findings: a review body has an unreadable findings count or overview verdict; read it in the review" >&2
    ;;
  mismatch)
    lines+=("suppressed-findings state=mismatch sections=$supp_mismatched")
    echo "suppressed-findings: $supp_mismatched findings section(s) across the review bodies at this head declare a count other than the entry lines parsed under them; read them in the reviews" >&2
    ;;
  ok)
    if [ "$supp_entries" != 0 ]; then
      lines+=("suppressed-findings count=$supp_entries")
      while IFS= read -r entry; do
        [ -z "$entry" ] || lines+=("suppressed-entry $entry")
      done <<<"$supp_list"
      echo "suppressed-findings: $supp_entries finding(s) across the review bodies at $HEAD_SHA carry no thread and no counted head-bound answer; reply in a PR comment opening 'Dispositions at ${HEAD_SHA:0:7}'" >&2
      # A login is not split by glob: an app's `[bot]` suffix is a bracket
      # expression.
      read -r -a ignored_logins <<<"$supp_ignored"
      for login in ${ignored_logins[@]+"${ignored_logins[@]}"}; do
        printf 'suppressed-findings: ignored-author login=%s\n  its head-bound disposition comment does not count: the author is not the PR author (%s), not the identity this check runs as (%s), and not an OWNER, MEMBER or COLLABORATOR\n' "$login" "$AUTHOR_NAMED" "$VIEWER_NAMED" >&2
      done
    fi
    ;;
  *)
    echo "check-review-replies: unknown suppressed-findings state $supp_state" >&2
    exit 2
    ;;
esac

if [ "${#lines[@]}" -eq 0 ]; then
  printf 'review-replies: pass head=%s\n' "$HEAD_SHA"
  exit 0
fi
printf 'review-replies: fail head=%s\n' "$HEAD_SHA"
printf '%s\n' "${lines[@]}"
exit 1
