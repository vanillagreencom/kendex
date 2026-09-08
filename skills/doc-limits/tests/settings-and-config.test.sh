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
clear_settings_sources() {
  local path="$R/.kendex/settings.toml"
  if [ -L "$path" ] || [ -f "$path" ]; then
    rm "$path"
  elif [ -d "$path" ]; then
    rmdir "$path"
  fi
  rm -f "$R/kendex.settings.toml" "$R/.env.local"
}

bytes AGENTS.md 2049
git -C "$R" add AGENTS.md

PRECEDENCE_ASSERTIONS=0
while IFS='|' read -r name operation expected; do
  case "$operation" in
    plain-env)
      printf 'DOC_LIMITS_CLASSES=*.md=1k\n' >"$R/.env"
      ;;
    project-setting)
      printf '[env]\nDOC_LIMITS_CLASSES = "*.md=1k"\n' >"$R/kendex.settings.toml"
      ;;
    local-over-project)
      mkdir -p "$R/.kendex"
      printf '[env]\nDOC_LIMITS_CLASSES = "*.md=3k"\n' >"$R/.kendex/settings.toml"
      ;;
    dotenv-local-over-local)
      printf 'DOC_LIMITS_CLASSES="*.md=2k" # local\n' >"$R/.env.local"
      ;;
    environment-over-files) export DOC_LIMITS_CLASSES='*.md=3k' ;;
    environment-explicit-empty) export DOC_LIMITS_CLASSES='' ;;
    settings-disabled)
      unset DOC_LIMITS_CLASSES
      printf '[env]\nDOC_LIMITS_CLASSES = "*.md=1k"\n' >"$R/.kendex/settings.toml"
      printf 'DOC_LIMITS_CLASSES="*.md=1k" # local\n' >"$R/.env.local"
      export DOC_LIMITS_SETTINGS_FILE=/dev/null
      ;;
    environment-with-settings-disabled) export DOC_LIMITS_CLASSES='*.md=1k' ;;
  esac
  run
  expect "$expected" "$name"
  PRECEDENCE_ASSERTIONS=$((PRECEDENCE_ASSERTIONS + 1))
done <<'PRECEDENCE_CASES'
plain-env-ignored|plain-env|0
project-setting|project-setting|1
local-over-project|local-over-project|0
dotenv-local-over-local|dotenv-local-over-local|1
environment-over-files|environment-over-files|0
environment-explicit-empty|environment-explicit-empty|0
settings-disabled|settings-disabled|0
environment-with-settings-disabled|environment-with-settings-disabled|1
PRECEDENCE_CASES
if [ "$PRECEDENCE_ASSERTIONS" -eq 0 ]; then
  printf 'FAIL: PRECEDENCE_CASES executed no assertions\n' >&2
  exit 1
fi

unset DOC_LIMITS_SETTINGS_FILE DOC_LIMITS_CLASSES
printf '[env]\nDOC_LIMITS_CLASSES = "*.md=1k"\n' >"$R/kendex.settings.toml"
printf '[env]\nDOC_LIMITS_CLASSES = "*.md=3k"\n' >"$R/.kendex/settings.toml"
printf 'DOC_LIMITS_CLASSES="*.md=2k" # local\n' >"$R/.env.local"
private_command precedence
MUTANT_SETTINGS="$(dirname "$MUTANT")/lib/settings.sh"
[ ! -L "$MUTANT_SETTINGS" ]
[ "$(grep -Fxc '  if [ -f "$local_env" ]; then' "$MUTANT_SETTINGS")" -eq 1 ]
sed 's/  if \[ -f "\$local_env" \]; then/  if false \&\& [ -f "$local_env" ]; then/' "$TEST_DIR/../scripts/lib/settings.sh" >"$MUTANT_SETTINGS.changed"
if cmp -s "$TEST_DIR/../scripts/lib/settings.sh" "$MUTANT_SETTINGS.changed"; then exit 1; fi
mv "$MUTANT_SETTINGS.changed" "$MUTANT_SETTINGS"
bash -n "$MUTANT_SETTINGS"
SR="$MUTANT"
run
must_fail 1 0 'precedence table control: disabling .env.local fails dotenv-local-over-local'
SR="$SOURCE_COMMAND"

