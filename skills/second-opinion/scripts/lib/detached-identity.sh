#!/usr/bin/env bash

# --detached-worker is the runtime's word to the process it detached, and to
# the lane children that process forks. It carries the parent's resolved model
# identity, so it is proven rather than believed: the caller must hold the
# runtime directory and its token, and the identity file inside must name that
# same token. A caller who simply passes the flag has none of that and is
# refused — otherwise the flag would be a way to declare any identity at all,
# and the cross-model guard is the thing that identity decides.
second_opinion_authenticate_detached() {
  DETACHED_AUTH_MODEL="" DETACHED_AUTH_SOURCE="" DETACHED_RUNTIME_DIR="" DETACHED_RUN_TOKEN=""
  if ! "$1"; then
    unset SECOND_OPINION_RUNTIME_DIR SECOND_OPINION_RUN_TOKEN
    return 0
  fi
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

# Everything the preloader resolved is settled before any project file is
# read: the loader sources .env.local and exports a settings [env] table into
# this shell, and SCRIPT_DIR is what the script sources its own runtime from.
second_opinion_freeze_preloader_state() {
  readonly SCRIPT_DIR FOREGROUND_CAP_IN_CALLER_ENV FOREGROUND_CAP_WAS_IN_CALLER_ENV \
    CURRENT_MODEL_IS_SESSION_SCOPED CURRENT_MODEL_IN_CALLER_ENV DETACHED_AUTH_REQUESTED \
    DETACHED_AUTH_MODEL DETACHED_AUTH_SOURCE DETACHED_RUNTIME_DIR DETACHED_RUN_TOKEN
  readonly -a ORIGINAL_ARGS
}
