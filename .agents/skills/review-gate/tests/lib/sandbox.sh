# shellcheck shell=bash
# The sandbox and the assertion helpers, shared by the two suites that drive
# scripts/validate.sh and scripts/validate-workflow.sh. SOURCED, never run:
# the shard's runner globs tests/*.sh and does not descend here.
#
# Contract with the caller: it sets SKILL_DIR and TMP, and defines nothing
# this file also defines. Sourcing it builds the pristine sandbox once.
#
# DRIVER_REL is the one exception — the entry point run_validate drives. A
# caller may set it either side of the source line: the default below yields
# to a value already set, so the ordering cannot silently cost a suite its
# driver. Assigning it after sourcing changes the driver for every case that
# follows, which is how a suite switches back mid-file.

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
# Built once — the `git init` is paid here, not per case — and copied per
# case. A symlinked tree would not do: cases chmod and overwrite the vendored
# scripts inside their own sandbox, and through a symlink those writes land on
# the original. A reflink is isolated, since copy-on-write gives each case its
# own inode, but it is unavailable where this suite runs. `cp --reflink=always`
# fails with "Operation not supported" on tmpfs, a common TMPDIR, and the shard
# runs on ubuntu-latest, whose ext4 disk has no reflink either; `--reflink=auto`
# then falls back to a full copy without saying so. It would also buy little,
# since the copies are not the bulk of this suite's runtime. What a suite can
# change is the entry point each case runs, which is DRIVER_REL below; the two
# entry points differ by an order of magnitude, and the copy's share of a case
# varies with the driver and with whether TMPDIR is tmpfs, so measure first.
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

# The entry point every expectation below drives. It defaults to the full
# driver and YIELDS to a caller that set it first, so a suite may name its
# driver either side of the source line; a suite whose subject is the workflow
# half points it at that tool and proves the driver's fold of the peer's
# verdicts in its own cases rather than re-proving it under every one of them.
# Both tools print `FAIL` at the start of a verdict line and exit 1 on a
# finding, which is the only shape expect_clean and expect_fail read.
DRIVER_REL="${DRIVER_REL:-$VALIDATE_REL}"

OUT=""
RC=0
run_validate() { # DIR
  OUT=""
  RC=0
  OUT="$(cd "$1" && "./$DRIVER_REL" 2>&1)" || RC=$?
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

