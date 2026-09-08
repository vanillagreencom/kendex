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

# Representative paths exercise each shipped document class at both edges.
while IFS=' ' read -r path limit; do
  bytes "$path" "$limit"
  git -C "$R" add -- "$path"
  run --staged
  expect 0 "$path at its class limit passes"
  bytes "$path" "$((limit + 1))"
  git -C "$R" add -- "$path"
  run --staged
  expect 1 "$path one byte over fails"
  case "$OUT" in
    *"$path: $((limit + 1)) bytes > $limit bytes"*) ;;
    *) FAIL=$((FAIL + 1)); printf '  FAIL: wrong document or limit: %s\n' "$OUT" ;;
  esac
  git -C "$R" rm -qf -- "$path"
done <<'CLASSES'
AGENTS.md 16384
CLAUDE.md 24576
pkg/AGENTS.md 6144
pkg/CLAUDE.md 24576
docs/architecture/overview.md 12288
docs/architecture/topic.md 16384
skills/demo/SKILL.md 24576
skills/demo/workflows/task.md 40960
README.md 16384
pkg/README.md 12288
skills/demo/references/contract.md 65536
CHANGELOG.md 65536
CLASSES

bytes src/large.rs 100000
git -C "$R" add src/large.rs
export DOC_LIMITS_CLASSES='*=1k'
run --staged
expect 0 'non-markdown-outside-ceilings'

private_command document-selection
[ ! -L "$MUTANT" ]
[ "$(grep -Fxc '  case "$f" in *.md) ;; *) continue ;; esac' "$MUTANT")" -eq 1 ]
sed 's/^  case "\$f" in \*\.md) ;; \*) continue ;; esac$/  case "$f" in *) ;; esac/' "$SOURCE_COMMAND" >"$MUTANT.changed"
if cmp -s "$SOURCE_COMMAND" "$MUTANT.changed"; then exit 1; fi
mv "$MUTANT.changed" "$MUTANT"
chmod +x "$MUTANT"
bash -n "$MUTANT"
SR="$MUTANT"
run --staged
must_fail 0 1 'document-selection control: measuring non-Markdown fails non-markdown-outside-ceilings'
SR="$SOURCE_COMMAND"
unset DOC_LIMITS_CLASSES
git -C "$R" rm -qf src/large.rs

bytes AGENTS.md 16385
git -C "$R" add AGENTS.md
EXCLUSION_ASSERTIONS=0
while IFS='|' read -r name operation expected; do
  case "$operation" in
    reasoned) printf 'AGENTS.md\tdeliberate fixture exception\n' >"$R/tools/doc-limits-excludes" ;;
    missing-reason) printf 'AGENTS.md\n' >"$R/tools/doc-limits-excludes" ;;
    removed) : >"$R/tools/doc-limits-excludes" ;;
  esac
  git -C "$R" add tools/doc-limits-excludes
  run --staged
  expect "$expected" "$name"
  EXCLUSION_ASSERTIONS=$((EXCLUSION_ASSERTIONS + 1))
done <<'EXCLUSION_CASES'
reasoned-exclusion|reasoned|0
exclusion-missing-reason|missing-reason|2
exclusion-removed|removed|1
EXCLUSION_CASES
if [ "$EXCLUSION_ASSERTIONS" -eq 0 ]; then
  printf 'FAIL: EXCLUSION_CASES executed no assertions\n' >&2
  exit 1
fi

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

printf '%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
