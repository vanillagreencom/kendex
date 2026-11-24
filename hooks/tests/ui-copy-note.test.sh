#!/usr/bin/env bash
# Surface: ui-copy-note.sh. Inputs: that hook, tests/lib/assert.sh, the
# decider settings reader, code-quality UI reference, the orch runtime's
# record-qa-decision scan (its QA_UI_PATHS matcher, through
# orch/scripts/orch-runtime, which needs a built runtime), and the tracked
# Claude Code and Codex registrations. A Pi row runs the hook the way the
# pi-hooks carrier spawns it, with the KENDEX_HOOK_SCOPE and KENDEX_HOOK_ROOT
# its registry suite holds the carrier to.
set -euo pipefail
TEST_DIR=$(cd -- "${BASH_SOURCE[0]%/*}" && pwd -P)
CATALOG=$(cd -- "$TEST_DIR/../.." && pwd -P)
HOOK=${HOOK_UNDER_TEST:-$TEST_DIR/../ui-copy-note.sh}
PASS=0 FAIL=0
TMP_ROOT=$(mktemp -d) || { echo 'ui-copy-note: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'ui-copy-note: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT=$(cd -- "$TMP_ROOT" && pwd -P) || { echo 'ui-copy-note: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
. "$TEST_DIR/lib/assert.sh"

unset QA_UI_PATHS QA_PERF_PATHS KENDEX_ENV_FILE ORCH_STATE_DIR CODEX_HOME KENDEX_HOOK_SCOPE KENDEX_HOOK_ROOT
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_OPTIONAL_LOCKS COPILOT_PROJECT_DIR
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
case "$OSTYPE" in msys* | cygwin*) export MSYS=winsymlinks:nativestrict ;; esac
export HOME="$TMP_ROOT/home" XDG_CONFIG_HOME="$TMP_ROOT/home/config" XDG_DATA_HOME="$TMP_ROOT/home/data"
export USERPROFILE="$HOME"
export XDG_CACHE_HOME="$TMP_ROOT/home/cache" XDG_STATE_HOME="$TMP_ROOT/home/state"
REPO="$TMP_ROOT/project"
FALLBACK="$TMP_ROOT/no-setting"
INSTALL="$TMP_ROOT/install"
GUIDE="$INSTALL/.agents/skills/code-quality/references/ui.md"
install_skills() { # SKILLS-DIRECTORY
  mkdir -p "$1/decider/scripts/lib" "$1/code-quality/references"
  cp -- "$CATALOG/skills/decider/scripts/lib/kendex-env.sh" "$1/decider/scripts/lib/kendex-env.sh"
  cp -- "$CATALOG/skills/code-quality/references/ui.md" "$1/code-quality/references/ui.md"
}
mkdir -p "$HOME" "$REPO/shell" "$FALLBACK"
install_skills "$INSTALL/.agents/skills"
git -C "$REPO" init -q
git -C "$REPO" config user.email ui-copy@example.com
git -C "$REPO" config user.name 'UI copy suite'
printf '[env]\nQA_UI_PATHS = "shell/**/*.qml ui/"\n' >"$REPO/kendex.settings.toml"

edit() { # TOOL CWD PATH SESSION [AGENT]
  jq -cn --arg t "$1" --arg c "$2" --arg p "$3" --arg s "$4" --arg a "${5:-}" \
    '{tool_name:$t,cwd:$c,session_id:$s,agent_id:$a,tool_input:{file_path:$p}}'
}

check() { # ROW HARNESS PAYLOAD FIRST-LINE [DIAGNOSTIC CAUSE]
  local install_dir status=0 context='' first
  case "$2" in
    claude | codex) install_dir="${FIXTURE_INSTALL:-$INSTALL}/.$2/hooks" ;;
    codex-global) install_dir="$CODEX_HOME/hooks" ;;
    codex-relative) install_dir="$FIXTURE_INSTALL/$CODEX_HOME/hooks" ;;
    pi-global) install_dir="$KENDEX_HOOK_ROOT/kendex/hooks" ;;
    pi-project) install_dir="$KENDEX_HOOK_ROOT/.pi/kendex/hooks" ;;
    claude-global) install_dir="$HOME/.claude/hooks" ;;
    unbound) install_dir="$TMP_ROOT/unbound/hooks" ;;
  esac
  mkdir -p "$install_dir"
  cp -- "$HOOK" "$install_dir/ui-copy-note.sh"
  if [ -n "${FIXTURE_COMMAND:-}" ]; then
    (cd -- "$FIXTURE_INSTALL" && "$BASH" -c "$FIXTURE_COMMAND") \
      <<<"$3" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr" || status=$?
  else
    "$BASH" "$install_dir/ui-copy-note.sh" <<<"$3" >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr" || status=$?
  fi
  if [ -s "$TMP_ROOT/stdout" ]; then
    context=$(jq -ser 'select(length == 1) | .[0].hookSpecificOutput | select(.hookEventName == "PostToolUse") | .additionalContext | strings' "$TMP_ROOT/stdout") || context=invalid-envelope
  fi
  first=${context%%$'\n'*}
  assert_eq "$status" 0 "$1: allows the edit"
  assert_eq "$(cat -- "$TMP_ROOT/stderr")" '' "$1: no hidden diagnostic"
  assert_eq "$first" "$4" "$1: keyed context"
  case "$4" in
    'ui-copy-note: path='*)
      case "$context" in *'§ UI copy in '"${EXPECTED_GUIDE:-$GUIDE}"*) first=present ;; *) first=missing ;; esac
      assert_eq "$first" present "$1: installed UI copy route"
      ;;
  esac
  if [ -n "${5:-}" ]; then
    case "${context#*$'\n'}" in *"$5"*) first=present ;; *) first=missing ;; esac
    assert_eq "$first" present "$1: diagnostic cause below key"
  fi
}

