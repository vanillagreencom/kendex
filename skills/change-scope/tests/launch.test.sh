#!/usr/bin/env bash
# The launch arm: the class a work item launches at, from its estimate, its
# body's Expected delta, the classes it already holds, its Location paths and
# its range. Each row runs the arm from a planted install layout; each control
# runs a copy with one rule's line changed and must turn its row red.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

SANDBOX="$(cd -- "$SANDBOX" && pwd -P)"
LAYOUT="$(plant_layout "$SANDBOX/layout")"
ARM="$LAYOUT/change-scope/scripts/change-scope"
CONF="$CHANGE_SCOPE_PACKAGE/references/narrow-change.conf"
WORK="$(new_repo work)"

conf_value() { sed -n "s/^$1=//p" "$CONF"; }
MICRO_MAX="$(conf_value micro_max_production)"
SMALL_MAX="$(conf_value small_max_production)"
[[ "$MICRO_MAX" =~ ^[0-9]+$ && "$SMALL_MAX" =~ ^[0-9]+$ ]] || {
  echo "FAIL: the ceiling reader found no ceilings in narrow-change.conf" >&2
  exit 1
}

# The class stdout names, the cause key and the exit status; with ARM_RAW set,
# the whole class line instead of the key.
run_arm() { # ARG...
  local out rc=0 line
  out="$(env -i GIT_CEILING_DIRECTORIES="${CEILING:-$SANDBOX}" PATH="$PATH" HOME="$SANDBOX" \
    TMPDIR="$SANDBOX" "${ARM_BIN:-$ARM}" launch --repo "$WORK" "$@" 2>"$SANDBOX/arm.err")" || rc=$?
  line="$(sed -n 's/^class: //p' "$SANDBOX/arm.err")"
  if [ "${ARM_RAW:-false}" != true ]; then
    line="$(sed -n 's/^class=[a-z]* measured=[a-z]* delta=[^ ]* \(cause=[a-z-]*\( class=[a-z]*\)\{0,1\}\).*/\1/p' <<<"$line")"
    out="${out#change_class=}"
  fi
  printf '%s' "${out:+$out }${line:+$line }rc=$rc"
}

# A control's verdict: ASSERTION run against the copy must fail.
control() { # NAME ASSERTION...
  local name="$1"
  shift
  if (PASS=0; FAIL=0; "$@" >/dev/null 2>&1; [ "$FAIL" -eq 0 ]); then
    assert_eq "control $name turns its row red" red green
  else
    assert_eq "control $name turns its row red" red red
  fi
}

PR_MERGE=skills/github/scripts/commands/pr-merge.sh
rows=0
while IFS='|' read -r args want name; do
  rows=$((rows + 1))
  # shellcheck disable=SC2086
  assert_eq "$name" "$want" "$(run_arm $args)"
