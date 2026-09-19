# shellcheck shell=bash
#
# The one answer to "what stands between this account and this launch". A lane
# picked on its binding bucket alone can still open on a model the account has
# no allowance left for, and the launch's first turn is a usage banner instead
# of a session.
#
# The jq program below is the whole answer, and `lanes` is its only consumer:
# both of its pick forms — the fleet chooser and the single named lane — read
# `lane_wall` and the `wall_verdict` that classifies it from here, so the two
# cannot come to different conclusions about one account on one usage reading,
# nor can one of them know a verdict the other has no arm for.
#
# Sourced, never run.

# model_wall($model) over one lane record: the largest usage percentage that
# stands between this account and a launch on $model, or null where the record
# carries no window that answers.
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

def model_wall($model):
  ($model | lane_norm) as $m
  | ([.session_5h_pct, .weekly_pct]
     + [ (.model_buckets // [])[]
         | ((.label // "") | lane_norm) as $l
         | select(.label == null
                  or ($l != "" and $m != ""
                      and (($l | contains($m)) or ($m | contains($l)))))
         | .pct ])
    | map(select(. != null))
    | if length == 0 then null else max end;

# lane_wall($model) over one lane record: the whole judgement, as one number
# or null. Null is "nothing measured this", which every caller refuses on and
# none may read as room; a number is what a caller compares to its threshold.
#
# A record whose usage could not be read answers null whatever its other fields
# say: a window nobody read is not an empty one. With no model named, the
# binding bucket decides as it always did, through the headroom the record
# already carries.
def binding_wall:
  if .status != "ok" or .headroom_pct == null then null
  else 100 - .headroom_pct
  end;

def lane_wall($model):
  if .status != "ok" then null
  elif $model != "" then model_wall($model)
  else binding_wall
  end;

# lane_wall($model; $binding_floor) — the same judgement with the account own
# binding bucket held to the threshold as well, as one number so wall_verdict
# below stays the only place a state is named.
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
# The two bounds are ONE number: the caller passes a single threshold and both
# walls are judged against it, so they cannot drift apart.
#
# Null still wins over any number, in either wall. An unmeasured binding bucket
# beside a measured model wall is a window nobody read, and this file never
# lets that read as room.
def lane_wall($model; $binding_floor):
  lane_wall($model) as $w
  | if $binding_floor != true then $w
    elif $w == null then null
    else (binding_wall as $b | if $b == null then null else ([$w, $b] | max) end)
    end;

# wall_verdict($max) over ONE wall value, the output of lane_wall above: the
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
