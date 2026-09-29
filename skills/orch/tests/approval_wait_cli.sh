#!/usr/bin/env bash
# approval-wait's argument surface: the parser's own answers (-h, --help, an
# unknown flag, a missing value, a mode it does not have, a missing PR#)
# before anything reaches gh. One run and one comparison per row: `observe`
# reads exactly the fields the row's expect names. --resolve-mode's answers
# over a PR's base rules are approval_wait.sh, which has the fake GitHub.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
# shellcheck source=lib/assertions.sh
source "$TEST_DIR/lib/assertions.sh"
TMP_ROOT="$(mktemp -d)"
TMP_ROOT="$(cd "$TMP_ROOT" && pwd -P)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# One project with orch beside github, and a gh that records every call and
# fails.
mkdir -p "$TMP_ROOT/project/.agents/skills" "$TMP_ROOT/bin"
ln -s "$REPO_ROOT/skills/orch" "$TMP_ROOT/project/.agents/skills/orch"
ln -s "$REPO_ROOT/skills/github" "$TMP_ROOT/project/.agents/skills/github"
git -C "$TMP_ROOT/project" init -q
GH_CALLS="$TMP_ROOT/gh.calls"
printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >> %s\nexit 1\n' "$GH_CALLS" > "$TMP_ROOT/bin/gh"
chmod +x "$TMP_ROOT/bin/gh"

# run ARGS... — one approval-wait run in the project. OUT, RC and ERR (a file)
# are what `observe` reads. The gh call log is emptied first.
RUN_SEQ=0
run() {
  ERR="$TMP_ROOT/run-$((++RUN_SEQ)).err"
  rm -f -- "${GH_CALLS:?}"
  set +e
  OUT="$(cd "$TMP_ROOT/project" && PATH="$TMP_ROOT/bin:$PATH" .agents/skills/orch/scripts/approval-wait "$@" 2>"$ERR")"
  RC=$?
  set -e
}

# observe EXPECT — prints the run's value of every `name=` field EXPECT names,
# in EXPECT's order (`+` reads as a space in a needle, so a literal plus cannot
# be pinned; no field carries one):
#   rc              exit status
#   stdout          `empty` when nothing was printed, else `lines`
#   stdout_line     the first stdout line, spaces encoded as +
#   stderr_line     the first stable diagnostic record, spaces encoded as +
#   gh              `called` when the gh stub was reached, else `uncalled`
observe() {
  local got="" token name value
  set -f
  for token in $1; do
    name="${token%%=*}"
    case "$name" in
      rc) value="$RC" ;;
      stdout) value="$([[ -n "$OUT" ]] && echo lines || echo empty)" ;;
      stdout_line) value="${OUT%%$'\n'*}"; value="${value// /+}" ;;
      stderr_line)
        value="$(awk '/^approval-wait: [a-z-]+ .*=/ { print; exit }' "$ERR")"
        value="${value// /+}"
        ;;
      gh) value="$([[ -s "$GH_CALLS" ]] && echo called || echo uncalled)" ;;
      *) echo "observe: unknown field $name" >&2; exit 1 ;;
    esac
    got="$got $name=$value"
  done
  set +f
  printf '%s' "${got# }"
}

echo "=== the arg parser answers -h, --help and its own errors before gh ==="
# `label|args|expect`; keys identify the usage response and parser refusals.
for row in \
  "--help prints the contract on stdout, exits 0 and never invokes gh|--help|rc=0 stdout_line=approval-wait:+usage+command=approval-wait gh=uncalled" \
  "-h prints usage|-h|rc=0 stdout_line=approval-wait:+usage+command=approval-wait" \
  "a bare help prints usage|help|rc=0 stdout_line=approval-wait:+usage+command=approval-wait" \
  "an unknown flag exits 2, is named, and never invokes gh|--bogus-flag|rc=2 stderr_line=approval-wait:+unknown-option+option=--bogus-flag gh=uncalled" \
  "a missing PR# exits 2 and names the argument||rc=2 stderr_line=approval-wait:+missing-pr+operand=PR gh=uncalled" \
  "--resolve-mode without a PR# exits 2 and never invokes gh|--resolve-mode|rc=2 stdout=empty stderr_line=approval-wait:+missing-pr+operand=PR gh=uncalled" \
  "--mode without a value exits 2 and names the requirement|1 --mode|rc=2 stderr_line=approval-wait:+missing-mode+option=--mode" \
  "a mode other than approval exits 2 and never invokes gh|1 --mode review|rc=2 stderr_line=approval-wait:+invalid-mode+value=review gh=uncalled" \
  "--item without a value exits 2 and names the option|1 --item|rc=2 stderr_line=approval-wait:+missing-item+option=--item" \
  "--on-timeout without a value exits 2|1 --on-timeout|rc=2 stderr_line=approval-wait:+missing-timeout+option=--on-timeout"; do
  IFS='|' read -r label args expect <<<"$row"
  [[ -n "$expect" ]] || { printf 'usage: a row with no expect asserts nothing: %s\n' "$row" >&2; exit 1; }
  # shellcheck disable=SC2086
  run $args
  assert_eq "$(observe "$expect")" "$expect" "$label" "$ERR"
done

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
