#!/usr/bin/env bash
# Pins for scripts/secrets: a credential gitleaks' default rules match is
# refused at its path, line and rule id under every scope, and the value never
# reaches the output; under a diff scope only a finding on an added line
# counts, and a range judges each commit it holds against that commit's
# parents; the repository cannot switch a finding off through gitleaks' own
# allowlists; a missing or too-old gitleaks is a gap notice that passes,
# except under CI on a range or --all scan; a gitleaks run that fails, or a
# report the lane cannot read, is exit 2. Each row builds a fresh repository
# and pins the exit status with the first stable line.
#
# The credentials are assembled at run time, so this file holds none a scan
# of it would find.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"

command -v gitleaks >/dev/null || {
  echo "harness: gitleaks is not on PATH; this suite runs the lane's tool" >&2
  exit 2
}

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}

CRED="AKIA""Z7Q3R5T2V4X6Y7W2"
PK_HEAD="-----BEGIN RSA PRIVATE ""KEY-----"
PK_FOOT="-----END RSA PRIVATE ""KEY-----"
PK_BODY="MIIEowIBAAKCAQEAu1SU1LfVLPHCozMxH2Mo4lgOEePzNm0tRgeL\nezV6ffAt0gunVTLw7onLRnrq0IzW7yWR7QkrmBL7jTKEn5uqKhbw\n"

# A gitleaks configuration that allowlists the path the rows stage it beside.
ALLOW_TOML="[extend]\nuseDefault = true\n[allowlist]\npaths = ['''cred\\\\.txt''']\n"

LANE="$SKILL_DIR/scripts/secrets"
# Every run sets OUT to the whole output and prints the exit status and the
# first stable line. OUT reaches a row only where the helper runs in the
# row's own shell, never inside $( ). CI and GITHUB_ACTIONS are passed
# explicitly, empty unless the row sets one, so a run inside a CI job judges
# what a developer machine would.
first_line() { # RC
  printf 'rc=%s %s' "$1" "$(printf '%s\n' "$OUT" | LC_ALL=C awk '/^secrets: [a-z-]+=/ && !seen { print; seen=1 }')"
}
run_with() { # PATH-VALUE ENV-WORDS REPO ARGS... — ENV-WORDS are NAME=VALUE words for env
  local path="$1" words="$2" repo="$3" rc=0
  shift 3
  # shellcheck disable=SC2086 # ENV-WORDS split into env's NAME=VALUE arguments
  OUT="$(cd "$repo" && env PATH="$path" CI= GITHUB_ACTIONS= $words "$LANE" "$@" 2>&1)" || rc=$?
  first_line "$rc"
}
run() { run_with "$PATH" "" "$@"; } # REPO ARGS...

env_run() { # REPO — run with the allowlisting configuration in the environment
  local rc=0
  OUT="$(cd "$1" && CI= GITHUB_ACTIONS= GITLEAKS_CONFIG_TOML="$(printf '%b' "$ALLOW_TOML")" "$LANE" 2>&1)" || rc=$?
  first_line "$rc"
}

LEAK=""
leak() { # sets LEAK to present or absent: whether OUT carries the credential
  case "$OUT" in
    (*"$CRED"*) LEAK=present ;;
    (*) LEAK=absent ;;
  esac
}

R=""
repo() { # NAME
  R="$TMP/$1"
  [ ! -e "$R" ] || { echo "harness: fixture $1 already exists" >&2; exit 2; }
  git -c init.defaultBranch=main init -q "$R"
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  git -C "$R" config gc.auto 0
  git -C "$R" config maintenance.auto false
}
put() { mkdir -p "$R/$(dirname "$1")"; printf '%b' "$2" >"$R/$1"; git -C "$R" add -A; } # PATH CONTENT (printf %b), staged
commit() { git -C "$R" commit -qm "${1:-seed}"; }

