#!/usr/bin/env bash
# Inputs: tools/guard, tools/ci-job-set, tools/macos-test-contracts, tools/macos-test-contracts.json,
# skills/orch/*, skills/commit-guards/*,
# skills/github/*, skills/deep-research/*, skills/slack/*, skills/bot-instructions/*,
# skills/jarvis/scripts/lib/watch.py, skills/harness-ci/tests/change-class.test.sh
# Package selection and PATH are exercised through the production guard and
# battery. The fixture engines model a command added after a release.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/guard-world.sh"
git -C "$R" config gc.auto 0
git -C "$R" config maintenance.auto false

mkdir -p "$TMP/released" "$TMP/main" "$R/skills/quiet/tests" "$R/skills/nonconsumer/tests"
# The leg asks the real CI owner which suites a Linux shard gives a kendex;
# guard-world's neutral stub answers none for every suite.
cp "$REPO/tools/ci-job-set" "$REPO/tools/macos-test-contracts" "$REPO/tools/macos-test-contracts.json" "$R/tools/"
for package in deep-research github commit-guards slack bot-instructions; do
  cp -R "$REPO/skills/$package" "$R/skills/$package"
done
printf '#!/bin/sh\nkendex --version >/dev/null\n' > "$R/skills/demo/scripts/demo.sh"
cat > "$TMP/released/kendex" <<'SH'
#!/bin/sh
case "$1" in
  --version) echo 'kendex 1.0.0' ;;
  project) [ "${2-}" = list ] || exit 2; printf '1.0.0 project list\n' >> "$ENGINE_LOG" ;;
  *) exit 2 ;;
esac
SH
cat > "$TMP/main/kendex" <<'SH'
#!/bin/sh
case "$1" in
  --version) echo 'kendex 1.1.0' ;;
  project) [ "${2-}" = list ] || exit 2; printf '1.1.0 project list\n' >> "$ENGINE_LOG" ;;
  future-command) exit 0 ;;
  *) exit 2 ;;
esac
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
export ENGINE_LOG="$TMP/engine-log"

run_release() { # BINARY [GUARD [PART]]
  : > "$SUITE_LOG"
  : > "$ENGINE_LOG"
  RC=0
  OUT="$(cd "$R" && PATH="$TMP/main:$PATH" "${2:-$GUARD}" --released-packages "$1" ${3:+--part "$3"} --range "$BASE" 2>&1)" || RC=$?
  RAN="$(sort "$SUITE_LOG" | tr '\n' ' ')"
  ENGINE_CALLS="$(cat "$ENGINE_LOG")"
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

# The package rows use whole shipped noncallers, including Node comments and
# shell strings. Positive rows retain actual caller source with short suites
# to observe dispatch. The prose rows cover comments and quoted separators.
while IFS='|' read -r kind input expected engine_expected; do
  case "$kind" in
    package) printf '\n' >> "$R/skills/$input/README.md" ;;
    prose)
      cat > "$R/skills/nonconsumer/tests/nonconsumer.test.sh" <<SH
#!/bin/sh
cat <<'HELP'
$input
HELP
$input
exit 97
SH
      ;;
    caller)
      mkdir -p "$R/skills/nonconsumer/scripts"
      cp "$REPO/$input" "$R/skills/nonconsumer/scripts/${input##*/}"
      cat > "$R/skills/nonconsumer/tests/nonconsumer.test.sh" <<'SH'
#!/bin/sh
printf 'caller\n' >> "$SUITE_LOG"
printf 'pass: 1 fail: 0\n'
SH
      ;;
    empty)
      mkdir -p "$R/skills/nonconsumer/scripts/lib"
      cp "$REPO/$input" "$R/skills/nonconsumer/scripts/lib/${input##*/}"
      ;;
    python)
      mkdir -p "$R/skills/nonconsumer/scripts/lib"
      cp "$REPO/$input" "$R/skills/nonconsumer/scripts/lib/${input##*/}"
      cat > "$R/skills/nonconsumer/tests/nonconsumer.test.sh" <<'SH'
#!/bin/sh
set -eu
python3 -B - "${0%/*}/../scripts/lib/watch.py" <<'PY'
import importlib.util
import sys

