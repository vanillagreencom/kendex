#!/usr/bin/env bash
# Review-gate validate — the one check a consuming repo runs against its own
# review-gate installation. Shipped by the kendex review-gate skill and
# vendored into consumers at .agents/skills/review-gate/scripts/.
#
# It is a TOOL, not a test suite. It never re-runs the engine's behavioural
# proofs — those run upstream, in the kendex repo, on every change. What it
# answers is repo-own: is the engine installed and runnable here, do this
# repo's committed REVIEW_GATE_* values resolve to legal settings, do the
# carry-forward exclusions still match something in this tree, and does the
# adopted writer workflow still meet the template's contract.
#
# The authoritative contract is print_usage below: run with --help.
set -euo pipefail

print_usage() {
  cat <<'USAGE'
Usage: validate.sh [--help]   (no positional arguments)

Validates THIS repository's review-gate installation. Run it from anywhere
inside the repository; it resolves the repository root itself and reads the
committed settings from there.

Output: one verdict line per check.
  ok    the check held
  FAIL  this repo's configuration or wiring is wrong, and the line says how
  note  informational — a source that is off, or a check nothing exercised

Exit codes:
  0  every check held
  1  at least one FAIL line
  2  the check could not run at all (bad arguments, not a git repository, a
     missing file the checks are derived from)

Four groups run, in this order:

  runtime     every engine script this repo needs is present, executable and
              parses under `bash -n`.
  settings    the committed file is TRACKED (CI checks out nothing else), and
              every REVIEW_GATE_* assignment is one the engine reads, spelt
              the way it reads it (bare key, no quotes), and legal. Unknown
              keys, per-invocation seams and repository variables are each
              named as what they are; the value rules come from
              `review-predicate.sh --check-config`, never a copy of them.
  carry       every REVIEW_GATE_CARRY_FORWARD_EXCLUDE glob is
              repository-relative, matches a tracked path, and is not
              universal; every prophylactic declaration names an active
              exclusion that still matches nothing. A value the loader
              refuses is a finding, never an empty list.
  workflow    the adopted .github/workflows/ copy is still the shipped
              template, line for line — delegated to validate-workflow.sh,
              whose --help states the model and the two allowed deltas.

The environment is scrubbed of every REVIEW_GATE_* key before settings are
read: what is validated is what the repository COMMITS, not what this shell
happens to export. REVIEW_GATE_SETTINGS_FILE is honoured (it names the file
to validate) and is resolved to an absolute path first.
USAGE
}

if [ "$#" -eq 1 ] && { [ "$1" = "--help" ] || [ "$1" = "-h" ]; }; then
  print_usage
  exit 0
fi
if [ "$#" -gt 0 ]; then
  echo "validate.sh: unknown argument list ($# argument(s), first: '${1}') — no positional arguments (run --help)" >&2
  exit 2
fi

die() { # MESSAGE — the check could not run at all
  echo "::error::review-gate validate: $1" >&2
  exit 2
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)" || die "could not resolve this script's directory"
SKILL_DIR="$(cd "$SCRIPT_DIR/.." && pwd)" || die "could not resolve the skill directory"

REPO_ROOT="$(git rev-parse --show-toplevel 2>/dev/null)" ||
  die "not inside a git repository — the tracked-path and workflow checks have nothing to read"
[ -n "$REPO_ROOT" ] || die "git named no repository root"

