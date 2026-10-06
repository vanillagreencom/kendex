# shellcheck shell=bash
#
# The one answer to "what stands between this account and this launch". A lane
# picked on its binding bucket alone can still open on a model the account has
# no allowance left for, and the launch's first turn is a usage banner instead
# of a session.
#
# The jq program below is the whole answer, and `lanes` is its only judge:
# both of its pick forms — the fleet chooser and the single named lane — read
# `lane_binding` and the `wall_verdict` that classifies it from here, so the two
# cannot come to different conclusions about one account on one usage reading,
# nor can one of them know a verdict the other has no arm for.
# oversee-watch reads `lane_binding` too, for the reset a walled launch waits
# on, once `lanes pick` has judged the wall; it judges no wall of its own.
#
# Sourced, never run.

# model_binding($model) over one lane record: the bucket with the largest usage
# percentage that stands between this account and a launch on $model, or null
# where the record carries no window that answers. The answer keeps the bucket
# and reset beside the percentage so a refusal can name what made the decision.
#
# The 5-hour session and the plan-wide weekly window wall every model, so both
# always count, and so does a monthly pool: the Copilot credits a Copilot
# account, or a Pi launch on a `github-copilot/` model, spends are one pool for
# every model it names. A
# model-scoped weekly window walls only the model its own label names, so a
# launch on another model does not draw on it and it is left out — the
# difference between refusing an account that is free for this launch and
# launching one into a wall the binding bucket never showed.
#
# The label match is containment in either direction over the NORMALIZED
# spellings: case-folded, with every character that is not a letter or a digit
# dropped. An API label carries a version the caller's model id does not
# (`Fable 5.1` for `fable`), and a fully-spelled id carries a vendor and a
# generation the label does not (`claude-opus-5` for `Opus`).
#
# Dropping the separators is what lets a full model id reach its own window:
# `Fable 5.1` and `claude-fable-5-1` spell one model with different separators,
# and raw containment finds neither inside the other, so the scoped window is
# dropped and the account is judged on the session and weekly windows alone —
# the launch then opens on the very usage banner this file exists to prevent.
# Normalized, `fable51` sits inside `claudefable51`.
#
# Dropping them can also match one generation onto another (`Opus 5` inside
# `claude-opus-5-1`). That direction only ever adds a window to the judgement,
# so it refuses an account that might be free rather than launching one into a
# wall, which is the bias the unnamed-window rule below takes too.
#
# A label or model name with no letter or digit left matches nothing, since
# containment in an empty string is true of every string.
#
# A window with NO label counts for every model. The API omitted the name, so
# nothing says which model it is scoped to, and a window that might wall this
# launch is not evidence the launch is free. Skipping it would make naming a
# model more permissive than naming none: `pick` with no model still refuses
# such an account through its binding bucket.
#
# A record whose windows answer nothing yields null, which every caller must
# read as "not measured" and never as "free": wall_verdict below classifies
# such a lane unmeasured, and no caller picks it.
#
# No apostrophe ANYWHERE in the program below: it is one single-quoted shell
# word from the opening quote to the closing one, so an apostrophe at any depth
# ends the string there and hands jq a fragment.
# shellcheck disable=SC2016  # a jq program, expanded by jq and never by the shell.
LANE_MODEL_JQ='
def lane_norm: ascii_downcase | gsub("[^a-z0-9]"; "");

# The statuses that can carry a usage reading, named once so both guards below
# and the record `lanes` emits agree. `rate_limited` carries one only where the
# endpoint refused a usage REFRESH while the host still held its last figures:
# those windows were read from the account, and usage_age_s says how old they
# are. Treating that lane as unmeasured would wall every launch on the host for
# the length of a transient burst, which is the whole cost the status exists
# to remove. A `rate_limited` lane with no figure, a token renewal refused with
# 429 or a usage 429 with nothing cached, passes this test too and reaches null
# only through the headroom_pct check in binding_bucket and the null-pct filter
# in max_binding, which must stay.
def lane_measured: (.status == "ok" or .status == "rate_limited");

def wall_rank:
  if .bucket == "monthly" then 3
  elif .bucket == "weekly" then 2
  elif .bucket == "model" then 1
  else 0
  end;

