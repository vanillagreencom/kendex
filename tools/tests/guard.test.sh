#!/usr/bin/env bash
# tools/guard at commit time, the last lane of the pre-commit chain: the
# rooted() rule on new temporary fixtures, the bash32-lint lane, the
# run-scoping scan, the compile checks a staged product change schedules, and
# the verdicts guard leaves to the packages that own them. The --full lanes are guard-full.test.sh and the
# render rule is guard-render.test.sh.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
unset DOC_LIMITS_CLASSES DOC_LIMITS_DEFAULT_CLASSES DOC_LIMITS_EXCLUDES DOC_LIMITS_SETTINGS_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/guard-world.sh
. "$TEST_DIR/lib/guard-world.sh"
CHANGELOG_ENTRIES="$REPO/.agents/skills/commit-guards/scripts/changelog-entries"
RATCHET="$REPO/.agents/skills/doc-limits/scripts/doc-limits"

echo "=== new temporary fixtures derive their canonical root at creation ==="
mkdir -p "$R/crates/core/tests"
temp_case() { # pass|refuse LABEL SOURCE-LINE...
  local expected=$1 label=$2
  shift 2
  printf '%s\n' "$@" >"$R/crates/core/tests/temp_path.rs"
  git -C "$R" add -A
  run_guard
  if [ "$expected" = pass ] && [ "$RC" -eq 0 ]; then
    ok "$label"
  elif [ "$expected" = refuse ] && [ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: unrooted-fixture=1"* ]]; then
    ok "$label"
  else
    bad "$label" "rc=$RC out=$OUT"
  fi
}

temp_case refuse "tempfile::tempdir without rooted is refused" \
  'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' drop(tmp);' '}'
temp_case refuse "TempDir::new without rooted is refused" \
  'fn fixture() {' ' let tmp = tempfile::TempDir::new().unwrap();' ' drop(tmp);' '}'
temp_case pass "a bound rooted fixture passes" \
  'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' let home = &rooted(&tmp);' ' drop(home);' '}'
temp_case pass "comments may sit between construction and rooted" \
  'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' // The root enters here.' ' let home = rooted(&tmp);' ' drop(home);' '}'
temp_case pass "same-name non-temporary path owners do not trigger" \
  'fn fixture() {' ' let tmp = ProjectFixture::new();' ' let root = tmp.path();' ' drop(root);' '}'
temp_case pass "comments and strings that mention tempfile constructors pass" \
  'fn prose() {' ' // let tmp = tempfile::tempdir().unwrap();' ' let shown = "tempfile::TempDir::new()";' ' drop(shown);' '}'
temp_case refuse "a line-comment glob cannot hide a later unrooted fixture" \
  'fn fixture() {' ' // fixtures live under crates/*/tests' ' let _tmp = tempfile::tempdir().unwrap();' '}'
temp_case refuse "rooting a different binding does not clear the declaration" \
  'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' let home = rooted(&other);' ' drop(home);' '}'
temp_case refuse "a string literal naming rooted does not clear the declaration" \
  'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' let shown = "rooted(&tmp)";' ' drop(shown);' '}'

# A run of adjacent declarations is checked member by member: resolving one
# must not consume the line that declares the next.
printf '%s\n' 'fn fixture() {' ' let a = tempfile::tempdir().unwrap();' ' let b = tempfile::tempdir().unwrap();' ' let c = tempfile::tempdir().unwrap();' ' drop((a, b, c));' '}' >"$R/crates/core/tests/temp_path.rs"
git -C "$R" add -A
run_guard
if [ "$RC" -ne 0 ] && [[ "$OUT" == *"temp_path.rs:2"* ]] && [[ "$OUT" == *"temp_path.rs:3"* ]] && [[ "$OUT" == *"temp_path.rs:4"* ]]; then
  ok "every member of a run of unrooted declarations is named"
else
  bad "every member of a run of unrooted declarations is named" "rc=$RC out=$OUT"
fi

git -C "$R" config color.diff always
temp_case refuse "colored diff output cannot hide an unrooted fixture" \
  'fn fixture() {' ' let tmp = tempfile::tempdir().unwrap();' ' drop(tmp);' '}'
