#!/usr/bin/env bash
# Tests for CI event selection and platform parity.
set -euo pipefail

# A suite running from inside a git hook inherits GIT_DIR, GIT_COMMON_DIR,
# GIT_WORK_TREE and GIT_INDEX_FILE, which would resolve ROOT to the hook's
# repository instead of this one.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/ci-job-set-world.sh
. "$TEST_DIR/lib/ci-job-set-world.sh"

# An event the workflow does not classify on is refused, with the parity
# call or without: a manual dispatch runs the nightly jobs whole with no
# selection, and a selection asked for one would stand lanes down on no
# diff. The rows ask over no diff, so no reach runs before the refusal.
# The main push and the schedule take the proof routes below.
# ARGUMENT|EVENT|EXPECTED
if [ "${1-}" != --inventory-proof ] && [ "${1-}" != --checkout-reads ]; then
refused_rows=0
refused_row() { # ARGUMENT EVENT EXPECTED
  check "event ${2:-unset}, called with ${1:-no argument}" "$3" \
    "$(SELECT_ARG="$1" SELECT_EVENT="$2" selection micro false '')"
}
while IFS='|' read -r arg event expected; do
  refused_rows=$((refused_rows + 1))
  row_spawn refused_row "$arg" "$event" "$expected"
done <<ROWS
|workflow_dispatch|exit=2 unsupported-event event=workflow_dispatch
--event-parity|workflow_dispatch|exit=2 unsupported-event event=workflow_dispatch
||exit=2 unsupported-event event=
ROWS
[ "$refused_rows" -eq 3 ] || { echo "the refused-event table read $refused_rows rows" >&2; exit 1; }
# The macOS legs run wherever a shard and a platform lane run, on the pull
# request as in the merge group: the --event-parity call derives both and
# refuses where they differ, as the parity rows below prove.
# PATHS|LEGS
leg_rows=0
leg_row() { # PATHS EXPECTED
  check "the legs over '$1' on both events" "$2" \
    "$(SELECT_ARG=--event-parity selection micro false "$(printf '%s\n' $1)" | sed 's/.* shell_os=\(\[[^]]*\]\).*/\1/')"
}
while IFS='|' read -r paths expected; do
  leg_rows=$((leg_rows + 1))
  row_spawn leg_row "$paths" "$expected"
done <<ROWS
skills/orch/scripts/resolve-base-branch|$BOTH
skills/orch/SKILL.md|$LINUX
.github/AGENTS.md skills/orch/scripts/resolve-base-branch|$BOTH
crates/core/src/lib.rs|$BOTH
ROWS
[ "$leg_rows" -eq 4 ] || { echo "the legs table read $leg_rows rows" >&2; exit 1; }
# Event parity: a copy that plants the macOS legs on the merge group alone is
# refused by the --event-parity call on either event. A call without the flag
# derives its one event alone, so the same copy answers it.
# ARGUMENT|EVENT|EXPECTED; an argument other than --event-parity or
# --runtime-publish is refused.
mkdir -p "$TMP/parity/tools"
cp -R "$ROOT/tools/lib" "$TMP/parity/tools/lib"
cp "$ROOT/tools/macos-test-contracts" "$ROOT/tools/macos-test-contracts.json" "$TMP/parity/tools/"
cp "$ROOT/tools/rust-reads" "$TMP/parity/tools/rust-reads"
awk '
  /\[ "\$SHELL_FULL" = false \] \|\| macos=true/ {
    print; print "  [ \"$event\" = merge_group ] || macos=false"; n++; next
  }
  { print }
  END { if (n != 1) exit 1 }
' "$JOB_SET" >"$TMP/parity/tools/ci-job-set"
chmod +x "$TMP/parity/tools/ci-job-set"
parity_rows=0
parity_row() { # ARGUMENT EVENT EXPECTED
  check "a macOS leg the merge group alone selects, called with ${1:-no argument} on $2" "$3" \
    "$(SELECT_WITH="$TMP/parity/tools/ci-job-set" SELECT_ARG="$1" SELECT_EVENT="$2" selection micro false skills/orch/scripts/resolve-base-branch | sed 's/.* shell_os=\(\[[^]]*\]\).*/\1/')"
}
while IFS='|' read -r arg event expected; do
  parity_rows=$((parity_rows + 1))
  row_spawn parity_row "$arg" "$event" "$expected"
done <<ROWS
--event-parity|pull_request|exit=2 event-parity event=merge_group
--event-parity|merge_group|exit=2 event-parity event=pull_request
|pull_request|$LINUX
|merge_group|$BOTH
--parity|pull_request|exit=2 unknown-argument value=--parity
ROWS
[ "$parity_rows" -eq 5 ] || { echo "the parity table read $parity_rows rows" >&2; exit 1; }
# That call says on stderr each step it starts, in order, with the reach's
# own progress forwarded inside the reach step.
progress_steps() { # STDERR_FILE — the steps and the reach's end, `|`-joined
  sed -n 's/^ci-job-set: progress=\([a-z]*\) at=\([0-9]*\/[0-9]*\) elapsed=[0-9]*s\(.*\)$/\1 \2\3/p; s/^guard-progress: phase=done at=.*/guard done/p' \
    "$1" | paste -sd '|' -
}
PROGRESS_STEPS="reach 1/4|guard done|select 2/4 event=pull_request|select 3/4 event=merge_group|emit 4/4"
parity_call_row() {
  check "this tree's selection passes the --event-parity call unchanged" \
    "$(selection micro false skills/orch/scripts/resolve-base-branch)" \
    "$(SELECT_ARG=--event-parity selection micro false skills/orch/scripts/resolve-base-branch)"
  check "the --event-parity call reports each step in order, the reach's progress inside the reach" \
    "$PROGRESS_STEPS" "$(progress_steps "$TMP/selection-err$ROW_TAG")"
}
row_spawn parity_call_row
# Control: a copy that drops the reach's progress lines breaks the row.
mkdir -p "$TMP/progress/tools"
cp -R "$ROOT/tools/lib" "$TMP/progress/tools/lib"
cp "$ROOT/tools/guard" "$ROOT/tools/rust-reads" "$ROOT/tools/macos-test-contracts" "$ROOT/tools/macos-test-contracts.json" \
  "$TMP/progress/tools/"
ln -s "$ROOT/skills" "$TMP/progress/skills"
sed "/^      'guard-progress: '\*) printf /d" "$JOB_SET" >"$TMP/progress/tools/ci-job-set"
chmod +x "$TMP/progress/tools/ci-job-set"
! cmp -s "$JOB_SET" "$TMP/progress/tools/ci-job-set" || exit 1
progress_control_row() {
  SELECT_WITH="$TMP/progress/tools/ci-job-set" SELECT_ARG=--event-parity selection micro false \
    skills/orch/scripts/resolve-base-branch >/dev/null
  [ "$(progress_steps "$TMP/selection-err$ROW_TAG")" != "$PROGRESS_STEPS" ] &&
    grep -q '^ci-job-set: progress=emit ' "$TMP/selection-err$ROW_TAG" &&
    ok "control: a copy that drops the reach's progress breaks the progress row" ||
    bad "control: a copy that drops the reach's progress breaks the progress row"
}
row_spawn progress_control_row

# An Ubuntu lane that differs by event is refused too.
cp -R "$TMP/parity" "$TMP/ubuntu"
awk '
  /^  printf .* cargo_linux=\$linux / {
    print "  [ \"$event\" = merge_group ] || linux=false"; n++
  }
  { print }
  END { if (n != 1) exit 1 }
' "$JOB_SET" >"$TMP/ubuntu/tools/ci-job-set"
ubuntu_row() { # EVENT OTHER
  check "Ubuntu event parity on $1" "exit=2 event-parity event=$2" \
    "$(SELECT_WITH="$TMP/ubuntu/tools/ci-job-set" SELECT_ARG=--event-parity SELECT_EVENT="$1" selection micro false crates/core/src/lib.rs)"
}
row_spawn ubuntu_row pull_request merge_group
row_spawn ubuntu_row merge_group pull_request

# THE PUBLISHED SELECTION: where CI_SELECTION names a file, a class
# selection writes there the skips and targets it emits, the one record the
# push at the group's head reads.
written_row() {
  local written
  written="$(CI_SELECTION="$TMP/written.json" selection micro false skills/orch/scripts/resolve-base-branch)"
  check "a class selection writes its skips and targets to CI_SELECTION" \
    "$(jq -cn --argjson s "$(sed -n 's/.* skipped_suites=\([^ ]*\).*/\1/p' <<<"$written")" \
      --argjson r "$(sed -n 's/.* rust_targets=\([^ ]*\).*/\1/p' <<<"$written")" '{skipped_suites: $s, rust_targets: $r}')" \
    "$(jq -c . "$TMP/written.json" 2>/dev/null || echo unwritten)"
}
row_spawn written_row
fi