session_rows() {
  local XDG_STATE_HOME="$TMP_ROOT/state-${HOOK##*/}"
  export XDG_STATE_HOME
  check 'configured globs replace the fallback' claude "$(edit Edit "$REPO" Other.tsx ui-session)" ''
  check 'first match' claude "$(edit Edit "$REPO/shell" './Panel.qml' ui-session)" 'ui-copy-note: path=shell/Panel.qml'
  check 'same session' claude "$(edit MultiEdit "$REPO" "$REPO/shell/New Panel.qml" ui-session)" ''
  check 'Claude subagent' claude "$(edit MultiEdit "$REPO" "$REPO/shell/New Panel.qml" ui-session child)" 'ui-copy-note: path=shell/New Panel.qml'
}

session_rows
check 'Codex directory glob' codex "$(edit Write "$REPO" ui/nested/View.txt codex-dir)" 'ui-copy-note: path=ui/nested/View.txt'
install_skills "$FALLBACK/.agents/skills"
FIXTURE_INSTALL="$FALLBACK" EXPECTED_GUIDE="$FALLBACK/.agents/skills/code-quality/references/ui.md" \
  check 'project install with no Git or settings' claude "$(edit Write "$FALLBACK" ui/View.tsx fallback)" 'ui-copy-note: path=ui/View.tsx'
QA_UI_PATHS='*.qml' check 'otherwise matching path outside any project' claude \
  "$(edit Edit "$REPO/shell" '../../Other.qml' outside)" ''

patch_payload() { # SESSION PATCH-BODY
  jq -cn --arg s "$1" --arg p "$2" --arg c "$REPO" \
    '{tool_name:"apply_patch",cwd:$c,session_id:$s,tool_input:{command:("*** Begin Patch\n"+$p+"\n*** End Patch")}}'
}
move_rows() {
  local XDG_STATE_HOME="$TMP_ROOT/move-state-${HOOK##*/}"
  export XDG_STATE_HOME
  check 'Codex matching destination' codex "$(
    patch_payload codex-move $'*** Update File: outside/Old.qml\n*** Move to: shell/nested/New Panel.qml'
  )" 'ui-copy-note: path=shell/nested/New Panel.qml'
}
check 'Codex ordinary update' codex "$(
  patch_payload codex-update '*** Update File: shell/Panel.qml'
)" 'ui-copy-note: path=shell/Panel.qml'
add_rows() {
  local XDG_STATE_HOME="$TMP_ROOT/add-state-${HOOK##*/}"
  export XDG_STATE_HOME
  check 'Codex ordinary addition' codex "$(patch_payload codex-add '*** Add File: shell/Added.qml')" \
    'ui-copy-note: path=shell/Added.qml'
}
add_rows
move_rows
check 'Codex delete and nonmatching destination' codex "$(
  patch_payload codex-delete $'*** Delete File: shell/Removed.qml\n*** Update File: shell/Old.qml\n*** Move to: outside/Old.qml'
)" ''

