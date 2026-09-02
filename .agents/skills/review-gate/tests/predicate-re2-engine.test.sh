#!/usr/bin/env bash
# The predicate hands its thread jq to `gh --jq`, and gh's regex engine is
# Go's RE2: no lookaround, at all. Every OTHER proof puts that same
# program through the LOCAL jq, whose Oniguruma accepts patterns RE2
# refuses to compile, so this is the only place the shipping engine reads
# the program at all. That is how #1930 shipped a lookbehind: local jq took
# it, and every live evaluation of a PR carrying a `Declined:` reply died
# with `invalid regular expression`, leaving the writer to red without
# posting anything and the gate status frozen where it stood.
#
# This suite is the missing half: the SHIPPED program, through the SHIPPED
# engine, with no opt-in. The real `gh` (not the tests' shim) is pointed at a
# local HTTP stub, so `gh api --jq` runs with no network and no credentials,
# and its verdict for every fixture reply must equal the local jq's.
#
# Three controls, because "the outputs matched" is a claim a broken harness
# also makes:
#   1. a planted `(?<!` in the reason pass must red the RE2 run while local
#      jq stays green — the #1930 defect, reproduced on demand;
#   2. a planted `(?<!` in the untracked-claim test must red it too — that
#      regex is only ever compiled if a fixture reply reaches it, and no
#      corpus reply does;
#   3. a planted word-list edit must make the SAME comparison the assertion
#      runs report a difference — proof the differ is looking at anything.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRED="$SCRIPT_DIR/../scripts/review-predicate.sh"
CORPUS="$SCRIPT_DIR/corpus"
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; echo "        got: $2"; }

# All three are hard requirements, never a skip: gh is the engine under
# proof, python3 serves the stub it reads, and jq builds the fixture and is
# the other half of the comparison. This suite exists because the engine that
# matters was never exercised, and a suite that quietly opts out when a tool
# is missing recreates that hole with a green tick on it.
for tool in gh python3 jq; do
  command -v "$tool" >/dev/null 2>&1 || {
    echo "review-gate predicate-re2-engine: FAIL — $tool is required; this suite proves the shipped jq against gh's RE2 engine and cannot be satisfied without it" >&2
    exit 1
  }
done

prog="$(sed -n "/^t_threads_page_jq='/,/^  end'/p" "$PRED" | sed "s/^t_threads_page_jq='//; s/^  end'\$/  end/")"
[ -n "$prog" ] || { echo "FAIL: could not extract t_threads_page_jq"; exit 1; }

work="$(mktemp -d)" || { echo "FATAL: mktemp -d failed" >&2; exit 1; }
srv="$work/srv"
mkdir -p "$srv" "$work/gh"
server_pid=""
cleanup() {
  if [ -n "$server_pid" ]; then kill "$server_pid" >/dev/null 2>&1 || true; fi
  rm -rf -- "${work:?}"
}
trap cleanup EXIT

