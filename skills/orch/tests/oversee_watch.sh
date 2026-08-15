#!/usr/bin/env bash
# Regression tests for orch/scripts/oversee-watch.
#
# oversee-watch is the overseer's single blocking watch: it loops until the
# fleet needs a hand and prints ONE `EVENT <kind> ...` line. Covered:
#   1.  pr-watch attention (non-zero rc) is the event; GH_REPO reaches pr-watch
#   2.  a matching branch merged at/after --since fires; a PR merged BEFORE
#       --since and a non-matching branch do not (since/regex controls)
#   3.  a listed lane window that no longer exists
#   4.  a lane pane showing a question prompt (pane tail follows)
#   5.  heartbeat after --max-loops with the open PR list
#   6.  gh auth failure exits 2; a failing pr list exits 2 (never a quiet 0)
#   7.  lanes given outside tmux exit 2
#   8.  a missing pr-watch.sh is a stderr note, not a failure
#   9.  --help exits 0
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0

dump_stderr() {
  local file="$1"
  [[ -n "$file" && -f "$file" ]] || return 0
  printf '        stderr:\n'
  sed 's/^/          /' "$file"
}

assert_eq() {
  local got="$1" want="$2" name="$3" stderr_file="${4:-}"
  if [[ "$got" == "$want" ]]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$name" "$want" "$got"
    dump_stderr "$stderr_file"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" name="$3" stderr_file="${4:-}"
  if grep -qF -- "$needle" <<<"$haystack"; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        wanted substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    dump_stderr "$stderr_file"
  fi
}

assert_not_contains() {
  local haystack="$1" needle="$2" name="$3" stderr_file="${4:-}"
  if grep -qF -- "$needle" <<<"$haystack"; then
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        forbidden substring: %s\n        in: %s\n' "$name" "$needle" "$haystack"
    dump_stderr "$stderr_file"
  else
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$name"
  fi
}

mkdir -p "$TMP_ROOT/repo/.agents/skills" "$TMP_ROOT/bin" "$TMP_ROOT/cases"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/repo/.agents/skills/orch"
git -C "$TMP_ROOT/repo" init -q

# gh stub, driven by files in $STUB_DIR:
#   merged.json   body for `pr list --state merged` (default: [])
#   open.txt      lines for `pr list --state open` (default: empty)
#   auth-fail     present → `auth status` fails
#   list-fail     present → every `pr list` fails
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-} ${2:-}" in
  "auth status")
    [[ -f "$STUB_DIR/auth-fail" ]] && { echo "You are not logged into any GitHub hosts." >&2; exit 1; }
    echo "Logged in"; exit 0 ;;
  "repo view")
    echo "owner/repo"; exit 0 ;;
  "pr list")
    printf '%s\n' "$*" >> "$STUB_DIR/gh.calls"
    [[ -f "$STUB_DIR/list-fail" ]] && { echo "HTTP 502: bad gateway" >&2; exit 1; }
    for a in "$@"; do
      if [[ "$a" == "merged" ]]; then
        [[ -f "$STUB_DIR/merged.json" ]] && cat "$STUB_DIR/merged.json" || echo '[]'
        exit 0
      fi
    done
    [[ -f "$STUB_DIR/open.txt" ]] && cat "$STUB_DIR/open.txt"
    exit 0 ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF

# tmux stub: windows.txt lists window names; pane-<lane>.txt is a lane's screen.
cat > "$TMP_ROOT/bin/tmux" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-}" in
  list-windows) cat "$STUB_DIR/windows.txt"; exit 0 ;;
  capture-pane)
    lane=""
    while [[ $# -gt 0 ]]; do [[ "$1" == "-t" ]] && lane="$2"; shift; done
    [[ -f "$STUB_DIR/pane-$lane.txt" ]] || { echo "can't find window: $lane" >&2; exit 1; }
    cat "$STUB_DIR/pane-$lane.txt"; exit 0 ;;
esac
printf 'unexpected tmux call: %s\n' "$*" >&2
exit 1
EOF

# Fake pr-watch: records GH_REPO, prints prwatch.out, exits with prwatch.rc.
cat > "$TMP_ROOT/bin/pr-watch-stub.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${GH_REPO:-<unset>}" > "$STUB_DIR/prwatch.repo"
[[ -f "$STUB_DIR/prwatch.out" ]] && cat "$STUB_DIR/prwatch.out"
rc=0; [[ -f "$STUB_DIR/prwatch.rc" ]] && rc="$(cat "$STUB_DIR/prwatch.rc")"
exit "$rc"
EOF
chmod +x "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/tmux" "$TMP_ROOT/bin/pr-watch-stub.sh"

STUB_DIR=""
new_case() {
  STUB_DIR="$TMP_ROOT/cases/$1"
  rm -rf "$STUB_DIR"
  mkdir -p "$STUB_DIR"
  printf 'gh-1\ngh-2\n' > "$STUB_DIR/windows.txt"
  printf '⏺ working on it\n' > "$STUB_DIR/pane-gh-1.txt"
  printf '⏺ working on it\n' > "$STUB_DIR/pane-gh-2.txt"
}

# run_watch [ENV=VAL ...] -- ARGS...   (fast cadence; TMUX set unless NO_TMUX=1)
run_watch() {
  local env_args=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do env_args+=("$1"); shift; done
  shift || true
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN \
           STUB_DIR="$STUB_DIR" TMUX="fake" \
           OVERSEE_WATCH_PR_WATCH="$TMP_ROOT/bin/pr-watch-stub.sh" \
           "${env_args[@]}" \
           .agents/skills/orch/scripts/oversee-watch --interval 0 --max-loops 2 --repo owner/repo "$@")
}

echo "=== oversee-watch ==="

# --- 1. pr-watch attention -------------------------------------------------
new_case prwatch
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "pr-watch attention exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" "first line is the pr-watch event" "$err"
assert_contains "$out" "threads-open" "pr-watch output follows the event line" "$err"
assert_eq "$(cat "$STUB_DIR/prwatch.repo")" "owner/repo" "GH_REPO is exported to pr-watch" "$err"

# --- 2. merged, with since and regex controls ------------------------------
new_case merged
cat > "$STUB_DIR/merged.json" <<'EOF'
[
  {"number": 5, "headRefName": "issue-5",   "mergedAt": "2026-08-15T10:00:00Z"},
  {"number": 6, "headRefName": "issue-6",   "mergedAt": "2026-08-15T08:00:00Z"},
  {"number": 7, "headRefName": "feature-x", "mergedAt": "2026-08-15T10:30:00Z"},
  {"number": 8, "headRefName": "VST-8",     "mergedAt": "2026-08-15T09:00:00Z"}
]
EOF
err="$TMP_ROOT/e2"
out="$(run_watch -- --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "merged exits 0" "$err"
assert_contains "$out" "EVENT merged 5 issue-5" "PR merged after --since fires" "$err"
assert_contains "$out" "EVENT merged 8 VST-8" "PR merged exactly at --since fires (Linear-style branch)" "$err"
assert_not_contains "$out" "EVENT merged 6" "PR merged before --since does not fire" "$err"
assert_not_contains "$out" "EVENT merged 7" "non-matching branch does not fire" "$err"
assert_eq "$(grep -c '^EVENT' <<<"$out")" "2" "one EVENT line per merged PR, nothing else" "$err"

# --- 3. window-gone --------------------------------------------------------
new_case window_gone
printf 'gh-1\n' > "$STUB_DIR/windows.txt"
err="$TMP_ROOT/e3"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "window-gone exits 0" "$err"
assert_eq "$out" "EVENT window-gone gh-2" "missing lane window is the event" "$err"

# --- 4. question -----------------------------------------------------------
new_case question
{
  printf '⏺ I found two ways to do this.\n\n'
  printf 'Do you want to proceed?\n'
  printf '❯ 1. Yes\n  2. No\n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e4"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "question exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT question gh-2" "lane with a question prompt is the event" "$err"
assert_contains "$out" "❯ 1. Yes" "pane tail follows the event line" "$err"
assert_not_contains "$out" "gh-1" "a working lane is not reported" "$err"

# --- 5. heartbeat ----------------------------------------------------------
new_case heartbeat
printf '9\tissue-9\tfix the thing\n' > "$STUB_DIR/open.txt"
err="$TMP_ROOT/e5"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "heartbeat exits 0" "$err"
assert_contains "$out" "EVENT heartbeat" "heartbeat after --max-loops with no event" "$err"
assert_contains "$out" "issue-9" "open PR list follows the heartbeat" "$err"
assert_eq "$(grep -c 'merged' "$STUB_DIR/gh.calls")" "2" "merged check ran once per loop (2 loops)" "$err"

# --- 6. global failures exit 2 ---------------------------------------------
new_case auth_fail
touch "$STUB_DIR/auth-fail"
err="$TMP_ROOT/e6a"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "gh auth failure exits 2" "$err"
assert_contains "$(cat "$err")" "no working GitHub auth path" "auth failure is named on stderr"
assert_eq "$out" "" "auth failure prints no EVENT" "$err"

new_case list_fail
touch "$STUB_DIR/list-fail"
err="$TMP_ROOT/e6b"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "failing pr list exits 2" "$err"
assert_contains "$(cat "$err")" "gh pr list --state merged failed" "pr list failure is named on stderr"

# --- 7. lanes outside tmux -------------------------------------------------
new_case no_tmux
err="$TMP_ROOT/e7"
out="$(run_watch TMUX= -- gh-1 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "lanes without \$TMUX exit 2" "$err"
assert_contains "$(cat "$err")" "not inside tmux" "missing tmux is named on stderr"

# --- 8. missing pr-watch is a note, not a failure ---------------------------
new_case no_prwatch
err="$TMP_ROOT/e8"
out="$(run_watch OVERSEE_WATCH_PR_WATCH="$TMP_ROOT/nope/pr-watch.sh" -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "missing pr-watch still watches (heartbeat)" "$err"
assert_contains "$out" "EVENT heartbeat" "missing pr-watch reaches the heartbeat" "$err"
assert_contains "$(cat "$err")" "pr-watch.sh not found" "missing pr-watch is noted once on stderr"
assert_eq "$(grep -c 'pr-watch.sh not found' "$err")" "1" "note printed exactly once, not per loop"

# --- 9. --help -------------------------------------------------------------
err="$TMP_ROOT/e9"
out="$(run_watch -- --help 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "--help exits 0" "$err"
assert_contains "$out" "EVENT question" "--help documents the event kinds" "$err"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