done <<ROWS
--production $MICRO_MAX|micro cause=estimate-within-micro rc=0|an estimate at the micro ceiling is micro
--production $((MICRO_MAX + 1))|small cause=estimate-within-small rc=0|an estimate one past the micro ceiling is small
--production $SMALL_MAX|small cause=estimate-within-small rc=0|an estimate at the small ceiling is small
--production $((SMALL_MAX + 1))|standard cause=estimate-past-small rc=0|an estimate one past the small ceiling is standard
--production 1 --path kendex.settings.toml|standard cause=configuration-source rc=0|a settings Location is a configuration source
--production 1 --path kendex.toml|standard cause=configuration-source rc=0|a manifest Location is a configuration source
--production 1 --path kendex-local.toml|standard cause=configuration-source rc=0|a catalog manifest Location is a configuration source
--production 1 --path .kendex/settings.toml|standard cause=configuration-source rc=0|a local settings Location is a configuration source
--production 1 --path src/main.rs|micro cause=estimate-within-micro rc=0|a plain source Location keeps the estimate's class
--production 1 --path .github/workflows/build.yml|standard cause=excluded-path rc=0|a workflow Location is standard at any estimate
--production 1 --path src/main.rs --path kendex.settings.toml|standard cause=configuration-source rc=0|each Location is classified, not only the first
--production 1 --path .pi/settings.json|standard cause=configuration-source rc=0|a registry Location proves no render
--production 1 --path CLAUDE.md|standard cause=instruction-pointer rc=0|an instruction pointer Location proves no render
--production 1 --path $PR_MERGE|standard cause=excluded-path rc=0|a merge-gate Location is never micro whatever the estimate
--production 1 --path skills/orch/runtime/src/ops/tier.rs|standard cause=excluded-path rc=0|the cycle's decider is never micro
--production 1 --path skills/orch/workflows/review-pr.md|micro cause=estimate-within-micro rc=0|a Location off the list leaves the estimate's class
--production 1 --path hooks/block-bare-cd.sh|standard cause=excluded-path rc=0|a hook body Location is never micro
--production 1 --path hooks/tests/block-bare-cd.test.sh|micro cause=estimate-within-micro rc=0|a hook suite Location leaves the estimate's class
--production 1 --path skills/x/SKILL.md|small cause=instruction-file rc=0|a SKILL.md Location is never micro
--production 1 --path AGENTS.md|small cause=instruction-file rc=0|a root AGENTS.md Location is never micro
--production $((SMALL_MAX + 1)) --path skills/x/SKILL.md|standard cause=estimate-past-small rc=0|an instruction Location leaves a wider estimate alone
--production $SMALL_MAX --floor small|small cause=estimate-within-small rc=0|of two inputs naming one class the first names the cause
--production 1 --floor small|small cause=floor class=small rc=0|a small floor raises a micro estimate
--production 1 --floor standard|standard cause=floor class=standard rc=0|a standard floor raises a micro estimate
--floor micro --floor small|small cause=floor class=small rc=0|of two floors the wider decides
--floor standard --floor small|standard cause=floor class=standard rc=0|a wider first floor keeps its cause
--path src/main.rs|rc=2|paths alone are no input
|rc=2|no input is a wiring error
--production 1x|rc=2|a malformed estimate is a wiring error
--floor tiny|rc=2|an unknown floor is a wiring error
--floor trivial|rc=2|a floor below micro is a wiring error
--base b|rc=2|a base without a head is a wiring error
--production 1 --head h|rc=2|a head without a base is a wiring error
--production 1 --body $SANDBOX/missing|rc=2|an unreadable body is a wiring error
ROWS
require_rows launch "$rows"

# The refused floor is named, which the tier's reader of an escape reads.
assert_eq "an invalid floor names the floor it refused" \
  "wiring-error: cause=invalid-floor floor=render" \
  "$(env -i PATH="$PATH" HOME="$SANDBOX" "$ARM" launch --floor small --floor render 2>&1 >/dev/null | sed -n '1p')"
assert_floor_refused() { assert_eq "a floor below micro is refused" "rc=2" "$(run_arm --floor trivial)"; }
ARM_BIN="$(mutant floor-unchecked change-scope '    change_scope_floor "$floor" ||' '    true ||')" \
  control floor-unchecked assert_floor_refused

# The repository's own standard paths come from the main checkout's
# settings, the local file over the root one; an unreadable one is standard.
assert_standard_setting() { # [REPO] [location|range]
  local setting globs want root ceiling repo="${1:-$WORK}" input="${2:-location}" args
  args=(--path src/main.rs)
  [ "$input" != range ] || args=(--base "$BASE" --head HEAD)
  while IFS='|' read -r setting globs want; do
    [ -z "${SETTING_ONLY:-}" ] || [ "$SETTING_ONLY" = "$setting" ] || continue
    root="$repo"
    ceiling="$SANDBOX"
    if [ "$setting" = resolver-failed ]; then
      [ "$input" != range ] || continue
      root="$SANDBOX/nonrepo"
      mkdir -p "$root"
    fi
    rm -rf -- "$root/kendex.settings.toml" "$root/.kendex"
    [ "$setting" = unset ] ||
      printf '[env]\nHARNESS_CI_STANDARD_PATHS = "%s"\n' "$globs" >"$root/kendex.settings.toml"
    case "$setting" in
      root-malformed) printf '[env]\nHARNESS_CI_STANDARD_PATHS = src/*.rs\n' >"$root/kendex.settings.toml" ;;
      local-empty)
        mkdir -p "$root/.kendex"
        printf '[env]\nHARNESS_CI_STANDARD_PATHS = ""\n' >"$root/.kendex/settings.toml" ;;
      local-malformed)
        mkdir -p "$root/.kendex"
        printf '[env]\nHARNESS_CI_STANDARD_PATHS = src/*.rs\n' >"$root/.kendex/settings.toml" ;;
    esac
    assert_eq "repository standard paths: $setting $input" "$want rc=0" \
      "$(CEILING="$ceiling" ARM_RAW=true run_arm --production 1 --repo "$root" "${args[@]}")"
  done <<'SETTINGS'
