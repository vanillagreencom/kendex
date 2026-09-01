#!/usr/bin/env bash
# One `gh` fake for the shell suites, answering from files a test stages.
#
# The shell suites each wrote their own `gh` heredoc: a `case` over the
# handful of verbs that suite needed, seeded with whichever identity answers
# its code path asked for — `auth status`, `api user`, `repo view` — and a
# refusal for the rest. The answer sets differ per suite, so the duplication
# was never in them; it was in the scaffolding around them, and in a per-suite
# pile of STUB_* environment knobs that made a scenario something you read by
# tracing which knob a case branch happened to consult.
#
# Here the shape is inverted: the stub has no knowledge of any suite. Install
# and reset seed the three identity probes documented below. A test STAGES
# every other answer, and an unstaged call is refused, so a suite cannot pass
# on a call it never meant the code to make.
#
# Usage, from a test:
#
#   . "$TEST_DIR/lib/gh-stub.sh"
#   gh_stub_install "$TMP/bin"        # writes $TMP/bin/gh, exports STUB_DIR
#   PATH="$TMP/bin:$PATH"
#
#   gh_stub_answer pr-list '[]'                     # every `pr list` call
#   gh_stub_answer_seq api-graphql "$page_one"      # 1st `api graphql` call
#   gh_stub_answer_seq api-graphql "$page_two"      # 2nd, then refused
#   gh_stub_fail repo-view 1 'repository unavailable'
#   gh_stub_calls                                   # the argv of every call
#
# THE VERB is the first two argv words joined by `-`, with the second dropped
# when it is flag-shaped: `auth status` → `auth-status`, `api graphql -f q=…`
# → `api-graphql`, `pr list --state merged` → `pr-list`, `api
# repos/o/r/issues/1/comments` → that whole path after `api-`. When nothing
# is staged under that two-word verb, the FIRST word alone is tried — so
# `gh_stub_answer api '[]'` answers every api path a suite did not name one
# at a time, and staging neither is still a refusal.
#
# THE KEY a verb names is one file stem, and a call maps to it injectively:
# each word is percent-encoded down to `[A-Za-z0-9_]`, and the encoded words
# are joined by `-`, which no encoded word can hold. So `api user` keys on
# `api-user` while the one-word `api-user` keys on `api%2Duser`, and `api a/b`
# keys on `api-a%2Fb` while `api 'a%b'` keys on `api-a%25b`. Anything less
# than injective hands a staged answer to a call nobody staged, which is the
# fail-open a fake exists to prevent.
#
# A staged verb splits at its FIRST `-`, so a hyphenated word is always the
# second one — `repo-set-default` is `repo set-default` — and a hyphenated
# FIRST word cannot be staged at all. Current suites do not stage top-level
# commands of that shape; the helper refuses them.
#
# A VERB IS NOT ALWAYS ENOUGH. Two `api graphql` calls carrying different
# queries are one verb, and answering both the same way would let a suite
# pass with the wrong query on the wire. So a staged verb may carry a
# selector — `api-graphql:mergeQueueEntry` — and the stub takes the first
# selector whose text occurs anywhere in the call's argv, falling back to the
# plain verb. Selectors are tried in the order they were staged.
#
# WHAT THIS DELIBERATELY DOES NOT DO. It does not read GH_TOKEN, GH_REPO or
# any other part of gh's own environment contract, and it does not judge a
# call's flags. A suite whose SUBJECT is which token gh was handed, or which
# filters a command sent, has to see those itself: the assertion is the whole
# point of that suite, and moving it in here would bury it. Those suites read
# `gh_stub_calls` and assert on the argv, or keep a bespoke fake.

