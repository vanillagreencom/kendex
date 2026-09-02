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

  runtime     every engine script this repo needs is present, TRACKED (CI
              checks out nothing else), executable and parses under `bash -n`.
  settings    the committed file is TRACKED (CI checks out nothing else), and
              every REVIEW_GATE_* assignment is one the engine reads, spelt
              the ONE way it reads them (a bare key, then its own `=`), and
              legal. Unknown keys, per-invocation seams and repository
              variables are each named as what they are; the value rules come
              from `review-predicate.sh --check-config`, never a copy of them.
  carry       every REVIEW_GATE_CARRY_FORWARD_EXCLUDE glob matches a
              tracked path and is not universal; every prophylactic
              declaration names an active exclusion that still matches
              nothing. A value the loader refuses is a finding, never an
              empty list. Pattern SPELLING is not judged here — the engine
              owns that grammar, and `--check-config` above relays its
              verdict, so this tool cannot drift from the matcher.
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
#
# Paths below are SKILL-relative, and every remediation naming one has to be
# runnable where the reader is standing — the repository root, which is where
# this script cd'd. A skill outside the repository leaves the prefix
# unstripped, which is an absolute path and still names the right file.
SKILL_REL="${SKILL_DIR#"$REPO_ROOT"/}"
for rel in scripts/review-predicate.sh scripts/review-writer.sh \
  scripts/pr-watch.sh scripts/validate.sh \
  scripts/validate-workflow.sh scripts/lib/settings.sh; do
  path="$SKILL_DIR/$rel"
  if [ ! -f "$path" ]; then
    bad "$rel is missing from the installed skill ($SKILL_DIR) — re-run \`kendex refresh\` and commit the result"
    continue
  fi
  # A tracked SYMLINK is not tracked content, and every check below follows
  # it: presence, syntax and mode all answer for the local target while a
  # fresh checkout holds the link itself, pointing at whatever is there —
  # nothing, if the target was untracked or outside the repository.
  if [ -L "$path" ]; then
    bad "$rel is a SYMLINK — presence, syntax and mode below would answer for its target, while CI checks out the link and resolves whatever sits at the other end. Commit the file itself"
    continue
  fi
  if ! bash -n "$path" 2>/dev/null; then
    bad "$rel does not parse under \`bash -n\` — the install is truncated or edited; re-run \`kendex refresh\`"
    continue
  fi
  # PRESENT is not COMMITTED, the same split the settings check closes: an
  # untracked engine passes every check here and does not exist in Actions,
  # where the writer then fails to execute on every leg.
  if ! git ls-files --error-unmatch -- "$SKILL_REL/$rel" >/dev/null 2>&1; then
    bad "$rel is present but UNTRACKED — CI checks out tracked files only, so the engine validated here is absent there and the writer cannot run (\`git add $SKILL_REL/$rel\`)"
    continue
  fi
  case "$rel" in
    */lib/*) ok "$rel is present, tracked and parses" ;;
    *)
      if [ -x "$path" ]; then
        ok "$rel is present, tracked, executable and parses"
      else
        bad "$rel is not executable — CI runs it directly, so a lost mode bit reds the writer on every leg (\`git update-index --chmod=+x $SKILL_REL/$rel\`)"
      fi
      ;;
  esac
done

# -------------------------------------------------------------- settings ---

group "settings"

SETTINGS_FILE="${REVIEW_GATE_SETTINGS_FILE:-kendex.settings.toml}"

# The key ledger is the skill's own shipped example, so this tool cannot
# drift from what the engine documents.
EXAMPLE="$SKILL_DIR/kendex.settings.toml.example"
[ -f "$EXAMPLE" ] ||
  die "$EXAMPLE is missing — it is the ledger of known keys, and without it an unknown-key scan would pass everything"
KNOWN_KEYS="$(sed -n 's/^[[:space:]]*\([A-Z][A-Z0-9_]*\)[[:space:]]*=.*/\1/p' "$EXAMPLE")"
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

