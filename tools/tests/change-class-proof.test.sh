#!/usr/bin/env bash
# `.github/actions/change-class/proof` decides whether a passing run of the
# same workflow already tested the tree this run tests. One truth table over
# (event, the run's own fields, the GitHub API's answers) -> the decision, the
# reason key beside it, the run it names and how many gh calls it made. The
# call count is what tells "refused before touching the API" from an ordinary
# refusal; nothing else in the output can.
#
# Three surfaces:
#   1. the table: the accepted rows, a push by the queue and a merge group
#      whose tree its pull request's run tested, its head squashed onto the
#      base or merged, and every refusal, each an accepted row with one thing
#      changed, so a refusal is attributable to that change alone. Every row
#      with no API call runs against a gh that fails every call.
#   2. the record: the accepted row's record is the file the artifact holds,
#      each event's calls come in order, and a newer record whose run failed
#      is passed over for an older one whose run passed.
#   3. the must-fail inverses: one copy of proof per rule, that rule planted
#      away, answers the row the rule decides other than the table says.
set -euo pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT="$(git rev-parse --show-toplevel)"
PROOF="$ROOT/.github/actions/change-class/proof"

mkdir -p "$ROOT/tmp"
TMP="$(mktemp -d)" || { echo "suite: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP && ! -L $TMP ]] || { echo "suite: scratch=not-a-directory" >&2; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)" || { echo "suite: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }
check() { # DESC EXPECTED ACTUAL
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1 (expected '$2', got '$3')"; fi
}

# --- The judged checkout ------------------------------------------------------
# main at B, a pull request head P, and M the merge of P onto B: the commit
# the pull request's run tests. A squashing queue's group head S is one
# commit on B carrying M's tree, and the sha the queue then pushes to main;
# a merging queue's group head is M itself.
REPO="$TMP/repo"
git init -q "$REPO"
git -C "$REPO" config user.email t@example.com
git -C "$REPO" config user.name t
git -C "$REPO" config commit.gpgsign false
mkdir -p "$REPO/.github/workflows" "$REPO/tools"
printf 'workflow\n' >"$REPO/.github/workflows/ci.yml"
printf 'selector\n' >"$REPO/tools/ci-job-set"
printf 'a\n' >"$REPO/a"
git -C "$REPO" add -A
git -C "$REPO" commit -q -m base
B="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q -b topic
printf 'b\n' >"$REPO/b"
git -C "$REPO" add b
git -C "$REPO" commit -q -m topic
P="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" checkout -q -
git -C "$REPO" merge -q --no-ff -m merge topic
M="$(git -C "$REPO" rev-parse HEAD)"
TREE="$(git -C "$REPO" rev-parse "$M^{tree}")"
S="$(git -C "$REPO" commit-tree -p "$B" -m squash "$TREE")"
OTHER_TREE="$(git -C "$REPO" rev-parse "$B^{tree}")"
[ "$(git -C "$REPO" rev-list --parents -n 1 "$S")" = "$S $B" ] ||
  { echo "the squashed group head is not one commit on the base" >&2; exit 1; }

REPO_NAME=vanillagreencom/kendex
WORKFLOW=.github/workflows/ci.yml
WORKFLOW_ID=245303662
RUN_MG=29457108504
RUN_PR=29457108600
RUN_PR_FAILED=29457108500
ARTIFACT=770001
ARTIFACT_FAILED=770000
PR=261
QUEUE_REF="refs/heads/gh-readonly-queue/main/pr-$PR-$B"

# --- Event payloads -----------------------------------------------------------
payload() { # NAME JSON
  printf '%s\n' "$2" >"$TMP/event-$1.json"
}
payload push "{\"ref\":\"refs/heads/main\",\"forced\":false,\"after\":\"$S\",\"repository\":{\"default_branch\":\"main\"}}"
payload push-forced "{\"ref\":\"refs/heads/main\",\"forced\":true,\"after\":\"$S\",\"repository\":{\"default_branch\":\"main\"}}"
payload push-other-after "{\"ref\":\"refs/heads/main\",\"forced\":false,\"after\":\"$B\",\"repository\":{\"default_branch\":\"main\"}}"
payload push-no-default "{\"ref\":\"refs/heads/main\",\"forced\":false,\"after\":\"$S\",\"repository\":{}}"
payload merge_group '{"repository":{"default_branch":"main"}}'

# --- The records the artifact zips hold ---------------------------------------
record_zip() { # NAME MEMBER CONTENT
  python3 - "$TMP/$1.zip" "$2" "$3" <<'PY'
import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr(sys.argv[2], sys.argv[3])
PY
}
RECORD="tree=$TREE
workflow=$WORKFLOW
event=pull_request
change_class=small
docs_only=false
covers=all
changed_path=src/main.rs"
record_zip valid record "$RECORD"
record_zip wrong-tree record "tree=$OTHER_TREE
workflow=$WORKFLOW
covers=all"
record_zip wrong-workflow record "tree=$TREE
workflow=.github/workflows/other.yml
covers=all"
# The member an upload of the record file itself, rather than of the
# directory holding it, would carry.
record_zip wrong-member change-class-record "$RECORD"
printf 'not a zip\n' >"$TMP/garbage.zip"

# A base move changes the integrated tree but leaves the queued patch intact.
git -C "$REPO" checkout -q --detach "$B"
printf 'main move\n' >"$REPO/main-only"
git -C "$REPO" add main-only
git -C "$REPO" commit -q -m advance
B2="$(git -C "$REPO" rev-parse HEAD)"
git -C "$REPO" cherry-pick "$P" >/dev/null
S2="$(git -C "$REPO" rev-parse HEAD)"
PATCH="$(git -C "$REPO" diff --binary "$B" "$S" -- | git patch-id --stable)"
PATCH="${PATCH%% *}"
CONTRACT="$( { git -C "$REPO" rev-parse "$S:$WORKFLOW"; git -C "$REPO" rev-parse "$S:tools/ci-job-set"; } | git hash-object --stdin)"
record_zip patch record "$RECORD
patch_id=$PATCH
macos_patch=true
macos_contract=$CONTRACT"
record_zip wrong-patch record "$RECORD
patch_id=0000000000000000000000000000000000000000
macos_patch=true
macos_contract=$CONTRACT"
record_zip no-macos record "$RECORD
patch_id=$PATCH
macos_contract=$CONTRACT"
record_zip wrong-contract record "$RECORD
patch_id=$PATCH
macos_patch=true
macos_contract=old"
record_zip wrong-patch-event record "tree=$TREE
workflow=$WORKFLOW
event=merge_group
patch_id=$PATCH
macos_patch=true
macos_contract=$CONTRACT"

# --- The fake gh --------------------------------------------------------------
# It records EVERY invocation before deciding how to answer, api-error
# included: a log written only on the success path could not tell "the script
# never called gh" from "the script called gh and gh refused", which is the
# whole claim the no-call rows make. FAKE_GH_MODE picks the one thing wrong
# with the answer; FAKE_ZIP names the zip the download streams.
#
# The runs it knows: the merge_group run for S, and the pull request's
# passing run and an older failed one, both at P, both naming pull request
# PR at that head. FAKE_PROVER is the run whose record the tree's artifact
# list names: the merge_group run for a push, the pull request's for a group.
mkdir -p "$TMP/bin"
cat >"$TMP/bin/gh" <<'FAKE_GH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$FAKE_GH_CALLS"
mode="${FAKE_GH_MODE:-valid}"
[ "$mode" != api-error ] || exit 1
args="$*"

workflow_json() { # ID PATH STATE
  printf '{"id":%s,"path":"%s","state":"%s"}\n' "$1" "$2" "$3"
}
the_run() { # ID — the run as the API answers it, bent by the mode
  local id="$1" event=pull_request status=completed conclusion=success sha="$FAKE_P" branch=topic
  local path="$FAKE_WORKFLOW" wid="$FAKE_WORKFLOW_ID" repo="$FAKE_REPO" head_repo="$FAKE_REPO"
  local pr="$FAKE_PR" pr_head="$FAKE_P" prs
  if [ "$id" = "$FAKE_RUN_MG" ]; then
    event=merge_group sha="$FAKE_S" branch="gh-readonly-queue/main/pr-$FAKE_PR-$FAKE_B"
  fi
  [ "$id" != "$FAKE_RUN_PR_FAILED" ] || conclusion=failure
  case "$mode" in
    malformed-run) printf '{"id":%s}' "$id"; return 0 ;;
    wrong-event) event=push ;;
    wrong-status) status=in_progress ;;
    wrong-conclusion) conclusion=failure ;;
    wrong-sha) sha="$FAKE_B" ;;
    wrong-branch) branch=main ;;
    wrong-run-path) path=.github/workflows/other.yml ;;
    wrong-workflow-id) wid=1 ;;
    wrong-repo) repo=other/kendex ;;
    wrong-head-repo) head_repo=fork/kendex ;;
    other-pr) pr=262 ;;
    stale-pr-head) pr_head="$FAKE_B" ;;
  esac
  prs="[{\"number\":$pr,\"head\":{\"sha\":\"$pr_head\"}}]"
  [ "$id" != "$FAKE_RUN_MG" ] && [ "$mode" != no-prs ] || prs='[]'
  printf '{"id":%s,"workflow_id":%s,"event":"%s","status":"%s","conclusion":"%s","head_sha":"%s","head_branch":"%s","path":"%s","repository":{"full_name":"%s"},"head_repository":{"full_name":"%s"},"pull_requests":%s}' \
    "$id" "$wid" "$event" "$status" "$conclusion" "$sha" "$branch" "$path" "$repo" "$head_repo" "$prs"
}
runs_list() { # RUN_JSON... — a whole list
  local n=$# list=""
  for run in "$@"; do list="$list${list:+,}$run"; done
  printf '{"total_count":%s,"workflow_runs":[%s]}\n' "$n" "$list"
}
artifact_json() { # ID NAME EXPIRED RUN
  printf '{"id":%s,"name":"%s","expired":%s,"workflow_run":{"id":%s}}' "$1" "$2" "$3" "$4"
}
# The artifacts named for the tree, the one RUN left among them.
the_artifacts() { # RUN
  local name="change-class-proof-$FAKE_TREE"
  [ "${MACOS_PATCH_PROOF:-}" != true ] || name="change-class-macos-proof-$FAKE_PATCH"
  case "$mode" in
    malformed-artifacts) printf '{"artifacts":{}}\n' ;;
    no-artifact) printf '{"artifacts":[]}\n' ;;
    other-name) printf '{"artifacts":[%s]}\n' "$(artifact_json "$FAKE_ARTIFACT" "change-class-proof-$FAKE_OTHER_TREE" false "$1")" ;;
    expired) printf '{"artifacts":[%s]}\n' "$(artifact_json "$FAKE_ARTIFACT" "$name" true "$1")" ;;
    # Newest first, as the API lists them: the failed run's record ahead of
    # the passing run's.
    failed-then-valid) printf '{"artifacts":[%s,%s]}\n' \
      "$(artifact_json "$FAKE_ARTIFACT_FAILED" "$name" false "$FAKE_RUN_PR_FAILED")" \
      "$(artifact_json "$FAKE_ARTIFACT" "$name" false "$FAKE_RUN_PR")" ;;
    *) printf '{"artifacts":[%s]}\n' "$(artifact_json "$FAKE_ARTIFACT" "$name" false "$1")" ;;
  esac
}

