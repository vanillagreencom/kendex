#!/usr/bin/env bash
# The harness gate a fleet launch passes before anything else: a lane launched
# into an oversee fleet hands off at a share of its own window, which a harness
# adapter reads, and runs with its harness's own compaction off, so the handoff
# comes first. A harness no adapter reads is refused as unsupported-for-oversee,
# and a Pi launch whose settings would let Pi compact the session is refused as
# compaction-on. A launch naming no fleet state is judged on neither.
#
# Every row stops before a window could open: a launch the gate passes is
# handed an empty worktree path by the stubbed worktree CLI and refused later,
# so a row reads the gate's own line, or `passed` where stderr carries none.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
export ORCH_LANE_HOST=local
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
TMP_ROOT="$(cd "$(mktemp -d)" && pwd -P)"
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

PASS=0
FAIL=0
assert_eq() {
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$3" "$2" "$1"
  fi
}

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nprintf "term %%s\\n" "$*" >> "$OT_TERM_LOG"\n' > "$BIN/term"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh"
# The worktree CLI a launch the gate passes reaches next: an empty path, which
# open-terminal refuses by name before any window opens.
printf '#!/usr/bin/env bash\nexit 0\n' > "$BIN/worktree-stub"
chmod +x "$BIN/term" "$BIN/gh" "$BIN/worktree-stub"

# stage DIR — a copy of the orch scripts in a git repo of its own, so the
# project root, and the project .pi/settings.json the Pi rule reads, are the
# fixture's.
stage() {
  mkdir -p "$1/scripts"
  cp -R "$SCRIPTS_DIR/." "$1/scripts/"
  orch_fixture_shared_libs "$1"
  git -C "$1" init -q
}
REPO="$TMP_ROOT/repo"
stage "$REPO"
PI_AGENT="$TMP_ROOT/pi-agent"
mkdir -p "$PI_AGENT"

# launch NAME HARNESS FLEET [OT] — the gate's line open-terminal wrote, or
# `passed` where it wrote none, for a GUI launch of CC-1 on HARNESS; FLEET `yes`
# names a fleet state.
launch() { # NAME HARNESS FLEET [OT]
  local fleet=() rc=0 line
  [[ "$3" != yes ]] || fleet=(--state-dir "$TMP_ROOT/$1.fleet")
  ( cd "$REPO" && PATH="$BIN:$PATH" ORCH_STATE_DIR="$TMP_ROOT/$1.state" WORKTREE_CLI="$BIN/worktree-stub" \
    OT_TERM_LOG="$TMP_ROOT/$1.term" TERMINAL=term TMUX= PI_CODING_AGENT_DIR="$PI_AGENT" \
    "${4:-$REPO/scripts/open-terminal}" --ghostty --harness "$2" ${fleet[@]+"${fleet[@]}"} CC-1 ) \
    >/dev/null 2>"$TMP_ROOT/$1.err" || rc=$?
  line="$(grep -E '^open-terminal: (unsupported-for-oversee|compaction-on) ' "$TMP_ROOT/$1.err" || true)"
  printf '%s' "${line:-passed}"
}

PASSED=passed
PI_FILE="file=$PI_AGENT/settings.json"

echo "=== a fleet launch runs only a harness whose context an adapter reads ==="
# `name|harness|fleet|user settings|project settings|answer`: `-` is no file.
while IFS='|' read -r name harness fleet user project want; do
  rm -f -- "$PI_AGENT/settings.json" "$REPO/.pi/settings.json"
  [[ "$user" == - ]] || printf '%s\n' "$user" > "$PI_AGENT/settings.json"
  if [[ "$project" != - ]]; then mkdir -p "$REPO/.pi"; printf '%s\n' "$project" > "$REPO/.pi/settings.json"; fi
  case "$want" in
    passed) want="$PASSED" ;;
    compaction-on) want="open-terminal: compaction-on harness=pi $PI_FILE" ;;
    unreadable) want="open-terminal: compaction-on harness=pi file=unreadable" ;;
    unsupported) want="open-terminal: unsupported-for-oversee harness=$harness" ;;
  esac
  assert_eq "$(launch "$name" "$harness" "$fleet")" "$want" "$name: $want"
done <<'ROWS'
claude in a fleet passes|claude|yes|-|-|passed
codex in a fleet passes|codex|yes|-|-|passed
opencode in a fleet is refused|opencode|yes|-|-|unsupported
opencode with no fleet passes|opencode|no|-|-|passed
pi in a fleet with compaction at its default is refused|pi|yes|-|-|compaction-on
pi in a fleet with compaction on is refused|pi|yes|{"compaction":{"enabled":true}}|-|compaction-on
pi in a fleet with compaction off passes|pi|yes|{"compaction":{"enabled":false}}|-|passed
pi in a fleet whose project turns compaction back on is refused|pi|yes|{"compaction":{"enabled":false}}|{"compaction":{"enabled":true}}|compaction-on
pi in a fleet with a settings file it cannot read is refused|pi|yes|not json|-|unreadable
pi with no fleet passes whatever its settings|pi|no|-|-|passed
ROWS
rm -f -- "$PI_AGENT/settings.json" "$REPO/.pi/settings.json"

echo "=== must-fail controls ==="
# Each rule's refusal replaced by a pass: the row it holds reads as passed.
UNSUPPORTED_CTRL="$TMP_ROOT/unsupported-ctrl"
stage "$UNSUPPORTED_CTRL"
mutate_file "$UNSUPPORTED_CTRL/scripts/open-terminal" \
  '*) ot_message unsupported-for-oversee "harness=$HARNESS" >&2; exit 1 ;;' '*) ;;'
assert_eq "$(launch unsupported-ctrl opencode yes "$UNSUPPORTED_CTRL/scripts/open-terminal")" "$PASSED" \
  "control: without its refusal an opencode fleet launch passes the gate"
COMPACTION_CTRL="$TMP_ROOT/compaction-ctrl"
stage "$COMPACTION_CTRL"
mutate_file "$COMPACTION_CTRL/scripts/open-terminal" \
  '0) ot_message compaction-on "harness=pi"' '0) : ot_message compaction-on "harness=pi"'
assert_eq "$(launch compaction-ctrl pi yes "$COMPACTION_CTRL/scripts/open-terminal")" "$PASSED" \
  "control: without its refusal a pi fleet launch Pi would compact passes the gate"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
