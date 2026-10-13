#!/usr/bin/env bash
# The action runs default-branch claiming lanes when a proved render deletes
# or renames their inputs. The real classifiers read synthetic git diffs;
# the verifier double supplies ownership, not the lane decision under test.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
ACTION="$ROOT/.github/actions/change-class/classify"
DECISION_LIB="$ROOT/skills/harness-ci/scripts/lib/change-class.sh"
mkdir -p "$SANDBOX/control/skills"
cp -R "$ROOT/skills/harness-ci" "$SANDBOX/control/skills/"
cp -R "$ROOT/skills/orch" "$SANDBOX/control/skills/"
mkdir -p "$SANDBOX/action" "$SANDBOX/bin" "$SANDBOX/default/.github"
cp "$ACTION" "$SANDBOX/action/classify"
cat >"$SANDBOX/action/proof" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
printf 'reuse=false\nreason=ineligible-event\n'
STUB
cat >"$SANDBOX/bin/kendex" <<'STUB'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  --version) printf 'kendex 0.0.0-stub\n' ;;
  'verify --help') printf '%s\n' '  --bot-instructions-from <DIR>' ;;
  *) cat -- "$RENDER_DOCUMENT" ;;
esac
STUB
chmod +x "$SANDBOX/action/proof" "$SANDBOX/bin/kendex"
export RENDER_DOCUMENT="$SANDBOX/document.json"
cat >"$RENDER_DOCUMENT" <<'JSON'
{"version":1,"clean":true,"checked":4,"failed":0,"base_owned":[{"path":".agents/skills/orch","owns":"tree"},{"path":".agents/skills/spare","owns":"tree"}],"rows":[{"kind":"skill","name":"orch","state":"ok","positions":[{"path":".agents/skills/orch","owns":"tree"}]},{"kind":"skill","name":"mailbox","state":"ok","positions":[{"path":".agents/skills/mailbox","owns":"tree"}]},{"kind":"skill","name":"spare","state":"ok","positions":[{"path":".agents/skills/spare","owns":"tree"}]},{"kind":"inventory","state":"ok","positions":[{"path":".kendex-generated.json","owns":"file"}]}]}
JSON
cat >"$SANDBOX/default/.github/ci-lanes.conf" <<'LANES'
orch .agents/skills/orch/scripts/lib/*
orch-suite .agents/skills/orch/scripts/lib/*
mailbox .agents/skills/mailbox/scripts/lib/*
queue:queue .agents/skills/orch/scripts/lib/*
other .agents/skills/other/*
LANES

repo="$(new_repo render-moved)"
old=.agents/skills/orch/scripts/lib/lane-mail-store.py
new=.agents/skills/mailbox/scripts/lib/lane-mail-store.py
spare=.agents/skills/spare/original.py
forwarder=.agents/skills/orch/scripts/lane-mail
commit_paths "$repo" baseline "$old" "$spare" "$forwarder"
printf '%s\n' "$old" "$spare" "$forwarder" .kendex-generated.json | jq -Rs 'split("\n")[:-1] | sort' >"$repo/.kendex-generated.json"
git -C "$repo" add -A
git -C "$repo" commit -qm inventory
base="$(git -C "$repo" rev-parse HEAD)"

run_action() { # SCRIPT EVENT
  local status=0
  : >"$SANDBOX/output"
  PATH="$SANDBOX/bin:$PATH" CLASSIFIER="${3:-$ROOT}" LANES_FROM="$SANDBOX/default" \
    EVENT="$2" BASE="$base" HEAD=HEAD REPO="$repo" \
    GITHUB_OUTPUT="$SANDBOX/output" "$1" \
    >"$SANDBOX/stdout" 2>"$SANDBOX/stderr" || status=$?
  assert_eq "$case: action exits successfully" 0 "$status"
  assert_eq "$case: real classifier proves render" change_class=render \
    "$(sed -n '/^change_class=/p' "$SANDBOX/output")"
}

rows=0
while IFS='|' read -r case event change expected_lanes expected_verdicts control control_lane control_expected; do
  rows=$((rows + 1))
  git -C "$repo" checkout -q -B row "$base"
  git -C "$repo" clean -qfd
  mkdir -p "$repo/$(dirname "$new")"
  case "$change" in
    renamed)
      git -C "$repo" mv "$old" "$new"
      printf 'forward to mailbox\n' >"$repo/$forwarder" ;;
    deleted) git -C "$repo" rm -q -- "$old" ;;
    in-place) printf 'updated implementation\n' >>"$repo/$old" ;;
    unclaimed) git -C "$repo" mv "$spare" .agents/skills/spare/renamed.py ;;
    destination) git -C "$repo" mv "$spare" "$new" ;;
    rewritten)
      git -C "$repo" mv "$spare" "$new"
      printf 'replacement implementation\n' >"$repo/$new" ;;
    addition) printf 'replacement implementation\n' >"$repo/$new" ;;
    paired-addition)
      git -C "$repo" mv "$old" .agents/skills/spare/renamed.py
      printf 'replacement implementation\n' >"$repo/$new" ;;
    legacy-copy)
      cp "$repo/$spare" "$repo/.agents/skills/spare/renamed.py"
      git -C "$repo" mv "$spare" "$new"
      printf 'replacement implementation\n' >"$repo/$new" ;;
    unclaimed-rewritten)
      git -C "$repo" mv "$spare" .agents/skills/spare/renamed.py
      printf 'replacement implementation\n' >"$repo/.agents/skills/spare/renamed.py" ;;
  esac
  git -C "$repo" add -A
  git -C "$repo" ls-files .agents | jq -Rs 'split("\n")[:-1] + [".kendex-generated.json"] | sort' >"$repo/.kendex-generated.json"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$case"
  if [ "$change" = rewritten ]; then
    git_statuses="$(git -C "$repo" diff --name-status --find-renames --diff-filter=ADR "$base" HEAD)" || exit 1
    assert_eq "$case: Git reports deletion plus addition" "$(printf 'A\t%s\nD\t%s' "$new" "$spare")" \
      "$git_statuses"
  elif [ "$change" = legacy-copy ]; then
    git_statuses="$(git -C "$repo" diff --name-status --find-renames --diff-filter=ADR "$base" HEAD)" || exit 1
    assert_eq "$case: similarity pairs the deleted path with its copy" \
      "$(printf 'A\t%s\nR100\t%s\t%s' "$new" "$spare" .agents/skills/spare/renamed.py)" "$git_statuses"
  fi
  run_action "$SANDBOX/action/classify" "$event"
  assert_eq "$case: lanes" "lanes=$expected_lanes" \
    "$(sed -n '/^lanes=/p' "$SANDBOX/output")"
  verdicts="$(sed -n '/^lane_verdicts<</,/^__change_class_lane_verdicts_end__/{ /^lane_[^<]*=/p; }' "$SANDBOX/output" | tr '\n' ',')"
  assert_eq "$case: default-branch claiming lanes" "$expected_verdicts" "${verdicts%,}"
  PATH="$SANDBOX/bin:$PATH" "$CHANGE_CLASS" --event "$event" --base "$base" \
    --head HEAD --repo "$repo" --lanes-from "$SANDBOX/default" \
    --output "$SANDBOX/local-output" >"$SANDBOX/local-stdout" 2>"$SANDBOX/local-stderr"
  assert_eq "$case: local lanes match the action" \
    "$(sed -n '/^lanes=/p; /^lanes_cause=/p' "$SANDBOX/output")" \
    "$(sed -n '/^lanes=/p; /^lanes_cause=/p' "$SANDBOX/local-output")"
  rm "${SANDBOX:?}/local-output"
  if [ "$expected_lanes" = true ]; then
    assert_eq "$case: lanes cause" lanes_cause=render-moved-claim \
      "$(sed -n '/^lanes_cause=/p' "$SANDBOX/output")"
    for lane in orch orch-suite mailbox queue; do
      case ",$expected_verdicts," in
        *",lane_$lane=true,"*)
          path="$old" glob='.agents/skills/orch/scripts/lib/*'
          [ "$lane" != mailbox ] || { path="$new"; glob='.agents/skills/mailbox/scripts/lib/*'; }
          assert_eq "$case: $lane cause and claim" \
            "lane: name=$lane verdict=true cause=render-moved-claim path=$path glob=$glob" \
            "$(sed -n "/^lane: name=$lane /p" "$SANDBOX/stderr")" ;;
      esac
    done
  fi
  if [ -n "$control" ]; then
    case "$control" in
      old-skip)
        needle='        lanes=true lanes_cause=render-moved-claim'
        replacement='        lanes=false lanes_cause=render' ;;
      candidate-off)
        needle='  if [ "$has_deletions" = true ]; then'
        replacement='  if false; then' ;;
      candidate-on)
        needle='  if [ "$has_deletions" = true ]; then'
        replacement='  if true; then' ;;
      similarity-on)
        needle='    --name-status -z --no-renames --diff-filter=AD "$render_base" "$render_head" -- \'
        replacement='    --name-status -z --find-renames --diff-filter=AD "$render_base" "$render_head" -- \' ;;
    esac
    NEEDLE="$needle" REPLACEMENT="$replacement" awk '$0 == ENVIRON["NEEDLE"] {
      hits++; print ENVIRON["REPLACEMENT"]; next
    } { print } END { if (hits != 1) exit 2 }' "$DECISION_LIB" >"$SANDBOX/control/skills/harness-ci/scripts/lib/change-class.sh"
    ! cmp -s "$DECISION_LIB" "$SANDBOX/control/skills/harness-ci/scripts/lib/change-class.sh" || exit 1
    run_action "$SANDBOX/action/classify" "$event" "$SANDBOX/control"
    assert_eq "must-fail: $case changes its claiming lane under $control" "lane_$control_lane=$control_expected" \
      "$(sed -n "/^lane_$control_lane=/p" "$SANDBOX/output")"
  fi
done <<'ROWS'
rename across skills|pull_request|renamed|true|lane_orch=true,lane_orch-suite=true,lane_mailbox=true,lane_queue=true,lane_other=false|old-skip|orch|false
rename in merge group|merge_group|renamed|true|lane_orch=true,lane_orch-suite=true,lane_mailbox=true,lane_queue=true,lane_other=false
delete claimed file|pull_request|deleted|true|lane_orch=true,lane_orch-suite=true,lane_mailbox=false,lane_queue=true,lane_other=false
modify claimed file in place|pull_request|in-place|false|lane_orch=false,lane_orch-suite=false,lane_mailbox=false,lane_queue=false,lane_other=false
rename unclaimed file|pull_request|unclaimed|false|lane_orch=false,lane_orch-suite=false,lane_mailbox=false,lane_queue=false,lane_other=false
rename into claimed directory|pull_request|destination|true|lane_orch=false,lane_orch-suite=false,lane_mailbox=true,lane_queue=false,lane_other=false
rewritten move into claimed directory|pull_request|rewritten|true|lane_orch=false,lane_orch-suite=false,lane_mailbox=true,lane_queue=false,lane_other=false|candidate-off|mailbox|false
rewritten move in merge group|merge_group|rewritten|true|lane_orch=false,lane_orch-suite=false,lane_mailbox=true,lane_queue=false,lane_other=false
addition into claimed directory|pull_request|addition|false|lane_orch=false,lane_orch-suite=false,lane_mailbox=false,lane_queue=false,lane_other=false|candidate-on|mailbox|true
addition beside a move|pull_request|paired-addition|true|lane_orch=true,lane_orch-suite=true,lane_mailbox=true,lane_queue=true,lane_other=false
rewritten unclaimed move|pull_request|unclaimed-rewritten|false|lane_orch=false,lane_orch-suite=false,lane_mailbox=false,lane_queue=false,lane_other=false
rewritten move with a retained copy|pull_request|legacy-copy|true|lane_orch=false,lane_orch-suite=false,lane_mailbox=true,lane_queue=false,lane_other=false|similarity-on|mailbox|false
retained copy in merge group|merge_group|legacy-copy|true|lane_orch=false,lane_orch-suite=false,lane_mailbox=true,lane_queue=false,lane_other=false
ROWS
require_rows render-moved-claims "$rows"
report render-moved-claims
