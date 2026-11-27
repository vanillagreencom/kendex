#!/usr/bin/env bash
# Surface: tools/pi-update-check. Inputs: that script.
# npm and gh are fixtures on PATH; the marker, jq and the comparison are real.
# Each row runs the script in its own copy of a tree that holds only the
# script and the marker, and reads its outcome line, the job summary and the
# issues it asked gh to open.
#
# Rows are `label|cleared|marker|latest|issues|create|rc|outcome|opened`:
#   cleared  lastVersion in pi-update.state.json
#   marker   lastTarget in pi-update.state.json, `-` for no marker file
#   latest   what npm prints as the latest version, `!` for a failed read
#   issues   the open-issue listing gh answers, by name below; `!` fails it
#   create   `ok`, or `!` for gh refusing the new issue
#   rc       the exit status
#   outcome  the outcome word on stdout, or a refusal's `key=value` on stderr
#   opened   how many issues the run asked gh to open
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$(cd -- "$TEST_DIR/../.." && pwd -P)"
TMP_ROOT="$(mktemp -d)" || { echo 'pi-update-check.test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'pi-update-check.test: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'pi-update-check.test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

command -v jq >/dev/null 2>&1 || { echo 'pi-update-check.test: jq is required: tools/pi-update-check reads with it' >&2; exit 1; }

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "$2"; }

mkdir -p "$TMP_ROOT/bin"
cat >"$TMP_ROOT/bin/npm" <<'NPM'
#!/usr/bin/env bash
set -euo pipefail
[[ $* == 'view @earendil-works/pi-coding-agent dist-tags.latest' ]] || exit 80
latest="$(cat -- "$WORLD/latest")"
[[ $latest != '!' ]] || exit 1
printf '%s\n' "$latest"
NPM
cat >"$TMP_ROOT/bin/gh" <<'GH'
#!/usr/bin/env bash
set -euo pipefail
if [[ $* == 'api --paginate --slurp repos/{owner}/{repo}/issues?state=open&per_page=100' ]]; then
  [[ -f $WORLD/issues.json ]] || exit 1
  cat -- "$WORLD/issues.json"
  exit 0
fi
[[ $1 == issue && $2 == create ]] || exit 80
shift 2
title=""
while (($#)); do
  case "$1" in
    --title) title="$2"; shift 2 ;;
    --label | --body) shift 2 ;;
    *) exit 80 ;;
  esac
done
[[ -n $title ]] || exit 80
[[ ! -f $WORLD/create-fails ]] || exit 1
printf '%s\n' "$title" >>"$WORLD/created"
printf 'https://github.com/fixture/repo/issues/%s\n' "$(wc -l <"$WORLD/created" | tr -d ' ')"
GH
chmod +x "$TMP_ROOT/bin/npm" "$TMP_ROOT/bin/gh"

BOT='{"login":"github-actions[bot]","type":"Bot"}'
issues_json() { # NAME — the listing gh answers, pages as --slurp returns them
  case "$1" in
    none) printf '[[]]' ;;
    unrelated) printf '[[{"number":5,"title":"pi-hooks: a hook misses a tool result","user":%s}]]' "$BOT" ;;
    # A pull request with no matching title, then the open item on page two.
    page2) printf '[[{"number":6,"title":"pi-qol: one","user":%s,"pull_request":{}}],[{"number":207,"title":"pi-update: audit the kendex Pi extensions against Pi 1.6.1","user":%s}]]' "$BOT" "$BOT" ;;
    # Anyone can open an issue with the audit title.
    outsider) printf '[[{"number":8,"title":"pi-update: audit the kendex Pi extensions against Pi 1.7.0","user":{"login":"someone","type":"User"},"author_association":"NONE"}]]' ;;
    # The item for the audit that moved the marker to 1.6.0, still open.
    residue) printf '[[{"number":9,"title":"pi-update: audit the kendex Pi extensions against Pi 1.6.0","user":%s}]]' "$BOT" ;;
    *) printf 'pi-update-check.test: no issues fixture %s\n' "$1" >&2; return 1 ;;
  esac
}

N=0
world() { # CLEARED MARKER LATEST ISSUES CREATE — a fresh tree, its path in DIR
  N=$((N + 1))
  DIR="$TMP_ROOT/w$N"
  local dir="$DIR"
  mkdir -p "$dir/tree/tools" "$dir/tree/pi-extensions"
  cp -p -- "$ROOT/tools/pi-update-check" "$dir/tree/tools/pi-update-check"
  if [[ $2 != - ]]; then
    printf '{"lastVersion": "%s", "lastDate": "2026-11-20", "lastTarget": "%s"}\n' "$1" "$2" >"$dir/tree/pi-extensions/pi-update.state.json"
  fi
  printf '%s\n' "$3" >"$dir/latest"
  if [[ $4 != '!' ]]; then
    issues_json "$4" >"$dir/issues.json"
  fi
  if [[ $5 == '!' ]]; then
    : >"$dir/create-fails"
  fi
}

