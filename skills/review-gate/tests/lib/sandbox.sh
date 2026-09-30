# shellcheck shell=bash
# Shared consumer sandbox and assertion library.
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() {
  FAIL=$((FAIL + 1))
  printf '  FAIL  %s\n' "$1"
  [ -n "${2:-}" ] && printf '%s\n' "$2" | sed 's/^/        /'
  return 0
}

PRISTINE="$TMP/pristine"
mkdir -p "$PRISTINE/.agents/skills" "$PRISTINE/.github/workflows" "$PRISTINE/docs"
cp -R "$SKILL_DIR" "$PRISTINE/.agents/skills/review-gate"
cp -R "$SKILL_DIR/../harness-ci" "$PRISTINE/.agents/skills/harness-ci"
printf '[env]\n' >"$PRISTINE/kendex.settings.toml"
printf '[]\n' >"$PRISTINE/.kendex-generated.json"
printf 'sandbox\n' >"$PRISTINE/docs/guide.md"
printf 'sandbox\n' >"$PRISTINE/AGENTS.md"
(
  cd "$PRISTINE"
  git init -q .
  git config maintenance.auto false
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
# Append a setting in the consumer's committed environment table.
settings() { # DIR KEY VALUE
  printf '%s = "%s"\n' "$2" "$3" >>"$1/kendex.settings.toml"
}

# The install suite supplies its recording curl in TMP/bin. Each run starts
# with an explicit environment and empty records, including for controls.
run_install_latest() { # SCRIPT RELEASE COMMIT FAIL_AT INSTALL_RC [GITHUB_ASSIGNMENT GH_ASSIGNMENT]
  local script="$1" release="$2" commit="$3" fail_at="$4" install_rc="$5"
  local github_env="${6:-}" gh_env="${7:-}" token_env=()
  INSTALL_TOKENS=("${github_env#*=}" "${gh_env#*=}")
  [ -z "$github_env" ] || token_env+=("$github_env")
  [ -z "$gh_env" ] || token_env+=("$gh_env")
  : >"$TMP/calls"
  : >"$TMP/transport"
  : >"$TMP/github-path"
  rm -f "$TMP/install-log" "$TMP/install-env"
  OUT="" RC=0
  OUT="$(env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" \
    CALLS="$TMP/calls" TRANSPORT_LOG="$TMP/transport" INSTALL_LOG="$TMP/install-log" INSTALL_ENV="$TMP/install-env" \
    GITHUB_PATH="$TMP/github-path" RELEASE="$release" COMMIT="$commit" FAIL_AT="$fail_at" INSTALL_RC="$install_rc" \
    ${token_env[@]+"${token_env[@]}"} bash "$script" 2>&1)" || RC=$?
}

# One assertion holds the transport, installer arguments, environment and
# path record together. Controls use the same assertion as the success rows.
install_latest_matches() { # VERSION SHA API_AUTHORIZATION
  local version="$1" sha="$2" authorization="$3" calls transport arguments environment github_path token
  calls="$(cat "$TMP/calls")" || return 1
  transport="$(cat "$TMP/transport")" || return 1
  arguments="$(cat "$TMP/install-log")" || return 1
  environment="$(cat "$TMP/install-env")" || return 1
  github_path="$(cat "$TMP/github-path")" || return 1
  [ "$calls" = "https://api.github.com/repos/vanillagreencom/kendex/releases/latest
https://api.github.com/repos/vanillagreencom/kendex/commits/$version
https://raw.githubusercontent.com/vanillagreencom/kendex/$sha/install.sh" ] || return 1
  [ "$transport" = "https://api.github.com/repos/vanillagreencom/kendex/releases/latest|$authorization|unset|unset
https://api.github.com/repos/vanillagreencom/kendex/commits/$version|$authorization|unset|unset
https://raw.githubusercontent.com/vanillagreencom/kendex/$sha/install.sh||unset|unset" ] || return 1
  [ "$arguments" = "--version $version --cli-only" ] && [ "$environment" = 'unset|unset' ] &&
    [ "$github_path" = "$TMP/.local/bin" ] || return 1
  for token in "${INSTALL_TOKENS[@]}"; do
    [ -n "$token" ] || continue
    case "$OUT" in *"$token"*) return 1 ;; esac
  done
  return 0
}
