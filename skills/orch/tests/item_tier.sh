#!/usr/bin/env bash
# Tests for item-tier, the gate that assigns an item's cycle.
#
# The script runs from a copy laid out as the installed packages are:
# orch/scripts beside harness-ci/scripts. Range and Location rows use
# harness-ci's shared path rules. The range rows use a real Git repository. The ceilings come from narrow-change.conf, so
# a boundary row follows the list rather than a second copy of its numbers.

set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ORCH_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "item-tier: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "item-tier: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "item-tier: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"

LAYOUT="$TMP_ROOT/layout"
mkdir -p "$LAYOUT/orch/scripts/lib" "$LAYOUT/orch/references" \
  "$LAYOUT/harness-ci/scripts/lib"
cp "$ORCH_DIR/../harness-ci/scripts/lib/change-class.sh" "$LAYOUT/harness-ci/scripts/lib/"
cp "$ORCH_DIR/scripts/item-tier" "$LAYOUT/orch/scripts/"
cp "$ORCH_DIR/scripts/lib/change-class.sh" "$ORCH_DIR/scripts/lib/branch-growth.sh" \
  "$LAYOUT/orch/scripts/lib/"
cp "$ORCH_DIR/references/narrow-change.conf" "$LAYOUT/orch/references/"
TIER="$LAYOUT/orch/scripts/item-tier"

# Two layouts whose ceiling list item-tier cannot use: one without the file,
# one without the small ceiling line.
for variant in no-conf no-small-ceiling; do
  cp -R "$LAYOUT" "$TMP_ROOT/$variant"
done
rm -- "${TMP_ROOT:?}/no-conf/orch/references/narrow-change.conf"
grep -v '^small_max_production=' "$ORCH_DIR/references/narrow-change.conf" \
  >"$TMP_ROOT/no-small-ceiling/orch/references/narrow-change.conf"

conf_value() { sed -n "s/^$1=//p" "$ORCH_DIR/references/narrow-change.conf"; }
MICRO_MAX="$(conf_value micro_max_production)"
SMALL_MAX="$(conf_value small_max_production)"
[[ "$MICRO_MAX" =~ ^[0-9]+$ && "$SMALL_MAX" =~ ^[0-9]+$ ]] || {
  echo "FAIL: the ceiling reader found no ceilings in narrow-change.conf" >&2
  exit 1
}

# The first stdout line's tier, brief, cause key and exit status.
run_tier() { # CLASS ARG...
  local out rc=0
  shift
  out="$(env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$PATH" TMPDIR="$TMP_ROOT" \
    "${TIER_BIN:-$TIER}" --repo "$TMP_ROOT" "$@" 2>/dev/null)" || rc=$?
  if [[ "${TIER_RAW:-false}" != true ]]; then
    out="$(sed -n '1s/^\(tier=[a-z]* brief=[a-z]* cause=[a-z-]*\( class=[a-z]*\)\{0,1\}\).*/\1/p' <<<"$out")"
  fi
  printf '%s' "${out:+$out }rc=$rc"
}

echo
echo "--- item-tier ---"