private_command diagnostics-load
MUTANT_DIAGNOSTICS="$(dirname "$MUTANT")/lib/diagnostics.sh"
[ "$(grep -Fxc 'source "$SCRIPT_DIR/lib/settings.sh" || exit 2' "$MUTANT")" -eq 1 ]
rm "$MUTANT_DIAGNOSTICS"
SR="$MUTANT"
run
expect 2 'diagnostics-load-failure'
expect_first_line "doc-limits-error=diagnostics-load value=$(printf '%q' "$MUTANT_DIAGNOSTICS")" 'diagnostics-load failure'
MUTANT_SETTINGS="$(dirname "$MUTANT")/lib/settings.sh"
[ "$(grep -Fxc "  printf 'doc-limits-error=diagnostics-load value=%q\\n%s\\n' \"\$sr_settings_script_dir/diagnostics.sh\" 'Could not load the diagnostics library.' >&2" "$MUTANT_SETTINGS")" -eq 1 ]
sed 's/doc-limits-error=diagnostics-load/doc-limits-error=diagnostics-renamed/' "$MUTANT_SETTINGS" >"$MUTANT_SETTINGS.changed"
if cmp -s "$MUTANT_SETTINGS" "$MUTANT_SETTINGS.changed"; then exit 1; fi
mv "$MUTANT_SETTINGS.changed" "$MUTANT_SETTINGS"
bash -n "$MUTANT_SETTINGS"
run
must_fail_first_line "doc-limits-error=diagnostics-load value=$(printf '%q' "$MUTANT_DIAGNOSTICS")" 'diagnostics-load control: changing the stable key fails the refusal'
sed 's#^source "\$SCRIPT_DIR/lib/settings.sh" || exit 2$#source "$SCRIPT_DIR/lib/settings.sh" || exit 1#' "$MUTANT" >"$MUTANT.changed"
if cmp -s "$MUTANT" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
run
must_fail 2 1 'diagnostics-load control: wrong loader exit fails the refusal'
SR="$SOURCE_COMMAND"

while IFS='|' read -r value key relevant; do
  export DOC_LIMITS_CLASSES="$value"
  run
  expect 2 "invalid-class: $value"
  expect_first_line "error=$key value=$(printf '%q' "$relevant")" "invalid-class diagnostic: $value"
done <<'INVALID_CLASS_CASES'
*.md=0k|class-threshold-invalid|0k
*.md=400|class-threshold-invalid|400
*.md=invalid|class-threshold-invalid|invalid
*.md|class-entry-invalid|*.md
=1k|class-pattern-empty|=1k
INVALID_CLASS_CASES

private_command invalid-classes
[ ! -L "$MUTANT" ]
[ "$(grep -Fxc 'parse_classes() { # SETTING-NAME VALUE — appends entries' "$MUTANT")" -eq 1 ]
sed 's/parse_classes() { # SETTING-NAME VALUE — appends entries/parse_classes() { # SETTING-NAME VALUE — appends entries\n  return 0/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
for value in '*.md=0k' '*.md=400' '*.md=invalid' '*.md' '=1k'; do
  export DOC_LIMITS_CLASSES="$value"
  run
  must_fail 2 0 "invalid-class table control: $value"
done
SR="$SOURCE_COMMAND"

private_command class-diagnostic
[ "$(grep -Fxc '      *) config_error class-threshold-invalid value "$craw" "$name: entry '\''$pair'\'' needs a positive integer with the '\''k'\'' byte suffix" ;;' "$MUTANT")" -eq 1 ]
sed 's/config_error class-threshold-invalid value "$craw"/config_error class-threshold-renamed value "$craw"/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
export DOC_LIMITS_CLASSES='*.md=400'
run
must_fail_first_line 'error=class-threshold-invalid value=400' 'class diagnostic control: changing the stable key fails the suffix row'
SR="$SOURCE_COMMAND"

