#!/usr/bin/env bash
# The action runs default-branch claiming lanes for every path a proved
# render changes: in place, added, deleted or at either end of a move. The
# merge group runs them; a pull request or push runs them only where the
# base names HARNESS_CI_PER_PUSH_REASON, since the queue-only default stands
# those events down, and a pull request still defers a `:queue` lane to the
# merge group. The real classifiers read synthetic git diffs; the
# verifier double supplies ownership, not the lane decision under test.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
ACTION="$ROOT/.github/actions/change-class/classify"
DECISION_LIB="$ROOT/skills/harness-ci/scripts/lib/change-class.sh"
# The queue-only stand-down needs the render that reads the opt-back, and the
# `:queue` deferral the render that reads the mark, in both trees a merge can
# run pr-merge from.
READER=.agents/skills/harness-ci/scripts/change-class
QUEUE_READER=.agents/skills/harness-ci/scripts/lib/ci-lanes.sh
mkdir -p "$SANDBOX/control/skills"
cp -R "$ROOT/skills/harness-ci" "$SANDBOX/control/skills/"
cp -R "$ROOT/skills/orch" "$SANDBOX/control/skills/"
mkdir -p "$SANDBOX/action" "$SANDBOX/bin" "$SANDBOX/default/.github" "$SANDBOX/default/$(dirname "$READER")" "$SANDBOX/default/$(dirname "$QUEUE_READER")"
cp "$ACTION" "$SANDBOX/action/classify"
cp "$CHANGE_CLASS" "$SANDBOX/default/$READER"
cp "$ROOT/skills/harness-ci/scripts/lib/ci-lanes.sh" "$SANDBOX/default/$QUEUE_READER"
cat >"$SANDBOX/bin/kendex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  --version) printf 'kendex 0.0.0-stub\n' ;;
  'verify --help') printf '%s\n' '  --bot-instructions-from <DIR>' ;;
  *) cat -- "$RENDER_DOCUMENT" ;;
