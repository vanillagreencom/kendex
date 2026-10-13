#!/usr/bin/env bash
# The action runs default-branch claiming lanes when a proved render deletes
# or renames their inputs. The real classifiers read synthetic git diffs;
# the verifier double supplies ownership, not the lane decision under test.
set -euo pipefail
# shellcheck source=lib/sandbox.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib/sandbox.sh"

ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
ACTION="$ROOT/.github/actions/change-class/classify"
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
  PATH="$SANDBOX/bin:$PATH" CLASSIFIER="$ROOT" LANES_FROM="$SANDBOX/default" \
    EVENT="$2" BASE="$base" HEAD=HEAD REPO="$repo" \
    GITHUB_OUTPUT="$SANDBOX/output" "$1" \
    >"$SANDBOX/stdout" 2>"$SANDBOX/stderr" || status=$?
  assert_eq "$case: action exits successfully" 0 "$status"
  assert_eq "$case: real classifier proves render" change_class=render \
    "$(sed -n '/^change_class=/p' "$SANDBOX/output")"
}

rows=0
while IFS='|' read -r case event change expected_lanes expected_verdicts; do
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
  esac
  git -C "$repo" add -A
  git -C "$repo" ls-files .agents | jq -Rs 'split("\n")[:-1] + [".kendex-generated.json"] | sort' >"$repo/.kendex-generated.json"
  git -C "$repo" add -A
  git -C "$repo" commit -qm "$case"
  run_action "$SANDBOX/action/classify" "$event"
  assert_eq "$case: lanes" "lanes=$expected_lanes" \
    "$(sed -n '/^lanes=/p' "$SANDBOX/output")"
  verdicts="$(sed -n '/^lane_verdicts<</,/^__change_class_lane_verdicts_end__/{ /^lane_[^<]*=/p; }' "$SANDBOX/output" | tr '\n' ',')"
  assert_eq "$case: default-branch claiming lanes" "$expected_verdicts" "${verdicts%,}"
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
  if [ "$rows" -eq 1 ]; then
    # Restoring the old render skip must turn the first row's true verdicts
    # false. Keep the matched class and claim logic in the disposable copy.
    awk '$0 == "          lanes=true lanes_cause=render-moved-claim" {
      hits++; print "          lanes=false lanes_cause=render"; next
    } { print } END { if (hits != 1) exit 2 }' "$ACTION" >"$SANDBOX/action/control"
    ! cmp -s "$ACTION" "$SANDBOX/action/control" || exit 1
    chmod +x "$SANDBOX/action/control"
    run_action "$SANDBOX/action/control" "$event"
    assert_eq 'must-fail: the old render skip rejects the first row' lanes=false \
      "$(sed -n '/^lanes=/p' "$SANDBOX/output")"
    assert_eq 'must-fail: the old render skip skips a claiming lane' lane_orch=false \
      "$(sed -n '/^lane_orch=/p' "$SANDBOX/output")"
  fi
done <<'ROWS'
rename across skills|pull_request|renamed|true|lane_orch=true,lane_orch-suite=true,lane_mailbox=true,lane_queue=true,lane_other=false
rename in merge group|merge_group|renamed|true|lane_orch=true,lane_orch-suite=true,lane_mailbox=true,lane_queue=true,lane_other=false
delete claimed file|pull_request|deleted|true|lane_orch=true,lane_orch-suite=true,lane_mailbox=false,lane_queue=true,lane_other=false
modify claimed file in place|pull_request|in-place|false|lane_orch=false,lane_orch-suite=false,lane_mailbox=false,lane_queue=false,lane_other=false
rename unclaimed file|pull_request|unclaimed|false|lane_orch=false,lane_orch-suite=false,lane_mailbox=false,lane_queue=false,lane_other=false
rename into claimed directory|pull_request|destination|true|lane_orch=false,lane_orch-suite=false,lane_mailbox=true,lane_queue=false,lane_other=false
ROWS
require_rows render-moved-claims "$rows"
report render-moved-claims
