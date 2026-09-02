#!/usr/bin/env bash
# Regression tests for the one thing that authorizes a fix round: the round
# record dev-round-write stamps at delegation time. dev-artifact-check reads it
# for both the delegated item set and the protected additions the round may
# make, so anything that lets a check run WITHOUT that record, or lets a record
# reach the additions probe carrying a base_sha or an adds path the reader's
# own rules forbid, is a bypass of the whole gate rather than one weak
# assertion.
#
# Each case here pairs a control that must pass with a mutation of exactly one
# input that must refuse, so a refusal cannot be credited to the wrong arm.

set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
CHECK="$REPO_ROOT/skills/orch/scripts/dev-artifact-check"
ROUND_WRITE_BIN="$REPO_ROOT/skills/orch/scripts/dev-round-write"
ROUND_WRITE=round_write
RETURN_WRITE="$REPO_ROOT/skills/orch/scripts/dev-return-write"
STATE="$REPO_ROOT/skills/orch/scripts/workflow-state"
# shellcheck source=lib/growth-state.sh
source "$TEST_DIR/lib/growth-state.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

round_write() {
  growth_round_write "$STATE" "$ROUND_WRITE_BIN" "$@"
}

reason() {
  "$CHECK" "$@" 2>/dev/null | jq -r '.reason'
}

echo "=== dev round gate ==="

wt="$TMP_ROOT/wt"
mkdir -p "$wt"
git -C "$wt" init -q -b main
git -C "$wt" config user.email test@example.com
git -C "$wt" config user.name Test
git -C "$wt" config commit.gpgsign false
git -C "$wt" commit -q --allow-empty -m base
init_growth_state "$STATE" "$wt" issue-826 seed 1000000

# A round that added a protected file it was never authorized to add. Every
# case below asks whether some other spelling of the check lets it through.
"$ROUND_WRITE" --worktree "$wt" --issue issue-826 --round-id 1-1 --item 1 "fix finding" "tools/guard on a staged render" >/dev/null
mkdir -p "$wt/tools"
printf 'sneaky\n' > "$wt/tools/sneaky-check"
git -C "$wt" add tools/sneaky-check
git -C "$wt" commit -q -m sneaky
head_sha="$(git -C "$wt" rev-parse HEAD)"
"$RETURN_WRITE" --worktree "$wt" --kind fix --issue issue-826 --round-id 1-1 --branch b \
  --commit "$head_sha" --validate pass --item 1 Applied done >/dev/null

assert_eq "$(reason --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round)" \
  "unapproved_additions" "control: the bound check refuses the unlisted addition"

# --- omitting the flag is not a way past the gate ---------------------------
# Without --expect-items-from-round there is no delegated set and no authorized
# additions list, so validate_artifact would fall back to the weak
# non-empty-items rule and never run the additions probe at all.
set +e
flagless_out="$("$CHECK" --worktree "$wt" --issue issue-826 --round-id 1-1 2>/dev/null)"
flagless_rc=$?
set -e
assert_eq "$flagless_rc" "2" "a flagless fix receipt over an unlisted addition refuses with exit 2"
assert_eq "$([[ -z "$flagless_out" ]] && echo silent || jq -r '.ok' <<<"$flagless_out")" "silent" \
  "the flagless refusal reports no verdict at all, never ok=true"

# Implement and analysis rounds write no round record, so they stay flagless.
"$RETURN_WRITE" --worktree "$wt" --kind implement --issue issue-826 --round-id 2-2 --branch b \
  --commit "$head_sha" --validate pass >/dev/null
assert_eq "$(env ORCH_STATE_DIR="$wt/tmp" "$CHECK" --worktree "$wt" --issue issue-826 \
  --round-id 2-2 | jq -r '.reason')" "valid" \
  "a flagless implement receipt is unaffected by the fix-round requirement"
printf 'Recommend: re-scope.\n' > "$wt/analysis.md"
"$RETURN_WRITE" --worktree "$wt" --kind analysis --issue issue-826 --round-id 3-3 --branch b \
  --summary-file "$wt/analysis.md" --no-summary >/dev/null
