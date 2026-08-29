#!/usr/bin/env bash
# Regression lint for KEN-768. The reviewer package told a re-review to scope
# the pass to the fix diff, and no delegation carried that diff. review.md
# resolved an absent Diff-range by diffing origin/<base>...HEAD, so every
# re-review round read the whole branch while believing itself scoped.
#
# KEN-768 orders two things, and this suite pins those two:
#
#   1. the re-review delegation carries Diff-range
#   2. a missing boundary does not silently become a full-branch read —
#      review.md § 1 matches what the sender actually renders and declares
#      the pass unscoped
#
# Check 2 renders the field line rather than looking for a word in it. A first
# cut of this fix put the sentinel in a placeholder INSIDE the value, leaving
# `...HEAD` outside it: the missing-boundary render was `unavailable...HEAD`,
# which review.md never matches, so it took the scoped route and ran
# `git diff unavailable...HEAD`. Every token the suite searched for was
# present. A token being present is not the path being reachable.
#
# What this pins are IDENTIFIERS and their relationships, never sentences:
# review-bots.md bans sentence-pinning lints on markdown, and an editorial
# rephrase must not fail a suite while the contract holds.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
REVIEW_PR_WF="$SKILL_DIR/workflows/review-pr.md"
REVIEW_WF="$SKILL_DIR/../reviewer/workflows/review.md"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

echo "=== re-review scope boundary lint (KEN-768) ==="

# HTML comment regions are stripped from EVERY line before any region gate, so
# a comment opened above a marker blanks the marker too: a commented-out
# instruction is not an instruction, wherever the comment starts.
strip_comments() {
  awk '
    {
      line = $0; out = ""
      while (length(line) > 0) {
        if (incomment) {
          p = index(line, "-->")
          if (p == 0) { line = ""; break }
          incomment = 0; line = substr(line, p + 3)
        } else {
          p = index(line, "<!--")
          if (p == 0) { out = out line; line = ""; break }
          out = out substr(line, 1, p - 1)
          incomment = 1; line = substr(line, p + 4)
        }
      }
      print out
    }
  ' "$1"
}

# $1 = file, $2 = ERE opening the region (line included), $3 = ERE closing it
# (line excluded). The prose region closes on any later heading of its level.
slice() {
  strip_comments "$1" | awk -v head="$2" -v tail="$3" '
    !on && $0 ~ head { on = 1 }
    on && printed && $0 ~ tail { on = 0 }
    !on { next }
    { print; printed = 1 }
  '
}

delegation_of() { slice "${1:-$REVIEW_PR_WF}" '^<delegation_format>$' '^</delegation_format>$'; }
launch_region() { slice "${1:-$REVIEW_PR_WF}" '^### 2[.]2 Launch And Delegate$' '^## '; }
diff_region()   { slice "${1:-$REVIEW_WF}" '^## 1[.] Diff$' '^## '; }
# The one line the wire hangs on, isolated from the block around it.
range_line()    { grep -E -e '^Diff-range:' <<<"$1" || true; }

# The literal both ends must spell for "no boundary".
ABSENT='unavailable'

# --- 1. the delegation carries the boundary ---------------------------------
sends_range() { [[ -n "$(range_line "$1")" ]]; }

if sends_range "$(delegation_of)"; then
  pass "the re-review delegation carries a Diff-range"
else
  fail "the re-review delegation carries no Diff-range"
fi

# --- 2. the missing-boundary render is what review.md matches ---------------
# Everything outside the field's bracketed instruction is emitted whatever the
# condition resolves to. The value is safe only when its first `[` closes on
# the last character: anything after that matching `]` rides on both branches,
# and the missing-boundary render stops being the bare sentinel.
value_wholly_conditional() {
  awk -v line="$1" '
    BEGIN {
      sub(/^Diff-range:[ \t]*/, "", line)
      if (substr(line, 1, 1) != "[") { exit 1 }
      depth = 0
      for (i = 1; i <= length(line); i++) {
        c = substr(line, i, 1)
        if (c == "[") depth++
        else if (c == "]") {
          depth--
          if (depth == 0) { exit (i == length(line)) ? 0 : 1 }
        }
      }
      exit 1
    }'
}

