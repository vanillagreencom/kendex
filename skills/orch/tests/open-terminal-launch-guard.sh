#!/usr/bin/env bash
# The last layer before a window opens: a launch whose working directory does
# not exist is refused by name.
#
# A suite that drives `open-terminal` with a stubbed worktree CLI gets an empty
# path back the moment the stub exits 0 without printing one — the shape a
# PATH stub leaves when its fixture tree is deleted under it — and open_gui
# handing that empty path to a real GUI terminal opens a window on the
# operator's desktop at a directory that is gone. The same is true of any
# lane whose worktree was removed while it ran. Refusing here closes it
# whatever produced the launch, without asking who did.
#
# Everything external is stubbed: the GUI terminal and tmux (invocations
# logged, so a refusal that still launched is visible), gh, and the worktree
# CLI.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# An inherited or configured lane host would turn these local launches into
# hosted ones; the caller environment outranks project settings.
export ORCH_LANE_HOST=local
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
# mutant_scripts and mutate_file, the two halves of the control below.
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
SRC_OT="$SCRIPTS_DIR/open-terminal"
SRC_LIB_DIR="$SCRIPTS_DIR/lib"
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-launch-guard: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-launch-guard: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-launch-guard: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

# Stub bin. The GUI terminal APPENDS rather than truncating, so a case that
# expects no launch fails loudly on a stray one instead of overwriting it.
# Every run names this stub in $TERMINAL, which open_gui reaches for first, so
# no case can resolve the developer's own terminal.
BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
cat > "$BIN/term" <<'EOF'
#!/usr/bin/env bash
printf 'term %s\n' "$*" >> "$OT_TERM_LOG"
exit 0
EOF
cat > "$BIN/tmux" <<'EOF'
#!/usr/bin/env bash
printf 'tmux %s\n' "$*" >> "$OT_TMUX_LOG"
# The named session exists, so a launch reaches the window calls, which fail.
[[ "${1:-}" != has-session ]] || exit 0
exit 1
EOF
cat > "$BIN/gh" <<'EOF'
#!/usr/bin/env bash
[[ "$*" != 'repo view --json nameWithOwner -q .nameWithOwner' ]] || { echo o/r; exit 0; }
exit 1
EOF
chmod +x "$BIN/term" "$BIN/tmux" "$BIN/gh"

# Stub worktree CLI, one shape per $STUB_MODE:
#   empty    exits 0 printing nothing (a stub that escaped its fixture)
#   missing  prints a path that was never created (a tree removed under a lane)
STUB="$TMP_ROOT/worktree-stub"
cat > "$STUB" <<EOF
#!/usr/bin/env bash
set -euo pipefail
[[ "\${1:-}" == "create" ]] || { echo "unexpected worktree stub call: \$*" >&2; exit 1; }
case "\$STUB_MODE" in
  valid) d="$TMP_ROOT/wt/\${2:-item}"; mkdir -p "\$d"; git init -q "\$d"; printf '%s\n' "\$d"; exit 0 ;;
  empty)   exit 0 ;;
  missing) printf '%s\n' "$TMP_ROOT/gone/\${2:-item}"; exit 0 ;;
esac
exit 1
EOF
chmod +x "$STUB"

# stage DIR SRC — a copy of open-terminal in a git repo of its own, so
# PROJECT_ROOT resolves hermetically.
stage() {
  mkdir -p "$1/scripts/lib"
  cp "$2" "$1/scripts/open-terminal"
  cp "$SCRIPTS_DIR/lane-host" "$SCRIPTS_DIR/workflow-state" "$SCRIPTS_DIR/git-context" "$SCRIPTS_DIR/lane-marker" "$1/scripts/"
  cp -R "$SRC_LIB_DIR/." "$1/scripts/lib/"
  orch_fixture_shared_libs "$1"
  chmod +x "$1/scripts/open-terminal"
  git -C "$1" init -q
}

REPO="$TMP_ROOT/repo"
stage "$REPO" "$SRC_OT"
mkdir -p "$REPO/.agents/skills/linear/scripts"
cat > "$REPO/.agents/skills/linear/scripts/linear.sh" <<'EOF'
#!/bin/sh
[ "$*" = 'teams get Checkout team --format raw' ] || exit 2
case "${TEAM_READ:-ok}" in
  ok) printf '{"team":{"key":"CC"}}\n' ;;
  invalid) printf '{"team":null}\n' ;;
  failed) exit 7 ;;
esac
EOF
chmod +x "$REPO/.agents/skills/linear/scripts/linear.sh"