assert_eq "$(reason --worktree "$wt" --issue issue-826 --round-id 3-3)" "valid" \
  "a flagless analysis receipt is unaffected by the fix-round requirement"

# --- the record's base_sha is a git revision, not a free string -------------
# It reaches `git diff` as an argument. A value git parses as an OPTION never
# reaches revision parsing: git exits 0 over an empty probe, the additions list
# comes back empty, and the gate reports valid over a round that added anything
# it liked. A `--` separator cannot stand in for the grammar: git does stop
# option parsing there, but everything after it is a pathspec, so the revision
# pair could not be passed at all.
record="$wt/tmp/dev-round-issue-826-1-1.json"
cp "$record" "$TMP_ROOT/record-honest.json"
for bad_base in "--output=$TMP_ROOT/sink" "HEAD" "0123456789abcdef0123456789abcdef0123456Z" ""; do
  jq --arg base "$bad_base" '.base_sha = $base' "$TMP_ROOT/record-honest.json" > "$TMP_ROOT/bad.json"
  cp "$TMP_ROOT/bad.json" "$record"
  set +e
  "$CHECK" --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round >/dev/null 2>&1
  bad_rc=$?
  set -e
  assert_eq "$bad_rc" "2" "a base_sha outside 40 hex ('$bad_base') refuses before the additions probe"
done
assert_eq "$([[ -e "$TMP_ROOT/sink" ]] && echo wrote || echo no)" "no" \
  "the refused base_sha never reached git as an option"
cp "$TMP_ROOT/record-honest.json" "$record"
assert_eq "$(reason --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round)" \
  "unapproved_additions" "restoring the honest base_sha restores the refusal"

# --- the grammar reaches every protected path this repository tracks --------
# A claim about THIS repository's tracked files, so it is measured rather than
# asserted in prose: every tracked path the additions classifier calls
# protected must be nameable in an Adds: line, or a fix round adding a sibling
# of it could never be authorized. Both halves are lifted out of the real
# scripts so the fixture cannot drift from them.
#
# The predicate is the SINGLE-PATH rule, not the whole-value grammar: the value
# grammar matches a multi-word list, so it would call 'crates/one file.rs'
# expressible when the writer records it as two paths.
#
# This is the one case in the suite that reads the ambient repository, so it
# needs a git checkout; from an export it fails rather than skipping, because a
# skipped sweep is the vacuous pass the classified-count control exists to stop.
classifier="$TMP_ROOT/is-protected-addition.sh"
awk '/^is_protected_addition\(\) \{$/,/^\}$/' "$CHECK" > "$classifier"
assert_eq "$([[ -s "$classifier" ]] && echo found || echo missing)" "found" \
  "control: the additions classifier was lifted from dev-artifact-check"
# shellcheck source=/dev/null
source "$classifier"
path_grammar="$(awk -F\' '/^ADDS_PATH_GRAMMAR=/ { print $2; exit }' "$ROUND_WRITE_BIN")"
assert_eq "$([[ -n "$path_grammar" ]] && echo found || echo missing)" "found" \
  "control: ADDS_PATH_GRAMMAR was lifted from dev-round-write"
assert_eq "$(git -C "$REPO_ROOT" rev-parse --is-inside-work-tree 2>/dev/null || echo no)" "true" \
  "precondition: the grammar sweep needs a git checkout at $REPO_ROOT"

# One sweep, run over any checkout, printing "<classified count>TAB<unnameable
# paths>". Taking a repository argument is what lets the planted-defect control
# below run the SAME code over a tree that carries the defect, instead of
# asserting the predicate is right and hoping.
sweep_unnameable() {
  local repo="$1" tracked count=0 unnameable=""
  while IFS= read -r tracked; do
    is_protected_addition "$tracked" || continue
    count=$((count + 1))
    [[ "$tracked" =~ ^${path_grammar}$ ]] && continue
    unnameable="${unnameable}[$tracked]"
  done < <(git -C "$repo" -c core.quotePath=false ls-files)
  printf '%s\t%s' "$count" "$unnameable"
}

sweep_result="$(sweep_unnameable "$REPO_ROOT")"
protected_seen="${sweep_result%%$'\t'*}"
assert_eq "${sweep_result#*$'\t'}" "" \
  "every tracked protected path can be named in an Adds: line"