# What a reviewer is handed when the read returned no sha. Printed only when
# the value is wholly conditional and the instruction names the sentinel —
# otherwise there is no single rendered line to hand anyone.
render_missing() {
  local l="$1"
  value_wholly_conditional "$l" || return 1
  grep -qE -e "(^|[^[:alnum:]])$ABSENT([^[:alnum:]]|$)" <<<"$l" || return 1
  printf 'Diff-range: %s' "$ABSENT"
}

# The rendered line has to be the one review.md § 1 routes on. Matching a
# token the render never produces is the silent full-branch read returning.
unscoped_path_fires() {
  local deleg="$1" diff="$2" rendered
  rendered="$(render_missing "$(range_line "$deleg")")" || return 1
  grep -qF -e "$rendered" <<<"$diff"
}

if unscoped_path_fires "$(delegation_of)" "$(diff_region)"; then
  pass "the missing-boundary render is the line review.md § 1 routes on"
else
  fail "the missing-boundary render is not what review.md § 1 matches"
fi

# --- 3. the external lane takes the same boundary ---------------------------
# § 4 declares external review part of the scoped panel. It is a shell command,
# not a delegation, so the range reaches it as a flag or not at all — and its
# own default is the whole branch, so omitting the flag silently reads exactly
# the surface the scoped pass excludes.
#
# Rendered, not grepped. `--range` appearing somewhere proves nothing: spelled
# literally in the command it survives the empty branch as `--range ...HEAD`,
# which is the same placeholder-inside-a-value shape as the field line. So both
# branches are rendered and each is asserted to be a command that runs.
external_cmd()   { grep -F -e 'second-opinion review' <<<"$1" || true; }
range_binding()  { grep -oE '`\[[A-Z_]+\]` is `--range [^`]*`' <<<"$1" | head -1; }

external_range_resolves() {
  local region="$1" cmd bind tok val missing sha
  cmd="$(external_cmd "$region")"
  bind="$(range_binding "$region")"
  if [[ -z "$cmd" ]] || [[ -z "$bind" ]]; then return 1; fi
  tok="$(sed -E 's/^`(\[[A-Z_]+\])`.*/\1/' <<<"$bind")"
  val="$(sed -E 's/^.* is `(--range [^`]*)`.*/\1/' <<<"$bind")"

  # The flag lives wholly inside the token. Spelled in the command it cannot be
  # withdrawn, and the empty branch leaves it dangling over a broken value.
  if grep -qF -e '--range' <<<"$cmd"; then return 1; fi
  if ! grep -qF -e "$tok" <<<"$cmd"; then return 1; fi

  # Missing boundary: the token vanishes and takes the whole flag with it, so
  # the script falls back to its own documented default.
  missing="${cmd//"$tok"/}"
  if grep -qE -e '(--range|\.\.\.HEAD)' <<<"$missing"; then return 1; fi

  # Real boundary: a resolvable range actually reaches the command.
  sha="${cmd//"$tok"/$val}"
  sha="${sha//\[PRE_SHA\]/deadbee}"
  grep -qE -e '--range deadbee\.\.\.HEAD' <<<"$sha"
}

if external_range_resolves "$(launch_region)"; then
  pass "the external lane renders the panel's boundary, and no flag without one"
else
  fail "the external lane reads the whole branch inside a scoped panel"
fi

# --- planted controls: prove each check can fail ----------------------------
echo
echo "--- planted controls ---"

# $1 = file, $2 = ERE to replace, $3 = replacement, $4 = ERE narrowing it to
# matching lines. Write a literal bracket as a bracket expression — awk warns
# on a backslash escape in a dynamic regex and the warning reaches the output.
sub_lines() {
  awk -v from="$2" -v to="$3" -v only="${4:-}" '
    { if (only == "" || $0 ~ only) gsub(from, to); print }
  ' "$1"
}

