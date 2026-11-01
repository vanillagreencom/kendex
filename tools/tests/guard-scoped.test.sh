#!/usr/bin/env bash
# Direct launch coverage stays local; production caller coverage stays in CI.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$TEST_DIR/lib/guard-world.sh"

mkdir -p "$R/skills/orch/scripts" "$R/skills/orch/tests/lib" "$R/tools/tests"
printf '#!/usr/bin/env bash\nlaunch_status=0\n' > "$R/skills/orch/scripts/open-terminal"
printf 'source "$PWD/skills/orch/scripts/open-terminal"\n' > "$R/skills/orch/scripts/dispatcher"
printf 'source "$PWD/skills/orch/scripts/open-terminal"\n' > "$R/skills/orch/tests/lib/launch.sh"
for row in 'direct|scripts/open-terminal' 'helper|tests/lib/launch.sh' 'indirect|scripts/dispatcher'; do
  IFS='|' read -r name input <<<"$row"
  printf 'source "$PWD/skills/orch/%s"\nprintf "%s\\n" >> "$SUITE_LOG"\nexit "$launch_status"\n' "$input" "$name" > "$R/skills/orch/tests/$name.sh"
done
printf 'printf "named\\n" >> "$SUITE_LOG"\n' > "$R/skills/orch/tests/open-terminal.test.sh"
git -C "$R" config gc.auto 0
git -C "$R" config maintenance.auto false
git -C "$R" add -A
entry_points_executable
git -C "$R" commit -qm launch
BASE="$(git -C "$R" rev-parse HEAD)"
SUITE_LOG="$TMP/suites"

launch_selection() { # SCOPED STATUS GUARD
  printf '#!/usr/bin/env bash\nlaunch_status=%s\n# changed\n' "$2" > "$R/skills/orch/scripts/open-terminal"
  : > "$SUITE_LOG"
  RC=0
  OUT="$(cd "$R" && DEV_VALIDATE_SCOPED="$1" SUITE_LOG="$SUITE_LOG" "$3" --selection --range "$BASE" 2>&1)" || RC=$?
  SELECTED="$(sort "$SUITE_LOG" | tr '\n' ' ')"
}
for status in 0 1; do
  launch_selection true "$status" "$GUARD"
  [ "$RC" -eq "$status" ] && [ "$SELECTED" = 'direct helper named ' ] \
    && ok "open-terminal scoped fixture returns status $status with direct, named and helper coverage" \
    || bad "open-terminal scoped fixture returns status $status with direct, named and helper coverage" "rc=$RC selected=$SELECTED out=$OUT"
done

# Restore main's reach without removing any file text or input references.
# The same launch diff then executes every suite in this fixture's orch tree.
if mutant_guard '/^  if \[ "\$scoped_only" -eq 1 \] \&\& \[ "\${3:-reader}" != changed \]; then$/,/^  fi$/d'; then
  launch_selection true 0 "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 0 ] && [ "$SELECTED" = 'direct helper indirect named ' ] \
    && ok 'control: main reach selects the full launch fixture and breaks the direct-only assertion' \
    || bad 'control: main reach selects the full launch fixture and breaks the direct-only assertion' "rc=$RC selected=$SELECTED out=$OUT"
else
  bad 'control changes the scoped reach'
fi

# Normal range selection still includes the production caller. This is the
# mapper CI already owns, not the local scoped branch above.
printf '#!/usr/bin/env bash\nlaunch_status=0\n# changed\n' > "$R/skills/orch/scripts/open-terminal"
: > "$SUITE_LOG"
RC=0
OUT="$(cd "$R" && SUITE_LOG="$SUITE_LOG" "$GUARD" --range "$BASE" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && [ "$(sort "$SUITE_LOG" | tr '\n' ' ')" = 'direct helper indirect named ' ] \
  && ok 'normal range retains full production caller coverage' \
  || bad 'normal range retains full production caller coverage' "rc=$RC out=$OUT"

