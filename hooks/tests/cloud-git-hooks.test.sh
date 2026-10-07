#!/usr/bin/env bash
# Surface: cloud-git-hooks.sh, with the real commit-guards installer and check.
# Inputs: hooks/cloud-git-hooks.sh, skills/commit-guards/**, tests/lib/assert.sh,
# tests/lib/first-line.sh. Claude Code produces the remote flag and project dir.
# shellcheck source-path=SCRIPTDIR
set -euo pipefail
unset GIT_DIR GIT_WORK_TREE GIT_COMMON_DIR GIT_INDEX_FILE GIT_OBJECT_DIRECTORY GIT_ALTERNATE_OBJECT_DIRECTORIES

TEST_DIR="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$TEST_DIR/../.." && pwd -P)"
HOOK="${HOOK_UNDER_TEST:-$REPO_ROOT/hooks/cloud-git-hooks.sh}"
# shellcheck source=lib/assert.sh
. "$TEST_DIR/lib/assert.sh"
# shellcheck source=lib/first-line.sh
. "$TEST_DIR/lib/first-line.sh"
PASS=0
FAIL=0
TMP_ROOT="$(mktemp -d)" || { echo 'cloud-git-hooks-test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'cloud-git-hooks-test: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'cloud-git-hooks-test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/no-jq-bin" "$TMP_ROOT/home"
BASH_BIN="$(command -v bash)"
ln -s "$(command -v git)" "$TMP_ROOT/no-jq-bin/git"
cat >"$TMP_ROOT/bin/bash" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >>"$INSTALL_LOG"
status=0
output=$("$REAL_BASH" "$@" 2>&1) || status=$?
printf '%s\n' "$output" >>"$INSTALL_REPORT"
printf '%s\n' "$output"
exit "$status"
SH
chmod +x "$TMP_ROOT/bin/bash"

fixture_commit() { # REPO
  git -C "$1" add .claude/settings.json
  git -C "$1" -c user.name=Fixture -c user.email=fixture@example.invalid \
    -c core.hooksPath=/dev/null commit -qm 'test: commit project settings'
}

project_registration() { # FILE
  cat >"$1" <<'JSON'
{"hooks":{"SessionStart":[{"matcher":"startup|resume","hooks":[{"type":"command","command":"[ -z \"${COPILOT_PROJECT_DIR-}\" ] || exit 0; bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/cloud-git-hooks.sh\""}]}]}}
JSON
}

remote_rows() {
  local remote layout consent scope selection key repo before after rc check_rc repeat_rc expected row hook run_hook foreign before_foreign after_foreign label world run_path
  world=$(mktemp -d "$TMP_ROOT/rows.XXXXXX") || exit 2
  # One table covers the harness flag, committed consent, install scope and
  # installer result. A missing skill can follow an incomplete checkout.
  while IFS='|' read -r remote layout consent scope selection key; do
    label="$remote $layout $consent $scope $selection"
    repo="$world/$remote-$layout-$consent-$scope-$selection"
    mkdir -p "$repo/.agents/skills" "$repo/.claude/hooks"
    env -i PATH="$PATH" HOME="$TMP_ROOT/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      git -C "$repo" init -q
    git -C "$repo" config gc.auto 0
    git -C "$repo" config maintenance.auto false
    printf '{}\n' >"$repo/.claude/settings.json"
    case "$consent" in
      committed) project_registration "$repo/.claude/settings.json" ;;
      malformed) printf '{\n' >"$repo/.claude/settings.json" ;;
    esac
    fixture_commit "$repo"
    case "$consent" in
      no-settings)
        rm -- "$repo/.claude/settings.json"
        fixture_commit "$repo"
        ;;
      unstaged) project_registration "$repo/.claude/settings.json" ;;
      disabled)
        project_registration "$repo/.claude/settings.json"
        fixture_commit "$repo"
        printf '{}\n' >"$repo/.claude/settings.json"
        fixture_commit "$repo"
        project_registration "$repo/.claude/settings.json"
        ;;
    esac
    run_hook="$repo/.claude/hooks/cloud-git-hooks.sh"
    if [ "$scope" = global ]; then
      mkdir -p "$TMP_ROOT/home/.claude/hooks"
      run_hook="$TMP_ROOT/home/.claude/hooks/cloud-git-hooks.sh"
    fi
    cp "$HOOK" "$run_hook"
    if [ "$layout" != missing ]; then
      cp -R "$REPO_ROOT/skills/commit-guards" "$repo/.agents/skills/commit-guards"
    fi
    [ "$layout" != hooks-path ] || git -C "$repo" config core.hooksPath ''
    INSTALL_LOG="$TMP_ROOT/installer.log"
    INSTALL_REPORT="$TMP_ROOT/installer-report.log"
    : >"$INSTALL_LOG"
    : >"$INSTALL_REPORT"
    before=$(tar -cf - -C "$repo/.git" hooks | cksum)
    rc=0
    run_path="$TMP_ROOT/bin:$PATH"
    [ "$layout" != no-jq ] || run_path="$TMP_ROOT/no-jq-bin"
    row=(env -i PATH="$run_path" HOME="$TMP_ROOT/home" \
      GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
      INSTALL_LOG="$INSTALL_LOG" INSTALL_REPORT="$INSTALL_REPORT" \
      REAL_BASH="$BASH_BIN" CLAUDE_PROJECT_DIR="$repo")
    [ "$remote" = unset ] || row+=(CLAUDE_CODE_REMOTE="$remote")
    if [ "$selection" = foreign ]; then
      foreign="$world/foreign-$remote-$layout-$consent-$scope"
      mkdir -p "$foreign/.claude"
      env -i PATH="$PATH" HOME="$TMP_ROOT/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        git -C "$foreign" init -q
      project_registration "$foreign/.claude/settings.json"
      fixture_commit "$foreign"
      row+=(GIT_DIR="$foreign/.git")
      before_foreign=$(tar -cf - -C "$foreign/.git" hooks | cksum)
    fi
    "${row[@]}" "$BASH_BIN" "$run_hook" </dev/null >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr" || rc=$?
    assert_eq "$rc" 0 "$label permits session start"
    assert_eq "$(cat "$TMP_ROOT/stderr")" '' "$label keeps failures in session context"
    case "$key" in
      silent) expected=- ;;
      missing-tools) expected='cloud-git-hooks: missing-tools=jq' ;;
      *) expected="cloud-git-hooks: $key=$repo" ;;
    esac
    assert_eq "$(first_line "$TMP_ROOT/stdout")" "$expected" "$label reports its result first"
    after=$(tar -cf - -C "$repo/.git" hooks | cksum)
    if [ "$key" = silent ]; then
      assert_eq "$(cat "$INSTALL_LOG")" '' "$label runs no installer"
      assert_eq "$after" "$before" "$label leaves git hooks untouched"
    elif [ "$key" = missing-tools ]; then
      assert_eq "$(cause_below "$TMP_ROOT/stdout")" present "$layout explains the arming gap below its key"
      assert_eq "$(cat "$INSTALL_LOG")" '' "$label runs no installer"
      assert_eq "$after" "$before" "$label leaves git hooks untouched"
    elif [ "$key" = armed ]; then
      check_rc=0
      env -i PATH="$PATH" HOME="$TMP_ROOT/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        "$BASH_BIN" "$repo/.agents/skills/commit-guards/scripts/install-git-hooks" --repo "$repo" --check \
        >"$TMP_ROOT/check" 2>&1 || check_rc=$?
      assert_eq "$check_rc" 0 'true leaves the real installer check armed'
      for hook in pre-commit commit-msg pre-push; do
        assert_eq "$(test -x "$repo/.git/hooks/$hook" && echo executable || echo absent)" executable "true arms $hook"
      done
      # A resume executes the same hook. The installer must still pass.
      repeat_rc=0
      "${row[@]}" "$BASH_BIN" "$run_hook" </dev/null >"$TMP_ROOT/stdout" 2>"$TMP_ROOT/stderr" || repeat_rc=$?
      assert_eq "$repeat_rc $(first_line "$TMP_ROOT/stdout")" "0 cloud-git-hooks: armed=$repo" 'resume stays armed'
      # Git's message hook calls the real gate, rather than a fixture gate.
      printf 'invalid message\n' >"$TMP_ROOT/message"
      check_rc=0
      (cd -- "$repo" && env -i PATH="$PATH" HOME="$TMP_ROOT/home" GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null \
        "$BASH_BIN" .git/hooks/commit-msg "$TMP_ROOT/message") >"$TMP_ROOT/message-result" 2>&1 || check_rc=$?
      assert_eq "$check_rc" 1 'armed commit-msg rejects a bad message'
    else
      assert_eq "$(test -s "$INSTALL_REPORT" && echo present || echo absent)" present "$layout captures a real installer report"
      # Compare with the real child's output. The hook's own explanation
      # cannot stand in for the installer's cause or remedy.
      assert_eq "$(sed '1,2d' "$TMP_ROOT/stdout")" "$(cat "$INSTALL_REPORT")" "$layout replays the captured installer report below its explanation"
      assert_eq "$after" "$before" "$layout leaves git hooks untouched"
    fi
    if [ "$selection" = foreign ]; then
      after_foreign=$(tar -cf - -C "$foreign/.git" hooks | cksum)
      assert_eq "$after_foreign" "$before_foreign" "$label leaves inherited git hooks untouched"
    fi
  done <<'ROWS'
