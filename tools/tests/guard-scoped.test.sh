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

# kendex.settings.toml in a scoped run: each changed [env] key seeds the
# suites naming it. skills/settings declares FIXTURE_READ_KEY and holds its
# reader and a suite writing a settings file of its own; skills/area
# declares FIXTURE_AREA_KEY, commented out, and no test of it names the key;
# no example declares FIXTURE_LOOSE_KEY. skills/second-opinion declares its
# reviewer key family alone, and no test of it names a key. skills/keyed has
# an example render and a test module naming FIXTURE_OLD_KEY, which both
# copies declare, and FIXTURE_NEW_KEY, which neither declares yet. tools/
# holds a copier noting the file alone and one noting it first in a comma list. Every
# key a row edits is appended here, never one of the copied live file.
printf '\nFIXTURE_READ_KEY = "a"\nFIXTURE_AREA_KEY = "b"\nFIXTURE_LOOSE_KEY = "c"\nSECOND_OPINION_FIXTURE_CMD = "d"\n' >> "$R/kendex.settings.toml"
mkdir -p "$R/skills/settings/tests" "$R/skills/area/tests" "$R/skills/second-opinion/tests"
printf '[env]\n# keys: SECOND_OPINION_<NAME>_CMD SECOND_OPINION_<NAME>_MODEL\n' > "$R/skills/second-opinion/kendex.settings.toml.example"
printf '[env]\nFIXTURE_READ_KEY = "a"\n' > "$R/skills/settings/kendex.settings.toml.example"
printf '[env]\n# FIXTURE_AREA_KEY = "b"\n' > "$R/skills/area/kendex.settings.toml.example"
printf 'grep -q FIXTURE_READ_KEY "$PWD/kendex.settings.toml"\nprintf "reader\\n" >> "$SUITE_LOG"\n' > "$R/skills/settings/tests/reader.sh"
printf 'own=$(mktemp -d)\nprintf "[env]\\nOWN = \\"1\\"\\n" > "$own/kendex.settings.toml"\nrm -rf "$own"\nprintf "writer\\n" >> "$SUITE_LOG"\n' > "$R/skills/settings/tests/writer.sh"
printf '# Inputs: skills/settings/kendex.settings.toml.example\nprintf "example-noted\\n" >> "$SUITE_LOG"\n' > "$R/skills/settings/tests/example-noted.sh"
for name in one two; do
  printf 'printf "%s\\n" >> "$SUITE_LOG"\n' "$name" > "$R/skills/area/tests/$name.sh"
  printf 'printf "review-%s\\n" >> "$SUITE_LOG"\n' "$name" > "$R/skills/second-opinion/tests/$name.sh"
