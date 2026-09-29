#!/usr/bin/env bash
# The Copilot arm of open-terminal's fleet gate: a Copilot fleet launch runs
# only where the lane-mail-check and lane-mail-compact hooks are in a Copilot
# hook scope the lane loads, and where the launch can make the lane's
# COPILOT_HOME run the kendex-lane-context extension, its context reader:
# the extension copied into that home's extensions/kendex-lane-context/ and
# its settings.json turning enabledFeatureFlags.EXTENSIONS on. Refusals are
# `unsupported-for-oversee harness=copilot` with reason=no-context-hooks or
# reason=no-context-reader. The harness-gate suite holds the other harnesses.
#
# With the hooks in place, the gate asks `kendex hooks-off` whether a Copilot
# settings file of that home and worktree switches every hook off, refusing as
# reason=hooks-disabled where one does and reason=hooks-unjudged where kendex
# cannot answer. Those rows run the real kendex on PATH, whose answer comes
# from crates/cli/src/commands/hooks_off.rs over the reader in
# crates/core/src/harness/copilot/settings.rs. Where no kendex there answers
# hooks-off they are skipped by name, and ORCH_REQUIRE_KENDEX set turns that
# skip into a failure. Every other row asks a stub that answers null.
#
# The hooks are judged in the item's worktree, which the stubbed worktree CLI
# makes as a fresh copy of BASE, the item's base, or on --relaunch keeps as it
# stands. That worktree is no git repository, so a launch the gate passes
# stops at its lane marker before any window opens. A row reads the gate's
# own line, or `passed` where stderr carries none.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
export ORCH_LANE_HOST=local
# shellcheck source=lib/shared-skill-libs.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/shared-skill-libs.sh"
# shellcheck source=lib/growth-state.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/growth-state.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$TEST_DIR/.." && pwd)/scripts"
TMP_ROOT="$(mktemp -d)" || { echo "open-terminal-copilot-context: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "open-terminal-copilot-context: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "open-terminal-copilot-context: scratch=resolve-failed" >&2; exit 1; }
trap 'chmod -R u+rwx -- "${TMP_ROOT:?}" 2>/dev/null || :; rm -rf -- "${TMP_ROOT:?}"' EXIT

# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
printf '#!/usr/bin/env bash\nprintf "term %%s\\n" "$*" >> "$OT_TERM_LOG"\n' > "$BIN/term"
printf '#!/usr/bin/env bash\nexit 1\n' > "$BIN/gh"
# The worktree CLI: `create` makes OT_WT a copy of OT_BASE and `create
# --reuse` keeps the OT_WT that stands, each printing its path; `exists` says
# whether OT_WT stands and `merged` answers not merged.
cat > "$BIN/worktree-stub" <<'STUB'
#!/usr/bin/env bash
case "$1" in
  exists) if [[ -d "$OT_WT" ]]; then echo true; else echo false; fi ;;
  merged) exit 1 ;;
  create)
    if [[ " $* " != *" --reuse "* ]]; then mkdir -p "$OT_WT" && cp -R "$OT_BASE/." "$OT_WT/"; fi
    printf '%s\n' "$OT_WT"
    ;;
  *) exit 0 ;;
esac
STUB
chmod +x "$BIN/term" "$BIN/gh" "$BIN/worktree-stub"

# The real kendex the hooks-off rows ask, found on the PATH this suite was
# started with and run in a home of its own, so it never writes the
# developer's. KX_REAL is its directory, empty where no kendex there answers
# hooks-off.
REAL_KENDEX="$(command -v kendex || true)"
KX_REAL=""
if [[ -n "$REAL_KENDEX" ]]; then
  mkdir -p "$TMP_ROOT/kendex-real" "$TMP_ROOT/kendex-home"
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export HOME=%q XDG_CONFIG_HOME=%q XDG_CACHE_HOME=%q XDG_DATA_HOME=%q KENDEX_BACKGROUND_REFRESH=off\n' \
      "$TMP_ROOT/kendex-home" "$TMP_ROOT/kendex-home/.config" "$TMP_ROOT/kendex-home/.cache" "$TMP_ROOT/kendex-home/.local/share"
    printf 'exec %q "$@"\n' "$REAL_KENDEX"
  } > "$TMP_ROOT/kendex-real/kendex"
  chmod +x "$TMP_ROOT/kendex-real/kendex"
  # A kendex without the verb reads `hooks-off` as a source to add, and its
  # --help as the whole program's, so the probe is a query of an empty home.
  mkdir -p "$TMP_ROOT/kendex-probe"
  if [[ "$("$TMP_ROOT/kendex-real/kendex" hooks-off --copilot-home "$TMP_ROOT/kendex-probe" \
    --project "$TMP_ROOT/kendex-probe" 2>/dev/null)" == '{"switched_off_by":null}' ]]; then
    KX_REAL="$TMP_ROOT/kendex-real"
  fi