assert_eq "$([[ "$protected_seen" -gt 100 ]] && echo many || echo "$protected_seen")" "many" \
  "control: the sweep actually classified protected paths"

# PLANTED DEFECT. A green sweep proves nothing unless it goes red on a tree
# that carries the class it exists to catch, and this class is invisible to the
# obvious predicate: the whole-VALUE grammar matches 'tools/one helper.sh' as a
# two-path list, so a sweep written against it stays green with the defect
# committed. The path is protected (root tools/), so only the predicate decides.
planted_repo="$TMP_ROOT/planted-sweep"
mkdir -p "$planted_repo/tools"
git -C "$planted_repo" init -q -b main
git -C "$planted_repo" config user.email test@example.com
git -C "$planted_repo" config user.name Test
git -C "$planted_repo" config commit.gpgsign false
printf 'helper\n' > "$planted_repo/tools/one helper.sh"
printf 'helper\n' > "$planted_repo/tools/plain-helper.sh"
git -C "$planted_repo" add -A
git -C "$planted_repo" commit -q -m planted
planted_result="$(sweep_unnameable "$planted_repo")"
assert_eq "${planted_result%%$'\t'*}" "2" \
  "control: the planted tree classified both paths as protected"
assert_eq "${planted_result#*$'\t'}" "[tools/one helper.sh]" \
  "control: the sweep names a planted space-carrying protected path"
# Default ls-files quoting would hand the sweep C-quoted spellings of the
# non-ASCII paths — `"...frapp\303\251-..."` — which carry no blank and no
# leading dash, so the grammar would admit a form the writer never sees and the
# miss would be silent. Measured over every tracked path, since the quoted ones
# here are not themselves protected.
quoted_paths=""
while IFS= read -r tracked_path; do
  case "$tracked_path" in
    '"'*) quoted_paths="$quoted_paths$tracked_path " ;;
  esac
done < <(git -C "$REPO_ROOT" -c core.quotePath=false ls-files)
assert_eq "$quoted_paths" "" \
  "control: the sweep reads path names unquoted"

# --- adds[] entries the reader's own rule forbids ---------------------------
# The reader accepts a recorded path only when it begins with something other
# than '-' and carries no ASCII whitespace, so the pair below moves only the
# adds entry across that line. The rule is stated in the reader's terms, not
# as an equality with the writer's: the writer additionally splits or refuses
# on whatever the running locale calls space, which is not a fixed set.
# U+00A0 is the case the regex form got wrong: the writer records it, while
# Oniguruma called it a space and the reader killed the round at exit 2 after
# the agent had done the work.
# `\xc2\xa0` rather than `\u00a0`: bash 3.2 does not read the second form,
# so the escape would survive as literal text and the case would assert
# nothing about a no-break space at all.
adds_nbsp="$(printf 'tools/a\xc2\xa0b')"
for adds_case in 'tools/a;b:writer-possible' 'crates/app/icons/128x128@2x.png:writer-possible' \
  "$adds_nbsp:writer-possible" \
  'tools/one path.sh:writer-impossible' '-c:writer-impossible'; do
  adds_value="${adds_case%:*}"
  adds_kind="${adds_case##*:}"
  jq --arg add "$adds_value" '.adds = [$add]' "$TMP_ROOT/record-honest.json" > "$TMP_ROOT/adds.json"
  cp "$TMP_ROOT/adds.json" "$record"
  set +e
  "$CHECK" --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round >/dev/null 2>&1
  adds_rc=$?
  set -e
  if [[ "$adds_kind" == "writer-impossible" ]]; then
    assert_eq "$adds_rc" "2" "a record carrying an adds path the writer refuses ('$adds_value') fails closed"
  else
    assert_eq "$([[ "$adds_rc" == "2" ]] && echo refused || echo read)" "read" \
      "control: a record carrying a writer-possible adds path ('$adds_value') is read"
  fi
done
cp "$TMP_ROOT/record-honest.json" "$record"