def max_binding:
  map(select(.pct != null))
  | if length == 0 then null else max_by([.pct, wall_rank]) end;

def shared_bindings:
  [{bucket: "session", pct: .session_5h_pct,
    resets_at: (.resets.session // null)},
   {bucket: "weekly", pct: .weekly_pct,
    resets_at: (.resets.weekly // null)},
   {bucket: "monthly", pct: (.monthly_pct // null),
    resets_at: (.resets.monthly // null)}];

def model_bindings($model):
  ($model | lane_norm) as $m
  | [ (.model_buckets // [])[]
         | ((.label // "") | lane_norm) as $l
         | select(.label == null
                  or ($l != "" and $m != ""
                      and (($l | contains($m)) or ($m | contains($l)))))
         | {bucket: "model", label: (.label // null), pct: .pct,
            resets_at: (.resets_at // null)} | select(.pct != null) ];

def model_binding($model):
  (shared_bindings + model_bindings($model)) | max_binding;

# binding_bucket over one lane record: the account-wide binding bucket, or null.
# Null is "nothing measured this", which every caller refuses on and none may
# read as room. With no model named, this bucket decides as it always did.
#
# A record whose usage could not be read answers null whatever its other fields
# say: a window nobody read is not an empty one.
def binding_bucket:
  if ((lane_measured | not) or .headroom_pct == null
      or .binding_bucket == null) then null
  else {bucket: .binding_bucket,
        label: (if .binding_bucket == "model" then ([.model_buckets[]] | max_by(.pct).label // null) else null end),
        pct: (100 - .headroom_pct),
        resets_at: (.binding_resets_at // null)}
  end;

def lane_binding($model):
  if (lane_measured | not) then null
  elif $model != "" then model_binding($model)
  else binding_bucket
  end;

# lane_binding($model; $binding_floor) is the same judgement with the account
# own binding bucket held to the threshold as well.
#
# A model wall alone answers "may this launch run", which is the right question
# for a lane picked to run ONE model: an account whose Opus window is spent is
# still free for a Sonnet lane, and open-terminal picks on that. It is not the
# whole question for a caller whose own next judgement reads the binding bucket.
# The overseer is that caller: it succeeds itself on headroom_pct, the worst of
# every window, so a successor opened on an account whose binding bucket is a
# model it will never launch reaches its first judgement already past the mark
# and succeeds itself again, costing a window swap and a handoff per cycle.
#
# The two bounds use ONE number: the caller passes a single threshold and both
# walls are judged against it, so they cannot drift apart.
#
# Null still wins over any number, in either wall. An unmeasured binding bucket
# beside a measured model wall is a window nobody read, and this file never
# lets that read as room.
def lane_binding($model; $binding_floor):
  lane_binding($model) as $w
  | if $binding_floor != true then $w
    elif $w == null then null
    else (binding_bucket as $b
          | if $b == null then null else ([$w, $b] | max_binding) end)
    end;

# same_window($binding) over one bucket of the prior sample: true where it is
# the window $binding judges now, so the difference between the two readings
# is usage spent inside one window and never a reset.
#
# Neither side of the comparison is held stable by the usage endpoint between
# two reads, so both are compared as identities rather than as strings. The
# label is compared in its lane_norm spelling, the one model_binding matches a
# model on, and a null label only ever matches a null one. The reset stamps are
# one window where both parse to epochs no more than reset_drift_s apart: a
# stamp read either side of a second boundary is still the same reset, and an
# equality test would read it as a new window on every pass, so the account
# would never measure a rate while its figure moved. A real reset between the
# two readings moves the stamp by a whole window, 5 hours at the shortest, so
# the tolerance never joins two windows. A stamp that does not parse is
# compared by equality, and a window with no stamp matches nothing, since
# nothing then says the two readings share it.
def reset_drift_s: 300;
def reset_epoch: if type == "string" then (try fromdateiso8601 catch null) else null end;
def label_identity: if . == null then null else lane_norm end;
def same_window($binding):
  (.resets_at | reset_epoch) as $was
  | ($binding.resets_at | reset_epoch) as $now
  | ((.label // null) | label_identity) == (($binding.label // null) | label_identity)
    and .resets_at != null and $binding.resets_at != null
    and (if $was != null and $now != null
         then ($was - $now | if . < 0 then -. else . end) <= reset_drift_s
         else .resets_at == $binding.resets_at end);

def with_lane_binding($model; $binding_floor):
  lane_binding($model; $binding_floor) as $binding
  | (if $binding == null then [] elif $binding.bucket == "model" then (._rate_prior.model_buckets // [])
     else [{label: null,
            pct: (if $binding.bucket == "session" then ._rate_prior.session_5h_pct
                  elif $binding.bucket == "weekly" then ._rate_prior.weekly_pct
                  elif $binding.bucket == "monthly" then ._rate_prior.monthly_pct else null end),
            resets_at: ._rate_prior.resets[$binding.bucket]}] end
     | map(select(same_window($binding)))
     | first.pct // null) as $prior
  | (if $binding == null or $prior == null then null
     else ($binding.pct - $prior) end) as $delta
  | (if $delta == null then "one-sample"
     elif ._rate_elapsed_s < 60 then "samples-too-close"
     elif $delta <= 0 then "not-increasing"
     else "measured" end) as $rate_state
  | . + {wall: ($binding.pct // null),
         binding_bucket: ($binding.bucket // null),
         binding_resets_at: ($binding.resets_at // null),
         usage_rate_state: $rate_state,
         usage_rate_pct_per_min:
           (if $rate_state == "measured" then ($delta * 60 / ._rate_elapsed_s) else null end),
         projected_wall_minutes:
           (if $rate_state == "measured"
            then (((100 - $binding.pct) * ._rate_elapsed_s / ($delta * 60)) | ceil)
            else null end)};

# with_lane_projection($burn_default; $now) over one record with_lane_binding
# has judged: the room the account has left if every live lane on it keeps
# burning, which is what a launch onto it inherits. A wall reading lags the
# launches in flight by minutes, so an account read as having the most room
# fills until it walls; the projection charges each live claim its expected
# burn before any verdict is taken.
#
# Each claim inherits its share of account-wide burn, divided by the
# claims live at the latest sample, floored at one. Missing counts and host
# rows use one. The divisor stays fixed while the sample is cached, so a new
# claim costs the share for another lane. A model rate uses one: claims omit
# models, so claims on other models cannot dilute it. With no claims or no rate, use
# ORCH_LANE_BURN_PCT_PER_HOUR.
#
# The default is points of the 5-hour session window. A weekly window, the
# plan-wide one or a model-scoped one, holds the same hour of work as the
# share 5 of its 168 hours is, so it is charged the default times 5/168:
# charged whole, an account weekly-bound at 86 percent with two lanes would
# project past 95 and be dropped with days of room left. A monthly Copilot pool
# holds it as 5 of the 720 hours of a month, charged the default times 5/720.
# The binding bucket is charged one hour of that burn per claim. The 5-hour
# session window is projected beside it whatever binds, since it walls every
# model: each claim is charged the session burn for the hours left until that
# window resets, bounded to 1 to 5, or 1 where the reset is unknown. Its burn
# is the binding one where the session binds and the default otherwise, since
# only the binding bucket carries a measured rate. Once a session reset makes
# the weekly window binding, its 5/168 charge alone lets an account carrying
# many lanes read as roomy while those lanes spend the new session window
# within hours; charging that window one hour, or charging the weekly window
# to its reset, still leaves such an account ahead of one with less room.
#
# projected_headroom_pct is the smaller of the two projected rooms, null where
# the wall is null, since nothing measured the account, or the claims are
# null, since the claim store could not be read: an unknown count is never
# charged as zero lanes. A record with no session reading is projected on the
# binding bucket alone. The record keeps both rooms and the session charge
# beside it, so a launch that stores the record names which window decided.
# projected_window is that window, {bucket, pct, resets_at}: the session
# window where its room is the smaller, the binding bucket otherwise, null
# with no projection. A refusal on the projection names it, and a wall dates
# to its reset rather than to the reset of the binding bucket.
def with_lane_projection($burn_default; $now):
  (if .usage_rate_state == "measured" and (.claims // 0) > 0
   then (.usage_rate_pct_per_min * 60) / (if .binding_bucket == "model" then 1 else ([._rate_sample_claims // 1, 1] | max) end)
   elif .binding_bucket == "session" then $burn_default
   elif .binding_bucket == "monthly" then $burn_default * 5 / 720
   else $burn_default * 5 / 168 end) as $burn
  | ((.resets.session // null) | reset_epoch) as $session_reset
  | (if $session_reset == null then 1
     else [1, ([5, ($session_reset - $now) / 3600] | min)] | max end) as $session_hours
  | (if .binding_bucket == "session" then $burn else $burn_default end) as $session_burn
  | (if .wall == null or .claims == null then null
     else 100 - .wall - .claims * $burn end) as $binding_room
  | (if $binding_room == null or .session_5h_pct == null then null
     else 100 - .session_5h_pct - .claims * $session_burn * $session_hours end) as $session_room
  | . + {burn_pct_per_lane_hour: (if .wall == null then null else $burn end),
         binding_projected_headroom_pct: $binding_room,
         session_projected_headroom_pct: $session_room,
         session_burn_pct_per_lane_hour: (if $session_room == null then null else $session_burn end),
         session_charge_hours: (if $session_room == null then null else $session_hours end),
         projected_headroom_pct:
           (if $binding_room == null then null
            else [$binding_room, $session_room] | map(select(. != null)) | min end),
         projected_window:
           (if $binding_room == null then null
            elif $session_room != null and $session_room < $binding_room
            then {bucket: "session", pct: .session_5h_pct, resets_at: (.resets.session // null)}
            else {bucket: .binding_bucket, pct: .wall, resets_at: (.binding_resets_at // null)} end)};

# judged_wall over one record with_lane_projection has read: the projected
# use wall_verdict judges, for the chooser and `pick --lane --projected`, so a
# named lane is refused on the rule the chooser drops it on. Null, which
# wall_verdict reads as unmeasured, where no projection was made: a wall
# nobody read, or claims nobody could count. Both callers refuse an unread
# claim store before judging, and this arm keeps one that reached it from
# reading as zero lanes in flight.
def judged_wall:
  if .projected_headroom_pct == null then null
  else 100 - .projected_headroom_pct
  end;

# The reset bonus is bounded to [1, 2]: a short reset cannot let small room
# outrank an account with more than twice that room. An unknown reset earns
# no bonus. The caller supplies the clock so one pick judges every row at once.
def with_lane_selection_score($now):
  (.binding_resets_at | reset_epoch) as $reset
  | (if $reset == null then null else ([0, ($reset - $now) / 3600] | max) end) as $hours
  | . + {selection_score:
      (if .projected_headroom_pct == null then null
       else .projected_headroom_pct * (if $hours == null then 1 else 1 + 1 / (1 + $hours) end) end)};

def lane_public: del(._rate_prior, ._rate_elapsed_s, ._rate_sample_claims, ._tier, ._expires, ._score, ._credit_unread, ._id);

# One spelling for every reset a lane record carries: whole-second UTC with a
# Z, the form Codex resets are rendered in. The Claude usage endpoint writes
# fractional seconds and +00:00, and a provider row carries whatever its
# timestamp is; a reader parsing the stamp (the BSD `date` arm cannot read the
# fraction) or comparing two of them, as same_window does with the prior
# sample, needs one form. emit_lane applies it to the current
# windows and to the prior sample alike, so the comparison stays like with like.
def utc_stamp: if type == "string" then sub("\\.[0-9]+"; "") | sub("\\+00:00$"; "Z") else . end;
def utc_resets:
  (if (.resets | type) == "object" then .resets |= map_values(utc_stamp) else . end)
  | (if (.model_buckets | type) == "array"
     then .model_buckets |= map(if type == "object" then .resets_at |= utc_stamp else . end)
     else . end);

# wall_verdict($max) over ONE percentage from lane_binding above: the
# one word both pick forms answer with. Room, walled, or unmeasured.
#
# This is the ONLY place the three states are named. Both `lanes pick` and
# `lanes pick --lane` classify through it, so neither form can know a state the
# other does not: the fleet chooser PARTITIONS its lanes on this word instead
# of filtering on a predicate written out a second time, and a filter cannot
# fold "nothing measured this" back into "over the limit" unnoticed.
#
# Null is tested for BY NAME, never through a number standing in for it: a
# sentinel above every real percentage is still a percentage, and it passes a
# threshold set above it. The parser caps --max-pct at 100, so no legal
# threshold sits above such a sentinel, and this arm holds at every one of them.
def wall_verdict($max):
  if . == null then "unmeasured"
  elif . < $max then "room"
  else "walled"
  end;

# credit_room($credit_floor) over one lane record: true where a Codex account
# holds a credit balance OpenAI spends once the included plan windows are
# reached, so a window wall does not stop its launch. The balance must sit
# strictly above the floor, with has_credits true and overage_limit_reached
# and spend_control_reached false; any of the four missing or unparsed is no
# credit room, never room. The usage body fields rate_limit.allowed and
# model_usage.*.credits_would_enable go unread: an account at its plan limit
# that completes turns on credits reads both false, so gating on them would
# wall it.
def credit_room($credit_floor):
  .harness == "codex"
  and .credits.has_credits == true and .credits.overage_limit_reached == false
  and .credits.spend_control_reached == false
  and (.credits.balance | type) == "number" and .credits.balance > $credit_floor;

# with_lane_verdict($wall; $max; $credit_floor) over one record: the record
# with `verdict`, the wall_verdict of $wall, which every judge of an account
# reads, so the chooser, `pick --lane` and the listing know one rule. A walled
# Codex account with credit_room is `room` on its credits, and its
# binding_bucket becomes `credits`, which is how the chooser ranks it after
# every account with plan room and how each display names it. The
# forecast of its spent window no longer binds it, so the record drops it: no rate, no
# projected_wall_minutes, and usage_rate_state `credits`, which no reader of a
# measured rate takes for one. Applied after with_lane_projection, which
# charges burn by the window bucket.
def with_lane_verdict($wall; $max; $credit_floor):
  ($wall | wall_verdict($max)) as $v
  | if $v == "walled" and credit_room($credit_floor)
    then . + {verdict: "room", binding_bucket: "credits", usage_rate_state: "credits",
              usage_rate_pct_per_min: null, projected_wall_minutes: null}
    else . + {verdict: $v} end;

# with_lane_tier($pool; $cloud_floor; $retire; $now) over one judged record
# applies the expires-first rule, `lanes --help` § pick, whose one statement
# that is. It adds the fields of the key, which lane_public drops as they order
# the pick and are no record of it: _tier, _expires (E, 0 outside tier 0) and
# _score (S); and _credit_unread, a measured Claude account of a
# pool=cloud-credit kind whose usage body forms no tier 0 credit to judge.
def with_lane_tier($pool; $cloud_floor; $retire; $now):
  (.credits // {}) as $c
  | ([($c.resets_at | utc_stamp | reset_epoch),
      ($retire[.config_dir] // null | if . == null then null else (. + "T00:00:00Z" | fromdateiso8601) end)]
     | map(select(. != null)) | min) as $e
  | ($c.unit == "usd" and ($c.remaining_dollars | type) == "number" and ($c.limit_dollars | type) == "number"
     and $e != null) as $read
  | . + {_credit_unread: ($pool == "cloud-credit" and ($read | not) and .harness == "claude"
                          and (.status == "ok" or .status == "rate_limited") and .headroom_pct != null)}
  | if $pool == "cloud-credit" and $read and $c.remaining_dollars > $cloud_floor and $c.locked_reason == null
       and $c.limit_dollars > 0 and $e > $now
    then . + {verdict: "room", _tier: 0, _expires: $e,
              _score: (100 * $c.remaining_dollars / $c.limit_dollars * (1 + 1 / (1 + ($e - $now) / 3600)))}
    elif .binding_bucket == "credits" then . + {_tier: 2, _expires: 0, _score: .credits.balance}
    else . + {_tier: 1, _expires: 0, _score: .selection_score} end;

# A cloud-session launch only admits the accounts lane_tier_inputs names for
# the checkout repository. Null leaves every other launch unchanged.
def with_lane_cloud_repo($cloud_repo):
  if $cloud_repo == null or (.config_dir as $d | any($cloud_repo[]; . == $d)) then .
  else . + {verdict: "cloud-repo-unset"} end;

# Partition on the same verdict the named pick reads. The tier key orders the
# room lanes, `lanes --help` § pick; a score cannot buy a launch past the
# projected wall. The counts preserve the distinction between an allowance
# spent and one never measured. A launch=cloud-session pick names in
# $cloud_repo the accounts whose ORCH_LANE_CLOUD_REPOS entry names the
# repository of the checkout, and every other account takes the verdict
# cloud-repo-unset; null for any other launch.
def lane_selection($model; $floor; $burn; $now; $max; $credit_floor; $pool; $cloud_floor; $retire; $cloud_repo):
  def neg: if . == null then null else 0 - . end;
  [ .[] | with_lane_binding($model; $floor) | with_lane_projection($burn; $now)
    | with_lane_selection_score($now)
    | with_lane_verdict(judged_wall; $max; $credit_floor)
    | with_lane_tier($pool; $cloud_floor; $retire; $now)
    | with_lane_cloud_repo($cloud_repo) ]
  | { chosen: ([ .[] | select(.verdict == "room") ]
                | sort_by([._tier, ._expires, (._score | neg), .claims, (.projected_headroom_pct | neg), .wall]) | first
                | if . == null then null
                  else . + {effective_headroom_pct: (if .wall == null then null else 100 - .wall end)}
                  | del(.wall, .verdict) | lane_public end),
      qualifying: ([ .[] | select(.verdict == "room") ] | length),
      walled: ([ .[] | select(.verdict == "walled") ] | length),
      unmeasured: ([ .[] | select(.verdict == "unmeasured") ] | length),
      cloud_repo_unset: [ .[] | select(.verdict == "cloud-repo-unset") | .config_dir ],
      cloud_credit_unread: [ .[] | select(._credit_unread) | .alias ],
      unread: [ .[] | select(.verdict == "unmeasured") ] };
'

# Read lane records on stdin and judge all their reset bonuses at one instant.
# POOL is the kind's declared pool, CLOUD_FLOOR the cloud credit floor in
# dollars, RETIRE a JSON object of config_dir to ORCH_LANE_RETIRE date and
# CLOUD_REPO the JSON array of admitted config dirs, or null.
lane_select() { # MODEL BINDING_FLOOR BURN MAX_PCT CREDIT_FLOOR POOL CLOUD_FLOOR RETIRE CLOUD_REPO
  local now
  now="$(date +%s)" || return 1
  jq -c --arg model "$1" --argjson floor "$2" --argjson burn "$3" \
    --argjson max "$4" --argjson credit_floor "$5" --arg pool "$6" --argjson cloud_floor "$7" \
    --argjson retire "$8" --argjson cloud_repo "$9" --argjson now "$now" "$LANE_MODEL_JQ"'
    lane_selection($model; $floor; $burn; $now; $max; $credit_floor; $pool; $cloud_floor; $retire; $cloud_repo)'
}

# Judge one record by the pick tiers, using the reading or the launch projection.
# The caller loads lane_tier_inputs so it can name the repository on refusal.
lane_judge() { # RECORD MODEL BINDING_FLOOR BURN MAX_PCT PROJECTED CREDIT_FLOOR
  local now
  now="$(date +%s)" || return 1
  jq -c --arg model "$2" --argjson floor "$3" --argjson burn "$4" \
    --argjson max "$5" --argjson projected "$6" --argjson credit_floor "$7" \
    --arg pool "$TIER_POOL" --argjson cloud_floor "$CLOUD_CREDIT_FLOOR" \
    --argjson retire "$TIER_RETIRE" --argjson cloud_repo "$TIER_CLOUD_REPO" --argjson now "$now" "$LANE_MODEL_JQ"'
    with_lane_binding($model; $floor) | with_lane_projection($burn; $now)
    | with_lane_verdict((if $projected then judged_wall else .wall end); $max; $credit_floor)
      | with_lane_tier($pool; $cloud_floor; $retire; $now)
      | with_lane_cloud_repo($cloud_repo)
  ' <<<"$1"
}

# Consult DIR for an unreachable host or a measured Claude row missing MODEL.
# Host credential refusals stay authoritative. A local Claude result for a named
# MODEL that carries model buckets, none of them MODEL's, is judged on the
# shared windows alone: the plan has no window scoped to MODEL. The record
# cannot tell that from a response that omitted MODEL's window, and the shared
# windows are the rule for both. A local result that read nothing or carries
# no model bucket stays unmeasured, whatever the consultation cause.
#
# `headroom_pct` is emit_lane's one word for a lane that measured a figure: it
# is null for every status that carries no reading and for a measured status
# with no window, so this asks no second question about the status. The age
# bound is usage_serve_max_age, the window measure_lane served the figure
# within, under the strict comparison read_usage_cache makes: a figure at or
# past it is one a refused refresh served, which says nothing about the window
# now. A figure 0 seconds old is the one this run's own fetch returned, which
# no window is shorter than: a TTL of 0 serves nothing and fetches every run,
# and that fetch's figure stands.
#
# A Pi root is judged on another rule, because its Copilot pool is one reading
# whichever copy of the seat makes it, and the local record is the
# ORCH_LANE_COPILOT_POOL override, which carries no age. A HOSTROW that reads
# the pool replaces the override; one that reads nothing, whatever its status,
# leaves the override standing where it states a reading, and stands itself,
# with the provider's status and detail, where it states none.
host_row_or_local() { # HARNESS DIR HOSTROW MODEL
	local trigger local_record="" age tmp bound detail
	trigger="$(jq -r --arg h "$1" --arg model "$4" "$LANE_MODEL_JQ"'
		if $h == "pi" then (if .headroom_pct == null then "local" else "host" end)
		elif .status == "unreachable" then "local"
		elif $h == "claude" and $model != "" and (lane_measured or .status == "no_usage_data")
		     and (model_bindings($model) | length) == 0 then "model"
		else "host" end' <<<"$3")" || return 1
	if [[ "$trigger" == host ]]; then
		printf '%s\n' "$3"
		return 0
	fi
	# measure_lane runs in THIS shell, never in a command substitution: the
	# one cold-lane retry per run is USAGE_RETRY_SPENT, which a substitution's
	# subshell would set and discard, so every held lane after a refused one
	# would retry and sleep again. Its one record line goes through a file
	# opened for writing on 7 and reading on 6 and unlinked before the
	# measurement, so a signal in the window leaves nothing behind without a
	# trap of this function's own, which would replace the lock handlers
	# measure_lane arms. 8 and 9 are the usage and credentials locks.
	tmp="$(mktemp)" || return 1
	exec 7>"$tmp" 6<"$tmp" || { rm -f -- "${tmp:?}"; return 1; }
	rm -f -- "${tmp:?}"
	measure_lane "$1" "$2" >&7 || { exec 7>&- 6<&-; return 1; }
	exec 7>&-
	IFS= read -r local_record <&6 || { exec 6<&-; return 1; }
	exec 6<&-
	bound="$(usage_serve_max_age)" || return 1
	age="$(jq -r --arg h "$1" --arg model "$4" --argjson bound "$bound" "$LANE_MODEL_JQ"'
		if .headroom_pct == null then empty
		elif $h == "claude" and $model != "" and ((.model_buckets // []) | length) == 0 then empty
		elif $h == "pi" then "stated"
		elif (.usage_age_s | type) == "number" and (.usage_age_s == 0 or .usage_age_s < $bound)
		then .usage_age_s else empty end' <<<"$local_record")" || return 1
	if [[ "$age" == stated ]]; then
		printf '%s\n' "$local_record"
	elif [[ -n "$age" ]]; then
		if [[ "$trigger" == model ]]; then
			message pick-local-model-reading "$2" "$ORCH_LANE_HOST" "$4" "$age" >&2
		else
			message pick-local-reading "$2" "$ORCH_LANE_HOST" "$age" >&2
		fi
		printf '%s\n' "$local_record"
	elif [[ "$trigger" == model ]]; then
		local_record="$(jq -c --arg model "$4" "$LANE_MODEL_JQ"'
			. + {status: (if lane_measured then "no_usage_data" else .status end),
			     headroom_pct: null, detail: (.detail // ("no fresh local model window for " + $model))}
		' <<<"$local_record")" || return 1
		detail="$(jq -r '.detail' <<<"$local_record")" || return 1
		message pick-local-model-unmeasured "$2" "$4" "$detail" >&2
		printf '%s\n' "$local_record"
	else
		printf '%s\n' "$3"
	fi
}
