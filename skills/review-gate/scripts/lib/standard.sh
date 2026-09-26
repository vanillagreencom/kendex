# shellcheck shell=bash
# The organization standard's values, read from the skill's standard.json.
# validate-standard.sh reads GitHub against them and provision-environment.sh
# writes the environment half of them; both load the manifest here, so its
# shape is judged in one place. Requires diagnostics.sh loaded first.

# Sets WANT_CONTEXTS (the required contexts, sorted, `;`-joined), WANT_APP,
# WANT_ENV and WANT_SECRETS (the environment's secret names, sorted, one per
# line). With no jq on PATH, or a missing, unreadable or malformed
# manifest, it prints the refusal to stderr and returns 1; the caller exits
# with its could-not-run status.
rg_standard_load() { # MANIFEST
  if ! command -v jq >/dev/null 2>&1; then
    rg_message error jq-missing jq "jq is not on PATH; the standard manifest is read with it, so install jq" >&2
    return 1
  fi
  if [ ! -r "$1" ]; then
    rg_message error standard-missing "$1" "the standard manifest is missing or unreadable — re-run \`kendex refresh\`" >&2
    return 1
  fi
  if ! jq -e '
    (.required_contexts | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
    and (.app | type == "string" and length > 0)
    and (.environment | type == "string" and length > 0)
    and (.environment_secrets | type == "array" and length > 0 and all(.[]; type == "string" and length > 0))
  ' "$1" >/dev/null 2>&1; then
    rg_message error standard-malformed "$1" "the standard manifest does not parse, or lacks a non-empty required_contexts, app, environment or environment_secrets" >&2
    return 1
  fi
  WANT_CONTEXTS="$(jq -r '.required_contexts | unique | join(";")' "$1")" || {
    rg_message error standard-read "$1" "could not read required_contexts" >&2
    return 1
  }
  WANT_APP="$(jq -r '.app' "$1")" || {
    rg_message error standard-read "$1" "could not read app" >&2
    return 1
  }
  WANT_ENV="$(jq -r '.environment' "$1")" || {
    rg_message error standard-read "$1" "could not read environment" >&2
    return 1
  }
  WANT_SECRETS="$(jq -r '.environment_secrets | unique | .[]' "$1")" || {
    rg_message error standard-read "$1" "could not read environment_secrets" >&2
    return 1
  }
}

# The names among WANT_SECRETS present in the newline list LISTED, one per
# line; an exact whole-line match, so APP_ID_OLD is not APP_ID.
rg_standard_held() { # LISTED
  local name
  for name in $WANT_SECRETS; do
    if grep -qxF -- "$name" <<<"$1"; then
      printf '%s\n' "$name"
    fi
  done
}

# The names among WANT_SECRETS absent from the newline list LISTED, one per
# line, by the same whole-line match.
rg_standard_missing() { # LISTED
  local name
  for name in $WANT_SECRETS; do
    if ! grep -qxF -- "$name" <<<"$1"; then
      printf '%s\n' "$name"
    fi
  done
}

# VALUE percent-encoded as one URL path segment.
rg_uri() { # VALUE
  jq -rn --arg v "$1" '$v | @uri'
}
