#!/usr/bin/env bash
# Inputs: tools/guard, skills/orch/tests/run-all.sh
# Package selection and PATH are exercised through the production guard and
# battery. The fixture engines model a command added after a release.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/guard-world.sh"
git -C "$R" config gc.auto 0
git -C "$R" config maintenance.auto false

mkdir -p "$TMP/released" "$TMP/main" "$R/skills/quiet/tests" "$R/skills/nonconsumer/tests"
printf '#!/bin/sh\nkendex --version >/dev/null\n' > "$R/skills/demo/scripts/demo.sh"
cat > "$TMP/released/kendex" <<'SH'
#!/bin/sh
case "$1" in --version) echo 'kendex 1.0.0' ;; *) exit 2 ;; esac
SH
cat > "$TMP/main/kendex" <<'SH'
#!/bin/sh
case "$1" in --version) echo 'kendex 1.1.0' ;; future-command) exit 0 ;; *) exit 2 ;; esac
SH
chmod +x "$TMP/released/kendex" "$TMP/main/kendex"
printf '#!/bin/sh\nexit 97\n' > "$R/skills/nonconsumer/tests/nonconsumer.test.sh"
cat > "$R/skills/demo/tests/demo.test.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'demo\n' >> "$SUITE_LOG"
printf 'pass: 1 fail: 0\n'
SH
cat > "$R/skills/demo/tests/companion.test.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'companion\n' >> "$SUITE_LOG"
printf 'pass: 1 fail: 0\n'
SH
cat > "$R/skills/quiet/tests/quiet.test.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'untouched\n' >> "$SUITE_LOG"
kendex --version
exit 97
SH
git -C "$R" add -A
entry_points_executable
git -C "$R" commit -qm 'chore: release suite fixtures'
BASE="$(git -C "$R" rev-parse HEAD)"
export SUITE_LOG="$TMP/suite-log"

run_release() { # BINARY [GUARD]
  : > "$SUITE_LOG"
  RC=0
  OUT="$(cd "$R" && PATH="$TMP/main:$PATH" "${2:-$GUARD}" --released-packages "$1" --range "$BASE" 2>&1)" || RC=$?
  RAN="$(sort "$SUITE_LOG" | tr '\n' ' ')"
}

# One changed input runs the whole package, including a suite the input
# reach cannot find. A changed render maps to the same source package.
for path in skills/demo/scripts/demo.sh skills/demo/README.md .agents/skills/demo/scripts/demo.sh; do
  printf '\n' >> "$R/$path"
  run_release "$TMP/released/kendex"
  [ "$RC:$RAN" = '0:companion demo ' ] && ok "complete changed package: $path" || bad "complete changed package: $path" "$RC $RAN $OUT"
  git -C "$R" reset -q --hard "$BASE"
  git -C "$R" clean -qfd
done

# The URL row comes from commit-guards/scripts/pre-push's help output.
for help in '' 'https://github.com/vanillagreencom/kendex/blob/main/skills/commit-guards/DEVELOPMENT.md#the-pre-push-lane'; do
  cat > "$R/skills/nonconsumer/tests/nonconsumer.test.sh" <<SH
#!/bin/sh
cat <<'HELP'
$help
HELP
exit 97
SH
  run_release "$TMP/released/kendex"
  [ "$RC:$RAN" = '0:' ] && ok "changed noncaller is excluded: ${help:-no help URL}" || bad "changed noncaller is excluded: ${help:-no help URL}" "$RC $RAN $OUT"
  git -C "$R" reset -q --hard "$BASE"
done

printf '\n' >> "$R/skills/demo/README.md"
python3 - "$GUARD" "$MUTANT_TOOLS/guard" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
needle = '[ -z "$release_version" ] || run=all'
assert source.count(needle) == 1
mutant = source.replace(needle, '[ -z "$release_version" ] || run=""')
assert mutant != source
Path(sys.argv[2]).write_text(mutant)
PY
chmod +x "$MUTANT_TOOLS/guard"
run_release "$TMP/released/kendex" "$MUTANT_TOOLS/guard"
[ "$RC:$RAN" = '0:' ] && ok 'control: affected-suite mapping misses complete package suites' || bad 'control: affected-suite mapping misses complete package suites' "$RC $RAN $OUT"
git -C "$R" reset -q --hard "$BASE"
git -C "$R" clean -qfd

printf '\n' >> "$R/skills/demo/scripts/demo.sh"
python3 - "$GUARD" "$MUTANT_TOOLS/guard" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
needle = '\n      continue\n    fi\n    tree_paths='
assert source.count(needle) == 1
mutant = source.replace(needle, '\n      :\n    fi\n    tree_paths=')
assert mutant != source
Path(sys.argv[2]).write_text(mutant)
PY
chmod +x "$MUTANT_TOOLS/guard"
run_release "$TMP/released/kendex" "$MUTANT_TOOLS/guard"
[ "$RC:$RAN" = '1:companion demo untouched ' ] && ok 'control: scanning unchanged packages runs their failing suite' || bad 'control: scanning unchanged packages runs their failing suite' "$RC $RAN $OUT"
git -C "$R" reset -q --hard "$BASE"

# This file calls the script behind a variable; testing only the directly
# named demo suite would miss the incompatibility.
mkdir -p "$R/skills/demo/scripts"
printf '#!/bin/sh\nkendex future-command\n' > "$R/skills/demo/scripts/future.sh"
cat > "$R/skills/demo/tests/companion.test.sh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'companion\n' >> "$SUITE_LOG"
script="$(dirname "$0")/../scripts/future.sh"
sh "$script"
printf 'pass: 1 fail: 0\n'
SH
run_release "$TMP/released/kendex"
[ "$RC" -ne 0 ] && [[ "$OUT" == *'version=1.0.0 leg=package-suites package=skills/demo'* ]] \
  && [[ "$OUT" == *'companion.test'* ]] && [[ "$OUT" == *'remedy=release-engine'* ]] \
  && ok 'unreleased command fails with package, suite and engine identified' \
  || bad 'unreleased command fails with package, suite and engine identified' "$RC $OUT"
run_release "$TMP/main/kendex"
[ "$RC:$RAN" = '0:companion demo ' ] && ok 'same package passes with the next engine' || bad 'same package passes with the next engine' "$RC $RAN $OUT"

# Must-fail: letting the inherited main engine outrank the supplied release
# turns the same incompatible package green. Keep the export in the copy.
MUTANT="$MUTANT_TOOLS/guard"
python3 - "$GUARD" "$MUTANT" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
needle = 'export PATH="$release_dir:$PATH"'
assert source.count(needle) == 1
mutant = source.replace(needle, 'export PATH="$PATH:$release_dir"')
assert mutant != source
Path(sys.argv[2]).write_text(mutant)
PY
chmod +x "$MUTANT"
run_release "$TMP/released/kendex" "$MUTANT"
[ "$RC:$RAN" = '0:companion demo ' ] && ok 'control: main first on PATH hides the incompatibility' || bad 'control: main first on PATH hides the incompatibility' "$RC $RAN $OUT"

printf '\npass: %s fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
