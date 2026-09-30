#!/usr/bin/env bash
# lib/escapes.sh: the escape count behind oversee-report's Escapes line.
#
# Each case builds a checkout whose origin holds merges and reverts at chosen
# times, stubs the Linear CLI's bug list, and calls escapes_read at a fixed
# NOW. It asserts the per-week lines the renderer reads, or the return status
# and the cause an unread count names.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "oversee_report_escapes: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "oversee_report_escapes: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "oversee_report_escapes: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
# shellcheck source=lib/escapes-fixture.sh
source "$TEST_DIR/lib/escapes-fixture.sh"
# mutant_scripts and mutate_file, for the must-fail control.
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"
LIB="$TEST_DIR/../scripts/lib/escapes.sh"

at() { jq -rn --arg s "$1" '$s | fromdateiso8601'; }
# A Wednesday: the six weeks counted are the Mondays 2026-08-24 to 2026-09-28.
NOW="$(at 2026-09-30T12:00:00Z)"

# The Linear CLI: the count's one call answers $ESCAPES_BUGS; any other fails.
LINEAR="$TMP_ROOT/linear"
cat > "$LINEAR" <<'EOF'
#!/usr/bin/env bash
[[ "$*" == "cache issues list --all-projects --label bug --max --include-archived --format=safe" ]] \
  || { echo "linear stub: unexpected call: $*" >&2; exit 1; }
[[ -f "${ESCAPES_BUGS:-}" ]] || { echo "linear stub: no bug list" >&2; exit 1; }
cat -- "$ESCAPES_BUGS"
EOF
chmod +x "$LINEAR"

# count LIB ROOT [TRACKER] — escapes_read from LIB against ROOT at NOW:
# `rc=N` then ESCAPE_WEEKS' lines, or `rc=N unread=<cause>` where it names one.
count() {
  local scratch
  scratch="$(mktemp -d "$TMP_ROOT/scratch.XXXXXX")" || return 1
  (
    # shellcheck source=../scripts/lib/escapes.sh
    source "$1"
    rc=0
    escapes_read "$2" "${3:-$LINEAR}" "$NOW" "$scratch" || rc=$?
    printf 'rc=%s%s\n%s' "$rc" "${ESCAPE_UNREAD:+ unread=$ESCAPE_UNREAD}" "$ESCAPE_WEEKS"
  )
}

echo
echo "--- the count, one world ---"

# Merges and reverts on origin/main, oldest first, and the bug issues. Each
# comment names the rule the row holds and the week it lands in.
COMMITS=(
  # #9's first finding, this revert, falls before the window, so its later
  # bug issue does not count it inside the window.
  "2026-08-11T10:00:00Z|feat: merged before the window (#9)"
  "2026-08-12T10:00:00Z|feat: reverted 13 days later (#10)"
  "2026-08-15T10:00:00Z|Revert \"feat: merged before the window (#9)\" (#21)"
  # #12's revert comes 19 days after its merge: past the 14-day reach.
  "2026-08-20T10:00:00Z|feat: reverted too late (#12)"
  # Week of 08-24: the revert names #10 thirteen days after its merge.
  "2026-08-25T10:00:00Z|Revert \"feat: reverted 13 days later (#10)\" (#20)"
  # Week of 08-31: a bug issue names #11.
  "2026-08-31T10:00:00Z|fix: found by a bug issue (#11)"
  "2026-09-08T10:00:00Z|Revert \"feat: reverted too late (#12)\" (#22)"
  # Week of 09-14: #13's bug issue predates its merge, and this revert names
  # #99, never merged, beside its own merge #14, which names no escape.
  "2026-09-14T10:00:00Z|feat: named before its merge (#13)"
  "2026-09-15T10:00:00Z|Revert \"feat: never merged here (#99)\" (#14)"
  # Week of 09-21: a bug issue and a revert both name #15; one escape, in the
  # week of the earlier.
  "2026-09-21T10:00:00Z|feat: found twice (#15)"
  "2026-09-23T10:00:00Z|revert: back out #15 (#16)"
  # Week of 09-28: a bug names #18, and one names #170, which is not #17.
  "2026-09-28T09:00:00Z|feat: a number inside a longer one (#17)"
  "2026-09-28T10:00:00Z|Merge pull request #18 from owner/ken-18"
)
BUGS=(
  "KEN-B9|2026-08-24T09:00:00Z|after its revert, #9 breaks again"
  "KEN-B11|2026-09-02T10:00:00Z|#11 breaks the report"
  "KEN-B13|2026-09-10T10:00:00Z|#13 is wrong before it merges"
  "KEN-B15|2026-09-22T10:00:00Z|#15 breaks the watch"
  "KEN-B17|2026-09-29T10:00:00Z|#170 breaks the build"
  "KEN-B18|2026-09-29T11:00:00Z|breaks after #18"
)
WANT="rc=0
2026-08-24	1
2026-08-31	1
2026-09-07	0
2026-09-14	0
2026-09-21	1
2026-09-28	1"

