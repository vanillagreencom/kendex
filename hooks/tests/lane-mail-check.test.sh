#!/usr/bin/env bash
# lane-mail-check, the turn-end entry: it finds its install's mailbox reader
# by walking up from its own directory, runs that install's `orch-runtime
# turn-end` through the shipped wrapper, and where the runtime is not built
# for its sources starts the build through the install's `scripts/setup
# --detach`, holding a turn end while the build runs in a checkout with a
# mailbox directory. Every row runs the real entry and the real wrapper over
# a lane the real `lane-marker` launched and the real `lane-mail` wrote to;
# with the runtime built, the binary scripts/setup placed in
# AGENT_RUNTIME_CACHE answers, and a row that needs it unbuilt runs the real
# setup over a cache of its own with agent-runtime's planted cargo first on
# PATH. What the verb decides is the runtime's Rust rows' subject.
# HOOK_UNDER_TEST overrides the entry copy the must-fail controls run;
# ENTRY_ROW runs one row alone.
# Inputs: hooks/lane-mail-check.sh, skills/orch/scripts/, skills/orch/runtime/,
# skills/agent-runtime/, skills/mailbox/scripts/.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HOOKS="$(cd "$TEST_DIR/.." && pwd)"
HOOK="${HOOK_UNDER_TEST:-$HOOKS/lane-mail-check.sh}"
REPO_ROOT="$(cd "$TEST_DIR/../.." && pwd -P)"
KEY_LIB="$REPO_ROOT/skills/agent-runtime/scripts/lib/key.sh"
TMP_ROOT="$(mktemp -d)" || { echo "lane-mail-check-test: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "lane-mail-check-test: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "lane-mail-check-test: scratch=resolve-failed" >&2; exit 1; }
ERR_FILE="$TMP_ROOT/stderr"
OUT_FILE="$TMP_ROOT/stdout"
PASS=0
FAIL=0

# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"
# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"