CLASS_ORDER_ASSERTIONS=0
while IFS='|' read -r name value expected; do
  export DOC_LIMITS_CLASSES="$value"
  run
  expect "$expected" "$name"
  CLASS_ORDER_ASSERTIONS=$((CLASS_ORDER_ASSERTIONS + 1))
done <<'CLASS_ORDER_CASES'
specific-class-first|AGENTS.md=3k;*.md=1k|0
wildcard-class-first|*.md=1k;AGENTS.md=3k|1
CLASS_ORDER_CASES
if [ "$CLASS_ORDER_ASSERTIONS" -eq 0 ]; then
  printf 'FAIL: CLASS_ORDER_CASES executed no assertions\n' >&2
  exit 1
fi

private_command class-order
[ ! -L "$MUTANT" ]
[ "$(grep -Fxc 'path_threshold() { # PATH: first matching class, or no limit' "$MUTANT")" -eq 1 ]
[ "$(grep -Fxc '  local i=0' "$MUTANT")" -eq 1 ]
sed 's/^  local i=0$/  local i=1/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
CLASS_ORDER_CONTROL_ASSERTIONS=0
while IFS='|' read -r name value expected mutant_exit; do
  export DOC_LIMITS_CLASSES="$value"
  run
  must_fail "$expected" "$mutant_exit" "class-order table control: $name"
  CLASS_ORDER_CONTROL_ASSERTIONS=$((CLASS_ORDER_CONTROL_ASSERTIONS + 1))
done <<'CLASS_ORDER_CONTROLS'
specific-class-first|AGENTS.md=3k;*.md=1k|0|1
wildcard-class-first|*.md=1k;AGENTS.md=3k|1|0
CLASS_ORDER_CONTROLS
if [ "$CLASS_ORDER_CONTROL_ASSERTIONS" -eq 0 ]; then
  printf 'FAIL: CLASS_ORDER_CONTROLS executed no assertions\n' >&2
  exit 1
fi
SR="$SOURCE_COMMAND"

unset DOC_LIMITS_CLASSES
printf '[env]\nDUP = "a"\nDUP = "b"\n' >"$R/kendex.settings.toml"
run
expect 2 'duplicate-settings-key'
expect_first_line 'doc-limits-error=settings-duplicate value=DUP' 'duplicate-settings-key diagnostic'
private_command settings-diagnostic
MUTANT_SETTINGS="$(dirname "$MUTANT")/lib/settings.sh"
[ "$(grep -Fxc '        printf "doc-limits-error=settings-duplicate value=%s\n::error::%s: %s is assigned more than once in [env] (each key must be unique in the table)\n", key, src, key > "/dev/stderr"' "$MUTANT_SETTINGS")" -eq 1 ]
sed 's/doc-limits-error=settings-duplicate value=%s/doc-limits-error=settings-renamed value=%s/' "$MUTANT_SETTINGS" >"$MUTANT_SETTINGS.changed"
if cmp -s "$MUTANT_SETTINGS" "$MUTANT_SETTINGS.changed"; then exit 1; fi
mv "$MUTANT_SETTINGS.changed" "$MUTANT_SETTINGS"
bash -n "$MUTANT_SETTINGS"
SR="$MUTANT"
run
must_fail_first_line 'doc-limits-error=settings-duplicate value=DUP' 'settings diagnostic control: changing the stable key fails the duplicate assertion'
SR="$SOURCE_COMMAND"
clear_settings_sources

