#!/usr/bin/env bash
# Surface: refresh-ci-proof. Inputs: harness-ci's shared caller and range owner.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -- "$TEST_DIR/../../.." && pwd -P)"
source "$TEST_DIR/lib/assertions.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'refresh-ci-proof.test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "refresh-ci-proof.test: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'refresh-ci-proof.test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

mkdir -p "$TMP_ROOT/bin" "$TMP_ROOT/skills/orch/scripts" "$TMP_ROOT/skills/harness-ci/scripts/lib"
SCRIPT="$TMP_ROOT/skills/orch/scripts/refresh-ci-proof"
cp "$REPO_ROOT/skills/orch/scripts/refresh-ci-proof" "$SCRIPT"
cp "$REPO_ROOT/skills/harness-ci/scripts/lib/change-class.sh" "$TMP_ROOT/skills/harness-ci/scripts/lib/"
cp "$REPO_ROOT/skills/harness-ci/scripts/harness-only" "$TMP_ROOT/skills/harness-ci/scripts/"
FIXTURE="$TMP_ROOT/repo"
git init -q "$FIXTURE"
git -C "$FIXTURE" config user.email test@example.com
git -C "$FIXTURE" config user.name test
git -C "$FIXTURE" config gc.auto 0
git -C "$FIXTURE" config maintenance.auto false
printf 'old\n' > "$FIXTURE/product"
git -C "$FIXTURE" add product
git -C "$FIXTURE" commit -qm root
EARLIER_BASE="$(git -C "$FIXTURE" rev-parse HEAD)"
printf 'new\n' > "$FIXTURE/product"
git -C "$FIXTURE" commit -qam product
MEASURED_BASE="$(git -C "$FIXTURE" rev-parse HEAD)"
mkdir -p "$FIXTURE/.agents"
printf 'render\n' > "$FIXTURE/.agents/render"
git -C "$FIXTURE" add .agents
git -C "$FIXTURE" commit -qm render
HEAD_SHA="$(git -C "$FIXTURE" rev-parse HEAD)"
git -C "$FIXTURE" checkout -q --detach "$MEASURED_BASE"
printf 'base advance\n' > "$FIXTURE/base-only"
git -C "$FIXTURE" add base-only
git -C "$FIXTURE" commit -qm base-advance
BASE_TIP="$(git -C "$FIXTURE" rev-parse HEAD)"
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$WORLD/calls"
case "$*" in
  'api repos/o/r/pulls/42')
    if [[ -e $WORLD/pr-read ]]; then cat "$WORLD/live.json"
    else touch "$WORLD/pr-read"; cat "$WORLD/pr.json"; fi ;;
  'api repos/o/r/pulls/42/files?per_page=100 --paginate --slurp') cat "$WORLD/files.json" ;;
  'api repos/o/r/commits/'*'/check-runs?check_name=Classify%20the%20diff&filter=latest&per_page=100 --paginate --slurp') cat "$WORLD/checks.json" ;;
  'api repos/o/r/actions/jobs/72') cat "$WORLD/job.json" ;;
  'api repos/o/r/actions/jobs/74') cat "$WORLD/extra-job.json" ;;
  'api repos/o/r/actions/runs/20') cat "$WORLD/run.json" ;;
  'api repos/o/r/actions/runs/30') cat "$WORLD/extra-run.json" ;;
  'api repos/o/r/actions/jobs/72/logs --allow-escape-sequences')
    [[ ! -e $WORLD/log-failed ]] || exit 1
    cat "$WORLD/log"
    ;;
  'api repos/o/r/actions/jobs/74/logs --allow-escape-sequences') cat "$WORLD/extra-log" ;;
  'api repos/o/r/actions/jobs/'*'/logs') exit 1 ;;
  *) printf 'fixture: unexpected=%s\n' "$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/gh"