# A trailing newline is the other half of the same bug, in the opposite
# direction: Oniguruma's `$` matches before a string-final newline, so the
# unanchored form accepted a path the writer cannot produce. `$'...'` holds
# the newline that a command substitution would strip.
jq --arg add $'tools/a\n' '.adds = [$add]' "$TMP_ROOT/record-honest.json" > "$TMP_ROOT/adds.json"
cp "$TMP_ROOT/adds.json" "$record"
set +e
"$CHECK" --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "a record whose adds path ends in a newline fails closed"
set -e

# The same anchoring bug on base_sha: 40 hex plus a trailing newline.
jq --arg base $'0123456789abcdef0123456789abcdef01234567\n' '.base_sha = $base' \
  "$TMP_ROOT/record-honest.json" > "$TMP_ROOT/base.json"
cp "$TMP_ROOT/base.json" "$record"
set +e
"$CHECK" --worktree "$wt" --issue issue-826 --round-id 1-1 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "a base_sha of 40 hex plus a trailing newline fails closed"
set -e
cp "$TMP_ROOT/record-honest.json" "$record"

# --- an option-shaped branch path is named, not misdiagnosed ----------------
# The refused paths reach jq as data, not as arguments: -test-helper.sh is
# protected on the classifier's substring arm with no directory needed, and
# through an argument list it made jq exit on an unknown option, so the round
# came back classifier_failed with an empty files list — an environment failure
# the orchestrator would retry rather than an addition it should cut.
option_wt="$TMP_ROOT/option-wt"
mkdir -p "$option_wt"
git -C "$option_wt" init -q -b main
git -C "$option_wt" config user.email test@example.com
git -C "$option_wt" config user.name Test
git -C "$option_wt" config commit.gpgsign false
git -C "$option_wt" commit -q --allow-empty -m base
init_growth_state "$STATE" "$option_wt" issue-826 seed 1000000
for probe_case in '-test-helper.sh' 'x-test-helper.sh'; do
  probe_round="p${#probe_case}-${#probe_case}"
  "$ROUND_WRITE" --worktree "$option_wt" --issue issue-826 --round-id "$probe_round" \
    --item 1 "option-shaped addition" "tools/guard on a staged render" >/dev/null
  printf 'helper\n' > "$option_wt/$probe_case"
  git -C "$option_wt" add -- "$probe_case"
  git -C "$option_wt" commit -q -m "add $probe_case"
  probe_head="$(git -C "$option_wt" rev-parse HEAD)"
  "$RETURN_WRITE" --worktree "$option_wt" --kind fix --issue issue-826 --round-id "$probe_round" \
    --branch b --commit "$probe_head" --validate pass --item 1 Applied done >/dev/null
  probe_out="$("$CHECK" --worktree "$option_wt" --issue issue-826 --round-id "$probe_round" \
    --expect-items-from-round 2>/dev/null || true)"
  assert_eq "$(jq -r '.reason' <<<"$probe_out")" "unapproved_additions" \
    "an addition named '$probe_case' is refused as unauthorized, not as a classifier failure"
  assert_eq "$(jq -c '.files' <<<"$probe_out")" "$(jq -nc --arg f "$probe_case" '[$f]')" \
    "the refusal names '$probe_case'"
done

# --- the record must be a regular file at its own path ----------------------
# Only the symlink changes between the two halves: same bytes, same token, same
# schema. A refusal here can come from nothing but the symlink.
"$ROUND_WRITE" --worktree "$wt" --issue issue-826 --round-id 4-4 --item 1 "later round" "tools/guard on a staged render" >/dev/null
linked_record="$wt/tmp/dev-round-issue-826-4-4.json"
set +e
"$CHECK" --worktree "$wt" --issue issue-826 --round-id 4-4 --expect-items-from-round >/dev/null 2>&1
control_rc=$?
set -e
assert_eq "$([[ "$control_rc" == "2" ]] && echo refused || echo read)" "read" \
  "control: the same record as a regular file passes the record gates"
cp "$linked_record" "$TMP_ROOT/link-target.json"
rm -f "$linked_record"
ln -s "$TMP_ROOT/link-target.json" "$linked_record"
set +e
"$CHECK" --worktree "$wt" --issue issue-826 --round-id 4-4 --expect-items-from-round >/dev/null 2>&1
assert_eq "$?" "2" "a symlinked round record fails closed"
set -e

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
