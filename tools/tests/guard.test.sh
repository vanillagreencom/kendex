#!/usr/bin/env bash
# tools/guard at commit time, the last lane of the pre-commit chain: the
# rooted() rule on new temporary fixtures, the bash32-lint, test-roster and
# shipped-refs lanes, the common file set, the run-scoping scan, the compile checks a staged product change schedules, and
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

echo "=== a test that names the kendex binary hands it a fixture home at each launch ==="
MARKED='    let out = std::process::Command::new(env!("CARGO_BIN_EXE_kendex")).envs(test_util::fixture_env(home)).output().unwrap();'
UNMARKED='    let out = std::process::Command::new(env!("CARGO_BIN_EXE_kendex")).output().unwrap();'
mkdir -p "$R/crates/cli/tests" && printf '%s\n' 'fn marked(home: &std::path::Path) {' "$MARKED" '}' 'fn unmarked() {' "$UNMARKED" '}' >"$R/crates/cli/tests/binary_home.rs" && git -C "$R" add -A && run_guard
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: binary-home=1"* ]] && [[ "$OUT" == *"crates/cli/tests/binary_home.rs:5"* ]] && ok "an unmarked launch beside a marked one is refused at its line" || bad "an unmarked launch beside a marked one is refused at its line" "rc=$RC out=$OUT"
printf '%s\n' 'fn unmarked(home: &std::path::Path, bin: &str) {' '    let mut run = std::process::Command::new(bin);' '    let git = std::process::Command::new("git").envs(test_util::fixture_env(home)).output().unwrap();' '    let out = run.output().unwrap();' '}' 'fn name() -> &'"'"'static str { env!("CARGO_BIN_EXE_kendex") }' >"$R/crates/cli/tests/binary_home.rs" && git -C "$R" add -A && run_guard
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: binary-home=1"* ]] && [[ "$OUT" == *"crates/cli/tests/binary_home.rs:2"* ]] && ok "a marked builder of another program between an unmarked launch and its run call is refused at the launch" || bad "a marked builder of another program between an unmarked launch and its run call is refused at the launch" "rc=$RC out=$OUT"
printf '%s\n' 'fn marked(home: &std::path::Path) {' "$MARKED" '}' 'fn also(home: &std::path::Path) {' "$MARKED" '}' >"$R/crates/cli/tests/binary_home.rs" && git -C "$R" add -A && run_guard
[ "$RC" -eq 0 ] && ok "two marked launches pass" || bad "two marked launches pass" "rc=$RC out=$OUT"
printf '#!/usr/bin/env bash\n[[ "$*" == *"function clears"* ]] && exit 2\nexec "$REAL_AWK" "$@"\n' >"$R/fake-bin/awk" && chmod +x "$R/fake-bin/awk"
run_guard PATH="$R/fake-bin:$PATH" REAL_AWK="$REAL_AWK"
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: test-scan=binary-home"* ]] && ok "a per-file scan that cannot run blocks guard, naming its lane" || bad "a per-file scan that cannot run blocks guard, naming its lane" "rc=$RC out=$OUT"
printf '%s\n' 'fn home(home: &std::path::Path) {' '    let out = std::process::Command::new("git").env("HOME", home).env("KENDEX_REAL_HOME", "1").output().unwrap();' '}' >"$R/crates/cli/tests/fixture_home.rs" && printf '#!/usr/bin/env bash\n[[ "$*" == *KENDEX_REAL_HOME* ]] && exit 2\nexec "$REAL_AWK" "$@"\n' >"$R/fake-bin/awk" && run_guard PATH="$R/fake-bin:$PATH" REAL_AWK="$REAL_AWK"
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: test-scan=fixture-home"* ]] && ok "a fixture-home scan that cannot run blocks guard, naming its lane" || bad "a fixture-home scan that cannot run blocks guard, naming its lane" "rc=$RC out=$OUT"
rm -f "$R/crates/cli/tests/fixture_home.rs"
git -C "$R" reset -q HEAD -- crates/cli/tests/binary_home.rs && rm -f "$R/crates/cli/tests/binary_home.rs" "$R/fake-bin/awk" && rmdir "$R/crates/cli/tests" "$R/crates/cli"