# THE PUSH ROUTE: a main push owes, on each runner, the suites and Rust
# targets its same-head merge group did not prove. A stub on PATH answers
# `gh api` from a world directory built out of the recorded responses in
# data/: merge-group run 41306604685 and its latest jobs, on the head main
# pushed next, with the selection that run published planted as its
# artifact. Each world varies them as one GitHub state would.
DATA="$TEST_DIR/data"
PUSH_SHA="$(jq -er '.workflow_runs[0].head_sha' "$DATA/main-proof-runs.json")"
PUSH_RUN="$(jq -er '.workflow_runs[0].id' "$DATA/main-proof-runs.json")"
PUSH_REPO="$TMP/push-repo"
git clone -q --shared "$ROOT" "$PUSH_REPO"
git -C "$PUSH_REPO" config core.hooksPath /dev/null
git -C "$PUSH_REPO" config gc.auto 0
git -C "$PUSH_REPO" config maintenance.auto false
PUSH_BEFORE="$(git -C "$PUSH_REPO" rev-parse HEAD)"
printf '\n# input\n' >>"$PUSH_REPO/tools/guard"
git -C "$PUSH_REPO" add tools/guard
git -C "$PUSH_REPO" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm head
PUSH_AFTER="$(git -C "$PUSH_REPO" rev-parse HEAD)"
PUSH_SHA="$PUSH_AFTER"
export PUSH_BEFORE PUSH_AFTER
mkdir -p "$TMP/gh-stub"
cat >"$TMP/gh-stub/gh" <<'STUB'
#!/usr/bin/env bash
# `gh api --paginate URL` for a listing and `gh api URL` for a run record or
# an artifact's zip, served from GH_WORLD; a `fail` file there is an API
# outage, and a URL the world has no response for is GitHub's 404.
set -eu
case "$#:${1-}:${2-}" in
  3:api:--paginate) url=$3 ;;
  2:api:*) url=$2 ;;
  *) echo "gh-stub: args=$*" >&2; exit 64 ;;
esac
[ ! -e "$GH_WORLD/fail" ] || { echo 'gh: HTTP 502' >&2; exit 1; }
# A runtime build's listing by name: runtime-<runtime> in the world names
# the one artifact's state, published from main where the file is absent.
# The state's run is 100 plus its place in `states`, and its record differs
# from a published one in the legs the state names; the artifact's
# workflow_run mirrors the record's legs GitHub copies onto it.
RUNS='def states: ["published", "expired", "fork", "queue", "pull-request-main", "feature-push", "other-workflow",
    "run-unread", "pull-request-queue", "queue-other-base"];
  def run($state): {id: (100 + (states | index($state) // error("no state \($state)"))),
    event: (if $state == "queue" or $state == "queue-other-base" then "merge_group"
      elif $state == "fork" or $state == "pull-request-main" or $state == "pull-request-queue" then "pull_request"
      else "push" end),
    head_branch: (if $state == "queue" or $state == "pull-request-queue" then "gh-readonly-queue/main/pr-1-0"
      elif $state == "queue-other-base" then "gh-readonly-queue/release/pr-1-0"
      elif $state == "feature-push" then "feature" else "main" end),
    path: (if $state == "other-workflow" then ".github/workflows/lock-record.yml" else ".github/workflows/skill-tests.yml" end),
    repository: {id: 1}, head_repository: {id: (if $state == "fork" then 2 else 1 end)}};'
case "$#:$url" in
  3:repos/*/actions/artifacts\?name=*)
    artifact="${url#*name=}"
    artifact="${artifact%%&*}"
    state=published
    [ ! -f "$GH_WORLD/runtime-${artifact%-*}" ] || state="$(cat "$GH_WORLD/runtime-${artifact%-*}")"
    case "$state" in
      unread) echo 'gh: HTTP 502' >&2; exit 1 ;;
      none) echo '{"total_count":0,"artifacts":[]}' ;;
      *) jq -cn --arg name "$artifact" --arg state "$state" "$RUNS"'run($state) as $run | {total_count: 1,
          artifacts: [{id: ($run.id + 1000), name: $name, expired: ($state == "expired"), workflow_run: {id: $run.id,
            repository_id: $run.repository.id, head_repository_id: $run.head_repository.id,
            head_branch: $run.head_branch}}]}' ;;
    esac
    exit 0 ;;
  2:repos/*/actions/runs/*)
    state="$(jq -nr --argjson id "${url##*/}" "$RUNS"'if $id >= 100 then states[$id - 100] // empty else empty end')"
    case "$state" in
      '') echo 'gh: HTTP 404' >&2; exit 1 ;;
      run-unread) echo 'gh: HTTP 502' >&2; exit 1 ;;
    esac
    jq -cn --arg state "$state" "$RUNS"'run($state)'
    exit 0 ;;
esac
case "$#:$url" in
  3:repos/*/actions/workflows/skill-tests.yml/runs\?event=push\&*) file=push-runs.json ;;
  3:repos/*/actions/workflows/skill-tests.yml/runs\?*) file=runs.json ;;
  3:repos/*/actions/runs/*/jobs\?*) id="${url#repos/*/actions/runs/}"; file="jobs-${id%%/*}.json" ;;
  3:repos/*/actions/runs/*/artifacts\?*) id="${url#repos/*/actions/runs/}"; file="artifacts-${id%%/*}.json" ;;
  2:repos/*/actions/artifacts/*/zip) id="${url#repos/*/actions/artifacts/}"; file="zip-${id%%/*}" ;;
  *) echo "gh-stub: url=$url" >&2; exit 64 ;;
esac
[ -f "$GH_WORLD/$file" ] || { echo 'gh: HTTP 404' >&2; exit 1; }
case "$file" in
  *runs.json) key=workflow_runs ;;
  jobs-*) key=jobs ;;
  artifacts-*) key=artifacts ;;
  *) cat "$GH_WORLD/$file"; exit ;;
esac
# A run listing's head_sha parameter keeps that head's runs alone, and a
# filtered listing serves at most 1000 rows whatever its total_count: the
# successful main push listing served 10 full pages of 100 under
# total_count 2500 on 2026-11-26.
sha=""
case "$url" in *'&head_sha='*) sha="${url#*&head_sha=}"; sha="${sha%%&*}" ;; esac
jq -c --arg key "$key" --arg sha "$sha" '
  if (.[$key] | type) == "array" then
    if $key == "workflow_runs" and $sha != "" then .workflow_runs |= map(select(.head_sha == $sha)) else . end
    | .total_count = (.fixture_total_count // (.[$key] | length))
    | .[$key] |= .[:1000]
    | if $key == "jobs" then .jobs |= (to_entries | map(.value + {id: (.key + 1)})) else . end
  else . end
' "$GH_WORLD/$file"
STUB
chmod +x "$TMP/gh-stub/gh"
# The recording gives the job shape and the non-shard jobs. The shard legs
# are one recorded leg cloned per roster shard and runner, so a roster or
# eligibility change edits no recorded data.
jq -e --argjson linux "$ROSTER" --argjson macos "$QUEUE_ALL" '
  ([.jobs[] | select(.name | startswith("Skill suites shard ("))][0] // error("no recorded shard leg")) as $leg
  | .jobs = [.jobs[] | select(.name | startswith("Skill suites shard (") | not)]
    + [($linux[] | [., "ubuntu-latest"]), ($macos[] | [., "macos-latest"])
       | $leg + {name: "Skill suites shard (\(.[0]), \(.[1]))"}]' \
  "$DATA/main-proof-jobs.json" >"$TMP/push-jobs.json" ||
  { echo "the recorded jobs gave no shard leg to clone" >&2; exit 1; }
EVERY_TARGET='["agent-runtime/*","orch/*"]'
# The selection a run published, as tools/ci-job-set writes CI_SELECTION,
# zipped as GitHub serves an artifact, and the run's listing of it.
plant_selection() { # DIR RUN SKIPPED RUST [EXPIRED]
  local artifact=$(($2 + 1000))
  jq -cn --argjson run "$2" --argjson id "$artifact" --argjson expired "${5:-false}" '
    {total_count: 1, artifacts: [{id: $id, name: "ci-selection", expired: $expired,
      created_at: "2026-11-13T09:00:00Z", workflow_run: {id: $run}}]}' >"$1/artifacts-$2.json"
  python3 -c 'import sys, zipfile
with zipfile.ZipFile(sys.argv[1], "w") as z:
    z.writestr("ci-selection.json", sys.argv[2])' "$1/zip-$artifact" "{\"skipped_suites\":$3,\"rust_targets\":$4}"
}
# Main's successful push history ahead of PUSH_BEFORE's: more runs than a
# listing of every successful push serves, each at a head outside this
# history, so only a read by head finds PUSH_BEFORE's run.
jq -cn '[range(1100) | {id: (10000 + .), event: "push", head_branch: "main", path: ".github/workflows/skill-tests.yml",
    status: "completed", conclusion: "success", created_at: "2026-11-11T00:00:00Z", head_sha: (("f" * 40 | .[:32]) + ("0000000" + tostring | .[-8:]))}]' \
  >"$TMP/push-history.json"