world() {
  WORLD="$TMP_ROOT/world"
  rm -rf -- "$WORLD"
  mkdir -p "$WORLD"
  jq -n --arg head "$HEAD_SHA" --arg base "$BASE_TIP" '{head:{sha:$head},base:{sha:$base,ref:"main"},body:"Engine version: `kendex 1.13.0`.",changed_files:1}' > "$WORLD/pr.json"
  printf '[[{"filename":".agents/skills/orch/SKILL.md"}]]\n' > "$WORLD/files.json"
  jq -n --arg head "$HEAD_SHA" '[{total_count:1,check_runs:[{id:72,name:"Classify the diff",app:{slug:"github-actions"},head_sha:$head,status:"completed",conclusion:"success"}]}]' > "$WORLD/checks.json"
  jq -n --arg head "$HEAD_SHA" '{id:72,run_id:20,name:"Classify the diff",head_sha:$head,status:"completed",conclusion:"success"}' > "$WORLD/job.json"
  jq -n --arg head "$HEAD_SHA" --arg base "$BASE_TIP" '{id:20,path:".github/workflows/ci.yml",event:"pull_request",head_sha:$head,repository:{full_name:"o/r"},pull_requests:[{number:42,head:{sha:$head},base:{sha:$base}}]}' > "$WORLD/run.json"
  printf '2026-10-09T08:00:00.000Z ##[group]Run \033[36;1mclassify the diff\033[0m\r\n' > "$WORLD/log"
  printf '%s\r\n' \
    '2026-10-09T08:00:00.000Z render-verifier: verifier=path version=1.13.0' \
    '2026-10-09T08:00:01.000Z class: class=render measured=true cause=render-proof' >> "$WORLD/log"
  printf '2026-10-09T08:00:00.000Z base-rev: %s\r\n2026-10-09T08:00:00.000Z head-rev: %s\r\n' "$MEASURED_BASE" "$HEAD_SHA" >> "$WORLD/log"
  case "$1" in
    render) ;;
    caller) printf '[[{"filename":".github/workflows/kendex-refresh.yml"}]]\n' > "$WORLD/files.json" ;;
    workflow) printf '[[{"filename":".github/workflows/ci.yml"}]]\n' > "$WORLD/files.json" ;;
    renamed-workflow) printf '[[{"filename":"elsewhere.yml","previous_filename":".github/workflows/ci.yml"}]]\n' > "$WORLD/files.json" ;;
    partial-files) printf '[[]]\n' > "$WORLD/files.json" ;;
    later-workflow) printf '[[{"filename":".agents/skills/orch/SKILL.md"}],[{"filename":".github/workflows/ci.yml"}]]\n' > "$WORLD/files.json"; jq '.changed_files=2' "$WORLD/pr.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/pr.json" ;;
    engine) sed 's/version=1.13.0/version=1.14.0/' "$WORLD/log" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/log" ;;
    body-missing) jq '.body=""' "$WORLD/pr.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/pr.json" ;;
    standard) sed 's/class=render/class=standard/' "$WORLD/log" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/log" ;;
    unmeasured) sed 's/measured=true/measured=false/' "$WORLD/log" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/log" ;;
    log-failed) touch "$WORLD/log-failed" ;;
    log-empty) : > "$WORLD/log" ;;
    pending) jq '.[0].check_runs[0].status="in_progress"' "$WORLD/checks.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/checks.json" ;;
    failed) jq '.[0].check_runs[0].conclusion="failure"' "$WORLD/checks.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/checks.json" ;;
    wrong-head) jq '.[0].check_runs[0].head_sha="old"' "$WORLD/checks.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/checks.json" ;;
    wrong-app) jq '.[0].check_runs[0].app.slug="other-app"' "$WORLD/checks.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/checks.json" ;;
    partial-checks) jq '.[0].total_count=2' "$WORLD/checks.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/checks.json" ;;
    job-pending) jq '.status="in_progress"' "$WORLD/job.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/job.json" ;;
    job-head) jq '.head_sha="old"' "$WORLD/job.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/job.json" ;;
    caller-origin) jq '.path=".github/workflows/kendex-refresh.yml"' "$WORLD/run.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/run.json" ;;
    wrong-run-head) jq '.head_sha="old"' "$WORLD/run.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/run.json" ;;
    wrong-run-event) jq '.event="push"' "$WORLD/run.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/run.json" ;;
    wrong-run-repo) jq '.repository.full_name="other/r"' "$WORLD/run.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/run.json" ;;
    wrong-run-id) jq '.id=30' "$WORLD/run.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/run.json" ;;
    multiple-green|latest-pending|latest-failed|forged-caller)
      jq '.[0].total_count=2 | .[0].check_runs += [.[0].check_runs[0] + {id:74}]' "$WORLD/checks.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/checks.json"
      jq '.id=74 | .run_id=30' "$WORLD/job.json" > "$WORLD/extra-job.json"
      jq '.id=30' "$WORLD/run.json" > "$WORLD/extra-run.json"
      cp "$WORLD/log" "$WORLD/extra-log"
      case "$1" in
        multiple-green) ;;
        latest-pending|latest-failed)
          state=in_progress conclusion=null
          [[ $1 != latest-failed ]] || { state=completed; conclusion='"failure"'; }
          jq --arg state "$state" --argjson conclusion "$conclusion" '.[0].check_runs[1] += {status:$state,conclusion:$conclusion}' "$WORLD/checks.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/checks.json"
          jq --arg state "$state" --argjson conclusion "$conclusion" '. += {status:$state,conclusion:$conclusion}' "$WORLD/extra-job.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/extra-job.json"
          ;;
        forged-caller)
          printf '[[{"filename":".github/workflows/kendex-refresh.yml"},{"filename":"src/product.ts"}]]\n' > "$WORLD/files.json"
          jq '.changed_files=2' "$WORLD/pr.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/pr.json"
          jq '.path=".github/workflows/kendex-refresh.yml"' "$WORLD/extra-run.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/extra-run.json"
          sed 's/class=render/class=standard/' "$WORLD/log" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/log"
          ;;
      esac
      ;;
    different-pr) jq '.pull_requests[0].number=43' "$WORLD/run.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/run.json" ;;
    link-head) jq '.pull_requests[0].head.sha="old"' "$WORLD/run.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/run.json" ;;
    empty-links) jq '.pull_requests=[]' "$WORLD/run.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/run.json" ;;
    missing-links) jq 'del(.pull_requests)' "$WORLD/run.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/run.json" ;;
    different-range) sed "s/base-rev: $MEASURED_BASE/base-rev: $EARLIER_BASE/" "$WORLD/log" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/log" ;;
    measured-head) sed "s/head-rev: $HEAD_SHA/head-rev: $EARLIER_BASE/" "$WORLD/log" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/log" ;;
    range-missing) sed '/base-rev:/d' "$WORLD/log" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/log" ;;
    range-duplicate) printf 'base-rev: %s\n' "$MEASURED_BASE" >> "$WORLD/log" ;;
    retargeted)
      jq --arg base "$EARLIER_BASE" '.base={sha:$base,ref:"earlier"}' "$WORLD/pr.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/pr.json"
      jq --arg base "$EARLIER_BASE" '.pull_requests[0].base.sha=$base' "$WORLD/run.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/run.json"
      ;;
    moved|base-moved|ref-moved) ;;
    missing-caller) rm "$TMP_ROOT/skills/harness-ci/scripts/lib/change-class.sh" ;;
    *) fail 'fixture row exists' "$1"; exit 1 ;;
  esac
  cp "$WORLD/pr.json" "$WORLD/live.json"
  case "$1" in
    moved) jq --arg sha "$EARLIER_BASE" '.head.sha=$sha' "$WORLD/live.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/live.json" ;;
    base-moved) jq --arg sha "$EARLIER_BASE" '.base.sha=$sha' "$WORLD/live.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/live.json" ;;
    ref-moved) jq '.base.ref="other"' "$WORLD/live.json" > "$WORLD/edit"; mv "$WORLD/edit" "$WORLD/live.json" ;;
  esac
}