unset|normal|committed|project|none|silent
false|normal|committed|project|none|silent
true|normal|committed|project|none|armed
true|missing|committed|project|none|gap
true|hooks-path|committed|project|none|gap
true|no-jq|committed|project|none|missing-tools
true|no-jq|no-settings|project|none|silent
false|no-jq|committed|project|none|silent
true|normal|absent|project|none|silent
true|normal|no-settings|project|none|silent
true|normal|unstaged|project|none|silent
true|normal|disabled|project|none|silent
true|normal|malformed|project|none|silent
true|normal|absent|global|none|silent
true|normal|absent|global|foreign|silent
true|normal|committed|global|none|armed
ROWS
}

remote_rows
if [ -z "${HOOK_UNDER_TEST:-}" ]; then
  # Preserve the matched test but make its local-skip branch unreachable.
  # The real installer then arms a local clone, and the same rows must fail.
  skill_load_control remote-guard "$HOOK" \
    'if [ "${CLAUDE_CODE_REMOTE:-}" != "true" ]; then' \
    ':; elif false; then' HOOK remote_rows \
    'unset normal committed project none runs no installer' \
    'unset normal committed project none leaves git hooks untouched'
  skill_load_control committed-consent "$HOOK" \
    "' <<<\"\$COMMITTED_SETTINGS\" >/dev/null 2>&1; then" \
    ':; elif false; then' HOOK remote_rows \
    'true normal absent global none runs no installer' \
    'true normal absent global none leaves git hooks untouched'
  skill_load_control inherited-repository "$HOOK" \
    '# An absent or unreadable registration grants no licence to run an installer.' \
    'unset() { :; }' HOOK remote_rows \
    'true normal absent global foreign runs no installer'
  skill_load_control armed-check "$HOOK" \
    '    bash "$PROJECT_DIR/.agents/skills/commit-guards/scripts/install-git-hooks" --check) 2>&1' \
    ':' HOOK remote_rows 'true hooks-path committed project none reports its result first'
  skill_load_control missing-jq "$HOOK" \
    'if ! command -v jq >/dev/null 2>&1; then' \
    'exit 0' HOOK remote_rows \
    'true no-jq committed project none reports its result first' \
    'no-jq explains the arming gap below its key'
  skill_load_control installer-report "$HOOK" \
    '  printf '\''cloud-git-hooks: gap=%s\n'\'' "$PROJECT_DIR"' \
    'OUTPUT=""' HOOK remote_rows \
    'missing replays the captured installer report below its explanation' \
    'hooks-path replays the captured installer report below its explanation'
fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