git -C "$R" config --unset color.diff

mkdir -p "$R/fake-bin"
cat >"$R/fake-bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
is_temp_diff=0
if [ "${1:-}" = diff ]; then
  for arg in "$@"; do
    [ "$arg" = "--unified=100000" ] && is_temp_diff=$((is_temp_diff + 1))
    [ "$arg" = "crates/*/tests/*.rs" ] && is_temp_diff=$((is_temp_diff + 1))
  done
fi
[ "${FAIL_TEMP_DIFF:-0}" -eq 1 ] && [ "$is_temp_diff" -eq 2 ] && exit 2
exec "$REAL_GIT" "$@"
SH
cat >"$R/fake-bin/awk" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
if [ "${FAIL_TEMP_AWK:-0}" -eq 1 ] && [[ "${1:-}" == *pending_text* ]]; then
  exit 2
fi
exec "$REAL_AWK" "$@"
SH
chmod +x "$R/fake-bin/git" "$R/fake-bin/awk"
run_guard PATH="$R/fake-bin:$PATH" REAL_GIT="$REAL_GIT" REAL_AWK="$REAL_AWK" FAIL_TEMP_DIFF=1
[ "$RC" -ne 0 ] && case "$OUT" in *"guard: fixture-diff=unreadable"*) true ;; *) false ;; esac \
  && ok "a failed fixture diff blocks guard" \
  || bad "a failed fixture diff blocks guard" "rc=$RC out=$OUT"
run_guard PATH="$R/fake-bin:$PATH" REAL_GIT="$REAL_GIT" REAL_AWK="$REAL_AWK" FAIL_TEMP_AWK=1
[ "$RC" -ne 0 ] && case "$OUT" in *"guard: fixture-scan=unreadable"*) true ;; *) false ;; esac \
  && ok "a failed fixture parser blocks guard" \
  || bad "a failed fixture parser blocks guard" "rc=$RC out=$OUT"
rm -f "$R/fake-bin/git" "$R/fake-bin/awk"
git -C "$R" reset -q HEAD -- crates/core/tests/temp_path.rs
rm -f "$R/crates/core/tests/temp_path.rs"

echo "=== the shipped packages' verdicts are not twinned here ==="
# Guard delegates document sizes and changelog entries to their shipped
# checks. The preconditions run those checks on the same defects: the
# fixture reaches each package's bound, so guard's silence is a delegation.
head -c 16385 /dev/zero | tr '\0' x >"$R/AGENTS.md"
printf '// %s: unfinished\n' "TO""DO" >"$R/crates/marker.rs" # split, or todo-ban fails this file
printf '#![allow(dead_code)]\n' >"$R/crates/blanket.rs"
head -c 300000 /dev/zero | tr '\0' 'x' >"$R/crates/huge.bin"
mkdir -p "$R/changelog.d/fixed"
LONG="$(head -c 260 /dev/zero | tr '\0' 'e')"
printf -- '- %s\n' "$LONG" >"$R/changelog.d/fixed/ken-long.md"
printf -- '- One entry.\n- A second entry.\n' >"$R/changelog.d/fixed/ken-two.md"
git -C "$R" add -A
SR_OUT=""
SR_RC=0
SR_OUT="$(cd "$R" && "$RATCHET" 2>&1)" || SR_RC=$?
[ "$SR_RC" -eq 1 ] && case "$SR_OUT" in *"AGENTS.md: 16385 bytes > 16384 bytes"*) true ;; *) false ;; esac \
  && ok "precondition: doc-limits refuses the oversized document" \
  || bad "precondition: doc-limits refuses the oversized document" "rc=$SR_RC out=$SR_OUT"
CE_OUT=""
CE_RC=0
CE_OUT="$(cd "$R" && "$CHANGELOG_ENTRIES" 2>&1)" || CE_RC=$?
[ "$CE_RC" -eq 1 ] \
  && case "$CE_OUT" in *ken-long.md*) true ;; *) false ;; esac \
  && case "$CE_OUT" in *ken-two.md*) true ;; *) false ;; esac \
  && ok "precondition: changelog-entries refuses the long entry and the two-entry fragment" \
  || bad "precondition: changelog-entries refuses the long entry and the two-entry fragment" "rc=$CE_RC out=$CE_OUT"
