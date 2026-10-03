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
# THE KEYRING LOGIN. Where Copilot CLI keeps the token in the platform's
# credential store, config.json holds none and names the login in
# `lastLoggedInUser` `{host, login}`. The one store read here is the Linux
# Secret Service, through libsecret's `secret-tool`. Measured on Copilot CLI
# 1.0.91 by logging its Secret Service calls: it
# searches `service` `copilot-cli` with `username` `<host>:<login>:entra`, then
# `<host>:<login>:github`, then `<host>:<login>`, an older form 1.0.91 still
# reads and this read drops when the CLI does. Only a `https://github.com`
# login is looked up, for the reason above. The `:entra` item is a Microsoft
# Entra sign-in, not the GitHub login this endpoint is asked with, so it is
# never read. Another platform's store, the macOS Keychain among them, is not
# read, since its read can raise an access prompt.
#
# The read is libsecret's `secret-tool search`, whose behaviour is its source
# (GNOME/libsecret tool/secret-tool.c and libsecret/secret-methods.c, main at
# 0ee86df8). It exits 1 where the Secret Service cannot be reached, else 0.
# For the first match it prints `[<id>]` and `label = `, then
# `secret = <secret>` only where the secret was read, then `created`,
# `modified` and `schema`; no match prints nothing. Each line is flushed as it
# is printed (GLib's g_print), so the secret, written raw, keeps its place.
# A secret the service withholds is printed the same way without its
# `secret = ` line, after one `secret-tool: <message>` line on stderr, and
# the exit is still 0 (`on_retrieve_secret`). stderr is read merged with
# stdout: it never carries the secret, only that error line and
# `attribute.` lines, and the first error line is the one part of it a record
# keeps. Without `--unlock` a locked item is withheld and nothing prompts;
# `secret-tool lookup` unlocks a locked match unasked, which prompts, so it is
# not used. The reasons: `keyring-absent` where no `secret-tool` or `timeout`
# is on PATH, as on a platform with no Secret Service, or the search fails or
# outlasts its bound; `keyring-locked` for a secret withheld under
# COPILOT_CREDITS_KEYRING_LOCKED; `keyring-refused` for one withheld under any
# other error, that error line in the record; `keyring-empty` where neither
# username matches or the secret is empty.
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
# `remaining`, `unlimited`, `overage_permitted`, `overage_count` and
# `token_based_billing`, and `quota_reset_date_utc` the reset. Its
# `credits_used` is not the pool github.com shows, so the used count is the
# grant less `remaining`, the figure the share is judged from. An answer lacking `remaining` or `entitlement` as numbers, or with an
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
# COPILOT_CREDITS_REASON. COPILOT_CREDITS_WHERE names where the login was read
# or sought, for a record's detail. The token goes into a variable and never
# onto this function's stdout, so no caller captures it with a command
# substitution, and neither COPILOT_CREDITS_REASON nor COPILOT_CREDITS_WHERE
# carries it. Inside, it crosses this shell's own substitutions: jq's on the
# config path, secret-tool's on the keyring path.
COPILOT_CREDITS_TOKEN="" COPILOT_CREDITS_REASON="" COPILOT_CREDITS_WHERE=""
# Seconds one `secret-tool search` may take before the Secret Service reads
# absent.
COPILOT_CREDITS_KEYRING_TIMEOUT_S=5
# The one withheld-secret error read as a lock: gnome-keyring's GetSecret
# refusal for a locked item (daemon/dbus/gkd-secret-session.c, main at
# e13215e6), which secret-tool prints with libsecret's D-Bus error name
# stripped (libsecret/secret-util.c `_secret_util_strip_remote_error`).
COPILOT_CREDITS_KEYRING_LOCKED="secret-tool: Cannot get secret of a locked object"
copilot_credits_token() { # HOME
  local config="$1/config.json" answer
  COPILOT_CREDITS_TOKEN="" COPILOT_CREDITS_REASON="" COPILOT_CREDITS_WHERE="$config"
  [ -f "$config" ] || { COPILOT_CREDITS_REASON=config-missing; return 1; }
  if ! answer="$(sed '/^[[:space:]]*\/\//d' "$config" 2>/dev/null | jq -r '
      (.copilotTokens // .copilot_tokens) as $t
      | ((.lastLoggedInUser | objects | select(.host == "https://github.com") | .login | strings
          | select(. != "")) // null) as $login
      | (if $login == null then "token-missing" else "login\t" + $login end) as $missing
      | if ($t | type) == "string" then "token\t" + $t
        elif ($t | type) == "object" then
          ([$t | to_entries[] | select(.value | type == "string")]) as $all
          | ([$all[] | select(.key | startswith("https://github.com:")) | .value]) as $v
          | if ($v | length) == 1 then "token\t" + $v[0]
            elif ($v | length) > 1 then "token-ambiguous"
            elif ($all | length) > 0 then "token-foreign-host"
            else $missing end
        else $missing end' 2>/dev/null)"; then
    COPILOT_CREDITS_REASON=config-unreadable
    return 1
  fi
  case "$answer" in
    "token	"?*) COPILOT_CREDITS_TOKEN="${answer#token	}" ;;
    "login	"?*) copilot_credits_keyring "${answer#login	}" ;;
    token-ambiguous | token-foreign-host) COPILOT_CREDITS_REASON="$answer"; return 1 ;;
    *) COPILOT_CREDITS_REASON=token-missing; return 1 ;;
  esac
}