# One world per GitHub state: runs.json, push-runs.json, and per run
# jobs-<run>.json, artifacts-<run>.json and the artifact's zip.
push_world() { # NAME [WORLD] — the NAME state, in the world named WORLD, NAME unless given
  local dir="$TMP/push/${2:-$1}" runs="$DATA/main-proof-runs.json" jobs="$TMP/push-jobs.json"
  local second=$((PUSH_RUN + 1))
  mkdir -p "$dir"
  jq --arg sha "$PUSH_SHA" '.workflow_runs[].head_sha = $sha' "$runs" >"$dir/runs.json"
  jq --arg sha "$PUSH_SHA" '.jobs[].head_sha = $sha' "$jobs" >"$dir/jobs-$PUSH_RUN.json"
  jq --arg sha "$PUSH_BEFORE" --slurpfile history "$TMP/push-history.json" '.workflow_runs = [(.workflow_runs[0] + {id:1,event:"push",head_branch:"main",status:"completed",conclusion:"success",created_at:"2026-11-12T00:00:00Z",head_sha:$sha})] + $history[0]' \
    "$runs" >"$dir/push-runs.json"
  plant_selection "$dir" "$PUSH_RUN" '[]' "$EVERY_TARGET"
  edit_jobs() { jq --arg sha "$PUSH_SHA" '.jobs[].head_sha = $sha' "$jobs" | jq "$1" >"$dir/jobs-$PUSH_RUN.json"; }
  fail_leg() { edit_jobs ".jobs |= map(if .name == \"Skill suites shard ($1)\" then .conclusion = \"failure\" else . end)"; }
  case "$1" in
    all-proved) ;;
    # A leg whose list left a suite out proves the suites it kept.
    kept-subset) plant_selection "$dir" "$PUSH_RUN" "[\"$P_TOOLS\"]" "$EVERY_TARGET" ;;
    # A group that left an original out still proved its native replacement.
    replacement-split) plant_selection "$dir" "$PUSH_RUN" "[\"$P_VIEW\"]" "$EVERY_TARGET" ;;
    red-leg) fail_leg 'guards-tools, ubuntu-latest' ;;
    linux-only) edit_jobs '.jobs |= map(select(.name | endswith(", macos-latest)") | not))' ;;
    no-shard-selected) edit_jobs '.jobs |= map(select(.name | test("^Skill suites shard \\([a-z]") | not))' ;;
    in-progress)
      edit_jobs '.jobs |= map(if .name == "Skill suites shard (guards-scans, ubuntu-latest)" then .status = "in_progress" | .conclusion = null else . end)' ;;
    failed-second-run)
      jq --arg sha "$PUSH_SHA" --argjson id "$second" '.workflow_runs[].head_sha = $sha | .workflow_runs += [.workflow_runs[0] | .id = $id | .run_attempt = 1]' "$runs" >"$dir/runs.json"
      jq --arg sha "$PUSH_SHA" --argjson id "$second" '.jobs |= map(.head_sha = $sha | .run_id = $id | if .name == "Skill suites shard (worktree, ubuntu-latest)" then .conclusion = "failure" else . end)' \
        "$jobs" >"$dir/jobs-$second.json"
      plant_selection "$dir" "$second" '[]' "$EVERY_TARGET" ;;
    foreign-head-job)
      edit_jobs '.jobs |= map(if .name == "Skill suites shard (mailbox, macos-latest)" then .head_sha = "0000000000000000000000000000000000000000" else . end)' ;;
    foreign-run-job)
      edit_jobs '.jobs |= map(if .name == "Skill suites shard (slack, ubuntu-latest)" then .run_id = 1 else . end)' ;;
    # A shard proved with only some of its Rust targets owes the rest.
    one-target) plant_selection "$dir" "$PUSH_RUN" '[]' '["orch/lib"]' ;;
    # A group whose selection held one package's targets whole.
    one-package) plant_selection "$dir" "$PUSH_RUN" '[]' '["agent-runtime/*"]' ;;
    red-orch-rest) fail_leg 'orch-rest, ubuntu-latest' ;;
    red-catalog) edit_jobs '.jobs |= map(if .name == "catalog (2/2) / kendex check" then .conclusion = "failure" else . end)' ;;
    no-selection) rm "$dir/artifacts-$PUSH_RUN.json" ;;
    expired-selection) plant_selection "$dir" "$PUSH_RUN" '[]' "$EVERY_TARGET" true ;;
    bad-selection) plant_selection "$dir" "$PUSH_RUN" '[]' '"orch/*"' ;;
    no-run) printf '{"total_count":0,"workflow_runs":[]}\n' >"$dir/runs.json" ;;
    outage) : >"$dir/fail" ;;
    unparseable) printf 'upstream connect error\n' >"$dir/runs.json" ;;
    jobs-missing) rm "$dir/jobs-$PUSH_RUN.json" ;;
    jobs-partial) edit_jobs '.fixture_total_count = ((.jobs | length) + 1)' ;;
    push-event-run) jq '.workflow_runs[0].event = "push"' "$runs" >"$dir/runs.json" ;;
    other-workflow-run) jq '.workflow_runs[0].path = ".github/workflows/lock-record.yml"' "$runs" >"$dir/runs.json" ;;
    *) echo "no push world named $1" >&2; exit 1 ;;
  esac
}
# `shards=… queue_macos_shards=… rust_targets=… skips=<linux>/<macos>
# main-proof=… warned=yes|no`, with the step's empty class inputs, or
# `exit=N`; the output stays in push-out for in_list.
push_select() { # WORLD [SELECTOR]
  local out="$TMP/push-out$ROW_TAG" err="$TMP/push-err$ROW_TAG" stdout="$TMP/push-stdout$ROW_TAG" status=0
  : >"$out"
  (cd "$PUSH_REPO" && PATH="$TMP/gh-stub:$PATH" GH_WORLD="$TMP/push/$1" GITHUB_REPOSITORY=vanillagreencom/kendex \
    GITHUB_SHA="$PUSH_SHA" EVENT=push CHANGE_CLASS='' DOCS_ONLY='' CHANGED_PATHS='' GITHUB_OUTPUT="$out" \
    "${2:-$JOB_SET}" --event-parity >"$stdout" 2>"$err") || status=$?
  [ "$status" -eq 0 ] || { printf 'exit=%s' "$status"; return 0; }
  printf 'shards=%s queue_macos_shards=%s rust_targets=%s skips=%s/%s %s warned=%s' \
    "$(field shards <"$out")" "$(field queue_macos_shards <"$out")" "$(field rust_targets <"$out")" \
    "$(field skipped_suites <"$out" | jq length)" "$(field skipped_suites_macos <"$out" | jq length)" \
    "$(sed -n 's/^ci-job-set: \(main-proof=[a-z]*\) .*/\1/p' "$err")" \
    "$(grep -q '^::warning ' "$stdout" && echo yes || echo no)"
}
field() { # NAME — the value of the NAME= line on stdin
  sed -n "s/^$1=//p"
}
in_list() { # NAME MEMBER — whether the last push output's NAME list holds MEMBER
  field "$1" <"$TMP/push-out$ROW_TAG" | jq --arg m "$2" 'index($m) != null'
}
# Rows run side by side, so a row that commits to the push checkout commits
# to its own: a clone of it at PUSH_BEFORE, removed when the row ends.
own_push_repo() {
  [ -n "$ROW_TAG" ] || { echo "own_push_repo runs inside a row alone" >&2; exit 1; }
  OWN_PUSH_REPO="$TMP/push-repo$ROW_TAG"
  git clone -q --shared -c core.hooksPath=/dev/null -c gc.auto=0 -c maintenance.auto=false \
    "$PUSH_REPO" "$OWN_PUSH_REPO"
  trap 'rm -rf -- "${OWN_PUSH_REPO:?}"' EXIT
  git -C "$OWN_PUSH_REPO" reset -q --hard "$PUSH_BEFORE"
  PUSH_REPO=$OWN_PUSH_REPO
}
push_commit() { # MESSAGE PATH... — PUSH_AFTER names the commit of PATH...
  git -C "$PUSH_REPO" add -A -- "${@:2}"
  git -C "$PUSH_REPO" -c user.name=fixture -c user.email=fixture@example.invalid commit -qm "$1"
  PUSH_AFTER="$(git -C "$PUSH_REPO" rev-parse HEAD)"
}
CHECKOUT_TEMPLATE=docs/checkout-mit-template.txt
main_checkout_row() { # PATH EXPECTED SKIPPED
  local reader=crates/core/src/author/scaffold.rs got
  own_push_repo
  # The changed include lives outside crates/ so the workspace build row
  # cannot select the checkout shards when the include is lost.
  git -C "$PUSH_REPO" mv crates/core/src/author/assets/mit.txt "$CHECKOUT_TEMPLATE"
  awk -v template="$CHECKOUT_TEMPLATE" '
    /^const MIT_TEXT: / { changes += sub(/"assets\/mit\.txt"/, "\"../../../../" template "\"") }
    { print }
    END { exit changes != 1 }
  ' "$PUSH_REPO/$reader" >"$TMP/scaffold.rs$ROW_TAG"
  cp "$TMP/scaffold.rs$ROW_TAG" "$PUSH_REPO/$reader"
  push_commit 'place production include outside crates' "$reader"
  PUSH_BEFORE=$PUSH_AFTER
  printf '\n' >>"$PUSH_REPO/$1"
  push_commit input "$1"
  PUSH_SHA="$PUSH_AFTER"
  push_world no-run "no-run$ROW_TAG"
  got="$(push_select "no-run$ROW_TAG")"
  if [[ $got != exit=* ]]; then
    got="$(field shards <"$TMP/push-out$ROW_TAG" | jq -c '
      [.[] | select(. == "refresh" or . == "orch-rest" or . == "rest" or . == "jarvis")]')"
  fi
  check "main push without merge proof selects checkout build shards for $1" "$2" "$got"
  check "main push skipped checkout suites for $1" "$3" \
    "$(field skipped_suites <"$TMP/push-out$ROW_TAG" | checkout_suites_skipped)"
  check "main push keeps the unrelated node shard off for $1" false "$(in_list shards node)"
}
main_checkout_rows() {
  local path expected skipped
  while IFS='|' read -r path expected skipped; do
    row_spawn main_checkout_row "$path" "$expected" "$skipped"
  done <<ROWS
ui/src/index.css|[]|4
skills/bot-instructions/tests/fixtures/canonical.toml|[]|4
$CHECKOUT_TEMPLATE|["refresh","orch-rest","rest","jarvis"]|0
ROWS
}
case "${1-}" in
  --checkout-reads)
    main_checkout_rows
    rows_join
    printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
    [ "$FAIL" -eq 0 ]
    exit ;;
  '') main_checkout_rows ;;
