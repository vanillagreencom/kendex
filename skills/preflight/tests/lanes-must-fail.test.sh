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
  mkdir -p "$R/docs" "$R/scripts" "$R/data"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  printf '# Fixture\n\nSee `scripts/existing.sh`.\n' >"$R/README.md"
  printf '# Guide\n\nNothing here yet.\n' >"$R/docs/guide.md"
  printf '#!/usr/bin/env bash\nset -euo pipefail\necho existing\n' >"$R/scripts/existing.sh"
  printf '#!/usr/bin/env bash\necho loose\n' >"$R/scripts/loose.sh"
  printf '{\n  "ok": true\n}\n' >"$R/data/config.json"
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

echo "=== lane docs-cited-paths: a backticked path that does not exist ==="
seed docs
printf '# Fixture\n\nSee `scripts/existing.sh`.\nAnd `docs/gone.md` for the rest.\n' >"$R/README.md"
git -C "$R" add -A
run_pf
fires "a citation of a missing file under a real directory fails" "README.md:4: [docs-cited-paths] cites a path that does not exist: docs/gone.md"

echo "=== lane todo-links: a TODO marker with no issue behind it ==="
seed todo
printf '# Guide\n\nNothing here yet.\n\nTODO: wire this up.\n' >"$R/docs/guide.md"
git -C "$R" add -A
run_pf
fires "the colon marker form fails" "docs/guide.md:5: [todo-links]"

# Both marker forms carry the same weight: `TODO(owner)` is the same
# untracked work item as `TODO:`, and FIXME is the same word as TODO.
printf '# Guide\n\nNothing here yet.\n\nTODO(alice) wire this up.\nFIXME(bob): and this.\n' >"$R/docs/guide.md"
git -C "$R" add -A
run_pf
fires "the owner-in-parentheses form fails too" "docs/guide.md:5: [todo-links]"
fires "FIXME is judged exactly as TODO is" "docs/guide.md:6: [todo-links]"

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

echo "=== the verdict line counts findings and changed files ==="
seed verdict
printf '# Guide\n\nNothing here yet.\n\nTODO: one.\nTODO: two.\n' >"$R/docs/guide.md"
git -C "$R" add -A
run_pf
fires "the summary names both counts" "preflight: 2 finding(s) across 1 changed file(s)"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