# copilot_credits_keyring LOGIN — the GitHub.com LOGIN's token from the
# Secret Service item Copilot CLI keeps it in, as copilot_credits_token
# answers. stdin is /dev/null and the search is bounded, so nothing waits on a
# prompt.
copilot_credits_keyring() { # LOGIN
  local cmd user out rc secret err nl=$'\n'
  for cmd in secret-tool timeout; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      COPILOT_CREDITS_REASON=keyring-absent COPILOT_CREDITS_WHERE="the Secret Service: no $cmd on PATH"
      return 1
    fi
  done
  for user in "https://github.com:$1:github" "https://github.com:$1"; do
    rc=0
    out="$(timeout "$COPILOT_CREDITS_KEYRING_TIMEOUT_S" secret-tool search service copilot-cli username "$user" \
      </dev/null 2>&1)" || rc=$?
    err=""
    case "$nl$out" in
      *"${nl}secret-tool: "*)
        err="$nl$out"
        err="secret-tool: ${err#*"${nl}secret-tool: "}"
        err="${err%%"$nl"*}"
        ;;
    esac
    if [ "$rc" -eq 124 ]; then
      COPILOT_CREDITS_REASON=keyring-absent
      COPILOT_CREDITS_WHERE="the Secret Service: secret-tool search outlasted ${COPILOT_CREDITS_KEYRING_TIMEOUT_S}s for username=$user"
      return 1
    elif [ "$rc" -ne 0 ]; then
      COPILOT_CREDITS_REASON=keyring-absent
      COPILOT_CREDITS_WHERE="the Secret Service: secret-tool search exited $rc for username=$user${err:+: $err}"
      return 1
    fi
    case "$out" in
      *"${nl}secret = "*)
        secret="${out#*"${nl}secret = "}"
        secret="${secret%%"$nl"*}"
        if [ -n "$secret" ]; then
          COPILOT_CREDITS_TOKEN="$secret"
          return 0
        fi
        ;;
      *"${nl}label = "*)
        COPILOT_CREDITS_WHERE="the Secret Service item service=copilot-cli username=$user"
        if [ "$err" = "$COPILOT_CREDITS_KEYRING_LOCKED" ]; then
          COPILOT_CREDITS_REASON=keyring-locked
        else
          COPILOT_CREDITS_REASON=keyring-refused
          COPILOT_CREDITS_WHERE="$COPILOT_CREDITS_WHERE: ${err:-secret withheld with no secret-tool error line}"
        fi
        return 1
        ;;
    esac
  done
  COPILOT_CREDITS_REASON=keyring-empty
  COPILOT_CREDITS_WHERE="the Secret Service items service=copilot-cli username=https://github.com:$1:github and https://github.com:$1"
  return 1
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
                                      used: ($granted - $remaining),
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