spec = importlib.util.spec_from_file_location('watch', sys.argv[1])
watch = importlib.util.module_from_spec(spec)
spec.loader.exec_module(watch)
assert watch.project_roots() == []
PY
printf 'caller\n' >> "$SUITE_LOG"
printf 'pass: 1 fail: 0\n'
SH
      cat > "$R/skills/nonconsumer/tests/companion.test.sh" <<'SH'
#!/bin/sh
printf 'companion\n' >> "$SUITE_LOG"
printf 'pass: 1 fail: 0\n'
SH
      ;;
    *) bad 'unknown selection fixture kind' "$kind"; exit 1 ;;
  esac
  run_release "$TMP/released/kendex"
  matched=1
  [ "$RC:${RAN% }" = "$expected" ] && [ "$ENGINE_CALLS" = "$engine_expected" ] || matched=0
  if [ "$expected" = 0: ]; then
    [[ "$OUT" != *'leg=package-suites package='* ]] || matched=0
  fi
  [ "$matched" -eq 1 ] && ok "selection $kind: ${input:-no CLI text}" || bad "selection $kind: $input" "$RC $RAN engine=$ENGINE_CALLS $OUT"
  git -C "$R" reset -q --hard "$BASE"
  git -C "$R" clean -qfd
done <<'ROWS'
package|deep-research|0:
package|github|0:
package|commit-guards|0:
package|slack|0:
package|bot-instructions|0:
empty|skills/slack/scripts/lib/__init__.py|0:
empty|skills/bot-instructions/scripts/lib/__init__.py|0:
prose||0:
prose|https://github.com/vanillagreencom/kendex/blob/main/skills/commit-guards/DEVELOPMENT.md#the-pre-push-lane|0:
prose|echo "a title (kendex#537)"|0:
prose|echo "reinstall; kendex refresh"|0:
prose|echo ready # reinstall; kendex refresh|0:
caller|skills/orch/tests/claude-model-classes.sh|0:caller
caller|skills/harness-ci/tests/change-class.test.sh|0:caller
python|skills/jarvis/scripts/lib/watch.py|0:caller companion|1.0.0 project list
ROWS

# A selector that includes noncallers must turn the negative row red.
printf '\n' >> "$R/skills/nonconsumer/tests/nonconsumer.test.sh"
python3 - "$GUARD" "$MUTANT_TOOLS/guard" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
needle = 'calls_kendex=0'
assert source.count(needle) == 1
mutant = source.replace(needle, 'calls_kendex=1')
assert mutant != source
Path(sys.argv[2]).write_text(mutant)
PY
chmod +x "$MUTANT_TOOLS/guard"
run_release "$TMP/released/kendex" "$MUTANT_TOOLS/guard"
[ "$RC" -eq 1 ] && [[ "$OUT" == *'package=skills/nonconsumer'* ]] \
  && [[ "$OUT" == *'suite=nonconsumer.test '*'pass=0 fail=1'* ]] \
  && ok 'control: including a noncaller runs its failing suite' || bad 'control: including a noncaller runs its failing suite' "$RC $OUT"
git -C "$R" reset -q --hard "$BASE"

# The existing runner owns which orch suites run alone. Discover one of its
# names, then prove native dispatch puts it after a pooled suite even with a
# single worker. No elapsed-time assertion or second isolation list is needed.
alone_names="$(sed -n '/^ALONE=(/,/^)/p' "$REPO/skills/orch/tests/run-all.sh" | sed '1d;$d' | awk '{print $1}')"
[ -n "$alone_names" ] || { bad 'runner isolation name is available'; exit 1; }
alone_name=${alone_names%%$'\n'*}
mkdir -p "$R/skills/orch/tests/lib" "$TMP/native/tools" "$TMP/native/skills/orch" "$TMP/one-worker"
cp "$GUARD" "$TMP/native/tools/guard"
cp "$REPO/skills/orch/tests/run-all.sh" "$R/skills/orch/tests/run-all.sh"
cp "$REPO/skills/orch/tests/lib/git-env.sh" "$R/skills/orch/tests/lib/git-env.sh"
ln -s "$R/skills/orch/tests" "$TMP/native/skills/orch/tests"
ln -s "$REPO/skills/orch/scripts" "$TMP/native/skills/orch/scripts"
ln -s "$REPO/skills/orch/scripts" "$R/skills/orch/scripts"
ln -s "$REPO/skills/github" "$TMP/native/skills/github"
ln -s "$REPO/skills/commit-guards" "$TMP/native/skills/commit-guards"
for tool in ci-job-set macos-test-contracts macos-test-contracts.json; do
  ln -s "$REPO/tools/$tool" "$TMP/native/tools/$tool"
