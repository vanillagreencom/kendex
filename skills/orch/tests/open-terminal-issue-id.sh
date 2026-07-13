#!/usr/bin/env bash
# Regression tests for open-terminal issue-id validation and case normalization.
#
# Bug 1 (vstack#507): open-terminal force-uppercased the item before matching
# GH_ISSUE_PATTERN, so lowercase-convention projects (e.g. cc-[0-9]+) rejected
# every id. It must now validate case-insensitively and normalize to whichever
# case the configured pattern accepts.
#
# The test runs a byte-identical copy of open-terminal inside a temp git repo so
# `git rev-parse --show-toplevel` resolves to a hermetic PROJECT_ROOT, and stubs
# the worktree CLI, GUI terminal, and gh so nothing external is launched.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
SRC_OT="$SCRIPTS_DIR/open-terminal"
SRC_LIB="$SCRIPTS_DIR/lib/vstack-env.sh"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

assert_eq() {
  local got="$1" want="$2" name="$3"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  fi
}

# Shared stub bin: a fake GUI terminal (exit 0 so open_gui's success echo runs)
# and a fake gh (exit 1 so resolve_repo yields empty without touching network).
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/ghostty" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BIN/ghostty" "$BIN/gh"

# Stub worktree CLI: `create <item>` makes and prints a temp dir.
STUB="$TMP_ROOT/worktree-stub"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "create" ]]; then
  d="$TMP_ROOT/wt/\${2:-unknown}"
  mkdir -p "\$d"
  printf '%s\n' "\$d"
  exit 0
fi
echo "unexpected worktree stub call: \$*" >&2
exit 1
EOF
chmod +x "$STUB"

# Build a temp git repo containing a copy of open-terminal + its lib, so the
# script's PROJECT_ROOT resolves to this repo. $2 optional settings body.
make_ot_repo() {
  local repo="$1" settings="${2:-}"
  mkdir -p "$repo/scripts/lib"
  cp "$SRC_OT" "$repo/scripts/open-terminal"
  cp "$SRC_LIB" "$repo/scripts/lib/vstack-env.sh"
  chmod +x "$repo/scripts/open-terminal"
  git -C "$repo" init -q
  if [[ -n "$settings" ]]; then
    printf '%s\n' "$settings" > "$repo/vstack.settings.toml"
  fi
  printf '%s\n' "$repo/scripts/open-terminal"
}

echo "=== open-terminal issue-id normalization ==="

# Repo A: no project settings -> built-in default pattern [A-Z]+-[0-9]+.
REPO_A="$TMP_ROOT/repo-a"
OT_A="$(make_ot_repo "$REPO_A")"

# Case 1: default pattern normalizes lowercase and uppercase input to uppercase.
set +e
c1a_out=$(PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT_A" --ghostty --cmd 'echo {item}' cc-737 2>"$TMP_ROOT/c1a.err")
c1a_code=$?
set -e
assert_eq "$c1a_code" "0" "default pattern: lowercase input accepted"
assert_contains "$c1a_out" "Opened terminal 'CC-737'" "default pattern: cc-737 normalizes to CC-737"

set +e
c1b_out=$(PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT_A" --ghostty --cmd 'echo {item}' CC-737 2>"$TMP_ROOT/c1b.err")
c1b_code=$?
set -e
assert_eq "$c1b_code" "0" "default pattern: uppercase input accepted"
assert_contains "$c1b_out" "Opened terminal 'CC-737'" "default pattern: CC-737 stays CC-737"

# Repo B: project settings force an UNRELATED uppercase pattern. A parent-env
# GH_ISSUE_PATTERN of cc-[0-9]+ must win (Bug 2) and drive lowercase
# normalization (Bug 1); without the Bug 2 fix the settings pattern would win
# and both ids would be rejected.
REPO_B="$TMP_ROOT/repo-b"
OT_B="$(make_ot_repo "$REPO_B" '[env]
GH_ISSUE_PATTERN = "ZZ-[0-9]+"')"

# Case 2: lowercase pattern normalizes uppercase and lowercase input to lowercase.
set +e
c2a_out=$(GH_ISSUE_PATTERN='cc-[0-9]+' PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT_B" --ghostty --cmd 'echo {item}' CC-737 2>"$TMP_ROOT/c2a.err")
c2a_code=$?
set -e
assert_eq "$c2a_code" "0" "lowercase pattern (parent env wins over settings): uppercase input accepted"
assert_contains "$c2a_out" "Opened terminal 'cc-737'" "lowercase pattern: CC-737 normalizes to cc-737"

set +e
c2b_out=$(GH_ISSUE_PATTERN='cc-[0-9]+' PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT_B" --ghostty --cmd 'echo {item}' cc-737 2>"$TMP_ROOT/c2b.err")
c2b_code=$?
set -e
assert_eq "$c2b_code" "0" "lowercase pattern: lowercase input accepted"
assert_contains "$c2b_out" "Opened terminal 'cc-737'" "lowercase pattern: cc-737 stays cc-737"

# Case 3: an id that matches no case of the default pattern is rejected.
set +e
c3_out=$(PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT_A" --ghostty --cmd 'echo {item}' 12ab 2>"$TMP_ROOT/c3.err")
c3_code=$?
set -e
assert_eq "$c3_code" "1" "invalid id exits nonzero"
assert_contains "$(cat "$TMP_ROOT/c3.err")" "Error: invalid issue id" "invalid id reports a clear error"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
