# shellcheck shell=bash
# merged-sweep.test.sh's harness: one stubbed gh over one GraphQL fixture,
# the builders that shape that fixture, the assertions and the runners. It
# lives here so the suite file is arms alone — reading what a case asserts
# should not mean scrolling the machinery that sets it up. The exception is
# at the foot: ms36's arms are here because the suite file is at its size
# ceiling. The caller sets TMP_ROOT and SWEEP before sourcing, owns
# PASS/FAIL, and calls that one arm set by name.
#
# shellcheck disable=SC2034 # every name here is read by the suite that sources it

# The assertion primitives live here with the rest of the machinery, and
# with the composite assertions below that call them: PASS and FAIL are the
# caller's, every one of these adds to exactly one of them.
assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        must not contain: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  else
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name"
  fi
}

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/cwd"

# The gh stub answers exactly one call — the sweep issues one query per
# invocation, and a second call would be a regression ms24 reports.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -u
[[ "${1:-}" == "api" && "${2:-}" == "graphql" ]] || { echo "unexpected gh call: $*" >&2; exit 1; }
echo call >> "${STUB_CALL_LOG:-/dev/null}"
printf '%s\n' "$@" >> "${STUB_ARGV_LOG:-/dev/null}"
if [[ "${STUB_READ_FAIL:-}" == "yes" ]]; then echo "HTTP 502" >&2; exit 1; fi
if [[ "${STUB_EMPTYBYTES:-}" == "yes" ]]; then exit 0; fi
cat "${STUB_FIXTURE:?}"
EOF
chmod +x "$TMP_ROOT/bin/gh"

# Timestamps are built from the RUN's clock, so the window arithmetic is
# exercised against real "now" rather than a frozen fixture date that would
# drift out of every window as the suite ages.
NOW="$(date -u +%s)"
iso() { # OFFSET_SECS_FROM_NOW
  date -u -d "@$((NOW + $1))" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null \
    || date -u -r "$((NOW + $1))" +%Y-%m-%dT%H:%M:%SZ
}
MERGED_AT="$(iso -3600)"       # merged an hour ago
BEFORE_MERGE="$(iso -7200)"
AFTER_MERGE="$(iso -1800)"
LATER="$(iso -600)"
OLD_MERGE="$(iso -864000)"     # ten days ago — outside the default window
OLD_AFTER="$(iso -863000)"

# Deliberately NOT self-similar: with forty identical characters an
# assertion on the 8-char column passes against an untruncated 40-char
# emission, so the column shape would be untestable.
HEAD_A="0123456789abcdef0123456789abcdef01234567"
HEAD_A8="01234567"

