#!/usr/bin/env bash
# Must-fail controls for every preflight lane. Each row plants one defect of
# a class the gate exists to catch and pins the whole fired set: exit 1, the
# planted finding attributed to the lane that owns it, and no other finding,
# so a fixture that also trips a neighbouring lane cannot pass on it. Lanes
# that need an optional tool skip loudly when it is absent rather than
# passing on a check that never ran.
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/lib/harness.sh"

TMP="$(mktemp -d)" || { echo 'lanes-must-fail: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP && ! -L $TMP ]] || { echo "lanes-must-fail: scratch=not-a-directory value=[$TMP]" >&2; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)" || { echo 'lanes-must-fail: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT

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
  git -C "$R" config gc.auto 0
  git -C "$R" config maintenance.auto false
  printf '# Fixture\n\nSee `scripts/existing.sh`.\n' >"$R/README.md"
  printf '# Guide\n\nNothing here yet.\n' >"$R/docs/guide.md"
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho existing\n' >"$R/scripts/existing.sh"
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho loose\n' >"$R/scripts/loose.sh"
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

# The shared row table gives every command and guard form its own verdict.
bare_guard_world() { # COMMAND FAMILY POSITION MODE
  local command="$1" family="$2" position="$3" mode="$4"
  local end='' name=ROOT assignment='' operand='' suffix='' guard=''

  assignment='ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"'
  case "$command" in
    single) command='['; end=' ]' ;;
    double) command='[['; end=' ]]' ;;
    test) command=test ;;
    *) printf 'bare_guard_world: no such command: %s\n' "$command" >&2; return 1 ;;
  esac
  case "$mode" in
    direct) ;;
    inner) name=INNER; assignment='INNER="$(cd "$1" && git rev-parse HEAD 2>/dev/null)"' ;;
    suffix) suffix=/.fleet ;;
    *) printf 'bare_guard_world: no such mode: %s\n' "$mode" >&2; return 1 ;;
  esac
  operand='"${'"$name"':-}"'"$suffix"
  case "$family:$position" in
    unary:-z|unary:-n) guard='if '"$command"' '"$position"' '"$operand$end"'; then' ;;
    equality:left) guard='if '"$command"' '"$operand"' = ""'"$end"'; then' ;;
    equality:right) guard='if '"$command"' "" = '"$operand$end"'; then' ;;
    *) printf 'bare_guard_world: no such form: %s %s\n' "$family" "$position" >&2; return 1 ;;
  esac
  {
    printf '#!/usr/bin/env bash\n'
    printf 'set -euo pipefail\n'
    printf '%s\n' "$assignment"
    # The -z row also pins the far edge of the four-line look-ahead.
    if [ "$family:$position:$mode" = unary:-z:direct ]; then
      printf 'log() {\n'
      printf '  printf "%%s\\n" "$1" >&2\n'
      printf '}\n'
    fi
    if [ "$family:$mode" = unary:suffix ]; then
      printf '# shellcheck disable=SC2157\n'
    fi
    printf '%s\n' "$guard"
    printf '  exit 1\n'
    printf 'fi\n'
    printf 'echo "$%s"\n' "$name"
  } >"$R/scripts/bare.sh"
}