run_guard
[ "$RC" -eq 0 ] \
  && ok "an over-limit document, a work marker, a blanket allow, a 300 KB file, a malformed and an over-long fragment all pass — the packages judge those" \
  || bad "an over-limit document, a work marker, a blanket allow, a 300 KB file, a malformed and an over-long fragment all pass — the packages judge those" "rc=$RC out=$OUT"
case "$OUT" in *Unreleased* | *changelog* | *fragment*) bad "guard names neither changelog scope" "$OUT" ;; *) ok "guard names neither changelog scope" ;; esac
reset_world

echo "=== the skill tree is 3.2-clean ==="
run_guard
[ "$RC" -eq 0 ] \
  && ok "a 3.2-clean skill tree with every render in step passes" \
  || bad "a 3.2-clean skill tree with every render in step passes" "rc=$RC out=$OUT"
BASH4_LINE='mapfile -t demo_lines <"$0"'
printf '%s\n' "$BASH4_LINE" >>"$R/skills/demo/tests/demo.test.sh"
printf '%s\n' "$BASH4_LINE" >>"$R/.agents/skills/demo/tests/demo.test.sh"
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: bash32-lint=1"* ]] \
  && [[ "$OUT" == *"bash32-lint: constructs=1"* ]] \
  && [[ "$OUT" != *"guard: missing-render="* ]] \
  && ok "a Bash 4 construct in a skill test reds the guard through the lint lane" \
  || bad "a Bash 4 construct in a skill test reds the guard through the lint lane" "rc=$RC out=$OUT"
if mutant_guard '/TOOLS_DIR\/bash32-lint/d'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the bash32-lint lane deleted the construct passes" \
    || bad "control: with the bash32-lint lane deleted the construct passes" "rc=$RC out=$OUT"
else
  bad "control: the bash32-lint lane could not be deleted from a guard copy"
fi
git -C "$R" checkout -q -- skills .agents

echo "=== a caller carrying its own run scoping reds through the correlation lane ==="
mkdir -p "$R/skills/github/scripts/commands"
printf '#!/usr/bin/env bash\necho "def bucket: ."\n' >"$R/skills/github/scripts/commands/demo.sh"
git -C "$R" add skills/github/scripts/commands/demo.sh
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: ci-correlation-copy=1"* ]] \
  && [[ "$OUT" == *"skills/github/scripts/commands/demo.sh:2:"* ]] \
  && ok "a def bucket copy in a GitHub command reds the guard, naming the line" \
  || bad "a def bucket copy in a GitHub command reds the guard, naming the line" "rc=$RC out=$OUT"
if mutant_guard '/def (bucket|runid)/d'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the correlation lane deleted the copy passes" \
    || bad "control: with the correlation lane deleted the copy passes" "rc=$RC out=$OUT"
else
  bad "control: the correlation lane could not be deleted from a guard copy"
fi
git -C "$R" rm -q --cached skills/github/scripts/commands/demo.sh
rm -rf -- "$R/skills/github"
mkdir -p "$R/skills/orch/scripts"
printf '#!/usr/bin/env bash\nscope_current_run() { :; }\n' >"$R/skills/orch/scripts/ci-wait"
git -C "$R" add skills/orch/scripts/ci-wait
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: ci-correlation-copy=1"* ]] \
  && [[ "$OUT" == *"skills/orch/scripts/ci-wait:2:"* ]] \
  && ok "a scope_current_run copy in orch ci-wait reds the guard, naming the line" \
  || bad "a scope_current_run copy in orch ci-wait reds the guard, naming the line" "rc=$RC out=$OUT"
git -C "$R" rm -q --cached skills/orch/scripts/ci-wait
rm -rf -- "$R/skills/orch"

