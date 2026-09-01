#!/usr/bin/env bash
# Must-fail controls for every preflight lane. Each case plants one defect of
# a class the gate exists to catch and requires a finding attributed to the
# lane that owns it — a gate nobody has watched fail is not evidence. Lanes
# that need an optional tool skip loudly when it is absent rather than
# passing on a check that never ran.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
PF="$SKILL_DIR/scripts/preflight"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() {
  PASS=$((PASS + 1))
  printf '  ok    %s\n' "$1"
}
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"
}
skipped() { printf '  skip  %s (%s)\n' "$1" "$2"; }

seed() { # NAME — fixture in $R: committed baseline, origin/main, feature branch
  R="$TMP/$1"
  # Migrations sit one directory down and more than one is committed, so a
  # deleted one is a path the glob no longer finds on disk while its siblings
  # still match: the shape that catches a setting read with globbing on.
  mkdir -p "$R/docs" "$R/scripts" "$R/data" "$R/store/migrations" \
    "$R/src/main/resources/db/migration"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  printf '# Fixture\n\nSee `scripts/existing.sh`.\n' >"$R/README.md"
  printf '# Guide\n\nNothing here yet.\n' >"$R/docs/guide.md"
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho existing\n' >"$R/scripts/existing.sh"
  printf '#!/usr/bin/env bash\necho loose\n' >"$R/scripts/loose.sh"
  printf '{\n  "ok": true\n}\n' >"$R/data/config.json"
  printf 'CREATE TABLE t (id INTEGER);\n' >"$R/store/migrations/V1__init.sql"
  printf 'CREATE TABLE u (id INTEGER);\n' >"$R/store/migrations/V2__more.sql"
  printf 'CREATE TABLE s (id INTEGER);\n' >"$R/src/main/resources/db/migration/V1__init.sql"
  git -C "$R" add -A
  git -C "$R" commit -qm init
  git clone -q --bare "$R" "$R.git"
  git -C "$R" remote add origin "$R.git"
  git -C "$R" fetch -q origin
  git -C "$R" remote set-head origin main >/dev/null
  git -C "$R" checkout -qb feature
}

run_pf() { # [args...] — run in $R; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$PF" "$@" 2>&1)" || RC=$?
}

fires() { # LABEL EXPECTED-SUBSTRING — the run failed AND named the lane/path
  if [ "$RC" -eq 1 ] && case "$OUT" in *"$2"*) true ;; *) false ;; esac; then
    ok "$1"
  else
    bad "$1" "rc=$RC out=$OUT"
  fi
}

echo "=== lane shell-syntax: a script bash cannot parse ==="
seed syntax
printf '#!/usr/bin/env bash\nset -euo pipefail\necho "unterminated\n' >"$R/scripts/broken.sh"
git -C "$R" add -A
run_pf
fires "an unparseable new script fails, attributed to shell-syntax" "scripts/broken.sh:3: [shell-syntax]"

echo "=== lane shellcheck-errors: an error-severity defect bash still parses ==="
seed scerror
if command -v shellcheck >/dev/null 2>&1; then
  printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 300\n' >"$R/scripts/exitcode.sh"
  git -C "$R" add -A
  run_pf
  fires "an out-of-range exit status fails as a shellcheck error" "scripts/exitcode.sh:3: [shellcheck-errors] SC2242"
else
  skipped "shellcheck-errors must-fail control" "shellcheck not on PATH"
fi

echo "=== lane masked-returns: SC2155 on an added line ==="
seed masked
if command -v shellcheck >/dev/null 2>&1; then
  printf '#!/usr/bin/env bash\nset -euo pipefail\nf() {\n  local d="$(mktemp -d)"\n  echo "$d"\n}\nf\n' >"$R/scripts/masked.sh"
  git -C "$R" add -A
  run_pf
  fires "a masking local-and-assign fails on the line that introduced it" "scripts/masked.sh:4: [masked-returns] SC2155"
else
  skipped "masked-returns must-fail control" "shellcheck not on PATH"
fi

echo "=== lane fail-open: unchecked mktemp in a file without errexit ==="
seed mktemp
printf '#!/usr/bin/env bash\necho loose\nTMP="$(mktemp -d)"\necho "$TMP"\n' >"$R/scripts/loose.sh"
git -C "$R" add -A
run_pf
fires "an mktemp assignment in an errexit-less file fails as fail-open" "scripts/loose.sh:3: [fail-open] unchecked mktemp"

echo "=== lane fail-open: a new script without strict mode ==="
seed strict
printf '#!/usr/bin/env bash\necho fresh\n' >"$R/scripts/fresh.sh"
git -C "$R" add -A
run_pf
fires "a new script that never sets -e/-u/pipefail fails as fail-open" "scripts/fresh.sh:0: [fail-open] new shell file without strict mode"