fi
# The stub every other row asks: null, or as OT_KENDEX says, a failure with
# its own words, an empty answer, or an object without the key.
mkdir -p "$TMP_ROOT/kendex-stub"
cat > "$TMP_ROOT/kendex-stub/kendex" <<'STUB'
#!/usr/bin/env bash
case "${OT_KENDEX:-null}" in
  null) printf '{"switched_off_by":null}\n' ;;
  fail) echo "kendex-stub: settings unread" >&2; exit 3 ;;
  empty) ;;
  keyless) printf '{}\n' ;;
esac
STUB
chmod +x "$TMP_ROOT/kendex-stub/kendex"

# stage DIR — a copy of the orch scripts in a git repo of its own, so the
# project root, and its project hook scope, are the fixture's.
stage() {
  mkdir -p "$1/scripts"
  cp -R "$SCRIPTS_DIR/." "$1/scripts/"
  orch_fixture_shared_libs "$1"
  git -C "$1" init -q
}
REPO="$TMP_ROOT/repo"
stage "$REPO"
# Whether a mode-000 file or a mode-555 directory can deny this writer: root
# ignores both.
CAN_DENY=1
[[ "$(id -u)" -ne 0 ]] || CAN_DENY=0

# The Copilot home every launch runs under, so the operator's own is never
# read or written.
COP_HOME="$TMP_ROOT/copilot-home"
COP_SETTINGS="$COP_HOME/settings.json"
COP_EXT="$COP_HOME/extensions/kendex-lane-context/extension.mjs"
EXTENSION="$SCRIPTS_DIR/copilot-lane-context/extension.mjs"

# The item's base, which a fresh worktree is a copy of, and where each
# launch's worktree stands.
BASE="$TMP_ROOT/base"
WTS="$TMP_ROOT/wt"

# launch NAME [ARG...] — a fleet launch of CC-1 on copilot under the home, in
# the worktree WTS/NAME, with ARGs; OT names another copy, and KENDEX_DIR the
# directory of the kendex it asks, ahead of any other, the stub where unset.
# The gate's line open-terminal wrote, or `passed`.
launch() { # NAME [ARG...]
  local name="$1" line
  shift
  ( cd "$REPO" && PATH="${KENDEX_DIR:-$TMP_ROOT/kendex-stub}:$BIN:$PATH" ORCH_STATE_DIR="$TMP_ROOT/$name.state" WORKTREE_CLI="$BIN/worktree-stub" \
    OT_BASE="$BASE" OT_WT="$WTS/$name" \
    OT_TERM_LOG="$TMP_ROOT/$name.term" TERMINAL=term TMUX="" COPILOT_HOME="$COP_HOME" \
    "${OT:-$REPO/scripts/open-terminal}" --ghostty --state-dir "$TMP_ROOT/fleet" --harness copilot \
      --launch-flags '--model claude-opus-5 --reasoning-effort high' "$@" CC-1 ) \
    >"$TMP_ROOT/$name.out" 2>"$TMP_ROOT/$name.err" || :
  line="$(grep -E '^open-terminal: unsupported-for-oversee ' "$TMP_ROOT/$name.err" || true)"
  printf '%s' "${line:-passed}"
}

