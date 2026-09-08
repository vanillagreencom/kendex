#!/usr/bin/env bash
# Must-fail controls for every preflight lane. Each row plants one defect of
# a class the gate exists to catch and pins the whole fired set: exit 1, the
# planted finding attributed to the lane that owns it, and no other finding,
# so a fixture that also trips a neighbouring lane cannot pass on it. Lanes
# that need an optional tool skip loudly when it is absent rather than
# passing on a check that never ran.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

seed() { # NAME — fixture in $R: committed baseline, origin/main, feature branch
  R="$TMP/$1"
  rm -rf -- "${TMP:?}/$1" "${TMP:?}/$1.git"
  # Migrations sit one directory down and more than one is committed, so a
  # deleted one is a path the glob does not find on disk while its siblings
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

# A workflow that runs one named suite, for the unwired-suite worlds.
seed_runner() {
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
}

# One planted defect per world, on top of the seeded fixture, staged. The
# temp-path literals are substituted at run time: the generated fixture
# carries them by design, while this suite's own committed bytes never join
# a creation call to one.
pf_world() {
  seed "$1"
  case "$1" in
    syntax) printf '#!/usr/bin/env bash\nset -euo pipefail\nif [ 1 = 1 ]; then\n' >"$R/scripts/broken.sh" ;;
    scerror) printf '#!/usr/bin/env bash\nset -euo pipefail\nexit 300\n' >"$R/scripts/exitcode.sh" ;;
    masked) printf '#!/usr/bin/env bash\nset -euo pipefail\ntrap '"'"'echo done'"'"' EXIT\nf() {\n  local d="$(mktemp -d)"\n  echo "$d"\n}\nf\n' >"$R/scripts/masked.sh" ;;
    mktemp) printf '#!/usr/bin/env bash\necho loose\nTMP="$(mktemp -d)"\necho "$TMP"\n' >"$R/scripts/loose.sh" ;;
    strict) printf '#!/usr/bin/env bash\necho fresh\n' >"$R/scripts/fresh.sh" ;;
    swallow) printf '#!/usr/bin/env bash\nset -euo pipefail\necho existing\ngrep -q x -- "$1" || true\n' >"$R/scripts/existing.sh" ;;
    swallowsubst) printf '#!/usr/bin/env bash\nset -euo pipefail\necho existing\nn="$(git rev-list --count HEAD || true)"\necho "$n"\n' >"$R/scripts/existing.sh" ;;
    # Written from the shell, never with cat reading a file: a cat-fed
    # fixture pushes several hundred KB before it blocks, so it passes
    # either way.
    earlyclose) printf '#!/usr/bin/env bash\nset -euo pipefail\nif echo "$1" | grep -q x; then echo hit; fi\n' >"$R/scripts/existing.sh" ;;
    # The guard sits at the far edge of the look-ahead window: the
    # assignment is on line 3 and the test of $ROOT on line 7, four lines
    # below it. A narrower window stops finding this. The assignment is bare
    # on purpose: a `readonly` or `local` in front would mask the
    # substitution's status and the script would survive, which is the
    # masked-returns lane's shape, not this one's.
    bareassign)
      {
        printf '#!/usr/bin/env bash\n'
        printf 'set -euo pipefail\n'
        printf 'ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"\n'
        printf 'log() {\n'
        printf '  printf "%%s\\n" "$1" >&2\n'
        printf '}\n'
        printf 'if [ -z "$ROOT" ]; then\n'
        printf '  log "not inside a repository"\n'
        printf '  exit 1\n'
        printf 'fi\n'
        printf 'echo "$ROOT"\n'
      } >"$R/scripts/bare.sh"
      ;;
    # An operator INSIDE the substitution captures nothing, so it must not
    # read as the same-line status capture that makes the fix shape exempt.
    bareinner)
      {
        printf '#!/usr/bin/env bash\n'
        printf 'set -euo pipefail\n'
        printf 'INNER="$(cd "$1" && git rev-parse HEAD 2>/dev/null)"\n'
        printf 'if [ -z "$INNER" ]; then\n'
        printf '  exit 1\n'
        printf 'fi\n'
        printf 'echo "$INNER"\n'
      } >"$R/scripts/bare.sh"
      ;;
    scratch) printf '#!/usr/bin/env bash\nset -euo pipefail\nD="$(mktemp -d)"\necho "$D"\n' >"$R/scripts/scratch.sh" ;;
    scratchfile) printf '#!/usr/bin/env bash\nset -euo pipefail\nF="$(mktemp)"\necho "$F"\n' >"$R/scripts/scratchfile.sh" ;;
    shellmk) printf '#!/usr/bin/env bash\nset -euo pipefail\nmkdir -p %s/cache\n' /tmp >"$R/scripts/shellmk.sh" ;;
    mkjs) printf 'const fs = require("fs");\nfs.mkdirSync("%s/out");\n' /tmp >"$R/src/mk.js" ;;
    mkjsprefix) printf 'const fs = require("fs");\nfs.mkdtempSync("%s/app-");\n' /tmp >"$R/src/mk.js" ;;
    mkjsroot) printf 'const fs = require("fs");\nfs.mkdtempSync("%s");\n' /tmp >"$R/src/mk.js" ;;
    mkpy) printf 'import os, tempfile\nos.makedirs("%s/state")\n' /tmp >"$R/src/mk.py" ;;
    mkpykw) printf 'import os, tempfile\ntempfile.mkdtemp(dir="%s/keep")\n' /tmp >"$R/src/mk.py" ;;
    mkpyroot) printf 'import os, tempfile\ntempfile.mkdtemp(dir="%s")\n' /tmp >"$R/src/mk.py" ;;
    mkrs) printf 'fn main() {\n    std::fs::create_dir_all("%s/rust").unwrap();\n}\n' /tmp >"$R/src/mk.rs" ;;
    mkvar) printf 'import os\nos.mkdir("%s/persist")\n' /var/tmp >"$R/src/mkvar.py" ;;
    unwired)
      seed_runner
      printf '#!/usr/bin/env bash\nset -euo pipefail\necho known\n' >"$R/tests/known.test.sh"
      printf '#!/usr/bin/env bash\nset -euo pipefail\necho orphan\n' >"$R/tests/orphan.test.sh"
      ;;
    # A suite that arrived by `git mv` is a new file at its new path. Rename
    # detection must not hide it from the new-file lanes.
    renamed)
      seed_runner
      printf '#!/usr/bin/env bash\nset -euo pipefail\necho moved\n' >"$R/scripts/moved.sh"
      git -C "$R" add -A
      git -C "$R" commit -qm base
      git -C "$R" mv scripts/moved.sh tests/moved.test.sh
      ;;
    docs) printf '# Fixture\n\nSee `scripts/existing.sh`.\nAnd `docs/gone.md` for the rest.\n' >"$R/README.md" ;;
    srccite) printf '#!/usr/bin/env bash\nset -euo pipefail\n# Read docs/gone.md before editing this.\necho run\n' >"$R/scripts/cite.sh" ;;
    srccitesrc) printf 'fn main() {\n    // The mode table lives in docs/gone.md.\n}\n' >"$R/src/main.rs" ;;
    json) printf '{\n  "ok": true,\n}\n' >"$R/data/config.json" ;;
    toml) printf '[table]\nkey = "unterminated\n' >"$R/data/bad.toml" ;;
    migrationedit) printf 'CREATE TABLE t (id INTEGER); -- clearer\n' >"$R/store/migrations/V1__init.sql" ;;
    migrationflyway) printf 'CREATE TABLE s (id INTEGER); -- clearer\n' >"$R/src/main/resources/db/migration/V1__init.sql" ;;
    migrationdelete) git -C "$R" rm -q store/migrations/V1__init.sql ;;
    # A repo that turns rename detection off would otherwise see the move as
    # a delete and an add, and the finding would not say where the file went.
    migrationrename)
      git -C "$R" config diff.renames false
      git -C "$R" mv store/migrations/V2__more.sql store/migrations/V2__later.sql
      ;;
    verdict) printf '# Guide\n\nNothing here yet.\n\nSee `docs/gone.md`.\nAnd `docs/missing.md`.\n' >"$R/docs/guide.md" ;;
    *) printf 'pf_world: no such world: %s\n' "$1" >&2; return 1 ;;
  esac
  git -C "$R" add -A
}