resolver-failed||change_class=standard class=standard measured=false delta=- cause=base-settings-unreadable
match|src/*.rs|change_class=standard class=standard measured=true delta=- cause=repository-standard-path setting=HARNESS_CI_STANDARD_PATHS path=src/main.rs glob=src/*.rs
unset||change_class=micro class=micro measured=true delta=- cause=estimate-within-micro production=1
empty||change_class=micro class=micro measured=true delta=- cause=estimate-within-micro production=1
local-empty|src/*.rs|change_class=micro class=micro measured=true delta=- cause=estimate-within-micro production=1
root-malformed||change_class=standard class=standard measured=false delta=- cause=base-settings-unreadable
local-malformed||change_class=standard class=standard measured=false delta=- cause=base-settings-unreadable
SETTINGS
}
assert_standard_setting
rm -rf -- "$WORK/kendex.settings.toml" "$WORK/.kendex" "$SANDBOX/nonrepo"
settings_control() { # NAME SETTING LINE REPLACEMENT
  ARM_BIN="$(mutant "$1" lib/change-scope.sh "$3" "$4")" SETTING_ONLY="$2" control "$1" assert_standard_setting
  rm -rf -- "$WORK/kendex.settings.toml" "$WORK/.kendex" "$SANDBOX/nonrepo"
}
settings_control standard-paths match \
  '    if change_class_path_match "$1" "${CHANGE_CLASS_STANDARD_PATHS:-}"; then' '    if false; then'
settings_control root-refusal root-malformed \
  '    kendex_load_settings_file "$root/kendex.settings.toml" -- HARNESS_CI_STANDARD_PATHS || exit 1' \
  '    kendex_load_settings_file "$root/kendex.settings.toml" -- HARNESS_CI_STANDARD_PATHS || :'
settings_control local-refusal local-malformed \
  '    kendex_load_settings_file "$root/.kendex/settings.toml" -- HARNESS_CI_STANDARD_PATHS || exit 1' \
  '    kendex_load_settings_file "$root/.kendex/settings.toml" -- HARNESS_CI_STANDARD_PATHS || :'
settings_control root-resolution resolver-failed \
  '  root="$(change_scope_main_root "$1")" || return 1' '  root="$(change_scope_main_root "$1")" || root="$1"'
settings_control local-precedence local-empty \
  '    kendex_load_settings_file "$root/.kendex/settings.toml" -- HARNESS_CI_STANDARD_PATHS || exit 1' '    : "$root/.kendex/settings.toml" || exit 1'

# Expected delta floors the estimate; a body with no count is standard.
LOCATION='**Location**: `src/main.rs`'
printf '%s\n**Expected delta**: %s lines, 1 test line\n' "$LOCATION" "$((SMALL_MAX + 1))" >"$SANDBOX/body"
printf '%s\nNo sizing headers\n' "$LOCATION" >"$SANDBOX/empty-body"
printf '%s\n**Expected delta**: junk\n' "$LOCATION" >"$SANDBOX/bad-body"
printf '%s\n**Expected delta**: 4 lines, 0 test lines\n' "$LOCATION" >"$SANDBOX/zero-test-body"
printf '%s\n**Expected delta**: 0 lines\n' "$LOCATION" >"$SANDBOX/zero-body"
printf '%s\n**Expected delta**: %s lines\n' "$LOCATION" "$((SMALL_MAX + 1))" >"$SANDBOX/bare-body"
body_rows=0
while IFS='|' read -r args want raw; do
  body_rows=$((body_rows + 1))
  # shellcheck disable=SC2086
  assert_eq "body input: $args" "$want" "$(ARM_RAW="${raw:-false}" run_arm $args)"
done <<ROWS
--production 1 --body $SANDBOX/body|standard cause=estimate-past-small rc=0
--body $SANDBOX/body|standard cause=estimate-past-small rc=0
--production $((SMALL_MAX + 2)) --body $SANDBOX/body|change_class=standard class=standard measured=true delta=$((SMALL_MAX + 1)) cause=estimate-past-small production=$((SMALL_MAX + 2)) rc=0|true
--production 1 --body $SANDBOX/empty-body|micro cause=estimate-within-micro rc=0
--production 1 --body $SANDBOX/empty-body --path src/main.rs|micro cause=estimate-within-micro rc=0
--body $SANDBOX/empty-body|change_class=standard class=standard measured=true delta=- cause=body-without-tier-inputs rc=0|true
--body $SANDBOX/empty-body --path src/main.rs|standard cause=body-without-tier-inputs rc=0
--body $SANDBOX/empty-body --path skills/x/SKILL.md|standard cause=body-without-tier-inputs rc=0
--body $SANDBOX/empty-body --path kendex.settings.toml|standard cause=body-without-tier-inputs rc=0
--body $SANDBOX/empty-body --path src/main.rs --floor micro|standard cause=body-without-tier-inputs rc=0
--body $SANDBOX/empty-body --path src/main.rs --floor standard|standard cause=body-without-tier-inputs rc=0
--body $SANDBOX/bad-body --path src/main.rs|standard cause=body-without-tier-inputs rc=0
--production 1 --body $SANDBOX/bad-body|micro cause=estimate-within-micro rc=0
--body $SANDBOX/zero-test-body|change_class=micro class=micro measured=true delta=4 cause=estimate-within-micro production=4 rc=0|true
--body $SANDBOX/zero-body|change_class=micro class=micro measured=true delta=0 cause=estimate-within-micro production=0 rc=0|true
--body $SANDBOX/bare-body|change_class=standard class=standard measured=true delta=$((SMALL_MAX + 1)) cause=estimate-past-small production=$((SMALL_MAX + 1)) rc=0|true
ROWS
require_rows body "$body_rows"
assert_no_count() {
  assert_eq "a body without counts is standard whatever its paths" "standard cause=body-without-tier-inputs rc=0" \
    "$(run_arm --body "$SANDBOX/empty-body" --path src/main.rs)"
}
ARM_BIN="$(mutant path-exclusion change-scope \
  '    [ -n "$production" ] || launch_consider standard body-without-tier-inputs' \
  '    [ -n "$production" ] || [ "${#paths[@]}" -gt 0 ] || launch_consider standard body-without-tier-inputs')" \
  control path-exclusion assert_no_count
assert_delta_floor() {
  assert_eq "the delta floors a smaller estimate" "standard cause=estimate-past-small rc=0" \
    "$(run_arm --production 1 --body "$SANDBOX/body")"
}
ARM_BIN="$(mutant no-delta-floor change-scope '      production="$delta"' '      production="$production"')" \
  control no-delta-floor assert_delta_floor

# A malformed or empty header warns once naming the line and reads as no
# delta. The wording past the line is not pinned.
printf '%s\n**Expected delta**: about 4 lines\n' "$LOCATION" >"$SANDBOX/about-body"
printf '%s\n**Expected delta**:\n' "$LOCATION" >"$SANDBOX/empty-delta-body"
warn_count() { # BODY LINE
  local err
  err="$(env -i PATH="$PATH" HOME="$SANDBOX" TMPDIR="$SANDBOX" "${ARM_BIN:-$ARM}" launch --repo "$WORK" \
    --production 1 --body "$1" 2>&1 >/dev/null)" || true
  grep -c "^launch-warning: cause=invalid-delta line=\[$2\]" <<<"$err" || true
}
assert_malformed_warns() {
  assert_eq "a malformed Expected delta warns once naming the line" 1 "$(warn_count "$SANDBOX/about-body" 'about 4 lines')"
  assert_eq "an empty Expected delta warns once" 1 "$(warn_count "$SANDBOX/empty-delta-body" '')"
  assert_eq "a malformed Expected delta proceeds with no delta" \
    "change_class=micro class=micro measured=true delta=- cause=estimate-within-micro production=1 rc=0" \
    "$(ARM_RAW=true run_arm --production 1 --body "$SANDBOX/about-body")"
}
assert_zero_reads() {
  assert_eq "a stated zero test count reads" \
    "change_class=micro class=micro measured=true delta=4 cause=estimate-within-micro production=4 rc=0" \
    "$(ARM_RAW=true run_arm --body "$SANDBOX/zero-test-body")"
}
assert_malformed_warns
assert_zero_reads
IFS= read -r warning_line <<'LINE'
      printf 'launch-warning: cause=invalid-delta line=[%s] accepted=[N lines] [N lines, M test lines] (1 line, 1 test line singular; 0 a stated zero); read as no delta\n' \
LINE
ARM_BIN="$(mutant no-delta-warning change-scope "$warning_line" '      printf "" \')" \
  control no-delta-warning assert_malformed_warns
IFS= read -r empty_check <<'LINE'
  grep -qE "$header" <<<"$1" || return 0
LINE
IFS= read -r no_empty_check <<'LINE'
  [[ -n "$(sed -n "/$header/p" <<<"$1" | sed "s/$header[[:space:]]*//")" ]] || return 0