esac

# The probes and the counts each row's expectation is made of.
P_TOOLS=tools/tests/ci-skill-prose.test.sh
P_JARVIS=skills/jarvis/tests/task.test.sh
P_MERGE=skills/github/tests/pr-merge.test.sh
P_VIEW=skills/github/tests/pr-view.test.sh
P_NATIVE=skills/github/tests/native-contracts.test.sh
P_ADOPTER=refresh/tests/adopt-refresh.test.sh
# Compare proof to the committed world read by the selector, including when
# the caller has staged suite additions or deletions outside that world.
UNIVERSE="$(cd "$PUSH_REPO" && git ls-files -- ':(glob)skills/*/tests/*.sh' ':(glob)skills/*/tests/*.test.mjs' \
  ':(glob)tools/tests/*.sh' ':(glob)hooks/tests/*.sh' ':(glob)refresh/tests/*.sh' | grep -v '/run-all\.sh$')"
count() { # PREFIX — the universe suites under PREFIX
  grep -c "^$1" <<<"$UNIVERSE" || true
}
U="$(count '')"
N_TOOLS="$(count tools/tests/)"
N_JARVIS="$(count skills/jarvis/tests/)"
N_WORKTREE="$(count skills/worktree/tests/)"
N_MAILBOX="$(count skills/mailbox/tests/)"
N_SLACK="$(count skills/slack/tests/)"
N_ORCH_REST="$(cd "$ROOT" && grep '^skills/orch/tests/' <<<"$UNIVERSE" | RUNNER_OS=Linux bash skills/orch/tests/run-all.sh --shard-of 2>/dev/null | grep -c '^orch-rest ')"
WHOLE="shards=$ROSTER queue_macos_shards=$QUEUE_ALL rust_targets=$EVERY_TARGET skips=0/0"
UNREAD="main-proof=unread warned=yes"
NO_RUN="main-proof=none warned=yes"
index_row() {
  local index_group index_push
  push_world kept-subset "kept-subset$ROW_TAG"
  index_group="$(GIT_INDEX_FILE="$TMP/unavailable-index" SELECT_IN="$PUSH_REPO" SELECT_EVENT=merge_group \
    selection small false kendex.toml)"
  index_push="$(GIT_INDEX_FILE="$TMP/unavailable-index" push_select "kept-subset$ROW_TAG")"
  case "$index_push" in exit=*) cat "$TMP/push-err$ROW_TAG" >&2 ;; esac
  check "a missing Git index keeps Node and prevents same-head subtraction" "true|$WHOLE $UNREAD" \
    "$(field shards <<<"$(tr ' ' '\n' <<<"$index_group")" | jq 'index("node") != null')|$index_push"
}
row_spawn index_row
if [ "${1-}" = --inventory-proof ]; then
  rows_join
  printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
  [ "$FAIL" -eq 0 ]
  exit
fi
# The all-proved world first: its macOS count is every macOS-placed suite,
# which each later row's expectation subtracts from.
push_world all-proved
got="$(push_select all-proved)"
M="$(sed -n 's/.* skips=[0-9]*\/\([0-9]*\) .*/\1/p' <<<"$got")"
check "push route: all-proved" "shards=[] queue_macos_shards=[] rust_targets=[] skips=$U/$M main-proof=read warned=no" "$got"
check "push route: all-proved places suites on macOS" true "$([ "${M:-0}" -gt 0 ] && echo true || echo false)"
check "push route: all-proved publishes no runtime build main has" '[]' "$(field runtime_publish <"$TMP/push-out")"
# The jobs a push runs come from what it owes: no shard job and no catalog
# where the group proved them, and, since this range changes a build input,
# the jobs that save main's compile cache.
check "push route: all-proved runs no shard job or catalog, and the cache-saving jobs" "false false false true true true" \
  "$(for job in skill-suites-shard skill-suites-macos-queue catalog smoke cargo-check-windows cargo-linux; do in_list jobs "$job"; done | paste -sd ' ' -)"
# A red leg of the group's catalog check proves no catalog.
red_catalog_row() {
  push_world red-catalog "red-catalog$ROW_TAG"
  push_select "red-catalog$ROW_TAG" >/dev/null
  check "push route: a red group catalog leg owes the catalog job" true "$(in_list jobs catalog)"
}
row_spawn red_catalog_row
# WORLD|EXPECTED. A suite counts only where no selection left it out and
# every same-head leg that runs it on its runner succeeded; a target only
# where every selection listed it and the orch-rest Linux leg succeeded; any
# read that fails runs the whole roster.
push_rows=0
push_row() { # WORLD EXPECTED
  push_world "$1"
  check "push route: $1" "$2" "$(push_select "$1")"
}
while IFS='|' read -r world expected; do
  push_rows=$((push_rows + 1))
  row_spawn push_row "$world" "$expected"
