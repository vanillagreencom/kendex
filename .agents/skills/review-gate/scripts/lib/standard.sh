# shellcheck shell=bash
# The organization standard's values, from two sources. The skill's
# standard.json holds the package's own: the CI and gate contexts. The
# consumer's review-gate settings hold the repository's: its required
# contexts and the bypass actors its rulesets admit, which no package can
# know. validate-standard.sh reads GitHub against them and loads them here,
# so their shape is judged in one place. Requires settings.sh loaded first.

# Sets WANT_CI (the CI context) and WANT_GATE (the gate context, which the
# target layout no longer requires) from MANIFEST, and from settings
# WANT_CONTEXTS (REVIEW_GATE_STANDARD_CONTEXTS, sorted, `;`-joined) and the
# bypass actors a ruleset holding one rule type alone may carry, one
# TYPE:ID:MODE per line: WANT_QUEUE_BYPASS
# (REVIEW_GATE_STANDARD_QUEUE_BYPASS, for a ruleset holding only
# merge_queue) and WANT_CHECKS_BYPASS (REVIEW_GATE_STANDARD_CHECKS_BYPASS,
# for one holding only required_status_checks), each empty where the key is.
# An empty WANT_CONTEXTS is no refusal: the standard-required-contexts row
# reports it. With no jq on PATH, a missing, unreadable or malformed
# manifest, an unreadable setting, or a bypass entry that is not
# TYPE:ID:MODE, it prints the refusal to stderr and returns 1; the caller
# exits with its could-not-run status.
rg_standard_load() { # MANIFEST
  local contexts
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

  WANT_QUEUE_BYPASS="$(rg_standard_actors REVIEW_GATE_STANDARD_QUEUE_BYPASS)" || return 1
  WANT_CHECKS_BYPASS="$(rg_standard_actors REVIEW_GATE_STANDARD_CHECKS_BYPASS)" || return 1
  contexts="$(rg_setting REVIEW_GATE_STANDARD_CONTEXTS "")" || return 1
  WANT_CONTEXTS="$(rg_pack "$contexts" ';' | LC_ALL=C sort -u | paste -sd ';' -)" || {
    rg_message error standard-read REVIEW_GATE_STANDARD_CONTEXTS "could not split the required contexts" >&2
    return 1
  }
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

# VALUE percent-encoded as one URL path segment.
rg_uri() { # VALUE
  jq -rn --arg v "$1" '$v | @uri'
}