# A typename of "null" builds a GHOST — the author key present and null,
# the shape GitHub returns for a deleted account; pr() takes it as its
# author too. The last argument of each is the EFFECTIVE PUBLICATION time, which is
# what the reduction places either side of the merge. Left empty it equals
# createdAt, the shape GitHub returns for anything already published; give
# it a later value for work drafted before the merge and published after
# it; give it "none" to omit the field and drive the createdAt fallback.
review() { # id, createdAt, state, body, login, [typename], [submittedAt|none]
  jq -n --arg id "$1" --arg at "$2" --arg st "$3" --arg body "$4" \
    --arg login "$5" --arg tn "${6:-Bot}" --arg sub "${7:-}" \
    '{id:$id, createdAt:$at, state:$st, body:$body,
       author:(if $tn == "null" then null else {login:$login, __typename:$tn} end)}
     | if $sub == "none" then . else .submittedAt = (if $sub == "" then $at else $sub end) end'
}
# The id defaults to one derived from the timestamp and body, so two
# distinct comments are distinctly keyed and a re-run over the same fixture
# is not: the shape the thread arm keys its finding on. The body is base64d
# because merged-sweep.sh reads the keys column with an unquoted `for key in
# $keys`, so a key carrying a SPACE becomes two keys. Nothing shipped emits
# one — GitHub node ids are base64url and the reduction lib names its
# overflow causes without whitespace — and these fixtures were the only
# producer that could. "none" omits the field and drives the id fallback.
comment() { # createdAt, body, login, [typename], [publishedAt|none], [id|none]
  jq -n --arg at "$1" --arg body "$2" --arg login "$3" --arg tn "${4:-User}" \
    --arg pub "${5:-}" --arg id "${6:-}" \
    '{createdAt:$at, body:$body, author:{login:$login, __typename:$tn}}
     | if $pub == "none" then . else .publishedAt = (if $pub == "" then $at else $pub end) end
     | if $id == "none" then . else .id = (if $id == "" then "C_\($at)_\($body | @base64)" else $id end) end'
}
thread() { # id, comments-totalCount, comment-json...
  local id="$1" total="$2"; shift 2
  jq -n --arg id "$id" --argjson total "$total" --argjson nodes "$(jq -sc '.' <<<"$*")" \
    '{id:$id, comments:{totalCount:$total, nodes:$nodes}}'
}
pr() { # number, mergedAt, author, reviews-json, comments-json, threads-json,
       # [reviews-totalCount], [threads-totalCount]
  jq -n --argjson n "$1" --arg merged "$2" --arg author "$3" --arg head "$HEAD_A" \
    --argjson rv "$4" --argjson cm "$5" --argjson th "$6" \
    --argjson rvt "${7:--1}" --argjson tht "${8:--1}" \
    '{number:$n, mergedAt:$merged, headRefOid:$head,
      author:(if $author == "null" then null else {login:$author} end),
      reviews:{totalCount:(if $rvt < 0 then ($rv|length) else $rvt end), nodes:$rv},
      comments:{nodes:$cm},
      reviewThreads:{totalCount:(if $tht < 0 then ($th|length) else $tht end), nodes:$th}}'
}
# The sweep enumerates through `search`, so the envelope carries the
# coverage metadata it compares against: issueCount defaults to the node
# count and hasNextPage to false, i.e. "this page covered the window", so
# only the arms that mean to trip the truncation guard do.
# data.repository is the repository PROBE the sweep rides along with the
# search: STUB_NO_REPO=yes makes it null, which is what GitHub returns for
# a repository the token cannot read while search still answers 0 findings
# and gh still exits 0.
envelope() { # pr-json...
  jq -n --argjson nodes "$(jq -sc '.' <<<"$*")" \
    --argjson total "${STUB_ISSUE_COUNT:--1}" --argjson next "${STUB_HAS_NEXT:-false}" \
    --arg norepo "${STUB_NO_REPO:-}" \
    '{data:{repository:(if $norepo == "yes" then null else {id:"R_kgDOabc123"} end),
            search:{issueCount:(if $total < 0 then ($nodes|length) else $total end),
                    pageInfo:{hasNextPage:$next}, nodes:$nodes}}}'
}

fixture() { printf '%s\n' "$1" > "$TMP_ROOT/fixture.json"; }
fresh_state() { rm -rf -- "${TMP_ROOT:?}/state"; }

# Assert one emitted row FIELD BY FIELD. Substring matching over the whole
# line cannot see a reordered printf or an untruncated sha, and the columns
# are the contract a consumer parses.
assert_row() { # name, line, want-pr, want-sha, want-kind, want-detail-substring
  local name="$1" line="$2" f1 f2 f3 f4
  IFS=$'\t' read -r f1 f2 f3 f4 <<<"$line"
  assert_eq "$f1" "$3" "$name: field 1 is the PR number"
  assert_eq "$f2" "$4" "$name: field 2 is the 8-char head sha"
  assert_eq "$f3" "$5" "$name: field 3 is the attention kind"
  assert_contains "$f4" "$6" "$name: field 4 is the detail"
}

# The REQUEST, not the response. The stub answers whatever it is handed,
# so only the recorded argv can prove the sweep asked search for the right
# set: issueCount bounds the window only while merged: does, and a
# malformed qualifier degrades search to free text, where issueCount counts
# the whole history and the coverage comparison means nothing.
assert_sent_query() { # name, expected --window seconds
  local name="$1" want_win="$2" q doc sent got want delta
  q="$(grep -m1 '^q=' "$TMP_ROOT/argv.log")"
  doc="$(cat "$TMP_ROOT/argv.log")"
  assert_contains "$q" "repo:acme/widgets" "$name: scoped to GH_REPO"
  assert_contains "$q" "is:pr" "$name: to pull requests"
  assert_contains "$q" "is:merged" "$name: that are merged"
  assert_contains "$q" "sort:updated-desc" "$name: newest-updated first, so a late review keeps its PR on the page"
  assert_contains "$doc" 'search(query:$q, type:ISSUE, first:$limit)' "$name: the search CALL, so a decoy in a document comment cannot satisfy it"
  assert_contains "$doc" 'repository(owner:$owner, name:$name)' "$name: beside the probe that proves the repository itself was read"
  assert_contains "$doc" "id createdAt submittedAt state" "$name: reviews carry submittedAt, the only field separating a draft from a submission"
  assert_contains "$doc" "createdAt publishedAt body" "$name: and comments carry publishedAt, which is null while their review is pending"
  assert_contains "$doc" "id createdAt publishedAt body" "$name: thread comments carry their own id, which the thread finding is keyed on"
  sent="$(sed -n 's/.*merged:>=\([0-9]\{4\}-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z\).*/\1/p' <<<"$q")"
  if [ -z "$sent" ]; then
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        no merged:>= with a full YYYY-MM-DDTHH:MM:SSZ in: %s\n' "$name" "$q"
    return
  fi
  PASS=$((PASS + 1)); printf '  ok    %s\n' "$name: merged:>= carries a full ISO-8601 Z timestamp"
  got="$(date -u -d "$sent" +%s 2>/dev/null || date -u -j -f '%Y-%m-%dT%H:%M:%SZ' "$sent" +%s)"
  want=$(( $(date -u +%s) - want_win ))
  delta=$(( got - want )); [ "$delta" -ge 0 ] || delta=$(( 0 - delta ))
  if [ "$delta" -le 120 ]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$name: and sits --window seconds before now, so the bound tracks the flag"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        merged:>= is %ss away from the requested window\n' "$name" "$delta"
  fi
}