done <<ROWS
kept-subset|shards=["guards-tools","guards-tools-tail"] queue_macos_shards=["guards-tools"] rust_targets=[] skips=$((U - 1))/$((M - 1)) main-proof=read warned=no
replacement-split|shards=["rest"] queue_macos_shards=["rest"] rust_targets=[] skips=$((U - 1))/$((M - 2)) main-proof=read warned=no
red-leg|shards=["orch-state","guards-hooks","guards-tools","guards-tools-tail","rest","jarvis"] queue_macos_shards=[] rust_targets=[] skips=$((U - N_TOOLS - N_JARVIS))/$M main-proof=read warned=no
linux-only|shards=[] queue_macos_shards=$QUEUE_ALL rust_targets=[] skips=$U/0 main-proof=read warned=no
no-shard-selected|$WHOLE main-proof=read warned=no
in-progress|shards=["guards-scans"] queue_macos_shards=[] rust_targets=[] skips=$U/$M main-proof=read warned=no
failed-second-run|shards=["worktree","worktree-restack"] queue_macos_shards=[] rust_targets=[] skips=$((U - N_WORKTREE))/$M main-proof=read warned=no
foreign-head-job|shards=[] queue_macos_shards=["mailbox"] rust_targets=[] skips=$U/$((M - N_MAILBOX)) main-proof=read warned=no
foreign-run-job|shards=["slack"] queue_macos_shards=[] rust_targets=[] skips=$((U - N_SLACK))/$M main-proof=read warned=no
red-orch-rest|shards=["orch-rest"] queue_macos_shards=[] rust_targets=$EVERY_TARGET skips=$((U - N_ORCH_REST))/$M main-proof=read warned=no
no-selection|$WHOLE $UNREAD
expired-selection|$WHOLE $UNREAD
bad-selection|$WHOLE $UNREAD
no-run|$WHOLE $NO_RUN
push-event-run|$WHOLE $NO_RUN
other-workflow-run|$WHOLE $NO_RUN
outage|$WHOLE $UNREAD
unparseable|$WHOLE $UNREAD
jobs-missing|$WHOLE $UNREAD
jobs-partial|$WHOLE $UNREAD
ROWS
[ "$push_rows" -ge 20 ] || { echo "the push table read $push_rows rows" >&2; exit 1; }
# A push owing only macOS shards runs the macOS job alone of the two.
macos_owed_row() {
  push_world linux-only "linux-only$ROW_TAG"
  push_select "linux-only$ROW_TAG" >/dev/null
  check "push route: macOS shards alone run the macOS shard job alone" "false true" \
    "$(in_list jobs skill-suites-shard) $(in_list jobs skill-suites-macos-queue)"
}
row_spawn macos_owed_row
# The probes: a red Linux leg owes its suites on Linux alone, and a group
# that left a suite out proves its every other suite.
red_leg_row() {
  push_world red-leg "red-leg$ROW_TAG"
  push_select "red-leg$ROW_TAG" >/dev/null
  check "push route: a red Linux leg owes its suite on Linux" false "$(in_list skipped_suites "$P_TOOLS")"
  check "push route: and its macOS leg still proves it" true "$(in_list skipped_suites_macos "$P_TOOLS")"
  check "push route: the red leg's other package owes its suites" false "$(in_list skipped_suites "$P_JARVIS")"
}
kept_subset_row() {
  push_world kept-subset "kept-subset$ROW_TAG"
  push_select "kept-subset$ROW_TAG" >/dev/null
  check "push route: the suite the group left out is owed" false "$(in_list skipped_suites "$P_TOOLS")"
  check "push route: the group's kept suites are proved" true "$(in_list skipped_suites tools/tests/ci-aggregate.test.sh)"
}
# What the push's macOS leg runs of SUITE..., through the leg's own skip list
# and native filter, or the filter's refusal.
macos_leg() { # SUITE...
  local kept status=0 err="$TMP/macos-leg-err$ROW_TAG"
  kept="$(SKIPPED_SUITES="$(field skipped_suites_macos <"$TMP/push-out$ROW_TAG")" "$JOB_SET" --suite-list "$@" |
    (cd "$ROOT" && tools/macos-test-contracts --filter) 2>"$err")" || status=$?
  [ "$status" -eq 0 ] || { sed -n 's/^macos-test-contracts: //p' "$err"; return 0; }
  printf '%s' "$kept" | paste -sd ' ' -
}
replacement_row() {
  push_world replacement-split "replacement-split$ROW_TAG"
  push_select "replacement-split$ROW_TAG" >/dev/null
  check "push route: an owed original keeps the replacement its group proved" "$P_NATIVE" \
    "$(macos_leg "$P_MERGE" "$P_NATIVE" "$P_VIEW")"
}
# The group's green legs prove each suite returned to the merge group, so
# the push leaves it out.
restored_row() {
  push_select all-proved >/dev/null
  check "push route: the group proves the restored adopter suite" true "$(in_list skipped_suites "$P_ADOPTER")"
  check "push route: the group proves the restored ownership partition" true \
    "$(in_list skipped_suites tools/tests/orch-shard-partition.test.sh)"
  check "push route: the group proves the restored deny hook" true \
    "$(in_list skipped_suites hooks/tests/critical-path-deny.test.sh)"
}
# The one-target world: the group ran orch/lib alone, so every other target
# of both runtimes runs on the push's orch-rest leg.
one_target_row() {
  push_world one-target
  check "push route: one-target" "shards=[\"orch-rest\"] queue_macos_shards=[] main-proof=read warned=no" \
    "$(push_select one-target | sed 's/ rust_targets=[^ ]* skips=[^ ]*//')"
  check "push route: one-target leaves out the proved target" false "$(in_list rust_targets orch/lib)"
  check "push route: one-target owes another orch target" true "$(in_list rust_targets orch/watch_reads)"
  check "push route: one-target owes the other runtime whole" true "$(in_list rust_targets 'agent-runtime/*')"
}
row_spawn red_leg_row
row_spawn kept_subset_row
row_spawn replacement_row
row_spawn restored_row
row_spawn one_target_row

# THE RUNTIME PUBLICATION: a push owes each package runtime build whose
# `<name>-<key>` has no unexpired artifact from a push run of this workflow
# on this repository's main or a merge-group run on one of main's queue
# branches, whatever its group proved, and runs the orch-state leg that
# publishes it. STATES|OWED: each runtime's listing state in the world, and the names
# owed; each owed name carries the key lib/key.sh gives the head's sources.
runtime_key() { # RUNTIME_DIR
  (cd "$PUSH_REPO" && refuse() { exit 1; } && . skills/agent-runtime/scripts/lib/key.sh && agent_runtime_key "$1")
}
KEYS="$(jq -cn --arg a "$(runtime_key skills/agent-runtime/runtime)" --arg o "$(runtime_key skills/orch/runtime)" \
  '{"agent-runtime": $a, "orch-runtime": $o}')"
publish_world() { # STATES — a world from all-proved, its listing states set, named publish and the row's tag
  local state world="$TMP/push/publish$ROW_TAG"
  rm -rf -- "${world:?}"
  cp -R "$TMP/push/all-proved" "$world"
  for state in $1; do printf '%s\n' "${state#*=}" >"$world/runtime-${state%%=*}"; done
}
owed_publish() { # OWED — the runtime_publish value naming OWED
  jq -c --argjson keys "$KEYS" 'map({name: ., key: $keys[.]})' <<<"$1"
}
publish_rows=0
publish_row() { # STATES OWED
  publish_world "$1"
  push_select "publish$ROW_TAG" >/dev/null
  check "runtime publication: $1" "shards=[\"orch-state\"] runtime_publish=$(owed_publish "$2")" \
    "shards=$(field shards <"$TMP/push-out$ROW_TAG") runtime_publish=$(field runtime_publish <"$TMP/push-out$ROW_TAG")"
  # The publishing leg alone still runs the Linux shard job.
  check "runtime publication: $1 runs the Linux shard job alone" "true false" \
    "$(in_list jobs skill-suites-shard) $(in_list jobs skill-suites-macos-queue)"
}
while IFS='|' read -r states owed; do
  publish_rows=$((publish_rows + 1))
  row_spawn publish_row "$states" "$owed"
done <<'ROWS'
agent-runtime=none|["agent-runtime"]
agent-runtime=fork orch-runtime=expired|["agent-runtime","orch-runtime"]
agent-runtime=queue orch-runtime=unread|["orch-runtime"]
agent-runtime=pull-request-main|["agent-runtime"]
agent-runtime=pull-request-queue orch-runtime=queue-other-base|["agent-runtime","orch-runtime"]
agent-runtime=feature-push|["agent-runtime"]
agent-runtime=other-workflow orch-runtime=run-unread|["agent-runtime","orch-runtime"]
ROWS
[ "$publish_rows" -eq 7 ] || { echo "the publication table read $publish_rows rows" >&2; exit 1; }
# A copy of the selector with one edit to PUBLISHED_RUN, or a refusal where
# the edit no longer matches one condition.
filter_copy() { # NAME FROM TO
  mkdir -p "$TMP/$1/tools"
  cp -R "$ROOT/tools/lib" "$TMP/$1/tools/lib"
  cp "$ROOT/tools/rust-reads" "$ROOT/tools/macos-test-contracts" "$ROOT/tools/macos-test-contracts.json" "$ROOT/tools/guard" "$TMP/$1/tools/"
  FROM="$2" TO="$3" awk '/^PUBLISHED_RUN=/ { on = 1 } on { n += gsub(ENVIRON["FROM"], ENVIRON["TO"]) } /\$path.$/ { on = 0 } { print } END { exit n != 1 }' \
    "$JOB_SET" >"$TMP/$1/tools/ci-job-set" ||
    { echo "PUBLISHED_RUN no longer holds one '$2' in $JOB_SET" >&2; exit 1; }
  chmod +x "$TMP/$1/tools/ci-job-set"
}
# Control: a selector that takes a push of any event as main's counts a
# pull-request run whose head branch is named main as published.
filter_copy any-event '\(\.event == "push" and ' '('
any_event_row() {
  publish_world agent-runtime=pull-request-main
  push_select "publish$ROW_TAG" "$TMP/any-event/tools/ci-job-set" >/dev/null
  check "control: a selector taking any event's run owes no agent-runtime build" '[]' "$(field runtime_publish <"$TMP/push-out$ROW_TAG")"
}
row_spawn any_event_row

# THE MERGE GROUP'S PUBLICATION: under --runtime-publish a class selection
# owes the same builds and adds the orch-state leg to its Linux shards in
# roster order, never to its macOS list, so the group that proves a head
# publishes its keys before main moves. The path selects shards on both
# runners and no orch-state leg of its own. Each call is the changes job's.
GROUP_PATH=skills/youtube-publish/scripts/youtube-publish
UNREAD_DOC="docs/no-reader"".md"
GROUP_SELECTION="$TMP/group-selection.json"
group_select() { # STATES [SELECTOR [CLASS PATH]] — the selection, micro over GROUP_PATH unless named, in a world from all-proved
  publish_world "$1"
  : >"$GROUP_SELECTION$ROW_TAG"
  PATH="$TMP/gh-stub:$PATH" GH_WORLD="$TMP/push/publish$ROW_TAG" GITHUB_REPOSITORY=vanillagreencom/kendex \
    CI_SELECTION="$GROUP_SELECTION$ROW_TAG" SELECT_IN="$PUSH_REPO" SELECT_WITH="${2:-$JOB_SET}" SELECT_EVENT=merge_group \
    SELECT_ARG="--event-parity --runtime-publish" selection "${3:-micro}" false "${4:-$GROUP_PATH}"
}
group_base="$(SELECT_IN="$PUSH_REPO" SELECT_EVENT=merge_group selection micro false "$GROUP_PATH")"
group_shards="$(field shards <<<"$(tr ' ' '\n' <<<"$group_base")")"
group_queue="$(field queue_macos_shards <<<"$(tr ' ' '\n' <<<"$group_base")")"
[ "$(jq 'index("orch-state") == null and length > 0' <<<"$group_shards")" = true ] &&
  [ "$group_queue" != '[]' ] ||
  { echo "$GROUP_PATH no longer selects shards on both runners and no orch-state leg: $group_base" >&2; exit 1; }