# Resolved BEFORE the cd: a relative override means relative to where the
# caller stood, and silently re-anchoring it to the repository root would
# validate a different file than the caller named.
if [ -n "${REVIEW_GATE_SETTINGS_FILE:-}" ] && [ "$REVIEW_GATE_SETTINGS_FILE" != "/dev/null" ]; then
  case "$REVIEW_GATE_SETTINGS_FILE" in
    /*) ;;
    *) REVIEW_GATE_SETTINGS_FILE="$PWD/$REVIEW_GATE_SETTINGS_FILE" ;;
  esac
  export REVIEW_GATE_SETTINGS_FILE
fi

cd "$REPO_ROOT" || die "could not enter the repository root $REPO_ROOT"

PASS=0
FAILED=0
ok() { PASS=$((PASS + 1)); printf 'ok    %s\n' "$1"; }
bad() { FAILED=$((FAILED + 1)); printf 'FAIL  %s\n' "$1"; }
note() { printf 'note  %s\n' "$1"; }
group() { printf '\n== %s ==\n' "$1"; }

# --------------------------------------------------------------- runtime ---

group "runtime"

# lib/settings.sh is sourced, never executed, so it is checked for syntax
# but not for an executable bit.
for rel in scripts/review-predicate.sh scripts/review-writer.sh \
  scripts/pr-watch.sh scripts/validate.sh scripts/validate-workflow.sh \
  scripts/lib/settings.sh; do
  path="$SKILL_DIR/$rel"
  if [ ! -f "$path" ]; then
    bad "$rel is missing from the installed skill ($SKILL_DIR) — re-run \`kendex refresh\` and commit the result"
    continue
  fi
  if ! bash -n "$path" 2>/dev/null; then
    bad "$rel does not parse under \`bash -n\` — the install is truncated or edited; re-run \`kendex refresh\`"
    continue
  fi
  case "$rel" in
    */lib/*) ok "$rel is present and parses" ;;
    *)
      if [ -x "$path" ]; then
        ok "$rel is present, executable and parses"
      else
        bad "$rel is not executable — CI runs it directly, so a lost mode bit reds the writer on every leg (\`git update-index --chmod=+x $rel\`)"
      fi
      ;;
  esac
done

# -------------------------------------------------------------- settings ---

group "settings"

SETTINGS_FILE="${REVIEW_GATE_SETTINGS_FILE:-kendex.settings.toml}"

# The key ledger is the skill's own shipped example, so this tool cannot
# drift from what the engine documents. REVIEW_GATE_OUTAGE_CONTEXT is the one
# deliberate addition: the legacy override name, still resolved by the
# predicate and deliberately absent from the example, which models v2.
EXAMPLE="$SKILL_DIR/kendex.settings.toml.example"
[ -f "$EXAMPLE" ] ||
  die "$EXAMPLE is missing — it is the ledger of known keys, and without it an unknown-key scan would pass everything"
KNOWN_KEYS="$(sed -n 's/^[[:space:]]*\([A-Z][A-Z0-9_]*\)[[:space:]]*=.*/\1/p' "$EXAMPLE")
REVIEW_GATE_OUTAGE_CONTEXT"
grep -q '^REVIEW_GATE_CONTEXT$' <<<"$KNOWN_KEYS" ||
  die "$EXAMPLE names no REVIEW_GATE_CONTEXT assignment — the ledger is unreadable and the unknown-key scan would pass everything"

# Per-invocation seams, never repo settings: assigning one in a committed
# file advertises a caller handle as configuration, and a settings file
# assigning its own path is read by nothing at all.
ENV_ONLY_SEAMS="REVIEW_GATE_SETTINGS_FILE
REVIEW_GATE_STATUS_SNAPSHOT_FILE"

# A GitHub repository variable, read by a workflow expression before any
# checkout exists. It is refused here on its own line rather than as an
# unknown key: the name is real and the value is wanted, just not in a file
# the workflow cannot see, and "you misspelled it" would send its reader
# looking for a typo that is not there.
REPO_VARIABLES="REVIEW_GATE_CHECK_RUN_NAME"

if [ "$SETTINGS_FILE" = "/dev/null" ]; then
  note "REVIEW_GATE_SETTINGS_FILE=/dev/null — settings are forced to built-in defaults; no committed file is being validated"
elif [ ! -f "$SETTINGS_FILE" ]; then
  note "$SETTINGS_FILE is absent — every key resolves to its built-in default, which is a valid install carrying no per-repo values"