echo "=== a credential is refused at its path, line and rule id, without its value ==="
repo staged
put "notes/a file.txt" "one\naws = $CRED\n"
run "$R" >"$TMP/first"
assert_eq "a staged credential is refused at its line under --staged, the default" \
  "rc=1 secrets: secret=notes/a file.txt:2:aws-access-token" "$(cat "$TMP/first")"
leak
assert_eq "the output never carries the value" "absent" "$LEAK"
STAGED="$R"
repo clean
put ok.txt "nothing to see\n"
assert_eq "a clean staged file is judged and passes" \
  "rc=0 secrets: summary=violations=0 files=1 scope=staged skipped=0" "$(run "$R")"

echo "=== a diff scope counts a finding only on an added line ==="
repo old-cred
put cred.txt "aws = $CRED\n"
commit
put cred.txt "aws = $CRED\nmore\n"
assert_eq "a staged change beside a committed credential passes: the commit adds no credential" \
  "rc=0 secrets: summary=violations=0 files=1 scope=staged skipped=0" "$(run "$R")"
assert_eq "control: --all judges every line, so the committed credential fails" \
  "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$(run "$R" --all)"
OLD_CRED="$R"
repo key-body
put key.pem "$PK_HEAD\n$PK_FOOT\n"
commit
put key.pem "$PK_HEAD\n$PK_BODY$PK_FOOT\n"
assert_eq "a finding spanning lines counts where an inner line is added" \
  "rc=1 secrets: secret=key.pem:1:private-key" "$(run "$R")"
KEY_BODY="$R"
# Two staged files whose added lines differ: a.txt sorts first and adds line
# 1, b.txt adds a later line. Each finding is held to its own file's list.
repo two-old
put b.txt "aws = $CRED\n"
commit
put a.txt "new\n"
put b.txt "aws = $CRED\nmore\n"
assert_eq "a credential on a line another staged file adds, but its own file does not, passes" \
  "rc=0 secrets: summary=violations=0 files=2 scope=staged skipped=0" "$(run "$R")"
TWO_OLD="$R"
repo two-new
put b.txt "x\n"
commit
put a.txt "new\n"
put b.txt "x\naws = $CRED\n"
assert_eq "a credential the second file adds, on a line the first file does not add, fails" \
  "rc=1 secrets: secret=b.txt:2:aws-access-token" "$(run "$R")"
TWO_NEW="$R"

echo "=== a range judges each commit it holds against that commit's parents ==="
repo range
put base.txt "base\n"
commit
put cred.txt "x\naws = $CRED\n"
commit added
assert_eq "--against REF refuses a credential the range adds" \
  "rc=1 secrets: secret=cred.txt:2:aws-access-token" "$(run "$R" --against HEAD~1)"
assert_eq "--base REF refuses it too" \
  "rc=1 secrets: secret=cred.txt:2:aws-access-token" "$(run "$R" --base HEAD~1)"
RANGE_ADD="$R"
put cred.txt "x\naws = $CRED\ny\n"
commit later
assert_eq "a range that adds a line beside an older credential passes" \
  "rc=0 secrets: summary=violations=0 files=1 scope=against skipped=0" "$(run "$R" --against HEAD~1)"
repo removed
put base.txt "base\n"
commit
put cred.txt "aws = $CRED\n"
commit added
git -C "$R" rm -q cred.txt
commit removed
assert_eq "a credential one commit adds and a later commit removes is refused under --against" \
  "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$(run "$R" --against HEAD~2)"
assert_eq "and under --base" \
  "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$(run "$R" --base HEAD~2)"
REMOVED="$R"
# side merges main, whose own commit added a credential: the merge carries
# main's line and adds none of its own. evil merges the same main and writes
# a credential into the merge itself.
repo merge
put base.txt "base\n"
commit
git -C "$R" checkout -q -b side
put s.txt "side\n"
commit side
git -C "$R" checkout -q main
put m.txt "m\naws = $CRED\n"
commit main-cred
git -C "$R" checkout -q -b evil side
git -C "$R" checkout -q side
git -C "$R" merge -q --no-edit main
assert_eq "a merge passes the lines a parent already carried" \
  "rc=0 secrets: summary=violations=0 files=2 scope=against skipped=0" "$(run "$R" --against main)"