# `read -d ''` rather than `$(cat <<'ROWS' ...)`: Bash 3.2 scans a here-document
# inside a command substitution for quotes, and a row carrying an odd number
# of double quotes runs its parse past the closing parenthesis. It returns 1
# at the end of the document, which errexit must not read; an empty table is
# pf_table's refusal.
#
# `fired` pins the whole set: the unwired world's `tests/known.test.sh` is not
# a finding because it is absent from the list, and the verdict row owns both
# heads its count names. The two bareassign worlds are one file each: the
# look-ahead claim is the distance between line 3 and line 7 of `bare.sh`,
# which one planted assignment shows on its own.
IFS= read -r -d '' rows <<'ROWS' || :
an unparseable new script fails, attributed to shell-syntax|syntax|-|-|1|scripts/broken.sh:4: [shell-syntax]|-
an out-of-range exit status fails as a shellcheck error|scerror|-|shellcheck|1|scripts/exitcode.sh:3: [shellcheck-errors]|SC2242
a masking local-and-assign fails on the line that introduced it|masked|-|shellcheck|1|scripts/masked.sh:5: [masked-returns]|SC2155
an mktemp assignment in an errexit-less file fails as fail-open|mktemp|-|-|1|scripts/loose.sh:3: [fail-open]|unchecked mktemp
a new script that never sets -e/-u/pipefail fails as fail-open|strict|-|-|1|scripts/fresh.sh:0: [fail-open]|new shell file without strict mode
a grep whose status or-true drops fails as fail-open, naming the command|swallow|-|-|1|scripts/existing.sh:4: [fail-open]|grep || true swallows exit 2
the shape is caught inside a command substitution too|swallowsubst|-|-|1|scripts/existing.sh:4: [fail-open]|git || true swallows exit 2
a condition piping echo into grep -q fails as early-close-pipe|earlyclose|-|-|1|scripts/existing.sh:3: [early-close-pipe]|a shell writer piped into a reader that stops before EOF
an assignment whose guard errexit kills first fails as fail-open|bareassign|-|-|1|scripts/bare.sh:3: [fail-open]|bare command-substitution assignment under errexit
an operator inside the substitution does not exempt the assignment|bareinner|-|-|1|scripts/bare.sh:3: [fail-open]|bare command-substitution assignment under errexit
a new script with mktemp and no EXIT trap fails as mktemp-trap|scratch|-|-|1|scripts/scratch.sh:3: [mktemp-trap]|mktemp without an EXIT trap
an mktemp with no arguments is the same finding|scratchfile|-|-|1|scripts/scratchfile.sh:3: [mktemp-trap]|mktemp without an EXIT trap
a shell mkdir -p at a literal /tmp path fails|shellmk|-|-|1|scripts/shellmk.sh:3: [hardcoded-temp-path]|-
a JS mkdirSync taking the literal fails|mkjs|-|-|1|src/mk.js:2: [hardcoded-temp-path]|-
a JS mkdtempSync prefix under /tmp is the same finding|mkjsprefix|-|-|1|src/mk.js:2: [hardcoded-temp-path]|-
the JS bare-root prefix form (mkdtempSync(/tmp) making a /tmpXXXXXX sibling) fails|mkjsroot|-|-|1|src/mk.js:2: [hardcoded-temp-path]|-
a Python makedirs taking the literal fails|mkpy|-|-|1|src/mk.py:2: [hardcoded-temp-path]|-
a Python mkdtemp aimed at /tmp by keyword fails|mkpykw|-|-|1|src/mk.py:2: [hardcoded-temp-path]|-
a bare-root mkdtemp keyword (dir=/tmp, no trailing slash) fails|mkpyroot|-|-|1|src/mk.py:2: [hardcoded-temp-path]|-
a Rust create_dir_all taking the literal fails|mkrs|-|-|1|src/mk.rs:2: [hardcoded-temp-path]|-
/var/tmp is the same literal|mkvar|-|-|1|src/mkvar.py:2: [hardcoded-temp-path]|-
a new suite named by no runner fails as unwired-suite, and the suite the workflow names is not a finding|unwired|-|-|1|tests/orphan.test.sh:0: [unwired-suite]|new suite is not invoked by any runner
a suite renamed into place is judged as the new file it is|renamed|-|-|1|tests/moved.test.sh:0: [unwired-suite]|-
the same holds in staged scope|renamed|--staged|-|1|tests/moved.test.sh:0: [unwired-suite]|-
a citation of a missing file under a real directory fails|docs|-|-|1|README.md:4: [docs-cited-paths]|cites a path that does not exist: docs/gone.md
a shell comment citing a missing doc fails at its line|srccite|-|-|1|scripts/cite.sh:3: [docs-cited-paths]|cites a path that does not exist: docs/gone.md
a non-shell source comment is judged the same way|srccitesrc|-|-|1|src/main.rs:2: [docs-cited-paths]|cites a path that does not exist: docs/gone.md
a JSON file jq cannot parse fails as data-syntax|json|-|jq|1|data/config.json:3: [data-syntax]|invalid JSON
a TOML file no parser accepts fails as data-syntax|toml|-|toml|1|data/bad.toml:2: [data-syntax]|invalid TOML
editing a migration the base already carried fails|migrationedit|-|-|1|store/migrations/V1__init.sql:0: [applied-migration-edited]|an applied migration was edited
the staged scope sees the same edit|migrationedit|--staged|-|1|store/migrations/V1__init.sql:0: [applied-migration-edited]|-
Flyway's own directory is in the default set|migrationflyway|-|-|1|src/main/resources/db/migration/V1__init.sql:0: [applied-migration-edited]|an applied migration was edited
deleting one is the same finding|migrationdelete|-|-|1|store/migrations/V1__init.sql:0: [applied-migration-edited]|an applied migration was deleted
renaming one names where it went|migrationrename|-|-|1|store/migrations/V2__more.sql:0: [applied-migration-edited]|an applied migration was renamed to store/migrations/V2__later.sql
the verdict line counts findings and changed files|verdict|-|-|1|docs/guide.md:5: [docs-cited-paths];docs/guide.md:6: [docs-cited-paths]|preflight: 2 finding(s) across 1 changed file(s)
ROWS
pf_table "every lane's must-fail control" "$rows"

pf_summary