echo "=== a file under tests/ no harness declares reds through the test-roster lane ==="
# The rule is tools/test-roster's and its rows are tools/tests/
# test-roster.test.sh; this proves guard runs it and forwards its verdict.
mkdir -p "$R/crates/cli/tests"
printf '[package]\nname = "demo"\nautotests = false\n\n[[test]]\nname = "integration"\npath = "tests/main.rs"\n' >"$R/crates/cli/Cargo.toml"
printf 'mod declared;\n' >"$R/crates/cli/tests/main.rs"
printf 'fn declared() {}\n' >"$R/crates/cli/tests/declared.rs"
printf 'fn orphan() {}\n' >"$R/crates/cli/tests/orphan.rs"
git -C "$R" add -A && run_guard
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: test-roster=1"* ]] && [[ "$OUT" == *"test-roster: orphans=1"* ]] && [[ "$OUT" == *"crates/cli/tests/orphan.rs"* ]] && ok "an undeclared test file reds guard through the test-roster lane, naming the file" || bad "an undeclared test file reds guard through the test-roster lane, naming the file" "rc=$RC out=$OUT"
if mutant_guard '/TOOLS_DIR\/test-roster/d'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the test-roster lane deleted the orphan passes" \
    || bad "control: with the test-roster lane deleted the orphan passes" "rc=$RC out=$OUT"
else
  bad "control: the test-roster lane could not be deleted from a guard copy"
fi
git -C "$R" reset -q HEAD -- crates/cli
rm -f "$R/crates/cli/Cargo.toml" "$R/crates/cli/tests/main.rs" "$R/crates/cli/tests/declared.rs" "$R/crates/cli/tests/orphan.rs"
rmdir "$R/crates/cli/tests" "$R/crates/cli"

echo "=== a shipped decision citation reds through the shipped-refs lane ==="
# The rule is tools/shipped-refs' and its rows are tools/tests/
# shipped-refs.test.sh; this proves guard runs it and forwards its verdict.
printf '#!/usr/bin/env bash\n# Per D015, the share stands.\necho demo\n' >"$R/skills/demo/scripts/demo.sh"
cp "$R/skills/demo/scripts/demo.sh" "$R/.agents/skills/demo/scripts/demo.sh"
git -C "$R" add -A && run_guard
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: shipped-refs=1"* ]] && [[ "$OUT" == *"shipped-refs: decisions=1"* ]] && [[ "$OUT" == *$'skills/demo/scripts/demo.sh:2\tD015'* ]] && ok "a shipped decision citation reds guard through the shipped-refs lane, naming the line" || bad "a shipped decision citation reds guard through the shipped-refs lane, naming the line" "rc=$RC out=$OUT"
if mutant_guard '/TOOLS_DIR\/shipped-refs/d'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the shipped-refs lane deleted the citation passes" \
    || bad "control: with the shipped-refs lane deleted the citation passes" "rc=$RC out=$OUT"
else
  bad "control: the shipped-refs lane could not be deleted from a guard copy"
fi
reset_world

echo "=== incomplete common-file discovery refuses all dependent scans ==="
printf '#!/usr/bin/env bash\nif [ "$*" = "$GUARD_TEST_FAIL_COLLECTION" ]; then echo skills/demo/README.md; exit 9; fi\nexec %q "$@"\n' \
  "$REAL_GIT" >"$MUTANT_TOOLS/git"
