# shellcheck shell=bash
#
# A Copilot account's monthly AI credit pool, read the way GitHub's own
# clients read it: GET api.github.com/copilot_internal/user with the account's
# stored login. The one reader of that endpoint and of the login it is asked
# with; `lanes` holds its cache and refusal record between the request and the
# parse, so a caller asks for the three steps in turn. The record `lanes`
# builds from the parse is ../../schemas/copilot-credits.md.
#
# THE STORED LOGIN. Copilot CLI keeps its login list in <COPILOT_HOME>/config.json,
# a state file it writes itself and whose layout no document names. The layout
# assumed here, and nowhere else: the file is JSON after any leading `//`
# comment lines, and its top-level `copilotTokens` holds the account's token
# either as a string or as an object keyed `<host>:<login>` whose one
# GitHub.com entry, a key opening `https://github.com:`, is the token: the
# endpoint below is GitHub.com's, and a token another host issued, a GitHub
# Enterprise Cloud tenant on `*.ghe.com` among them, is never sent to it. A
# file, a key or a token that does not read that way is a keyed reason, never
# a guess: `config-missing`, `config-unreadable`, `token-missing`,
# `token-ambiguous` for more than one GitHub.com login, and `token-foreign-host`
# where every login names another host. `copilotTokens` is the key Copilot CLI
# 1.0.90 writes (measured); 1.0.88 wrote the same value under `copilot_tokens`,
# read only where the current key is absent, and dropped once the fleet's
# Copilot CLI floor is 1.0.90. On a fleet host
# the value is a placeholder the host's proxy rewrites for api.github.com. The
# token crosses to curl on stdin, never in argv.
#
# This read is the fallback for interfaces Copilot CLI documents and that
# cannot serve here (1.0.90). Its login inputs, `copilot login` and the
# COPILOT_GITHUB_TOKEN, GH_TOKEN and GITHUB_TOKEN variables (`copilot help
# environment`), hand the CLI a token; none reads back the login an account
# already stored. Its credit budget is shown only inside a running session,
# in the footer, the `/statusline` quota option and `/usage` (`copilot help
# billing`), and no command or SDK reports an account's pool from outside
# one, while `lanes` measures accounts no session runs on.
#
# THE ENDPOINT is internal and its shape can change, so every field is checked
# for its type. `quota_snapshots.premium_interactions` gives `entitlement`,
# `remaining`, `unlimited`, `overage_permitted`, `overage_count`,
# `credits_used` and `token_based_billing`, and `quota_reset_date_utc` the
# reset. An answer lacking `remaining` or `entitlement` as numbers, or with an
# entitlement of zero, measures nothing. The used share is rounded UP, so a
# pool one credit short of its grant never reads as having more; a pool at or
# past its grant is 100, walled at every threshold whatever overage it
# permits, since no paid overage is authorised; one reporting more remaining
# than it was granted is 0. Only a boolean `unlimited: true` is unlimited, a
# pool at 0 percent used whatever the counts say; a zero, a failed read and a
# missing or mistyped field never are.
#
# Sourced, never run.

COPILOT_CREDITS_URL="https://api.github.com/copilot_internal/user"

# copilot_credits_token HOME — the stored login's token for the account at
# HOME, into COPILOT_CREDITS_TOKEN, 0 where it reads; 1 with the reason in
# COPILOT_CREDITS_REASON. Into a variable and never onto stdout, so the token
# never reaches a command substitution's pipe or a log.
COPILOT_CREDITS_TOKEN="" COPILOT_CREDITS_REASON=""
copilot_credits_token() { # HOME
  local config="$1/config.json" answer
  COPILOT_CREDITS_TOKEN="" COPILOT_CREDITS_REASON=""
  [ -f "$config" ] || { COPILOT_CREDITS_REASON=config-missing; return 1; }
  if ! answer="$(sed '/^[[:space:]]*\/\//d' "$config" 2>/dev/null | jq -r '
      (.copilotTokens // .copilot_tokens) as $t
      | if ($t | type) == "string" then "token\t" + $t
        elif ($t | type) == "object" then
          ([$t | to_entries[] | select(.value | type == "string")]) as $all
          | ([$all[] | select(.key | startswith("https://github.com:")) | .value]) as $v
          | if ($v | length) == 1 then "token\t" + $v[0]
            elif ($v | length) > 1 then "token-ambiguous"
            elif ($all | length) > 0 then "token-foreign-host"
            else "token-missing" end
        else "token-missing" end' 2>/dev/null)"; then
    COPILOT_CREDITS_REASON=config-unreadable
    return 1
  fi
  case "$answer" in
    "token	"?*) COPILOT_CREDITS_TOKEN="${answer#token	}" ;;
    token-ambiguous | token-foreign-host) COPILOT_CREDITS_REASON="$answer"; return 1 ;;
    *) COPILOT_CREDITS_REASON=token-missing; return 1 ;;
  esac
}

# copilot_credits_request TOKEN — the endpoint's raw answer on stdout in the
# shape `curl -D - -w '\n%{http_code}'` prints, headers, body and status last,
# for the caller's HTTP reader. 1 where curl is missing or fails.
copilot_credits_request() { # TOKEN
  command -v curl >/dev/null 2>&1 || return 1
  curl -s --max-time 10 -D - -w '\n%{http_code}' "$COPILOT_CREDITS_URL" \
    -H "Accept: application/json" -K - <<CURLCFG
header = "Authorization: token $1"
CURLCFG
}

# copilot_credits_parse < BODY — the pool one endpoint body answers, as the
# buckets `lanes` records: `monthly_pct`, `unlimited`, `credits` (the counts,
# ../../schemas/copilot-credits.md), `plan` and `resets.monthly`, null where
# the body measured nothing.
copilot_credits_parse() {
  jq -c '
    ((.quota_snapshots.premium_interactions | objects) // {}) as $q
    | ($q.unlimited == true) as $unlimited
    | (($q.remaining | numbers) // null) as $remaining
    | (($q.entitlement | numbers) // null) as $granted
    | ($remaining != null and $granted != null and $granted > 0) as $counted
    | (if $unlimited then 0
       elif ($counted | not) then null
       elif $remaining <= 0 then 100
       else ((($granted - $remaining) * 100 / $granted) | ceil | if . < 0 then 0 else . end)
       end) as $pct
    | ((.quota_reset_date_utc | strings
        | if test("^[0-9]{4}-[0-9]{2}-[0-9]{2}$") then . + "T00:00:00Z"
          elif test("^[0-9]{4}-[0-9]{2}-[0-9]{2}T") then . else null end) // null) as $reset
    | {
        monthly_pct: $pct,
        unlimited: $unlimited,
        credits: (if $unlimited then {unit: "AIC", unlimited: true}
                  elif $counted then {unit: "AIC", unlimited: false,
                                      used: (($q.credits_used | numbers) // null),
                                      granted: $granted,
                                      remaining: $remaining,
                                      over: (($q.overage_count | numbers) // null),
                                      overage_permitted: ($q.overage_permitted == true),
                                      token_based_billing: (($q.token_based_billing | booleans) // null)}
                  else null end),
        plan: ((.copilot_plan | strings) // null),
        resets: {monthly: (if $pct == null then null else $reset end)}
      }'
}