else
  # PRESENT is not COMMITTED. CI checks out tracked files only, so an
  # untracked settings file validates here with the intended trust values
  # while the gate runs on the built-in defaults — the widest possible split
  # between what was checked and what runs. An explicit
  # REVIEW_GATE_SETTINGS_FILE is a caller handle pointing anywhere, so it is
  # exempt and says so.
  if [ -n "${REVIEW_GATE_SETTINGS_FILE:-}" ]; then
    note "$SETTINGS_FILE is present (named by REVIEW_GATE_SETTINGS_FILE, so it is not required to be tracked)"
  elif git ls-files --error-unmatch -- "$SETTINGS_FILE" >/dev/null 2>&1; then
    ok "$SETTINGS_FILE is present and tracked"
  else
    bad "$SETTINGS_FILE is present but UNTRACKED — CI checks out tracked files only, so every value below is validated here and absent there; the gate would run on the built-in defaults. \`git add $SETTINGS_FILE\`"
  fi
  # Two scans, because the loader makes the distinction: its presence probe
  # is `^[[:space:]]*NAME[[:space:]]*=` (scripts/lib/settings.sh), which
  # matches the BARE key and nothing else. TOML says a quoted key is the same
  # key; this engine's parser says it is no key at all. Reading both shapes as
  # one would report a quoted assignment as a healthy setting while the gate
  # ran on the built-in default.
  # The TOML BARE-KEY charset, not the ledger's shape: scanning `[A-Z0-9_]*`
  # reads `REVIEW_GATE_MODEe` as `REVIEW_GATE_MODE`, finds it known, and
  # passes the one spelling the engine silently ignores.
  assigned="$(sed -n 's/^[[:space:]]*\(REVIEW_GATE_[A-Za-z0-9_-]*\)[[:space:]]*=.*/\1/p' "$SETTINGS_FILE" | sort -u)"
  quoted="$(sed -n "s/^[[:space:]]*[\"']\(REVIEW_GATE_[A-Za-z0-9_-]*\)[\"'][[:space:]]*=.*/\1/p" "$SETTINGS_FILE" | sort -u)"
  # A DOTTED key is the third spelling TOML allows and the loader does not
  # read: its probe wants the bare name followed by its `=`, so
  # `REVIEW_GATE_MODE.typo = "off"` is invisible to the engine and, scanned
  # for the bare shape alone, invisible here too.
  dotted="$(sed -n 's/^[[:space:]]*\(REVIEW_GATE_[A-Za-z0-9_-]*\)\.[A-Za-z0-9_.-]*[[:space:]]*=.*/\1/p' "$SETTINGS_FILE" | sort -u)"
  unknown=""
  seams=""
  repo_vars=""
  while IFS= read -r key; do
    [ -z "$key" ] && continue
    if grep -qxF -- "$key" <<<"$ENV_ONLY_SEAMS"; then
      seams="${seams:+$seams }$key"
      continue
    fi
    if grep -qxF -- "$key" <<<"$REPO_VARIABLES"; then
      repo_vars="${repo_vars:+$repo_vars }$key"
      continue
    fi
    grep -qxF -- "$key" <<<"$KNOWN_KEYS" || unknown="${unknown:+$unknown }$key"
  done <<EOF_ASSIGNED