# Streams captured SEPARATELY. run_sweep folds them, which cannot tell a
# message written to stdout from one written to stderr — so every arm that
# asserts the exit-2 contract goes through here instead.
SPLIT_OUT=""; SPLIT_ERR=""; SPLIT_RC=0
run_split() { # env-tokens... [-- flags...]
  local envs=() flags=() seen_sep=0 a
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then seen_sep=1; continue; fi
    if [[ "$seen_sep" == "1" ]]; then flags+=("$a"); else envs+=("$a"); fi
  done
  set +e
  (cd "$TMP_ROOT/cwd" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env GH_REPO=acme/widgets STUB_FIXTURE="$TMP_ROOT/fixture.json" \
           REVIEW_GATE_MERGED_SWEEP_STATE_DIR="$TMP_ROOT/state" "${envs[@]}" \
       "$SWEEP" ${flags[@]+"${flags[@]}"}) >"$TMP_ROOT/split.out" 2>"$TMP_ROOT/split.err"
  SPLIT_RC=$?
  set -e
  SPLIT_OUT="$(cat "$TMP_ROOT/split.out")"
  SPLIT_ERR="$(cat "$TMP_ROOT/split.err")"
}

# One pass with an explicit CWD and NO state-dir default in its
# environment, so an arm can prove where the settings ladder and the state
# anchoring each resolve from. Extra NAME=VALUE tokens join that pass.
run_at() { # cwd, [env-tokens...]
  local at="$1"; shift
  set +e
  (cd "$at" && PATH="$TMP_ROOT/bin:$PATH" \
     env GH_REPO=acme/widgets STUB_FIXTURE="$TMP_ROOT/fixture.json" "$@" \
     "$SWEEP") >"$TMP_ROOT/split.out" 2>"$TMP_ROOT/split.err"
  SPLIT_RC=$?
  set -e
  SPLIT_OUT="$(cat "$TMP_ROOT/split.out")"
  SPLIT_ERR="$(cat "$TMP_ROOT/split.err")"
}

run_sweep() { # env-tokens... [-- flags...]
  local envs=() flags=() seen_sep=0 a
  for a in "$@"; do
    if [[ "$a" == "--" ]]; then seen_sep=1; continue; fi
    if [[ "$seen_sep" == "1" ]]; then flags+=("$a"); else envs+=("$a"); fi
  done
  (cd "$TMP_ROOT/cwd" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env GH_REPO=acme/widgets STUB_FIXTURE="$TMP_ROOT/fixture.json" \
           REVIEW_GATE_MERGED_SWEEP_STATE_DIR="$TMP_ROOT/state" "${envs[@]}" \
       "$SWEEP" ${flags[@]+"${flags[@]}"} 2>&1)
}


# The DECLINE-REASON arms (ms36): a composite assertion, here for the same
# reason assert_sent_query is here, and because the suite file is at its
# size ceiling. The contract is `Declined: <reason>`; a decline with nothing
# after the colon answers nothing, and this sweep is the LAST net over these
# replies, since the merge gate that rejects an empty reason never reads
# post-merge activity. One body drives BOTH finding arms, because the one
# `answered` decides for both.
decline_arm() { # want-rc, reply-body, name
  local want="$1" body="$2" name="$3" reply
  reply="$(comment "$LATER" "$body" dev User)"
  fresh_state
  fixture "$(envelope "$(pr 15 "$MERGED_AT" dev \
    "[$(review REV_dr "$AFTER_MERGE" COMMENTED "P1: this leaks" codex Bot)]" "[$reply]" '[]')")"
  run_split
  assert_eq "$SPLIT_RC" "$want" "ms36: $name, over a late review"
  fresh_state
  fixture "$(envelope "$(pr 15 "$MERGED_AT" dev '[]' '[]' \
    "[$(thread THR_dr 2 "$(comment "$AFTER_MERGE" "P1: this leaks" codex Bot)" "$reply")]")")"
  run_split
  assert_eq "$SPLIT_RC" "$want" "ms36: $name, over a late thread comment"
}