# A skill doc and its render, each read by a suite outside the skill: tools/
# reads the source, the orch consumer tree reads the render. tools/ also reads
# skills/AGENTS.md, Markdown in no skill package. The real tools/ci-job-set
# answers which trees the merge group runs: tools/ in its shards, the orch
# corpus in none until KEN-4733 (REVISIT(D026)), so the orch reader of a
# skill doc stays in the scoped run.
mkdir -p "$R/skills/demo/references" "$R/.agents/skills/demo/references"
printf '# Guide\n' > "$R/skills/demo/references/guide.md"
cp "$R/skills/demo/references/guide.md" "$R/.agents/skills/demo/references/guide.md"
printf '# Skills\n' > "$R/skills/AGENTS.md"
printf 'cat "$PWD/skills/demo/references/guide.md" >/dev/null\nprintf "doc-source\\n" >> "$SUITE_LOG"\n' > "$R/tools/tests/doc-source.sh"
printf 'cat "$PWD/skills/AGENTS.md" >/dev/null\nprintf "doc-outside\\n" >> "$SUITE_LOG"\n' > "$R/tools/tests/doc-outside.sh"
printf 'cat "$PWD/.agents/skills/demo/references/guide.md" >/dev/null\nprintf "doc-render\\n" >> "$SUITE_LOG"\n' > "$R/skills/orch/tests/doc-render.sh"
git -C "$R" add -A
entry_points_executable
git -C "$R" commit -qm docs
BASE="$(git -C "$R" rev-parse HEAD)"
doc_change() { # [script|outside]: edit the doc pair, and open-terminal or skills/AGENTS.md too
  printf '# Guide\nchanged\n' > "$R/skills/demo/references/guide.md"
  cp "$R/skills/demo/references/guide.md" "$R/.agents/skills/demo/references/guide.md"
  case "${1:-}" in
    script) printf '#!/usr/bin/env bash\nlaunch_status=0\n# beside docs\n' > "$R/skills/orch/scripts/open-terminal" ;;
    outside) printf '# Skills\nchanged\n' > "$R/skills/AGENTS.md" ;;
  esac
  : > "$SUITE_LOG"
}
doc_selection() { # GUARD: the scoped selection's selected-suite lines in PLAN
  RC=0
  OUT="$(cd "$R" && DEV_VALIDATE_SCOPED=true SUITE_LOG="$SUITE_LOG" "$1" --selection --range "$BASE" 2>&1)" || RC=$?
  PLAN="$(sed -n 's/^guard-note: selected-suite=//p' <<<"$OUT" | sort | tr '\n' ' ')"
  SELECTED="$(sort "$SUITE_LOG" | tr '\n' ' ')"
}
doc_change
doc_selection "$GUARD"
[ "$RC" -eq 0 ] && [ "$PLAN" = 'skills/orch/tests/doc-render.sh ' ] && [ "$SELECTED" = 'doc-render ' ] \
  && ok 'scoped: a skill doc and its render select only the reader CI does not run' \
  || bad 'scoped: a skill doc and its render select only the reader CI does not run' "rc=$RC plan=$PLAN selected=$SELECTED out=$OUT"
doc_change outside
doc_selection "$GUARD"
[ "$RC" -eq 0 ] && [ "$PLAN" = 'skills/orch/tests/doc-render.sh tools/tests/doc-outside.sh ' ] \
  && ok 'scoped: Markdown outside a skill package still selects its reader' \
  || bad 'scoped: Markdown outside a skill package still selects its reader' "rc=$RC plan=$PLAN out=$OUT"
git -C "$R" checkout -q -- skills/AGENTS.md
# An unread --suite-shards answer seeds each tree as on main, with its note.
cp "$GUARD" "$MUTANT_TOOLS/guard"
printf '#!/usr/bin/env bash\nexit 3\n' > "$MUTANT_TOOLS/ci-job-set"
chmod +x "$MUTANT_TOOLS/ci-job-set"
doc_change
doc_selection "$MUTANT_TOOLS/guard"
[ "$RC" -eq 0 ] && [ "$PLAN" = 'skills/orch/tests/doc-render.sh tools/tests/doc-source.sh ' ] \
  && grep -qx 'guard-note: merge-group-shards=unread tree=tools' <<<"$OUT" \
  && ok 'scoped: an unread shard answer seeds the skill doc readers' \
  || bad 'scoped: an unread shard answer seeds the skill doc readers' "rc=$RC plan=$PLAN out=$OUT"
cp "$REPO/tools/ci-job-set" "$MUTANT_TOOLS/ci-job-set"
doc_change script
doc_selection "$GUARD"
[ "$RC" -eq 0 ] && [ "$SELECTED" = 'direct doc-render helper named ' ] \
  && ok 'scoped: a script beside the docs still selects its own suites' \
  || bad 'scoped: a script beside the docs still selects its own suites' "rc=$RC selected=$SELECTED out=$OUT"
git -C "$R" checkout -q -- skills/orch/scripts/open-terminal
doc_change
RC=0
OUT="$(cd "$R" && SUITE_LOG="$SUITE_LOG" "$GUARD" --range "$BASE" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && [ "$(sort "$SUITE_LOG" | tr '\n' ' ')" = 'doc-render doc-source ' ] \
  && ok 'normal range runs both doc readers' \
  || bad 'normal range runs both doc readers' "rc=$RC out=$OUT"
