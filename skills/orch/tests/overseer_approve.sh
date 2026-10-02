#!/usr/bin/env bash
# overseer-approve against a fake GitHub API: the approval call's shape, the
# head-prefix refusal, the credential refusal, and that the token never shows.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$TEST_DIR/../../.." && pwd -P)"
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'overseer_approve: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "overseer_approve: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'overseer_approve: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

TOKEN=ghs_fixtureOverseerReviewToken
GIVEN=0123456789abcdef0123456789abcdef01234567
MOVED=fedcba9876543210fedcba9876543210fedcba98
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/home" "$TMP_ROOT/cwd"
printf '%s\n' "$TOKEN" > "$TMP_ROOT/token"
: > "$TMP_ROOT/token-empty"
printf '%s\nsecond\n' "$TOKEN" > "$TMP_ROOT/token-two-lines"
printf 'Each decline holds.\n"Quoted" line\n' > "$TMP_ROOT/body"
CALLS="$TMP_ROOT/calls"
INPUT="$TMP_ROOT/input"
OUT="$TMP_ROOT/out"
ERR="$TMP_ROOT/err"

# One `<GH_TOKEN>|<argv>` line per call; the POST's stdin is kept whole.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s|%s\n' "${GH_TOKEN:-}" "$*" >> "$CALLS"
case "$*" in
  'api repos/o/r/pulls/42 --jq .head.sha')
    if [[ $LIVE_HEAD == fail ]]; then echo 'gh: Not Found (HTTP 404)' >&2; exit 1; fi
    echo "$LIVE_HEAD"
    ;;
  'api --method POST repos/o/r/pulls/42/reviews --input -')
    cat > "$INPUT"
    case "$POST" in
      ok) printf '{"state":"APPROVED","user":{"login":"vanillagreen-overseer[bot]"},"commit_id":"%s"}\n' "$LIVE_HEAD" ;;
      unreadable) echo '{}' ;;
      refused)
        echo '{"message":"Unprocessable Entity"}'
        echo 'gh: Unprocessable Entity (HTTP 422)' >&2
        exit 1
        ;;
    esac
    ;;
  *) printf 'gh: unexpected argv=%s\n' "$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/gh"

run_approve() { # SCRIPT TOKEN_FILE LIVE_HEAD POST ARGS...
  local script="$1" token_file="$2" live="$3" post="$4" setting=()
  shift 4
  [[ -z "$token_file" ]] || setting=("ORCH_OVERSEER_REVIEW_TOKEN_FILE=$token_file")
  : > "$CALLS"
  rm -f -- "$INPUT"
  RC=0
  (cd -- "$TMP_ROOT/cwd" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT/home" \
    ${setting[@]+"${setting[@]}"} \
    CALLS="$CALLS" INPUT="$INPUT" LIVE_HEAD="$live" POST="$post" \
    bash "$script" "$@" > "$OUT" 2> "$ERR") || RC=$?
  STDERR_KEY="$(sed -n 1p "$ERR")"
  NCALLS="$(wc -l < "$CALLS" | tr -d ' ')"
}

RUN="$REPO_ROOT/skills/orch/scripts/overseer-approve"
SUPPLIER="the control VM for a hosted overseer, the fleet worker on the owner's machine for a local one"
APPROVE=(42 "$GIVEN" --body-file "$TMP_ROOT/body" --repo o/r)

run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}"
assert_eq "$RC|$(cat "$OUT")" "0|APPROVED vanillagreen-overseer[bot] 0123456" \
  'approval prints state, login and short commit' "$ERR"
assert_eq "$(cat "$CALLS")" "$TOKEN|api repos/o/r/pulls/42 --jq .head.sha
$TOKEN|api --method POST repos/o/r/pulls/42/reviews --input -" \
  'live head read then one POST to the reviews path, both with the file token' "$ERR"
assert_eq "$(jq -c . "$INPUT")" \
  "$(jq -cn --arg sha "$GIVEN" '{commit_id: $sha, event: "APPROVE", body: "Each decline holds.\n\"Quoted\" line\n"}')" \
  'the review binds the given commit, APPROVE and the body text' "$ERR"
assert_not_contains "$(cat "$OUT" "$ERR")" "$TOKEN" 'approval prints no token'

# pr-watch prints the head as 8 characters; the review binds the full live one.
run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" ok 42 "${GIVEN:0:8}" --body-file "$TMP_ROOT/body" --repo o/r
assert_eq "$RC|$NCALLS|$(cat "$OUT")" "0|2|APPROVED vanillagreen-overseer[bot] 0123456" \
  'an 8-character head approves' "$ERR"
assert_eq "$(jq -r .commit_id "$INPUT")" "$GIVEN" 'a prefix head posts the full live commit' "$ERR"

# label | token file | live head | post | head | rc | first stderr line | gh calls
while IFS='|' read -r label token_file live post head want_rc want_key want_calls; do
  [[ -n "$label" ]] || continue
  token_file="${token_file//@/$TMP_ROOT/}"
  run_approve "$RUN" "$token_file" "$live" "$post" 42 "$head" --body-file "$TMP_ROOT/body" --repo o/r
  assert_eq "$RC|$STDERR_KEY|$NCALLS|$(cat "$OUT")" "$want_rc|$want_key|$want_calls|" "$label" "$ERR"
  assert_not_contains "$(cat "$OUT" "$ERR")" "$TOKEN" "$label prints no token"
  [[ "$want_rc" != 3 ]] || assert_eq "$(sed -n 2p "$ERR")" \
    "The fleet supplies this token file: $SUPPLIER. It must hold one non-empty line, the overseer app's installation token. Nothing was posted." \
    "$label names the supplier" "$ERR"