chmod +x "$MUTANT_TOOLS/git"
for command in 'ls-files' 'diff --cached --name-only'; do
  GUARD_TEST_ENV=(-i "PATH=$MUTANT_TOOLS:$PATH" "HOME=$TMP" LC_ALL=C "GUARD_TEST_FAIL_COLLECTION=$command")
  run_guard
  [ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: file-set=unreadable"* ]] \
    && ok "a failed $command cannot pass on its partial output" \
    || bad "a failed $command cannot pass on its partial output" "rc=$RC out=$OUT"
  matches=$(grep -Fc 'say file-set unreadable' "$GUARD") || matches=0
  if [ "$matches" -eq 1 ] && mutant_guard 's/say file-set unreadable/:/'; then
    run_mutant
    [ "$RC" -eq 0 ] && ok "control: without the file-set refusal a failed $command passes" \
      || bad "control: without the file-set refusal a failed $command passes" "rc=$RC out=$OUT"
  else
    bad "control: the file-set refusal was not changed in the guard copy"
  fi
done
rm -f -- "${MUTANT_TOOLS:?}/git"
unset GUARD_TEST_ENV

echo "=== the shipped packages' verdicts are not twinned here ==="
# Guard delegates document sizes and changelog entries to their shipped
# checks. The preconditions run those checks on the same fixture, so
# guard's silence on a package-owned refusal proves the delegation.
head -c 8193 /dev/zero | tr '\0' x >"$R/AGENTS.md"
printf '// %s: unfinished\n' "TO""DO" >"$R/crates/marker.rs" # split, or todo-ban fails this file
printf '#![allow(dead_code)]\n' >"$R/crates/blanket.rs"
head -c 300000 /dev/zero | tr '\0' 'x' >"$R/crates/huge.bin"
mkdir -p "$R/changelog.d/fixed"
LONG="$(head -c 260 /dev/zero | tr '\0' 'e')"
printf -- '- %s\n' "$LONG" >"$R/changelog.d/fixed/ken-long.md"
git -C "$R" add -A
SR_OUT=""
SR_RC=0
SR_OUT="$(cd "$R" && "$RATCHET" 2>&1)" || SR_RC=$?
[ "$SR_RC" -eq 1 ] && case "$SR_OUT" in *"AGENTS.md: 8193 bytes > 8192 bytes"*) true ;; *) false ;; esac \
  && ok "precondition: doc-limits refuses the oversized document" \
  || bad "precondition: doc-limits refuses the oversized document" "rc=$SR_RC out=$SR_OUT"
changelog_entries_pass() { # CHECKER: the same acceptance assertion for the control
  CE_OUT=""
  CE_RC=0
  CE_OUT="$(cd "$R" && "$1" 2>&1)" || CE_RC=$?
  [ "$CE_RC" -eq 0 ]
}
changelog_entries_pass "$CHANGELOG_ENTRIES" \
  && ok "precondition: changelog-entries accepts the long entry" \
  || bad "precondition: changelog-entries accepts the long entry" "rc=$CE_RC out=$CE_OUT"

# A private checker copy restores the length refusal on the same long entry.
mkdir -p "$TMP/changelog-control"
cp -R "$REPO/.agents/skills/commit-guards/scripts" "$TMP/changelog-control/scripts"
python3 - "$TMP/changelog-control/scripts/changelog-entries" <<'EDIT'
import pathlib, sys
p = pathlib.Path(sys.argv[1])
s = p.read_text()
needle = '  checked=$((checked + 1))'
assert s.count(needle) == 1
p.write_text(s.replace(needle, needle + '\n  [ "$(wc -c <"$GG_TMP/blob")" -le 200 ] || violations=$((violations + 1))'))
EDIT
if changelog_entries_pass "$TMP/changelog-control/scripts/changelog-entries"; then
  bad "control: the length refusal must fail the long-entry acceptance assertion" "rc=$CE_RC out=$CE_OUT"
elif [ "$CE_RC" -eq 1 ]; then
  ok "control: the length refusal fails the long-entry acceptance assertion"
else
  bad "control: the private checker did not reach its length refusal" "rc=$CE_RC out=$CE_OUT"
fi