echo "=== lane fail-open: a status-swallowing || true ==="
seed swallow
printf '#!/usr/bin/env bash\nset -euo pipefail\necho existing\ngrep -q x -- "$1" || true\nn="$(git rev-list --count HEAD || true)"\necho "$n"\n' >"$R/scripts/existing.sh"
git -C "$R" add -A
run_pf
fires "grep || true fails as fail-open, naming the command whose status is lost" "scripts/existing.sh:4: [fail-open] grep || true swallows exit 2"
fires "the shape is caught inside a command substitution too" "scripts/existing.sh:5: [fail-open] git || true swallows exit 2"

echo "=== lane mktemp-trap: a new script whose scratch nothing removes ==="
seed scratch
printf '#!/usr/bin/env bash\nset -euo pipefail\nD="$(mktemp -d)"\necho "$D"\n' >"$R/scripts/scratch.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\nF="$(mktemp)"\necho "$F"\n' >"$R/scripts/scratchfile.sh"
git -C "$R" add -A
run_pf
fires "a new script with mktemp and no EXIT trap fails as mktemp-trap" "scripts/scratch.sh:3: [mktemp-trap] mktemp without an EXIT trap"
fires "an mktemp with no arguments is the same finding" "scripts/scratchfile.sh:3: [mktemp-trap] mktemp without an EXIT trap"

echo "=== lane hardcoded-temp-path: directory creation at a literal absolute temp path ==="
seed tmppath
mkdir -p "$R/src"
# Trip paths are substituted at run time: the generated FIXTURE repo carries
# the literals by design, while this suite's own committed bytes never join
# a creation call to one.
printf '#!/usr/bin/env bash\nset -euo pipefail\nmkdir -p %s/cache\n' /tmp >"$R/scripts/shellmk.sh"
printf 'const fs = require("fs");\nfs.mkdirSync("%s/out");\nfs.mkdtempSync("%s/app-");\nfs.mkdtempSync("%s");\n' /tmp /tmp /tmp >"$R/src/mk.js"
printf 'import os, tempfile\nos.makedirs("%s/state")\ntempfile.mkdtemp(dir="%s/keep")\ntempfile.mkdtemp(dir="%s")\n' /tmp /tmp /tmp >"$R/src/mk.py"
printf 'fn main() {\n    std::fs::create_dir_all("%s/rust").unwrap();\n}\n' /tmp >"$R/src/mk.rs"
printf 'import os\nos.mkdir("%s/persist")\n' /var/tmp >"$R/src/mkvar.py"
git -C "$R" add -A
run_pf
fires "a shell mkdir -p at a literal /tmp path fails" "scripts/shellmk.sh:3: [hardcoded-temp-path]"
fires "a JS mkdirSync taking the literal fails" "src/mk.js:2: [hardcoded-temp-path]"
fires "a JS mkdtempSync prefix under /tmp is the same finding" "src/mk.js:3: [hardcoded-temp-path]"
fires "a Python makedirs taking the literal fails" "src/mk.py:2: [hardcoded-temp-path]"
fires "a Python mkdtemp aimed at /tmp by keyword fails" "src/mk.py:3: [hardcoded-temp-path]"
fires "a bare-root mkdtemp keyword (dir=/tmp, no trailing slash) fails" "src/mk.py:4: [hardcoded-temp-path]"
fires "the JS bare-root prefix form (mkdtempSync(/tmp) making a /tmpXXXXXX sibling) fails" "src/mk.js:4: [hardcoded-temp-path]"
fires "a Rust create_dir_all taking the literal fails" "src/mk.rs:2: [hardcoded-temp-path]"
fires "/var/tmp is the same literal" "src/mkvar.py:2: [hardcoded-temp-path]"

echo "=== lane unwired-suite: a new suite no runner invokes ==="
seed unwired
mkdir -p "$R/tests" "$R/.github/workflows"
cat >"$R/.github/workflows/ci.yml" <<'YML'
name: ci
on: push
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/known.test.sh
YML
printf '#!/usr/bin/env bash\nset -euo pipefail\necho known\n' >"$R/tests/known.test.sh"
printf '#!/usr/bin/env bash\nset -euo pipefail\necho orphan\n' >"$R/tests/orphan.test.sh"
git -C "$R" add -A
run_pf
fires "a new suite named by no runner fails as unwired-suite" "tests/orphan.test.sh:0: [unwired-suite] new suite is not invoked by any runner"
case "$OUT" in
  *"tests/known.test.sh"*) bad "the suite the workflow names is not a finding" "out=$OUT" ;;
  *) ok "the suite the workflow names is not a finding" ;;
esac

# A suite that arrived by `git mv` is a new file at its new path: rename
# detection must not hide it from the new-file lanes.
seed renamed
mkdir -p "$R/tests" "$R/.github/workflows"
cat >"$R/.github/workflows/ci.yml" <<'YML'
name: ci
on: push
jobs:
  t:
    runs-on: ubuntu-latest
    steps:
      - run: bash tests/known.test.sh
