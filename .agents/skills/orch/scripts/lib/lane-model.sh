# shellcheck shell=bash
#
# The one answer to "which usage bucket walls a launch on THIS model". A lane
# picked on its binding bucket alone can still open on a model the account has
# no allowance left for, and the launch's first turn is a usage banner instead
# of a session. Every launcher that passes a model asks here.
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
'

# lane_model_wall RECORD MODEL — that percentage for one lane record, or the
# word `none` where nothing measured answers for this model.
lane_model_wall() { # RECORD MODEL
  jq -r --arg m "$2" "$LANE_MODEL_JQ"' model_wall($m) // "none"' <<<"$1"
}