[[ "$args" == *"--method GET"* ]] || [[ "$args" == *"/zip"* ]] || exit 1
case "$args" in
  *"actions/workflows/ci.yml"*)
    case "$mode" in
      malformed-workflow) printf '{"id":"%s","path":"%s","state":"active"}\n' "$FAKE_WORKFLOW_ID" "$FAKE_WORKFLOW" ;;
      wrong-workflow-path) workflow_json "$FAKE_WORKFLOW_ID" .github/workflows/other.yml active ;;
      inactive-workflow) workflow_json "$FAKE_WORKFLOW_ID" "$FAKE_WORKFLOW" disabled_manually ;;
      *) workflow_json "$FAKE_WORKFLOW_ID" "$FAKE_WORKFLOW" active ;;
    esac
    exit 0 ;;
  *"actions/workflows/$FAKE_WORKFLOW_ID/runs"*)
    [ "$mode" != runs-api-error ] || exit 1
    [[ "$args" == *"status=completed"* ]] || exit 1
    [[ "$args" == *"per_page=100"* ]] || exit 1
    [[ "$args" == *"event=merge_group"*"head_sha=$FAKE_S"* ]] || exit 1
    case "$mode" in
      malformed-runs) printf '{"workflow_runs":{}}\n' ;;
      truncated) printf '{"total_count":2,"workflow_runs":[%s]}\n' "$(the_run "$FAKE_RUN_MG")" ;;
      missing) runs_list ;;
      ambiguous) runs_list "$(the_run "$FAKE_RUN_MG")" "$(the_run "$FAKE_RUN_MG")" ;;
      *) runs_list "$(the_run "$FAKE_RUN_MG")" ;;
    esac
    exit 0 ;;
  *"actions/runs/"*)
    [ "$mode" != runs-api-error ] || exit 1
    [ "$mode" != unreadable-run ] || { printf '"not a run"\n'; exit 0; }
    run="${args#*actions/runs/}"
    the_run "${run%% *}"
    exit 0 ;;
  *"actions/artifacts/$FAKE_ARTIFACT/zip"*)
    [ "$mode" != download-error ] || exit 1
    cat "$FAKE_ZIP"
    exit 0 ;;
  *"actions/artifacts -f"*)
    [ "$mode" != artifacts-api-error ] || exit 1
    if [ "${MACOS_PATCH_PROOF:-}" = true ]; then
      [[ "$args" == *"name=change-class-macos-proof-$FAKE_PATCH"* ]] || exit 1
    else
      [[ "$args" == *"name=change-class-proof-$FAKE_TREE"* ]] || exit 1
    fi
    the_artifacts "$FAKE_PROVER"
    exit 0 ;;
