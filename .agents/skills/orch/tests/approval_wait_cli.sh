#!/usr/bin/env bash
# approval-wait's argument surface: `--resolve-mode` precedence over the
# process environment, kendex.settings.toml, .env.local (a .env file is read by
# nothing) and the settings-file override, with and without the engine installed;
# and the parser's own answers (-h, --help, an unknown flag, a missing value)
# before anything reaches gh. One run and one comparison per row: `observe`
# reads exactly the fields the row's expect names.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
# shellcheck source=lib/waiter-assertions.sh
source "$TEST_DIR/lib/waiter-assertions.sh"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Two projects: `gate` has the review-gate engine beside orch, `nogate` has
# orch copied and only github beside it, so approval-wait's own fallback
# loader reads the settings. A gh that records every call and fails.
mkdir -p "$TMP_ROOT/gate/.agents/skills" "$TMP_ROOT/nogate/.agents/skills" "$TMP_ROOT/bin"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/gate/.agents/skills/orch"
ln -s "$REPO_ROOT/skills/review-gate" "$TMP_ROOT/gate/.agents/skills/review-gate"
cp -r "$REPO_ROOT/skills/orch" "$TMP_ROOT/nogate/.agents/skills/orch"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/nogate/.agents/skills/github"
for p in gate nogate; do
  git -C "$TMP_ROOT/$p" init -q
  git -C "$TMP_ROOT/$p" config user.email test@example.com
  git -C "$TMP_ROOT/$p" config user.name Test
done
GH_CALLS="$TMP_ROOT/gh.calls"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %s\nexit 1\n' "$GH_CALLS" > "$TMP_ROOT/bin/gh"
chmod +x "$TMP_ROOT/bin/gh"

# stage PROJECT FILES — the project's configuration files for one row, every
# other file of the set removed first. FILES is `;`-separated `kind:K=V,K=V`
# items: `settings` and `alt` write a TOML `[env]` table (kendex.settings.toml
# and alt-settings.toml), `kendex` the machine-local .kendex/settings.toml,
# `dotenv` and `dotenvlocal` a `.env` or `.env.local` line per pair. A key
# listed twice is written twice.
stage() {
  local project="$TMP_ROOT/$1" spec="$2" items item kind pairs assignments pair path
  rm -f -- "$project/kendex.settings.toml" "$project/alt-settings.toml" "$project/.env" "$project/.env.local" "$project/.kendex/settings.toml"
  [[ -n "$spec" ]] || return 0
  IFS=';' read -ra items <<<"$spec"
  for item in "${items[@]}"; do
    kind="${item%%:*}"; pairs="${item#*:}"
    case "$kind" in
      settings) path="$project/kendex.settings.toml" ;;
      alt) path="$project/alt-settings.toml" ;;
      kendex) mkdir -p "$project/.kendex"; path="$project/.kendex/settings.toml" ;;
      dotenv) path="$project/.env" ;;
      dotenvlocal) path="$project/.env.local" ;;
      *) echo "stage: unknown file kind $kind" >&2; exit 1 ;;
    esac
    case "$kind" in settings|alt|kendex) printf '[env]\n' > "$path" ;; *) : > "$path" ;; esac
    IFS=',' read -ra assignments <<<"$pairs"
    for pair in "${assignments[@]}"; do
      case "$kind" in
        settings|alt|kendex) printf '%s = "%s"\n' "${pair%%=*}" "${pair#*=}" >> "$path" ;;
        *) printf '%s\n' "$pair" >> "$path" ;;
      esac
    done
  done
}

# run PROJECT ENV ARGS... — one approval-wait run in PROJECT under the
# space-separated ENV assignments and no other reviewer-gate key: the four the
# resolver reads are cleared from the inherited environment first, so a row's
# answer is its own on any machine. OUT, RC and ERR (a file) are what
# `observe` reads. The gh call log is emptied first.
RUN_SEQ=0
run() {
  local project="$TMP_ROOT/$1" env_spec="$2" env_args=()
  shift 2
  # shellcheck disable=SC2206
  [[ -z "$env_spec" ]] || env_args=($env_spec)
  ERR="$TMP_ROOT/run-$((++RUN_SEQ)).err"
  rm -f -- "$GH_CALLS"
  set +e
  OUT="$(cd "$project" && PATH="$TMP_ROOT/bin:$PATH" env -u PR_REVIEW_GATE -u PR_APPROVAL_GATE -u REVIEW_GATE_MODE -u REVIEW_GATE_SETTINGS_FILE ${env_args[@]+"${env_args[@]}"} .agents/skills/orch/scripts/approval-wait "$@" 2>"$ERR")"
  RC=$?
  set -e
}