row_spawn check "a selection without --runtime-publish publishes no runtime line" '' \
  "$(tr ' ' '\n' <<<"$group_base" | field runtime_publish)"
with_leg="$(jq -c --argjson roster "$ROSTER" '. as $s | [$roster[] | select(. == "orch-state" or (. as $r | $s | index($r)))]' <<<"$group_shards")"
group_row() { # SELECTION — `shards=… queue_macos_shards=… runtime_publish=…`
  local lines
  lines="$(tr ' ' '\n' <<<"$1")"
  printf 'shards=%s queue_macos_shards=%s runtime_publish=%s' "$(field shards <<<"$lines")" \
    "$(field queue_macos_shards <<<"$lines")" "$(field runtime_publish <<<"$lines")"
}
# STATES|SHARDS|OWED
group_rows=0
group_publish_row() { # STATES SHARDS OWED
  check "merge-group publication: $1" \
    "shards=$2 queue_macos_shards=$group_queue runtime_publish=$(owed_publish "$3")" \
    "$(group_row "$(group_select "$1")")"
}
while IFS='|' read -r states shards owed; do
  group_rows=$((group_rows + 1))
  row_spawn group_publish_row "$states" "$shards" "$owed"
done <<ROWS
agent-runtime=none orch-runtime=queue|$with_leg|["agent-runtime"]
agent-runtime=queue|$group_shards|[]
ROWS
[ "$group_rows" -eq 2 ] || { echo "the merge-group publication table read $group_rows rows" >&2; exit 1; }
# A path outside suite reach adds the publishing leg without any suites.
# A workflow input selects the whole roster, which includes that same leg.
# The group's selection records the same skips, so the push at its head
# counts no skipped suite proved. CLASS|PATH|STATES|SHARDS|QUEUE|OWED|LEG
ORCH_CANDIDATES="$(cd "$ROOT" && git ls-files -- ':(glob)skills/orch/tests/*.sh' | awk '!/\/run-all\.sh$/')"
LEG_ALL="$(cd "$ROOT" && RUNNER_OS=Linux bash skills/orch/tests/run-all.sh --shard-of <<<"$ORCH_CANDIDATES" |
  awk '$1 == "orch-state" { print $2 }' | paste -sd ' ' -)"
[ -n "$LEG_ALL" ] || { echo "run-all.sh places no suite in orch-state on Linux" >&2; exit 1; }
leg_runs() { # SKIPS — the orch-state suites the shard step runs under SKIPS, space-joined, or `refused`
  local kept suite runs=""
  # A skip list --suite-list refuses fails the shard step, so it is no
  # empty run.
  # shellcheck disable=SC2086 # one candidate per word
  if ! kept=" $(cd "$ROOT" && SKIPPED_SUITES="$1" "$JOB_SET" --suite-list $ORCH_CANDIDATES 2>"$TMP/leg-err$ROW_TAG" | paste -sd ' ' -) "; then
    printf 'refused'
    return 0
  fi
  for suite in $LEG_ALL; do
    case "$kept" in *" $suite "*) runs="${runs:+$runs }$suite" ;; esac
  done
  printf '%s' "$runs"
}
row_spawn check "control: a skip list --suite-list refuses reads as refused" refused "$(leg_runs '"[]"')"
verify_rows=0
verify_row() { # CLASS PATH STATES SHARDS QUEUE OWED LEG
  local lines skips
  lines="$(tr ' ' '\n' <<<"$(group_select "$3" "$JOB_SET" "$1" "$2")")"
  skips="$(field skipped_suites <<<"$lines")"
  check "merge-group publication on $1 $2: $3" \
    "shards=$4 queue_macos_shards=$5 runtime_publish=$(owed_publish "$6") leg=$7 selection_skips=$skips" \
    "shards=$(field shards <<<"$lines") queue_macos_shards=$(field queue_macos_shards <<<"$lines") runtime_publish=$(field runtime_publish <<<"$lines") leg=$(leg_runs "$skips") selection_skips=$(jq -c .skipped_suites "$GROUP_SELECTION$ROW_TAG" 2>/dev/null)"
}
while IFS='|' read -r class path states shards queue owed leg; do
  verify_rows=$((verify_rows + 1))
  row_spawn verify_row "$class" "$path" "$states" "$shards" "$queue" "$owed" "$leg"
done <<ROWS
render|README.md|agent-runtime=none orch-runtime=queue|["orch-state"]|[]|["agent-runtime"]|
trivial|$UNREAD_DOC|agent-runtime=none|$ROSTER|$QUEUE_ALL|["agent-runtime"]|$LEG_ALL
standard|.github/workflows/skill-tests.yml|agent-runtime=none|$ROSTER|$QUEUE_ALL|["agent-runtime"]|$LEG_ALL
render|README.md|agent-runtime=queue|[]|[]|[]|
ROWS
[ "$verify_rows" -eq 4 ] || { echo "the render and trivial publication table read $verify_rows rows" >&2; exit 1; }
# Control: a selector whose filter admits no merge-group run owes the build
# the queue run published.
filter_copy no-queue '\(\.event == "merge_group" and ' '(false and '
no_queue_row() {
  check "control: a selector admitting no merge-group run owes the queue's orch-runtime build" \
    "$(owed_publish '["agent-runtime","orch-runtime"]')" \
    "$(tr ' ' '\n' <<<"$(group_select "agent-runtime=none orch-runtime=queue" "$TMP/no-queue/tools/ci-job-set")" | field runtime_publish)"
}
row_spawn no_queue_row

# THE SAME CHANGE ON BOTH EVENTS: the push's head changes GROUP_PATH alone
# past main's last tested push, so its range is the group's diff. After a
# passed group, with the selection the group's changes job published over
# that diff, the push owes no job; a direct push with no group runs what its
# range selects and every job no group proved.
same_change_row() {
  local group="$TMP/same-change-selection$ROW_TAG" class lines
  own_push_repo
  printf '\n# input\n' >>"$PUSH_REPO/$GROUP_PATH"
  push_commit 'one change' "$GROUP_PATH"
  PUSH_SHA=$PUSH_AFTER
  class="$(CI_SELECTION="$group" SELECT_IN="$PUSH_REPO" SELECT_EVENT=merge_group SELECT_ARG=--event-parity \
    selection micro false "$GROUP_PATH")"
  lines="$(tr ' ' '\n' <<<"$class")"
  push_world all-proved "same-change$ROW_TAG"
  plant_selection "$TMP/push/same-change$ROW_TAG" "$PUSH_RUN" "$(jq -c .skipped_suites "$group")" \
    "$(jq -c .rust_targets "$group")"
  check "push after a passed merge group of the same change" \
    "shards=[] queue_macos_shards=[] rust_targets=[] main-proof=read warned=no jobs=[]" \
    "$(push_select "same-change$ROW_TAG" | sed 's/ skips=[^ ]*//') jobs=$(field jobs <"$TMP/push-out$ROW_TAG")"
  push_world no-run "same-change-direct$ROW_TAG"
  check "direct push with no merge group runs its range's shards and every job" \
    "main-proof=none shards=$(field shards <<<"$lines") queue_macos_shards=$(field queue_macos_shards <<<"$lines") true true true true" \
    "$(push_select "same-change-direct$ROW_TAG" | sed -n 's/.*\(main-proof=[a-z]*\).*/\1/p') shards=$(field shards <"$TMP/push-out$ROW_TAG") queue_macos_shards=$(field queue_macos_shards <"$TMP/push-out$ROW_TAG") $(for job in skill-suites-shard catalog smoke cargo-check-windows; do in_list jobs "$job"; done | paste -sd ' ' -)"
}
row_spawn same_change_row
# A push that lands two groups: the head's group checked catalog's upgrade
# from its own base, the head's parent, and the push owes it from the commit
# main held before, two first-parent commits back.
two_group_row() {
  own_push_repo
  printf '\n# first group\n' >>"$PUSH_REPO/$GROUP_PATH"
  push_commit 'first group' "$GROUP_PATH"
  printf '\n# second group\n' >>"$PUSH_REPO/$GROUP_PATH"
  push_commit 'second group' "$GROUP_PATH"
  PUSH_SHA=$PUSH_AFTER
  push_world all-proved "two-groups$ROW_TAG"
  check "push landing two groups owes the catalog the head's group proved" 'main-proof=read jobs=["catalog"]' \
    "$(push_select "two-groups$ROW_TAG" | sed -n 's/.*\(main-proof=[a-z]*\).*/\1/p') jobs=$(field jobs <"$TMP/push-out$ROW_TAG")"
}
row_spawn two_group_row

