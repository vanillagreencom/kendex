#!/usr/bin/env bash
# The writer's install step, EXECUTED: its `run:` script extracted from the
# workflow and run under the runner's default `bash -e`, beside doubles for
# the three things it calls. review-policy answers each flag as the case says
# (its own suite holds what the flags print), curl hands back an installer
# double, and that double records the arguments and the HOME, XDG_DATA_HOME
# and first PATH entry it ran under, which are what decide where the real
# installer puts the command. The step runs against the template and against
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

  # label | --check-config | --lock-kendex | exit | installs | GITHUB_ENV
  rows=0
  while IFS='|' read -r case_label check lock want_rc want_installs want_env; do
    rows=$((rows + 1))
    runner_temp="$work/runner-temp"
    rm -rf -- "$runner_temp"
    mkdir -p "$runner_temp"
    : >"$work/curl.log"; : >"$work/install.log"; : >"$work/github-env"
    rc=0
    (cd "$work" && env CHECK_CONFIG="$check" LOCK_KENDEX="$lock" \
      CURL_LOG="$work/curl.log" INSTALL_LOG="$work/install.log" \
      GITHUB_ENV="$work/github-env" RUNNER_TEMP="$runner_temp" HOME="$work/home" \
      KENDEX_VERSION=v1.2.0 KENDEX_INSTALLER_SHA=0123456789abcdef0123456789abcdef01234567 \
      KENDEX_INSTALLER_REPO=o/kendex GH_TOKEN= PATH="$BIN:$PATH" \
      bash -e "$step" >/dev/null 2>&1) || rc=$?
    installs="$(sed "s#$runner_temp#RT#g; s#$work/home#HOME#g; s#$BIN#BIN#g" "$work/install.log" | paste -sd';' -)"
    github_env="$(sed "s#$runner_temp#RT#g" "$work/github-env" | paste -sd';' -)"
    assert_eq "$rc" "$want_rc" "[$label] $case_label: exit"
    assert_eq "$installs" "$want_installs" "[$label] $case_label: installs"
    assert_eq "$github_env" "$want_env" "[$label] $case_label: GITHUB_ENV"
    if [[ -s "$work/curl.log" ]]; then
      assert_eq "$(sort -u "$work/curl.log")" "$INSTALLER_URL" "[$label] $case_label: every install fetches the pinned installer"
    fi
  done <<'CASES'
an inactive policy installs nothing|review-policy=inactive|review-policy-lock-kendex=main|0||
an empty setting installs the pinned release alone|review-policy=active|review-policy-lock-kendex=off|0|args=--version v1.2.0 home=HOME data= path=BIN|
main also installs the rolling main build into its own home and hands its path on|review-policy=active|review-policy-lock-kendex=main|0|args=--version v1.2.0 home=HOME data= path=BIN;args=--git --cli-only home=RT/kendex-lock data=RT/kendex-lock/.local/share path=RT/kendex-lock/.local/bin|HARNESS_CI_LOCK_KENDEX=RT/kendex-lock/.local/bin/kendex
a refused setting fails the step after the pinned release|review-policy=active|refuse|2|args=--version v1.2.0 home=HOME data= path=BIN|
a record neither off nor main fails the step|review-policy=active|review-policy-lock-kendex=yes|1|args=--version v1.2.0 home=HOME data= path=BIN|
CASES
  [[ "$rows" -gt 0 ]] || { FAIL=$((FAIL + 1)); printf '  FAIL  [%s] %s\n' "$label" "the case table ran no rows"; }
done

printf '\npass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