check 'malformed payload' claude '{' 'ui-copy-note: reader=payload' 'parse error:'
mkdir -p "$FALLBACK/.kendex/settings.toml"
check 'unreadable setting' claude "$(edit Edit "$FALLBACK" ui/View.tsx bad-setting)" \
  'ui-copy-note: settings=unreadable' "kendex-env: not-file arg1=$FALLBACK/.kendex/settings.toml"
bad_candidate="*** Add File: $FALLBACK/ui/View.tsx"
valid_candidate='*** Add File: shell/Valid.qml'
combined_cause=$'ui-copy-note: settings=unreadable\n'"kendex-env: not-file arg1=$FALLBACK/.kendex/settings.toml"
check 'Codex unreadable candidate before matching candidate' codex \
  "$(patch_payload bad-first "$bad_candidate"$'\n'"$valid_candidate")" \
  'ui-copy-note: path=shell/Valid.qml' "$combined_cause"
check 'Codex unreadable candidate after matching candidate' codex \
  "$(patch_payload bad-last "$valid_candidate"$'\n'"$bad_candidate")" \
  'ui-copy-note: path=shell/Valid.qml' "$combined_cause"

NESTED="$REPO/nested"
SIBLING="$TMP_ROOT/sibling"
mkdir -p "$NESTED" "$SIBLING"
git -C "$SIBLING" init -q
printf '[env]\nQA_UI_PATHS = "views/"\n' >"$NESTED/kendex.settings.toml"
printf '[env]\nQA_UI_PATHS = "layouts/**/*.txt"\n' >"$SIBLING/kendex.settings.toml"
check 'nested project setting beats enclosing Git setting' claude \
  "$(edit Edit "$REPO" "$NESTED/views/Panel.txt" nested)" 'ui-copy-note: path=views/Panel.txt'
check 'sibling checkout uses its own setting' claude \
  "$(edit Edit "$REPO" "$SIBLING/layouts/Panel.txt" sibling)" 'ui-copy-note: path=layouts/Panel.txt'

printf 'old\n' >"$REPO/shell/Tracked.qml"
printf 'unchanged\n' >"$REPO/shell/Unchanged.qml"
git -C "$REPO" add shell/Tracked.qml shell/Unchanged.qml
git -C "$REPO" commit -q -m tracked
printf 'new\n' >"$REPO/shell/Tracked.qml"
touch -t 201001010000 "$REPO/shell/Unchanged.qml"
index_before=$(git -C "$REPO" hash-object .git/index)
BASH_EVENT=$(jq -cn --arg c "$NESTED" '{tool_name:"Bash",cwd:$c,session_id:"bash-edit",tool_input:{command:"true"}}')
check 'Claude Bash from nested project sees outer tracked edit' claude "$BASH_EVENT" 'ui-copy-note: path=shell/Tracked.qml'
assert_eq "$(git -C "$REPO" hash-object .git/index)" "$index_before" 'Claude Bash leaves the Git index unchanged'
cp -- "$REPO/.git/index" "$TMP_ROOT/refreshable-index"
GIT_INDEX_FILE="$TMP_ROOT/refreshable-index" git -C "$REPO" status --porcelain=v1 -z --untracked-files=no --no-renames >/dev/null
refreshed_index=$(git -C "$REPO" hash-object "$TMP_ROOT/refreshable-index")
if [ "$refreshed_index" != "$index_before" ]; then refreshed=yes; else refreshed=no; fi
assert_eq "$refreshed" yes 'ordinary Git status refreshes the planted stale index'
check 'Claude direct edit after Bash is already marked' claude "$(edit Edit "$REPO" shell/Panel.qml bash-edit)" ''
printf 'bad index\n' >"$TMP_ROOT/corrupt-index"
git_status=0
expected_cause=$(GIT_INDEX_FILE="$TMP_ROOT/corrupt-index" LC_ALL=C git --no-optional-locks -C "$REPO" \
  status --porcelain=v1 -z --untracked-files=no --no-renames 2>&1) || git_status=$?