read_proof() {
  RC=0
  rm -f "$WORLD/pr-read"
  (cd -- "$FIXTURE"; env -i PATH="$TMP_ROOT/bin:$PATH" WORLD="$WORLD" "$BASH" "$1" 42 "$HEAD_SHA" --repo o/r) > "$WORLD/out" 2> "$WORLD/err" || RC=$?
  OUT="$(cat "$WORLD/out")"
  ERR="$(sed -n '/^refresh-ci-proof: cause=/p' "$WORLD/err")"
}

# The overseer's route consumes the keyed proof and refusal lines.
while IFS='|' read -r row cause; do
  world "$row"
  read_proof "$SCRIPT"
  if [[ $cause == pass ]]; then
    expected_job=72
    [[ $row != multiple-green ]] || expected_job=74
    assert_eq "$RC" 0 "$row exit" "$WORLD/err"
    assert_eq "$OUT" "refresh-ci-proof: head=$HEAD_SHA class=render measured=true version=1.13.0 job=$expected_job" "$row proof"
  else
    assert_eq "$RC" 1 "$row exit" "$WORLD/err"
    assert_eq "$ERR" "refresh-ci-proof: cause=$cause" "$row cause"
    assert_eq "$OUT" '' "$row grants no proof"
  fi
  assert_not_contains "$OUT" $'\033' "$row output keeps log controls private"
  assert_not_contains "$(cat "$WORLD/err")" $'\033' "$row errors keep log controls private"