esac
exit 1
FAKE_GH
chmod +x "$TMP/bin/gh"

# A PATH with only what the script needs, and one without gh or unzip.
mkdir -p "$TMP/tools" "$TMP/no-unzip"
for tool in bash git jq unzip sed cat; do
  ln -s "$(command -v "$tool")" "$TMP/tools/$tool"
done
for tool in bash git jq sed cat; do
  ln -s "$(command -v "$tool")" "$TMP/no-unzip/$tool"
done
BIN="$TMP/bin:$TMP/tools"

CALLS="$TMP/calls"
OUT="$TMP/out"
# Run a proof script with an explicit environment: the accepted row's for
# KIND, the squashed group head S tested on either event, then each
# NAME=VALUE override, the later winning. Prints the exit status; the lines
# are in $OUT.
run() { # SCRIPT KIND(push|merge_group) MODE ZIP [NAME=VALUE]...
  local script="$1" kind="$2" mode="$3" zip="$4" status=0 ref prover
  shift 4
  : >"$CALLS"
  : >"$OUT"
  case "$kind" in
    push) ref=refs/heads/main prover="$RUN_MG" ;;
    merge_group) ref="$QUEUE_REF" prover="$RUN_PR" ;;
  esac
  mkdir -p "$TMP/work"
  rm -rf -- "${TMP:?}/work"/*
  (env -i PATH="$BIN" HOME="$TMP" \
    FAKE_GH_CALLS="$CALLS" FAKE_GH_MODE="$mode" FAKE_ZIP="$TMP/$zip.zip" \
    FAKE_WORKFLOW="$WORKFLOW" FAKE_WORKFLOW_ID="$WORKFLOW_ID" FAKE_REPO="$REPO_NAME" \
    FAKE_PATCH="$PATCH" FAKE_S="$S" FAKE_P="$P" FAKE_B="$B" FAKE_TREE="$TREE" FAKE_OTHER_TREE="$OTHER_TREE" FAKE_PR="$PR" \
    FAKE_RUN_MG="$RUN_MG" FAKE_RUN_PR="$RUN_PR" FAKE_RUN_PR_FAILED="$RUN_PR_FAILED" \
    FAKE_ARTIFACT="$ARTIFACT" FAKE_ARTIFACT_FAILED="$ARTIFACT_FAILED" FAKE_PROVER="$prover" \
    EVENT="$kind" BASE="$B" HEAD="$S" REPO="$REPO" \
    GITHUB_SHA="$S" GITHUB_REPOSITORY="$REPO_NAME" GITHUB_REF="$ref" \
    GITHUB_ACTOR='github-merge-queue[bot]' GITHUB_TRIGGERING_ACTOR='github-merge-queue[bot]' \
    GITHUB_WORKFLOW_REF="$REPO_NAME/$WORKFLOW@refs/heads/main" GITHUB_EVENT_PATH="$TMP/event-$kind.json" \
    GH_TOKEN=ghs_token \
    "$@" bash "$script" "$TMP/work" >"$OUT" 2>"$TMP/err") || status=$?
  printf '%s' "$status"
}
line() { sed -n "s/^$1=//p" "$OUT"; }
calls() { # the number of gh calls, or `unreadable`
  local n status=0
  n="$(grep -c . "$CALLS")" || status=$?
  [ "$status" -le 1 ] && printf '%s' "$n" || printf 'unreadable'
}
# `reuse reason run calls` for one row, or `exit=N` where the script failed.
answer() { # SCRIPT KIND MODE ZIP [NAME=VALUE]...
  local status
  status="$(run "$@")"
  if [ "$status" != 0 ]; then printf 'exit=%s %s' "$status" "$(head -1 "$TMP/err")"; return 0; fi
  printf '%s %s %s %s' "$(line reuse)" "$(line reason)" "$(line run)" "$(calls)"
}

# --- 1. The table ---------------------------------------------------------------
# LABEL|KIND|MODE|ZIP|OVERRIDES|EXPECTED (reuse reason run calls)
# Every row is an accepted row with ONE thing changed. The call column is the
# no-call rows' load-bearing assertion: they run under api-error, so a script
# that consulted the API before checking its own event would refuse for a
# plausible reason with a non-empty log. Both events read the workflow, the
# artifacts named for the tree, the run each names and the zip; a push reads
# its runs for the sha after the workflow, to hold it to one run. The `group:`
# rows and the record rows run on a merge group and stand for both.
rows() {
  cat <<ROWS
queue push with an exact merge-group proof|push|valid|valid||true exact-proof $RUN_MG 5
squashed merge group with its pull request's proof|merge_group|valid|valid||true exact-proof $RUN_PR 4
merged merge group with its pull request's proof|merge_group|valid|valid|GITHUB_SHA=$M HEAD=$M|true exact-proof $RUN_PR 4
no GITHUB_SHA|merge_group|api-error|valid|GITHUB_SHA=|false no-github-sha  0
tree unreadable: a sha the checkout lacks|merge_group|api-error|valid|GITHUB_SHA=0123456789abcdef0123456789abcdef01234567|false tree-unreadable  0
invalid input: malformed repository|merge_group|api-error|valid|GITHUB_REPOSITORY=not-a-repo GITHUB_WORKFLOW_REF=not-a-repo/.github/workflows/ci.yml@refs/heads/main|false invalid-input  0
invalid input: a workflow ref outside .github/workflows|merge_group|api-error|valid|GITHUB_WORKFLOW_REF=$REPO_NAME/tools/ci.yml@refs/heads/main|false invalid-input  0
ineligible: a pull request|merge_group|api-error|valid|EVENT=pull_request|false ineligible-event  0
ineligible: a schedule|merge_group|api-error|valid|EVENT=schedule|false ineligible-event  0
event unreadable: no payload file|push|api-error|valid|GITHUB_EVENT_PATH=$TMP/nowhere.json|false event-unreadable  0
event unreadable: no default branch|push|api-error|valid|GITHUB_EVENT_PATH=$TMP/event-push-no-default.json|false event-unreadable  0
ineligible push: not the default branch|push|api-error|valid|GITHUB_REF=refs/heads/feature|false ineligible-push  0
ineligible push: a human actor|push|api-error|valid|GITHUB_ACTOR=bmethod|false ineligible-push  0
ineligible push: a human triggering actor|push|api-error|valid|GITHUB_TRIGGERING_ACTOR=bmethod|false ineligible-push  0
ineligible push: forced|push|api-error|valid|GITHUB_EVENT_PATH=$TMP/event-push-forced.json|false ineligible-push  0
ineligible push: after is not the judged sha|push|api-error|valid|GITHUB_EVENT_PATH=$TMP/event-push-other-after.json|false ineligible-push  0
ineligible merge group: head is not the tested sha|merge_group|api-error|valid|HEAD=$P|false ineligible-merge-group  0
ineligible merge group: a queue branch of another branch|merge_group|api-error|valid|GITHUB_REF=refs/heads/gh-readonly-queue/other/pr-$PR-$B|false ineligible-merge-group  0
ineligible merge group: a ref naming no pull request|merge_group|api-error|valid|GITHUB_REF=refs/heads/main|false ineligible-merge-group  0
no gh on PATH|merge_group|api-error|valid|PATH=$TMP/tools|false gh-unavailable  0
no unzip on PATH|merge_group|api-error|valid|PATH=$TMP/bin:$TMP/no-unzip|false unzip-unavailable  0
no token|merge_group|api-error|valid|GH_TOKEN=|false no-token  0
workflow read fails|merge_group|api-error|valid|GH_TOKEN=ghs_token|false workflow-api-error  1
workflow id is not a number|merge_group|malformed-workflow|valid||false malformed-workflow  1
workflow answers for another path|merge_group|wrong-workflow-path|valid||false malformed-workflow  1
workflow is disabled|merge_group|inactive-workflow|valid||false malformed-workflow  1
push: runs read fails|push|runs-api-error|valid||false runs-api-error  2
push: runs payload is not a list|push|malformed-runs|valid||false malformed-runs  2
push: runs payload is truncated below its own total|push|truncated|valid||false malformed-runs  2
push: no run for the sha|push|missing|valid||false missing-proof  2
push: two merge-group runs for the pushed sha|push|ambiguous|valid||false ambiguous-proof  2
push: the run is for another sha|push|wrong-sha|valid||false mismatched-proof  4
push: the run is not from a queue branch|push|wrong-branch|valid||false mismatched-proof  4
group: artifacts read fails|merge_group|artifacts-api-error|valid||false artifacts-api-error  2
group: artifacts payload is not a list|merge_group|malformed-artifacts|valid||false malformed-artifacts  2
group: no artifact for the tree|merge_group|no-artifact|valid||false missing-record  2
group: the artifact names another tree|merge_group|other-name|valid||false missing-record  2
group: the artifact has expired|merge_group|expired|valid||false expired-record  2
group: run read fails|merge_group|runs-api-error|valid||false runs-api-error  3
group: run payload is not a run|merge_group|unreadable-run|valid||false malformed-runs  3
group: the run has the wrong event|merge_group|wrong-event|valid||false mismatched-proof  3
group: the run has not completed|merge_group|wrong-status|valid||false mismatched-proof  3
group: the run did not succeed|merge_group|wrong-conclusion|valid||false mismatched-proof  3
group: the run is for another workflow file|merge_group|wrong-run-path|valid||false mismatched-proof  3
group: the run belongs to another workflow id|merge_group|wrong-workflow-id|valid||false mismatched-proof  3
group: the run belongs to another repository|merge_group|wrong-repo|valid||false mismatched-proof  3
group: the run came from a fork head|merge_group|wrong-head-repo|valid||false mismatched-proof  3
group: the run is missing every field but its id|merge_group|malformed-run|valid||false mismatched-proof  3
group: the run is another pull request's|merge_group|other-pr|valid||false mismatched-proof  3
group: the run tested a head the pull request has left|merge_group|stale-pr-head|valid||false mismatched-proof  3
group: the run names no pull request|merge_group|no-prs|valid||false mismatched-proof  3
record download fails|merge_group|download-error|valid||false record-download-error  4
the artifact is not a zip|merge_group|valid|garbage||false record-unreadable  4
the artifact's member is not named record|merge_group|valid|wrong-member||false record-unreadable  4
the record names another tree|merge_group|valid|wrong-tree||false record-mismatch  4
the record names another workflow|merge_group|valid|wrong-workflow||false record-mismatch  4
patch proof survives the moved base|merge_group|valid|patch|MACOS_PATCH_PROOF=true BASE=$B2 HEAD=$S2 GITHUB_SHA=$S2|true exact-proof $RUN_PR 4
patch proof refuses changed test contract|merge_group|valid|wrong-contract|MACOS_PATCH_PROOF=true|false record-mismatch  4
patch proof refuses different recorded patch|merge_group|valid|wrong-patch|MACOS_PATCH_PROOF=true|false record-mismatch  4
patch proof refuses absent macOS coverage|merge_group|valid|no-macos|MACOS_PATCH_PROOF=true|false record-mismatch  4
patch proof refuses non-PR record|merge_group|valid|wrong-patch-event|MACOS_PATCH_PROOF=true|false record-mismatch  4
patch proof refuses failed run|merge_group|wrong-conclusion|patch|MACOS_PATCH_PROOF=true|false mismatched-proof  3
patch proof refuses missing record|merge_group|no-artifact|patch|MACOS_PATCH_PROOF=true|false missing-record  2
patch proof refuses unreadable merge base|merge_group|api-error|patch|MACOS_PATCH_PROOF=true BASE=absent|false patch-unreadable  0
ROWS
}
row_answer() { # SCRIPT ROW-LABEL — the answer for the row named LABEL
  local line label kind mode zip overrides expected
  line="$(rows | grep -m1 -F -- "$2|")" || { echo "no row named $2" >&2; exit 1; }
  IFS='|' read -r label kind mode zip overrides expected <<<"$line"
  # shellcheck disable=SC2086 # the overrides are blank-separated words
  answer "$1" "$kind" "$mode" "$zip" $overrides
}
table_rows=0
while IFS='|' read -r label kind mode zip overrides expected; do
  table_rows=$((table_rows + 1))
  # shellcheck disable=SC2086 # the overrides are blank-separated words
  check "$label" "$expected" "$(answer "$PROOF" "$kind" "$mode" "$zip" $overrides)"
done < <(rows)
[ "$table_rows" -ge 56 ] || { echo "the table read $table_rows rows" >&2; exit 1; }

# The tree and the workflow are printed on every answer, a refusal's too:
# the record a run leaves is written from them.
run "$PROOF" merge_group api-error valid EVENT=schedule >/dev/null
refused="$(line tree) $(line workflow)"
run "$PROOF" merge_group valid valid >/dev/null
check "the tree and workflow lines are printed on a refusal and on a proof alike" \
  "$TREE $WORKFLOW $TREE $WORKFLOW" "$refused $(line tree) $(line workflow)"
run "$PROOF" merge_group api-error valid GITHUB_WORKFLOW_REF="$REPO_NAME/tools/ci.yml@refs/heads/main" >/dev/null
check "an unreadable workflow ref prints the tree and an empty workflow" "$TREE " \
  "$(line tree) $(line workflow)"
check "a refusal prints what it saw" "event=schedule" \
  "$(run "$PROOF" merge_group api-error valid EVENT=schedule >/dev/null; line detail)"

run "$PROOF" merge_group api-error patch EVENT=pull_request MACOS_PATCH_PROOF=true >/dev/null
check "PR computes the patch identity without reading GitHub proof" "$PATCH 0" "$(line patch_id) $(calls)"

# --- 2. The record ------------------------------------------------------------
run "$PROOF" merge_group valid valid >/dev/null
check "the accepted row's record is the file the artifact holds" "$RECORD" "$(cat "$(line record)")"
check "the record path is inside the work directory given" "$TMP/work/record" "$(line record)"
calls_made() { sed 's/^api //; s/^--method GET //; s/^repos\/[^/]*\/[^/]*\///; s/ -f .*//' "$CALLS"; }
check "a merge group reads the workflow, the tree's artifacts, the run one names and the zip, in that order" \
  "actions/workflows/ci.yml