if [ "$git_status" -ne 0 ] && [ -n "$expected_cause" ]; then failed=yes; else failed=no; fi
assert_eq "$failed" yes 'Git emits a cause for the corrupt fixture index'
GIT_INDEX_FILE="$TMP_ROOT/corrupt-index" check 'Claude Bash preserves Git cause' claude \
  "$(jq -c '.session_id = "broken-index"' <<<"$BASH_EVENT")" 'ui-copy-note: reader=git-status' "$expected_cause"
BASH_EVENT=$(jq -c '.session_id = "shell-other"' <<<"$BASH_EVENT")
check 'Codex Bash stays silent' codex "$BASH_EVENT" ''

# Missing git stops only the Claude Bash branch, so an edit later in that
# session still gets the note.
NO_GIT_BIN="$TMP_ROOT/no-git-bin"
mkdir -p "$NO_GIT_BIN"
for tool in jq cat cp mkdir find; do ln -s -- "$(command -v "$tool")" "$NO_GIT_BIN/$tool"; done
no_git_rows() {
  local XDG_STATE_HOME="$TMP_ROOT/no-git-state-${HOOK##*/}" PATH="$NO_GIT_BIN"
  export XDG_STATE_HOME PATH
  check 'Claude Bash without git' claude "$(edit Bash "$REPO" '' no-git)" 'ui-copy-note: missing-tool=git'
  check 'Claude edit after Bash without git, same session' claude \
    "$(edit Edit "$REPO" shell/Panel.qml no-git)" 'ui-copy-note: path=shell/Panel.qml'
}
no_git_rows

RELOCATED="$TMP_ROOT/relocated/kendex"
install_skills "$RELOCATED/skills"
CODEX_HOME="$RELOCATED" EXPECTED_GUIDE="$RELOCATED/skills/code-quality/references/ui.md" \
  check 'relocated Codex native copy ending in kendex' codex-global \
    "$(edit Edit "$REPO" shell/Panel.qml global-codex)" 'ui-copy-note: path=shell/Panel.qml'
RELOCATED="$SIBLING/codex-global"
mkdir -p "$SIBLING/.agents/skills/decider/scripts/lib"
printf 'printf "fixture reader crossed scope\\n" >&2\nreturn 17\n' >"$SIBLING/.agents/skills/decider/scripts/lib/kendex-env.sh"
install_skills "$HOME/.agents/skills"
CODEX_HOME="$RELOCATED" EXPECTED_GUIDE="$HOME/.agents/skills/code-quality/references/ui.md" \
  check 'relocated global Codex skips adjacent project reader' codex-global \
    "$(edit Edit "$REPO" shell/Panel.qml global-shared)" 'ui-copy-note: path=shell/Panel.qml'
mkdir -p "$TMP_ROOT/dotfiles/claude-home"
ln -s "$TMP_ROOT/dotfiles/claude-home" "$HOME/.claude"
[ -L "$HOME/.claude" ]
EXPECTED_GUIDE="$HOME/.agents/skills/code-quality/references/ui.md" \
  check 'global Claude dotfiles alias' claude-global \
    "$(edit Edit "$REPO" shell/Panel.qml global-claude)" 'ui-copy-note: path=shell/Panel.qml'

# The carrier's payload has no cwd and an absolute file_path (vocab.ts).
pi_edit() { # PATH SESSION
  jq -cn --arg p "$1" --arg s "$2" '{tool_name:"Edit",session_id:$s,tool_input:{file_path:$p}}'
}
# A Pi global root moved into a checkout is spelled like that checkout's
# project install, and its shared tree holds the planted reader.
pi_rows() {
  local XDG_STATE_HOME="$TMP_ROOT/pi-state-${HOOK##*/}"
  export XDG_STATE_HOME
  KENDEX_HOOK_SCOPE=global KENDEX_HOOK_ROOT="$SIBLING/.pi" \
    EXPECTED_GUIDE="$HOME/.agents/skills/code-quality/references/ui.md" \
    check 'relocated global Pi skips adjacent project reader' pi-global \
      "$(pi_edit "$REPO/shell/Panel.qml" pi-relocated)" 'ui-copy-note: path=shell/Panel.qml'
}
pi_rows
mkdir -p "$TMP_ROOT/dotfiles/pi-home/agent"
ln -s "$TMP_ROOT/dotfiles/pi-home" "$HOME/.pi"
[ -L "$HOME/.pi" ]
install_skills "$HOME/.pi/agent/skills"
KENDEX_HOOK_SCOPE=global KENDEX_HOOK_ROOT="$HOME/.pi/agent" \
  EXPECTED_GUIDE="$HOME/.pi/agent/skills/code-quality/references/ui.md" \
  check 'global Pi through a symlinked harness folder' pi-global \
    "$(pi_edit "$REPO/shell/Panel.qml" pi-global-alias)" 'ui-copy-note: path=shell/Panel.qml'
