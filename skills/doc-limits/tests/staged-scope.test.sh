#!/usr/bin/env bash
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset DOC_LIMITS_CLASSES DOC_LIMITS_DEFAULT_CLASSES DOC_LIMITS_EXCLUDES DOC_LIMITS_SETTINGS_FILE
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_COMMAND="$(cd "$TEST_DIR/../scripts" && pwd)/doc-limits"
SR="$SOURCE_COMMAND"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
R="$TMP/repo"
mkdir -p "$R/tools"
git -C "$R" -c init.defaultBranch=main init -q
git -C "$R" config user.email test@example.com
git -C "$R" config user.name test
printf '[]\n' >"$R/.kendex-generated.json"
git -C "$R" add .kendex-generated.json
PASS=0
FAIL=0
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
  local assertion_rc=0
  (PASS=0; FAIL=0; expect_first_line "$1" "$2"; [ "$FAIL" -eq 0 ]) >"$TMP/control.log" || assertion_rc=$?
  if [ "$assertion_rc" -ne 0 ]; then
    PASS=$((PASS + 1)); printf '  ok: %s\n' "$2"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL: %s: first-line assertion stayed green\n' "$2"
    cat "$TMP/control.log"
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
run() {
  RC=0
  OUT="$(cd "$R" && "$SR" "$@" 2>&1)" || RC=$?
}
bytes() { # PATH COUNT: create a byte-sized text fixture
  mkdir -p "$R/$(dirname "$1")"
  head -c "$2" /dev/zero | tr '\0' x >"$R/$1"
}
private_command() { # NAME: copy the command and set MUTANT
  local root="$TMP/$1"
  mkdir -p "$root/skills/doc-limits"
  cp -R "$TEST_DIR/../scripts" "$root/skills/doc-limits/scripts"
  ln -s "$TEST_DIR/../../commit-guards" "$root/skills/commit-guards"
  MUTANT="$root/skills/doc-limits/scripts/doc-limits"
}

export DOC_LIMITS_CLASSES='*.md=1k'
bytes AGENTS.md 1024
printf '# exclusions\n' >"$R/tools/doc-limits-excludes"
git -C "$R" add -A
git -C "$R" commit -qm fixture

DOCUMENT_ASSERTIONS=0
while IFS='|' read -r name operation mode expected; do
  case "$operation" in
    worktree-grow) bytes AGENTS.md 1025 ;;
    stage-growth) git -C "$R" add AGENTS.md; bytes AGENTS.md 1024 ;;
    unchanged) : ;;
  esac
  case "$mode" in
    worktree) run ;;
    staged) run --staged ;;
  esac
  expect "$expected" "$name"
  DOCUMENT_ASSERTIONS=$((DOCUMENT_ASSERTIONS + 1))
done <<'DOCUMENT_CASES'
document-worktree-growth|worktree-grow|worktree|1
document-unstaged-growth|unchanged|staged|0
document-staged-growth|stage-growth|staged|1
document-worktree-shrink|unchanged|worktree|0
DOCUMENT_CASES
if [ "$DOCUMENT_ASSERTIONS" -eq 0 ]; then
  printf 'FAIL: DOCUMENT_CASES executed no assertions\n' >&2
  exit 1
fi

private_command document-measurement
[ ! -L "$MUTANT" ]
[ "$(grep -Fxc '  if [ "$STAGED" -eq 0 ] && [ -f "$f" ] && [ ! -L "$f" ]; then' "$MUTANT")" -eq 1 ]
sed 's/  if \[ "\$STAGED" -eq 0 \] \&\& \[ -f "\$f" \] \&\& \[ ! -L "\$f" \]; then/  if false \&\& [ "$STAGED" -eq 0 ] \&\& [ -f "$f" ] \&\& [ ! -L "$f" ]; then/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
run
must_fail 0 1 'document table control: disabled worktree measurement fails document-worktree-shrink'
SR="$SOURCE_COMMAND"

EXCLUSION_ASSERTIONS=0
while IFS='|' read -r name operation expected; do
  case "$operation" in
    worktree-only)
      printf 'AGENTS.md\tfixture exception\n' >"$R/tools/doc-limits-excludes"
      ;;
    stage-exclusion) git -C "$R" add tools/doc-limits-excludes ;;
    delete-exclusion)
      git -C "$R" commit -qm 'fixture exclusion'
      git -C "$R" rm -q --cached tools/doc-limits-excludes
      ;;
    delete-document)
      git -C "$R" add tools/doc-limits-excludes
      : >"$R/tools/doc-limits-excludes"
      git -C "$R" add tools/doc-limits-excludes
      bytes AGENTS.md 1025
      git -C "$R" rm -q --cached AGENTS.md
      ;;
  esac
  run --staged
  expect "$expected" "$name"
  EXCLUSION_ASSERTIONS=$((EXCLUSION_ASSERTIONS + 1))
done <<'EXCLUSION_CASES'
exclusion-worktree-only|worktree-only|1
exclusion-staged|stage-exclusion|0
exclusion-deleted-from-index|delete-exclusion|1
document-deleted-from-index|delete-document|0
EXCLUSION_CASES
if [ "$EXCLUSION_ASSERTIONS" -eq 0 ]; then
  printf 'FAIL: EXCLUSION_CASES executed no assertions\n' >&2
  exit 1
fi

