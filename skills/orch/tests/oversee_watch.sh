#!/usr/bin/env bash
# Regression tests for orch/scripts/oversee-watch.
#
# oversee-watch is the overseer's single blocking watch: it loops until the
# fleet needs a hand and prints ONE `EVENT <kind> ...` line. Covered:
#   1.  pr-watch: on the fleet's first run attention present at start is a
#       baseline (no event, one stderr note, context on the next event); that
#       baseline persists, so a line appearing between two runs is the next
#       run's first-pass event and a standing line is not; a NEW `<pr> <kind>`
#       line mid-run is the event; a head-only change is not; GH_REPO reaches
#       pr-watch; rc≠0 with no lines is a global failure (exit 2); attention
#       at start does not starve a lane's question; the state file is
#       rewritten after every pass, and an uncreatable state dir or an
#       unreadable state file exits 2 naming the path
#   2.  merged: an --item's PR merged at/after --since fires; a PR merged
#       BEFORE --since, a non-item branch, and a non-item conventional branch
#       do not; a fork's PR on the same head branch name does not; item ids
#       match branches case-insensitively; no --since means no floor; no
#       --item skips the check with a note; gh stderr noise on success does
#       not break the JSON parse
#   3.  a listed lane window that no longer exists
#   3b. a live window whose pane command is a bare shell on two consecutive
#       passes — the harness exited (pane tail follows); one pass alone, and
#       a shell followed by a live command, are not events; a login shell
#       (-bash) counts; a live pane command is not an event; an unreadable
#       pane command is window-gone
#   4.  a lane pane showing a question prompt (pane tail follows)
#   5.  heartbeat after --max-loops with the open PR list
#   6.  gh auth failure exits 2; a stale env token falls through to the
#       project GH_BOT_TOKEN; a failing pr list exits 2 (never a quiet 0)
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
#   auth-fail     present → keyring `auth status` fails
#   list-fail     present → every `pr list` fails
#   noisy         present → every successful `pr list` also writes to stderr
# `api user` (env-token preflight) succeeds for any token except one
# starting with ghp_stale.
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
case "${1:-} ${2:-}" in
  "auth status")
    [[ -f "$STUB_DIR/auth-fail" ]] && { echo "You are not logged into any GitHub hosts." >&2; exit 1; }
    echo "Logged in"; exit 0 ;;
  "api user")
    [[ "${GH_TOKEN:-}" == ghp_stale* ]] && { echo "HTTP 401: Bad credentials" >&2; exit 1; }
    echo "someone"; exit 0 ;;
  "repo view")
    echo "owner/repo"; exit 0 ;;
  "pr list")
    printf '%s\n' "$*" >> "$STUB_DIR/gh.calls"
    [[ -f "$STUB_DIR/list-fail" ]] && { echo "HTTP 502: bad gateway" >&2; exit 1; }
    [[ -f "$STUB_DIR/noisy" ]] && echo "Notice: something advisory" >&2
    head=""; limit=""; state=""; repo=""
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --head) head="$2"; shift ;;
        --limit) limit="$2"; shift ;;
        --state) state="$2"; shift ;;
        --repo) repo="$2"; shift ;;
      esac
      shift
    done
    if [[ "$state" == "merged" ]]; then
      src="$STUB_DIR/merged.json"; [[ -f "$src" ]] || src=/dev/null
      # newest-created first, like gh: the fixture is in that order already;
      # --head narrows to one branch, --limit caps the page. gh always returns
      # headRepositoryOwner; a fixture that omits it is a same-repo head.
      jq -c --arg head "$head" --arg owner "${repo%%/*}" --argjson limit "${limit:-1000}" \
        '[ .[] | select($head == "" or .headRefName == $head)
                | (.headRepositoryOwner //= {login: $owner}) ] | .[:$limit]' "$src" 2>/dev/null || echo '[]'
      exit 0
    fi
    [[ -f "$STUB_DIR/open.txt" ]] && cat "$STUB_DIR/open.txt"
    exit 0 ;;
esac
printf 'unexpected gh call: %s\n' "$*" >&2
exit 1
EOF

# tmux stub: windows.txt lists window names; pane-<lane>.txt is a lane's screen;
# cmd-<lane>.txt is the pane's foreground command (#{pane_current_command}).
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
  display-message)
    lane=""
    while [[ $# -gt 0 ]]; do [[ "$1" == "-t" ]] && lane="$2"; shift; done
    n=0; [[ -f "$STUB_DIR/cmd-$lane.calls" ]] && n="$(cat "$STUB_DIR/cmd-$lane.calls")"
    n=$((n + 1)); printf '%s' "$n" > "$STUB_DIR/cmd-$lane.calls"
    src="$STUB_DIR/cmd-$lane.$n.txt"; [[ -f "$src" ]] || src="$STUB_DIR/cmd-$lane.txt"
    [[ -f "$src" ]] || { echo "can't find window: $lane" >&2; exit 1; }
    cat "$src"; exit 0 ;;
esac
printf 'unexpected tmux call: %s\n' "$*" >&2
exit 1
EOF

# Fake pr-watch: records GH_REPO, counts calls in prwatch.calls, prints
# prwatch.out.<N> (else prwatch.out) on stdout and prwatch.err.<N> (else
# prwatch.err) on stderr, exits with prwatch.rc.<N> (else prwatch.rc).
cat > "$TMP_ROOT/bin/pr-watch-stub.sh" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "${GH_REPO:-<unset>}" > "$STUB_DIR/prwatch.repo"
n=0; [[ -f "$STUB_DIR/prwatch.calls" ]] && n="$(cat "$STUB_DIR/prwatch.calls")"
n=$((n + 1)); printf '%s' "$n" > "$STUB_DIR/prwatch.calls"
out="$STUB_DIR/prwatch.out.$n"; [[ -f "$out" ]] || out="$STUB_DIR/prwatch.out"
err="$STUB_DIR/prwatch.err.$n"; [[ -f "$err" ]] || err="$STUB_DIR/prwatch.err"
rcf="$STUB_DIR/prwatch.rc.$n"; [[ -f "$rcf" ]] || rcf="$STUB_DIR/prwatch.rc"
[[ -f "$out" ]] && cat "$out"
[[ -f "$err" ]] && cat "$err" >&2
rc=0; [[ -f "$rcf" ]] && rc="$(cat "$rcf")"
exit "$rc"
EOF
chmod +x "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/tmux" "$TMP_ROOT/bin/pr-watch-stub.sh"

STUB_DIR=""
STATE_DIR=""
new_case() {
  STUB_DIR="$TMP_ROOT/cases/$1"
  rm -rf "$STUB_DIR"
  mkdir -p "$STUB_DIR"
  # Fresh pr-watch baseline per case: cases stay independent and nothing is
  # written under the real repo.
  STATE_DIR="$STUB_DIR/state"
  printf 'gh-1\ngh-2\n' > "$STUB_DIR/windows.txt"
  printf '⏺ working on it\n' > "$STUB_DIR/pane-gh-1.txt"
  printf '⏺ working on it\n' > "$STUB_DIR/pane-gh-2.txt"
  # Default: the harness is the pane's foreground process, so the lane is live.
  printf 'claude\n' > "$STUB_DIR/cmd-gh-1.txt"
  printf 'claude\n' > "$STUB_DIR/cmd-gh-2.txt"
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
           OVERSEE_WATCH_STATE_DIR="$STATE_DIR" \
           ${env_args[@]+"${env_args[@]}"} \
           .agents/skills/orch/scripts/oversee-watch --interval 0 --max-loops 2 --repo owner/repo "$@")
}

echo "=== oversee-watch ==="

# --- 1. pr-watch -----------------------------------------------------------
# 1a. attention present at start: baseline, not the event
new_case prwatch_baseline
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1a"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "attention at start exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "attention at start is not the event (heartbeat is)" "$err"
assert_contains "$out" "pr-watch rc=1" "latest pr-watch state is appended to the event" "$err"
assert_contains "$out" "threads-open" "pr-watch lines follow the context header" "$err"
assert_contains "$(cat "$err")" "pr-watch attention present at start" "baseline is noted once on stderr"
assert_eq "$(grep -c 'attention present at start' "$err")" "1" "baseline note printed once, not per pass"
assert_eq "$(cat "$STUB_DIR/prwatch.repo")" "owner/repo" "GH_REPO is exported to pr-watch" "$err"

# 1b. a NEW <pr> <kind> line mid-run is the event
new_case prwatch_new
printf '0' > "$STUB_DIR/prwatch.rc.1"
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out.2"
printf '1' > "$STUB_DIR/prwatch.rc.2"
err="$TMP_ROOT/e1b"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "new pr-watch line exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" "a new attention line mid-run is the event" "$err"
assert_contains "$out" "threads-open" "pr-watch output follows the event line" "$err"

# 1c. the same <pr> <kind> under a new head is not new (a lane pushed)
new_case prwatch_head_moved
printf '12\taaaa0000\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out.1"
printf '12\tbbbb0000\tthreads-open\t1 unresolved\n' > "$STUB_DIR/prwatch.out.2"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1c"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "same pr+kind under a new head is not an event" "$err"
assert_contains "$out" "bbbb0000" "context carries the LATEST pr-watch output" "$err"

# 1d. a new kind on an already-baselined PR is new
new_case prwatch_new_kind
printf '12\taaaa0000\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out.1"
printf '12\taaaa0000\tthreads-open\t2 unresolved\n12\taaaa0000\tdisarmed\tauto-merge off\n' > "$STUB_DIR/prwatch.out.2"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1d"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" "a new kind on a baselined PR is the event" "$err"

# 1e'. a line that clears and later recurs is a rising edge again
new_case prwatch_recur
printf '12\taaaa0000\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out.1"
printf '1' > "$STUB_DIR/prwatch.rc.1"
printf '0' > "$STUB_DIR/prwatch.rc.2"
printf '12\tbbbb0000\tthreads-open\t1 unresolved\n' > "$STUB_DIR/prwatch.out.3"
printf '1' > "$STUB_DIR/prwatch.rc.3"
err="$TMP_ROOT/e1e2"
out="$(run_watch -- --max-loops 3 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" "a cleared pr+kind that recurs is an event again" "$err"

# 1e. rc≠0 with no per-PR lines is pr-watch's global failure: exit 2
new_case prwatch_global
printf '2' > "$STUB_DIR/prwatch.rc"
printf 'pr-watch: GH_REPO is not set\n' > "$STUB_DIR/prwatch.err"
err="$TMP_ROOT/e1e"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "pr-watch rc=2 with no lines exits 2" "$err"
assert_eq "$out" "" "pr-watch global failure prints no EVENT" "$err"
assert_contains "$(cat "$err")" "pr-watch failed (rc=2) with no per-PR lines" "global failure is named on stderr"
assert_contains "$(cat "$err")" "GH_REPO is not set" "pr-watch stderr is surfaced"

# 1f. attention at start does not starve a lane's question
new_case prwatch_no_starve
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
printf 'Do you want to proceed?\n❯ 1. Yes\n  2. No\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e1f"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT question gh-2" "a lane question is seen despite standing pr-watch attention" "$err"
assert_contains "$out" "pr-watch rc=1" "the question event still carries the pr-watch context" "$err"

# 1g. the baseline persists across runs of the same fleet: the overseer exits
# on every event and re-runs the watch, so a line that appears BETWEEN two runs
# is the next run's first-pass event, while a standing line stays baseline
new_case prwatch_cross_run
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1g1"
out="$(run_watch -- --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=2026-08-15T09:00:00Z" \
  "run 1 of a fleet: attention at start is the baseline, not the event" "$err"

# run 2, same fleet (same repo and --since): PR 12 alone is not news
err="$TMP_ROOT/e1g2"
out="$(run_watch -- --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=2026-08-15T09:00:00Z" \
  "run 2: a key carried over from run 1 is not an event" "$err"
assert_not_contains "$out" "EVENT pr-watch" "run 2 with no new key never fires pr-watch" "$err"

# run 3: PR 34 showed up while the overseer was handling something else
printf '12\tabcdef01\tthreads-open\t2 unresolved\n34\t99887766\tthreads-open\t1 unresolved\n' > "$STUB_DIR/prwatch.out"
err="$TMP_ROOT/e1g3"
out="$(run_watch -- --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "cross-run rising edge exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT pr-watch rc=1" \
  "attention arriving between two runs is the next run's first-pass event" "$err"
assert_contains "$out" "99887766" "the new PR's line follows the event" "$err"
assert_not_contains "$(cat "$err")" "attention present at start" \
  "a persisted baseline replaces the start-of-run note"

# 1h. the state file is rewritten after every pass — the pass's keys, and the
# empty set when the reducer reports nothing
new_case prwatch_state_file
printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
printf '1' > "$STUB_DIR/prwatch.rc"
err="$TMP_ROOT/e1h1"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$(ls -1 "$STATE_DIR" 2>/dev/null | wc -l | tr -d '[:space:]')" "1" "one state file per fleet, no temp left behind" "$err"
state_file="$STATE_DIR/owner_repo__none"
assert_eq "$([[ -f "$state_file" ]] && echo yes || echo no)" "yes" "the state file is keyed on the repo and --since" "$err"
assert_eq "$(cat "$state_file")" "$(printf '12\tthreads-open')" "the state file holds the pass's <pr> <kind> keys" "$err"

printf '0' > "$STUB_DIR/prwatch.rc"
: > "$STUB_DIR/prwatch.out"
err="$TMP_ROOT/e1h2"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$([[ -f "$state_file" ]] && echo yes || echo no)" "yes" "the state file survives a clean pass" "$err"
assert_eq "$(cat "$state_file" 2>/dev/null; echo x)" "x" "a pass with no attention empties the state file" "$err"

# 1i. a state directory that cannot be created is a hard failure, never a
# silent fallback to in-process-only memory
new_case prwatch_state_unwritable
printf 'not a directory\n' > "$STUB_DIR/blocker"
err="$TMP_ROOT/e1i"
out="$(run_watch OVERSEE_WATCH_STATE_DIR="$STUB_DIR/blocker/state" -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "an uncreatable state dir exits 2" "$err"
assert_eq "$out" "" "state dir failure prints no EVENT" "$err"
assert_contains "$(cat "$err")" "$STUB_DIR/blocker/state" "the failure names the state dir path"

# 1j. an unreadable state file is exit 2 naming the path, not a raw `cat`
# error under set -e. Root reads anything, so the case cannot run there.
new_case prwatch_state_unreadable
if [[ "$(id -u)" -eq 0 ]]; then
  printf '  skip  unreadable state file (running as root)\n'
else
  printf '12\tabcdef01\tthreads-open\t2 unresolved\n' > "$STUB_DIR/prwatch.out"
  printf '1' > "$STUB_DIR/prwatch.rc"
  err="$TMP_ROOT/e1j1"
  out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
  state_file="$STATE_DIR/owner_repo__none"
  chmod 000 "$state_file"
  err="$TMP_ROOT/e1j2"
  out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
  chmod 600 "$state_file"
  assert_eq "$rc" "2" "an unreadable state file exits 2" "$err"
  assert_eq "$out" "" "an unreadable state file prints no EVENT" "$err"
  assert_contains "$(cat "$err")" "cannot read the pr-watch state file: $state_file" \
    "the failure names the state file path"
fi

# --- 2. merged, with item, since, and case controls -------------------------
new_case merged
cat > "$STUB_DIR/merged.json" <<'EOF'
[
  {"number": 5, "headRefName": "issue-5",   "mergedAt": "2026-08-15T10:00:00Z"},
  {"number": 6, "headRefName": "issue-6",   "mergedAt": "2026-08-15T08:00:00Z"},
  {"number": 7, "headRefName": "feature-x", "mergedAt": "2026-08-15T10:30:00Z"},
  {"number": 8, "headRefName": "vst-8",     "mergedAt": "2026-08-15T09:00:00Z"},
  {"number": 9, "headRefName": "issue-9",   "mergedAt": "2026-08-15T10:45:00Z"}
]
EOF
err="$TMP_ROOT/e2"
out="$(run_watch -- --since 2026-08-15T09:00:00Z --item issue-5 --item issue-6 --item VST-8 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "merged exits 0" "$err"
assert_contains "$out" "EVENT merged 5 issue-5" "an item's PR merged after --since fires" "$err"
assert_contains "$out" "EVENT merged 8 vst-8" "an item's PR merged exactly at --since fires; id matches branch case-insensitively" "$err"
assert_not_contains "$out" "EVENT merged 6" "an item's PR merged before --since does not fire" "$err"
assert_not_contains "$out" "EVENT merged 7" "a non-item branch does not fire" "$err"
assert_not_contains "$out" "EVENT merged 9" "a conventional issue-N branch that is not a live item does not fire" "$err"
assert_eq "$(grep -c '^EVENT' <<<"$out")" "2" "one EVENT line per merged PR, nothing else" "$err"

# no --since: no floor, so a merge that landed before this run still fires
err="$TMP_ROOT/e2b"
out="$(run_watch -- --item issue-5 --item issue-6 2>"$err")" && rc=0 || rc=$?
assert_contains "$out" "EVENT merged 6 issue-6" "without --since a merge from before the run fires (no moving floor)" "$err"
assert_eq "$(grep -c '^EVENT' <<<"$out")" "2" "both item PRs fire, nothing else" "$err"

# busy repo: the item's PR is older than 60 newer merges — a single listing
# window would drop it; the per-item --head query still finds it
err="$TMP_ROOT/e2c"
jq -n '[range(1; 61) | {number: (100 + .), headRefName: ("noise-" + (.|tostring)), mergedAt: "2026-08-15T12:00:00Z"}] + [{number: 5, headRefName: "issue-5", mergedAt: "2026-08-15T10:00:00Z"}]' > "$STUB_DIR/merged.json"
out="$(run_watch -- --since 2026-08-15T09:00:00Z --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "busy-repo merged exits 0" "$err"
assert_contains "$out" "EVENT merged 5 issue-5" "an item's merge beyond a newest-60 window still fires (per-item --head query)" "$err"


# no --item: merged check skipped with a note; a merged PR is not an event
: > "$STUB_DIR/gh.calls"
err="$TMP_ROOT/e2c"
out="$(run_watch -- --since 2026-08-15T09:00:00Z 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=2026-08-15T09:00:00Z" "no --item reaches the heartbeat" "$err"
assert_contains "$(cat "$err")" "no --item given; skipping the merged check" "no --item is noted on stderr"
assert_eq "$(grep -c 'merged' "$STUB_DIR/gh.calls" || true)" "0" "no --item never lists merged PRs"

# gh stderr noise on a successful list does not reach the JSON parse
touch "$STUB_DIR/noisy"
err="$TMP_ROOT/e2d"
out="$(run_watch -- --since 2026-08-15T09:00:00Z --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "gh stderr noise on success still exits 0" "$err"
assert_eq "$out" "EVENT merged 5 issue-5" "gh stderr noise does not corrupt the merged list" "$err"

# a fork's PR carries the same head branch NAME, and --head matches by name
new_case merged_fork
cat > "$STUB_DIR/merged.json" <<'EOF'
[
  {"number": 42, "headRefName": "issue-5", "headRepositoryOwner": {"login": "forker"}, "mergedAt": "2026-08-15T10:00:00Z"}
]
EOF
err="$TMP_ROOT/e2e"
out="$(run_watch -- --since 2026-08-15T09:00:00Z --item issue-5 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "a fork-only merged list still exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=2026-08-15T09:00:00Z" "a fork PR on the item's branch name is not a merge" "$err"
assert_not_contains "$out" "EVENT merged" "a same-named fork branch never fires merged" "$err"

# --- 3. window-gone --------------------------------------------------------
new_case window_gone
printf 'gh-1\n' > "$STUB_DIR/windows.txt"
err="$TMP_ROOT/e3"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "window-gone exits 0" "$err"
assert_eq "$out" "EVENT window-gone gh-2" "missing lane window is the event" "$err"

# --- 3b. lane-exited: window alive, harness gone ----------------------------
# open-terminal runs the harness inside a shell, so a session that hit its
# limit or crashed leaves a live window whose pane matches no question prompt.
new_case lane_exited
printf 'bash\n' > "$STUB_DIR/cmd-gh-2.txt"
{
  printf '⏺ I will keep going.\n\n'
  printf "You've hit your session limit · resets 21:00\n"
  printf '$ \n'
} > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3b"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "lane-exited exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-exited gh-2" "a bare shell on two consecutive passes is the event" "$err"
assert_contains "$out" "session limit" "the pane tail follows, carrying the exit reason" "$err"
assert_not_contains "$out" "EVENT window-gone" "a live window is not reported gone" "$err"

# one pass is not enough: a live harness can hold a shell in the foreground
# for a single poll, and relaunching a working lane costs more than a wait
new_case lane_exited_debounce
printf 'bash\n' > "$STUB_DIR/cmd-gh-2.txt"
err="$TMP_ROOT/e3b2"
out="$(run_watch -- --max-loops 1 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=1 interval=0s since=none" "one pass of shell is not the event" "$err"
assert_not_contains "$out" "EVENT lane-exited" "a single shell reading never fires" "$err"

# a shell on one pass followed by a live command is a transient, not an exit
new_case lane_exited_transient
printf 'bash\n' > "$STUB_DIR/cmd-gh-2.1.txt"
err="$TMP_ROOT/e3b3"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "shell then live is not an exit" "$err"
assert_not_contains "$out" "EVENT lane-exited" "a non-consecutive shell reading never fires" "$err"

# a login shell reports itself as -bash
new_case lane_exited_login_shell
printf -- '-bash\n' > "$STUB_DIR/cmd-gh-2.txt"
err="$TMP_ROOT/e3b4"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT lane-exited gh-2" "a login shell (-bash) counts as a bare shell" "$err"

# a live harness under the same conditions is no event
new_case lane_live
printf 'codex\n' > "$STUB_DIR/cmd-gh-2.txt"
err="$TMP_ROOT/e3c"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT heartbeat loops=2 interval=0s since=none" "a live pane command is not an exit" "$err"
assert_not_contains "$out" "EVENT lane-exited" "a live lane never fires lane-exited" "$err"

# an exited lane whose pane holds only blank lines still reports the event:
# the pane tail is a grep miss there, which pipefail would turn into an abort
new_case lane_exited_blank_pane
printf 'zsh\n' > "$STUB_DIR/cmd-gh-2.txt"
printf '   \n\n\t\n' > "$STUB_DIR/pane-gh-2.txt"
err="$TMP_ROOT/e3e"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "an exited lane with a blank pane still exits 0" "$err"
assert_eq "$(head -1 <<<"$out")" "EVENT lane-exited gh-2" "a blank pane does not swallow the event" "$err"

# an unreadable pane command is window-gone, never a silent skip
new_case lane_cmd_unreadable
rm -f "$STUB_DIR/cmd-gh-2.txt"
err="$TMP_ROOT/e3d"
out="$(run_watch -- gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$(head -1 <<<"$out")" "EVENT window-gone gh-2" "an unreadable pane command is window-gone" "$err"

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
out="$(run_watch -- --item issue-9 gh-1 gh-2 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "heartbeat exits 0" "$err"
assert_contains "$out" "EVENT heartbeat" "heartbeat after --max-loops with no event" "$err"
assert_contains "$out" "issue-9" "open PR list follows the heartbeat" "$err"
assert_eq "$(grep -c 'merged' "$STUB_DIR/gh.calls")" "2" "merged check ran once per loop (2 loops)" "$err"

# --- 6. auth and listing failures ------------------------------------------
new_case auth_fail
touch "$STUB_DIR/auth-fail"
err="$TMP_ROOT/e6a"
out="$(run_watch -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "gh auth failure exits 2" "$err"
assert_contains "$(cat "$err")" "no working GitHub auth path" "auth failure is named on stderr"
assert_eq "$out" "" "auth failure prints no EVENT" "$err"

# a stale env token with no keyring falls through to the project GH_BOT_TOKEN
new_case auth_bot_fallback
touch "$STUB_DIR/auth-fail"
err="$TMP_ROOT/e6b"
out="$(run_watch GH_TOKEN=ghp_stale0000 GH_BOT_TOKEN=ghp_bot00000 -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "0" "stale GH_TOKEN + no keyring + valid GH_BOT_TOKEN watches" "$err"
assert_contains "$out" "EVENT heartbeat" "bot-token fallback reaches the heartbeat" "$err"

# the same stale token with no bot token still fails closed
err="$TMP_ROOT/e6c"
out="$(run_watch GH_TOKEN=ghp_stale0000 -- 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "stale GH_TOKEN with no other path exits 2" "$err"

new_case list_fail
touch "$STUB_DIR/list-fail"
err="$TMP_ROOT/e6d"
out="$(run_watch -- --item issue-1 2>"$err")" && rc=0 || rc=$?
assert_eq "$rc" "2" "failing pr list exits 2" "$err"
assert_contains "$(cat "$err")" "gh pr list --state merged failed" "pr list failure is named on stderr"
assert_contains "$(cat "$err")" "HTTP 502" "gh stderr is surfaced with the failure"

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
