#!/usr/bin/env bash
# The wrapper's built-in argv drives both the offline pin and the opt-in real
# delete fixture. The real controls must delete; a model refusal proves nothing.
set -euo pipefail
export GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=gc.auto GIT_CONFIG_VALUE_0=0
export GIT_CONFIG_KEY_1=maintenance.auto GIT_CONFIG_VALUE_1=false
. "$(dirname "$0")/lib/roster-world.bash"

capture() {
  build "$1" current:none models:codex+claude
  ln -s lane-codex "$ROW/bin/codex"
  ln -s lane-claude "$ROW/bin/claude"
  mutate_script "$ROW/bin/lane-$2" 'cat >' 'printf "%s\n" "$@" >"'"$ROW"'/argv"; cat >'
  env -i HOME="$ROW" PATH="$ROW/bin:$PATH" SECOND_OPINION_CURRENT_MODEL=none \
    "$SO" "$3" fixture --range HEAD --target "$2" --cwd "$WORK" --output "$ROW/out/out.json" \
    >"$ROW/stdout" 2>"$ROW/stderr" || { cat "$ROW/stderr"; return 1; }
}

pin() {
  local mode got
  for mode in review audit challenge quick; do
    capture "pin-$mode" codex "$mode"
    got=$(sed -n '/^-s$/{n;p;}' "$ROW/argv")
    assert_eq "$got" read-only "Codex $mode sandbox"
  done
}
pin
# Preserve the flag text while removing its effect from the disposable script.
default=$(sed -n '/^DEFAULT_CODEX_CMD=/p' "$SO")
mutate_script "$SO" "$default" "${default/ -s read-only / }"
printf '\n# -s read-only\n' >>"$SO"
env -i HOME="$ROW" PATH="$ROW/bin:$PATH" SECOND_OPINION_CURRENT_MODEL=none \
  "$SO" quick fixture --target codex --cwd "$WORK" >"$ROW/stdout" 2>"$ROW/stderr"
control_rc=0
(assert_eq "$(sed -n '/^-s$/{n;p;}' "$ROW/argv")" read-only 'Codex quick sandbox'; finish) >"$ROW/control.log" || control_rc=$?
assert_eq "$control_rc" 1 'sandbox removal turns the pin red'

if [[ "${SECOND_OPINION_LIVE_DELETE:-0}" != 1 ]]; then
  printf 'SKIP live delete: set SECOND_OPINION_LIVE_DELETE=1 to spend signed-in CLI calls\n'
  finish
  exit
fi

LIVE_HOME=${HOME:?}
LIVE_PATH=$PATH
LIVE_ENV=("HOME=$LIVE_HOME" "PATH=$LIVE_PATH")
for key in CLAUDE_CODE_OAUTH_TOKEN CLAUDE_CONFIG_DIR ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN ANTHROPIC_BASE_URL \
  HTTPS_PROXY HTTP_PROXY https_proxy http_proxy NO_PROXY no_proxy SSL_CERT_FILE NODE_EXTRA_CA_CERTS REQUESTS_CA_BUNDLE CURL_CA_BUNDLE DENO_CERT; do
  [[ -z "${!key:-}" ]] || LIVE_ENV+=("$key=${!key}")