# copilot_world HOOKS SETTINGS — HOOKS is where the two Copilot hooks are
# (project: on the item's base; caller: only in the caller's checkout; global;
# half: lane-mail-check alone on the base; none); SETTINGS the home's
# settings.json, `-` for no file. No worktree stands.
copilot_world() { # HOOKS SETTINGS
  local dir="" names="lane-mail-check lane-mail-compact" name
  chmod -R u+rwx -- "$COP_HOME" 2>/dev/null || :
  rm -rf -- "${REPO:?}/.github" "${COP_HOME:?}" "${BASE:?}" "${WTS:?}"
  mkdir -p "$COP_HOME" "$BASE"
  case "$1" in
    project) dir="$BASE/.github/hooks" ;;
    caller) dir="$REPO/.github/hooks" ;;
    global) dir="$COP_HOME/hooks" ;;
    half) dir="$BASE/.github/hooks" names=lane-mail-check ;;
  esac
  if [[ -n "$dir" ]]; then
    mkdir -p "$dir"
    for name in $names; do : > "$dir/$name.sh"; : > "$dir/$name.json"; done
  fi
  [[ "$2" == - ]] || printf '%s\n' "$2" > "$COP_SETTINGS"
}
# The home afterwards: its EXTENSIONS flag, and whether the extension there is
# the one this checkout ships.
flag_after() {
  [[ -e "$COP_SETTINGS" ]] || { echo none; return; }
  jq -c '.enabledFeatureFlags.EXTENSIONS | if . == null then "unset" end' "$COP_SETTINGS" 2>/dev/null || echo unreadable
}
# A file's inode, which a copy renamed over it changes and one left alone keeps.
inode() { ls -i -- "$1" | awk '{print $1}'; }
ext_after() {
  [[ -e "$COP_EXT" ]] || { echo none; return; }
  cmp -s "$EXTENSION" "$COP_EXT" && echo shipped || echo other
}

# no_hooks NAME — the hooks refusal of the launch NAME, naming its worktree.
no_hooks() { printf '%s' "open-terminal: unsupported-for-oversee harness=copilot reason=no-context-hooks item=CC-1 scope=$WTS/$1/.github/hooks scope=$COP_HOME/hooks"; }
NO_HOOKS="$(no_hooks row)"
NO_READER="open-terminal: unsupported-for-oversee harness=copilot reason=no-context-reader file=$COP_SETTINGS"

echo "=== a Copilot fleet launch runs only where its hooks and its context reader are where it loads them ==="
# `label|hooks|settings|gate line|flag after|extension after`
while IFS='|' read -r label hooks settings want flag ext; do
  copilot_world "$hooks" "$settings"
  assert_eq "$(launch row) flag=$(flag_after) ext=$(ext_after)" "$want flag=$flag ext=$ext" "$label"
done <<ROWS
no hook scope holding the two hooks is refused, naming the worktree's and the global|none|-|$NO_HOOKS|true|shipped
a scope holding lane-mail-check alone is refused the same way|half|-|$NO_HOOKS|true|shipped
hooks in the caller's checkout alone, not on the base the worktree is made from, are refused|caller|-|$NO_HOOKS|true|shipped
the project hooks on the base pass, and the home is made to load the extension|project|-|passed|true|shipped
the global hooks pass the same way|global|{"banner":"never"}|passed|true|shipped
a flag already on stands|project|{"enabledFeatureFlags":{"EXTENSIONS":true}}|passed|true|shipped
another flag beside it is kept|project|{"enabledFeatureFlags":{"AUTO_APPROVAL":true}}|passed|true|shipped
a flag the operator set false, with no status line to fall back on, is refused, and never overridden|project|{"enabledFeatureFlags":{"EXTENSIONS":false}}|$NO_READER detail=disabled cause=no-status-line|false|shipped
a flag that is no boolean is refused as unreadable|project|{"enabledFeatureFlags":{"EXTENSIONS":"yes"}}|$NO_READER detail=unreadable|"yes"|shipped
flags that are no object are refused as unreadable|project|{"enabledFeatureFlags":"EXTENSIONS"}|$NO_READER detail=unreadable|unreadable|shipped
settings that are no JSON object are refused as unreadable|project|null|$NO_READER detail=unreadable|"unset"|shipped
settings that are no JSON at all are refused as unreadable|project|not json|$NO_READER detail=unreadable|unreadable|shipped
ROWS
copilot_world global '{"banner":"never","enabledFeatureFlags":{"AUTO_APPROVAL":true}}'
launch keep >/dev/null
assert_eq "$(jq -c . "$COP_SETTINGS")" '{"banner":"never","enabledFeatureFlags":{"AUTO_APPROVAL":true,"EXTENSIONS":true}}' \
  "the settings already there are kept beside the flag"

echo "=== a relaunch is judged on the worktree it keeps ==="
# The base carries the hooks now; the kept worktree predates them.
copilot_world project -
mkdir -p "$WTS/relaunch"
assert_eq "$(launch relaunch --relaunch)" "$(no_hooks relaunch)" \
  "a relaunch into a worktree that lacks the hooks its base now carries is refused"
mkdir -p "$WTS/relaunch-held"
cp -R "$BASE/.github" "$WTS/relaunch-held/"
assert_eq "$(launch relaunch-held --relaunch)" "passed" "a relaunch into a worktree that holds them passes"

