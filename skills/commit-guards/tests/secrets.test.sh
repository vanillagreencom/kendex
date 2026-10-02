#!/usr/bin/env bash
# Pins for scripts/secrets: a credential gitleaks' default rules match is
# refused at its path, line and rule id under every scope, and the value never
# reaches the output; under a diff scope only a finding on an added line
# counts; the repository cannot switch a finding off through gitleaks' own
# allowlists; a missing gitleaks is a gap notice that passes; a gitleaks run
# that fails, or a report the lane cannot read, is exit 2. Each row builds a
# fresh repository and pins the exit status with the first stable line.
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
OUT=""
run() { # REPO ARGS... — sets OUT to the whole output; prints rc and the first stable line
  local repo="$1" rc=0
  shift
  OUT="$(cd "$repo" && "$LANE" "$@" 2>&1)" || rc=$?
  printf 'rc=%s %s' "$rc" "$(printf '%s\n' "$OUT" | LC_ALL=C awk '/^secrets: [a-z-]+=/ && !seen { print; seen=1 }')"
}

env_run() { # REPO — run with the allowlisting configuration in the environment
  local rc=0
  OUT="$(cd "$1" && GITLEAKS_CONFIG_TOML="$(printf '%b' "$ALLOW_TOML")" "$LANE" 2>&1)" || rc=$?
  printf 'rc=%s %s' "$rc" "$(printf '%s\n' "$OUT" | LC_ALL=C awk '/^secrets: [a-z-]+=/ && !seen { print; seen=1 }')"
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
assert_eq "a staged credential is refused at its line under --staged, the default" \
  "rc=1 secrets: secret=notes/a file.txt:2:aws-access-token" "$(run "$R")"
assert_eq "the output never carries the value" "absent" \
  "$(case "$OUT" in *"$CRED"*) echo present ;; *) echo absent ;; esac)"
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

echo "=== a range judges the lines it adds ==="
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

echo "=== the tool: absent is a gap, a failed run or an unread report refuses ==="
NO_TOOL_PATH="$TMP/no-tool-bin"
mkdir -p "$NO_TOOL_PATH"
for cmd in bash git mktemp dirname rm tr head wc cp mkdir cut cat awk sort; do
  cmd_path="$(command -v "$cmd")" || { echo "harness: $cmd is not on PATH" >&2; exit 2; }
  ln -s -- "$cmd_path" "$NO_TOOL_PATH/$cmd"
done
gap_run() { # REPO ARGS... — run with no gitleaks reachable
  local repo="$1" rc=0
  shift
  OUT="$(cd "$repo" && PATH="$NO_TOOL_PATH" "$LANE" "$@" 2>&1)" || rc=$?
  printf 'rc=%s %s' "$rc" "$(printf '%s\n' "$OUT" | LC_ALL=C awk '/^secrets: [a-z-]+=/ && !seen { print; seen=1 }')"
}
repo gap
put cred.txt "aws = $CRED\n"
assert_eq "a selected file with no gitleaks installed passes at the gap notice" \
  "rc=0 secrets: gap=gitleaks-missing:1" "$(gap_run "$R")"
GAP="$R"
repo nothing
put seed.txt "seed\n"
commit
assert_eq "a scope selecting no file looks for no tool" \
  "rc=0 secrets: summary=violations=0 files=0 scope=staged skipped=0" "$(gap_run "$R")"
NOTHING="$R"

# A stand-in gitleaks: STUB_EXIT is its status, and STUB_REPORT, when set, the
# report it writes where --report-path points.
STUB_PATH="$TMP/stub-bin"
mkdir -p "$STUB_PATH"
cat >"$STUB_PATH/gitleaks" <<'EOF'
#!/usr/bin/env bash
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
  OUT="$(cd "$3" && PATH="$STUB_PATH:$PATH" STUB_EXIT="$1" STUB_REPORT="$2" "$LANE" 2>&1)" || rc=$?
  printf 'rc=%s %s' "$rc" "$(printf '%s\n' "$OUT" | LC_ALL=C awk '/^secrets: [a-z-]+=/ && !seen { print; seen=1 }')"
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
mutant added-filter 'if [ "$MODE" != all ]; then' 'if false; then'
assert_eq "control: without the added-line filter the committed credential fails the staged change" \
  "rc=1 secrets: secret=cred.txt:1:aws-access-token" "$(run "$OLD_CRED")"
mutant span '$1 >= s && $1 <= e' '$1 == s'
assert_eq "control: matching the first line alone misses the added key body" \
  "rc=0 secrets: summary=violations=0 files=1 scope=staged skipped=0" "$(run "$KEY_BODY")"
mutant range-lines 'gg_range_added_lines "$1" "$RANGE"' 'gg_staged_added_lines "$1"'
assert_eq "control: reading the index instead of the range finds no added line" \
  "rc=0 secrets: summary=violations=0 files=1 scope=against skipped=0" "$(run "$RANGE_ADD" --against HEAD~2)"
mutant config '--config "$GG_TMP/gitleaks.toml"' '--log-level warn'
assert_eq "control: without the config flag the environment's configuration allowlists the path" \
  "rc=0 secrets: summary=violations=0 files=1 scope=staged skipped=0" "$(env_run "$ENV_CONFIG")"
mutant inline '--ignore-gitleaks-allow' '--no-color'
assert_eq "control: without --ignore-gitleaks-allow the inline comment allows the line" \
  "rc=0 secrets: summary=violations=0 files=1 scope=staged skipped=0" "$(run "$INLINE")"
mutant gap-exit 'Install gitleaks 8.19 or newer' 'Install gitleaks 8.19 or newer"; exit 2; : "'
assert_eq "control: a gap that refuses stops the change" \
  "rc=2 secrets: gap=gitleaks-missing:1" "$(gap_run "$GAP")"
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