done
mkdir -p "$R/skills/keyed/tests/lib" "$R/.agents/skills/keyed"
printf '[env]\nFIXTURE_OLD_KEY = "a"\n' > "$R/skills/keyed/kendex.settings.toml.example"
cp "$R/skills/keyed/kendex.settings.toml.example" "$R/.agents/skills/keyed/kendex.settings.toml.example"
printf 'KEYS = ("FIXTURE_OLD_KEY", "FIXTURE_NEW_KEY")\n' > "$R/skills/keyed/tests/lib/world.py"
printf 'python3 -B "$PWD/skills/keyed/tests/lib/world.py"\nprintf "keyed-reader\\n" >> "$SUITE_LOG"\n' > "$R/skills/keyed/tests/reader.sh"
printf 'printf "keyed-other\\n" >> "$SUITE_LOG"\n' > "$R/skills/keyed/tests/other.sh"
printf '# Inputs: kendex.settings.toml\ncat "$PWD/kendex.settings.toml" >/dev/null\nprintf "copy\\n" >> "$SUITE_LOG"\n' > "$R/tools/tests/settings-copy.sh"
printf '# Inputs: kendex.settings.toml, skills/demo/scripts/demo.sh\nprintf "listed\\n" >> "$SUITE_LOG"\n' > "$R/tools/tests/settings-listed.sh"
git -C "$R" add -A
entry_points_executable
git -C "$R" commit -qm settings
BASE="$(git -C "$R" rev-parse HEAD)"
settings_change() { # CHANGE: one edit of the settings world, then a clean SUITE_LOG
  case "$1" in
    read-key) sed -i.bak 's/^FIXTURE_READ_KEY = "a"$/FIXTURE_READ_KEY = "z"/' "$R/kendex.settings.toml" ;;
    area-key) sed -i.bak 's/^FIXTURE_AREA_KEY = "b"$/FIXTURE_AREA_KEY = "z"/' "$R/kendex.settings.toml" ;;
    loose-key) sed -i.bak 's/^FIXTURE_LOOSE_KEY = "c"$/FIXTURE_LOOSE_KEY = "z"/' "$R/kendex.settings.toml" ;;
    family-key) sed -i.bak 's/^SECOND_OPINION_FIXTURE_CMD = "d"$/SECOND_OPINION_FIXTURE_CMD = "z"/' "$R/kendex.settings.toml" ;;
    foreign-table) printf '[other]\nFIXTURE_READ_KEY = "z"\n' >> "$R/kendex.settings.toml" ;;
    comment) printf '# changed\n\n' >> "$R/kendex.settings.toml" ;;
    noted-example) printf '# changed\n' >> "$R/skills/settings/kendex.settings.toml.example" ;;
    named-example-key | unnamed-example-key)
      key=FIXTURE_NEW_KEY
      [ "$1" = named-example-key ] || key=FIXTURE_UNNAMED_KEY
      for example in skills/keyed .agents/skills/keyed; do
        printf '%s = "b"\n' "$key" >> "$R/$example/kendex.settings.toml.example"
      done
      ;;
    changed-example-value)
      for example in skills/keyed .agents/skills/keyed; do
        printf '[env]\nFIXTURE_OLD_KEY = "z"\n' > "$R/$example/kendex.settings.toml.example"
      done
      ;;
  esac
  rm -f "$R/kendex.settings.toml.bak"
  [ -n "$(git -C "$R" status --porcelain)" ] || { bad "settings fixture change $1 changed nothing"; }
  : > "$SUITE_LOG"
}
KEY_READERS='skills/settings/tests/reader.sh tools/tests/settings-copy.sh tools/tests/settings-listed.sh '
PATH_READERS='skills/settings/tests/reader.sh skills/settings/tests/writer.sh tools/tests/settings-copy.sh tools/tests/settings-listed.sh '
NOTED='tools/tests/settings-copy.sh tools/tests/settings-listed.sh '
for row in \
  "a changed key selects its reader and the noted copiers, not a suite writing its own file|read-key|$KEY_READERS" \
  "a declared key no test of its tree names selects that tree's whole set|area-key|skills/area/tests/one.sh skills/area/tests/two.sh $NOTED" \
  "a key of a declared family selects that tree's whole set, not the file's path readers|family-key|skills/second-opinion/tests/one.sh skills/second-opinion/tests/two.sh $NOTED" \
  "a changed key no example declares maps the file by path|loose-key|$PATH_READERS" \
  "a foreign table maps the file by path|foreign-table|$PATH_READERS" \
  "comments and blank lines select only the noted copiers|comment|$NOTED" \
  "a comment-only example change selects the suite noting it|noted-example|skills/settings/tests/example-noted.sh " \
  "an example and its render adding a key a test module names select its reader|named-example-key|skills/keyed/tests/reader.sh " \
  "an example and its render adding a key no test names select the tree's whole set|unnamed-example-key|skills/keyed/tests/other.sh skills/keyed/tests/reader.sh " \
  "an example and its render changing a named key's value select its reader|changed-example-value|skills/keyed/tests/reader.sh "; do
  IFS='|' read -r name change expected <<<"$row"
  settings_change "$change"
  doc_selection "$GUARD"
  [ "$RC" -eq 0 ] && [ "$PLAN" = "$expected" ] \
    && ok "scoped settings: $name" \
    || bad "scoped settings: $name" "rc=$RC plan=$PLAN expected=$expected out=$OUT"
  git -C "$R" checkout -q -- .