MERGE="$R"
git -C "$R" checkout -q evil
git -C "$R" merge -q --no-commit main >/dev/null 2>&1
put s.txt "side\naws = $CRED\n"
commit evil-merge
assert_eq "a line a merge adds over both parents is refused" \
  "rc=1 secrets: secret=s.txt:2:aws-access-token" "$(run "$R" --against main)"
git -C "$R" checkout -q --orphan orphan
git -C "$R" rm -rqf .
put o.txt "aws = $CRED\n"
commit orphan
assert_eq "a commit with no parent adds every line it holds" \
  "rc=1 secrets: secret=o.txt:1:aws-access-token" "$(run "$R" --against main)"
SHALLOW="$TMP/shallow"
git clone -q --depth 2 --branch evil "file://$MERGE" "$SHALLOW"
MAIN_TIP="$(git -C "$MERGE" rev-parse main)"
assert_eq "a shallow boundary inside the range refuses: its parents were never fetched" \
  "rc=2 secrets: range-shallow=$MAIN_TIP" "$(run "$SHALLOW" --against HEAD^1)"

echo "=== the repository's own gitleaks allowlists switch nothing off; the excludes list does ==="
# No production edit short of moving the scratch tree back under the
# repository reddens the next two rows: the copies sit at r/<n>/<path>
# beneath the directory gitleaks runs in, where no tracked file can land at
# the root it reads a .gitleaks.toml or a .gitleaksignore from. The rows hold
# that the guarantee survives. The .gitleaksignore carries every spelling of
# the finding's fingerprint gitleaks could compute.
repo toml
put .gitleaks.toml "$ALLOW_TOML"
put cred.txt "aws = $CRED\n"
assert_eq "a .gitleaks.toml allowlisting the path is not read" \
  "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$(run "$R")"
repo ignore
put .gitleaksignore "cred.txt:aws-access-token:1\nr/0/cred.txt:aws-access-token:1\nr/1/cred.txt:aws-access-token:1\n"
put cred.txt "aws = $CRED\n"
assert_eq "a .gitleaksignore naming the fingerprint is not read" \
  "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$(run "$R")"
repo env-config
put cred.txt "aws = $CRED\n"
assert_eq "a GITLEAKS_CONFIG_TOML in the environment is outranked" \
  "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$(env_run "$R")"
ENV_CONFIG="$R"
repo inline
put cred.txt "aws = $CRED # gitleaks:allow\n"
assert_eq "an inline gitleaks:allow comment is not honoured" \
  "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$(run "$R")"
INLINE="$R"
repo excluded
put tools/secrets-excludes "fixtures/*\tfake credentials the suite asserts against\n"
put fixtures/cred.txt "aws = $CRED\n"
assert_eq "a reasoned row in the excludes list passes the path" \
  "rc=0 secrets: summary=violations=0 files=1 scope=staged skipped=0" "$(run "$R")"

echo "=== the tool: missing or too old is a gap outside CI and on --staged, a refusal on a CI range or --all ==="
NO_TOOL_PATH="$TMP/no-tool-bin"
mkdir -p "$NO_TOOL_PATH"
for cmd in bash env git mktemp dirname rm tr head wc cp mv mkdir cut cat awk sort grep; do
  cmd_path="$(command -v "$cmd")" || { echo "harness: $cmd is not on PATH" >&2; exit 2; }
  ln -s -- "$cmd_path" "$NO_TOOL_PATH/$cmd"