PI_PROJECT="$TMP_ROOT/pi-project"
mkdir -p "$TMP_ROOT/physical-pi" "$PI_PROJECT"
git -C "$PI_PROJECT" init -q
ln -s "$TMP_ROOT/physical-pi" "$PI_PROJECT/.pi"
[ -L "$PI_PROJECT/.pi" ]
install_skills "$PI_PROJECT/.agents/skills"
KENDEX_HOOK_SCOPE=project KENDEX_HOOK_ROOT="$PI_PROJECT" \
  EXPECTED_GUIDE="$PI_PROJECT/.agents/skills/code-quality/references/ui.md" \
  check 'project Pi through a symlinked harness folder' pi-project \
    "$(pi_edit "$PI_PROJECT/Panel.qml" pi-project)" 'ui-copy-note: path=Panel.qml'

# A relative CODEX_HOME renders the global registration as the relative
# `bash "<path>"` engine::targets::direct_command writes, opened from the
# hook's working directory.
RELATIVE_BASE="$TMP_ROOT/relative"
install_skills "$RELATIVE_BASE/rel-codex/skills"
codex_relative_rows() {
  local XDG_STATE_HOME="$TMP_ROOT/relative-state-${HOOK##*/}"
  export XDG_STATE_HOME
  CODEX_HOME=rel-codex FIXTURE_INSTALL="$RELATIVE_BASE" FIXTURE_COMMAND='bash "rel-codex/hooks/ui-copy-note.sh"' \
    EXPECTED_GUIDE="$RELATIVE_BASE/rel-codex/skills/code-quality/references/ui.md" \
    check 'relative Codex global registration' codex-relative \
      "$(edit Edit "$REPO" shell/Panel.qml codex-relative)" 'ui-copy-note: path=shell/Panel.qml'
  CODEX_HOME=rel-codex FIXTURE_INSTALL="$RELATIVE_BASE" FIXTURE_COMMAND='bash "rel-codex/hooks/ui-copy-note.sh"' \
    EXPECTED_GUIDE="$RELATIVE_BASE/rel-codex/skills/code-quality/references/ui.md" \
    check 'relative Codex registration with two matching targets in one patch' codex-relative \
      "$(patch_payload codex-two $'*** Add File: shell/First.qml\n*** Update File: ui/Second.tsx')" \
      'ui-copy-note: path=shell/First.qml'
}
codex_relative_rows

ALIASED="$TMP_ROOT/aliased"
install_skills "$ALIASED/.agents/skills"
for harness in claude codex; do
  mkdir -p "$TMP_ROOT/physical-$harness"
  ln -s "$TMP_ROOT/physical-$harness" "$ALIASED/.$harness"
  [ -L "$ALIASED/.$harness" ]
  case "$harness" in
    claude) registry=.claude/settings.json ;;
    codex) registry=.codex/hooks.json ;;
  esac
  command=$(jq -er '.hooks.PostToolUse[].hooks[] | .command | select(contains("/ui-copy-note.sh"))' "$CATALOG/$registry")
  FIXTURE_INSTALL="$ALIASED" FIXTURE_COMMAND="$command" CLAUDE_PROJECT_DIR="$ALIASED" \
    EXPECTED_GUIDE="$ALIASED/.agents/skills/code-quality/references/ui.md" \
    check "aliased project $harness registry" "$harness" \
      "$(edit Edit "$ALIASED" Panel.qml "aliased-$harness")" 'ui-copy-note: path=Panel.qml'
done
# A Pi copy run by a carrier that sets no KENDEX_HOOK_SCOPE is unbound for its
# whole session, on every tool call.
unbound_rows() {
  local XDG_STATE_HOME="$TMP_ROOT/unbound-state-${HOOK##*/}"
  export XDG_STATE_HOME
  check 'unbound hook path' unbound "$(edit Edit "$REPO" shell/Panel.qml unbound)" 'ui-copy-note: reader=install-layout'
  check 'unbound hook path, same session' unbound "$(edit Bash "$REPO" '' unbound)" ''
}
unbound_rows