# Control: a selector that trusts each job's head without checking it counts
# a foreign head's success as proof, so the foreign-head-job row fails.
mkdir -p "$TMP/trusting/tools"
cp -R "$ROOT/tools/lib" "$TMP/trusting/tools/lib"
cp "$ROOT/tools/rust-reads" "$ROOT/tools/macos-test-contracts" "$ROOT/tools/macos-test-contracts.json" "$TMP/trusting/tools/"
cp "$ROOT/tools/guard" "$TMP/trusting/tools/"
awk '{ n += gsub(/select\(\.head_sha == \$sha and \.run_id == \$id\)/, "select(.run_id == $id)") } { print } END { exit n != 1 }' \
  "$JOB_SET" >"$TMP/trusting/tools/ci-job-set" ||
  { echo "the job head check is no longer one select in $JOB_SET" >&2; exit 1; }
chmod +x "$TMP/trusting/tools/ci-job-set"
trusting_row() {
  push_world foreign-head-job "foreign-head-job$ROW_TAG"
  case "$(push_select "foreign-head-job$ROW_TAG" "$TMP/trusting/tools/ci-job-set")" in
    *"queue_macos_shards=[] "*) ok "control: a selector skipping the job head check proves the foreign head's mailbox leg" ;;
    *) bad "control: the head-check mutant did not prove the foreign head's leg" ;;
  esac
}
row_spawn trusting_row

# The rows below read this no-run world; the table's own may still be written.
push_world no-run tail
# Path selection precedes proof subtraction, including a narrowed whole leg.
reach_row() { # PATH REQUIRED FORBIDDEN BUILD
  local got
  own_push_repo
  mkdir -p "$PUSH_REPO/$(dirname "$1")"
  printf '\nchanged\n' >>"$PUSH_REPO/$1"
  push_commit path "$1"
  push_select tail >/dev/null
  check "main build reach: $1" "cache_compile=$4" "$(grep '^cache_compile=' "$TMP/push-out$ROW_TAG")"
  got="$(sed -n 's/^shards=//p' "$TMP/push-out$ROW_TAG")"
  if jq -e --arg req "$2" --arg forbid "$3" '(($req == "" or index($req) != null) and ($forbid == "" or index($forbid) == null))' <<<"$got" >/dev/null; then
    ok "main path reach: $1"
  else bad "main path reach: $1 ($got)"; fi
}
while IFS='|' read -r path required forbidden build; do
  row_spawn reach_row "$path" "$required" "$forbidden" "$build"
done <<ROWS
.kendex-lock.json||rest|false
crates/core/src/lib.rs|rest|node|true
pi-extensions/pi-agents-tmux/index.ts|node|linear|false
$UNREAD_DOC|review-gate||false
ROWS
saved_after="$PUSH_AFTER"
PUSH_AFTER=0000000000000000000000000000000000000000
check "unread push range refuses selection" exit=2 "$(push_select all-proved)"
PUSH_AFTER="$saved_after"
# Copies of the selector and of the guard it asks, each with one edit.
control_copy() { # NAME
  mkdir -p "$TMP/$1/tools"
  cp -R "$ROOT/tools/lib" "$TMP/$1/tools/lib"
  cp "$ROOT/tools/rust-reads" "$ROOT/tools/macos-test-contracts" "$ROOT/tools/macos-test-contracts.json" \
    "$ROOT/tools/guard" "$JOB_SET" "$TMP/$1/tools/"
}
# Must-fail: retain matched path logic but force every shard selected on main.
control_copy main-control
awk -v roster="$ROSTER" '/^  main_linux=\$SHELL_SHARDS$/ { print; print "  main_linux=" sprintf("%c", 39) roster sprintf("%c", 39); n++; next } { print } END { exit n != 1 }' "$JOB_SET" >"$TMP/main-control/tools/ci-job-set"
control_copy guard-control
sed '/^    if \[ "\$f" = \.kendex-lock\.json \]; then$/,/^    fi$/d' "$ROOT/tools/guard" >"$TMP/guard-control/tools/guard"
! cmp -s "$ROOT/tools/guard" "$TMP/guard-control/tools/guard" || exit 1
lock_row() {
  own_push_repo
  printf 'lock\n' >"$PUSH_REPO/.kendex-lock.json"
  push_commit lock .kendex-lock.json
  push_select tail >/dev/null
  check "lock-only push runs no shard" 'shards=[]' "$(grep '^shards=' "$TMP/push-out$ROW_TAG")"
  push_select tail "$TMP/main-control/tools/ci-job-set" >/dev/null
  if grep -qxF 'shards=[]' "$TMP/push-out$ROW_TAG"; then bad 'must-fail: main selection mutant escaped'; else ok 'must-fail: main selection mutant runs forbidden lock-only shards'; fi
}
guard_control_row() {
  own_push_repo
  printf 'lock\n' >"$PUSH_REPO/.kendex-lock.json"
  push_commit lock .kendex-lock.json
  push_select tail "$TMP/guard-control/tools/ci-job-set" >/dev/null
  check 'control: install record reach runs suites that construct their own records' true "$(in_list shards node)"
}
row_spawn lock_row
row_spawn guard_control_row

# A pending first push can be replaced by a lock-only second push. The
# successful baseline still precedes both, so the first input remains owed.
control_copy event-control
awk '{ n += sub(/git diff --name-only --no-renames "\$PREVIOUS_PUSH"/, "git diff --name-only --no-renames \"$PUSH_BEFORE\"") } { print } END { exit n != 1 }' \
  "$JOB_SET" >"$TMP/event-control/tools/ci-job-set"
coalesce() { # PATH TEXT — a push of TEXT onto PATH, then a lock-only push after it
  own_push_repo
  printf '%s' "$2" >>"$PUSH_REPO/$1"
  push_commit pending "$1"
  PUSH_BEFORE=$PUSH_AFTER
  printf 'lock\n' >"$PUSH_REPO/.kendex-lock.json"
  push_commit newest .kendex-lock.json
}
coalesced_node_row() {
  coalesce .bun-version $'fixture\n'
  push_select tail >/dev/null
  check 'coalesced unproved push retains the replaced heads node work' true "$(in_list shards node)"
  push_select tail "$TMP/event-control/tools/ci-job-set" >/dev/null
  check 'control: event before alone loses the replaced heads node work' false "$(in_list shards node)"
}
coalesced_runtime_row() {
  local history world="tail$ROW_TAG"
  coalesce skills/agent-runtime/runtime/src/lib.rs $'\n// input\n'
  push_select tail >/dev/null
  check 'coalesced unproved runtime retains the dependent orch targets' true "$(field rust_targets <"$TMP/push-out$ROW_TAG" | jq 'any(.[]; startswith("orch/"))')"
  push_select tail "$TMP/event-control/tools/ci-job-set" >/dev/null
  check 'control: event before alone loses the replaced heads Rust targets' '[]' "$(field rust_targets <"$TMP/push-out$ROW_TAG")"
  cp -R "$TMP/push/tail" "$TMP/push/$world"
  for history in absent unread; do
    case "$history" in
      absent) printf '{"workflow_runs":[]}\n' >"$TMP/push/$world/push-runs.json" ;;
      unread) printf 'unread\n' >"$TMP/push/$world/push-runs.json" ;;
    esac
    push_select "$world" >/dev/null
    check "unproved coalesced range $history runs the full roster" "$ROSTER" "$(field shards <"$TMP/push-out$ROW_TAG")"
    check "unproved coalesced range $history retains every runtime" "$EVERY_TARGET" "$(field rust_targets <"$TMP/push-out$ROW_TAG")"
  done
}
row_spawn coalesced_node_row
row_spawn coalesced_runtime_row
# The night rows below rewrite the no-run world a table row reads.
rows_join

# Only the latest successful scheduled main run can stand a night down.
# A history with competing heads must reject an older matching success.
awk '/length > 0/ { n += sub(/sort_by\(\.created_at\) \| last \|/, "sort_by(.created_at) | first |") } { print } END { exit n != 1 }' \
  "$JOB_SET" >"$TMP/trusting/tools/ci-job-set"
