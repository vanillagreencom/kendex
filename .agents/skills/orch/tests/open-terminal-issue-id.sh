#!/usr/bin/env bash
# Tests for open-terminal issue-id validation and canonicalization.
#
# open-terminal validates the item against GH_ISSUE_PATTERN case-insensitively,
# so a lowercase-convention project (e.g. cc-[0-9]+) is accepted, and then emits
# the tracker's canonical spelling. The brief the lane receives names the item
# the way the overseer's watch and sends do, so a lane's mailbox and status file
# land where they are read on a case-sensitive disk.
#
# The test runs a byte-identical copy of open-terminal inside a temp git repo so
# `git rev-parse --show-toplevel` resolves to a hermetic PROJECT_ROOT, and stubs
# the worktree CLI, GUI terminal, and gh so nothing external is launched.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# An inherited or configured lane host would turn these local launches into
# hosted ones; the caller environment outranks project settings.
export ORCH_LANE_HOST=local
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
SRC_OT="$SCRIPTS_DIR/open-terminal"
SRC_LIB_DIR="$SCRIPTS_DIR/lib"
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
[[ -z "${OT_CAPTURE:-}" ]] || printf '%s\n' "${!#}" >"$OT_CAPTURE"
exit 0
EOF
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
exit 1
EOF
chmod +x "$BIN/ghostty" "$BIN/gh"

# $TERMINAL is what open_gui reaches for first, so it is PINNED to the stub on
# PATH here: unset, the branch below it would resolve whatever terminal the
# developer's desktop provides and this suite would open real windows.
export TERMINAL=ghostty

# Stub worktree CLI: `create <item>` makes and prints a temp dir.
STUB="$TMP_ROOT/worktree-stub"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
set -euo pipefail
if [[ "\${1:-}" == "create" ]]; then
  d="$TMP_ROOT/wt/\${2:-unknown}"
  mkdir -p "\$d"
  git init -q "\$d"
  printf '%s\n' "\$d"
  exit 0
fi
echo "unexpected worktree stub call: \$*" >&2
exit 1
EOF
chmod +x "$STUB"

# Build a temp git repo containing a copy of open-terminal + its libs, so the
# script's PROJECT_ROOT resolves to this repo. $2 optional settings body.
make_ot_repo() {
  local repo="$1" settings="${2:-}"
  mkdir -p "$repo/scripts/lib"
  cp "$SRC_OT" "$repo/scripts/open-terminal"
  cp "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/git-context" "$repo/scripts/"
  cp "$SRC_LIB_DIR"/*.sh "$repo/scripts/lib/"
  orch_fixture_shared_libs "$repo"
  chmod +x "$repo/scripts/open-terminal"
  git -C "$repo" init -q
  if [[ -n "$settings" ]]; then
    printf '%s\n' "$settings" > "$repo/kendex.settings.toml"
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
assert_contains "$c1a_out" "open-terminal: terminal-opened item=CC-737" "default pattern: cc-737 normalizes to CC-737"

set +e
c1b_out=$(PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT_A" --ghostty --cmd 'echo {item}' CC-737 2>"$TMP_ROOT/c1b.err")
c1b_code=$?
set -e
assert_eq "$c1b_code" "0" "default pattern: uppercase input accepted"
assert_contains "$c1b_out" "open-terminal: terminal-opened item=CC-737" "default pattern: CC-737 stays CC-737"

# Repo B: project settings force an UNRELATED uppercase pattern. A parent-env
# GH_ISSUE_PATTERN of cc-[0-9]+ must win over it, and a settings pattern that
# won would reject both ids.
REPO_B="$TMP_ROOT/repo-b"
OT_B="$(make_ot_repo "$REPO_B" '[env]
GH_ISSUE_PATTERN = "ZZ-[0-9]+"')"

# Case 2: a lowercase pattern accepts either case and still emits the canonical
# item, which is what the window name, the worktree id and the brief all carry.
for row in CC-737 cc-737; do
  set +e
  c2_out=$(GH_ISSUE_PATTERN='cc-[0-9]+' PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT_B" --ghostty --cmd 'echo {item}' "$row" 2>"$TMP_ROOT/c2-$row.err")
  c2_code=$?
  set -e
  assert_eq "$c2_code" "0" "lowercase pattern: $row accepted"
  assert_contains "$c2_out" "open-terminal: terminal-opened item=CC-737" "lowercase pattern: $row is emitted as CC-737"
done

# Case 2c: the brief itself, the only path a hosted lane learns its item on.
# The stub terminal records the launch line; the brief rides in it as the
# claude CLI's initial prompt.
set +e
GH_ISSUE_PATTERN='cc-[0-9]+' OT_CAPTURE="$TMP_ROOT/c2c.cmd" PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT_B" --ghostty --harness claude cc-737 >/dev/null 2>"$TMP_ROOT/c2c.err"
c2c_code=$?
set -e
assert_eq "$c2c_code" "0" "lowercase pattern: a brief-rendering launch succeeds"
# The stub terminal is launched detached, so its write races this read.
for _ in {1..200}; do [[ -f "$TMP_ROOT/c2c.cmd" ]] && break; sleep 0.05; done
assert_contains "$(cat "$TMP_ROOT/c2c.cmd" 2>/dev/null)" "/orch start CC-737" "the brief names the canonical item, never the pattern's case"

# Case 3: an id that matches no case of the default pattern is rejected.
set +e
c3_out=$(PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT_A" --ghostty --cmd 'echo {item}' 12ab 2>"$TMP_ROOT/c3.err")
c3_code=$?
set -e
assert_eq "$c3_code" "1" "invalid id exits nonzero"
c3_error="$(grep '^open-terminal: issue-invalid ' "$TMP_ROOT/c3.err" || true)"
assert_eq "$c3_error" "open-terminal: issue-invalid item=12ab" "invalid id reports a clear error"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