done
printf '#!/bin/sh\necho 1\n' > "$TMP/one-worker/nproc"
chmod +x "$TMP/one-worker/nproc"
for name in "$alone_name" zzz-pooled; do
  cat > "$R/skills/orch/tests/$name.sh" <<SH
#!/bin/sh
kendex --version >/dev/null
printf '%s\n' '$name' >> "\$SUITE_LOG"
printf 'pass: 1 fail: 0\n'
SH
done
OUT=""
RC=0
PATH="$TMP/one-worker:$PATH" run_release "$TMP/released/kendex" "$TMP/native/tools/guard"
order="$(tr '\n' ' ' < "$SUITE_LOG")"
[ "$RC:$order" = "0:zzz-pooled $alone_name " ] && ok 'orch native dispatch retains runner isolation order' || bad 'orch native dispatch retains runner isolation order' "$RC $order $OUT"
python3 - "$GUARD" "$TMP/native/tools/guard" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
needle = '[ "$d" = skills/orch ] || release_args=(--battery "$d/tests")'
assert source.count(needle) == 1
mutant = source.replace(needle, 'release_args=(--battery "$d/tests")')
assert mutant != source
Path(sys.argv[2]).write_text(mutant)
PY
PATH="$TMP/one-worker:$PATH" run_release "$TMP/released/kendex" "$TMP/native/tools/guard"
order="$(tr '\n' ' ' < "$SUITE_LOG")"
[ "$RC:$order" = "0:$alone_name zzz-pooled " ] && ok 'control: battery dispatch drops orch isolation order' || bad 'control: battery dispatch drops orch isolation order' "$RC $order $OUT"

# A caller suite in a shard CI gives a kendex (orch-rest) runs; a suite in
# one CI gives none (orch-oversee) cannot depend on one and does not.
cp "$GUARD" "$TMP/native/tools/guard"
rm "$R/skills/orch/tests/$alone_name.sh" "$R/skills/orch/tests/zzz-pooled.sh"
for name in zzz-caller zzz-second; do
  cat > "$R/skills/orch/tests/$name.sh" <<SH
#!/bin/sh
printf '%s\n' '$name' >> "\$SUITE_LOG"
[ '$name' != zzz-caller ] || kendex future-command || exit 1
printf 'pass: 1 fail: 0\n'
SH
done
printf '#!/bin/sh\nprintf "oversee_zzz\\n" >> "$SUITE_LOG"\nexit 97\n' > "$R/skills/orch/tests/oversee_zzz.sh"
run_release "$TMP/released/kendex" "$TMP/native/tools/guard"
[ "$RC" -ne 0 ] && [ "$RAN" = 'zzz-caller zzz-second ' ] && [[ "$OUT" == *'suite=zzz-caller '*'fail=1'* ]] \
  && [[ "$OUT" == *'remedy=release-engine'* ]] && [[ "$OUT" == *'selected-suite=skills/orch/tests/zzz-caller.sh'* ]] \
  && [[ "$OUT" != *'selected-suite=skills/orch/tests/oversee_zzz.sh'* ]] && [[ "$OUT" != *'reason=kendex-unread'* ]] \
  && ok 'kendex suites only: the caller fails under the release engine' \
  || bad 'kendex suites only: the caller fails under the release engine' "$RC $RAN $OUT"
run_release "$TMP/main/kendex" "$TMP/native/tools/guard"
[ "$RC:$RAN" = '0:zzz-caller zzz-second ' ] && ok 'kendex suites only: the next engine passes' || bad 'kendex suites only: the next engine passes' "$RC $RAN $OUT"

# Each part runs its share of the selected suites, and the parts cover them;
# a part with no share runs nothing.
while IFS='|' read -r part expected; do
  run_release "$TMP/main/kendex" "$TMP/native/tools/guard" "$part"
  [ "$RC:$RAN" = "$expected" ] && ok "part $part" || bad "part $part" "$RC $RAN $OUT"
