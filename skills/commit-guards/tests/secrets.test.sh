#!/usr/bin/env bash
# Pins for scripts/secrets: a credential gitleaks' default rules match is
# refused at its path, line and rule id under every scope, and the value never
# reaches the output; under a diff scope only a finding on an added line
# counts, and a range judges each commit it holds against that commit's
# parents; the repository cannot switch a finding off through gitleaks' own
# allowlists, nor through its own exclusion list under --policy-root, which
# still refuses that list or its setting when malformed, and refuses a policy
# root it cannot enter or that is no git repository; a value option refuses
# an empty or missing value in either form before any scan; a
# missing or too-old gitleaks is a gap notice that passes, except under CI on
# a range or --all scan; a gitleaks run that fails, or a report the lane
# cannot read, is exit 2. Each row builds a fresh repository
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
# The same configuration as the environment word a run passes the lane.
ENV_TOML="GITLEAKS_CONFIG_TOML=$(printf '%b' "$ALLOW_TOML")" || exit 2

LANE="$SKILL_DIR/scripts/secrets"
# The one runner. The lane runs in a child of this shell with its output in a
# file, never inside $( ), so OUT, the whole output, and GOT, the exit status
# and the first stable line, are this shell's own for the row that reads them.
# CI and GITHUB_ACTIONS are blank unless a NAME=VALUE word sets one, so a run
# inside a CI job judges what a developer machine would.
OUT=""
GOT=""
lane() { # [NAME=VALUE...] REPO ARGS...
  local words=() rc=0
  while case "${1-}" in /*) false ;; *=*) true ;; *) false ;; esac; do
    words+=("$1")
    shift
  done
  (cd -- "$1" && shift && env CI= GITHUB_ACTIONS= ${words[@]+"${words[@]}"} "$LANE" "$@") >"$TMP/out" 2>&1 || rc=$?
  OUT="$(cat -- "$TMP/out")" || exit 2
  GOT="rc=$rc $(printf '%s\n' "$OUT" | LC_ALL=C awk '/^secrets: [a-z-]+=/ && !seen { print; seen=1 }')" || exit 2
}
row() { # LABEL EXPECT [NAME=VALUE...] REPO ARGS... — one row through lane
  local label="$1" expect="$2"
  shift 2
  lane "$@"
  assert_eq "$label" "$expect" "$GOT"
}
HAS=""
carries() { # TEXT — sets HAS to present or absent: whether OUT holds TEXT
  case "$OUT" in
    (*"$1"*) HAS=present ;;
    (*) HAS=absent ;;
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
row "a staged credential is refused at its line under --staged, the default" \
  "rc=1 secrets: secret=notes/a file.txt:2:aws-access-token" "$R"
carries "$CRED"
assert_eq "the output never carries the value" "absent" "$HAS"
STAGED="$R"
repo clean
put ok.txt "nothing to see\n"
row "a clean staged file is judged and passes" \
  "rc=0 secrets: summary=violations=0 files=1 scope=staged skipped=0" "$R"

echo "=== a diff scope counts a finding only on an added line ==="
repo old-cred
put cred.txt "aws = $CRED\n"
commit
put cred.txt "aws = $CRED\nmore\n"
row "a staged change beside a committed credential passes: the commit adds no credential" \
  "rc=0 secrets: summary=violations=0 files=1 scope=staged skipped=0" "$R"
row "control: --all judges every line, so the committed credential fails" \
  "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$R" --all
OLD_CRED="$R"
repo key-body
put key.pem "$PK_HEAD\n$PK_FOOT\n"
commit
put key.pem "$PK_HEAD\n$PK_BODY$PK_FOOT\n"
row "a finding spanning lines counts where an inner line is added" \
  "rc=1 secrets: secret=key.pem:1:private-key" "$R"
KEY_BODY="$R"
# Two staged files whose added lines differ: a.txt sorts first and adds line
# 1, b.txt adds a later line. Each finding is held to its own file's list.
repo two-old
put b.txt "aws = $CRED\n"
commit
put a.txt "new\n"
put b.txt "aws = $CRED\nmore\n"
row "a credential on a line another staged file adds, but its own file does not, passes" \
  "rc=0 secrets: summary=violations=0 files=2 scope=staged skipped=0" "$R"
TWO_OLD="$R"
repo two-new
put b.txt "x\n"
commit
put a.txt "new\n"
put b.txt "x\naws = $CRED\n"
row "a credential the second file adds, on a line the first file does not add, fails" \
  "rc=1 secrets: secret=b.txt:2:aws-access-token" "$R"
TWO_NEW="$R"

echo "=== a range judges each commit it holds against that commit's parents ==="
repo range
put base.txt "base\n"
commit
put cred.txt "x\naws = $CRED\n"
commit added
row "--against REF refuses a credential the range adds" \
  "rc=1 secrets: secret=cred.txt:2:aws-access-token" "$R" --against HEAD~1
row "--base REF refuses it too" \
  "rc=1 secrets: secret=cred.txt:2:aws-access-token" "$R" --base HEAD~1
RANGE_ADD="$R"
put cred.txt "x\naws = $CRED\ny\n"
commit later
row "a range that adds a line beside an older credential passes" \
  "rc=0 secrets: summary=violations=0 files=1 scope=against skipped=0" "$R" --against HEAD~1
repo removed
put base.txt "base\n"
commit
put cred.txt "aws = $CRED\n"
commit added
ADDED="$(git -C "$R" rev-parse HEAD)" || exit 2
git -C "$R" rm -q cred.txt
commit removed
row "a credential one commit adds and a later commit removes is refused under --against" \
  "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$R" --against HEAD~2
carries "in commit $ADDED;"
assert_eq "the refusal names the commit that added it" "present" "$HAS"
carries "rewrite the commit that added it (git rebase -i)"
assert_eq "and says to rewrite that commit, since a removal does not clear it" "present" "$HAS"
row "and under --base" \
  "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$R" --base HEAD~2
REMOVED="$R"
# side merges main, whose own commit added a credential and a whole key
# block: the merge carries main's lines, each of the key's lines over the
# same one parent, and adds none of its own. evil merges the same main and
# writes a credential into the merge itself.
repo merge
put base.txt "base\n"
commit
git -C "$R" checkout -q -b side
put s.txt "side\n"
commit side
git -C "$R" checkout -q main
put m.txt "m\naws = $CRED\n"
put key.pem "$PK_HEAD\n$PK_BODY$PK_FOOT\n"
commit main-cred
git -C "$R" checkout -q -b evil side
git -C "$R" checkout -q side
git -C "$R" merge -q --no-edit main
row "a merge passes the lines a parent already carried" \
  "rc=0 secrets: summary=violations=0 files=3 scope=against skipped=0" "$R" --against main
MERGE="$R"
git -C "$R" checkout -q evil
git -C "$R" merge -q --no-commit main >/dev/null 2>&1
put s.txt "side\naws = $CRED\n"
commit evil-merge
row "a line a merge adds over both parents is refused" \
  "rc=1 secrets: secret=s.txt:2:aws-access-token" "$R" --against main
# Two branches from one base each add half of a private key block to one
# file, the header and body on one side and the footer on the other: neither
# side's commit holds a whole key, and the merge adds the footer over the
# first parent and the header and body over the second.
repo split-key
put key.txt "a\nb\nc\nd\n"
commit
git -C "$R" checkout -q -b foot
put key.txt "a\nb\nc\n$PK_FOOT\nd\n"
commit foot
git -C "$R" checkout -q -b head-half main
put key.txt "a\n$PK_HEAD\n${PK_BODY}b\nc\nd\n"
commit head-half
git -C "$R" checkout -q foot
git -C "$R" merge -q --no-edit head-half >/dev/null
row "a key block a merge completes from two parents' halves is refused" \
  "rc=1 secrets: secret=key.txt:2:private-key" "$R" --against main
carries "MIIEowIBAAKC"
assert_eq "the refusal never carries the key" "absent" "$HAS"
SPLIT_KEY="$R"
R="$MERGE"
git -C "$R" checkout -q --orphan orphan
git -C "$R" rm -rqf .
put o.txt "aws = $CRED\n"
commit orphan
row "a commit with no parent adds every line it holds" \
  "rc=1 secrets: secret=o.txt:1:aws-access-token" "$R" --against main
SHALLOW="$TMP/shallow"
git clone -q --depth 2 --branch evil "file://$MERGE" "$SHALLOW"
MAIN_TIP="$(git -C "$MERGE" rev-parse main)"
row "a shallow boundary inside the range refuses: its parents were never fetched" \
  "rc=2 secrets: range-shallow=$MAIN_TIP" "$SHALLOW" --against HEAD^1

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
row "a .gitleaks.toml allowlisting the path is not read" \
  "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$R"
repo ignore
put .gitleaksignore "cred.txt:aws-access-token:1\nr/0/cred.txt:aws-access-token:1\nr/1/cred.txt:aws-access-token:1\n"
put cred.txt "aws = $CRED\n"
row "a .gitleaksignore naming the fingerprint is not read" \
  "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$R"
repo env-config
put cred.txt "aws = $CRED\n"
row "a GITLEAKS_CONFIG_TOML in the environment is outranked" \
  "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$ENV_TOML" "$R"
ENV_CONFIG="$R"
repo inline
put cred.txt "aws = $CRED # gitleaks:allow\n"
row "an inline gitleaks:allow comment is not honoured" \
  "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$R"
INLINE="$R"
repo excluded
put tools/secrets-excludes "fixtures/*\tfake credentials the suite asserts against\n"
put fixtures/cred.txt "aws = $CRED\n"
row "a reasoned row in the excludes list passes the path" \
  "rc=0 secrets: summary=violations=0 files=1 scope=staged skipped=0" "$R"

echo "=== --policy-root reads the exclusion policy from that repository, never the judged one ==="
# CI passes the default branch's checkout, so a pull request that adds a
# match-everything row, to the default list or to a list its own setting
# names, is still judged by the default branch's rows.
repo trusted-policy
put tools/secrets-excludes "fixtures/*\tfake credentials the suite asserts against\n"
POLICY="$R"
while IFS='|' read -r name setting file; do
  repo "$name"
  [ -z "$setting" ] || put .kendex/settings.toml "[env]\nCOMMIT_GUARDS_SECRETS_EXCLUDES = \"$file\"\n"
  put "$file" "*\tthe pull request excludes every path\n"
  put fixtures/cred.txt "aws = $CRED\n"
  put cred.txt "aws = $CRED\n"
  row "$name: under --policy-root the judged repository's row is not read" \
    "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$R" --policy-root "$POLICY"
  carries fixtures/cred.txt
  assert_eq "$name: the policy root's own row still excludes its path" "absent" "$HAS"
  row "$name: the --policy-root= form reads the policy root's list too" \
    "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$R" "--policy-root=$POLICY"
  row "$name: without it the repository's own row governs, as at commit time" \
    "rc=0 secrets: summary=violations=0 files=0 scope=staged skipped=0" "$R"
done <<'ROWS'
own-list||tools/secrets-excludes
own-setting|yes|tools/pr-excludes
ROWS
row "a policy root that cannot be entered refuses" \
  "rc=2 secrets: policy-root=$TMP/no-checkout" "$R" --policy-root "$TMP/no-checkout"
NOT_REPO="$TMP/not-a-repo"
mkdir -p "$NOT_REPO"
row "a policy root outside any git repository refuses" \
  "rc=2 secrets: policy-root=$NOT_REPO" "$R" --policy-root "$NOT_REPO"

echo "=== --policy-root still refuses a malformed setting or list in the judged repository ==="
# Once merged the judged repository's list is the policy root's, so a
# malformed one would fail every later scan, the repairing pull request's too.
while IFS='|' read -r name setting list expect; do
  repo "$name"
  [ -z "$setting" ] || put .kendex/settings.toml "[env]\nCOMMIT_GUARDS_SECRETS_EXCLUDES = \"$setting\"\n"
  [ -z "$list" ] || put tools/secrets-excludes "$list"
  put ok.txt "nothing to see\n"
  row "$name" "$expect" "$R" --policy-root "$POLICY"
done <<'ROWS'
a well-formed judged list is validated and the scan runs||docs/*\tgenerated prose\n|rc=0 secrets: summary=violations=0 files=2 scope=staged skipped=0
a judged setting the lane cannot use refuses|/abs/excludes||rc=2 secrets: path-absolute=excludes:/abs/excludes
a judged row without a reason refuses||docs/*\n|rc=2 secrets: exclusion-reason=tools/secrets-excludes:1
ROWS

echo "=== a value option refuses an empty or missing value in either form, before any scan ==="
# The repository's own list excludes every path, so a lane that read an
# empty --policy-root or --excludes as not given would pass the credential.
repo empty-values
put tools/secrets-excludes "*\tthe repository excludes every path\n"
put tools/narrow-excludes "fixtures/*\tfake credentials the suite asserts against\n"
put cred.txt "aws = $CRED\n"
EMPTY_VALUES="$R"
while IFS='|' read -r option form; do
  case "$form" in
    equals) args=("$option=") ;;
    separate) args=("$option" "") ;;
    absent) args=("$option") ;;
  esac
  row "$option in the $form form refuses" "rc=2 secrets: argument-missing=$option" "$R" "${args[@]}"
done <<'ROWS'
--policy-root|equals
--policy-root|separate
--policy-root|absent
--excludes|equals
--excludes|separate
--excludes|absent
--base|equals
--base|separate
--base|absent
--against|equals
--against|separate
--against|absent
ROWS
row "a non-empty --excludes= reads the list it names" \
  "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$R" --excludes=tools/narrow-excludes

echo "=== the tool: missing or too old is a gap outside CI and on --staged, a refusal on a CI range or --all ==="
NO_TOOL_PATH="$TMP/no-tool-bin"
mkdir -p "$NO_TOOL_PATH"
for cmd in bash env git mktemp dirname rm tr head wc cp mv mkdir cut cat awk sort grep; do
  cmd_path="$(command -v "$cmd")" || { echo "harness: $cmd is not on PATH" >&2; exit 2; }
  ln -s -- "$cmd_path" "$NO_TOOL_PATH/$cmd"
done
NO_TOOL="PATH=$NO_TOOL_PATH"
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
OLD="PATH=$OLD_PATH:$PATH"
repo gap
put cred.txt "aws = $CRED\n"
row "a selected file with no gitleaks installed passes at the gap notice" \
  "rc=0 secrets: gap=gitleaks-missing:1" "$NO_TOOL" "$R"
carries '.agents/skills/commit-guards/scripts/install-gitleaks DIR'
assert_eq "the gap names the shipped installer" "present" "$HAS"
GAP="$R"
repo gap-all
put cred.txt "aws = $CRED\n"
commit
row "outside CI an --all scan with no gitleaks passes at the gap notice too" \
  "rc=0 secrets: gap=gitleaks-missing:1" "$NO_TOOL" "$R" --all
row "under CI an --all scan with no gitleaks refuses" \
  "rc=2 secrets: tool-missing=gitleaks" CI=true "$NO_TOOL" "$R" --all
carries '.agents/skills/commit-guards/scripts/install-gitleaks DIR'
assert_eq "the CI refusal names the shipped installer" "present" "$HAS"
row "GITHUB_ACTIONS alone marks CI as well" \
  "rc=2 secrets: tool-missing=gitleaks" GITHUB_ACTIONS=true "$NO_TOOL" "$R" --all
row "under CI a range scan with no gitleaks refuses" \
  "rc=2 secrets: tool-missing=gitleaks" CI=true "$NO_TOOL" "$RANGE_ADD" --against HEAD~2
row "under CI the commit scope keeps the gap" \
  "rc=0 secrets: gap=gitleaks-missing:1" CI=true "$NO_TOOL" "$STAGED"
GAP_ALL="$R"
row "a gitleaks older than 8.19 passes at the gap notice" \
  "rc=0 secrets: gap=gitleaks-unusable:1" "$OLD" "$R" --all
row "under CI it refuses" \
  "rc=2 secrets: tool-unusable=gitleaks" CI=true "$OLD" "$R" --all
repo nothing
put seed.txt "seed\n"
commit
row "a scope selecting no file looks for no tool" \
  "rc=0 secrets: summary=violations=0 files=0 scope=staged skipped=0" "$NO_TOOL" "$R"
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
STUB="PATH=$STUB_PATH:$PATH"
row "gitleaks' own failure status refuses rather than reading as a leak" \
  "rc=2 secrets: tool-failed=gitleaks:1" "$STUB" STUB_EXIT=1 "STUB_REPORT=" "$GAP"
row "a report that is not an array refuses" \
  "rc=2 secrets: tool-output=jq:5" "$STUB" STUB_EXIT=3 "STUB_REPORT={}" "$GAP"

echo "=== must-fail controls: a copy of the lane with one rule removed ==="
# Each control copies the scripts and changes one line of the lane, asserting
# the line matched once and the file changed, then reruns the row that rule
# decides.
gg_mutant LANE secrets '.agents/skills/commit-guards/scripts/install-gitleaks DIR' 'installer DIR'
lane "$NO_TOOL" "$GAP"
carries '.agents/skills/commit-guards/scripts/install-gitleaks DIR'
assert_eq "control: a gap without the installer fails the path row" "absent" "$HAS"
gg_mutant LANE secrets 'gg_message secret "${PATHS[$n]}:$start:$rule"' 'gg_message secret "${PATHS[$n]}:$start:$rule:$(cat -- "$GG_TMP/tree/r/$n/${PATHS[$n]}")"'
lane "$STAGED"
carries "$CRED"
assert_eq "control: a lane that prints the matched line carries the value" "present" "$HAS"
gg_mutant LANE secrets 'if [ -n "$LINES" ]; then' 'if false; then'
row "control: without the added-line filter the committed credential fails the staged change" \
  "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$OLD_CRED"
gg_mutant LANE secrets '$2 >= s && $2 <= e' '$2 == s'
row "control: matching the first line alone misses the added key body" \
  "rc=0 secrets: summary=violations=0 files=1 scope=staged skipped=0" "$KEY_BODY"
gg_mutant LANE secrets '"$GG_TMP/added/$n" 2>"$GG_TMP/added.err"' '"$GG_TMP/added/0" 2>"$GG_TMP/added.err"'
row "control: holding every finding to the first file's lines fails the old credential" \
  "rc=1 secrets: secret=b.txt:1:aws-access-token" "$TWO_OLD"
row "control: and misses the second file's new credential" \
  "rc=0 secrets: summary=violations=0 files=2 scope=staged skipped=0" "$TWO_NEW"
gg_mutant LANE secrets 'side_rows "$1" "$k" "$p..$COMMIT"' 'side_rows "$1" "$k"'
row "control: reading the index instead of the commit finds no added line" \
  "rc=0 secrets: summary=violations=0 files=2 scope=against skipped=0" "$RANGE_ADD" --against HEAD~2
gg_mutant LANE secrets 'git rev-list --reverse --parents --right-only "$range"' 'printf "%s %s\n" "$(git rev-parse HEAD)" "$(git rev-parse "$REF")"'
row "control: judging the net diff of the range passes the removed credential" \
  "rc=0 secrets: summary=violations=0 files=0 scope=against skipped=0" "$REMOVED" --against HEAD~2
gg_mutant LANE secrets 'ORIGINS+=("${COMMIT:+ in commit $COMMIT}")' 'ORIGINS+=("")'
lane "$REMOVED" --against HEAD~2
carries "in commit $ADDED;"
assert_eq "control: a lane that drops the commit from the refusal names no commit" "absent" "$HAS"
gg_mutant LANE secrets 'SIDE_COUNT="${#parent_list[@]}"' 'SIDE_COUNT=1'
git -C "$MERGE" checkout -q side
row "control: a merge judged as one side fails the lines main carried" \
  "rc=1 secrets: secret=key.pem:1:private-key" "$MERGE" --against main
gg_mutant LANE secrets 'print side "\t" $1' 'print side "-" NR "\t" $1'
row "control: counting each added line as its own side fails the key one parent carried whole" \
  "rc=1 secrets: secret=key.pem:1:private-key" "$MERGE" --against main
gg_mutant LANE secrets '$2 >= s && $2 <= e && !($1 in hit) { hit[$1]; held++ } END { exit held < sides }' '$2 >= s && $2 <= e && ++count[$2] == sides { found = 1 } END { exit !found }'
row "control: counting only a line every parent adds passes the key the merge completes" \
  "rc=0 secrets: summary=violations=0 files=3 scope=against skipped=0" "$SPLIT_KEY" --against main
gg_mutant LANE secrets '--parents --right-only' '--parents --no-merges --right-only'
git -C "$MERGE" checkout -q evil
row "control: skipping merges passes the merge's own credential" \
  "rc=0 secrets: summary=violations=0 files=1 scope=against skipped=0" "$MERGE" --against main
gg_mutant LANE secrets '1) PARENTS="$empty" ;;' '1) continue ;;'
git -C "$MERGE" checkout -q orphan
row "control: skipping a parentless commit passes its credential" \
  "rc=0 secrets: summary=violations=0 files=0 scope=against skipped=0" "$MERGE" --against main
git -C "$MERGE" checkout -q evil
gg_mutant LANE secrets 'grep -Fxq -- "$COMMIT" "$shallow"' 'grep -Fxq -- "$COMMIT" /dev/null'
row "control: a shallow boundary read as a root commit judges every line it holds" \
  "rc=1 secrets: secret=key.pem:1:private-key" "$SHALLOW" --against HEAD^1
# One row per rule of the --policy-root block, its subject and policy root
# named as fixtures under $TMP. The remedy naming the policy root is prose.
while IFS='^' read -r label from to subject root expect; do
  gg_mutant LANE secrets "$from" "$to"
  row "control: $label" "$expect" "$TMP/$subject" --policy-root "$TMP/$root"
done <<'ROWS'
a lane that stays in the judged repository reads its own row^cd -- "$POLICY_ROOT" 2>"$GG_TMP/policy-root.err"^true^own-setting^trusted-policy^rc=0 secrets: summary=violations=0 files=0 scope=staged skipped=0
a lane that ignores an unenterable policy root reads the judged repository's own row^|| gg_fail_cause policy-root "$POLICY_ROOT" "$GG_TMP/policy-root.err" "cannot enter the policy root"^|| true^own-setting^no-checkout^rc=0 secrets: summary=violations=0 files=0 scope=staged skipped=0
without the repository check a non-git policy root fails under the wrong key^git rev-parse --show-toplevel >/dev/null 2>"$GG_TMP/policy-root.err"^true^own-setting^not-a-repo^rc=2 secrets: repository-root=1
a lane that loads no list from the policy root fails the path its row excludes^gg_load_excludes "$EXCLUDES_FILE"^true^excluded^trusted-policy^rc=1 secrets: secret=fixtures/cred.txt:1:aws-access-token
a lane that never returns to the judged repository scans the policy root and passes^cd -- "$START_DIR" || gg_fail repository-cd^true || gg_fail repository-cd^own-setting^trusted-policy^rc=0 secrets: summary=violations=0 files=1 scope=staged skipped=0
a lane that skips the judged setting passes its absolute path^JUDGED_EXCLUDES="$(gg_resolve_path "$EXCLUDES_OPT" COMMIT_GUARDS_SECRETS_EXCLUDES "tools/secrets-excludes" excludes)"^JUDGED_EXCLUDES=tools/secrets-excludes^a judged setting the lane cannot use refuses^trusted-policy^rc=0 secrets: summary=violations=0 files=2 scope=staged skipped=0
a lane that skips the judged list passes its malformed row^gg_load_excludes "$JUDGED_EXCLUDES"^true^a judged row without a reason refuses^trusted-policy^rc=0 secrets: summary=violations=0 files=2 scope=staged skipped=0
ROWS
gg_mutant LANE secrets '[ $# -ge 2 ] && [ -n "$2" ] || gg_fail argument-missing' '[ $# -ge 2 ] || gg_fail argument-missing'
row "control: a lane that takes an empty --policy-root= scans under the judged repository's own list" \
  "rc=0 secrets: summary=violations=0 files=0 scope=staged skipped=0" "$EMPTY_VALUES" --policy-root=
row "control: and takes an empty separate --policy-root the same way" \
  "rc=0 secrets: summary=violations=0 files=0 scope=staged skipped=0" "$EMPTY_VALUES" --policy-root ""
gg_mutant LANE secrets '[ $# -ge 2 ] && [ -n "$2" ] || gg_fail argument-missing' '[ -n "$2" ] || gg_fail argument-missing'
row "control: without the count check a trailing option fails on the unset value, not as a refusal" \
  "rc=1 " "$EMPTY_VALUES" --policy-root
gg_mutant LANE secrets '--config "$GG_TMP/gitleaks.toml"' '--log-level warn'
row "control: without the config flag the environment's configuration allowlists the path" \
  "rc=0 secrets: summary=violations=0 files=1 scope=staged skipped=0" "$ENV_TOML" "$ENV_CONFIG"
gg_mutant LANE secrets '--ignore-gitleaks-allow' '--no-color'
row "control: without --ignore-gitleaks-allow the inline comment allows the line" \
  "rc=0 secrets: summary=violations=0 files=1 scope=staged skipped=0" "$INLINE"
gg_mutant LANE secrets '{ [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; }' 'false'
row "control: a lane blind to CI passes an --all scan with no gitleaks" \
  "rc=0 secrets: gap=gitleaks-missing:1" CI=true "$NO_TOOL" "$GAP_ALL" --all
gg_mutant LANE secrets '{ [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; }' 'true'
row "control: a lane that refuses outside CI stops the change" \
  "rc=2 secrets: tool-missing=gitleaks" "$NO_TOOL" "$GAP_ALL" --all
gg_mutant LANE secrets '{ [ -n "${CI:-}" ] || [ -n "${GITHUB_ACTIONS:-}" ]; }' '[ -n "${CI:-}" ]'
row "control: a lane reading CI alone misses GITHUB_ACTIONS" \
  "rc=0 secrets: gap=gitleaks-missing:1" GITHUB_ACTIONS=true "$NO_TOOL" "$GAP_ALL" --all
gg_mutant LANE secrets '    CI_REFUSES=0' '    CI_REFUSES=1'
row "control: a commit scope that refuses under CI stops the commit" \
  "rc=2 secrets: tool-missing=gitleaks" CI=true "$NO_TOOL" "$STAGED"
gg_mutant LANE secrets 'elif ! gitleaks dir --help >/dev/null 2>&1; then' 'elif false; then'
row "control: without the probe a gitleaks older than 8.19 fails the run" \
  "rc=2 secrets: tool-failed=gitleaks:1" "$OLD" "$GAP_ALL" --all
gg_mutant LANE secrets 'if [ "${#PATHS[@]}" -eq 0 ]; then' 'if false; then'
row "control: without the empty-scope exit the lane looks for the tool" \
  "rc=0 secrets: gap=gitleaks-missing:0" "$NO_TOOL" "$NOTHING"
gg_mutant LANE secrets '  0 | 3) ;;' '  0 | 1 | 3) ;;'
row "control: reading status 1 as a completed run loses the tool's failure" \
  "rc=2 secrets: tool-output=jq:5" "$STUB" STUB_EXIT=1 "STUB_REPORT={}" "$GAP"
gg_mutant LANE secrets '"$GG_TMP/added/$n" 2>"$GG_TMP/added.err"' '"$GG_TMP/added/missing" 2>"$GG_TMP/added.err"'
row "an added-line list the lane cannot read refuses rather than dropping the finding" \
  "rc=2 secrets: added-read=notes/a file.txt:2" "$STAGED"
gg_mutant LANE secrets 'if type != "array" then error("the report is not an array") else .[] end' '.[]'
row "control: without the type check an object report reads as clean" \
  "rc=0 secrets: summary=violations=0 files=1 scope=staged skipped=0" "$STUB" STUB_EXIT=3 "STUB_REPORT={}" "$GAP"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