# run NAME OT MODE ARGS... — sets RC, ERR, TERM_LOG_TEXT and TMUX_LOG_TEXT.
run() {
  local name="$1" ot="$2" mode="$3"
  shift 3
  local term_log="$TMP_ROOT/$name.term" tmux_log="$TMP_ROOT/$name.tmux"
  : > "$term_log"
  : > "$tmux_log"
  set +e
  env -i GIT_CEILING_DIRECTORIES="$GIT_CEILING_DIRECTORIES" HOME="$TMP_ROOT" PATH="$BIN:$PATH" ORCH_LANE_HOST=local \
    LINEAR_TEAM="${OT_LINEAR_TEAM:-}" TEAM_READ="${OT_TEAM_READ:-ok}" GH_REPO="${OT_GH_REPO:-}" \
    ORCH_STATE_DIR="$TMP_ROOT/$name.state" WORKTREE_CLI="$STUB" STUB_MODE="$mode" \
    OT_TERM_LOG="$term_log" OT_TMUX_LOG="$tmux_log" \
    TMUX="${OT_TMUX_VALUE:-}" ORCH_TMUX_SESSION=stub TERMINAL=term \
    "$ot" --cmd 'echo {item}' "$@" >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err"
  RC=$?
  set -e
  ERR="$(cat "$TMP_ROOT/$name.err")"
  # open_gui detaches the launch (`setsid ... &`), so the stub's line can land
  # after open-terminal has already exited, and a case on a loaded box then
  # reads an empty log. Which wait to take is DERIVED from the script's own
  # report rather than from a flag each call site remembers: an exit 0 says a
  # launch was started, so wait for its line; any other status says none was, so
  # watch a real interval and prove none appears.
  local i=0
  if [[ "$RC" -eq 0 ]]; then
    while [ "$i" -lt 100 ] && [ ! -s "$term_log" ]; do
      sleep 0.1
      i=$((i + 1))
    done
  else
    sleep 1
  fi
  TERM_LOG_TEXT="$(cat "$term_log")"
  TMUX_LOG_TEXT="$(cat "$tmux_log")"
}

echo "=== open-terminal: a launch at a working directory that is gone is refused ==="

run empty "$REPO/scripts/open-terminal" empty --ghostty CC-1
assert_eq "$RC" "1" "a GUI launch with no worktree path fails the item"
assert_eq "${ERR%%$'\n'*}" "open-terminal: directory-missing item=CC-1 path=" \
  "the refusal names the item and the empty directory"
assert_eq "$TERM_LOG_TEXT" "" "no terminal was launched for the empty path"

run missing "$REPO/scripts/open-terminal" missing --ghostty CC-1
assert_eq "$RC" "1" "a GUI launch at a deleted worktree fails the item"
assert_eq "${ERR%%$'\n'*}" "open-terminal: directory-missing item=CC-1 path=$TMP_ROOT/gone/CC-1" \
  "the refusal names the directory that is gone"
assert_eq "$TERM_LOG_TEXT" "" "no terminal was launched at the deleted directory"

# The tmux path refuses at the same layer, before the first tmux call: a window
# created with `-c` at a missing directory is the same broken lane. TMUX travels
# through the run helper, never as an assignment prefixed onto a function call:
# bash keeps such an assignment in the shell after the call, and it would then
# decide the mode of every case below.
OT_TMUX_VALUE=stub,1,0
run tmux_missing "$REPO/scripts/open-terminal" missing --tmux CC-1
OT_TMUX_VALUE=""
assert_eq "$RC" "1" "a tmux launch at a deleted worktree fails the item"
assert_eq "${ERR%%$'\n'*}" "open-terminal: directory-missing item=CC-1 path=$TMP_ROOT/gone/CC-1" \
  "the tmux path refuses in the same words"
assert_eq "$TMUX_LOG_TEXT" "" "tmux was never called for the deleted directory"

echo
echo "=== the refusal can fail: with the guard gone the window opens ==="

# The suite's one must-fail control. `launchable_dir` is the whole protection,
# so the mutation is its one test: with that gone the function returns 0 for
# every path and the launch at the deleted directory proceeds.
MUTANT_REPO="$TMP_ROOT/mutant-repo"
MUTANT_OT="$(mutant_scripts mutant-repo open-terminal)/open-terminal" || exit 1
git -C "$MUTANT_REPO" init -q
orch_fixture_shared_libs "$MUTANT_REPO"
mutate_file "$MUTANT_OT" '[[ -d "$1" ]] && return 0' 'return 0'

run mutant "$MUTANT_OT" missing --ghostty CC-1
assert_eq "$RC" "0" "control: without the guard the deleted-path launch is reported as successful"
assert_contains "$TERM_LOG_TEXT" "term -e bash -lc" \
  "control: and a terminal really is opened at the directory that is gone"

