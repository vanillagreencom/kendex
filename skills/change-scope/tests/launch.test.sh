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

# kendex as the arm's classifier meets it: a verify that passes and names the
# positions a real run names, the render tree and the two bookkeeping files,
# never a catalog source. No row runs the host's kendex.
STUB_BIN="$SANDBOX/stub-bin"
mkdir -p "$STUB_BIN"
cat >"$STUB_BIN/kendex" <<'STUB'
#!/usr/bin/env bash
case "$*" in
  --version) echo 'kendex 0.0.0-stub' ;;
  'verify --help') echo '  --scope <SCOPE> --json' ;;
  'verify '*)
    tree="${STUB_RENDER_TREE:-.agents/skills/x}"
    printf '{"version":1,"checked":3,"failed":0,"rows":[
{"kind":"skill","name":"%s","harness":"claude","state":"ok","positions":[{"path":"%s","owns":"tree"}]},
{"kind":"record","name":".kendex-lock.json","state":"ok","positions":[{"path":".kendex-lock.json","owns":"file"}]},
{"kind":"inventory","name":".kendex-generated.json","state":"ok","positions":[{"path":".kendex-generated.json","owns":"file"}]}]}\n' "${tree##*/}" "$tree" ;;
  *) exit 2 ;;
esac
STUB
chmod +x "$STUB_BIN/kendex"
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
  out="$(env -i GIT_CEILING_DIRECTORIES="${CEILING:-$SANDBOX}" PATH="$STUB_BIN:$PATH" HOME="$SANDBOX" \
    TMPDIR="$SANDBOX" STUB_RENDER_TREE="${STUB_RENDER_TREE:-}" \
    "${ARM_BIN:-$ARM}" launch --repo "$WORK" "$@" 2>"$SANDBOX/arm.err")" || rc=$?
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

# Location entries can name folders that are absent from the checkout.
while IFS='|' read -r path want; do
  for entry in "$path" "$path/"; do
    assert_eq "folder Location: $entry" "$want rc=0" "$(run_arm --production 1 --path "$entry")"
  done
