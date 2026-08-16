#!/usr/bin/env bash
# Pins tools/validate-changed: the changed-path -> lane derivation for every
# row of its table (via --dry-run against a scratch git repo), the base
# resolution (committed + uncommitted + untracked; --base REF; --all), and
# the runner's fail-closed contract (every selected lane runs, failures are
# named in a FAILED LANES block, a missing suite path is a failure).
#
# Controls: a docs-only change derives NO suite lane; a workflow change
# derives every lane.
#
# errexit is on: a broken fixture step aborts loudly instead of cascading
# into misleading assertion failures; the helpers below never fail the
# script themselves.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/../validate-changed"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

pass=0
fail=0
ok() { pass=$((pass + 1)); }
ko() { fail=$((fail + 1)); echo "FAIL: $*"; }

# --- assertion helpers -------------------------------------------------------
# $OUT holds the last run's stdout; $RC its exit status.
OUT=""
RC=0
run() { # args... -> OUT/RC from the script run inside the scratch repo
  RC=0
  OUT="$(cd "$REPO" && bash "$SCRIPT" "$@" 2>&1)" || RC=$?
}
has_lane() { # id -> the plan lists lane id
  printf '%s\n' "$OUT" | grep -Eq "^  lane: $1( |\$)"
}
assert_lane() { # case id
  if has_lane "$2"; then ok; else ko "$1: expected lane '$2' in:"$'\n'"$OUT"; fi
}
assert_no_lane() { # case id-or-prefix-regex
  if printf '%s\n' "$OUT" | grep -Eq "^  lane: $2"; then ko "$1: unexpected lane matching '$2' in:"$'\n'"$OUT"; else ok; fi
}
assert_line() { # case fixed-string
  if printf '%s\n' "$OUT" | grep -qF -- "$2"; then ok; else ko "$1: expected line '$2' in:"$'\n'"$OUT"; fi
}
assert_no_line() { # case fixed-string
  if printf '%s\n' "$OUT" | grep -qF -- "$2"; then ko "$1: unexpected line '$2' in:"$'\n'"$OUT"; else ok; fi
}
assert_rc() { # case expected
  if [ "$RC" -eq "$2" ]; then ok; else ko "$1: expected exit $2, got $RC:"$'\n'"$OUT"; fi
}
# Only the always-on lanes: exactly two `lane:` lines, both always:*.
assert_only_always() { # case
  local n
  n="$(printf '%s\n' "$OUT" | grep -c '^  lane: ' || true)"
  if [ "$n" -eq 2 ] && has_lane always:preflight && has_lane always:gate-selftest; then ok; else ko "$1: expected only the two always-on lanes, got:"$'\n'"$OUT"; fi
}

# --- scratch repo --------------------------------------------------------------
REPO="$TMP/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" symbolic-ref HEAD refs/heads/main
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false

mkfile() { # path [content] -> writes a file, creating parents
  mkdir -p "$(dirname "$REPO/$1")"
  printf '%s\n' "${2:-x}" >"$REPO/$1"
}
mkexec() { # path content -> executable file
  mkfile "$1" "$2"
  chmod +x "$REPO/$1"
}

