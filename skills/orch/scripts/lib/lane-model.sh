# shellcheck shell=bash
#
# The one answer to "what stands between this account and this launch". A lane
# picked on its binding bucket alone can still open on a model the account has
# no allowance left for, and the launch's first turn is a usage banner instead
# of a session.
#
# The jq program below is the whole answer, and `lanes` is its only consumer:
# both of its pick forms — the fleet chooser and the single named lane — read
# `lane_binding` and the `wall_verdict` that classifies it from here, so the two
# cannot come to different conclusions about one account on one usage reading,
# nor can one of them know a verdict the other has no arm for.
#
# Sourced, never run.

# model_binding($model) over one lane record: the bucket with the largest usage
# percentage that stands between this account and a launch on $model, or null
# where the record carries no window that answers. The answer keeps the bucket
# and reset beside the percentage so a refusal can name what made the decision.
#
# The 5-hour session and the plan-wide weekly window wall every model, so both
# always count. A model-scoped weekly window walls only the model its own label
# names, so a launch on another model does not draw on it and it is left out —
# the difference between refusing an account that is free for this launch and
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
  if .bucket == "weekly" then 2
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
    resets_at: (.resets.weekly // null)}];

def model_binding($model):
  ($model | lane_norm) as $m
  | (shared_bindings
     + [ (.model_buckets // [])[]
         | ((.label // "") | lane_norm) as $l
         | select(.label == null
                  or ($l != "" and $m != ""
                      and (($l | contains($m)) or ($m | contains($l)))))
         | {bucket: "model", label: (.label // null), pct: .pct,
            resets_at: (.resets_at // null)} ])
  | max_binding;

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

def with_lane_binding($model; $binding_floor):
  lane_binding($model; $binding_floor) as $binding
  | (if $binding == null then [] elif $binding.bucket == "model" then (._rate_prior.model_buckets // [])
     else [{label: null,
            pct: (if $binding.bucket == "session" then ._rate_prior.session_5h_pct
                  elif $binding.bucket == "weekly" then ._rate_prior.weekly_pct else null end),
            resets_at: ._rate_prior.resets[$binding.bucket]}] end
     | map(select((.label // null) == ($binding.label // null)
                  and .resets_at != null and .resets_at == $binding.resets_at))
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

def lane_public: del(._rate_prior, ._rate_elapsed_s);

# One spelling for every reset a lane record carries: whole-second UTC with a
# Z, the form Codex resets are rendered in. The Claude usage endpoint writes
# fractional seconds and +00:00, and a provider row carries whatever its
# timestamp is; a reader parsing the stamp (the BSD `date` arm cannot read the
# fraction) or comparing two of them by equality, as with_lane_binding does
# with the prior sample, needs one form. emit_lane applies it to the current
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
'
