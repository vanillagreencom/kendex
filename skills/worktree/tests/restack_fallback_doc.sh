#!/usr/bin/env bash
# Doc-contract lint for vstack#661: the policy-blocked rebase fallback.
#
# Codex `approval_policy = never` rejects top-level `git rebase` porcelain with
# "approval required by policy, but AskForApproval is set to Never" — both
# direct and via sub-agent — so the worktree SKILL.md must document a
# policy-compatible route: the supported guarded restack path first, then an
# exact cherry-pick replay fallback (fetch → verified detach → ordered replay
# → branch move → pinned-lease push → setup refresh) with clean-worktree,
# remote-head, and ancestry verification.
#
# This lint asserts the section exists, carries every required step and
# conflict control, and that every fenced ```bash command in it stays a single
# simple command per Codex's classifier: one command per block, no `$(...)` or
# backtick substitution, no `;`/`&&`/`||`/pipelines, no env-assignment
# prefixes (GIT_EDITOR=... must be `-c core.editor=true` instead), no shell
# loops, no redirection, no raw `--force`, and no unpinned
# `--force-with-lease`. Placeholder tokens such as `<path>` are stripped
# before the redirection check so they never false-flag. The README must carry
# the one-line cross-reference; the orch-side pointer is asserted in
# skills/orch/tests/workflow_helpers.sh.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
SKILL_MD="$SKILL_DIR/SKILL.md"
README_MD="$SKILL_DIR/README.md"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

SECTION_HEADING='### Policy-blocked rebase (cherry-pick replay fallback)'

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    pass "$name"
  else
    fail "$name (missing: $needle)"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    fail "$name (unwanted: $needle)"
  else
    pass "$name"
  fi
}

# extract_section <file>
# Prints the fallback section body: everything after the exact heading line up
# to (excluding) the next `## ` / `### ` heading.
extract_section() {
  awk -v h="$SECTION_HEADING" '
    $0 == h { insec = 1; next }
    insec && (/^## / || /^### /) { exit }
    insec { print }
  ' "$1"
}

# lint_section <file> — scans fenced ```bash / ```sh blocks and emits one
# violation line per breach of the single-simple-command contract. Prose and
# inline code are never scanned. Placeholders like <path> are stripped before
# the redirection check.
lint_section() {
  awk -v f="$1" '
    /^[[:space:]]*```/ {
      if (infence == 0) {
        infence = 1
        lang = $0
        sub(/^[[:space:]]*```/, "", lang)
        gsub(/[[:space:]]/, "", lang)
        iscmd = (lang == "bash" || lang == "sh") ? 1 : 0
        count = 0
        blockstart = NR
      } else {
        if (iscmd && count > 1)
          printf "%s:%d: %d commands in one fenced block\n", f, blockstart, count
        infence = 0
        iscmd = 0
      }
      next
    }
    (infence && iscmd) {
      line = $0
      sub(/^[[:space:]]+/, "", line)
      if (line == "") next
      count++
      check = line
      gsub(/<[A-Za-z][A-Za-z0-9-]*>/, "", check)
      if (check ~ /[<>]/)
        printf "%s:%d: redirection or heredoc: %s\n", f, NR, line
      if (index(check, "$(") > 0 || index(check, "`") > 0)
        printf "%s:%d: command substitution: %s\n", f, NR, line
      if (check ~ /;/ || check ~ /&&/ || check ~ /\|\|/ || check ~ / \| /)
        printf "%s:%d: multi-command or pipeline: %s\n", f, NR, line
      if (check ~ /^[A-Za-z_][A-Za-z0-9_]*=/)
        printf "%s:%d: env-assignment prefix: %s\n", f, NR, line
      if (check ~ /^(for|while) /)
        printf "%s:%d: shell loop: %s\n", f, NR, line
      if (check ~ /--force([^-]|$)/)
        printf "%s:%d: raw --force: %s\n", f, NR, line
      if (check ~ /--force-with-lease([^=]|$)/)
        printf "%s:%d: unpinned --force-with-lease: %s\n", f, NR, line
    }
  ' "$1"
}

echo "=== worktree policy-blocked rebase fallback doc contract ==="

# --- Part a: the real docs carry the contract ------------------------------

if grep -qF -- "$SECTION_HEADING" "$SKILL_MD"; then
  pass "SKILL.md has the fallback section heading"
else
  fail "SKILL.md is missing the fallback section heading"
fi

SECTION="$(extract_section "$SKILL_MD")"
if [[ -n "$SECTION" ]]; then
  pass "fallback section has a body"
else
  fail "fallback section body is empty"
fi

SECTION_FILE="$TMP_ROOT/section.md"
printf '%s\n' "$SECTION" >"$SECTION_FILE"
violations="$(lint_section "$SECTION_FILE")"
if [[ -z "$violations" ]]; then
  pass "every fenced command is a single simple command"