# Fixture tree: one skill with tests, one without, the name-keyed skills
# (orch runner, review-gate, deep-research node), hooks, cli, tools, one pi
# extension with a CI suite and one without, docs, workflows. The always-on
# checks and every suite are stubs that exit 0 so the runner cases can pass.
mkexec skills/withtests/tests/a.test.sh '#!/usr/bin/env bash
exit 0'
mkfile skills/withtests/SKILL.md 'report via vstack report'
mkfile skills/notests/SKILL.md 'report via vstack report'
mkfile skills/notests/scripts/lib/helper.sh 'x'
mkexec skills/orch/tests/run-all.sh '#!/usr/bin/env bash
exit 0'
mkexec skills/orch/tests/a.sh '#!/usr/bin/env bash
exit 0'
mkfile skills/orch/scripts/thing 'x'
chmod +x "$REPO/skills/orch/scripts/thing"
mkexec skills/review-gate/tests/a.sh '#!/usr/bin/env bash
exit 0'
mkexec skills/review-gate/scripts/review-predicate-selftest.sh '#!/usr/bin/env bash
echo selftest-stub
exit 0'
mkexec skills/preflight/scripts/preflight '#!/usr/bin/env bash
echo "preflight-stub $*"
exit 0'
mkexec skills/preflight/tests/a.test.sh '#!/usr/bin/env bash
exit 0'
mkexec skills/linear/tests/a.test.sh '#!/usr/bin/env bash
exit 0'
mkexec skills/github/tests/a.test.sh '#!/usr/bin/env bash
exit 0'
mkexec skills/reviewer/tests/a.test.sh '#!/usr/bin/env bash
exit 0'
mkexec skills/project-management/tests/a.test.sh '#!/usr/bin/env bash
exit 0'
mkfile skills/deep-research/tests/deep-research.test.mjs '// stub'
mkfile skills/deep-research/SKILL.md 'report via vstack report'
mkexec hooks/tests/h.test.sh '#!/usr/bin/env bash
exit 0'
mkfile hooks/some-hook.sh 'x'
mkfile cli/Cargo.toml '[package]'
mkfile cli/src/main.rs 'fn main() {}'
mkexec cli/scripts/integration-check.sh '#!/usr/bin/env bash
exit 0'
mkexec tools/tests/t.test.sh '#!/usr/bin/env bash
exit 0'
mkexec tools/validate-changed '#!/usr/bin/env bash
# placeholder for the tool itself'
mkfile pi-extensions/pi-qol/index.ts 'x'
mkfile pi-extensions/pi-output-policy/index.ts 'x'
mkfile pi-extensions/pi-agents-tmux/index.ts 'x'
mkfile pi-extensions/pi-codex-minimal-tools/index.ts 'x'
mkfile pi-extensions/pi-questions/index.ts 'x'
mkfile pi-extensions/pi-claude-bridge/index.ts 'x'
mkfile pi-extensions/pi-nosuite/index.ts 'x'
mkfile pi-extensions/pi-session-bridge/extensions/child-session-id.ts 'x'
mkfile pi-extensions/package-policy.test.mjs 'x'
mkfile docs/guide.md 'x'
mkfile agents/rust.md 'x'
mkfile README.md 'x'
mkfile CHANGELOG.md 'x'
mkfile AGENTS.md 'x'
mkfile vstack.settings.toml.example '[env]'
mkfile vstack.settings.toml '[env]'
mkfile .github/workflows/skill-tests.yml 'name: x'
mkfile .github/workflows/other.yml 'name: y'
mkfile .github/instructions/x.md 'x'
git -C "$REPO" add -A
git -C "$REPO" commit -qm base

touch_path() { printf 'changed\n' >>"$REPO/$1"; }
reset_tree() {
  git -C "$REPO" reset -q --hard
  git -C "$REPO" clean -fdq
  git -C "$REPO" checkout -q main
}

# --- 0. clean tree: nothing changed -> only the always-on lanes -----------
run --dry-run
assert_rc "clean tree" 0
assert_only_always "clean tree"
assert_line "clean tree" "0 changed path(s)"
assert_no_line "clean tree" "all lanes:"

# --- 1. CONTROL: docs-only change derives NO suite lane -----------------
touch_path docs/guide.md
touch_path README.md
touch_path CHANGELOG.md
touch_path AGENTS.md
touch_path .github/instructions/x.md
mkfile docs/new-untracked.md 'new'
run --dry-run
assert_rc "docs-only" 0
assert_only_always "docs-only"
assert_line "docs-only" "no suite lane: docs/guide.md"
assert_line "docs-only" "no suite lane: docs/new-untracked.md"
assert_line "docs-only" "no suite lane: .github/instructions/x.md"
assert_no_line "docs-only" "all lanes:"
assert_line "docs-only" "6 changed path(s)"
reset_tree

# A changed path containing a newline cannot be derived from: fail closed.
mkfile "docs/bad
name.md" 'x'
run --dry-run
assert_rc "newline in path" 2
assert_line "newline in path" "a changed path contains a newline"
reset_tree

# --- 2. skills/<name>/** with tests -----------------------------------------
touch_path skills/withtests/SKILL.md
run --dry-run
assert_lane "skill with tests" "skill:withtests"
assert_line "skill with tests" "bash skills/withtests/tests/*.sh (1 file(s))"
assert_lane "skill with tests" "lint:shell"
assert_lane "skill with tests" "skill:orch"
assert_no_lane "skill with tests" "skill:(github|reviewer|project-management)"
assert_no_lane "skill with tests" "hooks"
assert_no_lane "skill with tests" "cli:"
assert_no_lane "skill with tests" "pi:"
assert_no_lane "skill with tests" "tools"
assert_no_line "skill with tests" "no suite lane:"
reset_tree