done <<'FOLDERS'
skills/orch/runtime/src/ops|standard cause=excluded-path
skills/orch/runtime/src|standard cause=excluded-path
.agents/skills/orch/runtime/src/ops|standard cause=excluded-path
.github/workflows|standard cause=excluded-path
projects/one/.codex|standard cause=configuration-source
.gemini|standard cause=configuration-source
skills/orch/workflows|micro cause=estimate-within-micro
hooks/tests/fixtures|micro cause=estimate-within-micro
projects/one|micro cause=estimate-within-micro
FOLDERS

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
--production 1 --path kendex.settings.toml|micro cause=estimate-within-micro rc=0|a settings Location keeps the estimate's class
--production 1 --path kendex.toml|micro cause=estimate-within-micro rc=0|a manifest Location keeps the estimate's class
--production 1 --path kendex-local.toml|micro cause=estimate-within-micro rc=0|a catalog manifest Location keeps the estimate's class
--production 1 --path .kendex/settings.toml|micro cause=estimate-within-micro rc=0|a local settings Location keeps the estimate's class
--production 1 --path src/main.rs|micro cause=estimate-within-micro rc=0|a plain source Location keeps the estimate's class
--production 1 --path .github/workflows/build.yml|standard cause=excluded-path rc=0|a workflow Location is standard at any estimate
--production 1 --path src/main.rs --path .claude/settings.json|standard cause=configuration-source rc=0|each Location is classified, not only the first
--production 1 --path .pi/settings.json|standard cause=configuration-source rc=0|a registry Location proves no render
--production 1 --path CLAUDE.md|micro cause=estimate-within-micro rc=0|an instruction pointer Location keeps the estimate's class
--production 1 --path $PR_MERGE|standard cause=excluded-path rc=0|a merge-gate Location is never micro whatever the estimate
--production 1 --path skills/orch/runtime/src/validate/entry.rs|standard cause=excluded-path rc=0|a validation entry Location is never micro
--production 1 --path skills/orch/runtime/src/ops/tier.rs|standard cause=excluded-path rc=0|the cycle's decider is never micro
--production 1 --path skills/orch/workflows/review-pr.md|micro cause=estimate-within-micro rc=0|a Location off the list leaves the estimate's class
--production 1 --path hooks/block-bare-cd.sh|standard cause=excluded-path rc=0|a hook body Location is never micro
--production 1 --path hooks/tests/block-bare-cd.test.sh|micro cause=estimate-within-micro rc=0|a hook suite Location leaves the estimate's class
--production 1 --path skills/x/SKILL.md|micro cause=estimate-within-micro rc=0|a SKILL.md Location keeps the estimate's class
--production 1 --path AGENTS.md|micro cause=estimate-within-micro rc=0|a root AGENTS.md Location keeps the estimate's class
--production 1 --path tools/AGENTS.md|micro cause=estimate-within-micro rc=0|Markdown under a whole-tree path line keeps the estimate's class
--production 1 --path tools/spec.md/|standard cause=excluded-path rc=0|a slash marks a folder even if its name ends in .md
--production 1 --path tools/spec.markdown/|standard cause=excluded-path rc=0|a slash marks a folder even if its name ends in .markdown
--production 1 --path tools/guard|standard cause=excluded-path rc=0|a script under that tree is never micro
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
  local setting globs want root ceiling repo="${1:-$WORK}" input="${2:-location}" location args
  args=(--path src/main.rs)
  [ "$input" != range ] || args=(--base "$BASE" --head HEAD)
  while IFS='|' read -r setting globs want location; do
    [ -z "${SETTING_ONLY:-}" ] || [ "$SETTING_ONLY" = "$setting" ] || continue
    if [ -n "$location" ]; then
      [ "$input" != range ] || continue
      args=(--path "$location")
    elif [ "$input" = location ]; then
      args=(--path src/main.rs)
    fi
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
folder-match|src/*.rs|change_class=standard class=standard measured=true delta=- cause=repository-standard-path setting=HARNESS_CI_STANDARD_PATHS path=src/generated/ glob=src/*.rs|src/generated/
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
  '    if change_class_path_match "$1" "${CHANGE_CLASS_STANDARD_PATHS:-}" repository "$mode"; then' '    if false; then'
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

while IFS='|' read -r glob path; do
  printf '[env]\nHARNESS_CI_STANDARD_PATHS = "%s"\n' "$glob" >"$WORK/kendex.settings.toml"
  for entry in "$path" "$path/"; do
    assert_eq "configured extglob reaches under $entry" "standard cause=repository-standard-path rc=0" \
      "$(run_arm --production 1 --path "$entry")"
  done
  assert_eq "configured extglob $glob keeps a folder outside its tree micro" "micro cause=estimate-within-micro rc=0" \
    "$(run_arm --production 1 --path unrelated/)"
done <<'EXTGLOBS'
runtime/!(kept).ts|runtime/generated
src/@(generated/api)/*.rs|src/generated
EXTGLOBS
rm -- "$WORK/kendex.settings.toml"

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

# The shared rules' controls: the list's one-segment glob needs extglob, and
# the pre-render phase of configuration sources.
assert_path_rules() {
  assert_eq "a hook body Location is never micro" "standard cause=excluded-path rc=0" \
    "$(run_arm --production 1 --path hooks/block-bare-cd.sh)"
  assert_eq "a Gemini settings Location is standard" "standard cause=configuration-source rc=0" \
    "$(run_arm --production 1 --path .gemini/settings.json)"
}
ARM_BIN="$(mutant no-extglob change-scope 'shopt -s extglob' -)" control no-extglob assert_path_rules
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

# A range: its changed paths take the same rules, and the classifier's reading
# of it, its production lines included, is one more input.
RANGE="$(new_repo range)"
printf 'seed\n' >"$RANGE/seed"
git -C "$RANGE" add -A
git -C "$RANGE" commit -qm seed
BASE="$(git -C "$RANGE" rev-parse HEAD)"
mkdir -p "$RANGE/src"
printf 'pub fn source() {}\n' >"$RANGE/src/main.rs"
git -C "$RANGE" add -A
git -C "$RANGE" commit -qm source
assert_eq "a range alone takes the classifier's class" "micro cause=branch-class class=micro rc=0" \
  "$(run_arm --base "$BASE" --head HEAD --repo "$RANGE")"

# The cheapest class: a range confined to kendex manifests, JSON settings
# files and Markdown takes the classifier's trivial class at any size and
# any table, which the arm reads as micro. Each exception keeps its own
# rule, and a path beside the set reads by that path. Every row branches off
# one base: EDITS is `PATH=CONTENT` pairs joined by `;`, each CONTENT written
# whole with printf %b, or `PATH+N` for N lines added. A RAW row compares the
# whole class line. A row can name the tree the verifier's skill position owns.
QUICK="$(new_repo quick)"
QUICK_RENDER=.agents/skills/project-management/SKILL.md
quick_map() { # ENTRIES -> a kendex-local.toml holding a multiline project map
  printf "schema = 8\\\\nis_source_catalog = true\\\\n[skill-instructions]\\\\nproject-management = '''\\\\n### Project map\\\\n\\\\n%s'''\\\\n[sources.extra]\\\\nurl = \"%s\"" "$1" "${2:-https://example.invalid/a.git}"
}
quick_render() { # ENTRIES -> the SKILL.md that map renders
  printf -- '---\\nname: project-management\\n---\\n\\n<!-- kendex:project-instructions:start -->\\n### Project map\\n\\n%s<!-- kendex:project-instructions:end -->' "$1"
}
quick_write() { # PATH=CONTENT|PATH+N
  local spec="$1" file
  case "$spec" in
    *=*)
      file="$QUICK/${spec%%=*}"
      mkdir -p "${file%/*}"
      printf '%b\n' "${spec#*=}" >"$file" ;;
    *+*)
      file="$QUICK/${spec%+*}"
      mkdir -p "${file%/*}"
      awk -v n="${spec##*+}" 'BEGIN {for (i = 1; i <= n; i++) print "Added line " i "."}' >>"$file" ;;
  esac
}
QUICK_FILES='kendex.toml=schema = 8\n[install]\nmethod = "copy"\n[agent-frontmatter.claude.rust]\nmodel = "old"
kendex-local.toml='"$(quick_map '- Docs\n')"'
kendex.settings.toml=[env]\nORDINARY = "old"
.kendex/settings.toml=[env]\nORDINARY = "old"
'"$QUICK_RENDER"'='"$(quick_render '- Docs\n')"'
.kendex-lock.json={}
.vscode/settings.json={}
.claude/settings.json={}
.codex/hooks.json={}
.codex/config.toml=model = "old"
.github/hooks/guard.json={}
.pi/kendex/hooks.json={}
.mcp.json={}
opencode.json={}
.gemini/settings.json={}
script.sh=MODE="old"
AGENTS.md=# Agents
CLAUDE.md=@AGENTS.md
SKILL.md=# Root skill
skills/x/SKILL.md=---\nname: x\n---\n\n# X
skills/x/AGENTS.md=# X agents
skills/x/README.md=# x
skills/x/references/guide.md=# Guide
skills/x/workflows/run.md=# Run
skills/orch/workflows/micro.md=# Micro
tools/AGENTS.md=# Tools'
while IFS= read -r spec; do quick_write "$spec"; done <<<"$QUICK_FILES"
jq --arg path "$QUICK_RENDER" 'map(select(. != "CLAUDE.md")) + [$path]' "$QUICK/.kendex-generated.json" >"$SANDBOX/quick-inventory"
cp "$SANDBOX/quick-inventory" "$QUICK/.kendex-generated.json"
git -C "$QUICK" add -A
git -C "$QUICK" commit -qm base
QUICK_BASE="$(git -C "$QUICK" rev-parse HEAD)"
quick_settings_past_micro="$(awk -v n="$((MICRO_MAX + 1))" 'BEGIN {printf "[env]"; for (i = 1; i <= n; i++) printf "\\nKEY_%d = \"new\"", i}')"
assert_quick_ranges() {
  local row edits want raw render_tree spec rows=0
  while IFS='|' read -r row edits want raw render_tree; do
    [ -z "${QUICK_ROW:-}" ] || [ "$row" = "$QUICK_ROW" ] || continue
    rows=$((rows + 1))
    git -C "$QUICK" checkout -q -f -B "quick-$row" "$QUICK_BASE"
    while IFS= read -r spec; do
      [ -z "$spec" ] || quick_write "$spec"
    done <<<"${edits//;/$'\n'}"
    git -C "$QUICK" add -A
    git -C "$QUICK" commit -qm "$row"
    assert_eq "quick range: $row" "$want rc=0" \
      "$(ARM_RAW="${raw:-false}" STUB_RENDER_TREE="$render_tree" \
        run_arm --base "$QUICK_BASE" --head HEAD --repo "$QUICK")"
  done
  require_rows quick "$rows"
}
assert_quick_ranges <<QUICK_ROWS
skill-instructions-with-render|kendex-local.toml=$(quick_map '- Docs\n- Herdr\n- Upkeep\n');$QUICK_RENDER=$(quick_render '- Docs\n- Herdr\n- Upkeep\n')|micro cause=branch-class class=trivial|false|${QUICK_RENDER%/*}
install|kendex.toml=schema = 8\n[install]\nmethod = "symlink"\n[agent-frontmatter.claude.rust]\nmodel = "old"|micro cause=branch-class class=trivial
agent-frontmatter|kendex.toml=schema = 8\n[install]\nmethod = "copy"\n[agent-frontmatter.claude.rust]\nmodel = "new"|micro cause=branch-class class=trivial
settings-past-micro|kendex.settings.toml=$quick_settings_past_micro|micro cause=branch-class class=trivial
local-settings|.kendex/settings.toml=[env]\nHARNESS_CI_STANDARD_PATHS = "script.sh"|micro cause=branch-class class=trivial
sources|kendex-local.toml=$(quick_map '- Docs\n' https://example.invalid/b.git)|change_class=standard class=standard measured=true delta=- cause=branch-class class=standard rule=manifest-sources path=kendex-local.toml|true
lock|.kendex-lock.json={"version": 1}|standard cause=excluded-path
json-settings|.vscode/settings.json={"editor.tabSize": 2}|micro cause=branch-class class=trivial
claude-permissions|.claude/settings.json={"permissions": {"allow": []}}|standard cause=configuration-source
codex-hooks|.codex/hooks.json={"hooks": {}}|standard cause=configuration-source
codex-config|.codex/config.toml=model = "new"|standard cause=configuration-source
copilot-hooks|.github/hooks/guard.json={"hooks": {}}|standard cause=configuration-source
pi-hooks|.pi/kendex/hooks.json={"hooks": {}}|standard cause=configuration-source
mcp-servers|.mcp.json={"mcpServers": {"tool": {}}}|standard cause=configuration-source
opencode-mcp|opencode.json={"mcp": {}}|standard cause=configuration-source
gemini|.gemini/settings.json={"mcpServers": {}}|standard cause=configuration-source
skill-reference-200-lines|skills/x/references/guide.md+200|micro cause=branch-class class=trivial
skill-entry|skills/x/SKILL.md+3|micro cause=branch-class class=trivial
root-skill|SKILL.md+3|micro cause=branch-class class=trivial
root-agents|AGENTS.md+3|micro cause=branch-class class=trivial
nested-agents|skills/x/AGENTS.md+3|micro cause=branch-class class=trivial
claude-pointer|CLAUDE.md+3|micro cause=branch-class class=trivial
skill-render-alone|$QUICK_RENDER+3|change_class=standard class=standard measured=true delta=- cause=branch-class class=standard rule=render-path-unowned path=$QUICK_RENDER|true
skill-readme|skills/x/README.md+3|micro cause=branch-class class=trivial
skill-workflow|skills/x/workflows/run.md+3|micro cause=branch-class class=trivial
orch-tier-workflow|skills/orch/workflows/micro.md+3|micro cause=branch-class class=trivial
markdown-under-tools|tools/AGENTS.md+3|micro cause=branch-class class=trivial
manifest-beside-script|kendex.toml=schema = 8\n[install]\nmethod = "symlink"\n[agent-frontmatter.claude.rust]\nmodel = "old";script.sh=MODE="new"|change_class=micro class=micro measured=true delta=- cause=branch-class class=micro rule=production-within-micro production=2|true
QUICK_ROWS

# Ranges of a measured size, each a branch off one base. The MEM-460 range
# changes 7 files under one directory, 3 new and 4 modified, with 506
# production lines added.
SIZED="$(new_repo sized)"
mkdir -p "$SIZED/apps/sidecar/src"
for name in auth session store net; do
  awk -v n="$name" 'BEGIN {for (i=0;i<60;i++) print "export const " n "_" i " = " i ";"}' \
    >"$SIZED/apps/sidecar/src/$name.ts"
done
git -C "$SIZED" add -A
git -C "$SIZED" commit -qm seed
SIZED_BASE="$(git -C "$SIZED" rev-parse HEAD)"
sized_branch() { # BRANCH FILE=LINES...
  local spec file
  git -C "$SIZED" checkout -q -B "$1" "$SIZED_BASE"
  shift
  for spec in "$@"; do
    file="$SIZED/${spec%%=*}"
    mkdir -p "${file%/*}"
    awk -v n="${spec%%=*}" -v k="${spec#*=}" \
      'BEGIN {for (i=0;i<k;i++) print "export const added_" i " = \"" n "\";"}' >>"$file"
  done
  git -C "$SIZED" add -A
  git -C "$SIZED" commit -qm "$1"
}
sized_branch docs README.md=3
sized_branch micro "src/lib.rs=$MICRO_MAX"
sized_branch small "src/lib.rs=$SMALL_MAX"
sized_branch past-small "src/lib.rs=$((SMALL_MAX + 1))"
sized_branch mem-460 apps/sidecar/src/auth.ts=90 apps/sidecar/src/session.ts=70 \
  apps/sidecar/src/store.ts=40 apps/sidecar/src/net.ts=26 apps/sidecar/src/stall.ts=120 \
  apps/sidecar/src/retry.ts=100 apps/sidecar/src/signal.ts=60
awk 'NR > 20' "$SIZED/apps/sidecar/src/store.ts" >"$SANDBOX/store.ts"
cp -- "$SANDBOX/store.ts" "$SIZED/apps/sidecar/src/store.ts"
git -C "$SIZED" commit -qam "mem-460 deletions"
assert_eq "the MEM-460 fixture changes 7 files, 3 of them new" "7 3" \
  "$(git -C "$SIZED" diff --name-only "$SIZED_BASE...mem-460" | wc -l | tr -d ' ') $(
    git -C "$SIZED" diff --name-only --diff-filter=A "$SIZED_BASE...mem-460" | wc -l | tr -d ' ')"
assert_sized_ranges() {
  local args want name rows=0
  while IFS='|' read -r args want name; do
    rows=$((rows + 1))
    # shellcheck disable=SC2086
    assert_eq "$name" "$want" "$(run_arm $args --base "$SIZED_BASE" --repo "$SIZED")"
  done <<SIZED_ROWS
--head docs|micro cause=branch-class class=trivial rc=0|a docs range reads micro
--head micro|micro cause=branch-class class=micro rc=0|a range at the micro ceiling is micro
--head small|small cause=branch-class class=small rc=0|a range at the small ceiling is small
--head past-small|standard cause=branch-class class=standard rc=0|a range one past the small ceiling is standard
--floor small --head past-small|standard cause=branch-class class=standard rc=0|a small floor keeps no range past the small ceiling
--production 1 --head past-small|standard cause=branch-class class=standard rc=0|the range's size widens a narrower estimate
--floor small --head micro|small cause=floor class=small rc=0|a floor raises a micro range
--head mem-460|standard cause=branch-class class=standard rc=0|the MEM-460 range is standard
--floor small --head mem-460|standard cause=branch-class class=standard rc=0|the MEM-460 range is standard under a small floor
SIZED_ROWS
  require_rows sized "$rows"
  assert_eq "the MEM-460 range names the classifier's rule and its production lines" \
    "change_class=standard class=standard measured=true delta=- cause=branch-class class=standard rule=production-past-small production=506 rc=0" \
    "$(ARM_RAW=true run_arm --base "$SIZED_BASE" --head mem-460 --repo "$SIZED")"
}
assert_sized_ranges
ARM_BIN="$(mutant no-range-class change-scope \
  '      launch_range_class "$base" "$head" "$repo" "$launch_work/class-err"' \
  '      launch_consider micro branch-class')" \
  control no-range-class assert_sized_ranges
ARM_BIN="$(mutant narrow-unfloored change-scope '    class=micro' '    true')" \
  control narrow-unfloored assert_sized_ranges

# A classifier that cannot answer, here one whose harness-only is gone,
# leaves the range standard, unmeasured, and its own cause reaches the arm's
# stderr, where the tier verb carries it as a note.
assert_unread_class() { # ARM
  assert_eq "a classifier that cannot answer is standard, unmeasured" \
    "change_class=standard class=standard measured=false delta=- cause=branch-class-unreadable detail=classifier-exit-2 rc=0" \
    "$(ARM_BIN="$1" ARM_RAW=true run_arm --base "$SIZED_BASE" --head micro --repo "$SIZED")"
}
assert_class_err_replayed() {
  run_arm --base "$SIZED_BASE" --head micro --repo "$SIZED" >/dev/null
  assert_eq "the arm repeats the classifier's cause" "wiring-error: cause=harness-only-failed" \
    "$(grep -o '^wiring-error: cause=[a-z-]*' "$SANDBOX/arm.err" || true)"
}
cp -R "$LAYOUT" "$SANDBOX/no-reader"
rm -- "$SANDBOX/no-reader/change-scope/scripts/harness-only"
assert_unread_class "$SANDBOX/no-reader/change-scope/scripts/change-scope"
ARM_BIN="$SANDBOX/no-reader/change-scope/scripts/change-scope" assert_class_err_replayed
DROPPED_ARM="$(mutant class-err-dropped change-scope '    [ ! -s "$4" ] || cat -- "$4" >&2' -)"
rm -- "$SANDBOX/class-err-dropped/change-scope/scripts/harness-only"
ARM_BIN="$DROPPED_ARM" control class-err-dropped assert_class_err_replayed
UNREAD_ARM="$(mutant class-unread-continues change-scope \
  '    launch_consider standard "branch-class-unreadable detail=$CHANGE_SCOPE_CAUSE" unmeasured' '    true')"
rm -- "$SANDBOX/class-unread-continues/change-scope/scripts/harness-only"
control class-unread-continues assert_unread_class "$UNREAD_ARM"
assert_unread_range() {
  assert_eq "an unreadable range is standard, unmeasured" \
    "change_class=standard class=standard measured=false delta=- cause=branch-paths-unreadable rc=0" \
    "$(ARM_RAW=true run_arm --base "$BASE" --head no-such-revision --repo "$RANGE")"
}
assert_unread_range
ARM_BIN="$(mutant range-unread change-scope \
  '      launch_consider standard branch-paths-unreadable unmeasured' '      launch_consider micro branch-class')" \
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
  assert_eq "a changed hook body in the range selects standard by its path rule" "standard cause=excluded-path rc=0" \
    "$(run_arm --production 1 --base "$BASE" --head HEAD --repo "$RANGE")"
}
mkdir -p "$RANGE/hooks"
printf '#!/bin/sh\n' >"$RANGE/hooks/guard.sh"
git -C "$RANGE" add -A
git -C "$RANGE" commit -qm hook
assert_range_paths
ARM_BIN="$(mutant no-range-paths change-scope \
  '        change_class_path "$path" launch file' '        CHANGE_CLASS_PATH=""')" \
  control no-range-paths assert_range_paths

# Git diffs and declared Markdown paths identify files even when another
# extension would be protected under a hypothetical folder of the same name.
FILES="$(new_repo files)"
printf '[env]\nHARNESS_CI_STANDARD_PATHS = "src/*.rs"\nHARNESS_CI_DOCS_PATHS = "src/README.md"\n' \
  >"$FILES/kendex.settings.toml"
commit_paths "$FILES" base src/build.py src/README.md
FILES_BASE="$(git -C "$FILES" rev-parse HEAD)"
commit_paths "$FILES" source src/build.py
assert_eq "a range's file has no hypothetical descendants" "micro cause=branch-class class=micro rc=0" \
  "$(run_arm --base "$FILES_BASE" --head HEAD --repo "$FILES")"
FILES_SOURCE="$(git -C "$FILES" rev-parse HEAD)"
commit_paths "$FILES" docs src/README.md
HARNESS_ONLY="$LAYOUT/change-scope/scripts/harness-only" \
  assert_docs_verdict "a declared Markdown file has no hypothetical descendants" true \
    --event pull_request --base "$FILES_SOURCE" --head HEAD --repo "$FILES"

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
  assert_eq "a range rewriting a test in place stays micro" "micro cause=branch-class class=micro rc=0" \
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

# Catalog additions and removals carry their render and its inventory name in
# the same diff. A names-only inventory change under rendered roots is left to
# the classifier: an addition is standard there, since its render proof owns
# no catalog source, and a removal is read by its size.
INVENTORY_RANGE="$(new_repo inventory-range)"
printf '[".kendex-generated.json",{"path":".agents/skills/x/scripts/kept","template":"x","templateHash":"sha256:%064d"},".agents/skills/x/scripts/gone"]\n' 0 \
  >"$INVENTORY_RANGE/.kendex-generated.json"
mkdir -p "$INVENTORY_RANGE/.agents/skills/x/scripts" "$INVENTORY_RANGE/skills/x/scripts"
for name in kept gone; do
  printf '%s\n' "$name" >"$INVENTORY_RANGE/.agents/skills/x/scripts/$name"
  printf '%s\n' "$name" >"$INVENTORY_RANGE/skills/x/scripts/$name"
done
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
    if [ "$edit" = removed ]; then
      git -C "$INVENTORY_RANGE" rm -q skills/x/scripts/gone .agents/skills/x/scripts/gone
      jq 'map(select(. != ".agents/skills/x/scripts/gone"))' \
        "$INVENTORY_RANGE/.kendex-generated.json" >"$SANDBOX/next-inventory"
    else
      mkdir -p "$INVENTORY_RANGE/$root/skills/x/scripts"
      printf 'added\n' >"$INVENTORY_RANGE/skills/x/scripts/added"
      printf 'added\n' >"$INVENTORY_RANGE/$root/skills/x/scripts/added"
      jq --arg added "$root/skills/x/scripts/added" '. + [$added]' \
        "$INVENTORY_RANGE/.kendex-generated.json" >"$SANDBOX/next-inventory"
    fi
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
added|standard cause=branch-class class=standard rc=0
removed|small cause=floor class=small rc=0
hash-edited|standard cause=excluded-path rc=0
kept-unlisted|standard cause=excluded-path rc=0
unrendered-root|standard cause=excluded-path rc=0
repository-standard|standard cause=repository-standard-path rc=0
INVENTORY
}
assert_inventory_ranges
ARM_BIN="$(mutant no-inventory-exception change-scope \
  '          change_scope_inventory_rendered "$base" "$head" "$repo" "$launch_work/inventory-err"; then' \
  '          false; then')" INVENTORY_ONLY=removed control no-inventory-exception assert_inventory_ranges

report launch