# open-terminal's tracker arguments produce these two foreign item forms.
# The checkout's GitHub identity is independent of --repo and GH_REPO.
for tracker in github linear; do
  args=(--ghostty)
  OT_LINEAR_TEAM="" OT_GH_REPO=""
  case "$tracker" in
    github) args+=(--tracker github --repo other/repo 42); foreign=other/repo; OT_GH_REPO=other/repo ;;
    linear) args+=(OTHER-42); foreign=OTHER; OT_LINEAR_TEAM='Checkout team' ;;
  esac
  run "foreign-$tracker" "$REPO/scripts/open-terminal" valid "${args[@]}"
  assert_eq "$RC|${ERR%%$'\n'*}|$TERM_LOG_TEXT|$TMUX_LOG_TEXT" \
    "1|open-terminal: item-foreign repo=$foreign route=peer-mail||" \
    "$tracker foreign item refuses and launches nothing"
  MUTANT_REPO="$TMP_ROOT/foreign-$tracker"
  MUTANT_OT="$(mutant_scripts "foreign-$tracker" open-terminal)/open-terminal" || exit 1
  git -C "$MUTANT_REPO" init -q
  orch_fixture_shared_libs "$MUTANT_REPO"
  mkdir -p "$MUTANT_REPO/.agents/skills/linear/scripts"
  cp "$REPO/.agents/skills/linear/scripts/linear.sh" "$MUTANT_REPO/.agents/skills/linear/scripts/"
  mutate_file "$MUTANT_OT" 'if [[ "$repo_match" != true ]]; then' \
    'if false && [[ "$repo_match" != true ]]; then'
  run "foreign-$tracker-control" "$MUTANT_OT" valid "${args[@]}"
  assert_eq "$RC" 0 "$tracker control: removing the refusal admits the foreign item"
  assert_contains "$TERM_LOG_TEXT" 'term -e bash -lc' "$tracker control: a terminal opens"
done
OT_LINEAR_TEAM='Checkout team' OT_GH_REPO=""
run own-linear "$REPO/scripts/open-terminal" valid --ghostty cc-42
assert_eq "$RC" 0 "the configured team name resolves to its key and admits the canonical item"
OT_LINEAR_TEAM=""
run own-github "$REPO/scripts/open-terminal" valid --ghostty --tracker github --repo O/R 42
assert_eq "$RC" 0 "GitHub repository identity comparison ignores case"
OT_LINEAR_TEAM='Checkout team'
for OT_TEAM_READ in failed invalid; do
  run "team-$OT_TEAM_READ" "$REPO/scripts/open-terminal" valid --ghostty CC-42
  assert_eq "$RC|${ERR%%$'\n'*}|$TERM_LOG_TEXT|$TMUX_LOG_TEXT" \
    '1|open-terminal: item-repo-unresolved tracker=linear team=Checkout team||' \
    "a $OT_TEAM_READ configured team read launches nothing"
done

# Team resolution is an independent refusal from foreign comparison. The
# failed reader leaves no key, so disable both resolution failure exits while
# retaining their text. The foreign comparison remains unchanged.
MUTANT_REPO="$TMP_ROOT/unresolved-team"
MUTANT_OT="$(mutant_scripts unresolved-team open-terminal)/open-terminal" || exit 1
git -C "$MUTANT_REPO" init -q
orch_fixture_shared_libs "$MUTANT_REPO"
mkdir -p "$MUTANT_REPO/.agents/skills/linear/scripts"
cp "$REPO/.agents/skills/linear/scripts/linear.sh" "$MUTANT_REPO/.agents/skills/linear/scripts/"
mutate_file "$MUTANT_OT" \
  '  team_record="$("$linear_cli" teams get "$LINEAR_TEAM" --format raw)" \
    || { ot_message item-repo-unresolved tracker=linear "team=$LINEAR_TEAM" >&2; exit 1; }' \
  '  team_record="$("$linear_cli" teams get "$LINEAR_TEAM" --format raw)" \
    || { if false; then ot_message item-repo-unresolved tracker=linear "team=$LINEAR_TEAM" >&2; exit 1; fi; }'
mutate_file "$MUTANT_OT" \
  '  checkout_repo="$(jq -er '\''.team.key | strings | select(length > 0)'\'' <<<"$team_record")" \
    || { ot_message item-repo-unresolved tracker=linear "team=$LINEAR_TEAM" >&2; exit 1; }' \
  '  checkout_repo="$(jq -er '\''.team.key | strings | select(length > 0)'\'' <<<"$team_record")" \
    || { if false; then ot_message item-repo-unresolved tracker=linear "team=$LINEAR_TEAM" >&2; exit 1; fi; }'
OT_TEAM_READ=failed
run team-failed-control "$MUTANT_OT" valid --ghostty CC-42
assert_eq "$RC" 0 "control: without resolution refusal the failed team read admits a launch"
assert_contains "$TERM_LOG_TEXT" 'term -e bash -lc' \
  "control: the failed-read refusal assertion turns red because a terminal opens"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