actions/artifacts
actions/runs/$RUN_PR
actions/artifacts/$ARTIFACT/zip" "$(calls_made)"
run "$PROOF" push valid valid >/dev/null
check "a push reads the workflow, its runs for the sha, then the tree's artifacts, the run one names and the zip" \
  "actions/workflows/ci.yml
actions/workflows/$WORKFLOW_ID/runs
actions/artifacts
actions/runs/$RUN_MG
actions/artifacts/$ARTIFACT/zip" "$(calls_made)"
check "a newer record whose run failed is passed over for the passing run's" \
  "true exact-proof $RUN_PR 5" "$(answer "$PROOF" merge_group failed-then-valid valid)"

# --- 3. The must-fail inverses ------------------------------------------------
# NEEDLE@REPLACEMENT@ROW LABEL: one copy per rule, the rule planted away and
# every other line kept; the copy must run to completion and answer the row
# other than the table says. Split on `@` because a rule spells `|`.
mutant="$TMP/mutant/proof"
mkdir -p "$TMP/mutant"
mutants=0
while IFS='@' read -r needle replacement row; do
  mutants=$((mutants + 1))
  [ "$(grep -cF -- "$needle" "$PROOF")" -eq 1 ] ||
    { echo "the rule '$needle' is no longer one line in $PROOF" >&2; exit 1; }
  NEEDLE="$needle" REPLACEMENT="$replacement" awk '
    { i = index($0, ENVIRON["NEEDLE"]) }
    i > 0 { $0 = substr($0, 1, i - 1) ENVIRON["REPLACEMENT"] substr($0, i + length(ENVIRON["NEEDLE"])) }
    { print }
  ' "$PROOF" >"$mutant"
  ! cmp -s "$PROOF" "$mutant" || { echo "the mutant for '$needle' changed nothing" >&2; exit 1; }
  if [ "$row" = "a newer record whose run failed" ]; then
    expected="true exact-proof $RUN_PR 5"
    got="$(answer "$mutant" merge_group failed-then-valid valid)"
  else
    expected="$(rows | grep -m1 -F -- "$row|" | awk -F '|' '{ print $6 }')"
    got="$(row_answer "$mutant" "$row")"
  fi
  case "$got" in
    exit=*) bad "must-fail: '$needle' planted as '$replacement' crashed the $row row: $got" ;;
    "$expected") bad "must-fail: '$needle' planted as '$replacement' still answers the $row row" ;;
    *) ok "must-fail: '$needle' planted as '$replacement' fails the $row row" ;;
  esac