WORLD="$TMP_ROOT/world"
escapes_checkout "$WORLD"
for row in "${COMMITS[@]}"; do
  escapes_commit "$WORLD" "$(at "${row%%|*}")" "${row#*|}"
done
escapes_publish "$WORLD"
bug_lines=""
for row in "${BUGS[@]}"; do
  IFS='|' read -r id when text <<<"$row"
  bug_lines+="$(escapes_bug "$id" "$(at "$when")" "$text")"$'\n'
done
export ESCAPES_BUGS="$TMP_ROOT/bugs.json"
jq -s . <<<"$bug_lines" > "$ESCAPES_BUGS"

assert_eq "$(count "$LIB" "$WORLD")" "$WANT" \
  "a revert or a bug naming a merged PR within 14 days counts once, in the week of its first finding; a late, early, self-named or unmerged one does not"

# The count fetches first: a revert another clone pushed after this checkout
# last fetched is counted. The world's copy takes the push, so the world
# itself stays as WANT reads it.
cp -R "$WORLD.origin" "$TMP_ROOT/stale.origin"
git clone -q "$TMP_ROOT/stale.origin" "$TMP_ROOT/stale"
git clone -q "$TMP_ROOT/stale.origin" "$TMP_ROOT/other"
escapes_commit "$TMP_ROOT/other" "$(at 2026-09-30T06:00:00Z)" "Revert \"feat: a number inside a longer one (#17)\" (#19)"
git -C "$TMP_ROOT/other" push -q origin main
assert_eq "$(count "$LIB" "$TMP_ROOT/stale" | tail -n 1)" "2026-09-28	2" "a revert on origin that this checkout has not fetched is counted"

echo
echo "--- an unread count ---"

NO_ORIGIN="$TMP_ROOT/no-origin"
git init -q "$NO_ORIGIN"
NOT_EXECUTABLE="$TMP_ROOT/linear-not-executable"
: > "$NOT_EXECUTABLE"
FAILING="$TMP_ROOT/linear-failing"
printf '#!/usr/bin/env bash\necho "cache corrupt" >&2\nexit 1\n' > "$FAILING"
chmod +x "$FAILING"
NOT_A_LIST="$TMP_ROOT/linear-object"
printf '#!/usr/bin/env bash\necho "{\\"issues\\": []}"\n' > "$NOT_A_LIST"
chmod +x "$NOT_A_LIST"
# root|tracker|the first line
UNREAD=(
  "$NO_ORIGIN|$LINEAR|rc=1 unread=git fetch origin main failed"
  "$WORLD|$NOT_EXECUTABLE|rc=1 unread=no Linear CLI"
  "$WORLD|$FAILING|rc=1 unread=Linear cache read failed"
  "$WORLD|$NOT_A_LIST|rc=1 unread=the git log or the bug list did not parse"
)
for row in "${UNREAD[@]}"; do
  IFS='|' read -r root tracker want <<<"$row"
  assert_eq "$(count "$LIB" "$root" "$tracker")" "$want" "${want#*unread=}: no count, never 0"
done

echo
echo "--- planted control ---"

# The 14-day reach dropped, in a copy of the lib: #12's late revert counts.
REACH_LIB="$(mutant_scripts no-reach lib/escapes.sh)/lib/escapes.sh" || exit 1
mutate_file "$REACH_LIB" 'reach "$ESCAPE_REACH"' 'reach 999999999'
got="$(count "$REACH_LIB" "$WORLD")"
[[ "$got" != "$WANT" ]] && pass "the world's assertion flags a count with no 14-day reach" \
  || fail "the world's assertion MISSED a count with no 14-day reach" "got=$got"

printf '\npass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