LINE
ARM_BIN="$(mutant no-empty-check lib/branch-growth.sh "$empty_check" "$no_empty_check")" \
  control no-empty-check assert_malformed_warns
IFS= read -r grammar <<'LINE'
  local grammar='^(0 lines|1 line|[2-9] lines|[1-9][0-9]+ lines)(, (0 test lines|1 test line|[2-9] test lines|[1-9][0-9]+ test lines))?$'
LINE
ARM_BIN="$(mutant no-zero lib/branch-growth.sh "$grammar" "${grammar//(0 test lines|/(}")" \
  control no-zero assert_zero_reads

# The shared rules' controls: the list's one-segment glob needs extglob, the
# instruction floor, and the pre-render phase of configuration sources.
assert_path_rules() {
  assert_eq "a hook body Location is never micro" "standard cause=excluded-path rc=0" \
    "$(run_arm --production 1 --path hooks/block-bare-cd.sh)"
  assert_eq "a SKILL.md Location is never micro" "small cause=instruction-file rc=0" \
    "$(run_arm --production 1 --path skills/x/SKILL.md)"
  assert_eq "a settings Location is standard" "standard cause=configuration-source rc=0" \
    "$(run_arm --production 1 --path kendex.settings.toml)"
}
ARM_BIN="$(mutant no-extglob change-scope 'shopt -s extglob' -)" control no-extglob assert_path_rules
ARM_BIN="$(mutant no-instruction-floor lib/change-scope.sh '      CHANGE_CLASS_PATH=small' '      CHANGE_CLASS_PATH=""')" \
  control no-instruction-floor assert_path_rules
ARM_BIN="$(mutant no-configuration lib/change-scope.sh \
  '  if [ "$2" = before-render ] || [ "$2" = launch ]; then' '  if false; then')" \
  control no-configuration assert_path_rules

# A ceiling list the arm cannot use is standard, never a narrower class.
cp -R "$LAYOUT" "$SANDBOX/no-conf"
rm -- "$SANDBOX/no-conf/change-scope/references/narrow-change.conf"
cp -R "$LAYOUT" "$SANDBOX/no-small-ceiling"
grep -v '^small_max_production=' "$CONF" >"$SANDBOX/no-small-ceiling/change-scope/references/narrow-change.conf"
assert_eq "no ceiling list is standard, unmeasured" \
  "change_class=standard class=standard measured=false delta=- cause=narrow-change-unreadable rc=0" \
  "$(ARM_BIN="$SANDBOX/no-conf/change-scope/scripts/change-scope" ARM_RAW=true run_arm --production 1)"
assert_eq "a missing ceiling is standard, unmeasured" \
  "change_class=standard class=standard measured=false delta=- cause=narrow-change-ceilings-missing rc=0" \
  "$(ARM_BIN="$SANDBOX/no-small-ceiling/change-scope/scripts/change-scope" ARM_RAW=true run_arm --production 1)"
assert_eq "an unreadable list under a Location path is standard" \
  "standard cause=narrow-change-list-unreadable rc=0" \
  "$(ARM_BIN="$SANDBOX/no-conf/change-scope/scripts/change-scope" run_arm --floor micro --path src/main.rs)"

# A range: its changed paths take the same rules; its size never decides.
RANGE="$(new_repo range)"
printf 'seed\n' >"$RANGE/seed"
git -C "$RANGE" add -A
git -C "$RANGE" commit -qm seed
BASE="$(git -C "$RANGE" rev-parse HEAD)"
mkdir -p "$RANGE/src"
awk 'BEGIN {for (i=0;i<1000;i++) print "pub fn source_" i "() {}"}' >"$RANGE/src/main.rs"
git -C "$RANGE" add -A
git -C "$RANGE" commit -qm source
assert_eq "branch growth does not replace the launch estimate" "micro cause=estimate-within-micro rc=0" \
  "$(run_arm --production 1 --base "$BASE" --head HEAD --repo "$RANGE")"
assert_eq "branch growth does not replace the recorded floor" "small cause=floor class=small rc=0" \
  "$(run_arm --floor small --base "$BASE" --head HEAD --repo "$RANGE")"
assert_eq "a range alone is micro" "micro cause=branch-paths rc=0" \
  "$(run_arm --base "$BASE" --head HEAD --repo "$RANGE")"
assert_unread_range() {
  assert_eq "an unreadable range is standard, unmeasured" \
    "change_class=standard class=standard measured=false delta=- cause=branch-paths-unreadable rc=0" \
    "$(ARM_RAW=true run_arm --base "$BASE" --head no-such-revision --repo "$RANGE")"
}
assert_unread_range
ARM_BIN="$(mutant range-unread change-scope \
  '      launch_consider standard branch-paths-unreadable unmeasured' '      launch_consider micro branch-paths')" \
  control range-unread assert_unread_range
assert_standard_setting "$RANGE" range
rm -rf -- "$RANGE/kendex.settings.toml" "$RANGE/.kendex"

# A linked lane changes its local setting; the main checkout still owns it.
printf '[env]\nHARNESS_CI_STANDARD_PATHS = "src/*.rs"\n' >"$RANGE/kendex.settings.toml"
git -C "$RANGE" worktree add -q -b lane "$SANDBOX/lane"
printf '[env]\nHARNESS_CI_STANDARD_PATHS = ""\n' >"$SANDBOX/lane/kendex.settings.toml"
assert_main_checkout() {
  local args
  for args in "--path src/main.rs" "--base $BASE --head HEAD"; do
    # shellcheck disable=SC2086
    assert_eq "a lane's $args reads standard paths from the main checkout" \
      "standard cause=repository-standard-path rc=0" \
      "$(run_arm --production 1 --repo "$SANDBOX/lane" $args)"
  done
}
assert_main_checkout
ARM_BIN="$(mutant lane-settings lib/change-scope.sh \
  '    */.git) printf '"'"'%s\n'"'"' "${common%/.git}" ;;' \
  '    */.git) git -C "$1" rev-parse --show-toplevel 2>/dev/null ;;')" \
  control lane-settings assert_main_checkout
rm -- "$RANGE/kendex.settings.toml"

assert_range_paths() {
  assert_eq "a changed instruction file in the range selects small" "small cause=instruction-file rc=0" \
    "$(run_arm --production 1 --base "$BASE" --head HEAD --repo "$RANGE")"
  assert_eq "a SKILL.md metadata.version line alone selects small" "small cause=instruction-file rc=0" \
    "$(run_arm --production 1 --base "$SKILL_BASE" --head HEAD --repo "$RANGE")"
}
printf '# Instructions\n' >"$RANGE/AGENTS.md"
git -C "$RANGE" add -A
git -C "$RANGE" commit -qm instructions
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
assert_range_paths
# The range's path rule dropped, its git read kept: the last of the arm's two
# path-rule calls, which is the range loop's.
cp -R "$LAYOUT" "$SANDBOX/no-range-paths"
awk -v line='        change_class_path "$path" launch' '
  { body[NR] = $0; if ($0 == line) last = NR }
  END { if (!last) exit 3; for (i = 1; i <= NR; i++) print (i == last ? "        CHANGE_CLASS_PATH=\"\"" : body[i]) }
' "$ARM" >"$SANDBOX/no-range-paths/change-scope/scripts/change-scope"
ARM_BIN="$SANDBOX/no-range-paths/change-scope/scripts/change-scope" control no-range-paths assert_range_paths

# A range that removes test protection launches at small, read as the size
# path reads it, net over the range; one whose read fails is standard.
PROTECT="$(new_repo protect)"
protect_commit() { # BRANCH TEST_LINES... -> prints the commit
  local branch="$1"
  shift
  git -C "$PROTECT" checkout -q -B "$branch" "${PROTECT_BASE:-HEAD}"
  mkdir -p "$PROTECT/src"
  printf '%s\n' 'pub fn one() -> u32 {' '    1' '}' '' '#[cfg(test)]' 'mod tests {' ${1+"$@"} '}' >"$PROTECT/src/lib.rs"
  git -C "$PROTECT" add -A
  git -C "$PROTECT" commit -qm "$branch"
  git -C "$PROTECT" rev-parse HEAD
}
PROTECT_BASE=""
PROTECT_BASE="$(protect_commit base '    #[test]' '    fn one_is_one() {' '        assert_eq!(super::one(), 1);' '    }')"
PROTECT_DELETED="$(protect_commit deleted)"
PROTECT_REWRITTEN="$(protect_commit rewritten '    #[tokio::test]' '    async fn one_is_one() {' \
  '        assert_eq!(super::one(), 2 - 1);' '    }')"
git -C "$PROTECT" checkout -q -B quoted "$PROTECT_BASE"
printf 'x\n' >"$PROTECT/src/odd\"name.rs"
git -C "$PROTECT" add -A
git -C "$PROTECT" commit -qm quoted
PROTECT_QUOTED="$(git -C "$PROTECT" rev-parse HEAD)"
assert_range_deletes() {
  assert_eq "a range deleting a test case selects small" \
    "change_class=small class=small measured=true delta=- cause=protection-removed kind=case path=src/lib.rs removed=1 added=0 rc=0" \
    "$(ARM_RAW=true run_arm --base "$PROTECT_BASE" --head "$PROTECT_DELETED" --repo "$PROTECT")"
}
assert_range_rewrites() {
  assert_eq "a range rewriting a test in place stays micro" "micro cause=branch-paths rc=0" \
    "$(run_arm --base "$PROTECT_BASE" --head "$PROTECT_REWRITTEN" --repo "$PROTECT")"
}
assert_range_unreadable() {
  assert_eq "a range whose protection read fails is standard, unmeasured" \
    "change_class=standard class=standard measured=false delta=- cause=protection-unreadable rc=0" \
    "$(ARM_RAW=true run_arm --base "$PROTECT_BASE" --head "$PROTECT_QUOTED" --repo "$PROTECT")"
}
assert_range_deletes
assert_range_rewrites
assert_range_unreadable
ARM_BIN="$(mutant no-range-floor change-scope '      elif [ -n "$BRANCH_PROTECTION_KIND" ]; then' '      elif false; then')" \
  control no-range-floor assert_range_deletes
ARM_BIN="$(mutant range-gross lib/branch-growth.sh \
  '      for (k = 1; k <= n; k++) if (kind[k] == "case" && lost[k] > gained[k]) {' \
  '      for (k = 1; k <= n; k++) if (kind[k] == "case" && lost[k] > 0) {')" \
  control range-gross assert_range_rewrites
ARM_BIN="$(mutant range-read-continues change-scope \
  '        launch_consider standard protection-unreadable unmeasured' '        true')" \
  control range-read-continues assert_range_unreadable

# Catalog additions carry their render and its inventory name in the same diff.
INVENTORY_RANGE="$(new_repo inventory-range)"
printf '[".kendex-generated.json",{"path":".agents/skills/x/scripts/kept","template":"x","templateHash":"sha256:%064d"}]\n' 0 \
  >"$INVENTORY_RANGE/.kendex-generated.json"
mkdir -p "$INVENTORY_RANGE/.agents/skills/x/scripts" "$INVENTORY_RANGE/skills/x/scripts"
printf 'kept\n' >"$INVENTORY_RANGE/.agents/skills/x/scripts/kept"
printf 'kept\n' >"$INVENTORY_RANGE/skills/x/scripts/kept"
git -C "$INVENTORY_RANGE" add -A
git -C "$INVENTORY_RANGE" commit -qm inventory-base
INVENTORY_BASE="$(git -C "$INVENTORY_RANGE" rev-parse HEAD)"
assert_inventory_ranges() {
  local edit expected root
  while IFS='|' read -r edit expected; do
    [ -z "${INVENTORY_ONLY:-}" ] || [ "$INVENTORY_ONLY" = "$edit" ] || continue
    git -C "$INVENTORY_RANGE" reset -q --hard "$INVENTORY_BASE"
    git -C "$INVENTORY_RANGE" clean -qfd
    root=.agents
    [ "$edit" != unrendered-root ] || root=.other
    [ "$edit" != repository-standard ] ||
      printf '[env]\nHARNESS_CI_STANDARD_PATHS = ".kendex-generated.json"\n' >"$INVENTORY_RANGE/kendex.settings.toml"
    mkdir -p "$INVENTORY_RANGE/$root/skills/x/scripts"
    printf 'added\n' >"$INVENTORY_RANGE/skills/x/scripts/added"
    printf 'added\n' >"$INVENTORY_RANGE/$root/skills/x/scripts/added"
    jq --arg added "$root/skills/x/scripts/added" '. + [$added]' \
      "$INVENTORY_RANGE/.kendex-generated.json" >"$SANDBOX/next-inventory"
    case "$edit" in
      hash-edited)
        jq --arg hash "sha256:$(printf '%064d' 1)" \
          'map(if type == "object" then .templateHash = $hash else . end)' \
          "$SANDBOX/next-inventory" >"$INVENTORY_RANGE/.kendex-generated.json" ;;
      kept-unlisted)
        jq 'map(select(type != "object"))' "$SANDBOX/next-inventory" >"$INVENTORY_RANGE/.kendex-generated.json" ;;
      *) cp "$SANDBOX/next-inventory" "$INVENTORY_RANGE/.kendex-generated.json" ;;
    esac
    git -C "$INVENTORY_RANGE" add -A
    git -C "$INVENTORY_RANGE" commit -qm "$edit"
    assert_eq "inventory range: $edit" "$expected" \
      "$(run_arm --floor small --base "$INVENTORY_BASE" --head HEAD --repo "$INVENTORY_RANGE")"
  done <<'INVENTORY'
added|small cause=floor class=small rc=0
hash-edited|standard cause=excluded-path rc=0
kept-unlisted|standard cause=excluded-path rc=0
unrendered-root|standard cause=excluded-path rc=0
repository-standard|standard cause=repository-standard-path rc=0
INVENTORY
}
assert_inventory_ranges
ARM_BIN="$(mutant no-inventory-exception change-scope \
  '          change_scope_inventory_rendered "$base" "$head" "$repo" "$launch_work/inventory-err"; then' \
  '          false; then')" INVENTORY_ONLY=added control no-inventory-exception assert_inventory_ranges

report launch