jq --arg sha "$PUSH_SHA" '.workflow_runs[].head_sha = $sha' "$DATA/main-proof-runs.json" >"$TMP/night-runs.json"
while IFS='|' read -r row mutation expected; do
  jq "$mutation" "$TMP/night-runs.json" >"$TMP/push/no-run/runs.json"
  : >"$TMP/nightly-out"
  PATH="$TMP/gh-stub:$PATH" GH_WORLD="$TMP/push/no-run" EVENT=schedule GITHUB_RUN_ID=999 GITHUB_SHA="$PUSH_SHA" GITHUB_REPOSITORY=vanillagreencom/kendex GITHUB_OUTPUT="$TMP/nightly-out" "$JOB_SET"
  check "nightly $row" "nightly=$expected" "$(sed -n '/^nightly=/p' "$TMP/nightly-out")"
  # A night stood down runs no job; one owed runs the nightly macOS roster.
  night_jobs="$(sed -n 's/^jobs=//p' "$TMP/nightly-out" | jq -c 'if . == [] then "none" else index("skill-suites-macos") != null end')"
  check "nightly $row jobs" "$([ "$expected" = true ] && echo true || echo '"none"')" "$night_jobs"
  if [ "$row" = older-match-newest-different ]; then
    : >"$TMP/nightly-control-out"
    PATH="$TMP/gh-stub:$PATH" GH_WORLD="$TMP/push/no-run" EVENT=schedule GITHUB_RUN_ID=999 GITHUB_SHA="$PUSH_SHA" GITHUB_REPOSITORY=vanillagreencom/kendex GITHUB_OUTPUT="$TMP/nightly-control-out" "$TMP/trusting/tools/ci-job-set"
    check "must-fail: oldest successful night skips a head the latest night did not test" nightly=false "$(sed -n '/^nightly=/p' "$TMP/nightly-control-out")"
  fi
done <<'ROWS'
equal|.workflow_runs[0] += {event:"schedule",head_branch:"main",status:"completed",conclusion:"success",created_at:"2026-11-15T02:00:00Z"}|false
different|.workflow_runs[0] += {event:"schedule",head_branch:"main",status:"completed",conclusion:"success",created_at:"2026-11-15T02:00:00Z",head_sha:"other"}|true
older-match-newest-different|.workflow_runs = [(.workflow_runs[0] + {id:1,event:"schedule",head_branch:"main",status:"completed",conclusion:"success",created_at:"2026-11-14T02:00:00Z"}),(.workflow_runs[0] + {id:2,event:"schedule",head_branch:"main",status:"completed",conclusion:"success",created_at:"2026-11-15T02:00:00Z",head_sha:"other"})]|true
newest-match-older-different|.workflow_runs = [(.workflow_runs[0] + {id:2,event:"schedule",head_branch:"main",status:"completed",conclusion:"success",created_at:"2026-11-15T02:00:00Z"}),(.workflow_runs[0] + {id:1,event:"schedule",head_branch:"main",status:"completed",conclusion:"success",created_at:"2026-11-14T02:00:00Z",head_sha:"other"})]|false
push-success|.workflow_runs[0].event = "push"|true
no-success|.workflow_runs = []|true
unread|del(.workflow_runs)|true
ROWS

# THE NIGHT'S FAULT REPORT: a night run, NIGHT_RUN, whose jobs are the
# group's recorded legs run whole at the same head, judged against the
# group's record in a push world. A failed check the head's merge group did
# not run is a selector fault naming the commit and the check; one the group
# ran whole is an ordinary red night. Each stdout line is the report's
# program-read output; a targets fault's count follows the runtime
# inventory, so the rows leave it out.
NIGHT_RUN=999
NIGHT_LEG='Skill suites shard (guards-tools, ubuntu-latest)'
# `<stdout lines, ;-joined>|<night-faults state>[ <cause key>]`.
night_faults_row() { # LABEL WORLD GROUP_EDIT NIGHT_EDIT EXPECTED
  local tag="night$night_rows" dir out err status=0
  dir="$TMP/push/$tag"
  push_world "$2" "$tag"
  if [ -f "$dir/jobs-$PUSH_RUN.json" ]; then
    jq "$3" "$dir/jobs-$PUSH_RUN.json" >"$dir/group.json" && mv "$dir/group.json" "$dir/jobs-$PUSH_RUN.json"
  fi
  jq --argjson id "$NIGHT_RUN" --arg sha "$PUSH_SHA" \
    '.jobs |= map(.run_id = $id | .head_sha = $sha | .status = "completed" | .conclusion = "success")' \
    "$TMP/push-jobs.json" | jq "$4" >"$dir/jobs-$NIGHT_RUN.json"
  out="$(cd "$PUSH_REPO" && PATH="$TMP/gh-stub:$PATH" GH_WORLD="$dir" GITHUB_REPOSITORY=vanillagreencom/kendex \
    GITHUB_SHA="$PUSH_SHA" GITHUB_RUN_ID="$NIGHT_RUN" "$JOB_SET" --night-faults 2>"$dir/err")" || status=$?
  [ "$status" -eq 0 ] || out="exit=$status"
  # Each fault reaches the run as an `::error` annotation whose message is
  # the fault line's fields, and an unread record as one `::warning`, which
  # GitHub's runner parses out of the step's stdout.
  err="$(sed -n 's/^ci-job-set: night-faults=\([a-z]*\) .*\( cause=[a-z-]*\).*/\1\2/p; s/^ci-job-set: night-faults=\([a-z]*\) [^c]*$/\1/p' "$dir/err")"
  if [ "$(printf '%s\n' "$out" | sed -n 's/^selector-fault //p')" != "$(printf '%s\n' "$out" | sed -n 's/^::error title=[^:]*:://p')" ]; then
    out=annotation-mismatch
  elif [ "$(printf '%s\n' "$out" | grep -c '^::warning ')" != "$([ "${err%% *}" = unread ] && echo 1 || echo 0)" ]; then
    out=warning-mismatch
  fi
  out="$(printf '%s\n' "$out" | { grep -v '^::' || true; } | sed "s/commit=$PUSH_SHA /commit=HEAD /; s/ count=[0-9]*$//" | paste -sd ';' -)"
  check "night faults: $1" "$5" "$out|$err"
}
night_fail() { # NAME [CONCLUSION] — the night edit ending NAME red, `failure` unless named
  printf '.jobs |= map(if .name == "%s" then .conclusion = "%s" else . end)' "$1" "${2:-failure}"
}
group_drop() { # NAME — the group edit removing NAME
  printf '.jobs |= map(select(.name != "%s"))' "$1"
}
# The catalog legs a merge group splits in two and a night runs as one.
CATALOG_APART='.jobs |= map(if .name == "catalog (1/2) / kendex check" then .name = "catalog (1/1) / kendex check" | .conclusion = "failure" else select(.name != "catalog (2/2) / kendex check") end)'
# LABEL@WORLD@GROUP_EDIT@NIGHT_EDIT@EXPECTED, `@` apart since the edits are jq.
night_rows=0
while IFS='@' read -r label world group night expected; do
  night_rows=$((night_rows + 1))
  night_faults_row "$label" "$world" "$group" "$night" "$expected"
done <<ROWS
no failed check@all-proved@.@.@|read
a leg the group ran whole@all-proved@.@$(night_fail "$NIGHT_LEG")@night-red commit=HEAD check=$NIGHT_LEG selector=ran|read
a job the group did not run@all-proved@$(group_drop 'UI (vitest, tsc, biome)')@$(night_fail 'UI (vitest, tsc, biome)')@selector-fault commit=HEAD check=UI (vitest, tsc, biome) skipped=job|read
a shard the group did not select@all-proved@$(group_drop "$NIGHT_LEG")@$(night_fail "$NIGHT_LEG")@selector-fault commit=HEAD check=$NIGHT_LEG skipped=leg|read
a cancelled leg the group did not select@all-proved@$(group_drop "$NIGHT_LEG")@$(night_fail "$NIGHT_LEG" cancelled)@selector-fault commit=HEAD check=$NIGHT_LEG skipped=leg|read
a suite the group's selection skipped@kept-subset@.@$(night_fail "$NIGHT_LEG")@selector-fault commit=HEAD check=$NIGHT_LEG skipped=suites|read
a runtime target the group's selection left out@one-target@.@$(night_fail 'Skill suites shard (orch-rest, ubuntu-latest)')@selector-fault commit=HEAD check=Skill suites shard (orch-rest, ubuntu-latest) skipped=targets|read
the orch-rest leg with every target held@all-proved@.@$(night_fail 'Skill suites shard (orch-rest, ubuntu-latest)')@night-red commit=HEAD check=Skill suites shard (orch-rest, ubuntu-latest) selector=ran|read
another package's targets held whole@one-package@.@$(night_fail 'Skill suites shard (orch-rest, ubuntu-latest)')@selector-fault commit=HEAD check=Skill suites shard (orch-rest, ubuntu-latest) skipped=targets|read
legs named apart from the night's@all-proved@.@$CATALOG_APART@night-red commit=HEAD check=catalog (1/1) / kendex check selector=ran|read
a failed classifier, no lane@all-proved@.@$(night_fail 'Classify the diff')@|read
no merge group at the head@no-run@.@$(night_fail "$NIGHT_LEG")@night-red commit=HEAD check=$NIGHT_LEG selector=none|none cause=no-merge-group-run
the group's jobs unread@jobs-missing@.@$(night_fail "$NIGHT_LEG")@night-red commit=HEAD check=$NIGHT_LEG selector=unread|unread cause=jobs-read-failed
the night's own jobs unread@outage@.@.@|unread cause=night-jobs-unread
ROWS
[ "$night_rows" -ge 14 ] || { echo "the night fault table read $night_rows rows" >&2; exit 1; }

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