printf -- '- One entry.\n- A second entry.\n' >"$R/changelog.d/fixed/ken-two.md"
git -C "$R" add changelog.d/fixed/ken-two.md
changelog_entries_pass "$CHANGELOG_ENTRIES" || :
[ "$CE_RC" -eq 1 ] \
  && case "$CE_OUT" in *"changelog-entries: fragment-continuation=changelog.d/fixed/ken-two.md"*) true ;; *) false ;; esac \
  && ok "precondition: changelog-entries refuses the two-entry fragment" \
  || bad "precondition: changelog-entries refuses the two-entry fragment" "rc=$CE_RC out=$CE_OUT"
run_guard
[ "$RC" -eq 0 ] \
  && ok "an over-limit document, a work marker, a blanket allow, a 300 KB file, a malformed fragment and a long entry all pass: the packages judge those" \
  || bad "an over-limit document, a work marker, a blanket allow, a 300 KB file, a malformed fragment and a long entry all pass: the packages judge those" "rc=$RC out=$OUT"
case "$OUT" in *Unreleased* | *changelog* | *fragment*) bad "guard names neither changelog scope" "$OUT" ;; *) ok "guard names neither changelog scope" ;; esac
reset_world

echo "=== the skill tree is 3.2-clean ==="
run_guard
[ "$RC" -eq 0 ] \
  && ok "a 3.2-clean skill tree with every render in step passes" \
  || bad "a 3.2-clean skill tree with every render in step passes" "rc=$RC out=$OUT"
BASH4_LINE='mapfile -t demo_lines <"$0"'
printf '%s\n' "$BASH4_LINE" >>"$R/skills/demo/tests/demo.test.sh"
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
if mutant_guard '/def (bucket|runid|red|required_only)/d'; then
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
printf '#!/usr/bin/env bash\necho "def required_only($r): ."\n' >"$R/skills/orch/scripts/ci-wait"
git -C "$R" add skills/orch/scripts/ci-wait
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: ci-correlation-copy=1"* ]] \
  && [[ "$OUT" == *"skills/orch/scripts/ci-wait:2:"* ]] \
  && ok "a required_only copy in orch ci-wait reds the guard, naming the line" \
  || bad "a required_only copy in orch ci-wait reds the guard, naming the line" "rc=$RC out=$OUT"
if mutant_guard '/def (bucket|runid|red|required_only)/d'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the correlation lane deleted the required_only copy passes" \
    || bad "control: with the correlation lane deleted the required_only copy passes" "rc=$RC out=$OUT"
else
  bad "control: the correlation lane could not be deleted from a guard copy"
fi
printf '#!/usr/bin/env bash\necho "def red: ."\n' >"$R/skills/orch/scripts/ci-wait"
git -C "$R" add skills/orch/scripts/ci-wait
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: ci-correlation-copy=1"* ]] \
  && [[ "$OUT" == *"skills/orch/scripts/ci-wait:2:"* ]] \
  && ok "a red copy in orch ci-wait reds the guard, naming the line" \
  || bad "a red copy in orch ci-wait reds the guard, naming the line" "rc=$RC out=$OUT"
# Narrow: only the red alternative leaves the alternation, so this control
# answers for that alternative alone and not for the lane around it.
if mutant_guard 's/(bucket|runid|red|required_only)/(bucket|runid|required_only)/'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with only the red alternative removed the red copy passes" \
    || bad "control: with only the red alternative removed the red copy passes" "rc=$RC out=$OUT"
else
  bad "control: the red alternative could not be removed from a guard copy"
fi
git -C "$R" rm -q --cached skills/orch/scripts/ci-wait
rm -rf -- "$R/skills/orch"

echo "=== the shipped command-safety policy keeps refusing what it documents ==="
policy_line='COMMAND_SAFETY_DENY_PATTERN = "^never-matches-anything$"'
cp "$R/docs/authoring/command-safety.md" "$TMP/doc.orig"
awk -v repl="$policy_line" '/^COMMAND_SAFETY_DENY_PATTERN = / { print repl; next } { print }' \
  "$TMP/doc.orig" >"$R/docs/authoring/command-safety.md"