echo "=== the shipped command-safety policies keep refusing what they document ==="
policy_line='COMMAND_SAFETY_DENY_PATTERN = "^never-matches-anything$"'
cp "$R/kendex.settings.toml" "$TMP/settings.orig"
awk -v repl="$policy_line" '/^COMMAND_SAFETY_DENY_PATTERN = / { print repl; next } { print }' \
  "$TMP/settings.orig" >"$R/kendex.settings.toml"
git -C "$R" add kendex.settings.toml
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: command-safety-missed=kendex.settings.toml"* ]] \
  && [[ "$OUT" == *"  systemd-run --user --scope -p MemoryMax=64M cargo test -p kendex-core"* ]] \
  && ok "a settings policy that stopped refusing a capped scope reds, naming the command" \
  || bad "a settings policy that stopped refusing a capped scope reds, naming the command" "rc=$RC out=$OUT"
if mutant_guard '/^command_safety_policy kendex.settings.toml/,+5d'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the settings policy rows deleted the weakened pattern passes" \
    || bad "control: with the settings policy rows deleted the weakened pattern passes" "rc=$RC out=$OUT"
else
  bad "control: the settings policy rows could not be deleted from a guard copy"
fi
cp "$TMP/settings.orig" "$R/kendex.settings.toml"

cp "$R/docs/authoring/command-safety.md" "$TMP/doc.orig"
awk -v repl="$policy_line" '/^COMMAND_SAFETY_DENY_PATTERN = / { print repl; next } { print }' \
  "$TMP/doc.orig" >"$R/docs/authoring/command-safety.md"
git -C "$R" add docs/authoring/command-safety.md
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: command-safety-missed=docs/authoring/command-safety.md"* ]] \
  && [[ "$OUT" == *"  qs -c vshell"* ]] \
  && ok "a doc example that stopped refusing its own call reds, naming the command" \
  || bad "a doc example that stopped refusing its own call reds, naming the command" "rc=$RC out=$OUT"
cp "$TMP/doc.orig" "$R/docs/authoring/command-safety.md"

awk '/^COMMAND_SAFETY_DENY_PATTERN = / { print "COMMAND_SAFETY_DENY_PATTERN = \"[\"" ; next } { print }' \
  "$TMP/settings.orig" >"$R/kendex.settings.toml"
run_guard
# The lane's own tools speak here: grep refuses the pattern. Guard forwards
# the streams of everything it runs, so the claim is not that the keyed line
# is line 1 of the run — it is that the keyed line comes before the
# diagnostic that explains it, rather than after it.
keyed_at="$(awk '/guard: command-safety-not-an-ere=kendex.settings.toml/ { print NR; exit }' <<<"$OUT")"
grep_at="$(awk 'tolower($0) ~ /invalid|unmatched|unterminated/ { print NR; exit }' <<<"$OUT")"
[ "$RC" -ne 0 ] && [ -n "$keyed_at" ] && [ -n "$grep_at" ] && [ "$keyed_at" -lt "$grep_at" ] \
  && ok "a policy that is not a valid ERE reds with its own clause, above what grep said" \
  || bad "a policy that is not a valid ERE reds with its own clause, above what grep said" \
    "rc=$RC keyed=${keyed_at:--} grep=${grep_at:--} out=$OUT"
cp "$TMP/settings.orig" "$R/kendex.settings.toml"

# The assignment moved out of [env] with its text intact: the settings loader
# follows table headers, so this is no longer a policy the hook would apply
# and the lane must not read the line as one. A line-matching reader would
# find the same text and pass.
awk '/^COMMAND_SAFETY_DENY_PATTERN = / { held = $0; next } { print }
  END { print "[other]"; print held }' \
  "$TMP/settings.orig" >"$R/kendex.settings.toml"
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: command-safety-empty=kendex.settings.toml"* ]] \
  && ok "an assignment outside [env] is not read as a policy" \
  || bad "an assignment outside [env] is not read as a policy" "rc=$RC out=$OUT"
cp "$TMP/settings.orig" "$R/kendex.settings.toml"

