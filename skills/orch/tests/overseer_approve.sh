#!/usr/bin/env bash
# overseer-approve against a fake GitHub API: the approval call's shape, the
# exact-head refusal, the credential refusal, and that the token never shows.
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
  'api repos/o/r/pulls/42 --jq .head.sha') echo "$LIVE_HEAD" ;;
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

# label | token file | live head | post | rc | first stderr line | gh calls
while IFS='|' read -r label token_file live post want_rc want_key want_calls; do
  [[ -n "$label" ]] || continue
  token_file="${token_file//@/$TMP_ROOT/}"
  run_approve "$RUN" "$token_file" "$live" "$post" "${APPROVE[@]}"
  assert_eq "$RC|$STDERR_KEY|$NCALLS|$(cat "$OUT")" "$want_rc|$want_key|$want_calls|" "$label" "$ERR"
  assert_not_contains "$(cat "$OUT" "$ERR")" "$TOKEN" "$label prints no token"
  [[ "$want_rc" != 3 ]] || assert_eq "$(sed -n 2p "$ERR")" \
    "The fleet supplies this token file: $SUPPLIER. It must hold one non-empty line, the overseer app's installation token. Nothing was posted." \
    "$label names the supplier" "$ERR"
done <<EOF
head moved|@token|$MOVED|ok|4|overseer-approve: head-moved pr=42 given=$GIVEN live=$MOVED|1
token file unset||$GIVEN|ok|3|overseer-approve: credential setting=ORCH_OVERSEER_REVIEW_TOKEN_FILE file=|0
token file missing|@missing|$GIVEN|ok|3|overseer-approve: credential setting=ORCH_OVERSEER_REVIEW_TOKEN_FILE file=$TMP_ROOT/missing|0
token file empty|@token-empty|$GIVEN|ok|3|overseer-approve: credential setting=ORCH_OVERSEER_REVIEW_TOKEN_FILE file=$TMP_ROOT/token-empty|0
token file two lines|@token-two-lines|$GIVEN|ok|3|overseer-approve: credential setting=ORCH_OVERSEER_REVIEW_TOKEN_FILE file=$TMP_ROOT/token-two-lines|0
post refused|@token|$GIVEN|refused|1|overseer-approve: post-failed pr=42 repo=o/r commit=$GIVEN|2
answer unreadable|@token|$GIVEN|unreadable|1|overseer-approve: response-unread pr=42 repo=o/r commit=$GIVEN|2
EOF
run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" refused "${APPROVE[@]}"
assert_contains "$(cat "$ERR")" 'gh: Unprocessable Entity (HTTP 422)' 'a refused post prints GitHub'"'"'s message' "$ERR"

# label | args | first stderr line
while IFS='|' read -r label args want_key; do
  [[ -n "$label" ]] || continue
  read -r -a argv <<<"${args//@/$TMP_ROOT/}"
  run_approve "$RUN" "$TMP_ROOT/token" "$GIVEN" ok "${argv[@]}"
  assert_eq "$RC|$STDERR_KEY|$NCALLS" "2|$want_key|0" "$label" "$ERR"
done <<EOF
short head|42 0123456 --body-file @body --repo o/r|overseer-approve: usage reason=full-head-sha value=0123456
no body file|42 $GIVEN --repo o/r|overseer-approve: usage reason=missing-body-file value=
unreadable body file|42 $GIVEN --body-file @nobody --repo o/r|overseer-approve: body-file path=$TMP_ROOT/nobody
EOF

# Must-fail control: the approval sent without the live-head check posts on a
# moved head, which the head-moved row above refuses.
scripts="$(mutant_scripts mutant/orch overseer-approve)"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/mutant/github"
mutate_file "$scripts/overseer-approve" \
  '[[ "$live" == "$HEAD_SHA" ]] || refuse 4 head-moved' 'true || refuse 4 head-moved'
run_approve "$scripts/overseer-approve" "$TMP_ROOT/token" "$MOVED" ok "${APPROVE[@]}"
if [[ "$RC|$STDERR_KEY|$NCALLS" == "4|overseer-approve: head-moved pr=42 given=$GIVEN live=$MOVED|1" ]]; then
  fail 'head-check control did not turn the head-moved row red'
else
  pass 'head-check control turns the head-moved row red'
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