assert_decline_reason_arms() {
  decline_arm 1 "Declined:" "a bare decline answers nothing"
  decline_arm 1 $'Declined: \t\n ' "a decline followed only by whitespace answers nothing"
  decline_arm 0 "Declined: the handle is closed on the error path" "a decline WITH a reason answers"
}

# The mergedAt TIE arms (ms37), here for the same reason ms36 is. GitHub
# serializes to the second, so an item published in the same second as the
# merge resolves to exactly mergedAt and the read can prove neither side.
# It must fail closed into overflow: dropping it is silent forever, and
# claiming it is a finding asserts what the read cannot show. The control
# one second later pins the other side of the boundary.
assert_merge_tie_arms() {
  local one_later; one_later="$(iso -3599)"
  fresh_state
  fixture "$(envelope "$(pr 16 "$MERGED_AT" dev \
    "[$(review REV_tie "$MERGED_AT" COMMENTED "P1: tied with the merge" codex Bot)]" '[]' '[]')")"
  run_split
  assert_eq "$SPLIT_RC" "1" "ms37: a review tied with mergedAt surfaces"
  assert_row ms37 "$SPLIT_OUT" "16" "$HEAD_A8" "post-merge-findings" "same second as the merge"
  assert_eq "$(cat "$TMP_ROOT/state/acme_widgets")" "16:overflow:merge-tie" \
    "ms37: keyed ONLY on the overflow arm, naming the tie as its cause — widening the finding predicate to >= would key the review id here too"
  assert_not_contains "$SPLIT_OUT" "landed after the merge with no disposition reply" \
    "ms37: and never as a confirmed finding — the read cannot prove which side it is on"
  fresh_state
  fixture "$(envelope "$(pr 16 "$MERGED_AT" dev '[]' '[]' \
    "[$(thread THR_tie 1 "$(comment "$MERGED_AT" "P2: tied with the merge" codex Bot)")]")")"
  run_split
  assert_eq "$SPLIT_RC" "1" "ms37: a thread comment tied with mergedAt surfaces"
  assert_contains "$SPLIT_OUT" "same second as the merge" "ms37: with the same fail-closed line"
  fresh_state
  fixture "$(envelope "$(pr 16 "$MERGED_AT" dev \
    "[$(review REV_1s "$one_later" COMMENTED "P1: one second past" codex Bot)]" '[]' '[]')")"
  run_split
  assert_eq "$SPLIT_RC" "1" "ms37: one second past the merge is an ordinary finding"
  assert_contains "$SPLIT_OUT" "1 review(s) and 0 review thread(s)" "ms37: counted, not failed closed"
  assert_not_contains "$SPLIT_OUT" "same second as the merge" "ms37: the tie line belongs to the tie alone"
}

# The thread finding is keyed on the COMMENT that produced it (ms38), never
# on the thread. A thread id is stable for its whole life and a thread takes
# more than one finding, so keying the container makes the second one
# unreportable by construction. Three passes over ONE state file: report,
# dedupe, then report again once a new comment lands in the same thread.
assert_thread_key_arms() {
  local first later
  first="$(comment "$AFTER_MERGE" "P1: this leaks" codex Bot)"
  later="$(comment "$LATER" "P2: and this one double-frees" codex Bot)"
  fresh_state
  fixture "$(envelope "$(pr 17 "$MERGED_AT" dev '[]' '[]' "[$(thread THR_k 1 "$first")]")")"
  run_split
  assert_eq "$SPLIT_RC" "1" "ms38: the first finding in a thread reports"
  run_split
  assert_eq "$SPLIT_RC" "0" "ms38: an unchanged second pass stays silent"
  fixture "$(envelope "$(pr 17 "$MERGED_AT" dev '[]' '[]' "[$(thread THR_k 2 "$first" "$later")]")")"
  run_split
  assert_eq "$SPLIT_RC" "1" "ms38: a SECOND finding in the same thread reports — the key is the comment, not the container"
  assert_contains "$SPLIT_OUT" "0 review(s) and 1 review thread(s)" "ms38: still counted as one thread finding"
}

