#!/usr/bin/env bash
# Inputs: tools/guard, tools/ci-job-set, skills/orch/tests/run-all.sh, skills/harness-ci/tests/lib/kendex-engine.sh
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
cp "$REPO/skills/orch/tests/lib/suite-process.sh" "$R/skills/orch/tests/lib/"
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

# Cargo can fail after guard has filled another worker with an orch-dev suite.
if python3 - "$RUNNER" "$TMP" "$BASH" <<'PY'
import os
from pathlib import Path
import subprocess
import sys
import time

runner, root, bash = Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3]
source = runner.read_text()
cargo = root / "host-bin/cargo"
original_cargo = cargo.read_text()
needle = 'suite_environment "$suite_file" || { status=$?; stop_suites; exit "$status"; }'
assert source.count(needle) == 1
(root / "host-bin/nproc").write_text('#!/bin/sh\necho 2\n')
(root / "host-bin/nproc").chmod(0o755)
cargo.write_text('''#!/bin/sh
python3 - "$READY" <<'WAIT'
from pathlib import Path
import sys, time
deadline = time.monotonic() + 5
while not Path(sys.argv[1]).exists():
    assert time.monotonic() < deadline, "suite start deadline"
    time.sleep(0.01)
WAIT
exit 9
''')
(runner.parent / "dev-env-block.sh").write_text('trap \'printf stopped > "$STOPPED"; exit 0\' TERM\nprintf ready > "$READY"\nread -r line < "$FIFO"\nprintf done > "$DONE"\n')
(runner.parent / "open-terminal-env-fail.sh").write_text('printf "pass: 1 fail: 0\\n"\n')
try:
    for variant in ("normal", "missing-stop"):
        runner.write_text(source if variant == "normal" else source.replace(needle, 'suite_environment "$suite_file" || exit 1'))
        env = dict(os.environ, RUNNER_OS="Linux")
        for name in ("READY", "STOPPED", "DONE", "FIFO"):
            env[name] = str(root / (variant + name))
        os.mkfifo(env["FIFO"])
        hold = os.open(env["FIFO"], os.O_RDWR)
        try:
            result = subprocess.run([bash, str(runner), "--local", "=dev-env-block", "=open-terminal-env-fail"], env=env, capture_output=True, text=True, timeout=25)
            assert result.returncode == 1, result.stdout + result.stderr
            stopped = Path(env["STOPPED"]).exists()
            if not stopped:
                os.write(hold, b"release\n")
                deadline = time.monotonic() + 5
                while not Path(env["DONE"]).exists():
                    assert time.monotonic() < deadline, "suite release deadline"
                    time.sleep(0.01)
            assert stopped == (variant == "normal"), result.stdout + result.stderr
        finally:
            os.write(hold, b"release\n")
            os.close(hold)
finally:
    runner.write_text(source)
    cargo.write_text(original_cargo)
    (root / "host-bin/nproc").unlink()
    (runner.parent / "dev-env-block.sh").unlink()
    (runner.parent / "open-terminal-env-fail.sh").unlink()
PY
then ok 'pooled environment failure stops earlier suites and the control rejects missing teardown'
else bad 'pooled environment failure stops earlier suites and the control rejects missing teardown'
fi

# These are the direct Bash and Node arms of guard's configured range route.
printf 'kendex --version\n' > "$R/tools/tests/missing.test.sh"
printf 'import {execFileSync} from "node:child_process"; execFileSync("kendex", ["--version"]);\n' > "$R/tools/tests/missing.test.mjs"
cp "$GUARD" "$R/tools/guard"
cp -R "$MUTANT_TOOLS/." "$R/tools/"
for skill in "$REPO/.agents/skills/"*; do
  ln -s "$skill" "$R/.agents/skills/${skill##*/}"
done
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

# Guard changes to Git's physical root before it starts a direct suite.
# Its runner can still have the logical checkout path from the invocation.
export MSYS=winsymlinks:nativestrict
ln -s "$R" "$TMP/linked-checkout"
[ -L "$TMP/linked-checkout" ] || exit 1
printf '\n' >> "$R/skills/harness-ci/tests/change-class.test.sh"
cp "$RUNNER" "$TMP/source-runner"
for row in "physical|$R|checkout" "symlink|$TMP/linked-checkout|checkout" "control|$TMP/linked-checkout|none"; do
  IFS='|' read -r kind checkout expected <<< "$row"
  if [ "$kind" = control ]; then
    python3 - "$RUNNER" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1])
source = path.read_text()
before = 'SUITE_ROOT="$(cd "$ORCH_TEST_DIR/../../.." && pwd -P)"'
assert source.count(before) == 1
changed = source.replace(before, before.replace('pwd -P', 'pwd'))
assert changed != source
path.write_text(changed)
PY
    git -C "$R" add skills/orch/tests/run-all.sh
    git -C "$R" commit -qm control
    BASE="$(git -C "$R" rev-parse HEAD)"
  fi
  : > "$BUILD_LOG"
  RC=0
  OUT="$(cd "$checkout" && RUNNER_OS=Linux DEV_VALIDATE_SCOPED=true "$checkout/tools/guard" --selection --range "$BASE" 2>&1)" || RC=$?
  RESULT="$(sed -n 's/^resolved=//p' <<< "$OUT")"
  BUILT=no
  [ ! -s "$BUILD_LOG" ] || BUILT=yes
  want="0|$expected|yes"
  [ "$kind" != control ] || want='0|none|no'
  [ "$RC|$RESULT|$BUILT" = "$want" ] && ok "$kind guard supplies direct suite environment" || bad "$kind guard supplies direct suite environment" "$RC|$RESULT|$BUILT $OUT"
done
cp "$TMP/source-runner" "$RUNNER"

# The release job must also survive suites that normally replace PATH with
# their own build. Exercise the harness-ci suite's actual engine owner.
ENGINE_OWNER="$REPO/skills/harness-ci/tests/lib/kendex-engine.sh"
mkdir -p "$TMP/engine-source/crates/cli"
printf '[package]\nname = "kendex-cli"\n' > "$TMP/engine-source/crates/cli/Cargo.toml"
python3 - "$ENGINE_OWNER" "$TMP/engine-mutant.sh" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
needle = '[ "${KENDEX_RELEASE_TEST:-}" != 1 ] || return 0'
assert source.count(needle) == 1
mutant = source.replace(needle, ': "${KENDEX_RELEASE_TEST:-}"')
assert mutant != source
Path(sys.argv[2]).write_text(mutant)
PY
export BUILD_STATUS=0
for row in 'default|0|checkout|yes' 'release|1|host|no' 'control|1|checkout|yes'; do
  IFS='|' read -r kind release expected built <<< "$row"
  owner=$ENGINE_OWNER
  [ "$kind" != control ] || owner="$TMP/engine-mutant.sh"
  mkdir "$TMP/engine-$kind"
  : > "$BUILD_LOG"
  RC=0
  OUT="$(KENDEX_RELEASE_TEST="$release" "$BASH" -c '
    set -euo pipefail
    source "$1"
    hci_test_engine "$2" "$3"
    kendex --version
  ' sh "$owner" "$TMP/engine-source" "$TMP/engine-$kind" 2>&1)" || RC=$?
  BUILT=no
  [ ! -s "$BUILD_LOG" ] || BUILT=yes
  [ "$RC|$OUT|$BUILT" = "0|$expected|$built" ] && ok "$kind harness-ci engine selection" || bad "$kind harness-ci engine selection" "$RC|$OUT|$BUILT"
done
printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