SETTINGS_ERROR_ASSERTIONS=0
while IFS='|' read -r name operation first_line; do
  clear_settings_sources
  case "$operation" in
    dangling) ln -s missing "$R/.kendex/settings.toml" ;;
    directory) mkdir "$R/.kendex/settings.toml" ;;
    bom) printf '\357\273\277[env]\nDOC_LIMITS_CLASSES = "*.md=1k"\n' >"$R/.kendex/settings.toml" ;;
    header) printf '[env] # invalid\n' >"$R/.kendex/settings.toml" ;;
    syntax) printf '[env]\nDOC_LIMITS_CLASSES = 1\n' >"$R/.kendex/settings.toml" ;;
    dotenv) printf 'DOC_LIMITS_CLASSES="*.md=1k"tail\n' >"$R/.env.local" ;;
  esac
  run
  expect 2 "$name"
  expect_first_line "$first_line" "$name diagnostic"
  SETTINGS_ERROR_ASSERTIONS=$((SETTINGS_ERROR_ASSERTIONS + 1))
done <<'SETTINGS_ERROR_CASES'
settings-dangling-symlink|dangling|doc-limits-error=settings-symlink value=.kendex/settings.toml
settings-directory|directory|doc-limits-error=settings-type value=.kendex/settings.toml
settings-bom|bom|doc-limits-error=settings-bom value=.kendex/settings.toml
settings-header|header|doc-limits-error=settings-header value=1
settings-syntax|syntax|doc-limits-error=settings-syntax value=DOC_LIMITS_CLASSES
settings-dotenv|dotenv|doc-limits-error=settings-dotenv value=DOC_LIMITS_CLASSES
SETTINGS_ERROR_CASES
if [ "$SETTINGS_ERROR_ASSERTIONS" -eq 0 ]; then
  printf 'FAIL: SETTINGS_ERROR_CASES executed no assertions\n' >&2
  exit 1
fi

clear_settings_sources
ln -s missing "$R/.kendex/settings.toml"
private_command settings-message
MUTANT_DIAGNOSTICS="$(dirname "$MUTANT")/lib/diagnostics.sh"
[ "$(grep -Fxc "  printf 'doc-limits-%s=%s value=%q\\n%s\\n' \"\$1\" \"\$2\" \"\$3\" \"\$4\"" "$MUTANT_DIAGNOSTICS")" -eq 1 ]
sed 's/doc-limits-%s=%s/renamed-%s=%s/' "$MUTANT_DIAGNOSTICS" >"$MUTANT_DIAGNOSTICS.changed"
if cmp -s "$MUTANT_DIAGNOSTICS" "$MUTANT_DIAGNOSTICS.changed"; then exit 1; fi
mv "$MUTANT_DIAGNOSTICS.changed" "$MUTANT_DIAGNOSTICS"
bash -n "$MUTANT_DIAGNOSTICS"
SR="$MUTANT"
run
must_fail_first_line 'doc-limits-error=settings-symlink value=.kendex/settings.toml' 'settings formatter control: changing the stable prefix fails the symlink row'

clear_settings_sources
printf '[env] # invalid\n' >"$R/.kendex/settings.toml"
private_command settings-awk-message
MUTANT_SETTINGS="$(dirname "$MUTANT")/lib/settings.sh"
[ "$(grep -Fxc '      printf "doc-limits-error=settings-header value=%d\n::error::%s:%d: unsupported table header shape (a header is a lone [name] on its own line, with no comment and no second bracket)\n", NR, src, NR > "/dev/stderr"' "$MUTANT_SETTINGS")" -eq 1 ]
sed 's/doc-limits-error=settings-header value=%d/doc-limits-error=settings-header-renamed value=%d/' "$MUTANT_SETTINGS" >"$MUTANT_SETTINGS.changed"
if cmp -s "$MUTANT_SETTINGS" "$MUTANT_SETTINGS.changed"; then exit 1; fi
mv "$MUTANT_SETTINGS.changed" "$MUTANT_SETTINGS"
bash -n "$MUTANT_SETTINGS"
SR="$MUTANT"
run
must_fail_first_line 'doc-limits-error=settings-header value=1' 'settings parser control: changing the stable key fails the header row'
SR="$SOURCE_COMMAND"
clear_settings_sources

