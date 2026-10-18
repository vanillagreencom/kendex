#!/usr/bin/env bash
# Inputs: tools/guard, tools/ci-job-set, skills/orch/tests/run-all.sh
# The configured local route must not borrow an installed kendex. Fixture
# suites add BIN and OT_BIN as lanes-pick-spread does, then lose their kendex.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/guard-world.sh"

mkdir -p "$TMP/host-bin" "$TMP/checkout" "$R/skills/orch/tests/lib" \
  "$R/skills/orch/scripts/lib" "$R/skills/github/scripts/lib" "$R/tools/tests" \
  "$R/refresh/tests" "$R/skills/harness-ci/tests"
cp "$REPO/skills/orch/tests/run-all.sh" "$R/skills/orch/tests/"
cp "$REPO/skills/orch/tests/lib/git-env.sh" "$R/skills/orch/tests/lib/"
cp "$REPO/skills/orch/scripts/lib/lane-state.sh" "$R/skills/orch/scripts/lib/"
cp "$REPO/skills/github/scripts/lib/group-leader.sh" "$R/skills/github/scripts/lib/"
cp "$REPO/tools/ci-job-set" "$REPO/tools/macos-test-contracts" "$REPO/tools/macos-test-contracts.json" "$R/tools/"
printf '#!/bin/sh\necho host\n' > "$TMP/host-bin/kendex"
printf '#!/bin/sh\necho retained\n' > "$TMP/host-bin/peer-tool"
printf '#!/bin/sh\necho checkout\n' > "$TMP/checkout/kendex"
cat > "$TMP/host-bin/cargo" <<'SH'
#!/bin/sh
printf '%s\n' "$*" >> "$BUILD_LOG"
[ "$BUILD_STATUS" = 0 ] || exit "$BUILD_STATUS"
printf '{"reason":"compiler-artifact","target":{"name":"kendex"},"executable":"%s"}\n' "$CHECKOUT"
SH
chmod +x "$TMP/host-bin/"* "$TMP/checkout/kendex"
export BUILD_LOG="$TMP/builds" BUILD_STATUS=0 CHECKOUT="$TMP/checkout/kendex"
export PATH="$TMP/host-bin:$PATH"
RUNNER="$R/skills/orch/tests/run-all.sh"

# The same expectation runs against the source and a disposable mutation.
suite_result() { # RUNNER FILE pooled|direct OS
  local runner=$1 file=$2 route=$3 os=$4 name
  name=${file##*/}
  : > "$BUILD_LOG"
  RC=0
  if [ "$route" = pooled ]; then
    OUT="$(RUNNER_OS="$os" "$BASH" "$runner" --battery "${file%/*}" --local "=${name%.sh}" 2>&1)" || RC=$?
  else
    OUT="$(RUNNER_OS="$os" "$BASH" "$runner" --local --suite "$file" 2>&1)" || RC=$?
  fi
  RESULT="$(sed -n 's/^resolved=//p' <<< "$OUT")"
  BUILT=no
  [ ! -s "$BUILD_LOG" ] || BUILT=yes
  ACTUAL="$RC|$RESULT|$BUILT"
}
cat > "$TMP/suite" <<'SH'
set -euo pipefail
BIN="$FIXTURE_BIN" OT_BIN="$FIXTURE_OT_BIN"
PATH="$BIN:$OT_BIN:$PATH"
peer-tool >/dev/null
resolved=$(kendex --version) || resolved=none
printf 'resolved=%s\npass: 1 fail: 0\n' "$resolved"
SH
mkdir "$TMP/bin" "$TMP/ot-bin"
export FIXTURE_BIN="$TMP/bin" FIXTURE_OT_BIN="$TMP/ot-bin"
for row in \
  'skills/orch/tests/lanes-pick-spread.sh|none|no' \
  'skills/orch/tests/open-terminal-context.sh|checkout|yes' \
  'skills/orch/tests/tier-model-fixture.sh|checkout|yes' \
  'refresh/tests/refresh.test.sh|checkout|yes' \
  'skills/harness-ci/tests/change-class.test.sh|checkout|yes' \
  'tools/tests/local.test.sh|none|no'; do
  IFS='|' read -r path expected built <<< "$row"
  cp "$TMP/suite" "$R/$path"
  for route in pooled direct; do
    for os in Linux macOS; do
      want="0|$expected|$built"
      [ "$os" != macOS ] || want='0|none|no'
      suite_result "$RUNNER" "$R/$path" "$route" "$os"
      [ "$ACTUAL" = "$want" ] && ok "$route $os $path" || bad "$route $os $path" "$ACTUAL $OUT"
    done
  done
done

# Mutations keep the suite and assertions intact, and change only the PATH
# selected by the production runner.
for row in 'none|SUITE_PATH=$CLEAN_PATH|SUITE_PATH=$PATH|lanes-pick-spread.sh|0|none|no' \
  'checkout|SUITE_PATH=$CHECKOUT_PATH|SUITE_PATH=$PATH|open-terminal-context.sh|0|checkout|yes'; do
  IFS='|' read -r kind before after suite status resolved built <<< "$row"
  python3 - "$RUNNER" "$TMP/mutant" "$before" "$after" <<'PY'
from pathlib import Path
import sys
source, target, before, after = sys.argv[1:]
text = Path(source).read_text()
assert text.count(before) == 1
changed = text.replace(before, after)
assert changed != text
Path(target).write_text(changed)
PY
  cp "$RUNNER" "$TMP/source-runner"
  cp "$TMP/mutant" "$RUNNER"
  suite_result "$RUNNER" "$R/skills/orch/tests/$suite" direct Linux
  cp "$TMP/source-runner" "$RUNNER"
  [ "$ACTUAL" != "$status|$resolved|$built" ] && ok "control: $kind rejects host PATH" || bad "control: $kind rejects host PATH" "$OUT"
done

BUILD_STATUS=9
suite_result "$RUNNER" "$R/skills/orch/tests/open-terminal-context.sh" direct Linux
[ "$RC" -ne 0 ] && [ -z "$RESULT" ] && ok 'a failed checkout build starts no suite' || bad 'a failed checkout build starts no suite' "$OUT"
BUILD_STATUS=0

# These are the direct Bash and Node arms of guard's configured range route.
printf 'kendex --version\n' > "$R/tools/tests/missing.test.sh"
printf 'import {execFileSync} from "node:child_process"; execFileSync("kendex", ["--version"]);\n' > "$R/tools/tests/missing.test.mjs"
git -C "$R" add -A
entry_points_executable
git -C "$R" commit -qm suites
BASE="$(git -C "$R" rev-parse HEAD)"
for extension in sh mjs; do
  printf '\n' >> "$R/tools/tests/missing.test.$extension"
  RC=0
  OUT="$(cd "$R" && DEV_VALIDATE_SCOPED=true "$GUARD" --selection --range "$BASE" 2>&1)" || RC=$?
  [ "$RC" -eq 1 ] && ok "guard refuses a missing fixture kendex in $extension" || bad "guard refuses a missing fixture kendex in $extension" "$OUT"
  git -C "$R" restore "tools/tests/missing.test.$extension"
done
printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