PR_MERGE=skills/github/scripts/commands/pr-merge.sh
# classifier|arguments|expected|row
ROWS=(
  "-|--production $MICRO_MAX|tier=micro brief=micro cause=estimate-within-micro rc=0|an estimate at the micro ceiling is micro"
  "-|--production $((MICRO_MAX + 1))|tier=small brief=small cause=estimate-within-small rc=0|an estimate one past the micro ceiling is small"
  "-|--production $SMALL_MAX|tier=small brief=small cause=estimate-within-small rc=0|an estimate at the small ceiling is small"
  "-|--production $((SMALL_MAX + 1))|tier=standard brief=start cause=estimate-past-small rc=0|an estimate one past the small ceiling is standard"
  "-|--production 1 --path kendex.settings.toml|tier=standard brief=start cause=configuration-source rc=0|a settings Location takes the classifier's class and cause"
  "-|--production 1 --path kendex.toml|tier=standard brief=start cause=configuration-source rc=0|a manifest Location takes the classifier's class and cause"
  "-|--production 1 --path kendex-local.toml|tier=standard brief=start cause=configuration-source rc=0|a catalog manifest Location takes the classifier's class and cause"
  "-|--production 1 --path .kendex/settings.toml|tier=standard brief=start cause=configuration-source rc=0|a local settings Location takes the classifier's class and cause"
  "-|--production 1 --path src/main.rs|tier=micro brief=micro cause=estimate-within-micro rc=0|a plain source Location keeps the estimate's class"
  "-|--production 1 --path .github/workflows/build.yml|tier=standard brief=start cause=excluded-path rc=0|a workflow Location is standard at any estimate"
  "-|--production 1 --path src/main.rs --path kendex.settings.toml|tier=standard brief=start cause=configuration-source rc=0|each Location is classified, not only the first"
  "-|--production 1 --path .pi/settings.json|tier=standard brief=start cause=configuration-source rc=0|a registry Location proves no render"
  "-|--production 1 --path CLAUDE.md|tier=standard brief=start cause=instruction-pointer rc=0|an instruction pointer Location proves no render"
  "-|--production 1 --path $PR_MERGE|tier=standard brief=start cause=excluded-path rc=0|a merge-gate Location is never micro whatever the estimate"
  "-|--production 1 --path skills/orch/scripts/lib/change-class.sh|tier=standard brief=start cause=excluded-path rc=0|the classifier reader item-tier sources is never micro"
  "-|--production 1 --path skills/orch/workflows/review-pr.md|tier=micro brief=micro cause=estimate-within-micro rc=0|a Location off the list leaves the estimate's class"
  "-|--production 1 --path hooks/block-bare-cd.sh|tier=standard brief=start cause=excluded-path rc=0|a hook body Location is never micro"
  "-|--production 1 --path hooks/tests/block-bare-cd.test.sh|tier=micro brief=micro cause=estimate-within-micro rc=0|a hook suite Location leaves the estimate's class"
  "-|--production 1 --path skills/x/SKILL.md|tier=small brief=small cause=instruction-file rc=0|a SKILL.md Location is never micro"
  "-|--production 1 --path AGENTS.md|tier=small brief=small cause=instruction-file rc=0|a root AGENTS.md Location is never micro"
  "-|--production $((SMALL_MAX + 1)) --path skills/x/SKILL.md|tier=standard brief=start cause=estimate-past-small rc=0|an instruction Location leaves a wider estimate alone"
  "-|--production $SMALL_MAX --floor small|tier=small brief=small cause=estimate-within-small rc=0|of two inputs naming one class the first names the cause"
  "-||rc=2|no input is a usage error"
  "-|--production 1x|rc=2|a malformed estimate is a usage error"
  "-|--floor tiny|rc=2|an unknown floor is a usage error"
  "-|--base b|rc=2|a base without a head is a usage error"
  "-|--production 1 --head h|rc=2|a head without a base is a usage error"
)
for row in "${ROWS[@]}"; do
  IFS='|' read -r class args want name <<<"$row"
  # shellcheck disable=SC2086
  assert_eq "$(run_tier "$class" $args)" "$want" "$name"
done

# The filer emits Location and Expected delta headers; launch passes the same
# body file. Every body but no-location-body names a one-subsystem Location.
LOCATION='**Location**: `src/main.rs`'
printf '%s\n**Expected delta**: %s lines, 1 test line\n' "$LOCATION" "$((SMALL_MAX + 1))" > "$TMP_ROOT/body"
printf '%s\nNo sizing headers\n' "$LOCATION" > "$TMP_ROOT/empty-body"
printf '%s\n**Expected delta**: junk\n' "$LOCATION" > "$TMP_ROOT/bad-body"
printf '%s\n**Expected delta**: 4 lines, 0 test lines\n' "$LOCATION" > "$TMP_ROOT/zero-test-body"
printf '%s\n**Expected delta**: 0 lines\n' "$LOCATION" > "$TMP_ROOT/zero-body"
printf '%s\n**Expected delta**: %s lines\n' "$LOCATION" "$((SMALL_MAX + 1))" > "$TMP_ROOT/bare-body"
printf '* %s\n**Expected delta**: 4 lines\n' "$LOCATION" > "$TMP_ROOT/bullet-location-body"
printf 'Every test suite\n' > "$TMP_ROOT/no-location-body"
while IFS='|' read -r args want raw; do
  assert_eq "$(TIER_RAW="${raw:-false}" run_tier - $args)" "$want" "body input: $args"