done <<'ROWS'
  push | merge_group) ;;@  push | merge_group | pull_request) ;;@ineligible: a pull request
  [ "${GITHUB_REF:-}" = "refs/heads/$default_branch" ] &&@  true &&@ineligible push: not the default branch
    [ "${GITHUB_ACTOR:-}" = "$QUEUE_ACTOR" ] &&@    true &&@ineligible push: a human actor
    [ "${GITHUB_TRIGGERING_ACTOR:-}" = "$QUEUE_ACTOR" ] &&@    true &&@ineligible push: a human triggering actor
    [ "$forced" = false ] && [ "$after" = "$GITHUB_SHA" ] ||@    [ "$after" = "$GITHUB_SHA" ] ||@ineligible push: forced
    [ "$forced" = false ] && [ "$after" = "$GITHUB_SHA" ] ||@    [ "$forced" = false ] ||@ineligible push: after is not the judged sha
  [ "${HEAD:-}" = "$GITHUB_SHA" ] ||@  true ||@ineligible merge group: head is not the tested sha
gh-readonly-queue/$default_branch/pr-@gh-readonly-queue/[^/]+/pr-@ineligible merge group: a queue branch of another branch
  queue_re="^refs/heads/gh-readonly-queue/$default_branch/pr-([0-9]+)-[0-9a-f]+$"@  queue_re="^refs/heads/([0-9]*)"@ineligible merge group: a ref naming no pull request
