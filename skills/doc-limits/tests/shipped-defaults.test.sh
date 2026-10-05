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
expect_line() { # EXPECTED LABEL: one whole output line equals EXPECTED
  case "
$OUT
" in
    *"
$1
"*) PASS=$((PASS + 1)); printf '  ok: %s\n' "$2" ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL: %s: no line <%s>\n%s\n' "$2" "$1" "$OUT" ;;
  esac
}
must_fail_line() { # FORMER-LINE LABEL
  local assertion_rc=0
  (PASS=0; FAIL=0; expect_line "$1" "$2"; [ "$FAIL" -eq 0 ]) >"$TMP/control.log" || assertion_rc=$?
  if [ "$assertion_rc" -ne 0 ]; then
    PASS=$((PASS + 1)); printf '  ok: %s\n' "$2"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL: %s: line assertion stayed green\n' "$2"
    cat "$TMP/control.log"
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

# Representative paths exercise each shipped document class at both edges: at
# its limit the document passes, one byte over it fails the check.
CLASS_ASSERTIONS=0
while IFS=' ' read -r path limit; do
  bytes "$path" "$limit"
  git -C "$R" add -- "$path"
  run --staged
  expect 0 "$path at its class limit passes"
  expect_first_line 'notice=documents-checked count=1' "$path pass notice"
  bytes "$path" "$((limit + 1))"
  git -C "$R" add -- "$path"
  run --staged
  expect 1 "$path one byte over fails"
  expect_first_line "notice=document-over-limit path=$path" "$path over-limit notice"
  expect_line 'notice=documents-over-limit count=1' "$path failure count"
  git -C "$R" rm -qf -- "$path"
  CLASS_ASSERTIONS=$((CLASS_ASSERTIONS + 1))
done <<'CLASSES'
AGENTS.md 8192
CLAUDE.md 24576
GEMINI.md 24576
SKILL.md 24576
pkg/AGENTS.md 6144
pkg/CLAUDE.md 24576
pkg/GEMINI.md 24576
skills/demo/SKILL.md 24576
CLASSES
if [ "$CLASS_ASSERTIONS" -eq 0 ]; then
  printf 'FAIL: CLASSES executed no assertions\n' >&2
  exit 1
fi

# A tracked file outside the four load-point basenames is never measured,
# whatever its size and whatever class names it: the class here names every
# path. The control removes the basename gate from a private copy, which
# fails the first of these files.
export DOC_LIMITS_CLASSES='*=1k'
OUTSIDE_ASSERTIONS=0
while IFS= read -r path; do
  bytes "$path" 100000
  git -C "$R" add -- "$path"
  run --staged
  expect 0 "$path is outside the load points"
  expect_first_line 'notice=documents-checked count=0' "$path measures nothing"
  git -C "$R" rm -qf -- "$path"
  OUTSIDE_ASSERTIONS=$((OUTSIDE_ASSERTIONS + 1))
done <<'OUTSIDE'
README.md
pkg/README.md
docs/architecture/overview.md
docs/architecture/topic.md
skills/demo/workflows/task.md
skills/demo/references/contract.md
CHANGELOG.md
agents/big.md
src/large.rs
site/index.html
docs/references/example.html
OUTSIDE
if [ "$OUTSIDE_ASSERTIONS" -eq 0 ]; then
  printf 'FAIL: OUTSIDE executed no assertions\n' >&2
  exit 1
fi
bytes README.md 100000
git -C "$R" add README.md
private_command load-point-gate
[ ! -L "$MUTANT" ]
[ "$(grep -Fxc '  is_load_point "$f" || continue' "$MUTANT")" -eq 1 ]
sed 's/^  is_load_point "\$f" || continue$/  :/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
run --staged
must_fail 0 1 'load-point gate control: measuring every tracked file fails the README.md row'
SR="$SOURCE_COMMAND"
git -C "$R" rm -qf README.md
unset DOC_LIMITS_CLASSES

# A caller still passing the retired --against keeps its verdict, warned.
bytes AGENTS.md 8192
git -C "$R" add AGENTS.md
run --staged --against HEAD
expect 0 'retired --against still runs'
expect_first_line 'notice=argument-retired argument=--against' 'retired --against notice'
private_command retired-against
[ "$(grep -Fxc '[ "$AGAINST_RETIRED" = 0 ] \' "$MUTANT")" -eq 1 ]
sed 's/^\[ "\$AGAINST_RETIRED" = 0 \] \\$/true \\/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
run --staged --against HEAD
must_fail_first_line 'notice=argument-retired argument=--against' 'retired --against control: a silent flag fails the notice row'
SR="$SOURCE_COMMAND"
git -C "$R" rm -qf AGENTS.md

# A project class sets the ceiling of a load-point document and of nothing
# else: the same class over the same bytes passes agents/big.md unmeasured and
# fails agents/AGENTS.md.
export DOC_LIMITS_CLASSES='agents/*.md=1k'
bytes agents/big.md 1025
git -C "$R" add agents/big.md
run --staged
expect 0 'a project class over a file outside the load points measures nothing'
expect_first_line 'notice=documents-checked count=0' 'project class outside the load points notice'
git -C "$R" rm -qf agents/big.md
bytes agents/AGENTS.md 1025
git -C "$R" add agents/AGENTS.md
run --staged
expect 1 'control: the same project class fails a load-point document over its limit'
expect_first_line 'notice=document-over-limit path=agents/AGENTS.md' 'project class over-limit notice'
unset DOC_LIMITS_CLASSES
git -C "$R" rm -qf agents/AGENTS.md

bytes AGENTS.md 8192
git -C "$R" add AGENTS.md
private_command notice-protocol
[ "$(grep -Fxc "  printf 'notice=%s %s=%q\\n' \"\$key\" \"\$field\" \"\$value\"" "$MUTANT")" -eq 1 ]
sed "s/printf 'notice=%s %s=%q\\\\n'/printf 'renamed=%s %s=%q\\\\n'/" "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
run --staged
must_fail_first_line 'notice=documents-checked count=1' 'notice protocol control: changing the formatter fails the pass notice'
SR="$SOURCE_COMMAND"
git -C "$R" rm -qf AGENTS.md

DOCUMENT_PATH="bad$(printf '\t')dir/AGENTS.md"
bytes "$DOCUMENT_PATH" 1
git -C "$R" add -- "$DOCUMENT_PATH"
run --staged
expect 2 'document-path-tab'
expect_first_line "error=document-path-invalid path=$(printf '%q' "$DOCUMENT_PATH")" 'document-path-tab diagnostic'
git -C "$R" rm -qf -- "$DOCUMENT_PATH"

mkdir -p "$R/pkg"
printf 'conflict\n' >"$R/pkg/AGENTS.md"
git -C "$R" add pkg/AGENTS.md
CONFLICT_OID="$(git -C "$R" hash-object pkg/AGENTS.md)"
git -C "$R" rm -q --cached pkg/AGENTS.md
printf '100644 %s 1\tpkg/AGENTS.md\n100644 %s 2\tpkg/AGENTS.md\n100644 %s 3\tpkg/AGENTS.md\n' "$CONFLICT_OID" "$CONFLICT_OID" "$CONFLICT_OID" | git -C "$R" update-index --index-info
run --staged
expect 2 'document-unmerged'
expect_first_line 'error=document-unmerged path=pkg/AGENTS.md' 'document-unmerged diagnostic'
private_command document-diagnostic
[ "$(grep -Fxc '  [ "${entry##* }" = 0 ] || config_error document-unmerged path "$f" "tracked document is unmerged: $f"' "$MUTANT")" -eq 1 ]
sed 's/config_error document-unmerged path/config_error document-unmerged-renamed path/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
run --staged
must_fail_first_line 'error=document-unmerged path=pkg/AGENTS.md' 'document diagnostic control: changing the stable key fails the unmerged row'
SR="$SOURCE_COMMAND"
git -C "$R" update-index --force-remove pkg/AGENTS.md
rm -- "${R:?}/pkg/AGENTS.md"

bytes AGENTS.md 8193
git -C "$R" add AGENTS.md
EXCLUSION_ASSERTIONS=0
while IFS='|' read -r name operation expected first_line; do
  rm -f "$R/tools/doc-limits-excludes"
  case "$operation" in
    reasoned) printf 'AGENTS.md\tdeliberate fixture exception\n' >"$R/tools/doc-limits-excludes" ;;
    missing-reason) printf 'AGENTS.md\n' >"$R/tools/doc-limits-excludes" ;;
    removed) : >"$R/tools/doc-limits-excludes" ;;
    empty-carve) printf '!\tmissing pattern\n' >"$R/tools/doc-limits-excludes" ;;
    symlink)
      ln -s ../AGENTS.md "$R/tools/doc-limits-excludes"
      ;;
  esac
  git -C "$R" add tools/doc-limits-excludes
  run --staged
  expect "$expected" "$name"
  expect_first_line "$first_line" "$name diagnostic"
  EXCLUSION_ASSERTIONS=$((EXCLUSION_ASSERTIONS + 1))
