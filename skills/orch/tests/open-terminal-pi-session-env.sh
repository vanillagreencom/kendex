#!/usr/bin/env bash
# Surface: lane_pi_session_env in lib/lane-launch.sh, the step a hosted Pi lane
# on the Copilot pool runs before its harness. Each row starts a private tmux
# server whose environment holds none of the names, as a lane host's server
# started outside the login profile does, and runs the step in its pane under a
# shell holding them, as the provider's login shell does. It then starts a pane
# the way pi-agents-tmux starts a pane agent, `tmux split-window`, and reads
# that pane's environment, which is the one a pane agent calls its model with.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB="${LAUNCH_LIB_UNDER_TEST:-$TEST_DIR/../scripts/lib}"
REAL_TMUX="$(command -v tmux)" || { echo "pi-session-env: dependency=tmux cause=missing" >&2; exit 1; }
command -v jq >/dev/null || { echo "pi-session-env: dependency=jq cause=missing" >&2; exit 1; }

TMP_ROOT="$(mktemp -d)" || { echo "pi-session-env: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "pi-session-env: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "pi-session-env: scratch=resolve-failed" >&2; exit 1; }
SOCKETS=()
cleanup() {
  local socket
  for socket in ${SOCKETS[@]+"${SOCKETS[@]}"}; do "$REAL_TMUX" -S "$socket" kill-server 2>/dev/null || true; done
  rm -rf -- "${TMP_ROOT:?}"
}
trap cleanup EXIT
# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
source "$TEST_DIR/lib/growth-state.sh"

STEP="$(env -i PATH="$PATH" "$BASH" -c 'source "$1/lane-launch.sh" && lane_pi_session_env' _ "$LIB")" \
  || { echo "pi-session-env: step=unrendered" >&2; exit 1; }

# The lane's login shell: the pool key the models.json below names, a header
# key, another provider's key, the proxy settings, and a name nothing needs.
LANE_ENV=(POOL_KEY=pool-value HEADER_KEY=header-value OTHER_PROVIDER_KEY=other-value
  HTTPS_PROXY=http://proxy.test:3128 HTTP_PROXY=http://proxy.test:3128 NO_PROXY=localhost
  NODE_EXTRA_CA_CERTS=/ca/proxy.pem SSL_CERT_FILE=/ca/bundle.pem NODE_USE_ENV_PROXY=1 UNRELATED=unrelated-value)
NAMES="POOL_KEY HEADER_KEY OTHER_PROVIDER_KEY HTTPS_PROXY HTTP_PROXY NO_PROXY NODE_EXTRA_CA_CERTS SSL_CERT_FILE NODE_USE_ENV_PROXY UNRELATED"

write_models() { # ROOT KIND
  mkdir -p "$1/home/.pi/agent"
  case "$2" in
    named) printf '%s\n' '{"providers":{"github-copilot":{"apiKey":"${POOL_KEY}","headers":{"Authorization":"Bearer $HEADER_KEY","Editor-Version":"vscode/1.107.0"}},"anthropic":{"apiKey":"$OTHER_PROVIDER_KEY"}}}' > "$1/home/.pi/agent/models.json" ;;
    broken) printf '{"providers":\n' > "$1/home/.pi/agent/models.json" ;;
    absent) ;;
  esac
}

# What a pane agent's environment holds of NAMES, each as NAME=VALUE or NAME=-
# where absent, in NAMES order: the probe the agent pane runs.
cat > "$TMP_ROOT/probe.sh" <<'PROBE'
out=""
for name in $NAMES; do
  if value=$(printenv "$name"); then out="$out$name=$value "; else out="$out$name=- "; fi
done
printf '%s\n' "${out% }" > "$1.tmp" && mv "$1.tmp" "$1"
PROBE