esac
STUB
chmod +x "$SANDBOX/bin/kendex"
export RENDER_DOCUMENT="$SANDBOX/document.json"
cat >"$RENDER_DOCUMENT" <<'JSON'
{"version":1,"clean":true,"checked":4,"failed":0,"base_owned":[{"path":".agents/skills/orch","owns":"tree"},{"path":".agents/spare","owns":"tree"}],"rows":[{"kind":"skill","name":"orch","state":"ok","positions":[{"path":".agents/skills/orch","owns":"tree"}]},{"kind":"skill","name":"mailbox","state":"ok","positions":[{"path":".agents/skills/mailbox","owns":"tree"}]},{"kind":"skill","name":"spare","state":"ok","positions":[{"path":".agents/spare","owns":"tree"}]},{"kind":"inventory","state":"ok","positions":[{"path":".kendex-generated.json","owns":"file"}]}]}
JSON
# `skills` is a consumer test lane claiming every rendered skill; `spare`
# renders outside it, so its changes reach no lane.
cat >"$SANDBOX/default/.github/ci-lanes.conf" <<'LANES'
orch .agents/skills/orch/scripts/lib/*
orch-suite .agents/skills/orch/scripts/lib/*
mailbox .agents/skills/mailbox/scripts/lib/*
queue:queue .agents/skills/orch/scripts/lib/*
skills .agents/skills/*
other .agents/skills/other/*
LANES

repo="$(new_repo render-claims)"
old=.agents/skills/orch/scripts/lib/lane-mail-store.py
new=.agents/skills/mailbox/scripts/lib/lane-mail-store.py
spare=.agents/spare/original.py
moved_spare=.agents/spare/renamed.py
forwarder=.agents/skills/orch/scripts/lane-mail
commit_paths "$repo" baseline "$old" "$spare" "$forwarder"
mkdir -p "$repo/$(dirname "$READER")" "$repo/$(dirname "$QUEUE_READER")" "$repo/.github"
cp "$CHANGE_CLASS" "$repo/$READER"
cp "$ROOT/skills/harness-ci/scripts/lib/ci-lanes.sh" "$repo/$QUEUE_READER"
# change-class reads the `:queue` mark from the base commit's declaration.
cp "$SANDBOX/default/.github/ci-lanes.conf" "$repo/.github/ci-lanes.conf"
write_agents_inventory() {
  git -C "$repo" ls-files .agents | jq -Rs 'split("\n")[:-1] + [".kendex-generated.json"] | sort' >"$repo/.kendex-generated.json"
}
git -C "$repo" add -A
write_agents_inventory
git -C "$repo" add -A
git -C "$repo" commit -qm inventory
# One base per state of the opt-back: `default` names no reason, so the
# queue-only default applies; `optback` runs lanes on every pull-request push.
base_default="$(git -C "$repo" rev-parse HEAD)"
printf '[env]\nHARNESS_CI_PER_PUSH_REASON = "render rule suite"\nHARNESS_CI_QUEUE_PATHS = ""\n' >"$repo/kendex.settings.toml"
git -C "$repo" add -A
git -C "$repo" commit -qm optback
base_optback="$(git -C "$repo" rev-parse HEAD)"

run_action() { # SCRIPT EVENT [CLASSIFIER]
  local status=0
  : >"$SANDBOX/output"
  PATH="$SANDBOX/bin:$PATH" CLASSIFIER="${3:-$ROOT}" LANES_FROM="$SANDBOX/default" \
    QUEUE_ONLY_DEFAULT=true EVENT="$2" BASE="$base" HEAD=HEAD REPO="$repo" \
    GITHUB_OUTPUT="$SANDBOX/output" "$1" \
    >"$SANDBOX/stdout" 2>"$SANDBOX/stderr" || status=$?
  assert_eq "$case: action exits successfully" 0 "$status"
  assert_eq "$case: real classifier proves render" change_class=render \
    "$(sed -n '/^change_class=/p' "$SANDBOX/output")"
}

# ROW|EVENT|BASE|CHANGE|LANES|LANES_CAUSE|VERDICTS|SKILLS_HIT|CONTROL|CONTROL_LANE|CONTROL_EXPECTED
# SKILLS_HIT is the changed path the `skills` lane's cause names, `-` where
# that lane stays false.
rows=0
while IFS='|' read -r case event base_name change expected_lanes expected_cause expected_verdicts skills_hit control control_lane control_expected; do
  rows=$((rows + 1))
  base_var="base_$base_name"
  base="${!base_var}"
  git -C "$repo" checkout -q -B row "$base"
  git -C "$repo" clean -qfd
  mkdir -p "$repo/$(dirname "$new")"
  case "$change" in
    renamed)
      git -C "$repo" mv "$old" "$new"
      printf 'forward to mailbox\n' >"$repo/$forwarder" ;;
    deleted) git -C "$repo" rm -q -- "$old" ;;
    in-place) printf 'updated implementation\n' >>"$repo/$old" ;;
    unclaimed-in-place) printf 'updated implementation\n' >>"$repo/$spare" ;;
    unclaimed) git -C "$repo" mv "$spare" "$moved_spare" ;;
    destination) git -C "$repo" mv "$spare" "$new" ;;
    addition) printf 'replacement implementation\n' >"$repo/$new" ;;
  esac
  git -C "$repo" add -A
  write_agents_inventory
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$case"
  run_action "$SANDBOX/action/classify" "$event"
  assert_eq "$case: lanes" "$(printf 'lanes=%s\nlanes_cause=%s' "$expected_lanes" "$expected_cause")" \
    "$(sed -n '/^lanes=/p; /^lanes_cause=/p' "$SANDBOX/output")"
  verdicts="$(sed -n '/^lane_verdicts<</,/^__change_class_lane_verdicts_end__/{ /^lane_[^<]*=/p; }' "$SANDBOX/output" | tr '\n' ',')"
  assert_eq "$case: default-branch claiming lanes" "$expected_verdicts" "${verdicts%,}"
  PATH="$SANDBOX/bin:$PATH" "$CHANGE_CLASS" --event "$event" --base "$base" \
    --head HEAD --repo "$repo" --lanes-from "$SANDBOX/default" --queue-only-default true \
    --output "$SANDBOX/local-output" >"$SANDBOX/local-stdout" 2>"$SANDBOX/local-stderr"
  assert_eq "$case: local lanes match the action" \
    "$(sed -n '/^lanes=/p; /^lanes_cause=/p' "$SANDBOX/output")" \
    "$(sed -n '/^lanes=/p; /^lanes_cause=/p' "$SANDBOX/local-output")"
  rm "${SANDBOX:?}/local-output"
  if [ "$expected_cause" = render-claim ]; then
    for lane in orch orch-suite mailbox queue skills; do
      case ",$expected_verdicts," in
        *",lane_$lane=true,"*)
          case "$lane" in
            mailbox) path="$new" glob='.agents/skills/mailbox/scripts/lib/*' ;;
            skills) path="$skills_hit" glob='.agents/skills/*' ;;
            *) path="$old" glob='.agents/skills/orch/scripts/lib/*' ;;
          esac
          assert_eq "$case: $lane cause and claim" \
            "lane: name=$lane verdict=true cause=render-claim path=$path glob=$glob" \
            "$(sed -n "/^lane: name=$lane /p" "$SANDBOX/stderr")" ;;
      esac
    done
    case ",$expected_verdicts," in
      *",lane_orch=true,"*",lane_queue=false,"*)
        assert_eq "$case: queue lane defers to the merge group" \
          "lane: name=queue verdict=false cause=queue-deferred path=$old glob=.agents/skills/orch/scripts/lib/*" \
          "$(sed -n '/^lane: name=queue /p' "$SANDBOX/stderr")" ;;
    esac
  fi
  if [ -n "$control" ]; then
    case "$control" in
      claim-skip)
        needle='        lanes=true lanes_cause=render-claim'
        replacement='        lanes=false lanes_cause=render' ;;
      moved-only)
        needle='    --name-only -z --no-renames "$render_base" "$render_head" -- \'
        replacement='    --name-only -z --no-renames --diff-filter=AD "$render_base" "$render_head" -- \' ;;
      render-undeferred)
        needle='  elif [ "$EVENT" = pull_request ] && [ "${lane_queue[$index]}" = true ] && [ -n "$hit" ]; then'
        replacement='  elif [ "$class" != render ] && [ "$EVENT" = pull_request ] && [ "${lane_queue[$index]}" = true ] && [ -n "$hit" ]; then' ;;
      similarity-on)
        needle='    --name-only -z --no-renames "$render_base" "$render_head" -- \'
        replacement='    --name-only -z --find-renames "$render_base" "$render_head" -- \' ;;
    esac
    NEEDLE="$needle" REPLACEMENT="$replacement" awk '$0 == ENVIRON["NEEDLE"] {
      hits++; print ENVIRON["REPLACEMENT"]; next
    } { print } END { if (hits != 1) exit 2 }' "$DECISION_LIB" >"$SANDBOX/control/skills/harness-ci/scripts/lib/change-class.sh"
    ! cmp -s "$DECISION_LIB" "$SANDBOX/control/skills/harness-ci/scripts/lib/change-class.sh" || exit 1
    run_action "$SANDBOX/action/classify" "$event" "$SANDBOX/control"
    assert_eq "must-fail: $case changes its claiming lane under $control" "lane_$control_lane=$control_expected" \
      "$(sed -n "/^lane_$control_lane=/p" "$SANDBOX/output")"
  fi
done <<ROWS
modify claimed file in place in merge group|merge_group|default|in-place|true|render-claim|lane_orch=true,lane_orch-suite=true,lane_mailbox=false,lane_queue=true,lane_skills=true,lane_other=false|$old|moved-only|skills|false
modify claimed file in place, opted back|pull_request|optback|in-place|true|render-claim|lane_orch=true,lane_orch-suite=true,lane_mailbox=false,lane_queue=false,lane_skills=true,lane_other=false|$old|render-undeferred|queue|true
modify claimed file in place, push opted back|push|optback|in-place|true|render-claim|lane_orch=true,lane_orch-suite=true,lane_mailbox=false,lane_queue=true,lane_skills=true,lane_other=false|$old
modify claimed file in place, queue-only default|pull_request|default|in-place|false|queue-only|lane_orch=false,lane_orch-suite=false,lane_mailbox=false,lane_queue=false,lane_skills=false,lane_other=false|-
modify claimed file in place, push under the default|push|default|in-place|false|queue-only|lane_orch=false,lane_orch-suite=false,lane_mailbox=false,lane_queue=false,lane_skills=false,lane_other=false|-
modify unclaimed file in place in merge group|merge_group|default|unclaimed-in-place|false|render|lane_orch=false,lane_orch-suite=false,lane_mailbox=false,lane_queue=false,lane_skills=false,lane_other=false|-
modify unclaimed file in place, opted back|pull_request|optback|unclaimed-in-place|false|render|lane_orch=false,lane_orch-suite=false,lane_mailbox=false,lane_queue=false,lane_skills=false,lane_other=false|-
modify unclaimed file in place, push opted back|push|optback|unclaimed-in-place|false|render|lane_orch=false,lane_orch-suite=false,lane_mailbox=false,lane_queue=false,lane_skills=false,lane_other=false|-
rename across skills|pull_request|optback|renamed|true|render-claim|lane_orch=true,lane_orch-suite=true,lane_mailbox=true,lane_queue=false,lane_skills=true,lane_other=false|$new|similarity-on|orch|false
rename in merge group|merge_group|optback|renamed|true|render-claim|lane_orch=true,lane_orch-suite=true,lane_mailbox=true,lane_queue=true,lane_skills=true,lane_other=false|$new
delete claimed file|pull_request|optback|deleted|true|render-claim|lane_orch=true,lane_orch-suite=true,lane_mailbox=false,lane_queue=false,lane_skills=true,lane_other=false|$old|claim-skip|orch|false
rename unclaimed file|pull_request|optback|unclaimed|false|render|lane_orch=false,lane_orch-suite=false,lane_mailbox=false,lane_queue=false,lane_skills=false,lane_other=false|-
rename into claimed directory|pull_request|optback|destination|true|render-claim|lane_orch=false,lane_orch-suite=false,lane_mailbox=true,lane_queue=false,lane_skills=true,lane_other=false|$new
addition into claimed directory|pull_request|optback|addition|true|render-claim|lane_orch=false,lane_orch-suite=false,lane_mailbox=true,lane_queue=false,lane_skills=true,lane_other=false|$new
ROWS
require_rows render-claims "$rows"
report render-claims
