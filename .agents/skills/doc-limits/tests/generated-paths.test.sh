#!/usr/bin/env bash
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset DOC_LIMITS_CLASSES DOC_LIMITS_DEFAULT_CLASSES DOC_LIMITS_EXCLUDES DOC_LIMITS_SETTINGS_FILE
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_COMMAND="$TEST_DIR/../scripts/doc-limits"
SR="$SOURCE_COMMAND"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
R="$TMP/repo"
mkdir -p "$R/.agents/skills/owned" "$R/.agents/skills/rendered" "$R/tools"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
export DOC_LIMITS_CLASSES='*.md=1k'
printf '[[skills]]\nname = "owned"\nsource = "in-place"\n' >"$R/kendex.toml"
# The render writer omits the adopted source and records only its renders.
printf '[".agents/skills/rendered/SKILL.md"]\n' >"$R/.kendex-generated.json"
head -c 1025 /dev/zero | tr '\0' x >"$R/.agents/skills/rendered/SKILL.md"
printf 'owned\n' >"$R/.agents/skills/owned/SKILL.md"
git -C "$R" add -A
git -C "$R" commit -qm fixture
PASS=0
FAIL=0
run() {
  RC=0
  OUT="$(cd "$R" && "$SR" "$@" 2>&1)" || RC=$?
}
expect() { # EXPECTED-EXIT LABEL: assert the preceding run's result
  if [ "$RC" -eq "$1" ]; then
    PASS=$((PASS + 1)); printf '  ok: %s\n' "$2"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL: %s: exit %s\n%s\n' "$2" "$RC" "$OUT"
  fi
}
expect_first_line() { # EXPECTED LABEL
  local first="${OUT%%$'\n'*}"
  if [ "$first" = "$1" ]; then
    PASS=$((PASS + 1)); printf '  ok: %s\n' "$2"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL: %s: first line <%s>\n' "$2" "$first"
  fi
}
must_fail_first_line() { # FORMER-LINE LABEL
  local first="${OUT%%$'\n'*}"
  if [ "$first" != "$1" ]; then
    PASS=$((PASS + 1)); printf '  ok: %s\n' "$2"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL: %s: mutant retained <%s>\n' "$2" "$first"
  fi
}
must_fail() { # FORMER-EXIT MUTANT-EXIT LABEL: prove the former assertion turns red
  local assertion_rc=0
  (PASS=0; FAIL=0; expect "$1" "$3"; [ "$FAIL" -eq 0 ]) >"$TMP/control.log" || assertion_rc=$?
  if [ "$RC" -eq "$2" ] && [ "$assertion_rc" -ne 0 ]; then
    PASS=$((PASS + 1)); printf '  ok: %s\n' "$3"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL: %s: mutant exit %s\n' "$3" "$RC"
    cat "$TMP/control.log"
  fi
}
private_command() { # NAME: copy the command and set MUTANT
  local root="$TMP/$1"
  mkdir -p "$root/skills/doc-limits"
  cp -R "$TEST_DIR/../scripts" "$root/skills/doc-limits/scripts"
  ln -s "$TEST_DIR/../../commit-guards" "$root/skills/commit-guards"
  MUTANT="$root/skills/doc-limits/scripts/doc-limits"
}
run_mode() { # MODE
  case "$1" in
    worktree) run ;;
    staged) run --staged ;;
  esac
}

MODE_ASSERTIONS=0
while IFS='|' read -r name mode operation expected; do
  case "$operation" in
    listed) : ;;
    grow-owned)
      head -c 1025 /dev/zero | tr '\0' x >"$R/.agents/skills/owned/SKILL.md"
      git -C "$R" add .agents/skills/owned/SKILL.md
      ;;
    restore-owned)
      printf 'owned\n' >"$R/.agents/skills/owned/SKILL.md"
      git -C "$R" add .agents/skills/owned/SKILL.md
      ;;
  esac
  run_mode "$mode"
  expect "$expected" "$name: $mode"
  MODE_ASSERTIONS=$((MODE_ASSERTIONS + 1))
done <<'MODE_CASES'
listed-render-excluded|worktree|listed|0
unlisted-owned-source-measured|worktree|grow-owned|1
owned-source-restored|worktree|restore-owned|0
listed-render-excluded|staged|listed|0
unlisted-owned-source-measured|staged|grow-owned|1
owned-source-restored|staged|restore-owned|0
MODE_CASES
if [ "$MODE_ASSERTIONS" -eq 0 ]; then
  printf 'FAIL: MODE_CASES executed no assertions\n' >&2
  exit 1
fi

INVENTORY_ASSERTIONS=0
while IFS='|' read -r name mode operation expected first_line; do
  case "$operation" in
    inventory-worktree-empty) printf '[]\n' >"$R/.kendex-generated.json" ;;
    unchanged) : ;;
    stage-empty) git -C "$R" add .kendex-generated.json ;;
    delete-from-index)
      git -C "$R" checkout HEAD -- .kendex-generated.json
      git -C "$R" rm -q --cached .kendex-generated.json
      ;;
    small-without-inventory)
      printf 'rendered\n' >"$R/.agents/skills/rendered/SKILL.md"
      git -C "$R" add .agents/skills/rendered/SKILL.md
      ;;
    missing-worktree-fallback)
      head -c 1025 /dev/zero | tr '\0' x >"$R/.agents/skills/rendered/SKILL.md"
      git -C "$R" add .agents/skills/rendered/SKILL.md
      git -C "$R" add .kendex-generated.json
      rm "$R/.kendex-generated.json"
      ;;
    invalid-inventory)
      git -C "$R" checkout -- .kendex-generated.json
      printf '{}\n' >"$R/.kendex-generated.json"
      git -C "$R" add .kendex-generated.json
      ;;
    carve-back)
      git -C "$R" checkout HEAD -- .kendex-generated.json
      printf '!.agents/skills/rendered/*\tmeasure this render explicitly\n' >"$R/tools/doc-limits-excludes"
      git -C "$R" add tools/doc-limits-excludes
      ;;
  esac
  run_mode "$mode"
  expect "$expected" "$name: $mode"
  [ -z "$first_line" ] || expect_first_line "$first_line" "$name diagnostic: $mode"
  INVENTORY_ASSERTIONS=$((INVENTORY_ASSERTIONS + 1))