# The jq continuation is emitted by oversee-watch::check_lanes.
multisubst_world() { # SHAPE HANDLER
  local assignment='' prefix='' suffix='' guard='[ -z "$ROOT" ] && exit 1'
  local preamble='set -euo pipefail' path="$R/scripts/multisubst.sh"
  local phase phases='final'
  case "$2" in
    or) suffix=' || die' ;;
    and) suffix=' && echo "$ROOT"' ;;
    if) prefix='if '; suffix='; then echo "$ROOT"; fi' ;;
    while) prefix='while '; suffix='; do break; done' ;;
    until) prefix='until '; suffix='; do break; done' ;;
    test) prefix='[[ -n '; suffix=' ]]'; guard='echo done' ;;
    bare) ;;
    later) suffix='; echo later || die' ;;
    *) printf 'multisubst_world: no such handler: %s\n' "$2" >&2; return 1 ;;
  esac
  case "$1" in
    continued)
      # The two-line jq assignment and handler reported by the real producer.
      assignment='ROOT="$(jq -r '\''.lanes[]? | select(.item == $item) | .harness'\'' --arg item "$LANE_ITEM" <<<"${FLEET_STATE:-null}")" \' ;;
    quoted|condition)
      if [ "$1" = condition ]; then prefix="$prefix\\"$'\n'; fi
      assignment='ROOT="$(git
  rev-parse --show-toplevel 2>/dev/null)"' ;;
    inner)
      assignment='ROOT="$(cd "$1" || exit 1
  git rev-parse --show-toplevel 2>/dev/null)"' ;;
    doublequote)
      assignment='ROOT="$(git rev-parse --show-toplevel 2>/dev/null)\
"' ;;
    hash)
      assignment='ROOT="$(git rev-parse --show-toplevel 2>/dev/null '\''#'\'')" \' ;;
    commented)
      assignment='ROOT="$(git # lookup failure \
  rev-parse --show-toplevel 2>/dev/null)"' ;;
    literal)
      assignment='ROOT="$(printf '\''%s'\'' '\''literal \