done
gap_run() { run_with "$NO_TOOL_PATH" "" "$@"; } # REPO ARGS... — no gitleaks reachable
ci_gap_run() { run_with "$NO_TOOL_PATH" "$1=true" "${@:2}"; } # VAR REPO ARGS... — and VAR=true
# A gitleaks older than 8.19, the release that added `dir`: gitleaks 8.18.4
# answers `dir` with this error and exit 1, and `version` with its number.
OLD_PATH="$TMP/old-bin"
mkdir -p "$OLD_PATH"
cat >"$OLD_PATH/gitleaks" <<'EOF'
#!/usr/bin/env bash
if [ "${1-}" = version ]; then echo 8.18.4; exit 0; fi
echo "Error: unknown command \"${1-}\" for \"gitleaks\"" >&2
exit 1
EOF
chmod +x "$OLD_PATH/gitleaks"
old_run() { run_with "$OLD_PATH:$PATH" "" "$@"; } # REPO ARGS...
ci_old_run() { run_with "$OLD_PATH:$PATH" "CI=true" "$@"; } # REPO ARGS...
repo gap
put cred.txt "aws = $CRED\n"
assert_eq "a selected file with no gitleaks installed passes at the gap notice" \
  "rc=0 secrets: gap=gitleaks-missing:1" "$(gap_run "$R")"
GAP="$R"
repo gap-all
put cred.txt "aws = $CRED\n"
commit
assert_eq "outside CI an --all scan with no gitleaks passes at the gap notice too" \
  "rc=0 secrets: gap=gitleaks-missing:1" "$(gap_run "$R" --all)"
assert_eq "under CI an --all scan with no gitleaks refuses" \
  "rc=2 secrets: tool-missing=gitleaks" "$(ci_gap_run CI "$R" --all)"
assert_eq "GITHUB_ACTIONS alone marks CI as well" \
  "rc=2 secrets: tool-missing=gitleaks" "$(ci_gap_run GITHUB_ACTIONS "$R" --all)"
assert_eq "under CI a range scan with no gitleaks refuses" \
  "rc=2 secrets: tool-missing=gitleaks" "$(ci_gap_run CI "$RANGE_ADD" --against HEAD~2)"
assert_eq "under CI the commit scope keeps the gap" \
  "rc=0 secrets: gap=gitleaks-missing:1" "$(ci_gap_run CI "$STAGED")"
GAP_ALL="$R"
assert_eq "a gitleaks older than 8.19 passes at the gap notice" \
  "rc=0 secrets: gap=gitleaks-unusable:1" "$(old_run "$R" --all)"
assert_eq "under CI it refuses" \
  "rc=2 secrets: tool-unusable=gitleaks" "$(ci_old_run "$R" --all)"
repo nothing
put seed.txt "seed\n"
commit
assert_eq "a scope selecting no file looks for no tool" \
  "rc=0 secrets: summary=violations=0 files=0 scope=staged skipped=0" "$(gap_run "$R")"
NOTHING="$R"

# A stand-in gitleaks: it answers the lane's `dir --help` probe, STUB_EXIT is
# its scan's status, and STUB_REPORT, when set, the report it writes where
# --report-path points.
STUB_PATH="$TMP/stub-bin"
mkdir -p "$STUB_PATH"
cat >"$STUB_PATH/gitleaks" <<'EOF'
#!/usr/bin/env bash
for arg in "$@"; do
  [ "$arg" != --help ] || exit 0
