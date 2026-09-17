# shellcheck shell=bash
#
# The one answer to "what stands between this account and this launch". A lane
# picked on its binding bucket alone can still open on a model the account has
# no allowance left for, and the launch's first turn is a usage banner instead
# of a session.
#
# The jq program below is the whole answer, and `lanes` is its only consumer:
# both of its pick forms — the fleet chooser and the single named lane — read
# `lane_wall` from here, so the two cannot come to different conclusions about
# one account on one usage reading.
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
# The label match is containment in either direction, case-folded: an API label
# carries a version the caller's model id does not (`Fable 5.1` for `fable`),
# and a fully-spelled id carries a vendor and a generation the label does not
# (`claude-opus-5` for `Opus`). An empty label or model name matches nothing,
# since containment in an empty string is true of every string.
#
# A window with NO label counts for every model. The API omitted the name, so
# nothing says which model it is scoped to, and a window that might wall this
# launch is not evidence the launch is free. Skipping it would make naming a
# model more permissive than naming none: `pick` with no model still refuses
# such an account through its binding bucket.
#
# A record whose windows answer nothing yields null, which every caller must
# read as "not measured" and never as "free": `lanes pick` drops such a lane.
#
# No apostrophe ANYWHERE in the program below: it is one single-quoted shell
# word from the opening quote to the closing one, so an apostrophe at any depth
# ends the string there and hands jq a fragment.
# shellcheck disable=SC2016  # a jq program, expanded by jq and never by the shell.
LANE_MODEL_JQ='
def model_wall($model):
  ($model | ascii_downcase) as $m
  | ([.session_5h_pct, .weekly_pct]
     + [ (.model_buckets // [])[]
         | (.label // "" | ascii_downcase) as $l
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
def lane_wall($model):
  if .status != "ok" then null
  elif $model != "" then model_wall($model)
  elif .headroom_pct == null then null
  else 100 - .headroom_pct
  end;
'