# Every hold file a row planted is removed and every build it started has
# ended before the root goes, so no planted cargo outlives the suite.
HOLDS=()
cleanup() {
  local hold
  for hold in ${HOLDS[@]+"${HOLDS[@]}"}; do rm -f -- "$hold"; done
  for hold in "$TMP_ROOT"/cache-*; do [ ! -d "$hold" ] || builds_done "$hold" || :; done
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT

# The runtime the built rows read is the one setup placed for this checkout's
# sources; without it a row would start a real build, so the suite refuses.
BUILT_CACHE="${AGENT_RUNTIME_CACHE:-$(bash -c '. "$1"; agent_runtime_cache' _ "$KEY_LIB")}"
BUILT_KEY="$(bash -c 'refuse() { exit 1; }; . "$1"; agent_runtime_key "$2"' _ "$KEY_LIB" "$REPO_ROOT/skills/orch/runtime")" ||
  { echo "lane-mail-check-test: key=unread" >&2; exit 1; }
[ -x "$BUILT_CACHE/bin/orch-runtime-$BUILT_KEY" ] ||
  { echo "lane-mail-check-test: runtime=unbuilt cache=$BUILT_CACHE run=skills/orch/scripts/setup" >&2; exit 1; }

# agent-runtime's planted cargo, first on PATH for a row that starts a build.
PLANTED="$TMP_ROOT/planted"
mkdir -p "$PLANTED" "$TMP_ROOT/home"
ln -s "$REPO_ROOT/skills/agent-runtime/tests/setup/cargo" "$PLANTED/cargo"
BASE_PATH="$PATH"

# The packages an install lays under DIR, each this checkout's own.
install_packages() { # DIR
  local package
  mkdir -p "$1"
  for package in orch mailbox agent-runtime; do ln -s "$REPO_ROOT/skills/$package" "$1/$package"; done
}

# A lane: a repository on its item's branch the real `lane-marker` launched (its
# marker and its mailbox directory), with its install under .agents and the
# entry copied into .claude/hooks; `plain` leaves the launch out, so the
# checkout has no mailbox directory.
LANE=""
lane() { # NAME [plain]
  LANE="$TMP_ROOT/$1"
  mkdir -p "$LANE/.claude/hooks"
  git -C "$LANE" init -q
  git -C "$LANE" config gc.auto 0
  git -C "$LANE" config maintenance.auto false
  git -C "$LANE" checkout -q -b ken-1
  git -C "$LANE" -c user.email=t@example.com -c user.name=t commit -q --allow-empty -m base
  [ "${2:-}" = plain ] || "$REPO_ROOT/skills/orch/scripts/lane-marker" "$LANE" KEN-1 >/dev/null
  install_packages "$LANE/.agents/skills"
  cp -- "$HOOK" "$LANE/.claude/hooks/lane-mail-check.sh"
}

# A directive the overseer sends the lane through the real `lane-mail`.
direct() { # TEXT
  printf '%s\n' "$1" > "$TMP_ROOT/directive.md"
  (cd "$LANE" && env -i "HOME=$TMP_ROOT/home" "PATH=$BASE_PATH" "GIT_CEILING_DIRECTORIES=$TMP_ROOT" \
    "$REPO_ROOT/skills/mailbox/scripts/lane-mail" send --item KEN-1 --root "$LANE" --directive \
    --file "$TMP_ROOT/directive.md" >/dev/null)
}

# The entry at HOOK-PATH run from CWD as a harness runs it: `{}` on stdin, an
# environment of HOME, PATH, the cache and ROW_ENV alone, and ARG... as the
# arm. RC is its exit status; stdout and stderr land in OUT_FILE and ERR_FILE.
RC=0
ROW_ENV=()
ROW_PATH="$BASE_PATH"
ROW_HOME="$TMP_ROOT/home"
run() { # HOOK-PATH CWD CACHE [ARG...]
  local hook="$1" cwd="$2" cache="$3"
  shift 3
  RC=0
  (cd "$cwd" && printf '{}' | env -i "HOME=$ROW_HOME" "PATH=$ROW_PATH" "TMPDIR=$TMP_ROOT" LANG=C.UTF-8 \
    GIT_CONFIG_NOSYSTEM=1 "GIT_CEILING_DIRECTORIES=$TMP_ROOT" "AGENT_RUNTIME_CACHE=$cache" \
    ${ROW_ENV[@]+"${ROW_ENV[@]}"} bash "$hook" "$@") >"$OUT_FILE" 2>"$ERR_FILE" || RC=$?
}

# What a setup line on stderr says: its word and which build it names, one
# `<word>:<name>` per line, joined by `;`.
said() {
  local line out="" word name
  while IFS= read -r line; do
    case "$line" in
      "lane-mail-check: "*) word=${line#lane-mail-check: }; word=${word%% *} ;;
      *) word="other" ;;
    esac
    case "$line" in
      */build/agent-runtime/*) name=agent-runtime ;;
      */build/orch-runtime/*) name=orch-runtime ;;
      *) name=none ;;
    esac
    out="$out;$word:$name"
  done <"$ERR_FILE"
  printf '%s' "${out#;}"
}

# Until no detached build of CACHE holds its claim.
builds_done() { # CACHE
  local n=0
  while [ "$n" -lt 120 ]; do
    [ -n "$(find "$1/build" -maxdepth 2 -name '*.lock' 2>/dev/null)" ] || return 0
    sleep 0.25
    n=$((n + 1))
  done
  echo "lane-mail-check-test: builds=unfinished cache=$1" >&2
  return 1
}

# A fresh cache for a row that starts a build, its builds run by the planted
# cargo: held while HOLD stands, failing where FAIL is set.
unbuilt() { # NAME [HOLD|-] [FAIL]
  CACHE="$TMP_ROOT/cache-$1"
  mkdir -p "$CACHE"
  ROW_PATH="$PLANTED:$BASE_PATH"
  ROW_ENV=("FAKE_CARGO_LOG=$TMP_ROOT/cargo-$1.log")
  if [ -n "${2:-}" ] && [ "$2" != - ]; then
    : > "$2"
    HOLDS+=("$2")
    ROW_ENV+=("FAKE_CARGO_HOLD=$2")
  fi
  [ -z "${3:-}" ] || ROW_ENV+=("FAKE_CARGO_EXIT=1")
}
built() {
  ROW_PATH="$BASE_PATH"
  ROW_ENV=()
  ROW_HOME="$TMP_ROOT/home"
}

row_mail() {
  built
  lane mail
  direct "rebase onto main"
  ROW_ENV=("CLAUDE_PROJECT_DIR=$LANE")
  run "$LANE/.claude/hooks/lane-mail-check.sh" "$LANE" "$BUILT_CACHE"
  assert_eq "RC=$RC first=$(first_line) stdout=$(cat "$OUT_FILE")" \
    "RC=2 first=lane-mail-check: unread=1 stdout=" \
    "a lane's unread mail holds its turn end through the entry with the verb's answer and exit"
}

row_arm() {
  built
  lane arm
  ROW_ENV=("CLAUDE_PROJECT_DIR=$LANE")
  run "$LANE/.claude/hooks/lane-mail-check.sh" "$LANE" "$BUILT_CACHE" lane
  assert_eq "RC=$RC stdout=$(cat "$OUT_FILE")" "RC=0 stdout=lane" \
    "the arm the entry is run with reaches the verb: the lane arm names a launched lane"
}

row_copilot() {
  built
  lane copilot
  direct "rebase onto main"
  # The harness runs the hook by the path it registered; the directory behind
  # that path is the install's own, spelled another way.
  mkdir -p "$LANE/.kendex-hooks" "$LANE/.github"
  cp -- "$HOOK" "$LANE/.kendex-hooks/lane-mail-check.sh"
  ln -s ../.kendex-hooks "$LANE/.github/hooks"
  ROW_ENV=("CLAUDE_PROJECT_DIR=$LANE")
  run "$LANE/.github/hooks/lane-mail-check.sh" "$LANE" "$BUILT_CACHE"
  assert_eq "RC=$RC decision=$(jq -r '.decision // "none"' "$OUT_FILE" 2>/dev/null || echo unread)" \
    "RC=0 decision=block" \
    "the harness is named by the directory as the harness spelled it: a Copilot install through a link answers in Copilot's shape"
}

row_global() {
  built
  lane global
  rm -f -- "$LANE/.agents/skills/mailbox" "$LANE/.agents/skills/orch" "$LANE/.agents/skills/agent-runtime"
  direct "rebase onto main"
  ROW_HOME="$TMP_ROOT/global-home"
  install_packages "$ROW_HOME/.agents/skills"
  mkdir -p "$ROW_HOME/.claude/hooks"
  cp -- "$HOOK" "$ROW_HOME/.claude/hooks/lane-mail-check.sh"
  ROW_ENV=("CLAUDE_PROJECT_DIR=$LANE")
  run "$ROW_HOME/.claude/hooks/lane-mail-check.sh" "$LANE" "$BUILT_CACHE"
  assert_eq "RC=$RC first=$(first_line)" "RC=2 first=lane-mail-check: unread=1" \
    "a global install's reader is the one the verb reads, for a project that installs none"
}

row_unlocatable() {
  built
  mkdir -p "$TMP_ROOT/bare/.claude/hooks"
  cp -- "$HOOK" "$TMP_ROOT/bare/.claude/hooks/lane-mail-check.sh"
  run "$TMP_ROOT/bare/.claude/hooks/lane-mail-check.sh" "$TMP_ROOT/bare" "$BUILT_CACHE"
  assert_eq "RC=$RC first=$(first_line) stdout=$(cat "$OUT_FILE")" \
    "RC=0 first=lane-mail-check: reader=unlocatable hook=$TMP_ROOT/bare/.claude/hooks stdout=" \
    "an install whose walk finds no mailbox reader is reported and passes, never held"
}

row_building() {
  lane building
  mkdir -p "$LANE/.github/hooks" "$LANE/sub"
  cp -- "$HOOK" "$LANE/.github/hooks/lane-mail-check.sh"
  unbuilt building "$TMP_ROOT/hold-building"
  local building="runtime-building:agent-runtime;runtime-building:orch-runtime"
  run "$LANE/.claude/hooks/lane-mail-check.sh" "$LANE" "$CACHE"
  assert_eq "RC=$RC said=$(said) stdout=$(cat "$OUT_FILE")" "RC=2 said=$building stdout=" \
    "an unbuilt runtime starts both builds and holds the turn end with their lines, agent-runtime's first"
  run "$LANE/.github/hooks/lane-mail-check.sh" "$LANE" "$CACHE"
  assert_eq "RC=$RC said=$(said) decision=$(jq -r '"\(.decision) \(.reason | split("\n") | length)"' "$OUT_FILE" 2>/dev/null || echo unread)" \
    "RC=0 said=$building decision=block 2" \
    "on Copilot the held turn end is a block decision carrying both lines"
  run "$LANE/.claude/hooks/lane-mail-check.sh" "$LANE" "$CACHE" halt
  assert_eq "RC=$RC said=$(said)" "RC=0 said=$building" \
    "a tool call while the build runs passes with the lines on stderr"
  run "$LANE/.claude/hooks/lane-mail-check.sh" "$LANE/sub" "$CACHE"
  assert_eq "RC=$RC said=$(said)" "RC=2 said=$building" \
    "a turn end from a directory below the root holds on the root's mailbox directory"
  rm -f -- "$TMP_ROOT/hold-building"
  builds_done "$CACHE"
}

row_failed() {
  lane failed
  unbuilt failed - fail
  run "$LANE/.claude/hooks/lane-mail-check.sh" "$LANE" "$CACHE"
  assert_eq "RC=$RC said=$(said)" "RC=2 said=runtime-building:agent-runtime;runtime-building:orch-runtime" \
    "the first turn end on an unbuilt runtime holds while its builds start"
  builds_done "$CACHE"
  run "$LANE/.claude/hooks/lane-mail-check.sh" "$LANE" "$CACHE"
  assert_eq "RC=$RC said=$(said)" "RC=2 said=runtime-unbuilt:agent-runtime;runtime-unbuilt:orch-runtime" \
    "a failed build holds the next turn end once with its lines"
  run "$LANE/.claude/hooks/lane-mail-check.sh" "$LANE" "$CACHE"
  assert_eq "RC=$RC said=$(said)" "RC=0 said=runtime-unbuilt:agent-runtime;runtime-unbuilt:orch-runtime" \
    "after that the turn end passes with the lines on stderr"
}

row_boxless() {
  lane boxless plain
  unbuilt boxless
  run "$LANE/.claude/hooks/lane-mail-check.sh" "$LANE" "$CACHE"
  assert_eq "RC=$RC stderr=$(first_line) stdout=$(cat "$OUT_FILE")" "RC=0 stderr=- stdout=" \
    "an unbuilt runtime in a checkout with no mailbox directory starts the build and passes silently"
  builds_done "$CACHE"
}

ROWS="mail arm copilot global unlocatable building failed boxless"
for name in ${ENTRY_ROW:-$ROWS}; do "row_$name"; done

# The must-fail controls, each a copy of the entry with one whole line
# replaced, run on the one row that holds that line. Skipped when this run is
# itself a control.
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  control() { # NAME ROW OLD NEW
    local mutant="$TMP_ROOT/$1.sh" count line status=0 red=no
    count=$(grep -Fxc -- "$3" "$HOOKS/lane-mail-check.sh") || count=0
    assert_eq "$count" 1 "control $1: the line it replaces stands once in the entry"
    while IFS= read -r line; do
      if [ "$line" = "$3" ]; then printf '%s\n' "$4"; else printf '%s\n' "$line"; fi
    done < "$HOOKS/lane-mail-check.sh" > "$mutant"
    ENTRY_ROW="$2" HOOK_UNDER_TEST="$mutant" bash "${BASH_SOURCE[0]}" > "$TMP_ROOT/$1.log" 2>&1 || status=$?
    ! grep -q '^  FAIL  ' "$TMP_ROOT/$1.log" || red=yes
    assert_eq "status=$status red=$red" "status=1 red=yes" "control $1: the $2 row turns red"
  }
  control exit-passed mail '  exit "$rc"' '  exit 0'
  control arm-dropped arm \
    'err=$("$scripts/orch-runtime" turn-end --hook-dir "$dir" "$@" 2>&1 1>&3 3>&-) || rc=$?' \
    'err=$("$scripts/orch-runtime" turn-end --hook-dir "$dir" 2>&1 1>&3 3>&-) || rc=$?'
  control dir-resolved copilot \
    'err=$("$scripts/orch-runtime" turn-end --hook-dir "$dir" "$@" 2>&1 1>&3 3>&-) || rc=$?' \
    'err=$("$scripts/orch-runtime" turn-end --hook-dir "$hook" "$@" 2>&1 1>&3 3>&-) || rc=$?'
  control reader-unexported global 'export LANE_MAIL_CLI=$reader' 'LANE_MAIL_READER=$reader'
  control unlocatable-held unlocatable \
    "  printf 'lane-mail-check: reader=unlocatable hook=%s\\n' \"\$dir\" >&2" \
    "  printf 'lane-mail-check: reader=unlocatable hook=%s\\n' \"\$dir\" >&2; exit 2"
  control root-cwd building \
    'root=$(git -C "${CLAUDE_PROJECT_DIR:-$PWD}" rev-parse --show-toplevel 2>/dev/null) || root=""' \
    'root=${CLAUDE_PROJECT_DIR:-$PWD}'
  control hold-ignored building 'if [ "$src" -eq 3 ] && [ "$#" -eq 0 ]; then' 'if false; then'
  control arm-ignored building 'if [ "$src" -eq 3 ] && [ "$#" -eq 0 ]; then' 'if [ "$src" -eq 3 ]; then'
  control copilot-unshaped building '  if [ "$copilot" -eq 0 ]; then exit 2; fi' '  exit 2'
  control prefix-kept building 'line=${line//agent-runtime-setup: /lane-mail-check: }' ':'
  control pass-held failed "[ -z \"\$line\" ] || printf '%s\\n' \"\$line\" >&2" \
    "[ -z \"\$line\" ] || { printf '%s\\n' \"\$line\" >&2; exit 2; }"
  control hold-unnamed boxless \
    'line=$("$scripts/setup" --detach ${root:+--hold "$root/tmp/lane-mail"} 2>&1) || src=$?' \
    'line=$("$scripts/setup" --detach 2>&1) || src=$?'
fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