done <<'INVENTORY_CASES'
inventory-worktree-empty|worktree|inventory-worktree-empty|1
inventory-unstaged-empty|staged|unchanged|0
inventory-empty-staged|staged|stage-empty|1
inventory-deleted-from-index|staged|delete-from-index|1
inventory-absent-small-document|staged|small-without-inventory|0
inventory-worktree-missing-index-fallback|worktree|missing-worktree-fallback|0
inventory-invalid|worktree|invalid-inventory|2|error=inventory-invalid path=.kendex-generated.json
inventory-invalid|staged|unchanged|2|error=inventory-invalid path=.kendex-generated.json
render-carved-back|worktree|carve-back|1
render-carved-back|staged|unchanged|1
INVENTORY_CASES
if [ "$INVENTORY_ASSERTIONS" -eq 0 ]; then
  printf 'FAIL: INVENTORY_CASES executed no assertions\n' >&2
  exit 1
fi

git -C "$R" rm -qf tools/doc-limits-excludes
private_command generated-exclusion
[ ! -L "$MUTANT" ]
[ "$(grep -Fxc '  generated_path_contains "$1" \' "$MUTANT")" -eq 1 ]
sed 's/  generated_path_contains "\$1"/  false \&\& generated_path_contains "$1"/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
for mode in worktree staged; do
  run_mode "$mode"
  must_fail 0 1 "mode table control: disabled generated exclusion fails listed-render-excluded: $mode"
done
SR="$SOURCE_COMMAND"

printf '[]\n' >"$R/.kendex-generated.json"
private_command inventory-source
MUTANT_SETTINGS="$(dirname "$MUTANT")/lib/settings.sh"
[ ! -L "$MUTANT_SETTINGS" ]
[ "$(grep -Fxc '  if [ "${SR_SETTINGS_FROM_INDEX:-0}" != "1" ] || [ -z "${SR_SETTINGS_INDEX_DIR:-}" ]; then' "$MUTANT_SETTINGS")" -eq 1 ]
sed 's/  if \[ "${SR_SETTINGS_FROM_INDEX:-0}" != "1" \] || \[ -z "${SR_SETTINGS_INDEX_DIR:-}" \]; then/  if true || [ "${SR_SETTINGS_FROM_INDEX:-0}" != "1" ] || [ -z "${SR_SETTINGS_INDEX_DIR:-}" ]; then/' "$TEST_DIR/../scripts/lib/settings.sh" >"$MUTANT_SETTINGS.changed"
if cmp -s "$TEST_DIR/../scripts/lib/settings.sh" "$MUTANT_SETTINGS.changed"; then exit 1; fi
mv "$MUTANT_SETTINGS.changed" "$MUTANT_SETTINGS"
bash -n "$MUTANT_SETTINGS"
SR="$MUTANT"
run --staged
must_fail 0 1 'inventory table control: worktree inventory cannot replace indexed inventory'
SR="$SOURCE_COMMAND"

printf '{}\n' >"$R/.kendex-generated.json"
git -C "$R" add .kendex-generated.json
private_command inventory-diagnostic
[ "$(grep -Fxc "  || collection_error inventory-invalid path .kendex-generated.json 'cannot read .kendex-generated.json; jq is required; install or refresh kendex at the Git repository root in the main checkout and stage the inventory with the renders'" "$MUTANT")" -eq 1 ]
sed 's/collection_error inventory-invalid path/collection_error inventory-renamed path/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
run --staged
must_fail_first_line 'error=inventory-invalid path=.kendex-generated.json' 'inventory diagnostic control: changing the stable key fails inventory-invalid'

private_command inventory-parse
[ ! -L "$MUTANT" ]
[ "$(grep -Fxc "  || collection_error inventory-invalid path .kendex-generated.json 'cannot read .kendex-generated.json; jq is required; install or refresh kendex at the Git repository root in the main checkout and stage the inventory with the renders'" "$MUTANT")" -eq 1 ]
sed "s#^  || collection_error inventory-invalid path .kendex-generated.json 'cannot read .kendex-generated.json; jq is required; install or refresh kendex at the Git repository root in the main checkout and stage the inventory with the renders'\$#  || :#" "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
run --staged
must_fail 2 1 'inventory table control: bypassing parse failure fails inventory-invalid'
SR="$SOURCE_COMMAND"

git -C "$R" checkout HEAD -- .kendex-generated.json
mkdir -p "$R/tools"
printf '!.agents/skills/rendered/*\tmeasure this render explicitly\n' >"$R/tools/doc-limits-excludes"
git -C "$R" add tools/doc-limits-excludes
private_command carve-back
[ ! -L "$MUTANT" ]
[ "$(grep -Fxc '  ! glob_match "$1" ${CARVE_PATTERNS[@]+"${CARVE_PATTERNS[@]}"}' "$MUTANT")" -eq 1 ]
sed 's/^  ! glob_match "\$1" ${CARVE_PATTERNS\[@\]+"${CARVE_PATTERNS\[@\]}"}$/  true/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
for mode in worktree staged; do
  run_mode "$mode"
  must_fail 1 0 "inventory table control: disabled carve-back fails render-carved-back: $mode"
done

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