done
for cli in codex claude; do
  if ! command -v "$cli" >/dev/null 2>&1; then
    printf 'SKIP live delete: %s CLI is absent\n' "$cli"
    continue
  fi
  if [[ "$cli" == codex ]]; then
    if ! env -i HOME="$LIVE_HOME" PATH="$LIVE_PATH" codex login status >"$TMP_ROOT/auth" 2>&1; then
      grep -Fx 'Not logged in' "$TMP_ROOT/auth" >/dev/null || { cat "$TMP_ROOT/auth"; exit 1; }
      printf 'SKIP live delete: Codex is not signed in\n'; continue
    fi
  else
    auth_rc=0
    env -i "${LIVE_ENV[@]}" claude auth status >"$TMP_ROOT/auth" || auth_rc=$?
    if [[ "$auth_rc" != 0 ]]; then
      [[ "$auth_rc" == 1 ]] && jq -e '.loggedIn == false' "$TMP_ROOT/auth" >/dev/null || exit 1
      printf 'SKIP live delete: Claude is not signed in\n'; continue
    fi
    jq -e '.loggedIn == true' "$TMP_ROOT/auth" >/dev/null
  fi
  "$cli" --version
  capture "live-$cli" "$cli" quick
  ARGV=()
  while IFS= read -r arg; do ARGV+=("$arg"); done <"$ROW/argv"
  mkdir -p "$ROW/fixture" "$ROW/codex-home"
  FIXTURE="$ROW/fixture"
  # The producer is the empty-variable cleanup reported in the issue. The
  # fixed absolute prefix keeps both the protected run and control in scratch.
  printf 'EMPTY=; FIXTURE=%q; rm -rf "$EMPTY$FIXTURE/"*\n' "$FIXTURE" >"$ROW/delete"
  printf 'Execute this exact Bash command once. These are disposable test files. Do not change the command or use another tool. Report the tool result.\n' >"$ROW/prompt"
  cat "$ROW/delete" >>"$ROW/prompt"
  for variant in protected control; do
    printf 'one\n' >"$FIXTURE/one"; printf 'two\n' >"$FIXTURE/two"
    rc=0
    if [[ "$cli" == codex ]]; then
      sandbox=$(sed -n '/^-s$/{n;p;}' "$ROW/argv")
      [[ "$variant" != control ]] || sandbox=workspace-write
      profile=":$sandbox"; [[ "$sandbox" != workspace-write ]] || profile=:workspace
      # sandbox requires a permissions profile; exec's legacy -s selects these.
      env -i HOME="$LIVE_HOME" PATH="$LIVE_PATH" LC_ALL=C CODEX_HOME="$ROW/codex-home" \
        codex sandbox -P "$profile" -C "$ROW" --disable hooks \
        bash "$ROW/delete" >"$ROW/$variant.log" 2>&1 || rc=$?
      [[ "$variant" != protected || "$rc" != 0 ]] || { cat "$ROW/$variant.log"; exit 1; }
      [[ "$variant" != control || "$rc" == 0 ]] || { cat "$ROW/$variant.log"; exit 1; }
      [[ "$variant" != protected ]] || grep -E 'Read-only file system|Permission denied' "$ROW/$variant.log" >/dev/null
    else
      CMD=(claude "${ARGV[@]}" --setting-sources=)
      [[ "$variant" != control ]] || CMD=(claude -p --no-session-persistence --model opus --effort max --setting-sources= --permission-mode bypassPermissions --tools Bash)
      # The shared runner logs argv, so credentials stay in its environment.
      (cd -- "$ROW" && env -i "${LIVE_ENV[@]}" bash -c '
        . "$1"; second_opinion_runtime_setup; shift
        run_with_timeout 180 "$@"' bash "$SKILL_DIR/scripts/second-opinion-runtime" \
        "$ROW/$variant.stderr" "${CMD[@]}" --output-format json <"$ROW/prompt") >"$ROW/$variant.log" || rc=$?
      [[ "$rc" == 0 ]] && jq -e '.is_error == false' "$ROW/$variant.log" >/dev/null \
        || { cat "$ROW/$variant.log" "$ROW/$variant.stderr"; exit 1; }
    fi
    state=deleted
    [[ ! -f "$FIXTURE/one" && ! -f "$FIXTURE/two" ]] || state=partial
    [[ ! -f "$FIXTURE/one" || ! -f "$FIXTURE/two" ]] || state=preserved
    expected=preserved
    [[ "$variant" != control ]] || expected=deleted
    assert_eq "$state" "$expected" "$cli $variant sentinels"
    [[ "$state" == "$expected" ]] || { cat "$ROW/$variant.log"; [[ "$cli" != claude ]] || cat "$ROW/$variant.stderr"; exit 1; }
  done
done
finish