git -C "$R" add docs/authoring/command-safety.md
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: command-safety-missed=docs/authoring/command-safety.md"* ]] \
  && [[ "$OUT" == *"  qs -c vshell"* ]] \
  && ok "a doc example that stopped refusing its own call reds, naming the command" \
  || bad "a doc example that stopped refusing its own call reds, naming the command" "rc=$RC out=$OUT"
if mutant_guard '/^command_safety_policy docs\/authoring\/command-safety.md/,+9d'; then
  run_mutant
  [ "$RC" -eq 0 ] \
    && ok "control: with the doc policy rows deleted the weakened pattern passes" \
    || bad "control: with the doc policy rows deleted the weakened pattern passes" "rc=$RC out=$OUT"
else
  bad "control: the doc policy rows could not be deleted from a guard copy"
fi
cp "$TMP/doc.orig" "$R/docs/authoring/command-safety.md"

awk '/^COMMAND_SAFETY_DENY_PATTERN = / { print "COMMAND_SAFETY_DENY_PATTERN = \"[\"" ; next } { print }' \
  "$TMP/doc.orig" >"$R/docs/authoring/command-safety.md"
run_guard
# The lane's own tools speak here: grep refuses the pattern. Guard forwards
# the streams of everything it runs, so the claim is not that the keyed line
# is line 1 of the run — it is that the keyed line comes before the
# diagnostic that explains it, rather than after it.
keyed_at="$(awk '/guard: command-safety-not-an-ere=docs\/authoring\/command-safety.md/ { print NR; exit }' <<<"$OUT")"
grep_at="$(awk '/^grep: / { print NR; exit }' <<<"$OUT")"
[ "$RC" -ne 0 ] && [ -n "$keyed_at" ] && [ -n "$grep_at" ] && [ "$keyed_at" -lt "$grep_at" ] \
  && ok "a policy that is not a valid ERE reds with its own clause, above what grep said" \
  || bad "a policy that is not a valid ERE reds with its own clause, above what grep said" \
    "rc=$RC keyed=${keyed_at:--} grep=${grep_at:--} out=$OUT"
cp "$TMP/doc.orig" "$R/docs/authoring/command-safety.md"

# A pattern broad enough to catch an allowed command is the other direction of
# the same rule. The doc allows only scripts/validate qml, which no qs pattern
# reaches; the qs call on a test fixture is the guard's own allow row, the
# command a pattern broadened to every qs call catches.
awk '/^COMMAND_SAFETY_DENY_PATTERN = / { print "COMMAND_SAFETY_DENY_PATTERN = \"qs\""; next } { print }' \
  "$TMP/doc.orig" >"$R/docs/authoring/command-safety.md"
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: command-safety-over=docs/authoring/command-safety.md"* ]] \
  && [[ "$OUT" == *"  qs -c test-fixture"* ]] \
  && ok "a policy broadened over an allowed command reds, naming the command" \
  || bad "a policy broadened over an allowed command reds, naming the command" "rc=$RC out=$OUT"
cp "$TMP/doc.orig" "$R/docs/authoring/command-safety.md"

awk '/^COMMAND_SAFETY_DENY_PATTERN = / { print "COMMAND_SAFETY_DENY_PATTERN = \"\""; next } { print }' \
  "$TMP/doc.orig" >"$R/docs/authoring/command-safety.md"
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: command-safety-empty=docs/authoring/command-safety.md"* ]] \
  && ok "an emptied doc policy reds with its own clause" \
  || bad "an emptied doc policy reds with its own clause" "rc=$RC out=$OUT"
cp "$TMP/doc.orig" "$R/docs/authoring/command-safety.md"

awk '/^COMMAND_SAFETY_DENY_PATTERN = / { print } { print }' \
  "$TMP/doc.orig" >"$R/docs/authoring/command-safety.md"
