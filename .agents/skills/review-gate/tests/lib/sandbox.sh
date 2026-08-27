# shellcheck shell=bash
# The sandbox and the assertion helpers, shared by the two suites that drive
# scripts/validate.sh and scripts/validate-workflow.sh. SOURCED, never run:
# the shard's runner globs tests/*.sh and does not descend here.
#
# Contract with the caller: it sets SKILL_DIR and TMP, and defines nothing
# this file also defines. Sourcing it builds the pristine sandbox once.

# The verdict counters and their two writers: every helper below reports
# through these, and each suite prints the totals itself.
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
  return 0
}

# The two entry points, as a sandbox sees them — a vendored tree, which is
# the only shape either script has to work in.
VALIDATE_REL=".agents/skills/review-gate/scripts/validate.sh"
WORKFLOW_REL=".agents/skills/review-gate/scripts/validate-workflow.sh"
# Built once and copied per case: a fresh `cp -R` of the skill plus a `git
# init` for every one of the cases below is the bulk of this suite's runtime.
PRISTINE="$TMP/pristine"
mkdir -p "$PRISTINE/.agents/skills" "$PRISTINE/.github/workflows" "$PRISTINE/docs"
cp -R "$SKILL_DIR" "$PRISTINE/.agents/skills/review-gate"
cp "$SKILL_DIR/templates/review-gate-writer.yml" "$PRISTINE/.github/workflows/review-gate-writer.yml"
printf '[env]\nREVIEW_GATE_CONTEXT = "Review gate"\n' >"$PRISTINE/kendex.settings.toml"
printf 'sandbox\n' >"$PRISTINE/docs/guide.md"
printf 'sandbox\n' >"$PRISTINE/AGENTS.md"
(
  cd "$PRISTINE"
  git init -q .
  git config user.name "review-gate tests"
  git config user.email "tests@example.invalid"
  git add -A
  git commit -q -m "sandbox"
)

SANDBOX_N=0
DIR=""
sandbox() { # sets DIR to a fresh copy of the pristine repo
  # A GLOBAL, not a printed path: `dir="$(sandbox)"` would run the counter
  # in a subshell, every case would land on the same directory, and the
  # copies would pile up inside one another.
  SANDBOX_N=$((SANDBOX_N + 1))
  DIR="$TMP/case.$SANDBOX_N"
  cp -R "$PRISTINE" "$DIR"
}

commit() { # DIR — re-commit whatever the case mutated
  (cd "$1" && git add -A && git commit -q -m "case" --allow-empty)
}

OUT=""
RC=0
run_validate() { # DIR
  OUT=""
  RC=0
  OUT="$(cd "$1" && "./$VALIDATE_REL" 2>&1)" || RC=$?
}

# `settings` NAME VALUE — append one assignment to the sandbox settings file
settings() { # DIR KEY VALUE
  printf '%s = "%s"\n' "$2" "$3" >>"$1/kendex.settings.toml"
}

repo_fails() { # NAME SUBSTRING SHELL — SHELL runs at the sandbox root, then
                # the case commits and expects a finding
  sandbox
  dir="$DIR"
  ( cd "$dir" && eval "$3" )
  commit "$dir"
  expect_fail "$1" "$dir" "$2"
}

setting_fails() { # NAME KEY VALUE SUBSTRING — one setting, one expectation
  sandbox
  dir="$DIR"
  settings "$dir" "$2" "$3"
  expect_fail "$1" "$dir" "$4"
}

setting_clean() { # NAME KEY VALUE — one setting, expected to pass
  sandbox
  dir="$DIR"
  settings "$dir" "$2" "$3"
  expect_clean "$1" "$dir"
}

expect_clean() { # NAME DIR
  run_validate "$2"
  if [ "$RC" -eq 0 ] && ! printf '%s' "$OUT" | grep -q '^FAIL'; then
    ok "$1"
  else
    bad "$1 (rc=$RC)" "$OUT"
  fi
}

expect_fail() { # NAME DIR SUBSTRING
  run_validate "$2"
  if [ "$RC" -ne 1 ]; then
    bad "$1 — expected exit 1, got $RC" "$OUT"
    return 0
  fi
  if printf '%s' "$OUT" | grep -F -- "$3" | grep -q '^FAIL'; then
    ok "$1"
  else
    bad "$1 — no FAIL line carrying: $3" "$OUT"
  fi
}

