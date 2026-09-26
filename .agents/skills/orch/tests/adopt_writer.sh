#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd)"
SCRATCH="$(mktemp -d)"; trap 'rm -rf -- "$SCRATCH"' EXIT
# validate-workflow.sh is review-gate's and tested there; each row's stub says
# which install ran, with what arguments, one verdict line and an exit status.
stub() { # REPO PREFIX RC LINE
  mkdir -p "$1/$2/review-gate/scripts"
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s %s\n' '$2' \"\$*\"" "[ -z '$4' ] || printf '%s\n' '$4'" "exit $3" >"$1/$2/review-gate/scripts/validate-workflow.sh"
  chmod +x "$1/$2/review-gate/scripts/validate-workflow.sh"
}
while IFS='|' read -r name layout stub_rc line expected_rc expected; do
  repo="$SCRATCH/$name"; git init -q "$repo"; mkdir "$repo/sub"
  case "$layout" in
    none) ;;
    vendored) stub "$repo" .agents/skills "$stub_rc" "$line" ;;
    catalog) stub "$repo" .agents/skills 9 ""; stub "$repo" skills "$stub_rc" "$line" ;;
  esac
  rc=0; out="$(bash "${ADOPT_WRITER_UNDER_TEST:-$DIR/adopt-writer}" "$repo/sub" 2>&1)" || rc=$?
  out="$(printf '%s\n' "$out" | tr '\n' ',')"
  [[ "$rc:$out" == "$expected_rc:$expected" ]] || { printf 'FAIL %s: %s:%s\n' "$name" "$rc" "$out"; exit 1; }
  printf 'pass: %s\n' "$name"
done <<'ROWS'
absent|none|0||0|adopt-writer: review-gate=absent,
current|vendored|0|ok check=workflow-readopted value=w.yml|0|.agents/skills --adopt,ok check=workflow-readopted value=w.yml,adopt-writer: adopt=0,
edited|vendored|1|FAIL check=workflow-edited value=w.yml|1|.agents/skills --adopt,FAIL check=workflow-edited value=w.yml,adopt-writer: adopt=edited,
standing|vendored|1|FAIL check=workflow-count value=0|0|.agents/skills --adopt,FAIL check=workflow-count value=0,adopt-writer: adopt=standing,
error|vendored|2||1|.agents/skills --adopt,adopt-writer: adopt=2,
catalog|catalog|0||0|skills --adopt,adopt-writer: adopt=0,
ROWS