done <<'EXCLUSION_CASES'
reasoned-exclusion|reasoned|0|notice=documents-checked count=0
exclusion-missing-reason|missing-reason|2|error=excludes-row-invalid line=1
exclusion-removed|removed|1|notice=document-over-limit path=AGENTS.md
exclusion-empty-carve|empty-carve|2|error=excludes-carve-empty line=1
exclusion-symlink|symlink|2|error=excludes-mode-invalid mode=120000
EXCLUSION_CASES
if [ "$EXCLUSION_ASSERTIONS" -eq 0 ]; then
  printf 'FAIL: EXCLUSION_CASES executed no assertions\n' >&2
  exit 1
fi

rm -f "$R/tools/doc-limits-excludes"
printf 'AGENTS.md\n' >"$R/tools/doc-limits-excludes"
git -C "$R" add tools/doc-limits-excludes
private_command exclusion-diagnostic
[ "$(grep -Fxc '      config_error excludes-row-invalid line "$lineno" "$EXCLUDES_LABEL:$lineno: expected '\''pattern<TAB>reason'\'' (every exclusion carries its justification)"' "$MUTANT")" -eq 1 ]
sed 's/config_error excludes-row-invalid line/config_error excludes-row-renamed line/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
run --staged
must_fail_first_line 'error=excludes-row-invalid line=1' 'exclusion diagnostic control: changing the stable key fails the malformed row'
SR="$SOURCE_COMMAND"