done <<ROWS
--production 1 --body $TMP_ROOT/body|tier=standard brief=start cause=estimate-past-small rc=0
--body $TMP_ROOT/body|tier=standard brief=start cause=estimate-past-small rc=0
--production $((SMALL_MAX + 2)) --body $TMP_ROOT/body|tier=standard brief=start cause=estimate-past-small production=$((SMALL_MAX + 2)) estimate=$((SMALL_MAX + 2)) delta=$((SMALL_MAX + 1)) paths=0 rc=0|true
--production 1 --body $TMP_ROOT/empty-body|tier=micro brief=micro cause=estimate-within-micro rc=0
--production 1 --body $TMP_ROOT/empty-body --path src/main.rs|tier=micro brief=micro cause=estimate-within-micro rc=0
--production 1 --body $TMP_ROOT/bad-body|tier=micro brief=micro cause=estimate-within-micro rc=0
--production 1 --body $TMP_ROOT/missing|rc=2
--body $TMP_ROOT/zero-test-body|tier=micro brief=micro cause=estimate-within-micro production=4 estimate=- delta=4 paths=0 rc=0|true
--body $TMP_ROOT/zero-body|tier=micro brief=micro cause=estimate-within-micro production=0 estimate=- delta=0 paths=0 rc=0|true
--body $TMP_ROOT/bare-body|tier=standard brief=start cause=estimate-past-small production=$((SMALL_MAX + 1)) estimate=- delta=$((SMALL_MAX + 1)) paths=0 rc=0|true
--body $TMP_ROOT/bullet-location-body --path src/main.rs|tier=micro brief=micro cause=estimate-within-micro rc=0
--body $TMP_ROOT/no-location-body|rc=1
--production 1 --body $TMP_ROOT/no-location-body|rc=1
ROWS

# A body naming no Location is refused with one stderr line, which the
# overseer's launch reads, and no tier on stdout.
assert_no_location_refused() {
  local out err rc=0
  out="$(env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$PATH" TMPDIR="$TMP_ROOT" "${TIER_BIN:-$TIER}" --repo "$TMP_ROOT" \
    --body "$TMP_ROOT/no-location-body" 2>"$TMP_ROOT/no-location-err")" || rc=$?
  err="$(cat -- "$TMP_ROOT/no-location-err")"
  assert_eq "rc=$rc stdout=[$out] stderr=[$err]" \
    "rc=1 stdout=[] stderr=[item-tier-error: cause=no-location route=per-subsystem-split]" \
    "a body with no Location is refused for a per-subsystem split"
}
assert_no_location_refused
# Must-fail control: a copy that keeps the Location read but never refuses
# answers as the script did before the refusal: standard on a guess.
cp -R "$LAYOUT" "$TMP_ROOT/no-location-refusal"
awk '/^  if ! grep -qE .*Location/ {hits++; print "  if false; then # " $0; next} {print} END {exit hits == 1 ? 0 : 3}' \
  "$TIER" > "$TMP_ROOT/no-location-refusal/orch/scripts/item-tier"
TIER_BIN="$TMP_ROOT/no-location-refusal/orch/scripts/item-tier"
assert_eq "$(run_tier - --body "$TMP_ROOT/no-location-body")" \
  "tier=standard brief=start cause=body-without-tier-inputs rc=0" "control: without the refusal a no-Location body launches standard"
if (PASS=0; FAIL=0; assert_no_location_refused >/dev/null; [[ "$FAIL" -eq 0 ]]); then
  fail "control no-location-refusal: the refusal assertion stays green"
else
  pass "control no-location-refusal: the refusal assertion turns red"
fi
unset TIER_BIN
TIER_RAW=true
assert_eq "$(run_tier - --production 1 --body "$TMP_ROOT/body" --path src/a --path src/b)" \
  "tier=standard brief=start cause=estimate-past-small production=$((SMALL_MAX + 1)) estimate=1 delta=$((SMALL_MAX + 1)) paths=2 rc=0" \
  "launch output retains the unfloored estimate, production delta and every path"
unset TIER_RAW