$assigned
EOF_ASSIGNED
  if [ -n "$unknown" ]; then
    bad "$SETTINGS_FILE assigns REVIEW_GATE_* key(s) the engine never reads: $unknown — a misspelled key resolves as unset, so the value written there is ignored and the gate runs on the default (key table: references/settings.md)"
  else
    ok "every REVIEW_GATE_* key assigned in $SETTINGS_FILE is one the engine reads"
  fi
  if [ -n "$seams" ]; then
    bad "$SETTINGS_FILE assigns per-invocation env seam(s): $seams — these are caller handles, never repo settings; delete the assignment(s)"
  else
    ok "no per-invocation env seam is assigned as a repo setting"
  fi
  if [ -n "$repo_vars" ]; then
    bad "$SETTINGS_FILE assigns $repo_vars as a setting — it is a GitHub REPOSITORY VARIABLE (Settings → Secrets and variables → Actions), read by a workflow expression before any checkout exists, so nothing reads it here; set it in the repository's variables instead"
  else
    ok "no GitHub repository variable is assigned as a repo setting"
  fi
  if [ -n "$(printf '%s' "$dotted" | tr -d '[:space:]')" ]; then
    bad "$SETTINGS_FILE assigns REVIEW_GATE_* key(s) with a DOTTED name: $(printf '%s' "$dotted" | tr '\n' ' ')— valid TOML, but the loader reads the bare name followed by its own \`=\`, so these assignments are read by nothing and the gate runs on the built-in default; drop the dotted suffix"
  else
    ok "no REVIEW_GATE_* assignment hides behind a dotted key"
  fi
  if [ -n "$(printf '%s' "$quoted" | tr -d '[:space:]')" ]; then
    bad "$SETTINGS_FILE assigns REVIEW_GATE_* key(s) with a QUOTED name: $(printf '%s' "$quoted" | tr '\n' ' ')— valid TOML, but the loader's presence probe matches the bare name only, so these assignments are read by nothing and the gate runs on the built-in default; drop the quotes"
  else
    ok "every REVIEW_GATE_* assignment uses the bare key name the loader reads"
  fi
fi

