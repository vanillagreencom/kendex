# shellcheck shell=bash
# merged-sweep.test.sh's harness: one stubbed gh over one GraphQL fixture,
# the builders that shape that fixture, the assertions and the runners. It
# lives here so the suite file is arms alone — reading what a case asserts
# should not mean scrolling the machinery that sets it up. The caller sets
# TMP_ROOT and SWEEP before sourcing, and owns PASS/FAIL.
#
# shellcheck disable=SC2034 # every name here is read by the suite that sources it

# The assertion primitives live here with the rest of the machinery, and
# with the two composite assertions below that call them: PASS and FAIL are
# the caller's, every one of these adds to exactly one of them.
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

review() { # id, createdAt, state, body, login, [typename]
  jq -n --arg id "$1" --arg at "$2" --arg st "$3" --arg body "$4" \
    --arg login "$5" --arg tn "${6:-Bot}" \
    '{id:$id, createdAt:$at, state:$st, body:$body, author:{login:$login, __typename:$tn}}'
}
comment() { # createdAt, body, login, [typename]
  jq -n --arg at "$1" --arg body "$2" --arg login "$3" --arg tn "${4:-User}" \
    '{createdAt:$at, body:$body, author:{login:$login, __typename:$tn}}'
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
    '{number:$n, mergedAt:$merged, headRefOid:$head, author:{login:$author},
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