'\'')"' ;;
    arrayprefix)
      # oversee-watch::repeat_watch emits the continued array prefix.
      prefix=$'args=(--interval "$INTERVAL" --max-loops "$MAX_LOOPS" \\\n  --handoff "$HANDOFF" --state "$STATE_FILE")\n'
      assignment='ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"' ;;
    mktemp)
      preamble='set -uo pipefail'; path="$R/scripts/loose.sh"
      assignment='ROOT="$(mktemp -d
)"' ;;
    comment|closeif|closewhile|closecase|closebrace)
      assignment='ROOT="$(git rev-parse --show-toplevel 2>/dev/null)"'
      case "$1" in
        comment) ;;
        closeif) prefix=$'if true; then\n'; suffix='; fi' ;;
        closewhile) prefix=$'while true; do\n'; suffix='; done' ;;
        closecase) prefix=$'case x in x)\n'; suffix=';; esac' ;;
        closebrace) prefix=$'{\n'; suffix='; }' ;;
      esac
      suffix="$suffix"' # lookup failure \' ;;
    *) printf 'multisubst_world: no such shape: %s\n' "$1" >&2; return 1 ;;
  esac

  if [ "$2" = test ]; then assignment="${assignment#ROOT=}"; fi
  if [ "$1:$2" = quoted:bare ]; then
    # Only the closing line changes; its guard is outside the opening window.
    phases='baseline final'
    guard=$'log() {\n  printf "%s\\n" "$1" >&2\n}\n'"$guard"
  fi
  for phase in $phases; do
    if [ "$1:$2" = quoted:bare ]; then
      case "$phase" in baseline) suffix=' || die' ;; final) suffix='' ;; esac
    fi
    {
      printf '#!/usr/bin/env bash\n%s\ndie() { exit 1; }\n' "$preamble"
      printf '%s%s' "$prefix" "$assignment"
      case "$1" in continued|hash) printf '\n' ;; esac
      printf '%s\n%s\n' "$suffix" "$guard"
    } >"$path"
    if [ "$phase" = baseline ]; then
      git -C "$R" add scripts/multisubst.sh || return 1
      git -C "$R" commit -qm 'checked multiline assignment' || return 1
    fi
  done
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
    rustenv)
      mkdir -p "$R/tests"
      printf 'fn fixture() {\n    unsafe { %s::set_var("KEY", "value"); }\n}\n' "${2:-std::env}" >"$R/tests/env.rs"
      ;;
    rustremove)
      printf 'use std::env;\n#[cfg(test)]\nmod tests {\n    fn fixture() { unsafe { %s::remove_var("KEY"); } }\n}\n' "${2:-env}" >"$R/src/lib.rs"
      ;;
    rusttestfn)
      printf '#[test]\nfn case() { unsafe { std::env::remove_var("KEY"); } }\n' >"$R/src/lib.rs"
      ;;
    rustsignature)
      local error_type
      case "$2" in
        array) error_type='[(); 1]' ;;
        block) error_type='[(); { 1 }]' ;;
        generic) error_type='Error<{ 1 }>' ;;
        *) return 1 ;;
      esac
      # These error types implement Debug, so Rust accepts the test signature.
      printf '#[derive(Debug)]\nstruct Error<const N: usize>;\n#[test]\nfn case() -> Result<(), %s> {\n    unsafe { std::env::set_var("KEY", "value"); }\n    Ok(())\n}\nfn production() { unsafe { std::env::set_var("KEY", "value"); } }\n' "$error_type" >"$R/src/lib.rs"
      ;;
    # Written from the shell, never with cat reading a file: a cat-fed
    # fixture pushes several hundred KB before it blocks, so it passes
    # either way.
    earlyclose) printf '#!/usr/bin/env bash\nset -euo pipefail\nif echo "$1" | grep -q x; then echo hit; fi\n' >"$R/scripts/existing.sh" ;;
    # The same lane inside the test tree, on the mid-pipeline shape: the
    # reader is two stages down and another stage runs after it, and the
    # suite's own pipefail is what turns the writer's SIGPIPE into the 141
    # that ends the run mid-section. The pipeline is halved across two
    # variables so this suite's own committed line does not carry the shape.
    # The suite is the one the seeded workflow names, so it is wired.
    earlyclosesuite)
      seed_runner
      ec_writer='n=$(printf "%s\n" "$1" '
      ec_reader='| grep -n x | head -1 | cut -d: -f1)'
      printf '#!/usr/bin/env bash\nset -euo pipefail\n%s%s\necho "$n"\n' "$ec_writer" "$ec_reader" >"$R/tests/known.test.sh"
      ;;
    bareguard) bare_guard_world "$2" "$3" "$4" "$5" ;;
    multisubst) multisubst_world "$2" "$3" ;;
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
# heads its count names. The -z row pins the look-ahead edge on its own.
IFS= read -r -d '' rows <<'ROWS' || :
Rust test files cannot set the process environment|rustenv|-|-|1|tests/env.rs:2: [rust-test-env-mutation]|-
Rust inline test modules cannot remove process environment|rustremove|-|-|1|src/lib.rs:4: [rust-test-env-mutation]|-
Rust absolute set calls retain staged test scope|rustenv ::std::env|--staged|-|1|tests/env.rs:2: [rust-test-env-mutation]|-
Rust absolute remove calls retain all-file test scope|rustremove ::std::env|--all|-|1|src/lib.rs:4: [rust-test-env-mutation]|-
Rust test functions cannot mutate process environment|rusttestfn|--staged|-|1|src/lib.rs:2: [rust-test-env-mutation]|-
Rust array return types retain staged test scope|rustsignature array|--staged|-|1|src/lib.rs:5: [rust-test-env-mutation]|-
Rust array return types retain all-file test scope|rustsignature array|--all|-|1|src/lib.rs:5: [rust-test-env-mutation]|-
Rust array const blocks retain staged test scope|rustsignature block|--staged|-|1|src/lib.rs:5: [rust-test-env-mutation]|-
Rust array const blocks retain all-file test scope|rustsignature block|--all|-|1|src/lib.rs:5: [rust-test-env-mutation]|-
Rust generic const blocks retain staged test scope|rustsignature generic|--staged|-|1|src/lib.rs:5: [rust-test-env-mutation]|-
Rust generic const blocks retain all-file test scope|rustsignature generic|--all|-|1|src/lib.rs:5: [rust-test-env-mutation]|-
an unparseable new script fails, attributed to shell-syntax|syntax|-|-|1|scripts/broken.sh:4: [shell-syntax]|-
an out-of-range exit status fails as a shellcheck error|scerror|-|shellcheck|1|scripts/exitcode.sh:3: [shellcheck-errors]|-
a masking local-and-assign fails on the line that introduced it|masked|-|shellcheck|1|scripts/masked.sh:5: [masked-returns]|-
an mktemp assignment in an errexit-less file fails as fail-open|mktemp|-|-|1|scripts/loose.sh:3: [fail-open]|-
a new script that never sets -e/-u/pipefail fails as fail-open|strict|-|-|1|scripts/fresh.sh:0: [fail-open]|-
a grep whose status or-true drops fails as fail-open, naming the command|swallow|-|-|1|scripts/existing.sh:4: [fail-open]|-
the shape is caught inside a command substitution too|swallowsubst|-|-|1|scripts/existing.sh:4: [fail-open]|-
a condition piping echo into grep -q fails as early-close-pipe|earlyclose|-|-|1|scripts/existing.sh:3: [early-close-pipe]|-
a suite that sets pipefail is judged too, mid-pipeline reader included|earlyclosesuite|-|-|1|tests/known.test.sh:3: [early-close-pipe]|-
a bracket -z guard fails as fail-open at the look-ahead edge|bareguard single unary -z direct|-|-|1|scripts/bare.sh:3: [fail-open]|-
a bracket -n guard fails as fail-open|bareguard single unary -n direct|-|-|1|scripts/bare.sh:3: [fail-open]|-
a bracket variable-left equality guard fails as fail-open|bareguard single equality left direct|-|-|1|scripts/bare.sh:3: [fail-open]|-
a bracket variable-right equality guard fails as fail-open|bareguard single equality right direct|-|-|1|scripts/bare.sh:3: [fail-open]|-
a double-bracket unary guard fails as fail-open|bareguard double unary -z direct|-|-|1|scripts/bare.sh:3: [fail-open]|-
a double-bracket right equality guard fails as fail-open|bareguard double equality right direct|-|-|1|scripts/bare.sh:3: [fail-open]|-
an inline test unary guard fails as fail-open|bareguard test unary -z direct|-|-|1|scripts/bare.sh:3: [fail-open]|-
an inline test right equality guard fails as fail-open|bareguard test equality right direct|-|-|1|scripts/bare.sh:3: [fail-open]|-
an operator inside the substitution does not exempt the equality guard|bareguard single equality left inner|-|-|1|scripts/bare.sh:3: [fail-open]|-
a comment backslash preserves the immediate guard|multisubst comment bare|-|-|1|scripts/multisubst.sh:4: [fail-open]|-
an if close comment preserves the guard in default scope|multisubst closeif bare|-|-|1|scripts/multisubst.sh:5: [fail-open]|-
an if close comment preserves the guard in base scope|multisubst closeif bare|--base HEAD|-|1|scripts/multisubst.sh:5: [fail-open]|-
an if close comment preserves the guard in staged scope|multisubst closeif bare|--staged|-|1|scripts/multisubst.sh:5: [fail-open]|-
an if close comment preserves the guard in all scope|multisubst closeif bare|--all|-|1|scripts/multisubst.sh:5: [fail-open]|-
a while close comment preserves the guard in default scope|multisubst closewhile bare|-|-|1|scripts/multisubst.sh:5: [fail-open]|-
a while close comment preserves the guard in base scope|multisubst closewhile bare|--base HEAD|-|1|scripts/multisubst.sh:5: [fail-open]|-
a while close comment preserves the guard in staged scope|multisubst closewhile bare|--staged|-|1|scripts/multisubst.sh:5: [fail-open]|-
a while close comment preserves the guard in all scope|multisubst closewhile bare|--all|-|1|scripts/multisubst.sh:5: [fail-open]|-