echo "=== the extension is rewritten only where it differs ==="
copilot_world project '{"enabledFeatureFlags":{"EXTENSIONS":true}}'
mkdir -p "${COP_EXT%/*}"
printf 'stale\n' > "$COP_EXT"
assert_eq "$(launch stale) ext=$(ext_after)" "passed ext=shipped" "a stale copy is replaced by the shipped one"
cp "$EXTENSION" "$COP_EXT"
BEFORE="$(inode "$COP_EXT")"
launch same >/dev/null
assert_eq "$(inode "$COP_EXT")" "$BEFORE" "a copy identical to the shipped one is left as it is, never renamed over"

echo "=== a linked settings file is written through to its target ==="
copilot_world project -
mkdir -p "$TMP_ROOT/harness"
printf '{"banner":"never"}\n' > "$TMP_ROOT/harness/settings.json"
ln -s ../harness/settings.json "$COP_SETTINGS"
assert_eq "$(launch linked) link=$(readlink "$COP_SETTINGS") target=$(jq -c . "$TMP_ROOT/harness/settings.json")" \
  'passed link=../harness/settings.json target={"banner":"never","enabledFeatureFlags":{"EXTENSIONS":true}}' \
  "the link stays and its target turns the flag on"

echo "=== a write that fails is refused as unwritable ==="
if [[ "$CAN_DENY" -eq 1 ]]; then
  copilot_world project -
  mkdir -p "$COP_HOME/extensions"
  chmod 555 "$COP_HOME/extensions"
  assert_eq "$(launch ext-unwritable) ext=$(ext_after)" \
    "open-terminal: unsupported-for-oversee harness=copilot reason=no-context-reader file=$COP_EXT detail=unwritable ext=none" \
    "an extensions directory that cannot be written is refused, naming the extension's path"
  copilot_world project -
  mkdir -p "${COP_EXT%/*}"
  cp "$EXTENSION" "$COP_EXT"
  chmod 555 "$COP_HOME"
  assert_eq "$(launch settings-unwritable) flag=$(flag_after)" "$NO_READER detail=unwritable flag=none" \
    "a home whose settings cannot be written is refused, naming its settings"
  chmod 755 "$COP_HOME"
fi
stage "$TMP_ROOT/no-source"
rm -f -- "$TMP_ROOT/no-source/scripts/copilot-lane-context/extension.mjs"
copilot_world project -
assert_eq "$(OT="$TMP_ROOT/no-source/scripts/open-terminal" launch no-source)" \
  "open-terminal: unsupported-for-oversee harness=copilot reason=no-context-reader file=$TMP_ROOT/no-source/scripts/copilot-lane-context/extension.mjs detail=unreadable" \
  "an install missing the extension beside open-terminal is refused, naming the missing file"

echo "=== a kendex that cannot say whether the hooks run refuses the lane ==="
unjudged() { printf '%s' "open-terminal: unsupported-for-oversee harness=copilot reason=hooks-unjudged item=CC-1 exit=$1"; }
# `label|stub answer|gate line`
while IFS='|' read -r label answer want; do
  copilot_world project -
  assert_eq "$(OT_KENDEX="$answer" launch "unjudged-$answer")" "$want" "$label"
done <<ROWS
a kendex that fails the query is refused, naming its exit status|fail|$(unjudged 3)
an empty answer is refused, never read as no file|empty|$(unjudged answer)
an answer without switched_off_by is refused|keyless|$(unjudged answer)
ROWS
assert_eq "$(grep -c '^kendex-stub: settings unread$' "$TMP_ROOT/unjudged-fail.err" || true)" 1 \
  "the failed query's own words follow its refusal"

echo "=== disableAllHooks, as the real kendex reads it ==="
if [[ -z "$KX_REAL" ]]; then
  if [[ -n "${ORCH_REQUIRE_KENDEX:-}" ]]; then
    fail "ORCH_REQUIRE_KENDEX is set and no kendex on PATH answers hooks-off"
  else
    printf '  skip  no kendex on PATH answers hooks-off; the disableAllHooks rows and their controls did not run\n'
  fi