# A malformed or empty header warns once on stderr, naming the line, and the
# tier proceeds as with no delta. The wording past the line is not pinned.
printf '%s\n**Expected delta**: about 4 lines\n' "$LOCATION" > "$TMP_ROOT/about-body"
printf '%s\n**Expected delta**:\n' "$LOCATION" > "$TMP_ROOT/empty-delta-body"
warn_count() { # BODY
  env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" PATH="$PATH" TMPDIR="$TMP_ROOT" "${TIER_BIN:-$TIER}" --repo "$TMP_ROOT" \
    --production 1 --body "$1" 2>&1 >/dev/null | grep -c "^item-tier-warning: cause=invalid-delta line=\[$2\]" || true
}
assert_malformed_warns() {
  assert_eq "$(warn_count "$TMP_ROOT/about-body" 'about 4 lines')" "1" \
    "a malformed Expected delta warns once naming the line"
  assert_eq "$(warn_count "$TMP_ROOT/empty-delta-body" '')" "1" \
    "an empty Expected delta warns once"
  assert_eq "$(TIER_RAW=true run_tier - --production 1 --body "$TMP_ROOT/about-body")" \
    "tier=micro brief=micro cause=estimate-within-micro production=1 estimate=1 delta=- paths=0 rc=0" \
    "a malformed Expected delta proceeds with no delta"
}
assert_zero_reads() {
  assert_eq "$(TIER_RAW=true run_tier - --body "$TMP_ROOT/zero-test-body")" \
    "tier=micro brief=micro cause=estimate-within-micro production=4 estimate=- delta=4 paths=0 rc=0" \
    "a stated zero test count reads"
}
assert_malformed_warns
assert_zero_reads
# Must-fail controls: each assertion above turns red against a copy without
# its fix: the warning line dropped, the empty-header check dropped, and the
# grammar before a stated zero.
cp -R "$LAYOUT" "$TMP_ROOT/no-delta-warning"
awk '/item-tier-warning: cause=invalid-delta/ {hits++; print "    :"; getline; next} {print} END {exit hits == 1 ? 0 : 3}' \
  "$TIER" > "$TMP_ROOT/no-delta-warning/orch/scripts/item-tier"
cp -R "$LAYOUT" "$TMP_ROOT/no-empty-check"
awk '$0 ~ /grep -qE "\$header"/ {hits++; print "  [[ -n \"$(sed -n \"/$header/p\" <<<\"$1\" | sed \"s/$header[[:space:]]*//\")\" ]] || return 0"; next} {print} END {exit hits == 1 ? 0 : 3}' \
  "$ORCH_DIR/scripts/lib/branch-growth.sh" > "$TMP_ROOT/no-empty-check/orch/scripts/lib/branch-growth.sh"
cp -R "$LAYOUT" "$TMP_ROOT/no-zero"
sed -e 's/(0 lines|1 line|/(1 line|/' -e 's/(0 test lines|1 test line|/(1 test line|/' \
  "$ORCH_DIR/scripts/lib/branch-growth.sh" > "$TMP_ROOT/no-zero/orch/scripts/lib/branch-growth.sh"
for mutant in no-empty-check no-zero; do
  if cmp -s "$ORCH_DIR/scripts/lib/branch-growth.sh" "$TMP_ROOT/$mutant/orch/scripts/lib/branch-growth.sh"; then
    echo "FAIL: $mutant control changed nothing" >&2; exit 1
  fi
done
for control in no-delta-warning:assert_malformed_warns no-empty-check:assert_malformed_warns no-zero:assert_zero_reads; do
  TIER_BIN="$TMP_ROOT/${control%%:*}/orch/scripts/item-tier"
  if (PASS=0; FAIL=0; "${control#*:}" >/dev/null; [[ "$FAIL" -eq 0 ]]); then
    fail "control ${control%%:*}: ${control#*:} stays green"
  else
    pass "control ${control%%:*}: ${control#*:} turns red"
  fi
done
unset TIER_BIN

# The floor control retains the assignment but stops applying the header.
cp -R "$LAYOUT" "$TMP_ROOT/no-delta-floor"
awk '$0 == "    production=\"$delta\"" {hits++; print "    production=\"$production\""; next} {print} END {exit hits == 1 ? 0 : 3}' \
  "$TIER" > "$TMP_ROOT/no-delta-floor/orch/scripts/item-tier"
if cmp -s "$TIER" "$TMP_ROOT/no-delta-floor/orch/scripts/item-tier"; then
  echo 'FAIL: delta floor control changed nothing' >&2; exit 1
fi
TIER_BIN="$TMP_ROOT/no-delta-floor/orch/scripts/item-tier"
control_out="$(run_tier - --production 1 --body "$TMP_ROOT/body")"
if (PASS=0; FAIL=0; assert_eq "$control_out" "tier=standard brief=start cause=estimate-past-small rc=0" "delta floor" >/dev/null; [[ "$FAIL" -eq 0 ]]); then
  fail "delta floor regression accepts an unapplied delta"
else
  pass "delta floor regression turns red without the floor"