git -C "$R" checkout -q -- skills/demo .agents/skills/demo

# .kendex-generated.json, read as data by a tools/ suite and an orch suite. A
# scoped run reads the rows the range changed: skill Markdown rows alone
# select no tools/ suite, and any other changed row, or a side that is no list
# of paths, maps the file as today. The orch reader runs on every row while
# the merge group runs no orch suite.
jq -n '[".agents/skills/demo/SKILL.md", ".agents/skills/demo/kendex.settings.toml.example",
  ".agents/skills/demo/references/guide.md", ".agents/skills/demo/scripts/tool", ".claude/skills/demo"]' \
  > "$R/.kendex-generated.json"
printf 'cat "$PWD/.kendex-generated.json" >/dev/null\nprintf "inventory-reader\\n" >> "$SUITE_LOG"\n' > "$R/tools/tests/inventory-reader.sh"
printf 'cat "$PWD/.kendex-generated.json" >/dev/null\nprintf "inventory-orch\\n" >> "$SUITE_LOG"\n' > "$R/skills/orch/tests/inventory-orch.sh"
git -C "$R" add -A
entry_points_executable
git -C "$R" commit -qm inventory
BASE="$(git -C "$R" rev-parse HEAD)"
ORCH_READER='skills/orch/tests/inventory-orch.sh '
READERS="${ORCH_READER}tools/tests/inventory-reader.sh "
inventory_change() { # JQ-FILTER: rewrite the inventory through the filter
  git -C "$R" show "$BASE:.kendex-generated.json" | jq "$1" > "$R/.kendex-generated.json"
  : > "$SUITE_LOG"
}
for row in \
  'markdown rows added;. + [".agents/skills/demo/references/new.md"] | sort;' \
  'a markdown row removed;map(select(. != ".agents/skills/demo/references/guide.md"));' \
  'a script row added;. + [".agents/skills/demo/scripts/extra"] | sort;reader' \
  'a settings row removed;map(select(. != ".agents/skills/demo/kendex.settings.toml.example"));reader' \
  'an agent render row added;. + [".claude/agents/demo.md"] | sort;reader' \
  'a markdown and a non-Markdown render row added;. + [".agents/skills/demo/references/new.md", ".claude/skills/other"] | sort;reader' \
  'a side that is no list of paths;{rows: .};reader'; do
  IFS=';' read -r name filter expected <<<"$row"
  if [ -n "$expected" ]; then expected=$READERS; else expected=$ORCH_READER; fi
  inventory_change "$filter"
  doc_selection "$GUARD"
  [ "$RC" -eq 0 ] && [ "$PLAN" = "$expected" ] \
    && ok "scoped inventory: $name" \
    || bad "scoped inventory: $name" "rc=$RC plan=$PLAN expected=$expected out=$OUT"
done
for filter in '. + [".agents/skills/demo/references/new.md"] | sort' '. + [".agents/skills/demo/scripts/extra"] | sort'; do
  inventory_change "$filter"
  RC=0
  OUT="$(cd "$R" && SUITE_LOG="$SUITE_LOG" "$GUARD" --range "$BASE" 2>&1)" || RC=$?
  [ "$RC" -eq 0 ] && [ "$(sort "$SUITE_LOG" | tr '\n' ' ')" = 'inventory-orch inventory-reader ' ] \
    && ok "normal range runs the inventory readers: $filter" \
    || bad "normal range runs the inventory readers: $filter" "rc=$RC out=$OUT"
done
git -C "$R" checkout -q -- .kendex-generated.json

# Python test programs directly under a skill's tests/, as skills/jarvis
# keeps them: each suite wrapper runs one by path. mod_test.py names the
# module and the script pytool by path; importer_test.py and from_test.py
# import mod_test by module name; other_test.py names another module of the
# same scripts/lib/ folder.
mkdir -p "$R/skills/pyreach/scripts/lib" "$R/skills/pyreach/tests"
printf '#!/usr/bin/env bash\nexec python3 "${0%%/*}/lib/mod.py"\n' > "$R/skills/pyreach/scripts/pyreach"
printf 'VALUE = 1\n' > "$R/skills/pyreach/scripts/lib/mod.py"
printf '#!/usr/bin/env bash\n:\n' > "$R/skills/pyreach/scripts/pytool"
printf 'VALUE = 2\n' > "$R/skills/pyreach/scripts/lib/other.py"
printf 'SOURCE = "skills/pyreach/scripts/lib/mod.py"\nTOOL = "skills/pyreach/scripts/pytool"\n' > "$R/skills/pyreach/tests/mod_test.py"
printf 'SOURCE = "skills/pyreach/scripts/lib/other.py"\n' > "$R/skills/pyreach/tests/other_test.py"
printf 'import mod_test\n' > "$R/skills/pyreach/tests/importer_test.py"
printf 'from mod_test import SOURCE\n' > "$R/skills/pyreach/tests/from_test.py"
for name in mod other importer from; do
  printf 'python3 -B "$PWD/skills/pyreach/tests/%s_test.py"\nprintf "%s\\n" >> "$SUITE_LOG"\n' "$name" "$name" \
    > "$R/skills/pyreach/tests/$name-wrapper.sh"