[[ "$repo" =~ $repo_re ]] &&@true &&@invalid input: malformed repository
  [[ "$workflow_path" =~ $path_re ]] ||@  true ||@invalid input: a workflow ref outside .github/workflows
[ -n "${GH_TOKEN:-}" ] || answer no-token "GH_TOKEN is empty"@:@no token
  ((.id | type) == "number") and (.id > 0) and (.path == $path) and (.state == "active")@  (.path == $path) and (.state == "active")@workflow id is not a number
  ((.id | type) == "number") and (.id > 0) and (.path == $path) and (.state == "active")@  ((.id | type) == "number") and (.id > 0) and (.state == "active")@workflow answers for another path
  ((.id | type) == "number") and (.id > 0) and (.path == $path) and (.state == "active")@  ((.id | type) == "number") and (.id > 0) and (.path == $path)@workflow is disabled
  ((.workflow_runs | type) == "array") and (.total_count == (.workflow_runs | length))@  ((.workflow_runs | type) == "array")@push: runs payload is truncated below its own total
[ "$run_count" -eq 1 ] ||@true ||@push: two merge-group runs for the pushed sha
    ($event != "merge_group" or ((.head_sha == $sha) and (.head_branch | test($branch_re)))) and@    ($event != "merge_group" or ((.head_branch | test($branch_re)))) and@push: the run is for another sha
    ($event != "merge_group" or ((.head_sha == $sha) and (.head_branch | test($branch_re)))) and@    ($event != "merge_group" or ((.head_sha == $sha))) and@push: the run is not from a queue branch
  .artifacts[] | select(.name == $name and .expired == false)@  .artifacts[] | select(.name == $name)@group: the artifact has expired
    (.workflow_id == $workflow_id) and (.event == $event) and@    (.workflow_id == $workflow_id) and@group: the run has the wrong event
    (.status == "completed") and (.conclusion == "success") and@    (.conclusion == "success") and@group: the run has not completed
    (.status == "completed") and (.conclusion == "success") and@    (.status == "completed") and@group: the run did not succeed
    (.path == $path) and ((.head_sha | type) == "string") and@    ((.head_sha | type) == "string") and@group: the run is for another workflow file
    (.workflow_id == $workflow_id) and (.event == $event) and@    (.event == $event) and@group: the run belongs to another workflow id
    (.repository.full_name == $repo) and (.head_repository.full_name == $repo))@    (.head_repository.full_name == $repo))@group: the run belongs to another repository
    (.repository.full_name == $repo) and (.head_repository.full_name == $repo))@    (.repository.full_name == $repo))@group: the run came from a fork head