# A pattern broad enough to catch what the source documents as allowed is the
# other direction of the same rule, and the only one no row drove: `cargo
# test` under an uncapped scope is a command the settings comment names as
# left alone.
awk '/^COMMAND_SAFETY_DENY_PATTERN = / { print "COMMAND_SAFETY_DENY_PATTERN = \"systemd-run\""; next } { print }' \
  "$TMP/settings.orig" >"$R/kendex.settings.toml"
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: command-safety-over=kendex.settings.toml"* ]] \
  && [[ "$OUT" == *"  systemd-run --user --scope --slice=agents.slice cargo test -p kendex-core"* ]] \
  && ok "a policy broadened over a documented-allowed command reds, naming the command" \
  || bad "a policy broadened over a documented-allowed command reds, naming the command" "rc=$RC out=$OUT"
cp "$TMP/settings.orig" "$R/kendex.settings.toml"

# The loader answers from the process environment before the file it is given.
# The source is weakened and the environment carries the real policy: reading
# the environment would report a policy the file does not carry, which is the
# fail-open this lane exists to refuse.
awk -v repl="$policy_line" '/^COMMAND_SAFETY_DENY_PATTERN = / { print repl; next } { print }' \
  "$TMP/settings.orig" >"$R/kendex.settings.toml"
real_policy="$(sed -n 's/^COMMAND_SAFETY_DENY_PATTERN = "\(.*\)"$/\1/p' "$TMP/settings.orig")"
[ -n "$real_policy" ] || bad "precondition: the settings policy could not be read for the override row"
run_guard COMMAND_SAFETY_DENY_PATTERN="$real_policy"
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: command-safety-missed=kendex.settings.toml"* ]] \
  && ok "an ambient COMMAND_SAFETY_DENY_PATTERN does not answer for a weakened source" \
  || bad "an ambient COMMAND_SAFETY_DENY_PATTERN does not answer for a weakened source" "rc=$RC out=$OUT"
cp "$TMP/settings.orig" "$R/kendex.settings.toml"

git -C "$R" add kendex.settings.toml docs/authoring/command-safety.md
run_guard
[ "$RC" -eq 0 ] \
  && ok "the shipped policies pass the lane unchanged" \
  || bad "the shipped policies pass the lane unchanged" "rc=$RC out=$OUT"

echo "=== commit compile scheduling follows product changes ==="
mkdir -p "$R/crates/core/src" "$R/crates/cli/src" "$R/ui" "$R/fake-bin"
printf '[workspace]\n' >"$R/Cargo.toml"
printf '[lints]\nworkspace = true\n' >"$R/crates/core/Cargo.toml"
printf '[lints]\nworkspace = true\n' >"$R/crates/cli/Cargo.toml"
printf 'fn first() {}\n' >"$R/crates/core/src/lib.rs"
printf 'fn first() {}\n' >"$R/crates/cli/src/lib.rs"
printf '{}\n' >"$R/ui/package.json"
cat >"$R/fake-bin/cargo" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'cargo %s\n' "$*" >>"$COMPILE_LOG"
[ "$*" != "${FAIL_COMPILE:-}" ]
SH
cat >"$R/fake-bin/npm" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'npm %s\n' "$*" >>"$COMPILE_LOG"
[ "$*" != "${FAIL_COMPILE:-}" ]
SH
chmod +x "$R/fake-bin/cargo" "$R/fake-bin/npm"
git -C "$R" add -A
git -C "$R" commit -qm 'test: compiler fixture'
COMPILE_LOG="$TMP/compile.log"
printf '# docs\n' >"$R/README.md"
git -C "$R" add README.md
: >"$COMPILE_LOG"
run_guard PATH="$R/fake-bin:$PATH" COMPILE_LOG="$COMPILE_LOG"
[ "$RC" -eq 0 ] && [ ! -s "$COMPILE_LOG" ] \
  && ok "a docs-only commit runs no compiler or test runner" \
  || bad "docs-only scheduling" "rc=$RC out=$OUT calls=$(cat "$COMPILE_LOG")"