done <<EOF
head moved|@token|$MOVED|ok|$GIVEN|4|overseer-approve: head-moved pr=42 given=$GIVEN live=$MOVED|1
prefix head moved|@token|$MOVED|ok|${GIVEN:0:8}|4|overseer-approve: head-moved pr=42 given=${GIVEN:0:8} live=$MOVED|1
head read failed|@token|fail|ok|$GIVEN|1|overseer-approve: head-read-failed pr=42 repo=o/r|1
live head not a sha|@token|${GIVEN}0|ok|$GIVEN|1|overseer-approve: head-read-failed pr=42 repo=o/r|1
token file unset||$GIVEN|ok|$GIVEN|3|overseer-approve: credential setting=ORCH_OVERSEER_REVIEW_TOKEN_FILE file=|0
token file missing|@missing|$GIVEN|ok|$GIVEN|3|overseer-approve: credential setting=ORCH_OVERSEER_REVIEW_TOKEN_FILE file=$TMP_ROOT/missing|0
token file empty|@token-empty|$GIVEN|ok|$GIVEN|3|overseer-approve: credential setting=ORCH_OVERSEER_REVIEW_TOKEN_FILE file=$TMP_ROOT/token-empty|0
token file two lines|@token-two-lines|$GIVEN|ok|$GIVEN|3|overseer-approve: credential setting=ORCH_OVERSEER_REVIEW_TOKEN_FILE file=$TMP_ROOT/token-two-lines|0
post refused|@token|$GIVEN|refused|$GIVEN|1|overseer-approve: post-failed pr=42 repo=o/r commit=$GIVEN|2
answer unreadable|@token|$GIVEN|unreadable|$GIVEN|1|overseer-approve: response-unread pr=42 repo=o/r commit=$GIVEN|2
EOF
run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" refused "${APPROVE[@]}"
assert_contains "$(cat "$ERR")" 'gh: Unprocessable Entity (HTTP 422)' 'a refused post prints GitHub'"'"'s message' "$ERR"
run_approve "$RUN" "$TMP_ROOT/token" fail ok "${APPROVE[@]}"
assert_contains "$(cat "$ERR")" 'gh: Not Found (HTTP 404)' 'a failed head read prints gh'"'"'s words' "$ERR"

# label | args | rc | first stderr line
while IFS='|' read -r label args want_rc want_key; do
  [[ -n "$label" ]] || continue
  read -r -a argv <<<"${args//@/$TMP_ROOT/}"
  run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" ok "${argv[@]}"
  assert_eq "$RC|$STDERR_KEY|$NCALLS" "$want_rc|$want_key|0" "$label" "$ERR"
done <<EOF
hash pr number|#42 $GIVEN --body-file @body --repo o/r|2|overseer-approve: usage reason=pr-number value=#42
zero pr number|0 $GIVEN --body-file @body --repo o/r|2|overseer-approve: usage reason=pr-number value=0
six-character head|42 012345 --body-file @body --repo o/r|2|overseer-approve: usage reason=head-sha value=012345
41-character head|42 ${GIVEN}0 --body-file @body --repo o/r|2|overseer-approve: usage reason=head-sha value=${GIVEN}0
upper-case head|42 0123456789ABCDEF --body-file @body --repo o/r|2|overseer-approve: usage reason=head-sha value=0123456789ABCDEF
no body file|42 $GIVEN --repo o/r|2|overseer-approve: usage reason=missing-body-file value=
unreadable body file|42 $GIVEN --body-file @nobody --repo o/r|2|overseer-approve: body-file path=$TMP_ROOT/nobody
repo not owner/repo|42 $GIVEN --body-file @body --repo not-a-repo|1|overseer-approve: repo-shape repo=not-a-repo
EOF

# The settings loader's own words follow the keyed line, never precede it.
printf '[env]\nX = 1\n' > "$TMP_ROOT/cwd/kendex.settings.toml"
run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" ok "${APPROVE[@]}"
rm -- "${TMP_ROOT:?}/cwd/kendex.settings.toml"
assert_eq "$RC|$STDERR_KEY|$NCALLS" "1|overseer-approve: settings-load root=$TMP_ROOT/cwd|0" \
  'a malformed settings file refuses settings-load first' "$ERR"
assert_contains "$(sed -n '3,$p' "$ERR")" 'kendex-env: ' 'the loader'"'"'s words follow settings-load' "$ERR"

# Must-fail controls, each asserting what its mutant does, so a mutant that
# cannot start turns the suite red. Without the live-head check the moved
# head is approved; without the live-head shape check a junk head that
# starts with the given one passes the prefix check and is posted.
scripts="$(mutant_scripts mutant/orch overseer-approve)"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/mutant/github"
mutate_file "$scripts/overseer-approve" \
  '[[ "$live" == "$HEAD_SHA"* ]] || refuse 4 head-moved' 'true || refuse 4 head-moved'
run_approve "$scripts/overseer-approve" "$TMP_ROOT/token" "$MOVED" ok "${APPROVE[@]}"
assert_eq "$RC|$NCALLS|$(cat "$OUT")" "0|2|APPROVED vanillagreen-overseer[bot] fedcba9" \
  'head-check control approves the moved head' "$ERR"

scripts="$(mutant_scripts mutant/orch overseer-approve)"
mutate_file "$scripts/overseer-approve" '|| ! "$live" =~ ^[0-9a-f]{40}$ ]]' ']]'
run_approve "$scripts/overseer-approve" "$TMP_ROOT/token" "${GIVEN}0" ok "${APPROVE[@]}"
assert_eq "$RC|$NCALLS|$(jq -r .commit_id "$INPUT")" "0|2|${GIVEN}0" \
  'head-shape control posts the junk head' "$ERR"

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