# _gh_stub_word WORD — WORD as one key component: everything outside
# `[A-Za-z0-9_]` percent-encoded, `%` itself included so the escape is
# escaped, and `-` with it so `-` can join two components into one stem no
# other pair of words can produce. LC_ALL=C makes the pass byte-wise, which is
# what holds the map injective over anything a gh argv carries.
_gh_stub_word() {
  local s="$1" out="" i c
  local LC_ALL=C
  for ((i = 0; i < ${#s}; i++)); do
    c="${s:i:1}"
    case "$c" in
    [A-Za-z0-9_]) out="$out$c" ;;
    *) out="$out$(printf '%%%02X' "'$c")" ;;
    esac
  done
  printf '%s' "$out"
}

# _gh_stub_stem WORD [WORD] — the staged-file stem for a verb's words.
#
# THE ONE DERIVATION. The stub resolves a call through it and the staging
# helpers write a file through it, and the two agreeing is the whole of the
# stub's resolution: gh_stub_install writes this function and _gh_stub_word
# into the stub with `declare -f`, so there is one definition rather than two
# spellings someone has to keep in step.
_gh_stub_stem() {
  local stem
  stem="$(_gh_stub_word "$1")"
  [ "$#" -lt 2 ] || stem="$stem-$(_gh_stub_word "$2")"
  printf '%s' "$stem"
}

# _gh_stub_seed — stage the three identity answers. Install and reset both
# start from them, so the seeded owner/repo is written in one place.
_gh_stub_seed() {
  gh_stub_answer auth-status 'Logged in'
  gh_stub_answer api-user 'test-user'
  gh_stub_answer repo-view '{"owner":{"login":"owner"},"name":"repo","nameWithOwner":"owner/repo"}'
}

# gh_stub_install DIR — write DIR/gh and export STUB_DIR beside it.
#
# The three identity answers are seeded because a suite that needs one is not
# asserting on it; restage any of them to say something else.
gh_stub_install() {
  local bin="$1"
  mkdir -p "$bin" || return 1
  STUB_DIR="${GH_STUB_DIR:-$bin/../gh-stub}"
  mkdir -p "$STUB_DIR" || return 1
  STUB_DIR="$(cd "$STUB_DIR" && pwd)" || return 1
  export STUB_DIR

  {
    cat <<'STUB_HEAD'
#!/usr/bin/env bash
# Written by github/tests/lib/gh-stub.sh. Answers from $STUB_DIR.
set -uo pipefail
STUB_HEAD
    # The key derivation, copied out of this library rather than restated, so
    # the stem a call resolves to is the stem the staging helpers wrote.
    declare -f _gh_stub_word _gh_stub_stem
    cat <<'STUB'

[ -n "${STUB_DIR:-}" ] || {
  printf 'gh-stub: STUB_DIR is unset, so nothing could be staged\n' >&2
  exit 70
}

printf '%s\n' "$*" >>"$STUB_DIR/gh.calls"

# The verb: the first word, plus the second when it is not flag-shaped. The
# first word alone is the fallback, so `api` can answer every api path a
# suite did not name one at a time. Both go through _gh_stub_stem, which is
# also what the staging helpers wrote their files under.
fallback_key="$(_gh_stub_stem "${1:-}")"
key="$fallback_key"
if [ "$#" -gt 1 ]; then
  case "${2:-}" in
  -*) ;;
  *) key="$(_gh_stub_stem "$1" "$2")" ;;
  esac
fi

argv="$*"

# resolve BASE — the staged stem for BASE, or empty when nothing is staged
# under it. A selector wins over the plain key, in staging order: the index
# holds one `id<TAB>text` line per selector, and the first whose text occurs
# in this call's argv names the answer. The call ordinal is counted per
# resolved stem, so a sequence answers each call once; `.0` is the answer
# for every call and is what gh_stub_answer stages.
resolve() {
  local key="$1" sel_id sel_text n
  if [ -f "$STUB_DIR/$key.selectors" ]; then
    while IFS="$(printf '\t')" read -r sel_id sel_text; do
      [ -n "$sel_id" ] || continue
      case "$argv" in
      *"$sel_text"*)
        key="$key@$sel_id"
        break
        ;;
      esac
    done <"$STUB_DIR/$key.selectors"
  fi
  n=0
  [ -f "$STUB_DIR/$key.count" ] && n="$(cat "$STUB_DIR/$key.count")"
  n=$((n + 1))
  if [ -f "$STUB_DIR/$key.$n.out" ]; then
    printf '%s' "$n" >"$STUB_DIR/$key.count"
    printf '%s' "$STUB_DIR/$key.$n"
  elif [ -f "$STUB_DIR/$key.0.out" ]; then
    printf '%s' "$n" >"$STUB_DIR/$key.count"
    printf '%s' "$STUB_DIR/$key.0"
  fi
}

# known KEY — true when a suite staged anything at all under KEY. A key that
# is known but has no answer left is a REFUSAL, never a fall-through: a
# sequence that ran out means the code polled once more than the suite said
# it would, and answering that from a broad one-word key would hide it.
known() {
  [ -f "$STUB_DIR/$1.selectors" ] && return 0
  set -- "$STUB_DIR/$1".*.out
  [ -f "$1" ]
}

pick="$(resolve "$key")"
if [ -z "$pick" ] && [ "$key" != "$fallback_key" ] && ! known "$key"; then
  pick="$(resolve "$fallback_key")"
fi

if [ -z "$pick" ]; then
  printf 'gh-stub: nothing staged for %s (argv: %s)\n' "$key" "$argv" >&2
  exit 1
fi

[ -s "$pick.err" ] && cat "$pick.err" >&2
cat "$pick.out"
status=0
[ -f "$pick.status" ] && status="$(cat "$pick.status")"
exit "$status"
STUB
  } >"$bin/gh" || return 1
  chmod +x "$bin/gh" || return 1

  : >"$STUB_DIR/gh.calls"
  _gh_stub_seed
}