ORCH="$CATALOG/skills/orch/scripts"
parity_index=0
while IFS='|' read -r setting changed; do
  parity_index=$((parity_index + 1))
  parity_repo="$TMP_ROOT/parity-$parity_index"
  mkdir -p "$parity_repo/${changed%/*}"
  git -C "$parity_repo" init -q
  git -C "$parity_repo" config user.email ui-copy@example.com
  git -C "$parity_repo" config user.name 'UI copy suite'
  git -C "$parity_repo" commit -q --allow-empty -m base
  parity_base=$(git -C "$parity_repo" rev-parse HEAD)
  printf 'view\n' >"$parity_repo/$changed"
  git -C "$parity_repo" add -- "$changed"
  git -C "$parity_repo" commit -q -m change
  printf '[env]\nQA_UI_PATHS = "%s"\n' "$setting" >"$parity_repo/kendex.settings.toml"
  parity_branch=$(git -C "$parity_repo" branch --show-current)
  parity_request=$(jq -cn --arg w "$parity_repo" --arg b "$parity_base" \
    '{op: "record-qa-decision", step: "scan", worktree: $w, base: $b, judgments: []}')
  parity_answer=$(
    cd -- "$parity_repo" &&
      "$ORCH/orch-runtime" --state-dir "$parity_repo/tmp" state init --item UI-1 --worktree "$parity_repo" --branch "$parity_branch" >/dev/null &&
      "$ORCH/orch-runtime" --state-dir "$parity_repo/tmp" op --item UI-1 --request-json "$parity_request" >/dev/null &&
      "$ORCH/orch-runtime" --state-dir "$parity_repo/tmp" state get --item UI-1 /qa_decision
  ) || exit 1
  expected=''
  if jq -e '.result.value.signals | index("needs-ui-review") != null' <<<"$parity_answer" >/dev/null; then
    expected="ui-copy-note: path=$changed"
  fi
  check "orch runtime QA matcher parity $setting / $changed" claude \
    "$(edit Edit "$parity_repo" "$changed" "parity-$parity_index")" "$expected"
done <<'GLOBS'
shell/**/*.qml|shell/Panel.qml
shell/**/*.qml|shell/views/Panel.qml
shell/**/*.qml|shell/views/Panel.txt
docs/* ui/src/*|ui/src/deep/Panel.tsx
ui/src/|ui/src/deep/Panel.tsx
ui/src|ui/srcx/Panel.tsx
GLOBS

# The second call must expose a copy that skipped creating a session mark.
skill_load_control once "$HOOK" "DETAIL=\"Read § UI copy in \$REFERENCE and apply it to this edit.\"" \
  'STATE_DIR=/dev/null/unwritable' HOOK session_rows 'same session: keyed context'
skill_load_control move "$HOOK" '    command -v awk >/dev/null 2>&1 || { notice missing-tool awk; exit 0; }' \
  '    TARGETS=${TARGETS//Move to:/Ignored:}' HOOK move_rows 'Codex matching destination: keyed context'
skill_load_control add "$HOOK" '    command -v awk >/dev/null 2>&1 || { notice missing-tool awk; exit 0; }' \
  '    TARGETS=${TARGETS//Add File:/Ignored:}' HOOK add_rows 'Codex ordinary addition: keyed context'
skill_load_control no-git "$HOOK" '    [ "$HARNESS" = claude ] || exit 0' \
  '    command -v git >/dev/null 2>&1 || session_notice missing-tool git' HOOK no_git_rows \
  'Claude edit after Bash without git, same session: keyed context'
# A Pi copy that reads its shared tree beside its own root, as one that
# classified its path would, takes the planted project reader.
skill_load_control pi-scope "$HOOK" '      NATIVE_ROOT=$HOOK_ROOT' '      SHARED_ROOT=${HOOK_ROOT%/*}' \
  HOOK pi_rows 'relocated global Pi skips adjacent project reader: keyed context'
skill_load_control relative-codex "$HOOK" 'CLAUDE_ROOT="$HOME_PATH/.claude"' \
  '[[ "$HOOK_PATH" == /* ]] || { notice reader install-layout; exit 0; }' HOOK codex_relative_rows \
  'relative Codex global registration: keyed context' \
  'relative Codex registration with two matching targets in one patch: keyed context'

printf 'pass: %s   fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