a case close comment preserves the guard in default scope|multisubst closecase bare|-|-|1|scripts/multisubst.sh:5: [fail-open]|-
a case close comment preserves the guard in base scope|multisubst closecase bare|--base HEAD|-|1|scripts/multisubst.sh:5: [fail-open]|-
a case close comment preserves the guard in staged scope|multisubst closecase bare|--staged|-|1|scripts/multisubst.sh:5: [fail-open]|-
a case close comment preserves the guard in all scope|multisubst closecase bare|--all|-|1|scripts/multisubst.sh:5: [fail-open]|-
a brace close comment preserves the guard in default scope|multisubst closebrace bare|-|-|1|scripts/multisubst.sh:5: [fail-open]|-
a brace close comment preserves the guard in base scope|multisubst closebrace bare|--base HEAD|-|1|scripts/multisubst.sh:5: [fail-open]|-
a brace close comment preserves the guard in staged scope|multisubst closebrace bare|--staged|-|1|scripts/multisubst.sh:5: [fail-open]|-
a brace close comment preserves the guard in all scope|multisubst closebrace bare|--all|-|1|scripts/multisubst.sh:5: [fail-open]|-
the two-line jq assignment ending with or-die is checked|multisubst continued or|-|-|0|-|preflight: clean=1
a continued assignment ending with an and-handler is checked|multisubst continued and|-|-|0|-|preflight: clean=1
a quoted multiline substitution ending with or-die is checked|multisubst quoted or|-|-|0|-|preflight: clean=1
an escaped newline inside double quotes preserves the handler|multisubst doublequote or|-|-|0|-|preflight: clean=1
an escaped newline inside double quotes preserves the bare assignment finding|multisubst doublequote bare|-|-|1|scripts/multisubst.sh:4: [fail-open]|-
a quoted hash does not turn a continuation into a comment|multisubst hash or|-|-|0|-|preflight: clean=1
a comment slash inside a substitution preserves its closing line|multisubst commented bare|-|-|1|scripts/multisubst.sh:4: [fail-open]|-
a comment slash inside a substitution preserves its handler|multisubst commented or|-|-|0|-|preflight: clean=1
a slash in a single-quoted literal preserves its newline|multisubst literal or|-|-|0|-|preflight: clean=1
an array prefix preserves the following bare assignment finding|multisubst arrayprefix bare|-|-|1|scripts/multisubst.sh:6: [fail-open]|-
an array prefix preserves the following checked assignment|multisubst arrayprefix or|-|-|0|-|preflight: clean=1
an if continued onto the assignment stays checked|multisubst condition if|-|-|0|-|preflight: clean=1
a while continued onto the assignment stays checked|multisubst condition while|-|-|0|-|preflight: clean=1
an until continued onto the assignment stays checked|multisubst condition until|-|-|0|-|preflight: clean=1
a substitution inside a double-bracket test remains checked|multisubst quoted test|-|-|0|-|preflight: clean=1
a checked multiline mktemp without errexit stays checked|multisubst mktemp or|-|-|0|-|preflight: clean=1
an unchecked multiline mktemp without errexit still fails|multisubst mktemp bare|-|-|1|scripts/loose.sh:4: [fail-open]|-

