#!/usr/bin/env bash
# The proof for tools/exec-bits: one row per roster path shape and per
# exclusion, each staged at 100644 and at 100755 in the index with the
# opposite bit on disk, so a row passes only when the index decides; then
# the runs that cannot scan. Every row runs the real script over a fixture
# repository under tmp/ and reads its exit status and its keyed first line.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

ROOT="$(git rev-parse --show-toplevel)"
EXEC_BITS="$ROOT/tools/exec-bits"
mkdir -p "$ROOT/tmp"
TMP="$(mktemp -d "$ROOT/tmp/exec-bits.XXXXXX")" || exit 2
trap 'rm -rf -- "${TMP:?}"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

run_scan() { # DIR [ARG...] — sets OUT and RC
  local dir=$1
  shift
  RC=0
  OUT="$(cd "$dir" && "$EXEC_BITS" "$@" 2>&1)" || RC=$?
}

W="$TMP/repo"
git init -q "$W"
# The roster is never empty: one executable entry point stays staged.
mkdir -p "$W/skills/base/scripts"
printf '#!/usr/bin/env bash\n' >"$W/skills/base/scripts/base"
git -C "$W" add skills/base/scripts/base
git -C "$W" update-index --chmod=+x skills/base/scripts/base

stage() { # PATH INDEX-BIT(+x|-x) — the disk bit is the opposite one
  mkdir -p "$(dirname "$W/$1")"
  printf '#!/usr/bin/env bash\n' >"$W/$1"
  case "$2" in +x) chmod 0644 "$W/$1" ;; *) chmod 0755 "$W/$1" ;; esac
  git -C "$W" add -- "$1"
  git -C "$W" update-index --chmod="$2" -- "$1"
}
unstage() { # PATH
  git -C "$W" update-index --force-remove -- "$1"
  rm -f -- "$W/$1"
}

while IFS='|' read -r expected path; do
  stage "$path" -x
  run_scan "$W"
  if [ "$expected" = refuse ]; then
    [ "$RC" -eq 1 ] && [ "$OUT" = "exec-bits: not-executable=1
not executable in git: $path" ] && ok "refused at 100644: $path" || bad "refused at 100644: $path" "rc=$RC out=$OUT"
  else
    [ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "not judged at 100644: $path" || bad "not judged at 100644: $path" "rc=$RC out=$OUT"
  fi
  unstage "$path"
  stage "$path" +x
  run_scan "$W"
  [ "$RC" -eq 0 ] && [ -z "$OUT" ] && ok "passes at 100755: $path" || bad "passes at 100755: $path" "rc=$RC out=$OUT"
  unstage "$path"
done <<'ROWS'
refuse|skills/demo/tests/new.test.sh
refuse|skills/demo/tests/deep/nested.sh
refuse|skills/demo/scripts/tool
refuse|skills/demo/scripts/sub/tool.py
refuse|skills/demo/scripts/frappé.sh
refuse|hooks/tests/new.test.sh
pass|skills/demo/scripts/lib/helper.sh
pass|skills/demo/tests/lib/helper.sh
pass|skills/demo/tests/controls/mutant.sh
pass|skills/demo/tests/data.txt
pass|hooks/new.sh
pass|tools/new.sh
ROWS

mkdir -p "$TMP/plain"
GIT_CEILING_DIRECTORIES="$TMP" run_scan "$TMP/plain"
[ "$RC" -eq 2 ] && [[ "$OUT" == "exec-bits: not-in-repo=$TMP/plain"* ]] && ok "outside a repository exits 2" || bad "outside a repository exits 2" "rc=$RC out=$OUT"
git -C "$W" update-index --force-remove skills/base/scripts/base
run_scan "$W"
[ "$RC" -eq 2 ] && [ "$OUT" = "exec-bits: roster=empty" ] && ok "a roster with no entry point exits 2" || bad "a roster with no entry point exits 2" "rc=$RC out=$OUT"
run_scan "$W" extra
[ "$RC" -eq 2 ] && [[ "$OUT" == "exec-bits: usage="* ]] && ok "an argument is refused with the usage line" || bad "an argument is refused with the usage line" "rc=$RC out=$OUT"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