done <<'ROWS'
1/2|0:zzz-caller 
2/2|0:zzz-second 
1/1|0:zzz-caller zzz-second 
3/3|0:
ROWS
for part in 0/2 3/2 2 1/x 1/2/3 /2; do
  run_release "$TMP/main/kendex" "$TMP/native/tools/guard" "$part"
  [ "$RC:$RAN" = 2: ] && [[ "$OUT" == "guard: argument=--part=$part"* ]] && ok "part refused: $part" || bad "part refused: $part" "$RC $RAN $OUT"
done

# Must-fail: the whole package, as before this selection, runs the suite
# no CI shard gives a kendex, and with it the parts' split and an empty share.
for edit in 'release_suites=$release_kendex@@:' '[ $((release_index % release_parts + 1)) -ne "$release_part" ] || @@' \
  $'release_suites=$release_share\n      [ -n "$release_suites" ] || continue@@release_suites=$release_share'; do
  python3 - "$GUARD" "$TMP/native/tools/guard" "$edit" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
needle, replacement = sys.argv[3].split('@@')
assert source.count(needle) == 1
mutant = source.replace(needle, replacement)
assert mutant != source
Path(sys.argv[2]).write_text(mutant)
PY
  case "$edit" in
    'release_suites=$release_share'*)
      run_release "$TMP/main/kendex" "$TMP/native/tools/guard" 3/3
      [ "$RC:$RAN" = '1:oversee_zzz zzz-caller zzz-second ' ] && ok 'control: an empty share runs the whole package' \
        || bad 'control: an empty share runs the whole package' "$RC $RAN $OUT" ;;
    release_suites=*)
      run_release "$TMP/main/kendex" "$TMP/native/tools/guard"
      [ "$RC:$RAN" = '1:oversee_zzz zzz-caller zzz-second ' ] && ok 'control: the whole package runs the suite no shard gives a kendex' \
        || bad 'control: the whole package runs the suite no shard gives a kendex' "$RC $RAN $OUT" ;;
    *)
      run_release "$TMP/main/kendex" "$TMP/native/tools/guard" 1/2
      [ "$RC:$RAN" = '0:zzz-caller zzz-second ' ] && ok 'control: an unsplit part runs the other part too' \
        || bad 'control: an unsplit part runs the other part too' "$RC $RAN $OUT" ;;
  esac
done
# Unreadable selection evidence runs the whole package, under a note, in an
# unsplit run. A part of a split run fails: its share is of a list the other
# parts may have read.
cp "$GUARD" "$TMP/native/tools/guard"
rm "$TMP/native/tools/ci-job-set"
run_release "$TMP/main/kendex" "$TMP/native/tools/guard"
[ "$RC:$RAN" = '1:oversee_zzz zzz-caller zzz-second ' ] && [[ "$OUT" == *'guard-note: suites=all reason=kendex-unread tree=skills/orch'* ]] \
  && ok 'an unread kendex selection runs the whole package' || bad 'an unread kendex selection runs the whole package' "$RC $RAN $OUT"
run_release "$TMP/main/kendex" "$TMP/native/tools/guard" 2/2
[ "$RC:$RAN" = '1:' ] && [[ "$OUT" == *'guard: kendex-unread=skills/orch'* ]] && [[ "$OUT" != *'reason=kendex-unread'* ]] \
  && ok 'an unread kendex selection fails a split part' || bad 'an unread kendex selection fails a split part' "$RC $RAN $OUT"
# Must-fail: a part that falls back as an unsplit run does runs its share of
# the whole package, a share the other parts did not split.
python3 - "$GUARD" "$TMP/native/tools/guard" <<'PY'
from pathlib import Path
import sys
source = Path(sys.argv[1]).read_text()
needle = 'elif [ "$release_parts" -gt 1 ]; then'
assert source.count(needle) == 1
mutant = source.replace(needle, 'elif false; then')
assert mutant != source
Path(sys.argv[2]).write_text(mutant)
PY
run_release "$TMP/main/kendex" "$TMP/native/tools/guard" 2/2
[ "$RC:$RAN" = '0:zzz-caller ' ] && ok 'control: a falling-back part runs a share of the whole package' \
  || bad 'control: a falling-back part runs a share of the whole package' "$RC $RAN $OUT"
cp "$GUARD" "$TMP/native/tools/guard"
ln -s "$REPO/tools/ci-job-set" "$TMP/native/tools/ci-job-set"
git -C "$R" reset -q --hard "$BASE"
git -C "$R" clean -qfd

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