printf 'AGENTS.md\tdeliberate fixture exception\n' >"$R/tools/doc-limits-excludes"
git -C "$R" add tools/doc-limits-excludes
private_command exclusions
[ ! -L "$MUTANT" ]
[ "$(grep -Fxc 'is_excluded() { # PATH — inclusion rows override both exclusion sources' "$MUTANT")" -eq 1 ]
sed 's/^is_excluded() { # PATH — inclusion rows override both exclusion sources$/is_excluded() { # PATH — inclusion rows override both exclusion sources\n  return 1/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
run --staged
must_fail 0 1 'exclusion table control: bypassing exclusions fails reasoned-exclusion'
SR="$SOURCE_COMMAND"

: >"$R/tools/doc-limits-excludes"
git -C "$R" add tools/doc-limits-excludes
private_command comparison
[ ! -L "$MUTANT" ]
[ "$(grep -Fxc '  if [ "$n" -gt "$limit" ]; then' "$MUTANT")" -eq 1 ]
sed 's/if \[ "\$n" -gt "\$limit" \]; then/if false \&\& [ "$n" -gt "$limit" ]; then/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
run --staged
must_fail 1 0 'class table control: disabling comparison fails the over-limit row'
SR="$SOURCE_COMMAND"

# A malformed shipped class entry is a package defect; the same entry set
# by the project is the project's policy error. AGENTS.md stays one byte over
# its class limit, so a run past the table exits 1.
SHIPPED_HEAD="SHIPPED_CLASSES='AGENTS.md=8k;"
private_command shipped-entry
[ "$(grep -Fc "$SHIPPED_HEAD" "$MUTANT")" -eq 1 ]
sed "s|^$SHIPPED_HEAD|SHIPPED_CLASSES='AGENTS.md=8;|" "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
cp "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
run --staged
expect 2 'shipped-entry-invalid'
expect_first_line 'package-error=class-threshold-invalid value=8' 'a malformed shipped entry is a package defect'
SR="$SOURCE_COMMAND"
export DOC_LIMITS_DEFAULT_CLASSES='AGENTS.md=8'
run --staged
expect 2 'project-default-entry-invalid'
expect_first_line 'error=class-threshold-invalid value=8' 'the same entry set by the project is a policy error'
unset DOC_LIMITS_DEFAULT_CLASSES
[ "$(grep -Fxc '[ "$DEFAULT_CLASSES" != "$SHIPPED_CLASSES" ] || default_refusal=package_error' "$MUTANT")" -eq 1 ]
sed 's/^\[ "\$DEFAULT_CLASSES" != "\$SHIPPED_CLASSES" \] || default_refusal=package_error$/:/' "$MUTANT.changed" >"$MUTANT"
if cmp -s "$MUTANT" "$MUTANT.changed"; then exit 1; fi
bash -n "$MUTANT"
SR="$MUTANT"
run --staged
must_fail_first_line 'package-error=class-threshold-invalid value=8' 'refusal-owner control: a shipped entry refused as policy fails the package-defect row'
SR="$SOURCE_COMMAND"

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