else
  disabled() { printf '%s' "open-terminal: unsupported-for-oversee harness=copilot reason=hooks-disabled item=CC-1 file=$1"; }
  # real_world WHERE — the project hooks on the base, and disableAllHooks
  # true in the home's settings.json (home), in the base's Claude Code
  # settings (claude), or in the home and set false again by the base's
  # Copilot settings, a later layer (cleared).
  real_world() { # WHERE
    copilot_world project -
    case "$1" in
      home) printf '{"disableAllHooks":true}\n' > "$COP_SETTINGS" ;;
      claude) mkdir -p "$BASE/.claude" && printf '{"disableAllHooks":true}\n' > "$BASE/.claude/settings.json" ;;
      cleared)
        printf '{"disableAllHooks":true}\n' > "$COP_SETTINGS"
        mkdir -p "$BASE/.github/copilot" && printf '{"disableAllHooks":false}\n' > "$BASE/.github/copilot/settings.json" ;;
    esac
  }
  # `label|world|launch|gate line`
  while IFS='|' read -r label world name want; do
    real_world "$world"
    assert_eq "$(KENDEX_DIR="$KX_REAL" launch "$name")" "$want" "$label"
  done <<ROWS
true in the home's settings is refused, naming that file|home|real-home|$(disabled "$COP_SETTINGS")
true in the worktree's Claude Code settings is refused, naming the worktree's copy|claude|real-claude|$(disabled "$WTS/real-claude/.claude/settings.json")
true in the home and false in the worktree's Copilot settings, a later layer, passes|cleared|real-cleared|passed
ROWS
  # real_ctrl NAME OLD NEW — a staged copy of open-terminal with OLD cut.
  real_ctrl() { stage "$TMP_ROOT/$1" && mutate_file "$TMP_ROOT/$1/scripts/open-terminal" "$2" "$3"; }
  real_ctrl off-ctrl '  [[ -n "$off" ]] || return 0' '  return 0'
  real_world home
  assert_eq "$(OT="$TMP_ROOT/off-ctrl/scripts/open-terminal" KENDEX_DIR="$KX_REAL" launch off-ctrl)" passed \
    "control: without the hooks-disabled refusal a lane whose home switches every hook off passes"
  real_ctrl project-ctrl 'hooks-off --copilot-home "$home" --project "$1"' 'hooks-off --copilot-home "$home" --project "$CLAIM_ROOT"'
  real_world claude
  assert_eq "$(OT="$TMP_ROOT/project-ctrl/scripts/open-terminal" KENDEX_DIR="$KX_REAL" launch project-ctrl)" passed \
    "control: asked of the caller's checkout, the worktree's own switch is never read"
  real_world cleared
  assert_eq "$(OT="$TMP_ROOT/project-ctrl/scripts/open-terminal" KENDEX_DIR="$KX_REAL" launch project-ctrl-cleared)" \
    "$(disabled "$COP_SETTINGS")" \
    "control: asked of the caller's checkout, the worktree's later false never clears the home's true"
fi

echo "=== must-fail controls ==="
# copilot_ctrl NAME OLD NEW HOOKS SETTINGS WANT LABEL — the rule OLD cut from
# a staged copy of open-terminal, and what a launch in that world reads then.
copilot_ctrl() { # NAME OLD NEW HOOKS SETTINGS WANT LABEL
  stage "$TMP_ROOT/$1"
  mutate_file "$TMP_ROOT/$1/scripts/open-terminal" "$2" "$3"
  copilot_world "$4" "$5"
  assert_eq "$(OT="$TMP_ROOT/$1/scripts/open-terminal" launch "$1") flag=$(flag_after)" "$6" "$7"
}
copilot_ctrl admit-ctrl '    copilot) [[ "$LANE_HOST" == local ]] ||' '    copilot-x) [[ "$LANE_HOST" == local ]] ||' project - \
  "open-terminal: unsupported-for-oversee harness=copilot flag=none" \
  "control: without its admission a copilot fleet launch is refused as a harness nothing judges"
copilot_ctrl hooks-ctrl '  if ! lane_context_copilot_hooks "$1" "$home" >/dev/null; then' '  if false; then' \
  none - "passed flag=true" "control: without the hook check a copilot fleet lane nothing would judge passes"
copilot_ctrl caller-ctrl '  if ! lane_context_copilot_hooks "$1" "$home" >/dev/null; then' \
  '  if ! lane_context_copilot_hooks "$CLAIM_ROOT" "$home" >/dev/null; then' \
  caller - "passed flag=true" "control: judged in the caller's checkout, hooks the worktree lacks pass"
