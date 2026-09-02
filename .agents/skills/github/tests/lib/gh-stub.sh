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
# THE KEY a verb names is one file stem: the verb's words as written, with
# `/` spelled `%` because a stem is a file name. Two verbs can therefore
# reach one stem — `api-a/b` and `api-a%b` do — so a stem records the verb
# that claimed it. A staging under a second verb is REFUSED, and a call whose
# own verb is not the claimant's finds the stem UNSTAGED. Either half missing
# hands a staged answer to a call nobody staged, which is the fail-open a
# fake exists to prevent.
#
# THE CLAIM RECORDS WORDS, NOT THE JOINED TEXT. The join is lossy about
# arity: the two-word `api user` and the one-word command `api-user` both
# spell `api-user`, and a claim holding that string would hand the seeded
# `api user` answer to a call that ran the wrong command. So the record
# separates the words by a byte no gh argv word carries, and a call rebuilds
# the same form from its own argv — two words when it took `$2`, one word
# otherwise. A staged verb splits at its FIRST `-`, which is where the join
# put it. Arity is therefore part of the claim, and the two spellings, which
# still share a stem, cannot take each other's answers.
#
# `@` IS RESERVED. The stub mints `<stem>@<id>` for a selector's slot, so a
# verb or a call carrying `@` in its own text would address a slot nobody
# staged under it — the same fail-open, one layer down, and one the verb
# claim cannot see because the colliding names have different owners.
# Staging such a verb is refused, and a call whose stem carries `@` is
# unstaged. `%` stays legal: it is how a stem spells `/`.
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

  cat >"$bin/gh" <<'STUB' || return 1
#!/usr/bin/env bash
# Written by github/tests/lib/gh-stub.sh. Answers from $STUB_DIR.
set -uo pipefail

[ -n "${STUB_DIR:-}" ] || {
  printf 'gh-stub: STUB_DIR is unset, so nothing could be staged\n' >&2
  exit 70
}

printf '%s\n' "$*" >>"$STUB_DIR/gh.calls"

# SEP joins the claim's words. It is not in any gh argv word, so a claim
# built from two words never reads as one word that happens to contain it.
SEP="$(printf '\034')"

# The verb: the first word, plus the second when it is not flag-shaped. The
# first word alone is the fallback, so `api` can answer every api path a
# suite did not name one at a time. `claim` is the same words unjoined —
# what the staging helpers recorded — so a one-word `gh api-user` and the
# two-word `gh api user`, which share the stem `api-user`, differ here.
verb="${1:-}"
fallback="${1:-}"
claim="${1:-}"
fallback_claim="${1:-}"
if [ "$#" -gt 1 ]; then
  case "${2:-}" in
  -*) ;;
  *)
    verb="$verb-$2"
    claim="$claim$SEP$2"
    ;;
  esac
fi

# `/` cannot appear in a staged file's name; the staging helpers spell it the
# same way, so `api repos/o/r/labels` keys on `api-repos%o%r%labels`.
slug() { printf '%s' "$1" | tr '/' '%'; }

argv="$*"

# ours STEM CLAIM — false when STEM is not this call's to read. Several verbs
# reach one stem: `/` cannot appear in a file name, so `api a/b` and `api
# 'a%b'` both key on `api-a%b`, and the join is blind to arity, so the
# one-word `api-user` keys where `api user` does. The staging helpers record
# the claimant's words, and a call whose own words differ — a different
# spelling, or a different number of them — is UNSTAGED here, never served
# the claimant's answer. A stem carrying `@` belongs to no verb at all: `@`
# is minted below for a selector's slot, and the staging helpers refuse it in
# a verb, so a call that spells one is reaching for a slot rather than for
# anything staged under its own name.
ours() {
  case "$1" in
  *@*) return 1 ;;
  esac
  [ ! -f "$STUB_DIR/$1.verb" ] || [ "$(cat "$STUB_DIR/$1.verb")" = "$2" ]
}

# resolve BASE CLAIM — the staged stem for BASE, or empty when BASE holds
# nothing CLAIM's words staged. A selector wins over the plain key, in staging order:
# the index holds one `id<TAB>text` line per selector, and the first whose
# text occurs in this call's argv names the answer. The call ordinal is
# counted per resolved stem, so a sequence answers each call once; `.0` is
# the answer for every call and is what gh_stub_answer stages.
resolve() {
  local key="$1" sel_id sel_text n
  ours "$key" "$2" || return 0
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

# known KEY CLAIM — true when CLAIM's words staged anything at all under
# KEY. A key
# that is known but has no answer left is a REFUSAL, never a fall-through: a
# sequence that ran out means the code polled once more than the suite said
# it would, and answering that from a broad one-word key would hide it. A key
# another claimant holds is not known to this call, so the one-word fallback
# still answers a path the suite never named.
known() {
  local stem="$1"
  ours "$stem" "$2" || return 1
  [ -f "$STUB_DIR/$stem.selectors" ] && return 0
  set -- "$STUB_DIR/$stem".*.out
  [ -f "$1" ]
}

key="$(slug "$verb")"
pick="$(resolve "$key" "$claim")"
if [ -z "$pick" ] && [ "$fallback" != "$verb" ] && ! known "$key" "$claim"; then
  pick="$(resolve "$(slug "$fallback")" "$fallback_claim")"
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
  chmod +x "$bin/gh" || return 1

  : >"$STUB_DIR/gh.calls"
  _gh_stub_seed
}

# _gh_stub_key VERB — the staged-file stem for VERB, registering a selector
# when VERB carries one. Prints the stem.
#
# The stem is claimed by the first verb staged under it and refuses a second:
# `api-a/b` and `api-a%b` are one stem, and letting the second overwrite the
# first is the fail-open a fake exists to prevent.
#
# The record holds the verb's WORDS, split at the first `-` because that is
# where the join put the boundary, separated by a byte no gh argv word
# carries. A call rebuilds the same form from its own argv, so the one-word
# command `api-user` cannot read the two-word `api user`'s answer even
# though both spell one stem. Replacing the separator with `-` recovers the
# verb as written, which is how the refusal below names it.
_gh_stub_key() {
  local verb="$1" sel="" base id owner claim sep
  sep="$(printf '\034')"
  case "$verb" in
  *:*)
    sel="${verb#*:}"
    verb="${verb%%:*}"
    ;;
  esac
  case "$verb" in
  *@*)
    printf 'gh-stub: %s cannot be staged; @ is reserved for selector slots\n' \
      "$verb" >&2
    return 1
    ;;
  esac
  claim="$verb"
  case "$verb" in
  *-*) claim="${verb%%-*}$sep${verb#*-}" ;;
  esac
  base="$(printf '%s' "$verb" | tr '/' '%')"
  owner="${STUB_DIR:?}/$base.verb"
  if [ -f "$owner" ] && [ "$(cat "$owner")" != "$claim" ]; then
    printf 'gh-stub: %s already keys on %s; %s would overwrite it\n' \
      "$(tr "$sep" '-' <"$owner")" "$base" "$verb" >&2
    return 1
  fi
  printf '%s' "$claim" >"$owner" || return 1
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
    "${STUB_DIR:?}"/*.count "${STUB_DIR:?}"/*.selectors "${STUB_DIR:?}"/*.verb \
    "${STUB_DIR:?}/gh.calls"
  : >"$STUB_DIR/gh.calls"
  _gh_stub_seed
}