printf '*.md\tfixture exception\n!AGENTS.md\tkeep root instructions checked\n' >"$R/tools/doc-limits-excludes"
export DOC_LIMITS_CLASSES='*.md=1k'
run
expect 1 'exclusion-carve-back'

private_command carve-back
[ ! -L "$MUTANT" ]
[ "$(grep -Fxc '  ! glob_match "$1" ${CARVE_PATTERNS[@]+"${CARVE_PATTERNS[@]}"}' "$MUTANT")" -eq 1 ]
sed 's/^  ! glob_match "\$1" ${CARVE_PATTERNS\[@\]+"${CARVE_PATTERNS\[@\]}"}$/  true/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
run
must_fail 1 0 'carve-back control: disabling carve-back fails exclusion-carve-back'
SR="$SOURCE_COMMAND"

run --excludes
expect 2 'missing-excludes-value'
expect_first_line 'error=argument-value-missing option=--excludes' 'missing-excludes-value diagnostic'

private_command excludes-diagnostic
[ "$(grep -Fxc '      [ $# -ge 2 ] || config_error argument-value-missing option --excludes "--excludes requires a path"' "$MUTANT")" -eq 1 ]
sed 's/config_error argument-value-missing option --excludes/config_error argument-value-renamed option --excludes/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
run --excludes
must_fail_first_line 'error=argument-value-missing option=--excludes' 'diagnostic control: changing the stable key fails the missing-value assertion'
SR="$SOURCE_COMMAND"

EXCLUDES_PATH_ASSERTIONS=0
while IFS='|' read -r name argument key relevant; do
  run "$argument"
  expect 2 "$name"
  expect_first_line "error=$key path=$(printf '%q' "$relevant")" "$name diagnostic"
  EXCLUDES_PATH_ASSERTIONS=$((EXCLUDES_PATH_ASSERTIONS + 1))
done <<'EXCLUDES_PATH_CASES'
excludes-empty|--excludes=|excludes-path-empty|
excludes-absolute|--excludes=/outside|excludes-path-absolute|/outside
excludes-parent|--excludes=../outside|excludes-path-invalid|../outside
excludes-option|--excludes=-outside|excludes-path-option|-outside
EXCLUDES_PATH_CASES
if [ "$EXCLUDES_PATH_ASSERTIONS" -eq 0 ]; then
  printf 'FAIL: EXCLUDES_PATH_CASES executed no assertions\n' >&2
  exit 1
fi

private_command excludes-path-diagnostic
[ "$(grep -Fxc 'case "$EXCLUDES_FILE" in /*) config_error excludes-path-absolute path "$EXCLUDES_FILE" "excludes path must be repo-root-relative, got absolute: $EXCLUDES_FILE" ;; esac' "$MUTANT")" -eq 1 ]
sed 's/config_error excludes-path-absolute path/config_error excludes-path-absolute-renamed path/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
run --excludes=/outside
must_fail_first_line 'error=excludes-path-absolute path=/outside' 'excludes-path control: changing the stable key fails the absolute row'
SR="$SOURCE_COMMAND"

run --unknown
expect 2 'unknown-option'
expect_first_line 'error=argument-unknown argument=--unknown' 'unknown-option diagnostic'

REPO_FIXTURE="$R"
R="$TMP/outside-repository"
mkdir "$R"
run
expect 2 'outside-repository'
expect_first_line "error=repository-root-missing path=$(printf '%q' "$R")" 'outside-repository diagnostic precedes Git stderr'
R="$REPO_FIXTURE"