# Runs the script in world $1; sets RC, OUT, ERR, SUMMARY_LINES and OPENED.
run_in() {
  RC=0
  (cd -- "$1/tree" && WORLD="$1" GITHUB_STEP_SUMMARY="$1/summary" \
    PATH="$TMP_ROOT/bin:$ROOT/tools/tests/lib/sealed-bin:$PATH" \
    tools/pi-update-check) >"$1/stdout" 2>"$1/stderr" || RC=$?
  OUT="$(cat -- "$1/stdout")"
  ERR="$(cat -- "$1/stderr")"
  SUMMARY_LINES=0
  [[ ! -f $1/summary ]] || SUMMARY_LINES=$(wc -l <"$1/summary" | tr -d ' ')
  OPENED=0
  [[ ! -f $1/created ]] || OPENED=$(wc -l <"$1/created" | tr -d ' ')
}

# The outcome word of a success line, or the key=value of a refusal.
read_outcome() {
  local line words
  if ((RC == 0)); then
    line="$OUT"
    read -r -a words <<<"$line"
    printf '%s' "${words[1]:-}"
  else
    line="$ERR"
    line="${line##*$'\n'}"
    line="${line#pi-update-check: }"
    printf '%s' "${line%% *}"
  fi
}

ROWS='
newer release, nothing open|1.6.0|1.6.0|1.6.1|none|ok|0|opened|1
equal release|1.6.0|1.6.0|1.6.0|none|ok|0|current|0
a hold read the latest release|1.5.2|1.6.0|1.6.0|none|ok|0|current|0
older latest|1.6.0|1.6.0|1.5.2|none|ok|0|current|0
newer by a two-digit minor|1.9.0|1.9.0|1.10.0|none|ok|0|opened|1
newer major, older minor|1.6.0|1.6.0|2.0.0|none|ok|0|opened|1
an unrelated issue is open|1.6.0|1.6.0|1.6.1|unrelated|ok|0|opened|1
the open item is on page two|1.6.0|1.6.0|1.7.0|page2|ok|0|open|0
an outside author holds the title|1.6.0|1.6.0|1.6.1|outsider|ok|0|opened|1
the open item is at the marker|1.6.0|1.6.0|1.6.1|residue|ok|0|opened|1
no marker file|1.6.0|-|1.6.1|none|ok|2|marker=unreadable|0
npm read fails|1.6.0|1.6.0|!|none|ok|2|npm=failed|0
npm latest is a prerelease|1.6.0|1.6.0|1.7.0-rc.1|none|ok|2|npm=invalid|0
issue listing fails|1.6.0|1.6.0|1.6.1|!|ok|2|issues=failed|0
gh refuses the issue|1.6.0|1.6.0|1.6.1|none|!|2|create=failed|0
'

while IFS='|' read -r label cleared marker latest issues create rc outcome opened; do
  [[ -n $label ]] || continue
  world "$cleared" "$marker" "$latest" "$issues" "$create"
  run_in "$DIR"
  got="$(read_outcome)"
  want_summary=0
  ((rc != 0)) || want_summary=1
  if [[ $RC == "$rc" && $got == "$outcome" && $OPENED == "$opened" && $SUMMARY_LINES == "$want_summary" ]]; then
    ok "$label"
  else
    bad "$label" "rc=$RC outcome=$got opened=$OPENED summary-lines=$SUMMARY_LINES; want rc=$rc outcome=$outcome opened=$opened summary-lines=$want_summary; stderr: $ERR"
  fi
done <<<"$ROWS"

# The issue a run opens is the open item the next run finds: at most one at a
# time.
world 1.6.0 1.6.0 1.6.1 none ok
run_in "$DIR"
title="$(cat -- "$DIR/created")"
world 1.6.0 1.6.0 1.7.0 none ok
jq -cn --arg title "$title" --argjson user "$BOT" '[[{number: 301, title: $title, user: $user}]]' >"$DIR/issues.json"
run_in "$DIR"
if [[ $RC == 0 && $(read_outcome) == open && $OUT == *' issue=301 '* && $OPENED == 0 ]]; then
  ok 'the opened issue holds the next run'
else
  bad 'the opened issue holds the next run' "rc=$RC out=$OUT opened=$OPENED stderr: $ERR"
fi

printf 'pi-update-check.test: %d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