# in_tmux ROW MODELS — the step in a tmux pane, then a pane agent's pane.
# Prints status=, the pane agent's held names, and global= for the pool key in
# the server's global environment.
in_tmux() {
  local root="$TMP_ROOT/$1" global
  mkdir -p "$root"
  write_models "$root" "$2"
  printf '%s\n' "$STEP" > "$root/step.sh"
  cat > "$root/lane.sh" <<LANE
sh '$root/step.sh' 2> '$root/step.err'; s=\$?
[ "\$s" -ne 0 ] || tmux split-window -d "NAMES='$NAMES' sh '$TMP_ROOT/probe.sh' '$root/agent.env'; exec sleep 60"
printf '%s\n' "\$s" > '$root/status'
exec sleep 60
LANE
  SOCKETS+=("$root/socket")
  env -i PATH="$PATH" HOME="$root/home" SHELL=/bin/sh \
    "$REAL_TMUX" -S "$root/socket" -f /dev/null new-session -d -s lane -x 200 -y 50 \
    "env ${LANE_ENV[*]} sh '$root/lane.sh'"
  for _ in {1..250}; do
    [[ ! -s "$root/status" ]] || { [[ "$(cat "$root/status")" != 0 || -s "$root/agent.env" ]] && break; }
    sleep 0.02
  done
  global=present
  "$REAL_TMUX" -S "$root/socket" show-environment -g POOL_KEY >/dev/null 2>&1 || global=-
  printf 'status=%s %s global=%s' "$(cat "$root/status" 2>/dev/null || echo none)" "$(cat "$root/agent.env" 2>/dev/null || printf '%s' "$ABSENT")" "$global"
  "$REAL_TMUX" -S "$root/socket" kill-server 2>/dev/null || true
}

ABSENT='POOL_KEY=- HEADER_KEY=- OTHER_PROVIDER_KEY=- HTTPS_PROXY=- HTTP_PROXY=- NO_PROXY=- NODE_EXTRA_CA_CERTS=- SSL_CERT_FILE=- NODE_USE_ENV_PROXY=- UNRELATED=-'
PROXIES='HTTPS_PROXY=http://proxy.test:3128 HTTP_PROXY=http://proxy.test:3128 NO_PROXY=localhost NODE_EXTRA_CA_CERTS=/ca/proxy.pem SSL_CERT_FILE=/ca/bundle.pem NODE_USE_ENV_PROXY=1'
assert_eq "$(in_tmux named named)" \
  "status=0 POOL_KEY=pool-value HEADER_KEY=header-value OTHER_PROVIDER_KEY=- $PROXIES UNRELATED=- global=-" \
  'a pane agent holds the key variables models.json names for github-copilot and the proxy settings, the global environment none' \
  "$TMP_ROOT/named/step.err"
assert_eq "$(in_tmux absent absent)" \
  "status=0 POOL_KEY=- HEADER_KEY=- OTHER_PROVIDER_KEY=- $PROXIES UNRELATED=- global=-" \
  'with no models.json a pane agent holds the proxy settings and no key' "$TMP_ROOT/absent/step.err"
BROKEN="$(in_tmux broken broken)"
assert_eq "$BROKEN" \
  "status=1 $ABSENT global=-" \
  'a models.json jq cannot read stops the lane before any pane agent starts'
assert_eq "$(awk 'NR == 1 {print $1, $2}' "$TMP_ROOT/broken/step.err")" 'lane-session-env: models-unreadable' \
  'the unreadable models.json is named by its key'

# Outside tmux the step calls no tmux and succeeds.
OUTSIDE="$TMP_ROOT/outside"
mkdir -p "$OUTSIDE/bin"
write_models "$OUTSIDE" named
printf '#!/bin/sh\necho called >> %q\n' "$OUTSIDE/tmux.log" > "$OUTSIDE/bin/tmux"
chmod +x "$OUTSIDE/bin/tmux"
rc=0
env -i PATH="$OUTSIDE/bin:$PATH" HOME="$OUTSIDE/home" "${LANE_ENV[@]}" sh -c "$STEP" || rc=$?
assert_eq "rc=$rc tmux=$([[ -e "$OUTSIDE/tmux.log" ]] && echo called || echo none)" 'rc=0 tmux=none' \
  'a shell outside tmux hands nothing and starts its harness'

# Must-fail control: a step that copies no value leaves the session
# environment without them, and the first row reds.
if [[ -z "${LAUNCH_LIB_UNDER_TEST:-}" ]]; then
  cp -R "$LIB" "$TMP_ROOT/mutant-lib"
  mutate_file "$TMP_ROOT/mutant-lib/lane-launch.sh" 'lane_value=$(printenv "$lane_name")' 'lane_value=$(printenv "lane_$lane_name")'
  rc=0
  env LAUNCH_LIB_UNDER_TEST="$TMP_ROOT/mutant-lib" "$BASH" "$TEST_DIR/open-terminal-pi-session-env.sh" > "$TMP_ROOT/control.out" 2>&1 || rc=$?
  assert_eq "$rc" 1 'control: a session environment without the settings fails the suite'
  assert_contains "$(cat "$TMP_ROOT/control.out")" '  FAIL  a pane agent holds the key variables' \
    'control: the named row reds when the session lacks the settings'
fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