YML
printf '#!/usr/bin/env bash\nset -euo pipefail\necho moved\n' >"$R/scripts/moved.sh"
git -C "$R" add -A
git -C "$R" commit -qm base
git -C "$R" mv scripts/moved.sh tests/moved.test.sh
run_pf
fires "a suite renamed into place is judged as the new file it is" "tests/moved.test.sh:0: [unwired-suite]"
run_pf --staged
fires "the same holds in staged scope" "tests/moved.test.sh:0: [unwired-suite]"

echo "=== lane docs-cited-paths: a backticked path that does not exist ==="
seed docs
printf '# Fixture\n\nSee `scripts/existing.sh`.\nAnd `docs/gone.md` for the rest.\n' >"$R/README.md"
git -C "$R" add -A
run_pf
fires "a citation of a missing file under a real directory fails" "README.md:4: [docs-cited-paths] cites a path that does not exist: docs/gone.md"

echo "=== lane docs-cited-paths: a source line citing a doc that does not exist ==="
seed srccite
mkdir -p "$R/src"
printf '#!/usr/bin/env bash\nset -euo pipefail\n# Read docs/gone.md before editing this.\necho run\n' >"$R/scripts/cite.sh"
printf 'fn main() {\n    // The mode table lives in docs/gone.md.\n}\n' >"$R/src/main.rs"
git -C "$R" add -A
run_pf
fires "a shell comment citing a missing doc fails at its line" "scripts/cite.sh:3: [docs-cited-paths] cites a path that does not exist: docs/gone.md"
fires "a non-shell source comment is judged the same way" "src/main.rs:2: [docs-cited-paths] cites a path that does not exist: docs/gone.md"

echo "=== lane data-syntax: malformed JSON ==="
seed json
if command -v jq >/dev/null 2>&1; then
  printf '{\n  "ok": true,\n}\n' >"$R/data/config.json"
  git -C "$R" add -A
  run_pf
  fires "a JSON file jq cannot parse fails as data-syntax" "data/config.json:3: [data-syntax] invalid JSON"
else
  skipped "data-syntax JSON must-fail control" "jq not on PATH"
fi

echo "=== lane data-syntax: malformed TOML ==="
seed toml
if command -v taplo >/dev/null 2>&1 || { command -v python3 >/dev/null 2>&1 && python3 -c 'import tomllib' >/dev/null 2>&1; }; then
  printf '[table]\nkey = "unterminated\n' >"$R/data/bad.toml"
  git -C "$R" add -A
  run_pf
  fires "a TOML file no parser accepts fails as data-syntax" "data/bad.toml:2: [data-syntax] invalid TOML"
else
  skipped "data-syntax TOML must-fail control" "no taplo and no python3 with tomllib"
fi

echo "=== lane applied-migration-edited: a migration a database has already run ==="
seed migrationedit
printf 'CREATE TABLE t (id INTEGER); -- clearer\n' >"$R/store/migrations/V1__init.sql"
git -C "$R" add -A
run_pf
fires "editing a migration the base already carried fails" "store/migrations/V1__init.sql:0: [applied-migration-edited] an applied migration was edited"
run_pf --staged
fires "the staged scope sees the same edit" "store/migrations/V1__init.sql:0: [applied-migration-edited]"

seed migrationflyway
printf 'CREATE TABLE s (id INTEGER); -- clearer\n' >"$R/src/main/resources/db/migration/V1__init.sql"
git -C "$R" add -A
run_pf
fires "Flyway's own directory is in the default set" "src/main/resources/db/migration/V1__init.sql:0: [applied-migration-edited] an applied migration was edited"

seed migrationdelete
git -C "$R" rm -q store/migrations/V1__init.sql
run_pf
fires "deleting one is the same finding" "store/migrations/V1__init.sql:0: [applied-migration-edited] an applied migration was deleted"

seed migrationrename
# A repo that turns rename detection off would otherwise see the move as a
# delete and an add, and the finding would not say where the file went.
git -C "$R" config diff.renames false
git -C "$R" mv store/migrations/V2__more.sql store/migrations/V2__later.sql
run_pf
fires "renaming one names where it went" "store/migrations/V2__more.sql:0: [applied-migration-edited] an applied migration was renamed to store/migrations/V2__later.sql"

echo "=== the verdict line counts findings and changed files ==="
seed verdict
printf '# Guide\n\nNothing here yet.\n\nSee `docs/gone.md`.\nAnd `docs/missing.md`.\n' >"$R/docs/guide.md"
git -C "$R" add -A
run_pf
fires "the summary names both counts" "preflight: 2 finding(s) across 1 changed file(s)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