printf 'fn second() {}\n' >>"$R/crates/core/src/lib.rs"
git -C "$R" add crates/core/src/lib.rs
: >"$COMPILE_LOG"
run_guard PATH="$R/fake-bin:$PATH" COMPILE_LOG="$COMPILE_LOG"
[ "$RC" -eq 0 ] && grep -Fxq 'cargo check --manifest-path crates/core/Cargo.toml --all-targets' "$COMPILE_LOG" \
  && grep -Fxq 'cargo clippy --manifest-path crates/core/Cargo.toml --all-targets --quiet -- -D warnings' "$COMPILE_LOG" \
  && ! grep -Eq 'crates/cli|cargo (test|doc)|npm|--workspace|--target ' "$COMPILE_LOG" \
  && ok "Rust checks select the touched crate and omit full suites" \
  || bad "Rust scoped checks" "rc=$RC out=$OUT calls=$(cat "$COMPILE_LOG")"
# A failing compiler call blocks with guard's own first line for that call:
# `guard: <key>=<value>`, the value naming what was checked. The table counts
# its own rows: an emptied row list is a red, never a green.
before=$((PASS + FAIL))
while IFS='|' read -r command clause; do
  run_guard PATH="$R/fake-bin:$PATH" COMPILE_LOG="$COMPILE_LOG" FAIL_COMPILE="$command"
  [ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: $clause"* ]] \
    && ok "the $command failure blocks, naming it" \
    || bad "the $command failure blocks, naming it" "rc=$RC out=$OUT"
done <<'ROWS'
check --manifest-path crates/core/Cargo.toml --all-targets|cargo-check=crates/core/Cargo.toml
clippy --manifest-path crates/core/Cargo.toml --all-targets --quiet -- -D warnings|clippy=crates/core/Cargo.toml
ROWS
[ "$((PASS + FAIL))" -gt "$before" ] || { echo "no row was asserted: the compiler failures" >&2; exit 2; }
git -C "$R" reset -q HEAD -- crates/core/src/lib.rs
git -C "$R" checkout -q -- crates/core/src/lib.rs
printf 'export const value = 1;\n' >"$R/ui/test.ts"
git -C "$R" add ui/test.ts
: >"$COMPILE_LOG"
run_guard PATH="$R/fake-bin:$PATH" COMPILE_LOG="$COMPILE_LOG"
[ "$RC" -eq 0 ] && grep -Fxq 'npm run --prefix ui check:types' "$COMPILE_LOG" \
  && grep -Fxq 'npm run --prefix ui check:lint' "$COMPILE_LOG" \
  && ! grep -Eq 'cargo|npm.* test' "$COMPILE_LOG" \
  && ok "UI changes run types and lint without tests or Rust" \
  || bad "UI scoped checks" "rc=$RC out=$OUT calls=$(cat "$COMPILE_LOG")"
before=$((PASS + FAIL))
while IFS='|' read -r command clause; do
  run_guard PATH="$R/fake-bin:$PATH" COMPILE_LOG="$COMPILE_LOG" FAIL_COMPILE="$command"
  [ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: $clause"* ]] \
    && ok "the $command failure blocks, naming it" \
    || bad "the $command failure blocks, naming it" "rc=$RC out=$OUT"
done <<'ROWS'
run --prefix ui check:types|ui-check=check:types
run --prefix ui check:lint|ui-check=check:lint
ROWS
[ "$((PASS + FAIL))" -gt "$before" ] || { echo "no row was asserted: the UI failures" >&2; exit 2; }
git -C "$R" reset -q HEAD -- ui/test.ts
printf '# workspace changed\n' >>"$R/Cargo.toml"
git -C "$R" add Cargo.toml
: >"$COMPILE_LOG"
run_guard PATH="$R/fake-bin:$PATH" COMPILE_LOG="$COMPILE_LOG"
[ "$RC" -eq 0 ] && grep -Fxq 'cargo check --workspace --all-targets' "$COMPILE_LOG" \
  && ! grep -Eq 'cargo (test|doc)' "$COMPILE_LOG" \
  && ok "shared Rust inputs compile the workspace without running tests" \
  || bad "shared Rust input scheduling" "rc=$RC out=$OUT calls=$(cat "$COMPILE_LOG")"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
