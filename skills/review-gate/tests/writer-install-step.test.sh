#!/usr/bin/env bash
# The writer's install step, EXECUTED: its `run:` script extracted from the
# workflow and run under the runner's default `bash -e`, beside doubles for
# the three things it calls. review-policy answers each flag as the case says
# (its own suite holds what the flags print), curl hands back an installer
# double, and that double records the arguments and the HOME, XDG_DATA_HOME
# and first PATH entry it ran under, which are what decide where the real
# installer puts the command, then exits with the case's status for a --git
# install, the main build. The step runs against the template and against
# this repository's adopted copy where one exists.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_ROOT="$(cd "$TEST_DIR/.." && pwd)"
TMP_ROOT="$(mktemp -d)" || { echo "writer-install-step: scratch=mktemp-failed" >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "writer-install-step: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo "writer-install-step: scratch=resolve-failed" >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

PASS=0
FAIL=0
assert_eq() { # GOT WANT NAME
  if [[ "$1" == "$2" ]]; then
    PASS=$((PASS + 1)); printf '  ok    %s\n' "$3"
  else
    FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        expected: %s\n        got:      %s\n' "$3" "$2" "$1"
  fi
}

TEMPLATE="$SKILL_ROOT/templates/review-gate-writer.yml"
WORKFLOWS=("$TEMPLATE")
LABELS=(template)
# The adopted copy, found by walking up to the enclosing repository, as the
# template suite finds it.
dir="$SKILL_ROOT"
while [[ "$dir" != / ]]; do
  if [[ -e "$dir/.git" || -d "$dir/.github" ]]; then
    [[ ! -f "$dir/.github/workflows/review-gate-writer.yml" ]] ||
      { WORKFLOWS+=("$dir/.github/workflows/review-gate-writer.yml"); LABELS+=("adopted copy"); }
    break
  fi
  dir="$(dirname "$dir")"
done

BIN="$TMP_ROOT/bin"
mkdir -p "$BIN"
cat >"$BIN/curl" <<'CURL'
#!/usr/bin/env bash
printf '%s\n' "${@: -1}" >>"$CURL_LOG"
printf '. "%s"\n' "$INSTALLER_DOUBLE"
CURL
export INSTALLER_DOUBLE="$TMP_ROOT/installer"
cat >"$INSTALLER_DOUBLE" <<'INSTALLER'
printf 'args=%s home=%s data=%s path=%s\n' "$*" "$HOME" "${XDG_DATA_HOME:-}" "${PATH%%:*}" >>"$INSTALL_LOG"
case "$*" in *--git*) exit "$MAIN_BUILD_RC" ;; esac
INSTALLER
# review-policy answers --check-config with CHECK_CONFIG and --lock-kendex with
# LOCK_KENDEX, or exits 2 where LOCK_KENDEX is `refuse`.
policy_double() { # PATH
  mkdir -p "$(dirname "$1")"
  cat >"$1" <<'POLICY'
#!/usr/bin/env bash
case "$1" in
  --check-config) printf '%s\n' "$CHECK_CONFIG" ;;
  --lock-kendex)
    [ "$LOCK_KENDEX" != refuse ] || exit 2
    printf '%s\n' "$LOCK_KENDEX" ;;
  *) echo "review-policy double: unexpected $*" >&2; exit 2 ;;
esac
POLICY
  chmod +x "$1"
}
chmod +x "$BIN/curl"

extract_step() { # WORKFLOW OUT
  awk '
    /^      - name: Install kendex for change classification$/ { found = 1; next }
    found && !inblock && /^        run: \|$/ { inblock = 1; next }
    inblock {
      if ($0 ~ /^          / || $0 == "") { sub(/^          /, ""); print; next }
      exit
    }
  ' "$1" >"$2"
}

INSTALLER_URL="https://raw.githubusercontent.com/o/kendex/0123456789abcdef0123456789abcdef01234567/install.sh"

# Runs STEP in WORK, whose review-policy doubles answer CHECK and LOCK, with
# the main-build installer exiting MAIN_RC. Sets ROW_RC, ROW_INSTALLS and
# ROW_ENV, with the runner temp, HOME and doubles directory masked.
run_row() { # STEP WORK CHECK LOCK MAIN_RC
  local step="$1" work="$2" runner_temp="$2/runner-temp"
  rm -rf -- "${work:?}/runner-temp"
  mkdir -p "$runner_temp"
  : >"$work/curl.log"; : >"$work/install.log"; : >"$work/github-env"
  ROW_RC=0
  (cd "$work" && env CHECK_CONFIG="$3" LOCK_KENDEX="$4" MAIN_BUILD_RC="$5" \
    CURL_LOG="$work/curl.log" INSTALL_LOG="$work/install.log" \
    GITHUB_ENV="$work/github-env" RUNNER_TEMP="$runner_temp" HOME="$work/home" \
    KENDEX_VERSION=v1.2.0 KENDEX_INSTALLER_SHA=0123456789abcdef0123456789abcdef01234567 \
    KENDEX_INSTALLER_REPO=o/kendex GH_TOKEN= PATH="$BIN:$PATH" \
    bash -e "$step" >"$work/stdout" 2>/dev/null) || ROW_RC=$?
  ROW_INSTALLS="$(sed "s#$runner_temp#RT#g; s#$work/home#HOME#g; s#$BIN#BIN#g" "$work/install.log" | paste -sd';' -)"
  ROW_ENV="$(sed "s#$runner_temp#RT#g" "$work/github-env" | paste -sd';' -)"
}