done
git -C "$R" add -A
entry_points_executable
git -C "$R" commit -qm python-tests
BASE="$(git -C "$R" rev-parse HEAD)"
PY_SELECTED='skills/pyreach/tests/from-wrapper.sh skills/pyreach/tests/importer-wrapper.sh skills/pyreach/tests/mod-wrapper.sh '
python_change() { # PATH: append to PATH, then take the scoped selection
  printf '# changed\n' >> "$R/$1"
  : > "$SUITE_LOG"
  doc_selection "$GUARD"
  git -C "$R" checkout -q -- "$1"
}
for path in skills/pyreach/scripts/lib/mod.py skills/pyreach/scripts/pytool skills/pyreach/tests/mod_test.py; do
  python_change "$path"
  [ "$RC" -eq 0 ] && [ "$PLAN" = "$PY_SELECTED" ] && [ "$SELECTED" = 'from importer mod ' ] \
    && ok "scoped: $path selects the wrappers of the Python tests naming or importing it" \
    || bad "scoped: $path selects the wrappers of the Python tests naming or importing it" "rc=$RC plan=$PLAN selected=$SELECTED out=$OUT"
done
# Outside a scoped run no scan reads a test program: a changed one, or a
# changed script only a test program names, runs the whole set.
python_range() { # PATH: append to PATH, then run the normal range
  printf '# changed\n' >> "$R/$1"
  : > "$SUITE_LOG"
  RC=0
  OUT="$(cd "$R" && SUITE_LOG="$SUITE_LOG" "$GUARD" --range "$BASE" 2>&1)" || RC=$?
  SELECTED="$(sort "$SUITE_LOG" | tr '\n' ' ')"
  git -C "$R" checkout -q -- "$1"
}
for path in skills/pyreach/tests/mod_test.py skills/pyreach/scripts/pytool; do
  python_range "$path"
  [ "$RC" -eq 0 ] && [ "$SELECTED" = 'from importer mod other ' ] \
    && ok "normal range: $path runs the whole set" \
    || bad "normal range: $path runs the whole set" "rc=$RC selected=$SELECTED out=$OUT"
done

# A real cancellation must also name suites in batteries not yet entered.
# The first selected suite acknowledges its start before the parent sends TERM.
printf 'source "$PWD/skills/orch/scripts/open-terminal"\nprintf ready > "$ACK"\nread -r line < "$FIFO"\n' > "$R/skills/orch/tests/direct.sh"
printf '# Inputs: skills/orch/scripts/open-terminal\nprintf "later\\n" >> "$SUITE_LOG"\n' > "$R/tools/tests/later.sh"
mkdir -p "$R/skills/orch/scripts/lib" "$R/skills/github/scripts/lib" "$TMP/serial-bin"
cp "$REPO/skills/orch/tests/run-all.sh" "$R/skills/orch/tests/run-all.sh"
cp "$REPO/skills/orch/tests/lib/git-env.sh" "$R/skills/orch/tests/lib/git-env.sh"
cp "$REPO/skills/orch/tests/lib/suite-process.sh" "$R/skills/orch/tests/lib/suite-process.sh"
cp "$REPO/skills/orch/scripts/lib/lane-state.sh" "$R/skills/orch/scripts/lib/lane-state.sh"
cp "$REPO/skills/github/scripts/lib/group-leader.sh" "$R/skills/github/scripts/lib/group-leader.sh"
printf '# Inputs: skills/orch/scripts/open-terminal\nif [ "$PHASE" = standalone ]; then printf ready > "$ACK"; read -r line < "$FIFO"; fi\nprintf "pass: 1 fail: 0\\n"\n' > "$R/hooks/tests/startup.sh"
printf '#!/bin/sh\necho 1\n' > "$TMP/serial-bin/nproc"
chmod +x "$TMP/serial-bin/nproc"
git -C "$R" add -A
entry_points_executable
git -C "$R" commit -qm cancellation
BASE="$(git -C "$R" rev-parse HEAD)"
printf '# changed\n' >> "$R/skills/orch/scripts/open-terminal"
if python3 - "$R" "$GUARD" "$BASE" "$TMP" <<'PY'
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