git -C "$R" add AGENTS.md tools/doc-limits-excludes
git -C "$R" commit -qm 'control fixture'
printf 'AGENTS.md\tfixture exception\n' >"$R/tools/doc-limits-excludes"
private_command exclusion-source
[ ! -L "$MUTANT" ]
[ "$(grep -Fxc '  git show ":$1" >"$TMP/excludes" 2>/dev/null \' "$MUTANT")" -eq 1 ]
sed 's#  git show ":\$1" >"\$TMP/excludes" 2>/dev/null \\#  cp -- "$1" "$TMP/excludes" 2>/dev/null \\#' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
run --staged
must_fail 1 0 'exclusion table control: worktree policy cannot replace the indexed policy'
SR="$SOURCE_COMMAND"

: >"$R/tools/doc-limits-excludes"
git -C "$R" add tools/doc-limits-excludes
bytes AGENTS.md 1025
git -C "$R" add AGENTS.md
unset DOC_LIMITS_CLASSES

SETTINGS_ASSERTIONS=0
while IFS='|' read -r name operation mode expected first_line; do
  case "$operation" in
    split-settings)
      printf '[env]\nDOC_LIMITS_CLASSES = "*.md=1k"\n' >"$R/kendex.settings.toml"
      git -C "$R" add kendex.settings.toml
      printf '[env]\nDOC_LIMITS_CLASSES = "*.md=2k"\n' >"$R/kendex.settings.toml"
      ;;
    unchanged) : ;;
    stage-relaxed) git -C "$R" add kendex.settings.toml ;;
    delete-settings)
      git -C "$R" commit -qm 'fixture settings'
      git -C "$R" rm -q --cached kendex.settings.toml
      printf '[env]\nDOC_LIMITS_CLASSES = "*.md=1k"\n' >"$R/kendex.settings.toml"
      ;;
    stage-bom)
      rm "$R/kendex.settings.toml"
      mkdir -p "$R/.kendex"
      printf '\357\273\277[env]\nDOC_LIMITS_CLASSES = "*.md=1k"\n' >"$R/.kendex/settings.toml"
      git -C "$R" add .kendex/settings.toml
      ;;
  esac
  case "$mode" in
    worktree) run ;;
    staged) run --staged ;;
  esac
  expect "$expected" "$name"
  [ -z "$first_line" ] || expect_first_line "$first_line" "$name diagnostic"
  SETTINGS_ASSERTIONS=$((SETTINGS_ASSERTIONS + 1))
done <<'SETTINGS_CASES'
settings-staged-strict|split-settings|staged|1
settings-worktree-relaxed|unchanged|worktree|0
settings-relaxed-staged|stage-relaxed|staged|0
settings-deleted-from-index|delete-settings|staged|0
settings-staged-bom|stage-bom|staged|2|doc-limits-error=settings-bom value=.kendex/settings.toml
SETTINGS_CASES
if [ "$SETTINGS_ASSERTIONS" -eq 0 ]; then
  printf 'FAIL: SETTINGS_CASES executed no assertions\n' >&2
  exit 1
fi

private_command staged-settings-label
MUTANT_SETTINGS="$(dirname "$MUTANT")/lib/settings.sh"
[ "$(grep -Fxc '        sr_env_table "$file" "$source" >/dev/null || return 1' "$MUTANT_SETTINGS")" -eq 1 ]
sed 's/^        sr_env_table "\$file" "\$source" >\/dev\/null || return 1$/        sr_env_table "$file" >\/dev\/null || return 1/' "$TEST_DIR/../scripts/lib/settings.sh" >"$MUTANT_SETTINGS.changed"
if cmp -s "$TEST_DIR/../scripts/lib/settings.sh" "$MUTANT_SETTINGS.changed"; then exit 1; fi
mv "$MUTANT_SETTINGS.changed" "$MUTANT_SETTINGS"
bash -n "$MUTANT_SETTINGS"
SR="$MUTANT"
run --staged
must_fail_first_line 'doc-limits-error=settings-bom value=.kendex/settings.toml' 'staged settings label control: the snapshot path fails the BOM row'
SR="$SOURCE_COMMAND"

git -C "$R" rm -qf .kendex/settings.toml
printf '[env]\nDOC_LIMITS_CLASSES = "*.md=1k"\n' >"$R/kendex.settings.toml"
git -C "$R" add kendex.settings.toml
git -C "$R" commit -qm 'strict settings control'
printf '[env]\nDOC_LIMITS_CLASSES = "*.md=2k"\n' >"$R/kendex.settings.toml"
private_command settings-source
MUTANT_SETTINGS="$(dirname "$MUTANT")/lib/settings.sh"
[ ! -L "$MUTANT_SETTINGS" ]
[ "$(grep -Fxc '  if [ "${SR_SETTINGS_FROM_INDEX:-0}" != "1" ] || [ -z "${SR_SETTINGS_INDEX_DIR:-}" ]; then' "$MUTANT_SETTINGS")" -eq 1 ]
sed 's/  if \[ "${SR_SETTINGS_FROM_INDEX:-0}" != "1" \] || \[ -z "${SR_SETTINGS_INDEX_DIR:-}" \]; then/  if true || [ "${SR_SETTINGS_FROM_INDEX:-0}" != "1" ] || [ -z "${SR_SETTINGS_INDEX_DIR:-}" ]; then/' "$TEST_DIR/../scripts/lib/settings.sh" >"$MUTANT_SETTINGS.changed"
if cmp -s "$TEST_DIR/../scripts/lib/settings.sh" "$MUTANT_SETTINGS.changed"; then exit 1; fi
mv "$MUTANT_SETTINGS.changed" "$MUTANT_SETTINGS"
bash -n "$MUTANT_SETTINGS"
SR="$MUTANT"
run --staged
must_fail 1 0 'settings table control: worktree settings cannot replace indexed settings'

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
