#!/usr/bin/env bash
# The predicate hands its thread jq to `gh --jq`, and gh's regex engine is
# Go's RE2: no lookaround, at all. Every other suite beside this one runs
# that same program through the LOCAL jq, whose Oniguruma accepts patterns
# RE2 refuses to compile — so a green battery proved nothing about the path
# that actually runs. #1930 shipped a lookbehind on exactly that seam: local
# jq took it, and every live evaluation of a PR carrying a `Declined:` reply
# died with `invalid regular expression`, which the gate reports as a read
# failure and fails closed on.
#
# This suite is the missing half: the SHIPPED program, through the SHIPPED
# engine. The real `gh` (not the tests' shim) is pointed at a local HTTP
# stub, so `gh api --jq` runs with no network and no credentials, and its
# verdict for every corpus reply must equal the local jq's.
#
# Two controls, because "the outputs matched" is a claim a broken harness
# also makes:
#   1. a planted `(?<!` must red the RE2 run while local jq stays green —
#      the #1930 defect, reproduced on demand;
#   2. a planted word-list edit must make the comparison REPORT a
#      difference — proof the differ is looking at anything.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PRED="$SCRIPT_DIR/../scripts/review-predicate.sh"
CORPUS="$SCRIPT_DIR/corpus"
PASS=0 FAIL=0
ok()  { PASS=$((PASS+1)); echo "  ok    $1"; }
bad() { FAIL=$((FAIL+1)); echo "  FAIL  $1"; echo "        got: $2"; }

# Both are hard requirements, never a skip: this suite exists because the
# engine that matters was never exercised, and a suite that quietly opts out
# when a tool is missing recreates that hole with a green tick on it.
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
# One page envelope per corpus reply, so the comparison is per reply rather
# than one aggregate count two divergences could cancel inside. The corpus
# files are the fixtures here as everywhere else in this directory.
cat "$CORPUS"/*.txt | grep -v '^#' | grep -v '^[[:space:]]*$' \
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
  ok "RE2 answered every one of the $replies corpus replies"
else
  bad "RE2 answered every one of the $replies corpus replies" "$(wc -l <"$work/re2.out") verdicts"
fi

if diff -u "$work/local.out" "$work/re2.out" >"$work/engine.diff" 2>&1; then
  ok "both engines return the same verdict for every corpus reply"
else
  bad "both engines return the same verdict for every corpus reply" "$(head -20 "$work/engine.diff")"
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
# A compile-time control alone would pass with the comparison above deleted.
# This one changes a word the corpus exercises, in a way BOTH engines
# compile, and requires the differ to say so.
worded="$(printf '%s' "$prog" | plant '"frozen|freezes?' '"frozzen|freezes?')" || worded=""
if [ -z "$worded" ] || [ "$worded" = "$prog" ]; then
  bad "control: a word-list edit can be planted" "the anchor matched nothing in the extracted program"
else
  ok "control: a word-list edit can be planted"
  if re2 "$worded" >"$work/worded.out" 2>"$work/worded.err"; then
    if diff -q "$work/local.out" "$work/worded.out" >/dev/null 2>&1; then
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
