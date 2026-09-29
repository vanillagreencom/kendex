# shellcheck shell=bash
# The organization standard's values, from two sources. The skill's
# standard.json holds the package's own: the CI and gate contexts. The
# consumer's review-gate settings hold the organization's and the
# repository's: the app, the environment and its secret names, and the
# repository's required contexts, which no package can know.
# validate-standard.sh reads GitHub against them and provision-environment.sh
# writes the environment half of them; both load them here, so their shape
# is judged in one place. Requires settings.sh loaded first.

# Sets WANT_CI (the CI context) and WANT_GATE (the gate context, which the
# target layout no longer requires) from MANIFEST, and from settings WANT_ENV
# (REVIEW_GATE_STANDARD_ENVIRONMENT) and WANT_SECRETS
# (REVIEW_GATE_STANDARD_SECRETS, sorted, one per line). Each SCOPE reads the
# keys of the one before it and more:
#   environment  validate-standard.sh --environment-only: those two keys
#   provision    provision-environment.sh: also WANT_APP
#                (REVIEW_GATE_STANDARD_APP) and the bypass actors a ruleset
#                holding one rule type alone may carry, one TYPE:ID:MODE per
#                line: WANT_QUEUE_BYPASS (REVIEW_GATE_STANDARD_QUEUE_BYPASS,
#                for a ruleset holding only merge_queue) and
#                WANT_CHECKS_BYPASS (REVIEW_GATE_STANDARD_CHECKS_BYPASS, for
#                one holding only required_status_checks), each empty where
#                the key is
#   full         validate-standard.sh's full mode: also WANT_CONTEXTS
#                (REVIEW_GATE_STANDARD_CONTEXTS, sorted, `;`-joined)
# A key a scope does not read is left empty and never resolved, so a
# .env.local or process value of it cannot refuse that scope's run. A
# malformed assignment to it in a settings file's [env] table still
# refuses: settings.sh's rg_setting judges each present table whole,
# whatever key it resolves. An empty WANT_CONTEXTS is no
# refusal: the standard-required-contexts row reports it. With no jq on
# PATH, a missing, unreadable or malformed manifest, an unreadable setting
# the scope reads, a key the scope reads unset or empty, a secret name
# that is not uppercase letters, digits and underscores starting with no
# digit, or a bypass entry that is not TYPE:ID:MODE, it prints the refusal
# to stderr and returns 1; the caller exits with its could-not-run status.
rg_standard_load() { # MANIFEST SCOPE
  local secrets contexts invalid missing="" rc=0
  case "$2" in
    environment | provision | full) ;;
    *)
      rg_message error standard-scope "$2" "rg_standard_load: the scope is environment, provision or full" >&2
      return 1
      ;;
  esac
  if ! command -v jq >/dev/null 2>&1; then
    rg_message error jq-missing jq "jq is not on PATH; the standard manifest is read with it, so install jq" >&2
    return 1
  fi
  if [ ! -r "$1" ]; then
    rg_message error standard-missing "$1" "the standard manifest is missing or unreadable — re-run \`kendex refresh\`" >&2
    return 1
  fi
  if ! jq -e '
    (.ci_context | type == "string" and length > 0)
    and (.gate_context | type == "string" and length > 0)
    and .ci_context != .gate_context
  ' "$1" >/dev/null 2>&1; then
    rg_message error standard-malformed "$1" "the standard manifest does not parse, or lacks a non-empty ci_context and a gate_context distinct from it" >&2
    return 1
  fi
  WANT_GATE="$(jq -r '.gate_context' "$1")" || {
    rg_message error standard-read "$1" "could not read gate_context" >&2
    return 1
  }
  WANT_CI="$(jq -r '.ci_context' "$1")" || {
    rg_message error standard-read "$1" "could not read ci_context" >&2
    return 1
  }

  WANT_APP=""
  WANT_CONTEXTS=""
  WANT_QUEUE_BYPASS=""
  WANT_CHECKS_BYPASS=""
  if [ "$2" != environment ]; then
    WANT_APP="$(rg_setting REVIEW_GATE_STANDARD_APP "")" || return 1
    [ -n "$WANT_APP" ] || missing=REVIEW_GATE_STANDARD_APP
    WANT_QUEUE_BYPASS="$(rg_standard_actors REVIEW_GATE_STANDARD_QUEUE_BYPASS)" || return 1
    WANT_CHECKS_BYPASS="$(rg_standard_actors REVIEW_GATE_STANDARD_CHECKS_BYPASS)" || return 1
  fi
  if [ "$2" = full ]; then
    contexts="$(rg_setting REVIEW_GATE_STANDARD_CONTEXTS "")" || return 1
    WANT_CONTEXTS="$(rg_pack "$contexts" ';' | LC_ALL=C sort -u | paste -sd ';' -)" || {
      rg_message error standard-read REVIEW_GATE_STANDARD_CONTEXTS "could not split the required contexts" >&2
      return 1
    }
  fi
  WANT_ENV="$(rg_setting REVIEW_GATE_STANDARD_ENVIRONMENT "")" || return 1
  [ -n "$WANT_ENV" ] || missing="${missing:+$missing,}REVIEW_GATE_STANDARD_ENVIRONMENT"
  secrets="$(rg_setting REVIEW_GATE_STANDARD_SECRETS "")" || return 1
  WANT_SECRETS="$(rg_pack "$secrets" ';' | LC_ALL=C sort -u)" || {
    rg_message error standard-read REVIEW_GATE_STANDARD_SECRETS "could not split the secret names" >&2
    return 1
  }
  [ -n "$WANT_SECRETS" ] || missing="${missing:+$missing,}REVIEW_GATE_STANDARD_SECRETS"
  if [ -n "$missing" ]; then
    rg_message error standard-setting-missing "$missing" "this repository declares no value for these review-gate settings; set each in the [env] table of kendex.settings.toml (references/settings.md names them)" >&2
    return 1
  fi
  # A name is uppercase letters, digits and underscores, and does not start
  # with a digit. GitHub stores every secret name uppercase, and the name
  # lists rg_standard_held and rg_standard_missing read are that stored
  # form, so a lowercase letter is refused: it would never match. An accepted
  # name is the stored name, and two names differing only in case cannot
  # both be declared.
  invalid="$(LC_ALL=C grep -vxE -- '[A-Z_][A-Z0-9_]*' <<<"$WANT_SECRETS")" || rc=$?
  case "$rc" in
    0)
      rg_message error standard-secret-invalid "${invalid//$'\n'/;}" "REVIEW_GATE_STANDARD_SECRETS holds these names, which are not secret names: a name is uppercase letters, digits and underscores, and does not start with a digit; GitHub stores every secret name uppercase" >&2
      return 1
      ;;
    1) ;;
    *)
      rg_message error standard-read REVIEW_GATE_STANDARD_SECRETS "could not check the secret names" >&2
      return 1
      ;;
  esac
}

