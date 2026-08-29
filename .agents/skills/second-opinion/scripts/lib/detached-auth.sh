#!/usr/bin/env bash

second_opinion_authenticate_detached() {
  DETACHED_AUTH_MODEL="" DETACHED_AUTH_SOURCE="" DETACHED_RUNTIME_DIR="" DETACHED_RUN_TOKEN=""
  "$1" || return 0
  DETACHED_RUNTIME_DIR="${SECOND_OPINION_RUNTIME_DIR:-}"
  DETACHED_RUN_TOKEN="${SECOND_OPINION_RUN_TOKEN:-}"
  local identity_file="$DETACHED_RUNTIME_DIR/identity" identity_token
  local auth_in_caller_env auth_session_scoped
  [[ -d "$DETACHED_RUNTIME_DIR" && ! -L "$DETACHED_RUNTIME_DIR" \
      && -f "$DETACHED_RUNTIME_DIR/token" && ! -L "$DETACHED_RUNTIME_DIR/token" \
      && -f "$identity_file" && ! -L "$identity_file" ]] \
    || { echo "Error: internal detached worker mode requires runtime ownership proof" >&2; return 1; }
  exec 9<"$identity_file"
  IFS= read -r identity_token <&9 && IFS= read -r DETACHED_AUTH_MODEL <&9 \
    && IFS= read -r DETACHED_AUTH_SOURCE <&9 && IFS= read -r auth_in_caller_env <&9 \
    && IFS= read -r auth_session_scoped <&9 \
    || { echo "Error: detached identity state is incomplete" >&2; return 1; }
  exec 9<&-
  [[ "$identity_token" == "$DETACHED_RUN_TOKEN" \
      && "$(cat < "$DETACHED_RUNTIME_DIR/token")" == "$DETACHED_RUN_TOKEN" \
      && "$DETACHED_AUTH_SOURCE" =~ ^(detected|session|project)$ \
      && "$auth_in_caller_env" =~ ^(true|false)$ \
      && "$auth_session_scoped" =~ ^(true|false)$ && -n "$DETACHED_AUTH_MODEL" ]] \
    || { echo "Error: detached identity ownership proof does not match" >&2; return 1; }
  CURRENT_MODEL_IN_CALLER_ENV="$auth_in_caller_env"
  CURRENT_MODEL_IS_SESSION_SCOPED="$auth_session_scoped"
  unset SECOND_OPINION_RUNTIME_DIR SECOND_OPINION_RUN_TOKEN
}