else
  fail "fenced commands break the single-simple-command contract:"
  printf '%s\n' "$violations" | sed 's/^/          /'
fi

# Supported tool path is offered first.
assert_contains "$SECTION" 'create <ID> --reuse' "section routes to the supported reuse path first"
assert_contains "$SECTION" 'worktree restack continue|skip|abort <ID>' "section names the guarded restack controls"

# Required verification and replay steps, in policy-safe single-command form.
assert_contains "$SECTION" 'git -C <path> status --porcelain' "section verifies a clean worktree"
assert_contains "$SECTION" 'git -C <path> fetch origin' "section fetches current remote state"
assert_contains "$SECTION" 'git -C <path> rev-parse refs/remotes/origin/<branch>' "section records the observed remote head"
assert_contains "$SECTION" 'git -C <path> merge-base --is-ancestor <remote-oid> <branch>' "section verifies remote-head ancestry before replaying"
assert_contains "$SECTION" 'git -C <path> log --oneline --reverse origin/<default>..<branch>' "section lists the replay commits oldest first"
assert_contains "$SECTION" 'git -C <path> checkout --detach origin/<default>' "section detaches at the new base"
assert_contains "$SECTION" 'git -C <path> cherry-pick origin/<default>..<branch>' "section replays the unique commits as one range"
assert_contains "$SECTION" '-c core.editor=true cherry-pick --continue' "section continues via -c core.editor=true, not GIT_EDITOR"
assert_contains "$SECTION" 'cherry-pick --skip' "section documents the skip control"
assert_contains "$SECTION" 'cherry-pick --abort' "section documents the abort control"
assert_contains "$SECTION" 'git -C <path> merge-base --is-ancestor origin/<default> HEAD' "section verifies the replayed tip contains the new base"
assert_contains "$SECTION" 'git -C <path> branch -f <branch> HEAD' "section moves the branch ref only after the replay"
assert_contains "$SECTION" '--force-with-lease=refs/heads/<branch>:<remote-oid>' "section pins the push lease to the recorded remote OID"
assert_contains "$SECTION" 'worktree fix-links <ID>' "section restores worktree setup afterward"
assert_not_contains "$SECTION" 'GIT_EDITOR' "section never uses a GIT_EDITOR env prefix"

# Cross-reference: README points readers at the section.
if grep -qF -- 'Policy-blocked rebase (cherry-pick replay fallback)' "$README_MD"; then
  pass "README cross-references the fallback section"
else
  fail "README is missing the fallback section cross-reference"
fi

# --- Part b: the lint has teeth --------------------------------------------

# inject_block <descriptor> <body> → prints scratch-file path. Appends a
# fenced ```bash block containing <body> (printf %b, so embedded \n splits it
# into multiple command lines) to a scratch copy of the real, now-clean
# section body; any violation reported comes from the injected block alone.
inject_block() {
  local scratch="$TMP_ROOT/inject-$1.md"
  cp "$SECTION_FILE" "$scratch"
  printf '\n```bash\n%b\n```\n' "$2" >>"$scratch"
  printf '%s' "$scratch"
}

TWO_CMD='git -C <path> fetch origin\ngit -C <path> status --porcelain'
if [[ -n "$(lint_section "$(inject_block two "$TWO_CMD")")" ]]; then
  pass "lint flags two commands in one fenced block"
else
  fail "lint MISSED a two-command block (no teeth)"
fi

if [[ -n "$(lint_section "$(inject_block subst 'git push origin $(git branch --show-current)')")" ]]; then
  pass "lint flags command substitution"
else
  fail "lint MISSED command substitution"
fi

if [[ -n "$(lint_section "$(inject_block envprefix 'GIT_EDITOR=true git cherry-pick --continue')")" ]]; then
  pass "lint flags an env-assignment prefix"
else
  fail "lint MISSED an env-assignment prefix"
fi

if [[ -n "$(lint_section "$(inject_block rawforce 'git -C <path> push origin <branch> --force')")" ]]; then
  pass "lint flags a raw --force push"
else
  fail "lint MISSED a raw --force push"
fi

if [[ -n "$(lint_section "$(inject_block redirect 'git -C <path> log --oneline > tmp/commits.txt')")" ]]; then
  pass "lint flags redirection"
else
  fail "lint MISSED redirection"
fi

if [[ -n "$(lint_section "$(inject_block unpinned 'git -C <path> push origin <branch> --force-with-lease')")" ]]; then
  pass "lint flags an unpinned --force-with-lease"
else
  fail "lint MISSED an unpinned --force-with-lease"
fi

if [[ -z "$(lint_section "$(inject_block clean 'git -C <path> add <file>')")" ]]; then
  pass "lint accepts a clean single command with placeholders"
else
  fail "lint false-flagged a clean placeholder command"
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