done
while [ $# -gt 0 ]; do
  if [ "$1" = --report-path ]; then
    [ -z "${STUB_REPORT-}" ] || printf '%s\n' "$STUB_REPORT" >"$2"
  fi
  shift
done
echo "stub gitleaks: failing as asked"
exit "$STUB_EXIT"
EOF
chmod +x "$STUB_PATH/gitleaks"
stub_run() { # EXIT REPORT REPO
  local rc=0
  OUT="$(cd "$3" && CI= GITHUB_ACTIONS= PATH="$STUB_PATH:$PATH" STUB_EXIT="$1" STUB_REPORT="$2" "$LANE" 2>&1)" || rc=$?
  first_line "$rc"
}
assert_eq "gitleaks' own failure status refuses rather than reading as a leak" \
  "rc=2 secrets: tool-failed=gitleaks:1" "$(stub_run 1 "" "$GAP")"
assert_eq "a report that is not an array refuses" \
  "rc=2 secrets: tool-output=jq:5" "$(stub_run 3 "{}" "$GAP")"

echo "=== must-fail controls: a copy of the lane with one rule removed ==="
# Each control copies the scripts and changes one line of the lane, asserting
# the line matched once and the file changed, then reruns the row that rule
# decides.
mutant() { # NAME FROM TO — a copy of the lane with FROM replaced by TO
  local dir="$TMP/mutant-$1" before matches
  cp -R "$SKILL_DIR/scripts" "$dir"
  before="$(cat -- "$dir/secrets")"
  matches="$(FROM="$2" awk 'index($0, ENVIRON["FROM"]) { n++ } END { print n + 0 }' "$dir/secrets")"
  [ "$matches" -eq 1 ] || { echo "harness: control $1 matched $matches lines" >&2; exit 2; }
  FROM="$2" TO="$3" awk '{ i = index($0, ENVIRON["FROM"]); if (i) $0 = substr($0, 1, i - 1) ENVIRON["TO"] substr($0, i + length(ENVIRON["FROM"])); print }' \
    "$dir/secrets" >"$dir/secrets.new"
  mv -- "$dir/secrets.new" "$dir/secrets"
  chmod +x "$dir/secrets"
  [ "$before" != "$(cat -- "$dir/secrets")" ] || { echo "harness: control $1 changed nothing" >&2; exit 2; }
  LANE="$dir/secrets"
}
mutant prints-value 'gg_message secret "${PATHS[$n]}:$start:$rule"' 'gg_message secret "${PATHS[$n]}:$start:$rule:$(cat -- "$GG_TMP/tree/r/$n/${PATHS[$n]}")"'
run "$STAGED" >/dev/null
leak
assert_eq "control: a lane that prints the matched line carries the value" "present" "$LEAK"
mutant added-filter 'if [ -n "$LINES" ]; then' 'if false; then'
assert_eq "control: without the added-line filter the committed credential fails the staged change" \
  "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$(run "$OLD_CRED")"
mutant span '$1 >= s && $1 <= e' '$1 == s'
assert_eq "control: matching the first line alone misses the added key body" \
  "rc=0 secrets: summary=violations=0 files=1 scope=staged skipped=0" "$(run "$KEY_BODY")"
mutant first-list '"$GG_TMP/added/$n" 2>"$GG_TMP/added.err"' '"$GG_TMP/added/0" 2>"$GG_TMP/added.err"'
assert_eq "control: holding every finding to the first file's lines fails the old credential" \
  "rc=1 secrets: secret=b.txt:1:aws-access-token" "$(run "$TWO_OLD")"
assert_eq "control: and misses the second file's new credential" \
  "rc=0 secrets: summary=violations=0 files=2 scope=staged skipped=0" "$(run "$TWO_NEW")"
mutant range-lines 'gg_added_lines "$1" "$p..$COMMIT"' 'gg_added_lines "$1"'
assert_eq "control: reading the index instead of the commit finds no added line" \
  "rc=0 secrets: summary=violations=0 files=2 scope=against skipped=0" "$(run "$RANGE_ADD" --against HEAD~2)"
mutant net-diff 'git rev-list --reverse --parents --right-only "$range"' 'printf "%s %s\n" "$(git rev-parse HEAD)" "$(git rev-parse "$REF")"'
assert_eq "control: judging the net diff of the range passes the removed credential" \
  "rc=0 secrets: summary=violations=0 files=0 scope=against skipped=0" "$(run "$REMOVED" --against HEAD~2)"
mutant first-parent 'for p in $PARENTS; do' 'for p in ${PARENTS%% *}; do'
git -C "$MERGE" checkout -q side
assert_eq "control: a merge judged against its first parent alone fails the line main carried" \
  "rc=1 secrets: secret=m.txt:2:aws-access-token" "$(run "$MERGE" --against main)"
mutant no-merges '--parents --right-only' '--parents --no-merges --right-only'
git -C "$MERGE" checkout -q evil
assert_eq "control: skipping merges passes the merge's own credential" \
  "rc=0 secrets: summary=violations=0 files=1 scope=against skipped=0" "$(run "$MERGE" --against main)"
mutant root '1) PARENTS="$empty" ;;' '1) continue ;;'
git -C "$MERGE" checkout -q orphan
assert_eq "control: skipping a parentless commit passes its credential" \
  "rc=0 secrets: summary=violations=0 files=0 scope=against skipped=0" "$(run "$MERGE" --against main)"
git -C "$MERGE" checkout -q evil
mutant shallow 'grep -Fxq -- "$COMMIT" "$shallow"' 'grep -Fxq -- "$COMMIT" /dev/null'
assert_eq "control: a shallow boundary read as a root commit judges every line it holds" \
  "rc=1 secrets: secret=m.txt:2:aws-access-token" "$(run "$SHALLOW" --against HEAD^1)"
mutant config '--config "$GG_TMP/gitleaks.toml"' '--log-level warn'
assert_eq "control: without the config flag the environment's configuration allowlists the path" \
  "rc=0 secrets: summary=violations=0 files=1 scope=staged skipped=0" "$(env_run "$ENV_CONFIG")"
mutant inline '--ignore-gitleaks-allow' '--no-color'
assert_eq "control: without --ignore-gitleaks-allow the inline comment allows the line" \
  "rc=0 secrets: summary=violations=0 files=1 scope=staged skipped=0" "$(run "$INLINE")"
mutant ci-ignored '{ [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; }' 'false'
assert_eq "control: a lane blind to CI passes an --all scan with no gitleaks" \
  "rc=0 secrets: gap=gitleaks-missing:1" "$(ci_gap_run CI "$GAP_ALL" --all)"
mutant ci-always '{ [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; }' 'true'
assert_eq "control: a lane that refuses outside CI stops the change" \
  "rc=2 secrets: tool-missing=gitleaks" "$(gap_run "$GAP_ALL" --all)"
mutant ci-only '{ [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; }' '[ -n "${CI:-}" ]'
assert_eq "control: a lane reading CI alone misses GITHUB_ACTIONS" \
  "rc=0 secrets: gap=gitleaks-missing:1" "$(ci_gap_run GITHUB_ACTIONS "$GAP_ALL" --all)"
mutant staged-refuses '    CI_REFUSES=0' '    CI_REFUSES=1'
assert_eq "control: a commit scope that refuses under CI stops the commit" \
  "rc=2 secrets: tool-missing=gitleaks" "$(ci_gap_run CI "$STAGED")"
mutant no-probe 'elif ! gitleaks dir --help >/dev/null 2>&1; then' 'elif false; then'
assert_eq "control: without the probe a gitleaks older than 8.19 fails the run" \
  "rc=2 secrets: tool-failed=gitleaks:1" "$(old_run "$GAP_ALL" --all)"
mutant empty-scope 'if [ "${#PATHS[@]}" -eq 0 ]; then' 'if false; then'
assert_eq "control: without the empty-scope exit the lane looks for the tool" \
  "rc=0 secrets: gap=gitleaks-missing:0" "$(gap_run "$NOTHING")"
mutant leak-status '  0 | 3) ;;' '  0 | 1 | 3) ;;'
assert_eq "control: reading status 1 as a completed run loses the tool's failure" \
  "rc=2 secrets: tool-output=jq:5" "$(stub_run 1 "{}" "$GAP")"
mutant added-list '"$GG_TMP/added/$n" 2>"$GG_TMP/added.err"' '"$GG_TMP/added/missing" 2>"$GG_TMP/added.err"'
assert_eq "an added-line list the lane cannot read refuses rather than dropping the finding" \
  "rc=2 secrets: added-read=notes/a file.txt:2" "$(run "$STAGED")"
mutant report-type 'if type != "array" then error("the report is not an array") else .[] end' '.[]'
assert_eq "control: without the type check an object report reads as clean" \
  "rc=0 secrets: summary=violations=0 files=1 scope=staged skipped=0" "$(stub_run 3 "{}" "$GAP")"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
