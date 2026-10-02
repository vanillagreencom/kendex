# shellcheck shell=bash
#
# The readers of a usage endpoint's answer: each harness's body turned into the
# bucket record `lanes` emits and lib/lane-model.sh judges. `lanes` is the one
# caller, through parse_usage_body.
#
# Sourced, never run. parse_usage_body reads the SESSION_WINDOW_S `lanes` sets
# and calls copilot_credits_parse from lib/copilot-credits.sh.

# Claude: `.five_hour` and `.seven_day` carry utilization/resets_at directly.
# The model-scoped weekly window moved out of the legacy seven_day_sonnet /
# seven_day_opus fields into `limits[]` entries with kind=="weekly_scoped";
# the legacy fields stand in where an older response carries no entries, so an
# older response still parses, and a response carrying both keeps both. The
# label is whatever the API says, never hard-coded.
#
# EVERY scoped window is kept in model_buckets, not just the most-consumed one:
# the MODEL column reports the largest, while a launch on a named model is
# walled by the window scoped to THAT model, which on an account with several
# is a different entry. lib/lane-model.sh is the reader.
#
# A bucket's label is the API's own display name and NOTHING where the response
# omits it — never the MODEL column's "weekly (model)" filler. A window nobody
# can name is a window that might wall any model, and lane-model.sh counts it
# for all of them; a filler string there would be a name matching no model, and
# naming a model would then be more permissive than not naming one.

parse_claude_usage() {
	jq -c '
		def pct($p): (($p | numbers) // 0) | round | (if (. > 1e12 or . < 0) then 0 else . end);
		(.five_hour  // null) as $s
		| (.seven_day // null) as $w
		# The parentheses around the whole `//` are LOAD-BEARING, not style.
		# jq 1.7 and jq 1.8 disagree on `A // B as $x | C`: 1.7 binds it as
		# `A // (B as $x | C)`, so a non-null A short-circuits and emits A itself
		# instead of ever reaching C. That produced a silent empty parse under the
		# jq on CI while passing locally on 1.8. Never rely on the relative
		# precedence of `//` and `as`.
		| ([.limits[]? | select(type == "object")
		    | select(.kind == "weekly_scoped" or (.group == "weekly" and .scope != null))]) as $live
		# Each legacy field is appended on its own, never as one branch of an
		# if/elif: a response carrying both would otherwise keep the first and
		# drop the second, and the dropped window walls the launch its model
		# names. Appending is a no-op where only one field is present.
		| ((if .seven_day_sonnet != null then
		      [{percent: .seven_day_sonnet.utilization, resets_at: .seven_day_sonnet.resets_at,
		        scope: {model: {display_name: "Sonnet"}}}]
		    else [] end)
		   + (if .seven_day_opus != null then
		        [{percent: .seven_day_opus.utilization, resets_at: .seven_day_opus.resets_at,
		          scope: {model: {display_name: "Opus"}}}]
		      else [] end)) as $legacy
		| (if ($live | length) > 0 then $live else $legacy end) as $scoped
		| (($scoped | max_by(.percent // 0)) // null) as $m
		| {
		    session_5h_pct:  (if $s then pct($s.utilization) else null end),
		    weekly_pct:      (if $w then pct($w.utilization) else null end),
		    model_pct:       (if $m then pct($m.percent) else null end),
		    model_label:     (if $m then ($m.scope.model.display_name // "weekly (model)") else null end),
		    model_buckets:   [$scoped[] | {label: .scope.model.display_name,
		                                   pct: pct(.percent),
		                                   resets_at: (.resets_at // null)}],
		    resets: {
		      session: (if $s then ($s.resets_at // null) else null end),
		      weekly:  (if $w then ($w.resets_at // null) else null end),
		      model:   (if $m then ($m.resets_at // null) else null end)
		    }
		  }
	'
}

# Codex: primary/secondary windows do NOT map to session/weekly by position.
# Their DURATIONS vary by account and shift over time — a weekly-only account
# reports its 7-day limit as the *primary* window with a null secondary, and
# routing by position then labels a 7-day window "5h" and invents a 0% weekly.
# Route each window by its own limit_window_seconds instead.
# `credits` is the balance spent past the plan windows, with the body's
# top-level `spend_control.reached` carried in as `spend_control_reached`; a
# balance or flag that does not parse, or is absent, is null, which
# credit_room never reads as room.
#
# This body is the ChatGPT backend's usage endpoint, which OpenAI does not
# document. The documented read of the same figures is the Codex app server's
# `account/rateLimits/read`, whose snapshot carries `credits` (hasCredits,
# unlimited, balance) and `spendControlReached`. It cannot serve here: it
# carries no `overage_limit_reached`, which credit_room requires; it needs a
# `codex app-server` process per account per refresh, where this body is the
# one request the plan windows read below already come from, cached host-wide
# per account for ORCH_LANES_USAGE_TTL.
parse_codex_usage() {
	local session_window="$1"
	jq -c --argjson sw "$session_window" '
		def pct($p): (($p | numbers) // 0) | floor | (if (. > 1e12 or . < 0) then 0 else . end);
		def flag: if type == "boolean" then . else null end;
		def credits:
			if type != "object" then null
			else {unit: "credits", unlimited: (.unlimited | flag), has_credits: (.has_credits | flag),
			      overage_limit_reached: (.overage_limit_reached | flag),
			      balance: (.balance | if type == "number" then .
			                           elif type == "string" then (try tonumber catch null)
			                           else null end)}
			end;
		# The reset is rendered as an ISO timestamp here; emit_lane gives it,
		# and every other reset, the one spelling utc_resets in
		# lib/lane-model.sh names, so no reader has to know which harness
		# measured the lane.
		def win($w): {
			pct: pct($w.used_percent),
			resets_at: (($w.reset_at | numbers | todate?) // null),
			window_s: ((($w.limit_window_seconds | numbers) // 0) | floor)
		};
		(.spend_control | if type == "object" then (.reached | flag) else null end) as $spent
		| (.credits | credits | if . == null then null else . + {spend_control_reached: $spent} end) as $credits
		| [ (.rate_limit.primary_window   // null),
		    (.rate_limit.secondary_window // null) ]
		| map(select(. != null) | win(.))
		# Within 50% of the 5h window counts as the session bucket; anything
		# materially longer (daily, weekly, monthly) is the long window.
		| ((map(select(.window_s > 0 and .window_s <= ($sw * 3 / 2))) | first) // null) as $s
		| ((map(select(.window_s == 0 or .window_s > ($sw * 3 / 2))) | first) // null) as $w
		| {
		    session_5h_pct: (if $s then $s.pct else null end),
		    weekly_pct:     (if $w then $w.pct else null end),
		    model_pct:      null,
		    model_label:    null,
		    credits:        $credits,
		    resets: {
		      session: (if $s then $s.resets_at else null end),
		      weekly:  (if $w then $w.resets_at else null end),
		      model:   null
		    }
		  }
	'
}

# The buckets one usage body answers, by the harness that measured it: the one
# dispatch, so the current sample and the prior it is compared with parse
# through the same reader.
parse_usage_body() { # HARNESS
	case "$1" in
		claude) parse_claude_usage ;;
		copilot) copilot_credits_parse ;;
		*) parse_codex_usage "$SESSION_WINDOW_S" ;;
	esac
}
