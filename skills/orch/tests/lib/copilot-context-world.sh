# shellcheck shell=bash
# An installed reader, a fake SDK event source, and the real hook and mark
# judge. Callers provide the session's environment and keep their assertions.
# No extension is copied here: the launcher must have installed it.
copilot_context_flow() { # ROOT HOME COPILOT_HOME SCRIPTS [ENV=VALUE...]
  local root="$1" user_home="$2" cop_home="$3" scripts="$4" sdk payload reading name
  shift 4
  mkdir -p "$root/.agents/skills/orch" "$root/.github/hooks" "$root/tmp" "$user_home"
  rm -f -- "${root:?}/tmp/lane-mail/overseer/context.json" "${root:?}/tmp/lane-mail/CC-1/context.json"
  if [[ ! -e "$root/.git" ]]; then
    git -C "$root" init -q
    git -C "$root" config gc.auto 0
    git -C "$root" config maintenance.auto false
  fi
  ln -sfn "$scripts" "$root/.agents/skills/orch/scripts"
  for name in lane-mail-check lane-mail-start lane-mail-compact; do
    local source="$TEST_DIR/../../../hooks/$name.sh"
    [[ "$name" != lane-mail-check || -z "${FLOW_JUDGE:-}" ]] || source="$FLOW_JUDGE"
    cp "$source" "$root/.github/hooks/$name.sh"
    printf '{}\n' > "$root/.github/hooks/$name.json"
  done
  sdk="$cop_home/node_modules/@github/copilot-sdk"
  mkdir -p "$sdk" "$cop_home/session-state/s1"
  printf '{"name":"@github/copilot-sdk","type":"module","exports":{"./extension":"./extension.mjs"}}\n' > "$sdk/package.json"
  cat > "$sdk/extension.mjs" <<'SDK'
import { appendFileSync } from "node:fs";
export async function joinSession() {
  return {
    sessionId: "s1",
    on(type, handler) {
      if (type === "session.usage_info") setTimeout(() => handler({
        type, data: { currentTokens: 199000, tokenLimit: 272000 },
      }), 0);
      return () => {};
    },
    async log(message) { appendFileSync(process.env.FLOW_LOG, message + "\n"); },
  };
}
SDK
  printf '{"type":"session.start","data":{"sessionId":"s1"}}\n' > "$cop_home/session-state/s1/events.jsonl"
  payload="$(jq -nc --arg cwd "$root" '{sessionId:"s1",cwd:$cwd}')" || return 1
  FLOW_START="$(cd -- "$root" && env -i PATH="$PATH" HOME="$user_home" COPILOT_HOME="$cop_home" \
    ORCH_STATE_DIR="$root/tmp" "$@" bash "$root/.github/hooks/lane-mail-start.sh" <<<"$payload")" || return 1
  : > "$root/tmp/flow.log"
  if [[ -r "$cop_home/extensions/kendex-lane-context/extension.mjs" ]] && \
      jq -e '.enabledFeatureFlags.EXTENSIONS == true' "$cop_home/settings.json" >/dev/null 2>&1; then
    (cd -- "$root" && env -i PATH="$PATH" HOME="$user_home" COPILOT_HOME="$cop_home" \
      ORCH_STATE_DIR="$root/tmp" FLOW_LOG="$root/tmp/flow.log" "$@" \
      node "$cop_home/extensions/kendex-lane-context/extension.mjs") || return 1
  fi
  payload="$(jq -nc --arg cwd "$root" --arg transcript "$cop_home/session-state/s1/events.jsonl" \
    '{sessionId:"s1",cwd:$cwd,transcript_path:$transcript}')" || return 1
  FLOW_STOP="$(cd -- "$root" && env -i PATH="$PATH" HOME="$user_home" COPILOT_HOME="$cop_home" \
    ORCH_STATE_DIR="$root/tmp" ORCH_LANE_DIRS="" ORCH_OVERSEER_SUCCESSION=on "$@" \
    bash "$root/.github/hooks/lane-mail-check.sh" <<<"$payload")" || return 1
  FLOW_RECORD=none FLOW_VERDICT=""
  if [[ -f "$root/tmp/lane-mail/CC-1/context.json" ]]; then
    FLOW_RECORD="$(jq -r '"\(.tokens):\(.window)"' "$root/tmp/lane-mail/CC-1/context.json")" || return 1
    FLOW_VERDICT=lane
    return 0
  fi
  if [[ -f "$root/tmp/lane-mail/overseer/context.json" ]]; then
    reading="$(jq -r 'if .tokens != null and .window != null then "\(.tokens):\(.window)" else "" end' \
      "$root/tmp/lane-mail/overseer/context.json")" || return 1
    if [[ -n "$reading" ]]; then FLOW_RECORD="$reading"; fi
  else
    reading=""
  fi
  # The value comes only from the real hook's record. An absent reader supplies
  # no context argument, so main/control cannot be given a fabricated reading.
  local context=()
  [[ -z "$reading" ]] || context=(--context "$reading")
  FLOW_VERDICT="$(cd -- "$root" && env -i PATH="$PATH" HOME="$user_home" COPILOT_HOME="$cop_home" \
    ORCH_STATE_DIR="$root/tmp" ORCH_LANE_DIRS="" ORCH_OVERSEER_SUCCESSION=on "$@" \
    "$scripts/oversee-succeed" --check-marks --harness copilot ${context[@]+"${context[@]}"})" || return 1
}