repo, guard, base, scratch = sys.argv[1:]
runner = Path(repo) / "skills/orch/tests/run-all.sh"
runner_text = runner.read_text()
grace_text = (Path(guard).parent.parent / "skills/orch/scripts/lib/job-unit.sh").read_text()
grace = int(next(line.split("=", 1)[1] for line in grace_text.splitlines()
                 if line.startswith("JOB_UNIT_KILL_GRACE=")))
packages = ["pi-extensions/startup", "pi-extensions/z-later"]
for name in packages:
  package = Path(repo) / name
  package.mkdir(parents=True, exist_ok=True)
  (package / "package.json").write_text('{"scripts":{"test":"fixture"}}\n')
subprocess.run(["git", "add", "pi-extensions"], cwd=repo, check=True)
npm = Path(scratch) / "serial-bin/npm"
npm.write_text('''#!/usr/bin/env bash
if [ "$1" = --version ]; then
  if [ "$PHASE" != npm-probe ]; then echo fixture; exit 0; fi
elif [ "$PHASE" = npm-later ]; then
  [ "${PWD##*/}" = z-later ] || exit 0
elif [ "$PHASE" != npm ]; then
  exit 0
fi
printf ready > "$ACK"
read -r line < "$FIFO"
''')
npm.chmod(0o755)
shell_suites = ["skills/orch/tests/direct.sh", "skills/orch/tests/helper.sh",
                "skills/orch/tests/open-terminal.test.sh", "tools/tests/later.sh"]
complete_plan = ["hooks/tests/startup.sh", *packages, *shell_suites]
# Each row stops a different execution state. The fallback consumes these
# machine-read suite paths, including later package batteries.
for phase, expected in (
    ("npm", [packages[1], *shell_suites]),
    ("standalone", [*packages, *shell_suites]),
    ("npm-probe", [*packages, *shell_suites]),
    ("npm-later", shell_suites),
    ("loading", shell_suites),
    ("running", ["helper", "open-terminal.test", "tools/tests/later.sh"]),
):
  ack, fifo = Path(scratch) / (phase + "-ready"), Path(scratch) / (phase + "-hold")
  os.mkfifo(fifo)
  text = runner_text
  if phase == "loading":
    marker = 'source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"'
    assert text.count(marker) == 1
    text = text.replace(marker, 'printf ready > "$ACK"\nread -r line < "$FIFO"\n' + marker)
  runner.write_text(text)
  env = dict(os.environ, DEV_VALIDATE_SCOPED="true", ACK=str(ack), FIFO=str(fifo), PHASE=phase,
             PATH=str(Path(scratch) / "serial-bin") + os.pathsep + os.environ["PATH"])
  process = subprocess.Popen([guard, "--selection", "--range", base], cwd=repo, env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                             start_new_session=True)
  try:
    deadline = time.monotonic() + 20
    while not ack.exists():
        if process.poll() is not None:
            raise AssertionError("guard ended before the suite acknowledgement: " + process.communicate()[0])
        assert time.monotonic() < deadline, "suite acknowledgement deadline"
        time.sleep(0.01)
    os.killpg(process.pid, signal.SIGTERM)
    output, _ = process.communicate(timeout=grace)
    assert process.returncode == 143, output
    selected = [line.removeprefix("guard-note: selected-suite=") for line in output.splitlines()
                if line.startswith("guard-note: selected-suite=")]
    assert selected == complete_plan, output
    unstarted = [line for line in output.splitlines() if line.startswith("unstarted suite=")]
    if phase not in ("running", "loading"):
        queued = [line.removeprefix("guard-note: unstarted-suite=") for line in output.splitlines()
                  if line.startswith("guard-note: unstarted-suite=")]
        assert queued == expected, output
        assert (queued == [packages[1], *shell_suites]) == (phase == "npm"), output
        assert not unstarted, output
    else:
        assert unstarted == ["unstarted suite=" + name for name in expected], output
        assert not any(line.startswith("guard-note: unstarted-suite=") for line in output.splitlines()), output
    print("pass: guard cancellation " + phase)
  finally:
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
PY
then ok 'guard cancellation reports queued suites during loading, npm and execution'
else bad 'guard cancellation reports queued suites during loading, npm and execution'
fi
printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