done <<'EOF'
render|pass
caller|pass
workflow|workflow-changed
renamed-workflow|workflow-changed
later-workflow|workflow-changed
partial-files|ci-proof-missing
engine|engine-mismatch
body-missing|engine-mismatch
standard|class-not-render
unmeasured|class-not-render
log-failed|ci-proof-missing
log-empty|class-not-render
pending|ci-proof-missing
failed|ci-proof-missing
wrong-head|ci-proof-missing
wrong-app|ci-proof-missing
partial-checks|ci-proof-missing
job-pending|ci-proof-missing
job-head|ci-proof-missing
caller-origin|ci-proof-missing
wrong-run-head|ci-proof-missing
wrong-run-event|ci-proof-missing
wrong-run-repo|ci-proof-missing
wrong-run-id|ci-proof-missing
multiple-green|pass
latest-pending|ci-proof-missing
latest-failed|ci-proof-missing
forged-caller|class-not-render
different-pr|ci-proof-missing
link-head|ci-proof-missing
empty-links|ci-proof-missing
missing-links|ci-proof-missing
different-range|ci-proof-missing
measured-head|ci-proof-missing
range-missing|ci-proof-missing
range-duplicate|ci-proof-missing
retargeted|ci-proof-missing
moved|ci-proof-missing
base-moved|ci-proof-missing
ref-moved|ci-proof-missing
EOF

mutate() {
  python3 - "$SCRIPT" "$1" "$2" "$3" <<'PY'
from pathlib import Path
import sys
source, target, old, replacement = sys.argv[1:]
text = Path(source).read_text()
assert text.count(old) == 1, (old, text.count(old))
changed = text.replace(old, replacement)
assert text != changed
with Path(target).open("w", newline="\n") as output:
    output.write(changed)
PY
}

# Each control removes one rule from a disposable production copy. The same
# row's exit assertion turns red because the defective reader grants proof.
while IFS='|' read -r row old replacement; do
  world "$row"
  mutated="$TMP_ROOT/skills/orch/scripts/mutated"
  mutate "$mutated" "$old" "$replacement"
  read_proof "$mutated"
  assert_eq "$RC" 0 "$row control makes refusal row red" "$WORLD/err"
  assert_contains "$OUT" 'class=render measured=true' "$row control reaches proof"
done <<'EOF'
engine|$version == "$engine"|true
workflow|or . == $caller)|or true)
partial-files|length) == $metadata.changed_files|length) >= 0
standard|class=render\ measured=true|class=standard\ measured=true
unmeasured|class=render\ measured=true|class=render\ measured=false
pending|.check.status == "completed" and .check.conclusion == "success")|true)
wrong-head|.check.head_sha == $head and .check.status == "completed" and .check.conclusion == "success")|.check.status == "completed" and .check.conclusion == "success")
wrong-app|and .app.slug == "github-actions"|and true
partial-checks|length) == .[0].total_count|length) >= 0
job-pending|  .status == "completed" and .conclusion == "success"|  true
job-head|.id == $job and .head_sha == $head and .name|.id == $job and .name
caller-origin|and . != $caller|and true
forged-caller|and . != $caller|and true
wrong-run-head|.head_sha == $head and .event|true and .event
wrong-run-event|.event == "pull_request"|true
wrong-run-repo|== ($repo|!= (""
wrong-run-id|.id == $run and (.path|true and (.path
latest-pending|max_by(.check.id)|min_by(.check.id)
latest-failed|max_by(.check.id)|min_by(.check.id)
different-pr|.number == $pr and .head.sha == $head|true and .head.sha == $head
link-head|.number == $pr and .head.sha == $head|.number == $pr and true
empty-links|any(.run.pull_requests[]; .number == $pr and .head.sha == $head)|true
different-range|$proof_base == "$range_base"|true
range-missing|$proof_base == "$range_base"|true
range-duplicate|$proof_base == "$range_base"|true
retargeted|$proof_base == "$range_base"|true
measured-head|$proof_head == "$range_head"|true
moved|.head.sha == $initial.head.sha|true
base-moved|.base.sha == $initial.base.sha|true
ref-moved|.base.ref == $initial.base.ref|true
EOF

# Without the documented raw-log option, gh rejects the producer's color bytes.
world render
mutate "$TMP_ROOT/skills/orch/scripts/no-raw-option" ' --allow-escape-sequences)' ')'
read_proof "$TMP_ROOT/skills/orch/scripts/no-raw-option"
assert_eq "$RC" 1 'raw-log control makes accepted render row red'
assert_eq "$ERR" 'refresh-ci-proof: cause=ci-proof-missing' 'raw-log control names unavailable proof'

world missing-caller
read_proof "$SCRIPT"
assert_eq "$RC" 1 'missing dependency exit'
assert_eq "$ERR" 'refresh-ci-proof: cause=ci-proof-missing' 'missing dependency cause'
printf 'pass: %s  fail: %s\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