# The EFFECTIVE PUBLICATION time, not the creation time (ms35). A reviewer
# drafting during the merge queue and submitting just after it is the
# ordinary shape of this finding, and that review carries createdAt <
# mergedAt. One fixture drives all three cases; the counts pin each.
assert_publication_time_arms() {
  local LATE_SUB NO_FIELD LATE_PUB
  fresh_state
  LATE_SUB="$(review REV_q "$BEFORE_MERGE" COMMENTED "P1: drafted in the queue" codex Bot "$AFTER_MERGE")"
  NO_FIELD="$(review REV_nf "$AFTER_MERGE" COMMENTED "P2: late, older shape" codex Bot none)"
  LATE_PUB="$(thread THR_q 1 "$(comment "$BEFORE_MERGE" "P2: drafted in the queue" codex Bot "$LATER")")"
  fixture "$(envelope "$(pr 14 "$MERGED_AT" dev "[$LATE_SUB,$NO_FIELD]" '[]' "[$LATE_PUB]")")"
  run_split
  assert_eq "$SPLIT_RC" "1" "ms35: work drafted before the merge and PUBLISHED after it is a finding"
  assert_contains "$SPLIT_OUT" "2 review(s) and 1 review thread(s)" "ms35: the review by submittedAt, the thread comment by publishedAt, a field-less shape by createdAt"
}

# A key carries the CAUSE, not just the PR (ms40). A second, distinct
# fail-closed cause arriving while the first still holds is a different
# reason to need eyes and a strictly more specific detail line; keyed on the
# PR alone it matched the seen set and the pass said nothing. Three passes
# over ONE state file: report, add a cause, then hold still.
assert_overflow_cause_arms() {
  local one two
  one="$(envelope "$(pr 19 "$MERGED_AT" dev '[]' '[]' \
    "[$(thread THR_o 9 "$(comment "$AFTER_MERGE" "P1: leak" codex Bot)")]")")"
  two="$(envelope "$(pr 19 "$MERGED_AT" dev \
    "[$(review REV_bad "not-a-date" COMMENTED "late" codex Bot none)]" '[]' \
    "[$(thread THR_o 9 "$(comment "$AFTER_MERGE" "P1: leak" codex Bot)")]")")"
  fresh_state
  fixture "$one"
  run_split
  assert_eq "$SPLIT_RC" "1" "ms40: the first fail-closed cause reports"
  assert_eq "$(grep ':overflow:' "$TMP_ROOT/state/acme_widgets")" "19:overflow:thread-comments" \
    "ms40: keyed on the PR AND the cause that fired"
  run_split
  assert_eq "$SPLIT_RC" "0" "ms40: an unchanged second pass stays silent"
  fixture "$two"
  run_split
  assert_eq "$SPLIT_RC" "1" "ms40: a SECOND distinct cause on the same PR reports again"
  assert_contains "$SPLIT_OUT" "will not parse" "ms40: with the more specific detail the new cause earns"
  assert_eq "$(grep ':overflow:' "$TMP_ROOT/state/acme_widgets")" "19:overflow:thread-comments+unparsable-time" \
    "ms40: and the key now names both causes"
}

# A ghost author is not proof of a self-review (ms41). Defaulting an absent
# login to "" made an unidentifiable reviewer match an unidentifiable PR
# author and the review was dropped as the author's own. Only that pair was
# affected, so the controls pin both neighbours: a NAMED reviewer on a ghost
# PR was always kept, and a real self-review is still excluded.
assert_ghost_author_arms() {
  fresh_state
  fixture "$(envelope "$(pr 21 "$MERGED_AT" null \
    "[$(review REV_g "$AFTER_MERGE" COMMENTED "P1: still leaks" ghost null)]" '[]' '[]')")"
  run_split
  assert_eq "$SPLIT_RC" "1" "ms41: a ghost review on a ghost-authored PR is a finding, not a self-review"
  assert_contains "$SPLIT_OUT" "1 review(s) and 0 review thread(s)" "ms41: counted as one"
  fresh_state
  fixture "$(envelope "$(pr 21 "$MERGED_AT" null \
    "[$(review REV_n "$AFTER_MERGE" COMMENTED "P1: still leaks" codex Bot)]" '[]' '[]')")"
  run_split
  assert_eq "$SPLIT_RC" "1" "ms41: a NAMED reviewer on a ghost-authored PR was never the dropped case"
  fresh_state
  fixture "$(envelope "$(pr 21 "$MERGED_AT" dev \
    "[$(review REV_s "$AFTER_MERGE" COMMENTED "note to self" dev User)]" '[]' '[]')")"
  run_split
  assert_eq "$SPLIT_RC" "0" "ms41: a real self-review, both logins KNOWN and equal, is still excluded"
}