for i in "${!WORKFLOWS[@]}"; do
  label="${LABELS[$i]}"
  step="$TMP_ROOT/step-$i.sh"
  extract_step "${WORKFLOWS[$i]}" "$step"
  if ! grep -qF -- '--lock-kendex' "$step"; then
    FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$label" "the install step could not be extracted, or reads no --lock-kendex"
    continue
  fi
  work="$TMP_ROOT/work-$i"
  mkdir -p "$work"
  policy_double "$work/.agents/skills/review-gate/scripts/review-policy"
  policy_double "$work/skills/review-gate/scripts/review-policy"

  # label | --check-config | --lock-kendex | main-build installer exit | exit
  # | installs | GITHUB_ENV | warning keys
  rows=0
  while IFS='|' read -r case_label check lock main_rc want_rc want_installs want_env want_warn; do
    rows=$((rows + 1))
    run_row "$step" "$work" "$check" "$lock" "$main_rc"
    assert_eq "$ROW_RC" "$want_rc" "[$label] $case_label: exit"
    assert_eq "$ROW_INSTALLS" "$want_installs" "[$label] $case_label: installs"
    assert_eq "$ROW_ENV" "$want_env" "[$label] $case_label: GITHUB_ENV"
    assert_eq "$(sed -n 's/^::warning::\([^:]*\):.*/\1/p' "$work/stdout" | paste -sd';' -)" "$want_warn" "[$label] $case_label: warnings"
    if [[ -s "$work/curl.log" ]]; then
      assert_eq "$(sort -u "$work/curl.log")" "$INSTALLER_URL" "[$label] $case_label: every install fetches the pinned installer"
    fi
  done <<'CASES'
an inactive policy installs nothing|review-policy=inactive|review-policy-lock-kendex=main|0|0|||
an empty setting installs the pinned release alone|review-policy=active|review-policy-lock-kendex=off|0|0|args=--version v1.2.0 home=HOME data= path=BIN||
main also installs the rolling main build into its own home and hands its path on|review-policy=active|review-policy-lock-kendex=main|0|0|args=--version v1.2.0 home=HOME data= path=BIN;args=--git --cli-only home=RT/kendex-lock data=RT/kendex-lock/.local/share path=RT/kendex-lock/.local/bin|HARNESS_CI_LOCK_KENDEX=RT/kendex-lock/.local/bin/kendex|
a main build that fails to install warns and leaves the pinned release to judge|review-policy=active|review-policy-lock-kendex=main|3|0|args=--version v1.2.0 home=HOME data= path=BIN;args=--git --cli-only home=RT/kendex-lock data=RT/kendex-lock/.local/share path=RT/kendex-lock/.local/bin||lock-kendex-install exit=3
a refused setting fails the step after the pinned release|review-policy=active|refuse|0|2|args=--version v1.2.0 home=HOME data= path=BIN||
a record neither off nor main fails the step|review-policy=active|review-policy-lock-kendex=yes|0|1|args=--version v1.2.0 home=HOME data= path=BIN||
CASES
  [[ "$rows" -gt 0 ]] || { FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$label" "the case table ran no rows"; }
done

# Must-fail control: the template's step with its export of the main build's
# path made inert. On the main row it still installs that build and hands no
# path on, so the main row's GITHUB_ENV assertion reads it as a failure.
extracted="$TMP_ROOT/inert-export.extracted.sh"
inert="$TMP_ROOT/inert-export.sh"
extract_step "$TEMPLATE" "$extracted"
export_line='printf '\''HARNESS_CI_LOCK_KENDEX=%s\n'\'' "$lock_home/.local/bin/kendex" >>"$GITHUB_ENV"'
hits="$(LINE="$export_line" OUT="$inert" awk '
  { body = $0; sub(/^ +/, "", body) }
  body == ENVIRON["LINE"] { hits++; sub(/printf/, ": printf") }
  { print > ENVIRON["OUT"] }
  END { print hits + 0 }
' "$extracted")" || hits=awk-failed
assert_eq "$hits" 1 "control: the export line occurs once in the template step"
if cmp -s -- "$extracted" "$inert"; then
  assert_eq unchanged changed "control: the edit changes the step copy"
fi
control_work="$TMP_ROOT/work-control"
mkdir -p "$control_work"
policy_double "$control_work/.agents/skills/review-gate/scripts/review-policy"
run_row "$inert" "$control_work" review-policy=active review-policy-lock-kendex=main 0
assert_eq "$ROW_INSTALLS" "args=--version v1.2.0 home=HOME data= path=BIN;args=--git --cli-only home=RT/kendex-lock data=RT/kendex-lock/.local/share path=RT/kendex-lock/.local/bin" \
  "control: the inert step still installs the main build"
assert_eq "$ROW_ENV" "" "control: the inert step hands no path on, which the main row's GITHUB_ENV value refuses"

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