fi
unset TIER_BIN
# Must-fail control for the hook body row: the list's one-segment glob needs
# extglob, and a copy without it reads a hook body as off the list.
mkdir -p "$TMP_ROOT/no-extglob"
cp -R "$LAYOUT/." "$TMP_ROOT/no-extglob/"
sed '/^shopt -s extglob$/d' "$ORCH_DIR/scripts/item-tier" >"$TMP_ROOT/no-extglob/orch/scripts/item-tier"
assert_eq "$(grep -c '^shopt -s extglob$' "$ORCH_DIR/scripts/item-tier") $(grep -c '^shopt -s extglob$' "$TMP_ROOT/no-extglob/orch/scripts/item-tier" || true)" \
  "1 0" "the extglob control drops the one shopt"
TIER_BIN="$TMP_ROOT/no-extglob/orch/scripts/item-tier"
assert_eq "$(run_tier - --production 1 --path hooks/block-bare-cd.sh)" \
  "tier=micro brief=micro cause=estimate-within-micro rc=0" "an item-tier without extglob misses a hook body"
unset TIER_BIN

# Must-fail control for instruction rows: disable the class assigned by the
# shared rule. A SKILL.md Location then keeps the estimate's class.
mkdir -p "$TMP_ROOT/no-floor"
cp -R "$LAYOUT/." "$TMP_ROOT/no-floor/"
floor_line='      CHANGE_CLASS_PATH=small'
awk -v line="$floor_line" '
  $0 == line { hits++; print "      CHANGE_CLASS_PATH=\"\""; next }
  { print }
  END { exit hits == 1 ? 0 : 3 }
' "$LAYOUT/harness-ci/scripts/lib/change-class.sh" >"$TMP_ROOT/no-floor/harness-ci/scripts/lib/change-class.sh"
if cmp -s "$LAYOUT/harness-ci/scripts/lib/change-class.sh" "$TMP_ROOT/no-floor/harness-ci/scripts/lib/change-class.sh"; then
  echo "FAIL: the floor control did not change the library" >&2; exit 1
fi
TIER_BIN="$TMP_ROOT/no-floor/orch/scripts/item-tier"
assert_eq "$(run_tier - --production 1 --path skills/x/SKILL.md)" \
  "tier=micro brief=micro cause=estimate-within-micro rc=0" "an item-tier without the floor lets a SKILL.md Location run micro"
unset TIER_BIN

# Must-fail control for configuration Locations: retain the rule but disable
# its pre-render phase in a private library, restoring the old launch answer.
cp -R "$LAYOUT" "$TMP_ROOT/no-configuration"
configuration_line='  if [ "$2" = before-render ] || [ "$2" = launch ]; then'
awk -v line="$configuration_line" '
  $0 == line { hits++; print "  if false; then # " line; next }
  { print }
  END { exit hits == 1 ? 0 : 3 }
' "$LAYOUT/harness-ci/scripts/lib/change-class.sh" >"$TMP_ROOT/no-configuration/harness-ci/scripts/lib/change-class.sh"
if cmp -s "$LAYOUT/harness-ci/scripts/lib/change-class.sh" "$TMP_ROOT/no-configuration/harness-ci/scripts/lib/change-class.sh"; then
  echo "FAIL: the configuration control did not change the library" >&2; exit 1
fi
TIER_BIN="$TMP_ROOT/no-configuration/orch/scripts/item-tier"
control_out="$(run_tier - --production 1 --path kendex.settings.toml)"
assert_eq "$control_out" "tier=micro brief=micro cause=estimate-within-micro rc=0" \
  "the old launch behavior misses a settings Location"
# The regression assertion itself must reject that old answer.
if (PASS=0; FAIL=0; assert_eq "$control_out" \
  "tier=standard brief=start cause=configuration-source rc=0" "settings regression" >/dev/null; [[ "$FAIL" -eq 0 ]]); then
  fail "the settings regression accepts old behavior"
else
  pass "the settings regression turns red on old behavior"
fi
unset TIER_BIN

# A missing shared rule library refuses a narrow Location class.
cp -R "$LAYOUT" "$TMP_ROOT/no-path-rules"
rm -- "$TMP_ROOT/no-path-rules/harness-ci/scripts/lib/change-class.sh"
TIER_BIN="$TMP_ROOT/no-path-rules/orch/scripts/item-tier"
assert_eq "$(run_tier - --floor micro --path src/main.rs)" \
  "tier=standard brief=start cause=classifier-path-rules-unreadable rc=0" "missing path rules are not an unmatched Location"