# --- 3. skills/<name>/** without tests -> no suite lane -----------------------
touch_path skills/notests/SKILL.md
run --dry-run
assert_no_lane "skill without tests" "skill:notests"
assert_lane "skill without tests" "skill:orch"
assert_lane "skill without tests" "lint:shell"
assert_line "skill without tests" "no suite lane: skills/notests/SKILL.md (skills/notests has no tests)"
reset_tree

# A new, untracked test file makes the skill testable — the derivation reads
# the working tree, not just the index.
mkexec skills/notests/tests/new.test.sh '#!/usr/bin/env bash
exit 0'
run --dry-run
assert_lane "untracked new test file" "skill:notests"
reset_tree

# --- 4. orch -> its runner, never the bare glob --------------------------------
touch_path skills/orch/scripts/thing
run --dry-run
assert_lane "orch" "skill:orch"
assert_line "orch" "bash skills/orch/tests/run-all.sh"
assert_no_line "orch" "bash skills/orch/tests/*.sh"
assert_lane "orch" "skill:github"
assert_lane "orch" "skill:reviewer"
assert_no_lane "orch" "skill:project-management"
reset_tree

# --- 5. review-gate -> its tests/*.sh -----------------------------------------
touch_path skills/review-gate/tests/a.sh
run --dry-run
assert_lane "review-gate" "skill:review-gate"
assert_line "review-gate" "bash skills/review-gate/tests/*.sh (1 file(s))"
reset_tree

# --- 6. deep-research -> node suite -------------------------------------------
touch_path skills/deep-research/SKILL.md
run --dry-run
assert_lane "deep-research" "node:deep-research"
assert_line "deep-research" "node --test skills/deep-research/tests/deep-research.test.mjs"
assert_no_lane "deep-research" "skill:deep-research"
reset_tree

# --- 7. hooks/** ---------------------------------------------------------------
touch_path hooks/some-hook.sh
run --dry-run
assert_lane "hooks" "hooks"
assert_line "hooks" "bash hooks/tests/*.sh"
assert_lane "hooks" "lint:shell"
assert_no_lane "hooks" "skill:"
reset_tree

# --- 8. cli/** -> cargo test + integration check (AGENTS.md requires both) -----
touch_path cli/src/main.rs
run --dry-run
assert_lane "cli" "cli:cargo-test"
assert_line "cli" "cargo test --manifest-path cli/Cargo.toml"
assert_lane "cli" "cli:integration-check"
assert_line "cli" "cli/scripts/integration-check.sh"
assert_no_lane "cli" "lint:shell"
reset_tree

# --- 9. pi-extensions/<name>/** ------------------------------------------------
touch_path pi-extensions/pi-qol/index.ts
touch_path pi-extensions/pi-nosuite/index.ts
touch_path pi-extensions/package-policy.test.mjs
run --dry-run
assert_lane "pi-qol" "pi:pi-qol"
assert_line "pi-qol" "[pi-extensions/pi-qol]"
assert_no_lane "pi-qol" "pi:pi-output-policy"
assert_line "pi no suite" "no suite lane: pi-extensions/pi-nosuite/index.ts (CI runs no suite for pi-extensions/pi-nosuite)"
assert_line "pi top-level file" "no suite lane: pi-extensions/package-policy.test.mjs"
reset_tree

for ext in pi-output-policy pi-agents-tmux pi-codex-minimal-tools pi-questions pi-claude-bridge; do
  touch_path "pi-extensions/$ext/index.ts"
done
run --dry-run
for ext in pi-output-policy pi-agents-tmux pi-codex-minimal-tools pi-questions pi-claude-bridge; do
  assert_lane "pi $ext" "pi:$ext"
done
assert_no_lane "pi five" "pi:pi-qol"
reset_tree

# pi-session-bridge has no suite of its own, but pi-agents-tmux's suite
# imports it: the change selects that lane.
touch_path pi-extensions/pi-session-bridge/extensions/child-session-id.ts
run --dry-run
assert_lane "pi-session-bridge" "pi:pi-agents-tmux"
assert_no_lane "pi-session-bridge" "pi:(pi-qol|pi-output-policy|pi-codex-minimal-tools|pi-questions|pi-claude-bridge)"
assert_line "pi-session-bridge" "no suite lane: pi-extensions/pi-session-bridge/extensions/child-session-id.ts (CI runs no suite for pi-extensions/pi-session-bridge)"
reset_tree

