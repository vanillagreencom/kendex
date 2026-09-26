#!/usr/bin/env bash
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
# shellcheck source=lib/assertions.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib/assertions.sh"
DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../scripts" && pwd)"
SCRATCH="$(mktemp -d)"; trap 'rm -rf -- "$SCRATCH"' EXIT
# validate-workflow.sh is review-gate's and tested there; each row's stub says
# which install ran, with what arguments, one verdict line and an exit status.
stub() { # REPO PREFIX RC LINE
  mkdir -p "$1/$2/review-gate/scripts"
  printf '%s\n' '#!/usr/bin/env bash' "printf '%s %s\n' '$2' \"\$*\"" "[ -z '$4' ] || printf '%s\n' '$4'" "exit $3" >"$1/$2/review-gate/scripts/validate-workflow.sh"
  chmod +x "$1/$2/review-gate/scripts/validate-workflow.sh"
}
table() { # SCRIPT TAG JUDGE — every row against SCRIPT, each judged by JUDGE GOT WANT ROW;
  # returns 1 at the first row JUDGE refuses
  local name layout stub_rc line expected_rc expected repo rc out
  while IFS='|' read -r name layout stub_rc line expected_rc expected; do
    repo="$SCRATCH/$2-$name"; git init -q "$repo"; git -C "$repo" config gc.auto 0; git -C "$repo" config maintenance.auto false; mkdir "$repo/sub"
    case "$layout" in
      none) ;;
      vendored) stub "$repo" .agents/skills "$stub_rc" "$line" ;;
      catalog) stub "$repo" .agents/skills 9 ""; stub "$repo" skills "$stub_rc" "$line" ;;
    esac
    rc=0; out="$(bash "$1" "$repo/sub" 2>&1)" || rc=$?
    out="$(printf '%s\n' "$out" | tr '\n' ',')"
    "$3" "$rc:$out" "$expected_rc:$expected" "$name" || return 1
  done <<'ROWS'
absent|none|0||0|adopt-writer: review-gate=absent,
current|vendored|0|ok check=workflow-readopted value=w.yml|0|.agents/skills --adopt,ok check=workflow-readopted value=w.yml,adopt-writer: adopt=0,
edited|vendored|1|FAIL check=workflow-edited value=w.yml|1|.agents/skills --adopt,FAIL check=workflow-edited value=w.yml,adopt-writer: adopt=edited,
standing|vendored|1|FAIL check=workflow-count value=0|0|.agents/skills --adopt,FAIL check=workflow-count value=0,adopt-writer: adopt=standing,
error|vendored|2||1|.agents/skills --adopt,adopt-writer: adopt=2,
catalog|catalog|0||0|skills --adopt,adopt-writer: adopt=0,
ROWS
}
table "$DIR/adopt-writer" real assert_eq
# Must-fail control: a copy whose edited branch no longer exits 1 fails the
# edited row. Its judge counts nothing, so the miss it expects stays out of the
# suite's tally.
miss() { [[ "$1" == "$2" ]] || { printf 'miss %s rc=%s\n' "$3" "${1%%:*}"; return 1; }; }
edited='    status adopt edited; exit 1'
assert_eq "$(grep -cxF -- "$edited" "$DIR/adopt-writer" || true)" 1 "control finds the edited exit as one line to strip"
edited="$edited" awk '$0 == ENVIRON["edited"] { print "    status adopt edited"; next } { print }' "$DIR/adopt-writer" >"$SCRATCH/mutant"
rc=0; out="$(table "$SCRATCH/mutant" mutant miss)" || rc=$?
assert_eq "$rc:$out" "1:miss edited rc=0" "control: a copy whose edited branch exits 0 fails the edited row"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