unset TIER_BIN

# A ceiling list item-tier cannot use is standard, never a narrower class.
TIER_BIN="$TMP_ROOT/no-conf/orch/scripts/item-tier"
assert_eq "$(run_tier - --production 1)" \
  "tier=standard brief=start cause=narrow-change-unreadable rc=0" "no ceiling list is standard"
TIER_BIN="$TMP_ROOT/no-small-ceiling/orch/scripts/item-tier"
assert_eq "$(run_tier - --production 1)" \
  "tier=standard brief=start cause=narrow-change-ceilings-missing rc=0" "a missing ceiling is standard"
unset TIER_BIN

# A branch larger than the launch estimate keeps its tier. Path rules still apply.
RANGE="$TMP_ROOT/range"
mkdir -p "$RANGE"
git -C "$RANGE" init -q
git -C "$RANGE" config user.email test@example.com
git -C "$RANGE" config user.name test
git -C "$RANGE" config gc.auto 0
git -C "$RANGE" config maintenance.auto false
printf 'seed\n' >"$RANGE/seed"
git -C "$RANGE" add -A
git -C "$RANGE" commit -qm seed
BASE="$(git -C "$RANGE" rev-parse HEAD)"
mkdir -p "$RANGE/src"
awk 'BEGIN {for (i=0;i<1000;i++) print "pub fn source_" i "() {}"}' >"$RANGE/src/main.rs"
git -C "$RANGE" add -A
git -C "$RANGE" commit -qm source
assert_eq "$(run_tier - --production 1 --base "$BASE" --head HEAD --repo "$RANGE")" \
  "tier=micro brief=micro cause=estimate-within-micro rc=0" "branch growth does not replace the launch estimate"
assert_eq "$(run_tier - --floor small --base "$BASE" --head HEAD --repo "$RANGE")" \
  "tier=small brief=small cause=floor class=small rc=0" "branch growth does not replace the recorded tier"
printf '# Instructions\n' >"$RANGE/AGENTS.md"
git -C "$RANGE" add -A
git -C "$RANGE" commit -qm instructions
assert_eq "$(run_tier - --production 1 --base "$BASE" --head HEAD --repo "$RANGE")" \
  "tier=small brief=small cause=instruction-file rc=0" "a changed instruction file still selects small"
# A range whose only change is a skill's metadata.version line, in the
# source and its render, is an instruction-file edit like any other.
skill_version() { # VERSION
  local file
  for file in skills/x/SKILL.md .agents/skills/x/SKILL.md; do
    mkdir -p "$RANGE/${file%/*}"
    printf -- '---\nname: x\nmetadata:\n  version: "%s"\n---\n\n# X\n' "$1" >"$RANGE/$file"
  done
  git -C "$RANGE" add -A
  git -C "$RANGE" commit -qm "skill $1"
}
skill_version 1.0.0
SKILL_BASE="$(git -C "$RANGE" rev-parse HEAD)"
skill_version 1.0.1
assert_eq "$(run_tier - --production 1 --base "$SKILL_BASE" --head HEAD --repo "$RANGE")" \
  "tier=small brief=small cause=instruction-file rc=0" "a SKILL.md metadata.version line alone still selects small"
# The range-path control loses those files while retaining the Git read.
cp -R "$LAYOUT" "$TMP_ROOT/no-range-paths"
python3 - "$TMP_ROOT/no-range-paths/orch/scripts/item-tier" <<'EDIT'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
needle = '      change_class_path "$path" launch'
assert s.count(needle) == 2
before, after = s.rsplit(needle, 1)
p.write_text(before + '      CHANGE_CLASS_PATH=""' + after)
EDIT
TIER_BIN="$TMP_ROOT/no-range-paths/orch/scripts/item-tier"
assert_eq "$(run_tier - --production 1 --base "$BASE" --head HEAD --repo "$RANGE")" \
  "tier=micro brief=micro cause=estimate-within-micro rc=0" "control: losing range path rules misses the instruction file"
assert_eq "$(run_tier - --production 1 --base "$SKILL_BASE" --head HEAD --repo "$RANGE")" \
  "tier=micro brief=micro cause=estimate-within-micro rc=0" "control: losing range path rules misses the SKILL.md version line"
unset TIER_BIN

printf '\npass: %s fail: %s\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