# _gh_stub_key VERB — the staged-file stem for VERB, registering a selector
# when VERB carries one. Prints the stem.
_gh_stub_key() {
  local verb="$1" sel="" base id
  case "$verb" in
  *:*)
    sel="${verb#*:}"
    verb="${verb%%:*}"
    ;;
  esac
  # The verb's words: it splits at its FIRST `-`, so a path or a subcommand
  # carrying one stays whole as the second word.
  case "$verb" in
  *-*) base="$(_gh_stub_stem "${verb%%-*}" "${verb#*-}")" ;;
  *) base="$(_gh_stub_stem "$verb")" ;;
  esac
  [ -n "$sel" ] || {
    printf '%s' "$base"
    return 0
  }
  # A selector's id is its position in the index, so restaging the same
  # selector text reuses its slot instead of shadowing it with a second one.
  id=""
  if [ -f "$STUB_DIR/$base.selectors" ]; then
    id="$(awk -F'\t' -v want="$sel" '$2 == want { print $1; exit }' \
      "$STUB_DIR/$base.selectors")"
  fi
  if [ -z "$id" ]; then
    id=0
    [ -f "$STUB_DIR/$base.selectors" ] &&
      id="$(wc -l <"$STUB_DIR/$base.selectors" | tr -d ' ')"
    id=$((id + 1))
    printf '%s\t%s\n' "$id" "$sel" >>"$STUB_DIR/$base.selectors"
  fi
  printf '%s@%s' "$base" "$id"
}

# gh_stub_answer VERB TEXT — TEXT answers every call of VERB.
gh_stub_answer() {
  local key
  key="$(_gh_stub_key "$1")" || return 1
  rm -f "${STUB_DIR:?}/$key".[0-9]*.out "${STUB_DIR:?}/$key".[0-9]*.err \
    "${STUB_DIR:?}/$key".[0-9]*.status "${STUB_DIR:?}/$key.count"
  printf '%s\n' "$2" >"$STUB_DIR/$key.0.out"
}

# gh_stub_answer_seq VERB TEXT — TEXT answers the NEXT unstaged call of VERB.
# A call past the last staged one is refused, which is what makes "the code
# polled once more than it should have" a failure rather than a repeat.
#
# Staging after a call of VERB has already been served starts a NEW sequence:
# the served count and the earlier answers go, and TEXT becomes the first
# answer. A scenario that restages a verb the previous scenario consumed is
# saying "from here, this", and serving the previous scenario's unconsumed
# answer instead would be a suite going green over the wrong response.
gh_stub_answer_seq() {
  local key n=1
  key="$(_gh_stub_key "$1")" || return 1
  if [ -f "${STUB_DIR:?}/$key.count" ]; then
    rm -f "${STUB_DIR:?}/$key".[0-9]*.out "${STUB_DIR:?}/$key".[0-9]*.err \
      "${STUB_DIR:?}/$key".[0-9]*.status "${STUB_DIR:?}/$key.count"
  fi
  rm -f "${STUB_DIR:?}/$key.0.out"
  while [ -f "$STUB_DIR/$key.$n.out" ]; do n=$((n + 1)); done
  printf '%s\n' "$2" >"$STUB_DIR/$key.$n.out"
}

# gh_stub_fail VERB CODE [STDERR] — VERB exits CODE, printing STDERR.
gh_stub_fail() {
  local key
  key="$(_gh_stub_key "$1")" || return 1
  rm -f "${STUB_DIR:?}/$key".[0-9]*.out "${STUB_DIR:?}/$key".[0-9]*.err \
    "${STUB_DIR:?}/$key".[0-9]*.status "${STUB_DIR:?}/$key.count"
  : >"$STUB_DIR/$key.0.out"
  printf '%s' "$2" >"$STUB_DIR/$key.0.status"
  [ "$#" -lt 3 ] || printf '%s\n' "$3" >"$STUB_DIR/$key.0.err"
}

# gh_stub_calls — the argv of every call so far, one per line.
gh_stub_calls() { cat "$STUB_DIR/gh.calls" 2>/dev/null; }

# gh_stub_reset — forget every staged answer and every recorded call, then
# reseed the identity answers. A suite calls this between scenarios so one
# scenario's leftovers cannot answer the next one's calls.
gh_stub_reset() {
  rm -f "${STUB_DIR:?}"/*.out "${STUB_DIR:?}"/*.err "${STUB_DIR:?}"/*.status \
    "${STUB_DIR:?}"/*.count "${STUB_DIR:?}"/*.selectors "${STUB_DIR:?}/gh.calls"
  : >"$STUB_DIR/gh.calls"
  _gh_stub_seed
}
