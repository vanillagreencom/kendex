#!/usr/bin/env bash
# The secret-value pattern in ../references/secret-value.ere, read the way its
# header says: the one line that is neither empty nor a comment, run through
# both readers the header names, grep and Python's re. Every row must get its
# verdict from both. A token row is built here from a prefix and a generated
# tail, so this file holds no string a secret scanner takes for a key.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

PATTERN_FILE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/references/secret-value.ere"
SCRATCH="$(mktemp -d)"
trap 'rm -rf "$SCRATCH"' EXIT
PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

echo "=== orch secret-value pattern ==="

# load_pattern FILE: the header's reader contract. Prints the pattern, or
# returns 1 when the file holds no pattern line or several.
load_pattern() {
  local lines rc=0
  lines="$(grep -v -e '^#' -e '^$' -- "$1")" || rc=$?
  [ "$rc" -eq 0 ] || return 1
  case "$lines" in *$'\n'*) return 1 ;; esac
  printf '%s\n' "$lines"
}

# The two readers, each printing sensitive, clean or error.
grep_verdict() { # PATTERN FILE
  local rc=0
  env -i PATH="$PATH" LC_ALL=C grep -aiE -e "$1" -- "$2" >/dev/null 2>&1 || rc=$?
  case "$rc" in 0) echo sensitive ;; 1) echo clean ;; *) echo error ;; esac
}
python_verdict() { # PATTERN FILE
  env -i PATH="$PATH" python3 -B -c '
import re, sys
data = open(sys.argv[2], "rb").read()
print("sensitive" if re.compile(sys.argv[1].encode(), re.I | re.M).search(data) else "clean")
' "$1" "$2" 2>/dev/null || echo error
}

if PATTERN="$(load_pattern "$PATTERN_FILE")"; then
  pass "the file holds exactly one pattern line"
else
  fail "secret-value.ere must hold exactly one line that is neither empty nor a comment"
  printf 'pass: %s   fail: %s\n' "$PASS" "$FAIL"
  exit 1
fi

# NAME|TEXT|VERDICT. In TEXT, `@` is a key tail long enough for every prefix
# and `~` is a line break.
TAIL="Ab3dEf5hIj7lMn9pQr1tUv2x"
ROWS="$(cat <<'EOF'
an RSA private-key header|-----BEGIN RSA PRIVATE KEY-----|sensitive
a bare private-key header|-----BEGIN PRIVATE KEY-----|sensitive
an OpenPGP private-key armor header|-----BEGIN PGP PRIVATE KEY BLOCK-----|sensitive
a GitHub personal token|ghp_@|sensitive
a GitHub OAuth token|gho_@|sensitive
a GitHub user token|ghu_@|sensitive
a GitHub server token|ghs_@|sensitive
a GitHub refresh token|ghr_@|sensitive
a GitHub fine-grained token|github_pat_@|sensitive
an sk- key|sk-@|sensitive
an sk- key with separators in its tail|key=sk-ant-api03-aB-_aB-_@|sensitive
a Slack bot token|xoxb-@|sensitive
a Slack app-level token|xapp-@|sensitive
a Slack app token in capitals|XAPP-@|sensitive
a Slack app token with its numbered segment|xapp-1-@|sensitive
a Slack bot token with its numeric segments|xoxb-1234567890-1234567890-@|sensitive
a Slack xoxp- token|xoxp-@|sensitive
a Slack xoxa- token|xoxa-@|sensitive
a Slack xoxr- token|xoxr-@|sensitive
a Slack xoxs- token|xoxs-@|sensitive
a token as an env value|SLACK_BOT_TOKEN=xoxb-@|sensitive
a token in a JSON string|{"token": "xapp-@"}|sensitive
a token at the start of a later line|report line~xapp-@|sensitive
a fleet record quoting keyed output|secrets=22 plain=0|clean
an empty keyed value|tokens=|clean
a secret key naming a store entry|{"secret": "fleet-slack-bot-token"}|clean
a prefix glued to a word|myxapp-@|clean
an sk- prefix inside a word|desk-@|clean
an app prefix with a short tail|xapp-1-short|clean
a prefix named in prose|the xapp- and xoxb- prefixes|clean
a short sk- word|sk-learn|clean
EOF
)"

# row_text TEXT: the row's bytes with `@` and `~` expanded.
row_text() {
  local text=${1//@/$TAIL} nl=$'\n'
  printf '%s\n' "${text//\~/$nl}"
}

run_rows() { # PATTERN LABEL
  local name text want i=0 file got_grep got_python
  while IFS='|' read -r name text want; do
    i=$((i + 1))
    file="$SCRATCH/row-$2-$i"
    row_text "$text" >"$file"
    got_grep="$(grep_verdict "$1" "$file")"
    got_python="$(python_verdict "$1" "$file")"
    if [ "$got_grep" = "$want" ] && [ "$got_python" = "$want" ]; then
      pass "$2: $name is $want"
    else
      fail "$2: $name must be $want (grep=$got_grep python=$got_python)"
    fi
  done <<<"$ROWS"
}

run_rows "$PATTERN" pattern

# Control: the pattern without its app-token branch must read an app token as
# clean, so the xapp rows above hold that branch and not a neighbour of it.
APP_BRANCH='|xapp-[A-Za-z0-9-]{10,}'
MUTANT="$(awk -v p="$APP_BRANCH" '{ i = index($0, p); if (i) $0 = substr($0, 1, i - 1) substr($0, i + length(p)); print }' <<<"$PATTERN")"
row_text 'xapp-@' >"$SCRATCH/control"
if [ "$MUTANT" = "$PATTERN" ]; then
  fail "control: the pattern carries no $APP_BRANCH branch to remove"
elif [ "$(grep_verdict "$MUTANT" "$SCRATCH/control")" != clean ] ||
  [ "$(python_verdict "$MUTANT" "$SCRATCH/control")" != clean ]; then
  fail "control: a pattern with no app-token branch still refuses an app token"
else
  pass "control: a pattern with no app-token branch passes an app token"
fi

printf 'pass: %s   fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