stage "$TMP_ROOT/reuse-ctrl"
mutate_file "$TMP_ROOT/reuse-ctrl/scripts/open-terminal" \
  '  if [[ "$COPILOT_HOOKS_GATED" == true ]] && ! copilot_hooks_gate "$wt" "$item"; then' \
  '  if [[ "$COPILOT_HOOKS_GATED" == true && "$RELAUNCH" != true ]] && ! copilot_hooks_gate "$wt" "$item"; then'
copilot_world project -
mkdir -p "$WTS/reuse-ctrl"
assert_eq "$(OT="$TMP_ROOT/reuse-ctrl/scripts/open-terminal" launch reuse-ctrl --relaunch)" "passed" \
  "control: without the relaunch's check a kept worktree that lacks the hooks passes"
copilot_ctrl reader-ctrl '  copilot_context_configure "$home" && return 0' '  return 0' \
  project '{"enabledFeatureFlags":{"EXTENSIONS":false}}' "passed flag=false" \
  "control: without the reader's refusal a copilot fleet lane whose home loads no extension passes unmeasured"
copilot_ctrl disabled-ctrl '      | if $on == true then "enabled" elif $on == false then "disabled"' '      | if $on == true then "enabled"' \
  project '{"enabledFeatureFlags":{"EXTENSIONS":false}}' "$NO_READER detail=unreadable flag=false" \
  "control: without the disabled rule the operator's own false reads as a fault"
copilot_ctrl boolean-ctrl '        elif $on == null then "absent" else "unreadable" end' '        else "absent" end' \
  project '{"enabledFeatureFlags":{"EXTENSIONS":"yes"}}' "passed flag=true" \
  "control: without the boolean rule a flag the operator wrote is overwritten"
copilot_ctrl link-ctrl '  while [[ -L "$target" ]]; do' '  while false; do' \
  project - "passed flag=true" "control: the link rule's copy launches as the world it replaces"
copilot_world project -
printf '{"banner":"never"}\n' > "$TMP_ROOT/harness/settings.json"
ln -s ../harness/settings.json "$COP_SETTINGS"
OT="$TMP_ROOT/link-ctrl/scripts/open-terminal" launch link-ctrl-linked >/dev/null
assert_eq "$([[ -L "$COP_SETTINGS" ]] && echo link || echo file)" "file" \
  "control: without the link rule a linked settings file is replaced by a file of its own"
copilot_ctrl cmp-ctrl '  if ! cmp -s -- "$source" "$dest"; then' '  if true; then' \
  project '{"enabledFeatureFlags":{"EXTENSIONS":true}}' "passed flag=true" "control: the content rule's copy launches as the world it replaces"
mkdir -p "${COP_EXT%/*}"
cp "$EXTENSION" "$COP_EXT"
BEFORE="$(inode "$COP_EXT")"
OT="$TMP_ROOT/cmp-ctrl/scripts/open-terminal" launch cmp-ctrl-same >/dev/null
assert_eq "$([[ "$(inode "$COP_EXT")" == "$BEFORE" ]] && echo kept || echo rewritten)" "rewritten" \
  "control: without the content rule an identical copy is rewritten"
OT_KENDEX=fail copilot_ctrl unjudged-ctrl '  if [[ "$query_rc" != 0 ]]; then' '  if false; then' project - "passed flag=true" \
  "control: without the unjudged refusal a lane whose kendex failed the query passes"
OT_KENDEX=empty copilot_ctrl empty-ctrl "  [[ \"\$query_rc\" -ne 0 ]] || off=\"\$(jq -rn 'input" "  [[ \"\$query_rc\" -ne 0 ]] || off=\"\$(jq -r '." \
  project - "passed flag=true" "control: read with a bare filter, an empty answer passes as no file"
OT_KENDEX=keyless copilot_ctrl keyless-ctrl '    | if type == "object" and has("switched_off_by")' '    | if type == "object"' \
  project - "passed flag=true" "control: without the key rule an answer that names nothing passes as no file"
copilot_ctrl source-ctrl '  [[ -r "$source" ]] || return 1' '  :' project - "passed flag=true" \
  "control: the source rule's copy launches as the world it replaces"
rm -f -- "$TMP_ROOT/source-ctrl/scripts/copilot-lane-context/extension.mjs"
copilot_world project -
assert_eq "$(OT="$TMP_ROOT/source-ctrl/scripts/open-terminal" launch source-ctrl-missing)" \
  "open-terminal: unsupported-for-oversee harness=copilot reason=no-context-reader file=$COP_EXT detail=unwritable" \
  "control: without the source rule a missing extension is misnamed as a home that cannot be written"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
