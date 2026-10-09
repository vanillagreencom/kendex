#!/usr/bin/env bash
# Surface: refresh-ci-proof. Inputs: harness-ci's shared caller path.
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
HEAD_SHA=0123456789abcdef0123456789abcdef01234567
cat > "$TMP_ROOT/bin/gh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >> "$WORLD/calls"
case "$*" in
  'api repos/o/r/pulls/42') cat "$WORLD/pr.json" ;;
  'api repos/o/r/pulls/42 --jq .head.sha') cat "$WORLD/live" ;;
  'api repos/o/r/pulls/42/files?per_page=100 --paginate --slurp') cat "$WORLD/files.json" ;;
  'api repos/o/r/commits/'*'/check-runs?check_name=Classify%20the%20diff&filter=latest&per_page=100 --paginate --slurp') cat "$WORLD/checks.json" ;;
  'api repos/o/r/actions/jobs/72') cat "$WORLD/job.json" ;;
  'api repos/o/r/actions/jobs/72/logs')
    [[ ! -e $WORLD/log-failed ]] || exit 1
    cat "$WORLD/log"
    ;;
  *) printf 'fixture: unexpected=%s\n' "$*" >&2; exit 9 ;;
esac
EOF
chmod +x "$TMP_ROOT/bin/gh"

world() {
  WORLD="$TMP_ROOT/world"
  rm -rf -- "$WORLD"
  mkdir -p "$WORLD"
  jq -n --arg head "$HEAD_SHA" '{head:{sha:$head},body:"Engine version: `kendex 1.13.0`.",changed_files:1}' > "$WORLD/pr.json"
  printf '%s\n' "$HEAD_SHA" > "$WORLD/live"
  printf '[[{"filename":".agents/skills/orch/SKILL.md"}]]\n' > "$WORLD/files.json"
  jq -n --arg head "$HEAD_SHA" '[{total_count:1,check_runs:[{id:72,name:"Classify the diff",app:{slug:"github-actions"},head_sha:$head,status:"completed",conclusion:"success"}]}]' > "$WORLD/checks.json"
  jq -n --arg head "$HEAD_SHA" '{id:72,name:"Classify the diff",head_sha:$head,status:"completed",conclusion:"success"}' > "$WORLD/job.json"
  printf '%s\r\n' \
    '2026-10-09T08:00:00.000Z render-verifier: verifier=path version=1.13.0' \
    '2026-10-09T08:00:01.000Z class: class=render measured=true cause=render-proof' > "$WORLD/log"
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
    moved) printf 'old\n' > "$WORLD/live" ;;
    missing-caller) rm "$TMP_ROOT/skills/harness-ci/scripts/lib/change-class.sh" ;;
    *) fail 'fixture row exists' "$1"; exit 1 ;;
  esac
}

read_proof() {
  RC=0
  env -i PATH="$TMP_ROOT/bin:$PATH" WORLD="$WORLD" "$BASH" "$1" 42 "$HEAD_SHA" --repo o/r > "$WORLD/out" 2> "$WORLD/err" || RC=$?
  OUT="$(cat "$WORLD/out")"
  ERR="$(sed -n '/^refresh-ci-proof: cause=/p' "$WORLD/err")"
}

# The overseer's route consumes the keyed proof and refusal lines.
while IFS='|' read -r row cause; do
  world "$row"
  read_proof "$SCRIPT"
  if [[ $cause == pass ]]; then
    assert_eq "$RC" 0 "$row exit" "$WORLD/err"
    assert_eq "$OUT" "refresh-ci-proof: head=$HEAD_SHA class=render measured=true version=1.13.0 job=72" "$row proof"
  else
    assert_eq "$RC" 1 "$row exit" "$WORLD/err"
    assert_eq "$ERR" "refresh-ci-proof: cause=$cause" "$row cause"
    assert_eq "$OUT" '' "$row grants no proof"
  fi
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
moved|ci-proof-missing
EOF

# Each control removes one rule from a disposable production copy. The same
# row's exit assertion turns red because the defective reader grants proof.
while IFS='|' read -r row old replacement; do
  world "$row"
  mutated="$TMP_ROOT/skills/orch/scripts/mutated"
  python3 - "$SCRIPT" "$mutated" "$old" "$replacement" <<'PY'
from pathlib import Path
import sys
source, target, old, replacement = sys.argv[1:]
text = Path(source).read_text()
assert text.count(old) == 1, (old, text.count(old))
changed = text.replace(old, replacement)
assert text != changed
Path(target).write_text(changed)
PY
  read_proof "$mutated"
  assert_eq "$RC" 0 "$row control makes refusal row red" "$WORLD/err"
  assert_contains "$OUT" 'class=render measured=true' "$row control reaches proof"
done <<'EOF'
engine|$version == "$engine"|true
workflow|or . == $caller)|or true)
partial-files|length) == $metadata.changed_files|length) >= 0
standard|class=render\ measured=true|class=standard\ measured=true
unmeasured|class=render\ measured=true|class=render\ measured=false
pending|.status == "completed" and .conclusion == "success")|true)
wrong-head|.head_sha == $head and .status == "completed" and .conclusion == "success")|.status == "completed" and .conclusion == "success")
wrong-app|and .app.slug == "github-actions"|and true
partial-checks|length) == .[0].total_count|length) >= 0
job-pending|  .status == "completed" and .conclusion == "success"|  true
job-head|.id == $job and .head_sha == $head and .name|.id == $job and .name
moved|[[ $live == "$head" ]]|[[ true ]]
EOF

world missing-caller
read_proof "$SCRIPT"
assert_eq "$RC" 1 'missing dependency exit'
assert_eq "$ERR" 'refresh-ci-proof: cause=ci-proof-missing' 'missing dependency cause'
printf 'pass: %s  fail: %s\n' "$PASS" "$FAIL"
[[ $FAIL -eq 0 ]]
