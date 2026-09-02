#!/usr/bin/env bash
# Regression tests for the codex kickoff prompt emitted by open-terminal.
#
# Bug (kendex#976): the codex arms emitted `codex '\$orch start <item>'`. The
# composed line crosses another quoting layer (e.g. an agent-confine wrapper)
# before the spawned window's shell runs it; once the single quotes were
# consumed, fish expanded the bare `$orch` to empty and errored, so codex
# launched with NO prompt argv and every fleet worker sat at an empty composer.
# Codex also has no /orch slash command, so the arms must deliver a plain-prose
# kickoff naming .agents/skills/orch/SKILL.md, built only from shell-inert
# characters — no `$`, backtick, or anything else a downstream shell layer
# could expand after one round of quote consumption.
#
# The test runs a byte-identical copy of open-terminal inside a temp git repo so
# `git rev-parse --show-toplevel` resolves to a hermetic PROJECT_ROOT, stubs the
# worktree CLI and gh, and stubs ghostty to capture the composed command it
# would launch.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

# The brief ends at the start command; start.md owns completion.
TC=""

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

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        forbidden substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

# Stub bin: ghostty captures its final argument — the composed `cd ... && codex
# ...` command open_gui hands to `bash -lc` — into $OT_CAPTURE; gh exits 1 so
# resolve_repo yields empty without touching the network (the github case
# passes --repo explicitly).
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/ghostty" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${!#}" > "$OT_CAPTURE"
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
  printf '%s\n' "\$d"
  exit 0
fi
echo "unexpected worktree stub call: \$*" >&2
exit 1
EOF
chmod +x "$STUB"

# Temp git repo containing a copy of open-terminal + its libs, so the script's
# PROJECT_ROOT resolves to this repo.
REPO="$TMP_ROOT/repo"
mkdir -p "$REPO/scripts/lib"
cp "$SRC_OT" "$REPO/scripts/open-terminal"
cp "$SRC_LIB_DIR"/*.sh "$REPO/scripts/lib/"
chmod +x "$REPO/scripts/open-terminal"
git -C "$REPO" init -q
OT="$REPO/scripts/open-terminal"

# open_gui launches the (stubbed) terminal via `setsid ... &`, so the capture
# file lands asynchronously after open-terminal itself has exited.
wait_capture() {
  local f="$1" i
  for i in $(seq 1 50); do
    [[ -s "$f" ]] && return 0
    sleep 0.1
  done
  return 1
}

echo "=== open-terminal codex kickoff prompt ==="

# Case 1: linear:codex — plain-prose kickoff carrying the item, with nothing a
# downstream shell layer could expand.
CAP1="$TMP_ROOT/cap1"
set +e
c1_out=$(OT_CAPTURE="$CAP1" PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --ghostty --harness codex cc-737 2>"$TMP_ROOT/c1.err")
c1_code=$?
set -e
assert_eq "$c1_code" "0" "linear:codex launch succeeds"
if wait_capture "$CAP1"; then
  c1_cmd="$(cat "$CAP1")"
  assert_contains "$c1_cmd" "codex 'Read .agents/skills/orch/SKILL.md and execute the orch start workflow for CC-737${TC}'" \
    "linear:codex emits the prose kickoff naming SKILL.md and the item"
  assert_not_contains "$c1_cmd" '$' "linear:codex command contains no \$"
  assert_not_contains "$c1_cmd" '`' "linear:codex command contains no backtick"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  linear:codex never invoked the terminal stub\n'
fi

# Case 2: github:codex — same prose shape carrying repo#item.
CAP2="$TMP_ROOT/cap2"
set +e
c2_out=$(OT_CAPTURE="$CAP2" PATH="$BIN:$PATH" WORKTREE_CLI="$STUB" "$OT" --tracker github --repo acme/widgets --ghostty --harness codex 42 2>"$TMP_ROOT/c2.err")
c2_code=$?
set -e
assert_eq "$c2_code" "0" "github:codex launch succeeds"
if wait_capture "$CAP2"; then
  c2_cmd="$(cat "$CAP2")"
  assert_contains "$c2_cmd" "codex 'Read .agents/skills/orch/SKILL.md and execute the orch start workflow for github acme/widgets#42${TC}'" \
    "github:codex emits the prose kickoff carrying repo#item"
  assert_not_contains "$c2_cmd" '$' "github:codex command contains no \$"
  assert_not_contains "$c2_cmd" '`' "github:codex command contains no backtick"
else
  FAIL=$((FAIL + 1))
  printf '  FAIL  github:codex never invoked the terminal stub\n'
fi

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