done
# Unscoped, the same key change maps the file by path as before.
settings_change read-key
RC=0
OUT="$(cd "$R" && SUITE_LOG="$SUITE_LOG" "$GUARD" --range "$BASE" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && [ "$(sort "$SUITE_LOG" | tr '\n' ' ')" = 'copy listed reader writer ' ] \
  && ok 'normal range maps a settings key change by path' \
  || bad 'normal range maps a settings key change by path' "rc=$RC out=$OUT"
git -C "$R" checkout -q -- .
# Control: reading the settings file by path again selects the writer.
if mutant_guard '/^  if \[ -n "\${2-}" \]; then$/,/^  fi$/d'; then
  settings_change read-key
  doc_selection "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 0 ] && [ "$PLAN" = "$PATH_READERS" ] \
    && ok 'control: the path seed selects the writer and breaks the key row' \
    || bad 'control: the path seed selects the writer and breaks the key row' "rc=$RC plan=$PLAN out=$OUT"
  git -C "$R" checkout -q -- .
else
  bad 'control changes the settings seed'
fi
# Control: without the settings-example role, its render is a path of no role.
if mutant_guard '/^    skills\/\*:kendex\.settings\.toml\.example)$/,/^      ;;$/d'; then
  settings_change named-example-key
  doc_selection "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 0 ] && [ "$PLAN" = 'skills/keyed/tests/other.sh skills/keyed/tests/reader.sh ' ] \
    && grep -qx 'guard-note: suites=all reason=unidentified path=.agents/skills/keyed/kendex.settings.toml.example' <<<"$OUT" \
    && ok 'control: the render read by path selects the whole set and breaks the example key row' \
    || bad 'control: the render read by path selects the whole set and breaks the example key row' "rc=$RC plan=$PLAN out=$OUT"
  git -C "$R" checkout -q -- .
else
  bad 'control changes the example key queries'
fi
# Control: comparing only which keys the example declares misses a value change.
if mutant_guard 's/settings_declared --lines/settings_declared -/'; then
  settings_change changed-example-value
  doc_selection "$MUTANT_TOOLS/guard"
  [ "$RC" -eq 0 ] && [ -z "$PLAN" ] \
    && ok 'control: comparing declared keys alone selects no suite and breaks the value row' \
    || bad 'control: comparing declared keys alone selects no suite and breaks the value row' "rc=$RC plan=$PLAN out=$OUT"
  git -C "$R" checkout -q -- .
else
  bad 'control changes the example line comparison'
fi

# A tree with no run-all.sh runs each suite through guard's direct loop.
# skills/jarvis is such a tree, and a child of its session.test.sh reads
# stdin. Here a-reader reads stdin, whole or one line, and every suite names
# the changed script. A suite named by SIGNAL_SUITE sends the guard TERM once
# it has logged, so the guard's signal report names what it had not started.
mkdir -p "$R/skills/stdin/scripts" "$R/skills/stdin/tests"
printf '#!/usr/bin/env bash\n:\n' > "$R/skills/stdin/scripts/tool"
for name in a-reader b-later c-later d-later; do
  {
    printf '"$PWD/skills/stdin/scripts/tool"\n'
    [ "$name" != a-reader ] || printf 'case "$READ_MODE" in whole) cat >/dev/null ;; line) read -r _ || : ;; esac\n'
    printf 'printf "%s\\n" >> "$SUITE_LOG"\n' "$name"
    printf '[ "$SIGNAL_SUITE" != %s ] || kill -TERM "$GUARD_PID"\n' "$name"
  } > "$R/skills/stdin/tests/$name.sh"