# --- 10. tools/** -> tools tests (not --all) -----------------------------------
touch_path tools/tests/t.test.sh
run --dry-run
assert_lane "tools tests" "tools"
assert_line "tools tests" "bash tools/tests/*.sh"
assert_no_line "tools tests" "all lanes:"
assert_no_lane "tools tests" "cli:"
reset_tree

# --- 11. vstack.settings.toml.example -> settings-example-sync owners ---------
touch_path vstack.settings.toml.example
run --dry-run
assert_lane "root template" "skill:orch"
assert_lane "root template" "skill:linear"
assert_lane "root template" "skill:review-gate"
assert_no_lane "root template" "skill:withtests"
reset_tree

# --- 11b. cross-suite reads: agents/** -> orch + reviewer; linear -> pm ------
touch_path agents/rust.md
run --dry-run
assert_lane "agents" "skill:orch"
assert_lane "agents" "skill:reviewer"
assert_no_lane "agents" "lint:shell"
assert_no_lane "agents" "skill:(github|project-management|withtests)"
assert_no_line "agents" "no suite lane:"
reset_tree

touch_path skills/linear/tests/a.test.sh
run --dry-run
assert_lane "linear" "skill:linear"
assert_lane "linear" "skill:project-management"
assert_lane "linear" "skill:orch"
assert_no_lane "linear" "skill:(github|reviewer)"
reset_tree

# A mapped suite with no tests is a lane that fails, never a silent skip.
rm -r "$REPO/skills/reviewer"
touch_path agents/rust.md
run
assert_rc "mapped suite missing" 1
assert_line "mapped suite missing" "FAILED: skill:reviewer — no suite files matched"
reset_tree

# --- 12. CONTROL: .github/workflows/** -> every lane -------------------------
touch_path .github/workflows/skill-tests.yml
run --dry-run
assert_rc "workflow change" 0
assert_line "workflow change" "all lanes: .github/workflows/skill-tests.yml changed"
for id in always:preflight always:gate-selftest lint:shell skill:withtests skill:orch skill:review-gate node:deep-research skill:preflight skill:linear skill:github skill:reviewer skill:project-management hooks tools cli:cargo-test cli:integration-check pi:pi-qol pi:pi-output-policy pi:pi-agents-tmux pi:pi-codex-minimal-tools pi:pi-questions pi:pi-claude-bridge; do
  assert_lane "workflow change" "$id"
done
assert_no_lane "workflow change" "skill:notests"
assert_no_line "workflow change" "no suite lane:"
reset_tree

touch_path .github/workflows/other.yml
run --dry-run
assert_line "other workflow" "all lanes: .github/workflows/other.yml changed"
reset_tree

# --- 13. tools/validate-changed itself -> every lane -------------------------
touch_path tools/validate-changed
run --dry-run
assert_line "tool itself" "all lanes: tools/validate-changed changed"
assert_lane "tool itself" "cli:integration-check"
reset_tree

# --- 14. --all on a clean tree -------------------------------------------------
run --dry-run --all
assert_rc "--all" 0
assert_line "--all" "all lanes: --all"
assert_lane "--all" "cli:integration-check"
assert_lane "--all" "pi:pi-claude-bridge"
assert_lane "--all" "skill:withtests"

# --- 15. base resolution: committed on a branch + uncommitted + --base --------
git -C "$REPO" checkout -q -b feature
touch_path skills/withtests/SKILL.md
git -C "$REPO" commit -qam "feat: skill change"
run --dry-run
assert_lane "committed on branch" "skill:withtests"
assert_line "committed on branch" "merge base of HEAD and main"
touch_path hooks/some-hook.sh
run --dry-run
assert_lane "committed + uncommitted" "skill:withtests"
assert_lane "committed + uncommitted" "hooks"
# --base HEAD scopes to the uncommitted change only.
run --dry-run --base HEAD
assert_lane "--base HEAD" "hooks"
assert_no_lane "--base HEAD" "skill:withtests"
assert_line "--base HEAD" "preflight --base HEAD"
run --dry-run --base does-not-exist
assert_rc "--base unresolvable" 2
assert_line "--base unresolvable" "does not resolve"
run --dry-run --bogus
assert_rc "unknown flag" 2
reset_tree
git -C "$REPO" branch -q -D feature

# origin/main wins over main when it exists.
git -C "$REPO" update-ref refs/remotes/origin/main main
run --dry-run
assert_line "origin/main preferred" "merge base of HEAD and origin/main"
git -C "$REPO" update-ref -d refs/remotes/origin/main