# ---------------------------------------------------------------- fixture ---
# One page envelope per reply, so the comparison is per reply rather than one
# aggregate count two divergences could cancel inside. The corpus files are
# the fixtures here as everywhere else in this directory.
#
# THE TWO APPENDED REPLIES ARE COVERAGE, NOT VOCABULARY. gojq compiles a
# regex when the program reaches it, not when it parses, so this suite proves
# only the patterns a fixture actually drives. Every corpus reply opens with
# a decline, so `standing` is always a disposition, `select(disposition|not)`
# drops it, and the untracked-claim `test(...)` behind that filter is never
# compiled — a lookbehind planted there shipped green through this very
# suite. A tracking reply with no issue id and one naming an id take the arm
# in both directions. They belong here rather than in tests/corpus/, which is
# the unreasoned-decline term's contract and nothing else's.
{ cat "$CORPUS"/*.txt
  printf '%s\n' 'Tracking this one for later.' 'Tracked: KEN-1081'
} | grep -v '^#' | grep -v '^[[:space:]]*$' \
  | jq -R -s '{pages: (split("\n") | map(select(length > 0)) | map(
      {data: {repository: {pullRequest: {reviewThreads: {
        pageInfo: {hasNextPage: false, endCursor: null},
        nodes: [{isResolved: true, comments: {pageInfo: {hasNextPage: false},
                 nodes: [{body: ., author: {__typename: "User"}}]}}]
      }}}}}))}' >"$srv/pages.json"
replies="$(jq -r '.pages | length' "$srv/pages.json")"
# A floor, not the exact count: the corpus grows by design, and a test that
# restated its size would red on every added reply. What must never happen
# is the fixture silently emptying and every assertion below passing over
# nothing.
if [ "${replies:-0}" -lt 100 ]; then
  bad "corpus built a usable fixture" "only ${replies:-0} replies read from $CORPUS"
  echo "$PASS passed, $FAIL failed"
  exit 1
fi

# ----------------------------------------------------------------- engines ---
# Port 0: the kernel picks a free one, so concurrent lanes on one machine do
# not collide. The port is read back from the server's own banner.
#
# The log is created HERE, in the parent. bash performs a background
# command's redirections in the child, after the fork, so without this line
# the parent can reach the read below before the child has made the file:
# `sed` fails, `pipefail` carries that into the assignment, and `set -e`
# ends the run before the retry loop ever reaches a second pass. The loop
# covers an empty banner, never an absent file.
: >"$work/httpd.log"
python3 -u -m http.server 0 --bind 127.0.0.1 --directory "$srv" >"$work/httpd.log" 2>&1 &
server_pid=$!
port=""
i=0
while [ "$i" -lt 100 ]; do
  port="$(sed -n 's/.*port \([0-9][0-9]*\).*/\1/p' "$work/httpd.log" | head -1)"
  [ -n "$port" ] && break
  kill -0 "$server_pid" 2>/dev/null || break
  i=$((i + 1))
  sleep 0.1
done
if [ -z "$port" ]; then
  bad "local HTTP stub started" "$(cat "$work/httpd.log")"
  echo "$PASS passed, $FAIL failed"
  exit 1
fi

# GH_TOKEN is a placeholder the stub ignores: gh refuses to issue a request
# with no credential, and a real one must never be needed to run a suite.
# GH_CONFIG_DIR isolates the run from the developer's own gh config.
re2() { # re2 PROGRAM -> gh's RE2 engine over the stub
  GH_TOKEN=x GH_CONFIG_DIR="$work/gh" GH_NO_UPDATE_NOTIFIER=1 \
    gh api "http://127.0.0.1:$port/pages.json" --jq ".pages[] | ($1)"
}
local_jq() { # local_jq PROGRAM -> the Oniguruma engine every other suite uses
  jq -r ".pages[] | ($1)" "$srv/pages.json"
}

# A probe rewrites the program's text, and "the text changed" is a contract a
# WRONG rewrite also satisfies. plant() refuses unless the anchor occurs
# exactly once, so a drifted anchor reds here instead of leaving the control
# asserting against a program nobody described.
plant() { # plant FROM TO   (program on stdin, mutant on stdout)
  python3 -c '
import sys
src = sys.stdin.read()
frm, to = sys.argv[1], sys.argv[2]
n = src.count(frm)
if n != 1:
    sys.stderr.write("anchor occurs %d times, expected exactly 1: %s\n" % (n, frm))
    sys.exit(1)
sys.stdout.write(src.replace(frm, to))
' "$1" "$2"
}

# ------------------------------------------------------- the shipped program ---
if local_jq "$prog" >"$work/local.out" 2>"$work/local.err"; then local_rc=0; else local_rc=$?; fi
if re2 "$prog" >"$work/re2.out" 2>"$work/re2.err"; then re2_rc=0; else re2_rc=$?; fi

if [ "$local_rc" = 0 ]; then
  ok "the shipped program runs under local jq"
else
  bad "the shipped program runs under local jq" "exit $local_rc: $(head -1 "$work/local.err")"
fi

if [ "$re2_rc" = 0 ]; then
  ok "the shipped program runs under gh's RE2 engine"
else
  bad "the shipped program runs under gh's RE2 engine" "exit $re2_rc: $(head -1 "$work/re2.err")"
fi

if [ "$(wc -l <"$work/re2.out")" = "$replies" ]; then
  ok "RE2 answered every one of the $replies fixture replies"
else
  bad "RE2 answered every one of the $replies fixture replies" "$(wc -l <"$work/re2.out") verdicts"
fi

# THE assertion, in a function, because control three has to be able to kill
# it. A control running its own parallel diff proves the fixture is sensitive
# and nothing about the line under it: misdirect that line and the control
# stays green. Control three overwrites re2.out with a mutant's output and
# calls this, so a comparison that has stopped comparing reds there.
engines_agree() { diff -u "$work/local.out" "$work/re2.out" >"$work/engine.diff" 2>&1; }

if engines_agree; then
  ok "both engines return the same verdict for every fixture reply"
else
  bad "both engines return the same verdict for every fixture reply" "$(head -20 "$work/engine.diff")"
fi

# ------------------------------------------------------------- control one ---
# The #1930 defect, planted back into the line it shipped on: local jq must
# stay green and RE2 must refuse to compile. A suite that keeps passing here
# is reading the wrong engine again.
lookbehind="$(printf '%s' "$prog" | plant \
  'gsub("(?<w>[\\p{L}\\p{N}]+' \
  'gsub("(?<![\\p{L}\\p{N}])(?<w>[\\p{L}\\p{N}]+')" || lookbehind=""
if [ -z "$lookbehind" ] || [ "$lookbehind" = "$prog" ]; then
  bad "control: a lookbehind can be planted" "the anchor matched nothing in the extracted program"
else
  ok "control: a lookbehind can be planted"

  if local_jq "$lookbehind" >/dev/null 2>"$work/lb.local.err"; then
    ok "control: local jq accepts the planted lookbehind (which is why it hid)"
  else
    bad "control: local jq accepts the planted lookbehind (which is why it hid)" \
        "$(head -1 "$work/lb.local.err")"
  fi

  if re2 "$lookbehind" >/dev/null 2>"$work/lb.re2.err"; then
    bad "control: RE2 rejects the planted lookbehind" "the RE2 run succeeded — this suite cannot see the defect it exists for"
  elif grep -q 'invalid regular expression' "$work/lb.re2.err"; then
    ok "control: RE2 rejects the planted lookbehind"
  else
    bad "control: RE2 rejects the planted lookbehind" \
        "failed for some other reason: $(head -1 "$work/lb.re2.err")"
  fi
fi

# ------------------------------------------------------------- control two ---
# Control one plants into a pass every reply reaches. This one plants into the
# untracked-claim test, which sits behind `select(disposition | not)` and is
# compiled only when a reply reaches it — no corpus reply does, and a
# lookbehind planted there once passed this suite 9 for 9. The two appended
# fixture replies are what make it reachable, so this is also the assertion
# that they still are.
claimtest="$(printf '%s' "$prog" | plant \
  'select(test("([A-Z][A-Z0-9]+-[0-9]+' \
  'select(test("(?<![a-z])([A-Z][A-Z0-9]+-[0-9]+')" || claimtest=""
if [ -z "$claimtest" ] || [ "$claimtest" = "$prog" ]; then
  bad "control: a lookbehind can be planted in the untracked-claim test" \
      "the anchor matched nothing in the extracted program"
else
  ok "control: a lookbehind can be planted in the untracked-claim test"
  if re2 "$claimtest" >/dev/null 2>"$work/ct.re2.err"; then
    bad "control: RE2 rejects a lookbehind in the untracked-claim test" \
        "the RE2 run succeeded — no fixture reply reaches that regex, so it is never compiled"
  elif grep -q 'invalid regular expression' "$work/ct.re2.err"; then
    ok "control: RE2 rejects a lookbehind in the untracked-claim test"
  else
    bad "control: RE2 rejects a lookbehind in the untracked-claim test" \
        "failed for some other reason: $(head -1 "$work/ct.re2.err")"
  fi
fi

# ----------------------------------------------------------- control three ---
# The compile-time controls would both pass with the comparison above gone or
# misdirected. This one changes a word the corpus exercises, in a way BOTH
# engines compile, then re-runs `engines_agree` itself — the same line the
# assertion runs — and requires it to say no. re2.out is overwritten on
# purpose; nothing reads it after this.
worded="$(printf '%s' "$prog" | plant '"frozen|freezes?' '"frozzen|freezes?')" || worded=""
if [ -z "$worded" ] || [ "$worded" = "$prog" ]; then
  bad "control: a word-list edit can be planted" "the anchor matched nothing in the extracted program"
else
  ok "control: a word-list edit can be planted"
  if re2 "$worded" >"$work/re2.out" 2>"$work/worded.err"; then
    if engines_agree; then
      bad "control: the comparison reports a real divergence" \
          "a corpus-visible word-list edit produced identical output — the differ is inert"
    else
      ok "control: the comparison reports a real divergence"
    fi
  else
    bad "control: the comparison reports a real divergence" \
        "the mutant did not run under RE2: $(head -1 "$work/worded.err")"
  fi
fi

echo "$PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
