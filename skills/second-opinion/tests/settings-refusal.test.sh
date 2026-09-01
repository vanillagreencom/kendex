#!/usr/bin/env bash
# A settings file the loader refuses is a configuration error, never
# "undeclared": every second-opinion
# run aborts at the startup project-env load naming the defect. Emitting
# the undeclared refusal instead would send the operator hunting a
# declaration while the real fix is one line in the settings file. Sibling
# of review-dual-model.test.sh scenario 33c, split out at the
# settings-refusal seam — the startup abort needs none of that suite's
# harness-detection fixtures.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$TEST_DIR/../../.." && pwd)"
TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n' "$1"; }

# The declaration reaches the run only through the project settings file,
# exactly like scenario 33: the skill copy lives inside the project so the
# script's own root resolution finds the file under test.
proj="$TMP_ROOT/proj"
mkdir -p "$proj"
git -C "$proj" init -q
cp -R "$REPO_ROOT/skills/second-opinion" "$proj/second-opinion"
SO="$proj/second-opinion/scripts/second-opinion"

echo "=== a refused settings file fails the run as a config error ==="
for defect in header; do
  case "$defect" in
    header)
      printf '[env] # comment\nSECOND_OPINION_CURRENT_MODEL = "codex"\n' > "$proj/kendex.settings.toml"
      msg="unsupported table header shape"
      ;;
  esac
  rc=0
  env -u SECOND_OPINION_CURRENT_MODEL "$SO" detect >/dev/null 2>"$TMP_ROOT/err" || rc=$?
  [ "$rc" -eq 1 ] && ok "($defect) the run exits 1 at the startup settings load" \
    || fail "($defect) expected exit 1, got $rc: $(cat "$TMP_ROOT/err")"
  grep -q "$msg" "$TMP_ROOT/err" && ok "($defect) the failure names the settings defect" \
    || fail "($defect) stderr does not name the defect: $(cat "$TMP_ROOT/err")"
  # The marker proves SECOND-OPINION terminated on the refusal: without it,
  # the loader's own stderr plus detect's unrelated exit 1 satisfies every
  # other assertion even when the run tolerates the rejected load.
  grep -q "second-opinion: refusing to run on a rejected settings load" "$TMP_ROOT/err" \
    && ok "($defect) the run's own refusal marker is stated" \
    || fail "($defect) the refusal marker is missing: $(cat "$TMP_ROOT/err")"
  if grep -q "model undeclared" "$TMP_ROOT/err"; then
    fail "($defect) a refused file must not read as an undeclared session"
  else
    ok "($defect) not misreported as an undeclared session"
  fi
done

# SECOND_OPINION_FOREGROUND_CAP is a statement about ONE session, so a project
# file may not make it for every session in the repo. The refusal fires on the
# value that actually reaches the run: a project declaration the caller did not
# set. A caller who exports the key holds the higher-precedence value and the
# run is that caller's own, whatever a project file also says.
printf '[env]\nSECOND_OPINION_FOREGROUND_CAP = "1"\n' > "$proj/kendex.settings.toml"
rc=0
env -u SECOND_OPINION_FOREGROUND_CAP "$SO" detect >/dev/null 2>"$TMP_ROOT/err" || rc=$?
[ "$rc" -eq 1 ] && ok "(foreground-cap) a project declaration exits 1" \
  || fail "(foreground-cap) expected exit 1, got $rc: $(cat "$TMP_ROOT/err")"
grep -q "session-only SECOND_OPINION_FOREGROUND_CAP" "$TMP_ROOT/err" \
  && ok "(foreground-cap) the refusal names the session-only key" \
  || fail "(foreground-cap) refusal did not name the key: $(cat "$TMP_ROOT/err")"
grep -q "pass --foreground" "$TMP_ROOT/err" \
  && ok "(foreground-cap) the refusal names the supported flag" \
  || fail "(foreground-cap) refusal did not name --foreground: $(cat "$TMP_ROOT/err")"
rm -f "$proj/kendex.settings.toml"
printf 'export SAFE=1 SECOND_OPINION_FOREGROUND_CAP=1\n' > "$proj/.env.local"
rc=0
env -u SECOND_OPINION_FOREGROUND_CAP "$SO" detect >/dev/null 2>"$TMP_ROOT/err" || rc=$?
[ "$rc" -eq 1 ] && ok "(foreground-cap-env-file) an .env.local declaration exits 1" \
  || fail "(foreground-cap-env-file) expected exit 1, got $rc: $(cat "$TMP_ROOT/err")"
grep -q "session-only SECOND_OPINION_FOREGROUND_CAP" "$TMP_ROOT/err" \
  && ok "(foreground-cap-env-file) the refusal names the session-only key" \
  || fail "(foreground-cap-env-file) refusal did not name the key: $(cat "$TMP_ROOT/err")"

echo
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