run_guard
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: command-safety-lines=docs/authoring/command-safety.md"* ]] \
  && ok "a doc that spells the policy assignment twice reds with its own clause" \
  || bad "a doc that spells the policy assignment twice reds with its own clause" "rc=$RC out=$OUT"
cp "$TMP/doc.orig" "$R/docs/authoring/command-safety.md"

# The loader answers from the process environment before the file it is given.
# The source is weakened and the environment carries the real policy: reading
# the environment would report a policy the file does not carry, which is the
# fail-open this lane exists to refuse.
awk -v repl="$policy_line" '/^COMMAND_SAFETY_DENY_PATTERN = / { print repl; next } { print }' \
  "$TMP/doc.orig" >"$R/docs/authoring/command-safety.md"
real_policy="$(sed -n 's/^COMMAND_SAFETY_DENY_PATTERN = "\(.*\)"$/\1/p' "$TMP/doc.orig")"
[ -n "$real_policy" ] || bad "precondition: the doc policy could not be read for the override row"
run_guard COMMAND_SAFETY_DENY_PATTERN="$real_policy"
[ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: command-safety-missed=docs/authoring/command-safety.md"* ]] \
  && ok "an ambient COMMAND_SAFETY_DENY_PATTERN does not answer for a weakened source" \
  || bad "an ambient COMMAND_SAFETY_DENY_PATTERN does not answer for a weakened source" "rc=$RC out=$OUT"
cp "$TMP/doc.orig" "$R/docs/authoring/command-safety.md"

git -C "$R" add docs/authoring/command-safety.md
run_guard
[ "$RC" -eq 0 ] \
  && ok "the shipped policy passes the lane unchanged" \
  || bad "the shipped policy passes the lane unchanged" "rc=$RC out=$OUT"

echo "=== commit compile scheduling follows product changes ==="
mkdir -p "$R/crates/core/src" "$R/crates/cli/src" "$R/ui" "$R/fake-bin"
printf '[workspace]\n' >"$R/Cargo.toml"
printf '[package]\nname = "kendex-core"\n\n[lints]\nworkspace = true\n' >"$R/crates/core/Cargo.toml"
printf '[package]\nname = "kendex-cli"\n\n[lints]\nworkspace = true\n' >"$R/crates/cli/Cargo.toml"
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
[ "$RC" -eq 0 ] && grep -Fxq 'cargo clippy --manifest-path crates/core/Cargo.toml --all-targets --quiet -- -D warnings' "$COMPILE_LOG" \
  && ! grep -Eq 'crates/cli|cargo (check|test|doc)|npm|--workspace|--target ' "$COMPILE_LOG" \
  && ok "Rust checks select the touched crate, clippy alone compiling it, and omit full suites" \
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
[ "$RC" -eq 0 ] && grep -Fxq 'cargo clippy --workspace --all-targets --quiet -- -D warnings' "$COMPILE_LOG" \
  && ! grep -Eq 'cargo (check|test|doc)' "$COMPILE_LOG" \
  && ok "shared Rust inputs compile the workspace with clippy alone, without running tests" \
  || bad "shared Rust input scheduling" "rc=$RC out=$OUT calls=$(cat "$COMPILE_LOG")"
git -C "$R" reset -q HEAD -- Cargo.toml
git -C "$R" checkout -q -- Cargo.toml
# An underivable reader is a finding, and every path an input: all compiles.
printf '#!/usr/bin/env bash\n[ "${FAIL_FIND:-0}" = 1 ] && [ "$1" = crates ] && [ "${5:-}" = "*.rs" ] && exit 1\nexec %s "$@"\n' \
  "$(command -v find)" >"$R/fake-bin/find"
chmod +x "$R/fake-bin/find"
mkdir -p "$R/packaging"
printf 'data\n' >"$R/packaging/recipe.txt"
git -C "$R" add packaging/recipe.txt
unreadable_inputs() { # [GUARD] — the staged recipe with the reader failing; sets OUT and RC
  : >"$COMPILE_LOG"
  GUARD="${1:-$GUARD}" run_guard PATH="$R/fake-bin:$PATH" COMPILE_LOG="$COMPILE_LOG" FAIL_FIND=1
}
unreadable_inputs
[ "$RC" -eq 1 ] && [[ "$OUT" == *"guard: rust-reads=crates"* ]] \
  && grep -Fxq 'cargo clippy --workspace --all-targets --quiet -- -D warnings' "$COMPILE_LOG" \
  && ok "an underivable set of shared inputs is a finding, and the workspace compiles" \
  || bad "an underivable set of shared inputs is a finding, and the workspace compiles" "rc=$RC out=$OUT calls=$(cat "$COMPILE_LOG")"
if mutant_guard '/^  workspace_every=1$/d'; then
  unreadable_inputs "$MUTANT_TOOLS/guard"
  grep -Fxq 'cargo clippy --workspace --all-targets --quiet -- -D warnings' "$COMPILE_LOG" \
    && bad "control: with every path no longer an input the recipe compiles nothing" "calls=$(cat "$COMPILE_LOG")" \
    || ok "control: with every path no longer an input the recipe compiles nothing"
else
  bad "control: the fail-closed input could not be cut from a guard copy"
fi
git -C "$R" reset -q HEAD -- packaging/recipe.txt
rm -f -- "$R/packaging/recipe.txt"

echo "=== the CLI draws through its ui module ==="
# Each row plants one line in one CLI source file and runs guard over it.
# The table counts its own rows: an emptied row list is a red, never a green.
raw_output_case() { # pass|refuse LABEL PATH SOURCE-LINE
  local expected=$1 label=$2 path=$3
  mkdir -p "$(dirname "$R/$path")"
  printf '%s\n' "$4" >"$R/$path"
  git -C "$R" add -- "$path"
  : >"$COMPILE_LOG"
  run_guard PATH="$R/fake-bin:$PATH" COMPILE_LOG="$COMPILE_LOG"
  if [ "$expected" = refuse ] && [ "$RC" -ne 0 ] && [[ "$OUT" == *"guard: cli-raw-output=1"* ]]; then
    ok "$label"
  elif [ "$expected" = pass ] && [ "$RC" -eq 0 ] && [[ "$OUT" != *cli-raw-output* ]]; then
    ok "$label"
  else
    bad "$label" "rc=$RC out=$OUT"
  fi
  git -C "$R" rm -q --cached -- "$path"
  rm -f -- "$R/$path"
}
before=$((PASS + FAIL))
while IFS='|' read -r expected label path line; do
  raw_output_case "$expected" "$label" "$path" "$line"
done <<'ROWS'
refuse|an escape spelled \x1b in a verb is refused|crates/cli/src/commands/paint.rs|const RED: &str = "\x1b[31m";
refuse|an escape spelled \u{1b} in a verb is refused|crates/cli/src/commands/paint.rs|const RED: &str = "\u{1b}[31m";
refuse|an escape spelled \033 in a verb is refused|crates/cli/src/commands/paint.rs|const RED: &str = "\033[31m";
refuse|a stderr handle in a verb is refused|crates/cli/src/commands/paint.rs|fn say() { let _ = writeln!(std::io::stderr(), "x"); }
refuse|a stdout handle in a verb is refused|crates/cli/src/commands/paint.rs|fn say() { let _ = writeln!(std::io::stdout(), "x"); }
pass|an escape inside the ui module passes|crates/cli/src/ui/paint.rs|const RED: &str = "\x1b[31m";
pass|a stream handle in the ui module's root passes|crates/cli/src/ui.rs|fn say() { let _ = writeln!(std::io::stderr(), "x"); }
ROWS
[ "$((PASS + FAIL))" -gt "$before" ] || { echo "no row was asserted: the CLI output rule" >&2; exit 2; }

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
