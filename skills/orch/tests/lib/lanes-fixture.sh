# shellcheck shell=bash
#
# The neutral world the two lane suites (lanes.sh, open-terminal-lane.sh)
# share: fake account config dirs, a usage-API fetch stub that answers from
# fixture files, and the canned usage bodies. It also carries `settled_mutex`,
# the one reading of a reaped lock every suite that bounds a renewal shares.
# Nothing here plants a defect; a case that needs one writes it into its own
# home.
#
# Sourced, never run: the runners glob tests/*.sh, so the `lib/` prefix keeps
# this file out of the run. The sourcing suite sets TMP_ROOT first, which only
# `new_home` reads, so a suite that wants `settled_mutex` alone needs none.

# make_lane HOME NAME [EXPIRES_IN_S] [PLAN] — a claude config dir with an
# OAuth credentials file; a negative EXPIRES_IN_S is an already-expired token.
make_lane() {
  local home="$1" name="$2" expires_in_s="${3:-3600}" plan="${4:-max}"
  local dir="$home/.$name"
  mkdir -p "$dir"
  local exp=$(( ($(date +%s) + expires_in_s) * 1000 ))
  jq -n --arg at "token-$name" --arg rt "refresh-$name" --argjson exp "$exp" --arg plan "$plan" \
    '{claudeAiOauth: {accessToken: $at, refreshToken: $rt, expiresAt: $exp, subscriptionType: $plan}}' \
    > "$dir/.credentials.json"
}

# make_dead_lane HOME NAME — a claude lane whose access token expired an hour
# ago and whose credentials carry no refresh token to renew it with: the login
# `lanes` proves dead and reports `expired`. That reading needs a client id
# configured, since the renewal refuses on a missing one first, and it never
# reaches the token endpoint, so no row on it posts anywhere.
make_dead_lane() {
  local dir="$1/.$2"
  mkdir -p "$dir"
  jq -n --arg at "token-$2" --argjson exp "$(( ($(date +%s) - 3600) * 1000 ))" \
    '{claudeAiOauth: {accessToken: $at, expiresAt: $exp, subscriptionType: "max"}}' \
    > "$dir/.credentials.json"
}

# make_codex_lane DIR — a codex home with an auth file.
make_codex_lane() {
  local dir="$1"
  mkdir -p "$dir"
  jq -n '{tokens: {access_token: "codex-token", account_id: "acct-1"}}' > "$dir/auth.json"
}

# make_fetcher PATH — the ORCH_LANES_FETCH_CMD stub: answers in the shape both
# network calls of `lanes` answer in, the HTTP status and any Retry-After on the
# first line and the body under it, with the fixture file
# $FIXTURE_DIR/<basename of the config dir>.json as that body, or fails when
# there is none. $FETCH_STATUS names a status other than 200, and
# $FETCH_RETRY_AFTER a Retry-After beside it, so a case can stage a refusal
# without a stub of its own. With FETCH_LOG set, every call first appends that
# basename to it.
#
# A file $FIXTURE_DIR/<basename>.status stages that first line for one lane
# alone, `<code> <retry-after>`, and the body still follows it, so a case can
# refuse one account of several, or refuse with a body the endpoint sent.
#
# With FETCH_SEQ_DIR set the stub counts its calls PER LANE and prefers
# `<basename>.json.<N>` and `<basename>.status.<N>` on the Nth call, so a case
# can have one account answer differently the second time it is asked — which
# is the whole of what a retry has to be measured against. FETCH_DELAY seconds
# hold each call open, for a case timing two callers against each other.
make_fetcher() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
# argv: <harness> <config_dir>
name="$(basename "$2")"
[[ -z "${FETCH_LOG:-}" ]] || printf '%s\n' "$name" >> "$FETCH_LOG"
n=1
if [[ -n "${FETCH_SEQ_DIR:-}" ]]; then
  mkdir -p -- "$FETCH_SEQ_DIR" || exit 1
  n=$(( $(cat -- "$FETCH_SEQ_DIR/$name" 2>/dev/null || printf 0) + 1 ))
  printf '%s\n' "$n" > "$FETCH_SEQ_DIR/$name" || exit 1
fi
st="$FIXTURE_DIR/$name.status.$n"
[[ -f "$st" ]] || st="$FIXTURE_DIR/$name.status"
if [[ -f "$st" ]]; then
  head -n 1 -- "$st"
