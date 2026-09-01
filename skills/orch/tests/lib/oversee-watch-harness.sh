# Shared sandbox for the oversee-watch suites: the stub binaries every case
# drives, the assertion helpers, and one `run_watch` entry point.
#
# oversee-watch reads two independent surfaces — GitHub (pr-watch, `gh pr
# list`) and the tmux panes of the lane windows — and each has its own suite:
# oversee_watch.sh covers the GitHub side and the process-wide failures,
# oversee_watch_lanes.sh the pane side. Both build the same sandbox, so it
# lives here rather than in either of them.
#
# Sourced, never run: the runners glob tests/*.sh, so nothing here executes on
# its own. Sourcing it sets the shell options, builds $TMP_ROOT and the stub
# binaries under it, arms the cleanup trap, and defines the assertion helpers,
# `new_case` and `run_watch`. A suite sources it, adds its cases, and prints
# the `pass: N   fail: M` line itself.
# Set here as well as in each suite: this file's own body relies on it, and a
# suite that forgot it must not get a sandbox built without it.
set -euo pipefail

# Resolved from this file, not from the sourcing suite: four levels up from
# skills/<skill>/tests/lib is the repo root.
REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../../.." && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "oversee-watch harness: mktemp -d failed" >&2; exit 1; }
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
#   repoview.txt  what `repo view` reports — the repository the watch resolves
#                 when no --repo is given (default: owner/repo)
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
    [[ -f "$STUB_DIR/repoview.txt" ]] && { cat "$STUB_DIR/repoview.txt"; exit 0; }
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
# cmd-<lane>.txt is the pane's foreground command (#{pane_current_command}) and
# panepid-<lane>.txt its #{pane_pid} (default 9000), returned together as the
# lane's one liveness read; panes.txt is `list-panes -a` (`<server pid> <pane
# id>` lines, the lane-claim liveness key). pane-<lane>.<N>.txt and
# cmd-<lane>.<N>.txt override the plain file on the Nth read of that lane, so a
# case can change a screen between passes; obs-<lane>.txt replaces the whole
# liveness reply, for a case that needs a malformed one.
cat > "$TMP_ROOT/bin/tmux" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
prev=""
case "${1:-}" in
  list-windows) cat "$STUB_DIR/windows.txt"; exit 0 ;;
  list-panes)
    [[ -f "$STUB_DIR/panes.txt" ]] && cat "$STUB_DIR/panes.txt"
    exit 0 ;;
  capture-pane)
    lane=""
    while [[ $# -gt 0 ]]; do [[ "$1" == "-t" ]] && lane="$2"; shift; done
    n=0; [[ -f "$STUB_DIR/pane-$lane.calls" ]] && n="$(cat "$STUB_DIR/pane-$lane.calls")"
    n=$((n + 1)); printf '%s' "$n" > "$STUB_DIR/pane-$lane.calls"
    src="$STUB_DIR/pane-$lane.$n.txt"; [[ -f "$src" ]] || src="$STUB_DIR/pane-$lane.txt"
    [[ -f "$src" ]] || { echo "can't find window: $lane" >&2; exit 1; }
    cat "$src"; exit 0 ;;
  display-message)
    # `-p -t <lane> '#{pid} #{pane_id}'` asks for the pane's liveness key.
    for a in "$@"; do
      [[ "$a" == *'#{pane_id}'* ]] || continue
      lane=""
      for x in "$@"; do [[ "$prev" == "-t" ]] && lane="$x"; prev="$x"; done
      key="$STUB_DIR/pane-key-$lane.txt"
      [[ -f "$key" ]] && cat "$key"
      exit 0
    done
    lane=""
    while [[ $# -gt 0 ]]; do [[ "$1" == "-t" ]] && lane="$2"; shift; done
    n=0; [[ -f "$STUB_DIR/cmd-$lane.calls" ]] && n="$(cat "$STUB_DIR/cmd-$lane.calls")"
    n=$((n + 1)); printf '%s' "$n" > "$STUB_DIR/cmd-$lane.calls"
    src="$STUB_DIR/cmd-$lane.$n.txt"; [[ -f "$src" ]] || src="$STUB_DIR/cmd-$lane.txt"
    [[ -f "$src" ]] || { echo "can't find window: $lane" >&2; exit 1; }
    # `#{pane_pid} #{pane_current_command}`: one read, pid first. obs-<lane>.txt
    # replaces the whole reply, so a case can hand the watch a malformed one.
    if [[ -f "$STUB_DIR/obs-$lane.txt" ]]; then cat "$STUB_DIR/obs-$lane.txt"; exit 0; fi
    pid=9000; [[ -f "$STUB_DIR/panepid-$lane.txt" ]] && pid="$(cat "$STUB_DIR/panepid-$lane.txt")"
    printf '%s %s\n' "$pid" "$(cat "$src")"; exit 0 ;;
esac
printf 'unexpected tmux call: %s\n' "$*" >&2
exit 1
EOF

# pgrep stub, modelling the probe the watch actually runs: `pgrep -P <pid>`
# prints kids-<pid>.txt and exits 0 when that file exists — the children of a
# pane process — and exits 1 with nothing when it does not, the way procps and
# BSD pgrep both report no match. probe-fail-<pid> holds the status to exit
# with instead, empty meaning 2 — the statuses that are not an answer, since
# pgrep documents 2 for a syntax error and 3 for a fatal one, and a pgrep
# missing from PATH leaves 127. Every call is logged to pgrep.calls, so a case
# can hold the watch to one probe per bare-shell lane per pass.
cat > "$TMP_ROOT/bin/pgrep" <<'EOF'
#!/usr/bin/env bash
set -uo pipefail
ppid=""
while [[ $# -gt 0 ]]; do
  case "$1" in -P) ppid="$2"; shift ;; esac
  shift
done
[[ -n "$ppid" ]] || exit 2
printf '%s\n' "$ppid" >> "$STUB_DIR/pgrep.calls"
if [[ -f "$STUB_DIR/probe-fail-$ppid" ]]; then
  rc="$(cat "$STUB_DIR/probe-fail-$ppid")"
  exit "${rc:-2}"
fi
[[ -f "$STUB_DIR/kids-$ppid.txt" ]] || exit 1
cat "$STUB_DIR/kids-$ppid.txt"
EOF

# Fake pr-watch: records GH_REPO in prwatch.repo (the latest call) and appends
# it to prwatch.repos (every call), counts calls per repo in
# prwatch.calls.<SLUG>, and answers from the first fixture that exists —
# prwatch.out.<SLUG>.<N>, prwatch.out.<SLUG>, prwatch.out.<N>, prwatch.out —
# on stdout, the same ladder for prwatch.err on stderr and prwatch.rc as the
# exit status. <SLUG> is GH_REPO with everything outside [A-Za-z0-9._-]
# replaced by `_`, so a multi-repo case answers each repo separately while a
# single-repo case reads the same as a global call count.
cat > "$TMP_ROOT/bin/pr-watch-stub.sh" <<'EOF'
#!/usr/bin/env bash
repo="${GH_REPO:-<unset>}"
slug="$(printf '%s' "$repo" | tr -c 'A-Za-z0-9._-' '_')"
printf '%s\n' "$repo" > "$STUB_DIR/prwatch.repo"
printf '%s\n' "$repo" >> "$STUB_DIR/prwatch.repos"
n=0; [[ -f "$STUB_DIR/prwatch.calls.$slug" ]] && n="$(cat "$STUB_DIR/prwatch.calls.$slug")"
n=$((n + 1)); printf '%s' "$n" > "$STUB_DIR/prwatch.calls.$slug"
pick() {
  local f
  for f in "$STUB_DIR/$1.$slug.$n" "$STUB_DIR/$1.$slug" "$STUB_DIR/$1.$n" "$STUB_DIR/$1"; do
    [[ -f "$f" ]] && { printf '%s' "$f"; return 0; }
  done
  return 1
}
out="$(pick prwatch.out || true)"
err="$(pick prwatch.err || true)"
rcf="$(pick prwatch.rc || true)"
[[ -n "$out" ]] && cat "$out"
[[ -n "$err" ]] && cat "$err" >&2
rc=0; [[ -n "$rcf" ]] && rc="$(cat "$rcf")"
exit "$rc"
EOF
chmod +x "$TMP_ROOT/bin/gh" "$TMP_ROOT/bin/tmux" "$TMP_ROOT/bin/pgrep" "$TMP_ROOT/bin/pr-watch-stub.sh"

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
  # One pane process per lane, and by default nothing under it: a case that
  # puts a shell in the foreground gets the exited shape unless it also writes
  # kids-<pid>.txt.
  printf '9001\n' > "$STUB_DIR/panepid-gh-1.txt"
  printf '9002\n' > "$STUB_DIR/panepid-gh-2.txt"
}

# run_watch [ENV=VAL ...] -- ARGS...   (fast cadence; TMUX set unless NO_TMUX=1)
# `--repo owner/repo` is supplied only when ARGS name no repo of their own:
# --repo is repeatable, so injecting it beside a case's own would make that
# case a two-repo fleet with owner/repo first. `--no-repo` is the harness's own
# token, stripped before the watch runs: it asks for no --repo at all, the
# default path where the watch resolves the repository from `gh repo view`.
run_watch() {
  local env_args=() repo_args=(--repo owner/repo) watch_args=() arg
  while [[ $# -gt 0 && "$1" != "--" ]]; do env_args+=("$1"); shift; done
  shift || true
  for arg in "$@"; do
    case "$arg" in
      --no-repo) repo_args=() ;;
      --repo | --repo=*) repo_args=(); watch_args+=("$arg") ;;
      *) watch_args+=("$arg") ;;
    esac
  done
  (cd "$TMP_ROOT/repo" \
    && PATH="$TMP_ROOT/bin:$PATH" \
       env -u GH_TOKEN -u GITHUB_TOKEN -u GH_BOT_TOKEN \
           STUB_DIR="$STUB_DIR" TMUX="fake" \
           OVERSEE_WATCH_PR_WATCH="$TMP_ROOT/bin/pr-watch-stub.sh" \
           OVERSEE_WATCH_STATE_DIR="$STATE_DIR" \
           ${env_args[@]+"${env_args[@]}"} \
           .agents/skills/orch/scripts/oversee-watch --interval 0 --max-loops 2 \
             ${repo_args[@]+"${repo_args[@]}"} ${watch_args[@]+"${watch_args[@]}"})
}