done
git -C "$R" add -A
entry_points_executable
git -C "$R" commit -qm stdin
BASE="$(git -C "$R" rev-parse HEAD)"
stdin_row() { # GUARD ROW: run the normal range over a changed tool; fails naming what differs
  local guard=$1 name read_mode signal want_rc want_ran want_left rc=0 out ran left
  IFS='|' read -r name read_mode signal want_rc want_ran want_left <<<"$2"
  printf '# changed\n' >> "$R/skills/stdin/scripts/tool"
  : > "$SUITE_LOG"
  out="$(cd "$R" && READ_MODE="$read_mode" SIGNAL_SUITE="$signal" SUITE_LOG="$SUITE_LOG" \
    bash -c 'export GUARD_PID=$$; exec "$0" --range "$1"' "$guard" "$BASE" 2>&1)" || rc=$?
  git -C "$R" checkout -q -- skills/stdin/scripts/tool
  ran="$(sort "$SUITE_LOG" | tr '\n' ' ')"
  left="$(sed -n 's#^guard-note: unstarted-suite=skills/stdin/tests/\(.*\)\.sh$#\1#p' <<<"$out" | tr '\n' ' ')"
  [ "$rc" = "$want_rc" ] && [ "$ran" = "$want_ran" ] && [ "$left" = "$want_left" ] && return 0
  ROW_DETAIL="$name: rc=$rc ran=$ran unstarted=$left out=$out"
  return 1
}
# name | a-reader's read | suite that signals | exit | suites run | suites reported unstarted
STDIN_ROWS=(
  'whole-read|whole||0|a-reader b-later c-later d-later |'
  'one-line|line||0|a-reader b-later c-later d-later |'
  'one-line-then-signal|line|c-later|143|a-reader b-later c-later |d-later '
)
for row in "${STDIN_ROWS[@]}"; do
  stdin_row "$GUARD" "$row" \
    && ok "direct loop: ${row%%|*} runs or reports every selected suite" \
    || bad "direct loop: ${row%%|*} runs or reports every selected suite" "$ROW_DETAIL"