# Git is the real producer of policy lookup, document enumeration, and blob sizes.
REAL_GIT="$(command -v git)"
export REAL_GIT
mkdir -p "$TMP/bin"
cat >"$TMP/bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
case "${GIT_FAULT:-none}" in
  policy-lookup)
    if [ "${1:-}" = ls-files ] && [ "${2:-}" = --error-unmatch ]; then exit 9; fi
    ;;
  enumeration)
    if [ "$#" -eq 3 ] && [ "${1:-}" = ls-files ] && [ "${2:-}" = -s ] && [ "${3:-}" = -z ]; then exit 9; fi
    ;;
  batch-empty-failure)
    if [ "${1:-}" = cat-file ] && [ "${2:-}" = --batch-check ]; then cat >/dev/null; exit 9; fi
    ;;
  batch-complete-failure)
    if [ "${1:-}" = cat-file ] && [ "${2:-}" = --batch-check ]; then "$REAL_GIT" "$@"; exit 9; fi
    ;;
  batch-empty-success)
    if [ "${1:-}" = cat-file ] && [ "${2:-}" = --batch-check ]; then cat >/dev/null; exit 0; fi
    ;;
esac
exec "$REAL_GIT" "$@"
GIT
chmod +x "$TMP/bin/git"
export PATH="$TMP/bin:$PATH"

COLLECTION_ASSERTIONS=0
while IFS='|' read -r name fault expected first_line; do
  export GIT_FAULT="$fault"
  run --staged
  expect "$expected" "$name"
  expect_first_line "$first_line" "$name diagnostic"
  COLLECTION_ASSERTIONS=$((COLLECTION_ASSERTIONS + 1))
done <<'COLLECTION_CASES'
git-policy-lookup-failure|policy-lookup|2|doc-limits-error=settings-index-query value=9
git-enumeration-failure|enumeration|2|error=documents-enumeration-failed exit=9
git-batch-empty-failure|batch-empty-failure|2|error=blob-sizes-read-failed exit=9
git-batch-failure|batch-complete-failure|2|error=blob-sizes-read-failed exit=9
empty-successful-batch-response|batch-empty-success|2|error=blob-size-response-incomplete path=AGENTS.md
collection-restored|none|1|notice=document-over-limit path=AGENTS.md
COLLECTION_CASES
if [ "$COLLECTION_ASSERTIONS" -eq 0 ]; then
  printf 'FAIL: COLLECTION_CASES executed no assertions\n' >&2
  exit 1
fi

private_command collection-diagnostic
[ "$(grep -Fxc 'git ls-files -s -z >"$TMP/files.z" 2>/dev/null || collection_error documents-enumeration-failed exit "$?" "could not enumerate tracked documents"' "$MUTANT")" -eq 1 ]
sed 's/collection_error documents-enumeration-failed exit/collection_error documents-enumeration-renamed exit/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
export GIT_FAULT=enumeration
run --staged
must_fail_first_line 'error=documents-enumeration-failed exit=9' 'collection diagnostic control: changing the stable key fails enumeration'
SR="$SOURCE_COMMAND"

private_command enumeration-guard
[ ! -L "$MUTANT" ]
[ "$(grep -Fxc 'git ls-files -s -z >"$TMP/files.z" 2>/dev/null || collection_error documents-enumeration-failed exit "$?" "could not enumerate tracked documents"' "$MUTANT")" -eq 1 ]
sed 's/^git ls-files -s -z >"\$TMP\/files.z" 2>\/dev\/null || collection_error documents-enumeration-failed exit "\$?" "could not enumerate tracked documents"$/git ls-files -s -z >"$TMP\/files.z" 2>\/dev\/null || :/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
export GIT_FAULT=enumeration
run --staged
must_fail 2 0 'collection table control: bypassing enumeration failure fails git-enumeration-failure'

private_command batch-guard
[ ! -L "$MUTANT" ]
[ "$(grep -Fxc '  || collection_error blob-sizes-read-failed exit "$?" "could not read document blob sizes"' "$MUTANT")" -eq 1 ]
sed 's/^  || collection_error blob-sizes-read-failed exit "\$?" "could not read document blob sizes"$/  || :/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
export GIT_FAULT=batch-complete-failure
run --staged
must_fail 2 1 'collection table control: bypassing batch status fails git-batch-failure'

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