# --- 16. runner: every lane runs, passes -> exit 0 -----------------------------
touch_path skills/withtests/SKILL.md
run
assert_rc "runner pass" 0
assert_line "runner pass" "===== lane: always:preflight"
assert_line "runner pass" "preflight-stub --base main"
assert_line "runner pass" "selftest-stub"
assert_line "runner pass" "=== skills/withtests/tests/a.test.sh"
assert_line "runner pass" "all 5 lane(s) passed"
assert_no_line "runner pass" "FAILED"
reset_tree

# --- 17. runner: a failing suite is named twice, later lanes still run ---------
touch_path skills/withtests/SKILL.md
touch_path hooks/some-hook.sh
printf '#!/usr/bin/env bash\nexit 1\n' >"$REPO/skills/withtests/tests/a.test.sh"
run
assert_rc "runner fail" 1
assert_line "runner fail" "FAILED: skills/withtests/tests/a.test.sh"
assert_line "runner fail" "FAILED LANE: skill:withtests"
assert_line "runner fail" "FAILED LANES: skill:withtests"
assert_line "runner fail" "===== lane: hooks"
assert_no_line "runner fail" "lane(s) passed"
reset_tree

# --- 18. runner: a missing suite path fails closed ---------------------------
touch_path skills/orch/scripts/thing
rm "$REPO/skills/orch/tests/run-all.sh"
run
assert_rc "missing runner" 1
assert_line "missing runner" "FAILED: missing or not executable: skills/orch/tests/run-all.sh"
assert_line "missing runner" "FAILED LANES: skill:orch"
reset_tree

touch_path hooks/some-hook.sh
rm "$REPO/hooks/tests/h.test.sh"
run
assert_rc "missing hook suite" 1
assert_line "missing hook suite" "no suite files matched"
assert_line "missing hook suite" "FAILED LANES: hooks"
reset_tree

# A missing always-on check is a failure too, never a skip.
rm "$REPO/skills/review-gate/scripts/review-predicate-selftest.sh"
run
assert_rc "missing selftest" 1
assert_line "missing selftest" "FAILED LANES: always:gate-selftest"
reset_tree

# --- 19. runner: the shell lints run (exec bit + vstack report) --------------
touch_path skills/withtests/SKILL.md
chmod -x "$REPO/skills/withtests/tests/a.test.sh"
git -C "$REPO" update-index --chmod=-x skills/withtests/tests/a.test.sh
run
assert_rc "exec-bit lint" 1
assert_line "exec-bit lint" "not executable in git: skills/withtests/tests/a.test.sh"
assert_line "exec-bit lint" "FAILED LANE: lint:shell"
reset_tree

# A tracked executable whose bit was dropped only in the working tree (index
# still 100755) fails too: `git add` would record the missing bit.
touch_path skills/withtests/SKILL.md
chmod -x "$REPO/skills/withtests/tests/a.test.sh"
run
assert_rc "working-tree exec-bit lint" 1
assert_line "working-tree exec-bit lint" "not executable in working tree: skills/withtests/tests/a.test.sh"
assert_no_line "working-tree exec-bit lint" "not executable in git:"
reset_tree

printf 'no routing here\n' >"$REPO/skills/withtests/SKILL.md"
run
assert_rc "vstack report lint" 1
assert_line "vstack report lint" "missing \`vstack report\` guidance: skills/withtests/SKILL.md"
reset_tree

# Untracked files are linted by their filesystem mode / content: a new 0644
# script and a new SKILL.md without routing fail before they are ever added.
mkfile skills/withtests/scripts/new-script '#!/usr/bin/env bash'
mkfile skills/newskill/SKILL.md 'no routing here'
run
assert_rc "untracked lint" 1
assert_line "untracked lint" "not executable (untracked): skills/withtests/scripts/new-script"
assert_line "untracked lint" "missing \`vstack report\` guidance: skills/newskill/SKILL.md"
chmod +x "$REPO/skills/withtests/scripts/new-script"
printf 'report via vstack report\n' >"$REPO/skills/newskill/SKILL.md"
run
assert_rc "untracked lint fixed" 0
assert_no_line "untracked lint fixed" "not executable"
reset_tree

# --- 20. --help ------------------------------------------------------------------
run --help
assert_rc "--help" 0
assert_line "--help" "usage: tools/validate-changed"

echo "pass: $pass   fail: $fail"
[ "$fail" -eq 0 ]