# The value rules are the ENGINE's, invoked rather than restated: a rule
# added to the predicate is enforced here on the same commit. The
# environment is scrubbed of every known key so the committed file is what
# answers — an exported value would otherwise validate a setting no CI run
# of the gate will ever see.
scrub=(env)
while IFS= read -r key; do
  [ -z "$key" ] && continue
  scrub[${#scrub[@]}]="-u"
  scrub[${#scrub[@]}]="$key"
done <<EOF_SCRUB
$KNOWN_KEYS
EOF_SCRUB

predicate="$SKILL_DIR/scripts/review-predicate.sh"
if [ ! -x "$predicate" ]; then
  bad "cannot validate settings values: scripts/review-predicate.sh is missing or not executable (the runtime group above says which)"
else
  cfg_rc=0
  cfg_err="$("${scrub[@]}" "$predicate" --check-config 2>&1 >/dev/null)" || cfg_rc=$?
  if [ "$cfg_rc" -eq 0 ]; then
    ok "every committed setting resolves to a legal value (review-predicate.sh --check-config)"
  else
    bad "a committed setting is not legal:"
    printf '%s\n' "$cfg_err" | sed 's/^/        /'
  fi
fi

# ----------------------------------------------------------------- carry ---

group "carry-forward exclusions"

CARRY_TMP="$(mktemp -d)" || die "could not create a scratch directory"
trap 'rm -rf "$CARRY_TMP"' EXIT

# The loader's DIAGNOSTIC is kept and a refusal is a finding: collapsing a
# failed read into an empty value would read as "no exclusions configured"
# and report a clean sheet. The PROPHYLACTIC key is the one nothing else
# validates — the predicate never reads it — so here is its only reader.
CARRY_LOAD_FAILED=0
carry_setting() { # KEY — sets CARRY_VALUE; a refusal is a FAIL row, not ""
  local rc=0
  CARRY_VALUE=""
  CARRY_VALUE="$("${scrub[@]}" bash -c '
    . "$1/scripts/lib/settings.sh"
    rg_setting "$2" ""
  ' _ "$SKILL_DIR" "$1" 2>"$CARRY_TMP/err")" || rc=$?
  [ "$rc" -eq 0 ] && return 0
  CARRY_LOAD_FAILED=1
  CARRY_VALUE=""
  bad "$SETTINGS_FILE: $1 could not be read — a refused load is a configuration error, never an empty value:
$(sed 's/^/        /' "$CARRY_TMP/err")"
  return 0
}

list_items() { # PACKED — one trimmed, non-empty item per line
  printf '%s' "$1" | tr ';' '\n' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//' | sed '/^$/d'
}

carry_setting REVIEW_GATE_CARRY_FORWARD
CARRY_FORWARD="$CARRY_VALUE"
carry_setting REVIEW_GATE_CARRY_FORWARD_EXCLUDE
CARRY_EXCLUDE="$CARRY_VALUE"
carry_setting REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC
CARRY_PROPHYLACTIC="$CARRY_VALUE"

if [ "$CARRY_LOAD_FAILED" -eq 1 ]; then
  note "the exclusion checks below are SKIPPED — a value above could not be read, and checking the empty list it would otherwise default to reports a clean sheet"
elif [ -z "$CARRY_FORWARD" ]; then
  note "REVIEW_GATE_CARRY_FORWARD is empty — carry-forward is off and these exclusions are inert; they are checked anyway, because dead config bites on the day the class is turned on"
fi

TRACKED=()
TRACKED_TOTAL=0
while IFS= read -r -d '' path; do
  TRACKED[$TRACKED_TOTAL]="$path"
  TRACKED_TOTAL=$((TRACKED_TOTAL + 1))
done < <(git ls-files -z)
[ "$TRACKED_TOTAL" -gt 0 ] ||
  die "git tracks no files here — a dead-glob verdict would be unreachable and every exclusion would pass"

# Matching is the PREDICATE's: an unquoted case pattern, so '*' spans '/'
# exactly as fnmatch-without-FNM_PATHNAME does at gate time. A checker
# matching more narrowly would call a live glob dead.
glob_hits() { # GLOB — sets GLOB_FIRST and GLOB_TOTAL (never a subshell: the
              # counts are read back by the caller)
  local pat="$1" p
  GLOB_FIRST=""
  GLOB_TOTAL=0
  for p in "${TRACKED[@]}"; do
    case "$p" in
      $pat)
        GLOB_TOTAL=$((GLOB_TOTAL + 1))
        [ -n "$GLOB_FIRST" ] || GLOB_FIRST="$p"
        ;;
    esac
  done
}

# Planted controls in both directions. Without them a matcher that matched
# everything, or nothing, would report a clean sheet and every real defect
# below would be unreachable.
GLOB_FIRST=""
GLOB_TOTAL=0
glob_hits '*'
[ -n "$GLOB_FIRST" ] && [ "$GLOB_TOTAL" -eq "$TRACKED_TOTAL" ] ||
  die "the glob matcher did not match every tracked path against '*' — the universal and dead verdicts below are unreachable"
glob_hits '__review-gate-validate-no-such-path__/*'
[ -z "$GLOB_FIRST" ] && [ "$GLOB_TOTAL" -eq 0 ] ||
  die "the glob matcher matched a planted impossible path — every dead glob below would pass silently"

exclude_items="$(list_items "$CARRY_EXCLUDE")"
prophylactic_items="$(list_items "$CARRY_PROPHYLACTIC")"

if [ "$CARRY_LOAD_FAILED" -eq 1 ]; then : # the refusal above said why
elif [ -z "$exclude_items" ]; then
  note "REVIEW_GATE_CARRY_FORWARD_EXCLUDE is empty — no exclusion globs to check"
else
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    case "$pat" in
      /*)
        bad "carry-exclude '$pat' is anchored with a leading '/' — compare filenames are repository-relative, so this glob can never match and the paths it names are NOT excluded"
        continue
        ;;
    esac
    glob_hits "$pat"
    if [ -z "$GLOB_FIRST" ]; then
      if grep -qxF -- "$pat" <<<"$prophylactic_items"; then
        note "carry-exclude '$pat' matches no tracked path and is DECLARED prophylactic"
      else
        bad "carry-exclude '$pat' matches no tracked path — a typo or a wrong anchor is dead config that excludes nothing (declare it in REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC if it deliberately guards paths that do not exist yet)"
      fi
      continue
    fi
    if [ "$GLOB_TOTAL" -eq "$TRACKED_TOTAL" ]; then
      bad "carry-exclude '$pat' matches EVERY tracked path — no delta could ever carry; narrow the exclusion, or turn REVIEW_GATE_CARRY_FORWARD off instead of excluding everything"
      continue
    fi
    ok "carry-exclude '$pat' matches $GLOB_TOTAL tracked path(s), e.g. $GLOB_FIRST"
  done <<EOF_EXCLUDE
$exclude_items
EOF_EXCLUDE
fi

# The ledger is reconciled in BOTH directions: a declaration whose exclusion
# is gone waives nothing, and a declaration whose glob now matches keeps a
# live exclusion out of the checks above.
if [ "$CARRY_LOAD_FAILED" -eq 1 ]; then : # ditto
elif [ -z "$prophylactic_items" ]; then
  note "REVIEW_GATE_CARRY_FORWARD_EXCLUDE_PROPHYLACTIC is empty — no declarations to reconcile"
else
  while IFS= read -r pat; do
    [ -z "$pat" ] && continue
    if ! grep -qxF -- "$pat" <<<"$exclude_items"; then
      bad "prophylactic declaration '$pat' is not an entry in REVIEW_GATE_CARRY_FORWARD_EXCLUDE — a waiver without its glob is stale config; remove the declaration, or restore the exclusion it waives"
      continue
    fi
    glob_hits "$pat"
    if [ -n "$GLOB_FIRST" ]; then
      bad "prophylactic declaration '$pat' no longer holds: the glob now matches '$GLOB_FIRST' — remove the declaration so the live exclusion is checked"
      continue
    fi
    ok "prophylactic declaration '$pat' is an active exclusion and still matches nothing"
  done <<EOF_PROPHYLACTIC
$prophylactic_items
EOF_PROPHYLACTIC
fi

# -------------------------------------------------------------- workflow ---
group "adopted writer workflow"

# A PEER TOOL, run as a subprocess: it is the one group whose subject —
# the adopted workflow file — is shared with nothing else here, and it
# stands alone for anyone changing only that copy. Its verdict lines are
# relayed and its counts folded in, so this summary still speaks for every
# check that ran.
workflow_tool="$SKILL_DIR/scripts/validate-workflow.sh"
if [ ! -x "$workflow_tool" ]; then
  bad "cannot check the adopted workflow: scripts/validate-workflow.sh is missing or not executable (the runtime group above says which)"
else
  wf_rc=0
  wf_out="$("$workflow_tool")" || wf_rc=$?
  printf '%s\n' "$wf_out"
  [ "$wf_rc" -le 1 ] ||
    die "the adopted-workflow check could not run (validate-workflow.sh exit $wf_rc); its ::error above says why"
  wf_ok=0
  wf_bad=0
  while IFS= read -r line; do
    case "$line" in
      ok*) wf_ok=$((wf_ok + 1)) ;;
      FAIL*) wf_bad=$((wf_bad + 1)) ;;
    esac
  done <<EOF_WF
$wf_out
EOF_WF
  # The exit code and the verdicts must AGREE. A peer that exits 1 having
  # named nothing failed in a way it could not describe — an unhandled
  # command failure, or a file damaged down to `exit 1` that is still
  # executable and still parses — and folding zero counted failures from it
  # reports a clean sheet for a check that never ran.
  if [ "$wf_rc" -eq 1 ] && [ "$wf_bad" -eq 0 ]; then
    bad "the adopted-workflow check exited 1 without printing a single FAIL verdict — it failed in a way it could not name, so nothing here knows whether the workflow was checked at all; re-run \`kendex refresh\` and commit the result"
  elif [ "$wf_rc" -eq 0 ] && [ "$wf_bad" -gt 0 ]; then
    bad "the adopted-workflow check printed $wf_bad FAIL verdict(s) but exited 0 — its verdicts and its exit code disagree, so neither can be trusted"
  fi
  PASS=$((PASS + wf_ok))
  FAILED=$((FAILED + wf_bad))
fi

printf '\n'
if [ "$FAILED" -gt 0 ]; then
  printf 'review-gate validate: %d check(s) failed, %d passed\n' "$FAILED" "$PASS"
  exit 1
fi
printf 'review-gate validate: %d checks passed\n' "$PASS"
exit 0