removing only the closing-line handler fails at the statement-end guard boundary in base scope|multisubst quoted bare|--base HEAD|-|1|scripts/multisubst.sh:4: [fail-open]|-
removing only the closing-line handler fails at the statement-end guard boundary in staged scope|multisubst quoted bare|--staged|-|1|scripts/multisubst.sh:4: [fail-open]|-
an operator inside a multiline substitution does not check its assignment|multisubst inner bare|-|-|1|scripts/multisubst.sh:4: [fail-open]|-
a later command handler does not check the multiline assignment|multisubst quoted later|-|-|1|scripts/multisubst.sh:4: [fail-open]|-
a quoted unary operand with a path suffix is not a direct guard|bareguard single unary -z suffix|-|-|0|-|preflight: clean=1
a quoted right-hand equality operand with a path suffix is not a direct guard|bareguard single equality right suffix|-|-|0|-|preflight: clean=1
a new script with mktemp and no EXIT trap fails as mktemp-trap|scratch|-|-|1|scripts/scratch.sh:3: [mktemp-trap]|-
an mktemp with no arguments is the same finding|scratchfile|-|-|1|scripts/scratchfile.sh:3: [mktemp-trap]|-
a shell mkdir -p at a literal /tmp path fails|shellmk|-|-|1|scripts/shellmk.sh:3: [hardcoded-temp-path]|-
a JS mkdirSync taking the literal fails|mkjs|-|-|1|src/mk.js:2: [hardcoded-temp-path]|-
a JS mkdtempSync prefix under /tmp is the same finding|mkjsprefix|-|-|1|src/mk.js:2: [hardcoded-temp-path]|-
the JS bare-root prefix form (mkdtempSync(/tmp) making a /tmpXXXXXX sibling) fails|mkjsroot|-|-|1|src/mk.js:2: [hardcoded-temp-path]|-
a Python makedirs taking the literal fails|mkpy|-|-|1|src/mk.py:2: [hardcoded-temp-path]|-
a Python mkdtemp aimed at /tmp by keyword fails|mkpykw|-|-|1|src/mk.py:2: [hardcoded-temp-path]|-
a bare-root mkdtemp keyword (dir=/tmp, no trailing slash) fails|mkpyroot|-|-|1|src/mk.py:2: [hardcoded-temp-path]|-
a Rust create_dir_all taking the literal fails|mkrs|-|-|1|src/mk.rs:2: [hardcoded-temp-path]|-
/var/tmp is the same literal|mkvar|-|-|1|src/mkvar.py:2: [hardcoded-temp-path]|-
a new suite named by no runner fails as unwired-suite, and the suite the workflow names is not a finding|unwired|-|-|1|tests/orphan.test.sh:0: [unwired-suite]|-
a suite renamed into place is judged as the new file it is|renamed|-|-|1|tests/moved.test.sh:0: [unwired-suite]|-
the same holds in staged scope|renamed|--staged|-|1|tests/moved.test.sh:0: [unwired-suite]|-
a citation of a missing file under a real directory fails|docs|-|-|1|README.md:4: [docs-cited-paths]|-
a shell comment citing a missing doc fails at its line|srccite|-|-|1|scripts/cite.sh:3: [docs-cited-paths]|-
a non-shell source comment is judged the same way|srccitesrc|-|-|1|src/main.rs:2: [docs-cited-paths]|-
a JSON file jq cannot parse fails as data-syntax|json|-|jq|1|data/config.json:3: [data-syntax]|-
a TOML file no parser accepts fails as data-syntax|toml|-|toml|1|data/bad.toml:2: [data-syntax]|-
editing a migration the base already carried fails|migrationedit|-|-|1|store/migrations/V1__init.sql:0: [applied-migration-edited]|-
the staged scope sees the same edit|migrationedit|--staged|-|1|store/migrations/V1__init.sql:0: [applied-migration-edited]|-
Flyway's own directory is in the default set|migrationflyway|-|-|1|src/main/resources/db/migration/V1__init.sql:0: [applied-migration-edited]|-
deleting one is the same finding|migrationdelete|-|-|1|store/migrations/V1__init.sql:0: [applied-migration-edited]|-
renaming one names where it went|migrationrename|-|-|1|store/migrations/V2__more.sql:0: [applied-migration-edited]|-
the verdict counts findings and changed files|verdict|-|-|1|docs/guide.md:5: [docs-cited-paths];docs/guide.md:6: [docs-cited-paths]|preflight: findings=2
ROWS
pf_table "every lane's must-fail control" "$rows"

pf_summary