# observe EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order (`+` reads as a space in a needle, so a literal plus cannot
# be pinned; no field carries one):
#   rc              exit status
#   mode            stdout whole
#   stdout          `empty` when nothing was printed, else `lines`
#   stdout~<text>   whether stdout carries <text>
#   stderr~<text>   whether stderr carries <text>
#   gh              `called` when the gh stub was reached, else `uncalled`
observe() {
  local got="" token name value needle
  set -f
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RC" ;;
      mode) value="${OUT// /+}" ;;
      stdout) value="$([[ -n "$OUT" ]] && echo lines || echo empty)" ;;
      stdout~*) needle="${name#stdout~}"; value="$(grep -qF -- "${needle//+/ }" <<<"$OUT" && echo true || echo false)" ;;
      stderr~*) needle="${name#stderr~}"; value="$(grep -qF -- "${needle//+/ }" "$ERR" && echo true || echo false)" ;;
      gh) value="$([[ -s "$GH_CALLS" ]] && echo called || echo uncalled)" ;;
      *) echo "observe: unknown field $name" >&2; exit 1 ;;
    esac
    got="$got $name=$value"
  done
  set +f
  printf '%s' "${got# }"
}

# resolve_table ROW... — `label|project|env|files|expect`, one --resolve-mode
# run per row.
resolve_table() {
  local row label project env files expect
  for row in "$@"; do
    IFS='|' read -r label project env files expect <<<"$row"
    [[ -n "$expect" ]] || { printf 'resolve_table: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
    stage "$project" "$files"
    run "$project" "$env" --resolve-mode
    assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
  done
}

echo "=== --resolve-mode precedence ==="
# PR_REVIEW_GATE names the mode and beats the legacy PR_APPROVAL_GATE, whose
# on and off map to approval and off; the default is approval, and so is an
# invalid value. The process environment beats kendex.settings.toml.
# REVIEW_GATE_MODE=off overrides either reviewer key; any other value never
# narrows (the engine fails loud on it, not this resolver). REVIEW_GATE_MODE is
# read from the process environment and the committed settings file only: a
# .env file is read by nothing, and .env.local is ignored for that one key
# while it keeps full precedence for PR_REVIEW_GATE. REVIEW_GATE_SETTINGS_FILE
# names another settings file, /dev/null included. A key assigned twice in the
# settings file fails loud, exit 2 from the engine and exit 1 from the
# fallback loader, which resolves no mode. The fallback reads the committed
# file and ignores the machine-local .kendex copy for the mode key too.
resolve_table \
  "PR_REVIEW_GATE=review|gate|PR_REVIEW_GATE=review||mode=review" \
  "PR_REVIEW_GATE=off|gate|PR_REVIEW_GATE=off||mode=off" \
  "PR_REVIEW_GATE=approval|gate|PR_REVIEW_GATE=approval||mode=approval" \
  "PR_REVIEW_GATE beats the legacy PR_APPROVAL_GATE|gate|PR_REVIEW_GATE=review PR_APPROVAL_GATE=off||mode=review" \
  "legacy on maps to approval|gate|PR_APPROVAL_GATE=on||mode=approval" \
  "legacy off maps to off|gate|PR_APPROVAL_GATE=off||mode=off" \
  "the default is approval|gate|||mode=approval" \
  "an invalid value falls back to approval|gate|PR_REVIEW_GATE=bogus||rc=0 mode=approval" \
  "a settings-file PR_REVIEW_GATE applies|gate||settings:PR_REVIEW_GATE=review|mode=review" \
  "the process environment beats the settings file|gate|PR_REVIEW_GATE=approval|settings:PR_REVIEW_GATE=review|mode=approval" \
  "REVIEW_GATE_MODE=off overrides approval|gate|REVIEW_GATE_MODE=off PR_REVIEW_GATE=approval||mode=off" \
  "REVIEW_GATE_MODE=off overrides review|gate|REVIEW_GATE_MODE=off PR_REVIEW_GATE=review||mode=off" \
  "REVIEW_GATE_MODE=enforce preserves the reviewer keys|gate|REVIEW_GATE_MODE=enforce PR_REVIEW_GATE=review||mode=review" \
  "a non-off REVIEW_GATE_MODE never narrows here|gate|REVIEW_GATE_MODE=bogus PR_REVIEW_GATE=review||mode=review" \
  "a settings-file REVIEW_GATE_MODE=off applies|gate||settings:REVIEW_GATE_MODE=off,PR_REVIEW_GATE=review|mode=off" \
  "a .env REVIEW_GATE_MODE=off is read by nothing|gate||dotenv:REVIEW_GATE_MODE=off|mode=approval" \
  "a .env PR_REVIEW_GATE is read by nothing either: the loader skips .env|gate||dotenv:PR_REVIEW_GATE=review|mode=approval" \
  "a parent-environment off still applies beside a dotenv file|gate|REVIEW_GATE_MODE=off|dotenv:REVIEW_GATE_MODE=off|mode=off" \
  "a settings-file off still applies beside a dotenv file|gate||settings:REVIEW_GATE_MODE=off;dotenv:REVIEW_GATE_MODE=off|mode=off" \
  "a .env.local REVIEW_GATE_MODE=off is ignored, the per-key exception|gate||dotenvlocal:REVIEW_GATE_MODE=off|mode=approval" \
  "control: a .env.local PR_REVIEW_GATE keeps full precedence|gate||dotenvlocal:PR_REVIEW_GATE=review|mode=review" \
  "REVIEW_GATE_SETTINGS_FILE=/dev/null forces the default over a settings-file off|gate|REVIEW_GATE_SETTINGS_FILE=/dev/null|settings:REVIEW_GATE_MODE=off|mode=approval" \
  "REVIEW_GATE_SETTINGS_FILE names another settings file|gate|REVIEW_GATE_SETTINGS_FILE=alt-settings.toml|alt:REVIEW_GATE_MODE=off|mode=off" \
  "a duplicate REVIEW_GATE_MODE assignment fails loud, naming the cause|gate||settings:REVIEW_GATE_MODE=off,REVIEW_GATE_MODE=enforce|rc=2 stderr~assigned+more+than+once=true" \
  "the fallback loader reads the committed settings file|nogate||settings:REVIEW_GATE_MODE=off|mode=off" \
  "the fallback ignores a machine-local .kendex off for the mode key too|nogate||kendex:REVIEW_GATE_MODE=off|mode=approval" \
  "a duplicate assignment fails the fallback loud, exit 1, and resolves no mode|nogate||settings:REVIEW_GATE_MODE=off,REVIEW_GATE_MODE=enforce|rc=1 stdout=empty stderr~assigned+more+than+once=true"

echo "=== the arg parser answers -h, --help and its own errors before gh ==="
# `label|args|expect`; the usage text carries the exit-code table, the
# proceeded status and the on-timeout setting the workflow quotes.
stage gate ""
for row in \
  "--help prints the contract on stdout, exits 0 and never invokes gh|--help|rc=0 stdout~Usage:+approval-wait=true stdout~Exit+codes:=true stdout~proceeded=true stdout~PR_REVIEW_ON_TIMEOUT=true gh=uncalled" \
  "-h prints usage|-h|rc=0 stdout~Usage:+approval-wait=true" \
  "a bare help prints usage|help|rc=0 stdout~Usage:+approval-wait=true" \
  "an unknown flag exits 2, is named, and never invokes gh|--bogus-flag|rc=2 stderr~unknown+option=true gh=uncalled" \
  "a missing PR# exits 2 and names the argument||rc=2 stderr~missing+required+<PR#>=true" \
  "--mode without a value exits 2 and names the requirement|1 --mode|rc=2 stderr~requires+a+value=true" \
  "--on-timeout without a value exits 2|1 --on-timeout|rc=2"; do
  IFS='|' read -r label args expect <<<"$row"
  [[ -n "$expect" ]] || { printf 'usage: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
  # shellcheck disable=SC2086
  run gate "" $args
  assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
done

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