done
# The loop shape before this guarantee: the list on the loop's stdin, which
# the child inherits, and a remainder kept by stripping up to each entry
# read. Every row must fail against it.
if mutant_guard '/^    direct_suites=()$/d
s/^    while IFS= read -r t; do direct_suites+=("\$t"); done <<<"\$run"$/    while IFS= read -r t; do/
/^    for ((direct_index = 0; /d
/^      t=\${direct_suites\[direct_index\]}$/d
/^      # One assignment, so the signal report sees a complete remainder\.$/,/^      suite_runs\[suite_index\]=\$direct_later$/c\
      suite_runs[suite_index]=${suite_runs[suite_index]#*"$t"}
s#--local --suite "\$t" </dev/null ||#--local --suite "$t" ||#
/--local --suite "\$t" ||/{
n
s/^    done$/    done <<<"$run"/
}'; then
  for row in "${STDIN_ROWS[@]}"; do
    stdin_row "$MUTANT_TOOLS/guard" "$row" \
      && bad "control: the stdin-fed loop breaks direct loop row ${row%%|*}" \
      || ok "control: the stdin-fed loop breaks direct loop row ${row%%|*}"
  done
else
  bad 'control restores the stdin-fed direct loop'
fi

# A real cancellation must also name suites in batteries not yet entered.
# Each phase holds on its FIFO; the parent sends TERM only once its
# non-blocking writer open proves a holder is there, then releases the hold.
printf 'source "$PWD/skills/orch/scripts/open-terminal"\nread -r line < "$FIFO"\n' > "$R/skills/orch/tests/direct.sh"
printf '# Inputs: skills/orch/scripts/open-terminal\nprintf "later\\n" >> "$SUITE_LOG"\n' > "$R/tools/tests/later.sh"
mkdir -p "$R/skills/orch/scripts/lib" "$R/skills/github/scripts/lib" "$TMP/serial-bin"
cp "$REPO/skills/orch/tests/run-all.sh" "$R/skills/orch/tests/run-all.sh"
cp "$REPO/skills/orch/tests/lib/git-env.sh" "$R/skills/orch/tests/lib/git-env.sh"
cp "$REPO/skills/orch/tests/lib/suite-process.sh" "$R/skills/orch/tests/lib/suite-process.sh"
cp "$REPO/skills/orch/scripts/lib/lane-state.sh" "$R/skills/orch/scripts/lib/lane-state.sh"
cp "$REPO/skills/github/scripts/lib/group-leader.sh" "$R/skills/github/scripts/lib/group-leader.sh"
printf '# Inputs: skills/orch/scripts/open-terminal\nif [ "$PHASE" = standalone ]; then read -r line < "$FIFO"; fi\nprintf "pass: 1 fail: 0\\n"\n' > "$R/hooks/tests/startup.sh"
printf '#!/bin/sh\necho 1\n' > "$TMP/serial-bin/nproc"
chmod +x "$TMP/serial-bin/nproc"
git -C "$R" add -A
entry_points_executable
git -C "$R" commit -qm cancellation
BASE="$(git -C "$R" rev-parse HEAD)"
printf '# changed\n' >> "$R/skills/orch/scripts/open-terminal"
if python3 - "$R" "$GUARD" "$BASE" "$TMP" <<'PY'
import errno
import os
from pathlib import Path
import signal
import subprocess
import sys
import time

repo, guard, base, scratch = sys.argv[1:]
runner = Path(repo) / "skills/orch/tests/run-all.sh"
runner_text = runner.read_text()
# The phase holds below rewrite the runner. They are harness, not a change
# under test: a changed run-all.sh selects its tree's whole set.
subprocess.run(["git", "update-index", "--skip-worktree", "skills/orch/tests/run-all.sh"], cwd=repo, check=True)
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
  fifo = Path(scratch) / (phase + "-hold")
  os.mkfifo(fifo)
  text = runner_text
  if phase == "loading":
    # The runner owns the TERM trap this row reads, so its hold ignores TERM:
    # the signal stays pending in the runner until the parent releases the
    # hold, the worst order a hold entered around the signal can take.
    marker = 'source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"'
    assert text.count(marker) == 1
    text = text.replace(marker, 'sh -c \'trap "" TERM; read -r line < "$FIFO"\'\n' + marker)
  runner.write_text(text)
  env = dict(os.environ, DEV_VALIDATE_SCOPED="true", FIFO=str(fifo), PHASE=phase,
             PATH=str(Path(scratch) / "serial-bin") + os.pathsep + os.environ["PATH"])
  process = subprocess.Popen([guard, "--selection", "--range", base], cwd=repo, env=env,
                             stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True,
                             start_new_session=True)
  writer = None
  try:
    deadline = time.monotonic() + 20
    while writer is None:
        try:
            writer = os.open(fifo, os.O_WRONLY | os.O_NONBLOCK)
        except OSError as error:
            if error.errno != errno.ENXIO:
                raise
            if process.poll() is not None:
                raise AssertionError("guard ended before the phase held its FIFO: " + process.communicate()[0])
            assert time.monotonic() < deadline, "phase hold deadline"
            time.sleep(0.01)
    os.killpg(process.pid, signal.SIGTERM)
    os.close(writer)
    writer = None
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
    if writer is not None:
        os.close(writer)
    if process.poll() is None:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait()
PY
then ok 'guard cancellation reports queued suites during loading, npm and execution'
else bad 'guard cancellation reports queued suites during loading, npm and execution'
fi
printf '\npass: %s   fail: %s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