else
  printf '%s %s\n' "${FETCH_STATUS:-200}" "${FETCH_RETRY_AFTER:-}"
  [[ "${FETCH_STATUS:-200}" == 200 ]] || exit 0
fi
[[ -z "${FETCH_DELAY:-}" ]] || sleep "$FETCH_DELAY"
f="$FIXTURE_DIR/$name.json.$n"
[[ -f "$f" ]] || f="$FIXTURE_DIR/$name.json"
[[ -f "$f" ]] || exit 1
cat -- "$f"
STUB
  chmod +x "$path"
}

# claude_usage SESSION_PCT WEEKLY_PCT MODEL_PCT MODEL_LABEL — a usage body.
claude_usage() {
  jq -n --argjson s "$1" --argjson w "$2" --argjson m "$3" --arg lbl "$4" '{
    five_hour: {utilization: $s, resets_at: "2026-07-27T06:00:00Z"},
    seven_day: {utilization: $w, resets_at: "2026-08-01T06:00:00Z"},
    limits: [{kind: "weekly_scoped", percent: $m, resets_at: "2026-08-01T06:00:00Z",
              scope: {model: {display_name: $lbl}}}]
  }'
}

# age_usage_record STATE_DIR CONFIG_DIR AGE_S — backdate the usage figure
# STATE_DIR holds for CONFIG_DIR, so a case names the age a served figure
# reports without waiting for a clock. The figure's stamp is `usage_fetched_at`
# where a refusal was written over it and `fetched_at` where it stands alone,
# and a record holding no figure is skipped. Finding none stops the suite: a
# case whose staging silently did nothing would assert a fresh figure and call
# it a reused one.
age_usage_record() {
  local f
  for f in "$1"/usage/*.json; do
    [[ -f "$f" && "$(jq -r 'select(.usage) | .config_dir' "$f" 2>/dev/null)" == "$2" ]] || continue
    jq --argjson at "$(( $(date +%s) - $3 ))" \
      'if has("usage_fetched_at") then .usage_fetched_at = $at else .fetched_at = $at end' \
      "$f" > "$f.tmp" && mv "$f.tmp" "$f"
    return 0
  done
  echo "age_usage_record: no cached usage record for $2 under $1" >&2
  exit 1
}

# new_home NAME — a fresh home and fixture directory under TMP_ROOT; sets H
# and exports FIXTURE_DIR, which the fetch stub reads.
new_home() {
  H="$TMP_ROOT/$1"
  FIXTURE_DIR="$TMP_ROOT/$1.fix"
  rm -rf "$H" "$FIXTURE_DIR"
  mkdir -p "$H" "$FIXTURE_DIR"
  export FIXTURE_DIR
}

# standard_home NAME — three measurable claude lanes and one config dir with
# no credentials. Headroom is 100 minus the largest bucket: claude 80, eclaude
# 20, nclaude 5, so claude is the pick and nclaude the one a 15% threshold
# refuses last.
standard_home() {
  new_home "$1"
  make_lane "$H" claude 3600
  make_lane "$H" eclaude 3600
  make_lane "$H" nclaude 3600
  mkdir -p "$H/.openclaude"
  printf '{}\n' > "$H/.openclaude/.claude.json"
  claude_usage 10 20 5  Opus > "$FIXTURE_DIR/.claude.json"
  claude_usage 80 30 10 Opus > "$FIXTURE_DIR/.eclaude.json"
  claude_usage 5  95 12 Opus > "$FIXTURE_DIR/.nclaude.json"
}

# settled_mutex LOCK_DIR [TRIES] — what a reaped run leaves once it is DONE,
# never the instant the ceiling hands control back. The subshell that took the
# mutex runs its release a moment later, so a row that sampled that instant
# would go red on a loaded runner with no change to the code under test.
#
# TRIES is 0.1 s each, 50 by default. A row expecting `released` wants the full
# budget, since it waits only as long as the teardown actually takes. A row
# expecting `held` always polls to the ceiling, so it passes a short count: the
# state it asserts is already settled, and the wait buys it nothing.
settled_mutex() { # LOCK_DIR [TRIES]
  local waited=0 limit="${2:-50}"
  while [ -d "$1" ]; do
    [ "$waited" -lt "$limit" ] || { printf held; return; }
    sleep 0.1
    waited=$((waited + 1))
  done
  printf released
}