# $1 = what the mutation removed, $2 = 1 when the mutation changed the file,
# $3 = 1 when the predicate HOLDS on the source, $4 = 1 when it holds on the
# control. The source is judged first: a check already red there would go green
# for the wrong reason — the mutation proves nothing about a predicate that was
# never satisfied — and the control would credit itself for a defect it cannot
# see.
verdict() {
  local what="$1" planted="$2" src_ok="$3" ctrl_ok="$4"
  if [[ "$src_ok" -ne 1 ]]; then
    fail "control for $what is vacuous — its predicate is already false on the source"
  elif [[ "$planted" -ne 1 ]]; then
    fail "control planted nothing for $what — the mutation matched no text"
  elif [[ "$ctrl_ok" -eq 1 ]]; then
    fail "lint MISSED $what"
  else
    pass "lint flags $what"
  fi
}

# Runs a predicate and prints 1 when it holds, 0 when it does not. The call
# sits inside `if`, where bash suspends errexit, so a predicate that correctly
# returns non-zero does not end the run before its verdict is read.
held() { if "$@"; then echo 1; else echo 0; fi; }

# The delegation with its Diff-range field renamed: the reviewer is handed a
# re-review block and no boundary in it.
C="$TMP_ROOT/no-field.md"
sub_lines "$REVIEW_PR_WF" '^Diff-range:' 'Range:' > "$C"
S=$(held sends_range "$(delegation_of "$REVIEW_PR_WF")")
K=$(held sends_range "$(delegation_of "$C")")
if cmp -s "$C" "$REVIEW_PR_WF"; then P=0; else P=1; fi
verdict "a re-review delegation carrying no Diff-range" "$P" "$S" "$K"

# The exact shape this fix corrected: the sentinel inside a placeholder with
# `...HEAD` left outside it. Every token stays present and the missing-boundary
# render becomes `unavailable...HEAD`, which review.md never matches.
C="$TMP_ROOT/leaky-value.md"
sub_lines "$REVIEW_PR_WF" '^Diff-range: [[]' 'Diff-range: [PRE_SHA]...HEAD [' '^Diff-range:' > "$C"
S=$(held unscoped_path_fires "$(delegation_of "$REVIEW_PR_WF")" "$(diff_region)")
K=$(held unscoped_path_fires "$(delegation_of "$C")" "$(diff_region)")
if cmp -s "$C" "$REVIEW_PR_WF"; then P=0; else P=1; fi
verdict "a value emitting text outside its condition" "$P" "$S" "$K"

# review.md matching a sentinel the sender never renders: the other half of the
# same wire, broken from the reader's end.
C="$TMP_ROOT/reader-drift.md"
sub_lines "$REVIEW_WF" "$ABSENT" 'unset' > "$C"
S=$(held unscoped_path_fires "$(delegation_of)" "$(diff_region "$REVIEW_WF")")
K=$(held unscoped_path_fires "$(delegation_of)" "$(diff_region "$C")")
if cmp -s "$C" "$REVIEW_WF"; then P=0; else P=1; fi
verdict "a reader matching a sentinel the sender never renders" "$P" "$S" "$K"

# The flag spelled literally in the command, which is what makes it
# unwithdrawable: the empty branch renders `--range ...HEAD`.
C="$TMP_ROOT/literal-range.md"
sub_lines "$REVIEW_PR_WF" '[[]RANGE_FLAG[]]' '--range [PRE_SHA]...HEAD' 'second-opinion review' > "$C"
S=$(held external_range_resolves "$(launch_region "$REVIEW_PR_WF")")
K=$(held external_range_resolves "$(launch_region "$C")")
if cmp -s "$C" "$REVIEW_PR_WF"; then P=0; else P=1; fi
verdict "an external range that cannot be withdrawn" "$P" "$S" "$K"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
