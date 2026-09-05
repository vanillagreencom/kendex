# shellcheck shell=bash
#
# The neutral world the two lane suites (lanes.sh, open-terminal-lane.sh)
# share: fake account config dirs, a usage-API fetch stub that answers from
# fixture files, and the canned usage bodies. Nothing here plants a defect; a
# case that needs one writes it into its own home.
#
# Sourced, never run: the runners glob tests/*.sh, so the `lib/` prefix keeps
# this file out of the run. The sourcing suite sets TMP_ROOT first.

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

# make_codex_lane DIR — a codex home with an auth file.
make_codex_lane() {
  local dir="$1"
  mkdir -p "$dir"
  jq -n '{tokens: {access_token: "codex-token", account_id: "acct-1"}}' > "$dir/auth.json"
}

# make_fetcher PATH — the ORCH_LANES_FETCH_CMD stub: prints the fixture file
# $FIXTURE_DIR/<basename of the config dir>.json, or fails when there is none.
make_fetcher() {
  local path="$1"
  cat > "$path" <<'STUB'
#!/usr/bin/env bash
# argv: <harness> <config_dir>
f="$FIXTURE_DIR/$(basename "$2").json"
[[ -f "$f" ]] || exit 1
cat "$f"
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

# new_home NAME — a fresh home and fixture directory under TMP_ROOT; sets H
# and exports FIXTURE_DIR, which the fetch stub reads.
new_home() {
  H="$TMP_ROOT/$1"
  FIXTURE_DIR="$TMP_ROOT/$1.fix"
  rm -rf "$H" "$FIXTURE_DIR"
  mkdir -p "$H" "$FIXTURE_DIR"
  export FIXTURE_DIR
}

# standard_home NAME — three measurable claude lanes and one dir with no
# credentials. Headroom is 100 minus the largest bucket: claude 80, eclaude
# 20, nclaude 5, so claude is the pick and nclaude the one a 15% threshold
# refuses last.
standard_home() {
  new_home "$1"
  make_lane "$H" claude 3600
  make_lane "$H" eclaude 3600
  make_lane "$H" nclaude 3600
  mkdir -p "$H/.openclaude"
  claude_usage 10 20 5  Opus > "$FIXTURE_DIR/.claude.json"
  claude_usage 80 30 10 Opus > "$FIXTURE_DIR/.eclaude.json"
  claude_usage 5  95 12 Opus > "$FIXTURE_DIR/.nclaude.json"
}