# The bypass actors the setting KEY admits, one TYPE:ID:MODE per line, the
# spelling validate-standard.sh reads each actor of a ruleset in: GitHub's
# actor_type, its actor_id (empty for an actor GitHub gives none, such as
# OrganizationAdmin) and its bypass_mode. An unset or empty key admits none.
# An entry of any other shape is refused: it would never match an actor.
rg_standard_actors() { # KEY
  local raw actors invalid rc=0
  raw="$(rg_setting "$1" "")" || return 1
  actors="$(rg_pack "$raw" ';' | LC_ALL=C sort -u)" || {
    rg_message error standard-read "$1" "could not split the bypass actors" >&2
    return 1
  }
  [ -n "$actors" ] || return 0
  invalid="$(LC_ALL=C grep -vxE -- '[A-Za-z]+:[0-9]*:(always|pull_request|exempt)' <<<"$actors")" || rc=$?
  case "$rc" in
    0)
      rg_message error standard-bypass-invalid "${invalid//$'\n'/;}" "$1 holds these entries, which are not bypass actors: an entry is TYPE:ID:MODE, GitHub's actor_type, actor_id and bypass_mode (always, pull_request or exempt)" >&2
      return 1
      ;;
    1) ;;
    *)
      rg_message error standard-read "$1" "could not check the bypass actors" >&2
      return 1
      ;;
  esac
  printf '%s\n' "$actors"
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

# The value of the environment variable NAME on stdout, byte-exact: its own
# trailing newlines kept, none added. It reads the process environment only,
# never a shell variable, so a secret named like a bash variable (EUID) or a
# script's own unexported one reads as absent. Returns 1 when the environment
# does not hold NAME, or holds it empty.
rg_secret_value() { # NAME
  local value
  value="$(printenv -- "$1" && printf x)" || return 1
  value="${value%$'\n'x}"
  [ -n "$value" ] || return 1
  printf '%s' "$value"
}

# VALUE percent-encoded as one URL path segment.
rg_uri() { # VALUE
  jq -rn --arg v "$1" '$v | @uri'
}