any(.pull_requests[]?; .number == $pr and .head.sha == $head)@any(.pull_requests[]?; .head.sha == $head)@group: the run is another pull request's
any(.pull_requests[]?; .number == $pr and .head.sha == $head)@any(.pull_requests[]?; .number == $pr)@group: the run tested a head the pull request has left
    ($event != "pull_request" or (.head_sha as $head | any(.pull_requests[]?; .number == $pr and .head.sha == $head))) and@@group: the run names no pull request
  [ "$qualified" != "$run_id" ] || take_record "$artifact" "$run_id"@  take_record "$artifact" "$run_id"@a newer record whose run failed
  [ "$recorded_tree" = "$tree" ] && [ "$recorded_workflow" = "$workflow_path" ] ||@  [ "$recorded_workflow" = "$workflow_path" ] ||@the record names another tree
  [ "$recorded_tree" = "$tree" ] && [ "$recorded_workflow" = "$workflow_path" ] ||@  [ "$recorded_tree" = "$tree" ] ||@the record names another workflow
    [ "$recorded_patch" = "$patch_id" ] && [ "$recorded_macos" = true ] &&@    true && [ "$recorded_macos" = true ] &&@patch proof refuses different recorded patch
    [ "$recorded_patch" = "$patch_id" ] && [ "$recorded_macos" = true ] &&@    [ "$recorded_patch" = "$patch_id" ] && true &&@patch proof refuses absent macOS coverage
      [ "$recorded_event" = pull_request ] && [ "$recorded_workflow" = "$workflow_path" ] ||@      true && [ "$recorded_workflow" = "$workflow_path" ] ||@patch proof refuses non-PR record
[ "$kind" != macos-patch ] || artifact_name="change-class-macos-proof-$patch_id"@:@patch proof survives the moved base
    [ "$recorded_contract" = "$macos_contract" ] || answer record-mismatch "run $2 changed the macOS contract"@:@patch proof refuses changed test contract
ROWS
[ "$mutants" -ge 33 ] || { echo "the mutant table read $mutants rows" >&2; exit 1; }

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