# One default-TOML source, checked whole: tracking state, then the keyscan
# findings, each naming the file it was found in.
scan_settings_source() { # FILE
  local sf="$1"
  local keyscan assigned outside unread badheaders unknown seams repo_vars key
  # PRESENT is not COMMITTED. CI checks out tracked files only, so an
  # untracked settings file validates here with the intended trust values
  # while the gate runs on the built-in defaults — the widest possible split
  # between what was checked and what runs. An explicit
  # REVIEW_GATE_SETTINGS_FILE is a caller handle pointing anywhere, so it is
  # exempt and says so.
  if [ -n "${REVIEW_GATE_SETTINGS_FILE:-}" ]; then
    note "$sf is present (named by REVIEW_GATE_SETTINGS_FILE, so it is not required to be tracked)"
  elif [ -L "$sf" ]; then
    bad "$sf is a SYMLINK — everything below would read its target's bytes, while CI checks out the link itself and the engine resolves whatever sits there. Commit the real file, or name the shared one with REVIEW_GATE_SETTINGS_FILE, which is the handle for a path outside this repository"
  elif git ls-files --error-unmatch -- "$sf" >/dev/null 2>&1; then
    ok "$sf is present and tracked"
  else
    bad "$sf is present but UNTRACKED — CI checks out tracked files only, so every value below is validated here and absent there; the gate would run on the built-in defaults. \`git add $sf\`"
  fi
  # INVERTED, after four spellings arrived one at a time — quoted, dotted,
  # quoted-dotted, and a key nested in an inline table. Enumerate what the
  # loader READS, not the ways to hide from it: the loader reads the [env]
  # table only (scripts/lib/settings.sh), and inside it probes
  # `^[[:space:]]*NAME[[:space:]]*=` — the bare name at the start of its own
  # line, then its own `=`, and nothing else. A bare assignment OUTSIDE
  # [env] is its own finding: the shape is right, the location is not, and
  # "you misspelled it" would send its reader hunting a typo that is not
  # there.
  #
  # Beyond that there is NO classification. Comments are dropped, and after
  # that any occurrence of the REVIEW_GATE_ token on a line that is not
  # exactly that shape is a finding — including one inside a string value,
  # which is deliberate: every carve-out this check has had (the key
  # position, the text before the first `=`) became the next hole. The
  # verdict says what the rule is, so a legitimate mention is one reword
  # away and a setting nobody reads is never reported healthy.
  keyscan="$(awk '
    { l = $0; sub(/\r$/, "", l) }
    l ~ /^[[:space:]]*\[/ && l !~ /^[[:space:]]*\[[A-Za-z0-9_.-]+\][[:space:]]*$/ {
      print "badheader line " NR ": " l
      next
    }
    /^[[:space:]]*\[[A-Za-z0-9_.-]+\][[:space:]]*$/ {
      h = l
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", h)
      in_env = (h == "[env]")
    }
    l ~ /^[[:space:]]*#/ { next }
    l !~ /REVIEW_GATE_/ { next }
    l ~ /^[[:space:]]*REVIEW_GATE_[A-Za-z0-9_]*[[:space:]]*=/ {
      k = l
      sub(/^[[:space:]]*/, "", k)
      sub(/[[:space:]]*=.*$/, "", k)
      print (in_env ? "read " : "outside ") k
      next
    }
    {
      gsub(/^[[:space:]]+/, "", l)
      gsub(/[[:space:]]+$/, "", l)
      print "unread " l
    }
  ' < "$sf")"
  assigned="$(printf '%s\n' "$keyscan" | sed -n 's/^read //p' | sort -u)"
  outside="$(printf '%s\n' "$keyscan" | sed -n 's/^outside //p' | sort -u)"
  unread="$(printf '%s\n' "$keyscan" | sed -n 's/^unread //p')"
  badheaders="$(printf '%s\n' "$keyscan" | sed -n 's/^badheader //p')"
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
    bad "$sf assigns REVIEW_GATE_* key(s) the engine never reads: $unknown — a misspelled key resolves as unset, so the value written there is ignored and the gate runs on the default (key table: references/settings.md)"
  else
    ok "every REVIEW_GATE_* key assigned in $sf is one the engine reads"
  fi
  if [ -n "$seams" ]; then
    bad "$sf assigns per-invocation env seam(s): $seams — these are caller handles, never repo settings; delete the assignment(s)"
  else
    ok "no per-invocation env seam is assigned as a repo setting"
  fi
  if [ -n "$repo_vars" ]; then
    bad "$sf assigns $repo_vars as a setting — it is a GitHub REPOSITORY VARIABLE (Settings → Secrets and variables → Actions), read by a workflow expression before any checkout exists, so nothing reads it here; set it in the repository's variables instead"
  else
    ok "no GitHub repository variable is assigned as a repo setting"
  fi
  if [ -n "$outside" ]; then
    bad "$sf assigns REVIEW_GATE_* key(s) outside the [env] table: $outside — the loader reads only [env], so the value written there is ignored and the gate runs on the default; move the assignment(s) under the [env] header"
  else
    ok "every REVIEW_GATE_* assignment sits inside the [env] table"
  fi
  # The engine reads REVIEW_GATE_MODE from env and the COMMITTED root file
  # only, so a nested assignment of it is read by nothing: the mode set
  # here validates while the gate keeps enforcing. Same never-reads class
  # as a misspelled key, pointed at the file the engine does read.
  if [ "$sf" = ".kendex/settings.toml" ]; then
    if printf '%s\n' "$assigned" | grep -qx "REVIEW_GATE_MODE"; then
      bad "$sf assigns REVIEW_GATE_MODE, which the engine never reads from this file — that key resolves from env and the committed kendex.settings.toml only; move the assignment to kendex.settings.toml"
    else
      ok "REVIEW_GATE_MODE is not assigned in the machine-local file the engine skips for it"
    fi
  fi
  # Headers decide which assignments load, so a header shape the loader
  # cannot parse corrupts every classification after it: `[env] # comment`
  # hides the whole table, and a quoted or doubled header after [env] leaves
  # foreign keys reading as [env] keys. The loader refuses these files;
  # findings about lines below a malformed header describe the corrupted
  # read, so fix the header first.
  if [ -n "$badheaders" ]; then
    bad "$sf has table header(s) the loader cannot parse (a header is a lone [name] on its own line, with no comment and no second bracket):
$(printf '%s\n' "$badheaders" | sed 's/^/        /')"
  else
    ok "every table header parses as a lone [name]"
  fi
  # Every settings reader refuses a BOM-prefixed file whole (lib/settings.sh
  # rg_bom_guard): the BOM is neither whitespace nor `[` nor a key
  # character, so the first line would misclassify. Findings below a BOM
  # describe that corrupted read — remove the BOM first.
  if [ "$(head -c 3 < "$sf" 2>/dev/null)" = "$(printf '\357\273\277')" ]; then
    bad "$sf starts with a UTF-8 byte-order mark; remove it (every settings reader refuses the file whole)"
  else
    ok "no UTF-8 byte-order mark before the first line"
  fi
  if [ -n "$(printf '%s' "$unread" | tr -d '[:space:]')" ]; then
    bad "$sf names REVIEW_GATE_ in a shape the loader does not read. The loader reads ONE shape — a bare KEY at the start of its own line, followed by its own \`=\` — and everything else is unsupported syntax read by nothing, so the gate runs on the built-in default. This is deliberately unforgiving, string values included: every exception this check has carried became a place for the next spelling to hide. Rewrite, or reword a mention, on the line(s) below:
$(printf '%s\n' "$unread" | sed 's/^/        /')"
  else
    ok "every REVIEW_GATE_* assignment uses the bare key name the loader reads"
  fi
}

# ONE classification for every TOML source scanned below, so a third one
# added later inherits it. Testing -f alone read a present-but-unusable
# source as absent, and the scan then said "every key resolves to its
# built-in default" about a file it never opened; an unreadable one reached
# the scan and surfaced as bash's own line-numbered read error. The resolver
# refuses both shapes on whichever key it reads first — this is the half
# that says WHICH file to fix. ABSENT_NOTE is the caller's line for a
# genuinely absent source; a caller with nothing to say passes none.
scan_source() { # FILE [ABSENT_NOTE]
  if [ -f "$1" ]; then
    if [ ! -r "$1" ]; then
      bad "$1 exists but cannot be READ (permission denied); nothing below was checked against it"
      return 0
    fi
    scan_settings_source "$1"
  elif [ -e "$1" ] || [ -L "$1" ]; then
    bad "$1 exists but is not a file the loader can read (directory, FIFO, socket, device, or a symlink that does not resolve); a source is skipped only when it is ABSENT"
  elif [ -n "${2:-}" ]; then
    note "$2"
  fi
}

if [ "$SETTINGS_FILE" = "/dev/null" ]; then
  note "REVIEW_GATE_SETTINGS_FILE=/dev/null — settings are forced to built-in defaults; no committed file is being validated"
else
  scan_source "$SETTINGS_FILE" \
    "$SETTINGS_FILE is absent — every key resolves to its built-in default, which is a valid install carrying no per-repo values"
fi
# The resolver treats .kendex/settings.toml as the AUTHORITATIVE default
# TOML source when present, so with no explicit override the same checks
# cover it too: a committed nested file with a typo'd trust key must not
# validate clean while the engine ignores the typo and the gate widens.
if [ -z "${REVIEW_GATE_SETTINGS_FILE:-}" ]; then
  # No absent-note: a repo with no nested file is the ordinary install, and
  # the line above already said what an absent source resolves to.
  scan_source ".kendex/settings.toml"
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
  # A peer that printed NO verdict at all inspected nothing, whatever it
  # exited: a truncated or replaced file that parses and exits 0 passes the
  # runtime group, folds zero counts, and leaves this summary speaking for a
  # check that never ran.
  if [ "$((wf_ok + wf_bad))" -eq 0 ]; then
    bad "the adopted-workflow check printed no verdict at all — it inspected nothing, so the workflow is unchecked here whatever its exit code said; re-run \`kendex refresh\` and commit the result"
  elif [ "$wf_rc" -eq 1 ] && [ "$wf_bad" -eq 0 ]; then
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
