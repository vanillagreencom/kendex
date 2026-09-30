#!/usr/bin/env bash
# Run the shared installer against release/commit API fixtures and a recording
# installer. The real jq judges API payloads; curl is the network boundary.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)" || { echo 'install-latest-test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP && ! -L $TMP ]] || { echo "install-latest-test: scratch=not-a-directory value=[$TMP]" >&2; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)" || { echo 'install-latest-test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT
. "$TEST_DIR/lib/sandbox.sh"
. "$TEST_DIR/lib/workflow-edit.sh"
mkdir -p "$TMP/bin"
cat >"$TMP/bin/curl" <<'CURL'
#!/usr/bin/env bash
set -euo pipefail
url="$2"
printf '%s\n' "$url" >>"$CALLS"
case "$url" in
  */releases/latest)
    printf '%s\n' "$RELEASE"
    [ "$FAIL_AT" != release ] || exit 22 ;;
  */commits/*)
    printf '%s\n' "$COMMIT"
    [ "$FAIL_AT" != commit ] || exit 22 ;;
  */install.sh)
    [ "$3" = -o ]
    cat >"$4" <<'INSTALL'
printf '%s\n' "$*" >"$INSTALL_LOG"
exit "$INSTALL_RC"
INSTALL
    [ "$FAIL_AT" != installer ] || exit 22
    ;;
  *) exit 2 ;;
esac
CURL
chmod +x "$TMP/bin/curl"
installer="$SKILL_DIR/scripts/install-latest.sh"
while IFS='|' read -r name release commit fail_at install_rc expected key; do
  : >"$TMP/calls"
  : >"$TMP/github-path"
  rm -f "$TMP/install-log"
  rc=0
  out="$(env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP" \
    CALLS="$TMP/calls" INSTALL_LOG="$TMP/install-log" GITHUB_PATH="$TMP/github-path" RELEASE="$release" COMMIT="$commit" \
    FAIL_AT="$fail_at" INSTALL_RC="$install_rc" bash "$installer" 2>&1)" || rc=$?
  if [ "$rc" = "$expected" ] && grep -qF -- "$key" <<<"$out"; then
    ok "$name"
  else
    bad "$name (exit=$rc)" "$out"
  fi
  if [ "$expected" = 0 ]; then
    version="$(jq -r .tag_name <<<"$release")"
    sha="$(jq -r .sha <<<"$commit")"
    expected_calls="https://api.github.com/repos/vanillagreencom/kendex/releases/latest
https://api.github.com/repos/vanillagreencom/kendex/commits/$version
https://raw.githubusercontent.com/vanillagreencom/kendex/$sha/install.sh"
    if [ "$(cat "$TMP/calls")" = "$expected_calls" ] && [ "$(cat "$TMP/install-log")" = "--version $version --cli-only" ] && [ "$(cat "$TMP/github-path")" = "$TMP/.local/bin" ]; then
      ok "$name: the selected tag and resolved installer commit travel together"
    else
      bad "$name: release selection did not reach the installer"
    fi
  elif [ "$fail_at" != run ] && [ -e "$TMP/install-log" ]; then
    bad "$name: a failed dependency still executed the installer"
  fi
done <<'CASES'
latest release|{"tag_name":"v7.8.9","target_commitish":"main"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}||0|0|kendex-install: version=v7.8.9 commit=0123456789abcdef0123456789abcdef01234567
a later release|{"tag_name":"v7.8.10"}|{"sha":"abcdef0123456789abcdef0123456789abcdef01"}||0|0|kendex-install: version=v7.8.10 commit=abcdef0123456789abcdef0123456789abcdef01
release read fails|{"tag_name":"v7.8.9"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}|release|0|1|kendex-install: cause=release-read
release version missing|{}|{}||0|1|kendex-install: cause=release-version
release version malformed|{"tag_name":"../main"}|{}||0|1|kendex-install: cause=release-version
commit read fails|{"tag_name":"v7.8.9"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}|commit|0|1|kendex-install: cause=commit-read
commit SHA missing|{"tag_name":"v7.8.9"}|{}||0|1|kendex-install: cause=commit-sha
commit SHA malformed|{"tag_name":"v7.8.9"}|{"sha":"main"}||0|1|kendex-install: cause=commit-sha
installer read fails|{"tag_name":"v7.8.9"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}|installer|0|1|kendex-install: cause=installer-read
installer exits nonzero|{"tag_name":"v7.8.9"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}|run|3|1|kendex-install: cause=installer-run
CASES

# Control: keep the install command text but pass a different version. The
# success row's installer arguments must detect this production defect.
sandbox
file_edit "$DIR" .agents/skills/review-gate/scripts/install-latest.sh 1 '^sh .*--version "\$version" --cli-only' \
  's/--version "\$version"/--version latest/'
: >"$TMP/calls"
rc=0
env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP" \
  CALLS="$TMP/calls" INSTALL_LOG="$TMP/install-log" RELEASE='{"tag_name":"v7.8.9"}' \
  COMMIT='{"sha":"0123456789abcdef0123456789abcdef01234567"}' FAIL_AT= INSTALL_RC=0 \
  bash "$DIR/.agents/skills/review-gate/scripts/install-latest.sh" >"$TMP/control-out" 2>&1 || rc=$?
if [ "$rc" = 0 ] && [ "$(cat "$TMP/install-log")" != '--version v7.8.9 --cli-only' ]; then
  ok 'control: a changed installed version fails the success row assertion'
else
  bad 'control: installed-version mutation was not detected'
fi
# Each dependency status is its own refusal. Preserve its diagnostic text
# but make its fail call inert. A response followed by a failed transfer is
# still a failed read, even when its body happens to contain valid JSON.
while IFS='|' read -r key fail_at install_rc; do
  sandbox
  file_edit "$DIR" .agents/skills/review-gate/scripts/install-latest.sh 1 "^  fail $key " \
    "s/^  fail $key /  : fail $key /"
  rc=0
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP" \
    CALLS="$TMP/calls" INSTALL_LOG="$TMP/install-log" RELEASE='{"tag_name":"v7.8.9"}' \
    COMMIT='{"sha":"0123456789abcdef0123456789abcdef01234567"}' FAIL_AT="$fail_at" INSTALL_RC="$install_rc" \
    bash "$DIR/.agents/skills/review-gate/scripts/install-latest.sh" >"$TMP/control-out" 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then
    ok "control: inert $key refusal fails its dependency row assertion"
  else
    bad "control: $key did not reach the incorrect success"
  fi
done <<'CONTROLS'
release-read|release|0
commit-read|commit|0
installer-read|installer|0
installer-run|run|3
CONTROLS

# The producer's tag and SHA grammar are two independent rules. Keep their
# select expressions but bypass each condition on one invalid response.
while IFS='|' read -r field release commit match; do
  sandbox
  file_edit "$DIR" .agents/skills/review-gate/scripts/install-latest.sh 1 "$match" \
    's/select(type ==/select(true or type ==/'
  rc=0
  env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP" \
    CALLS="$TMP/calls" INSTALL_LOG="$TMP/install-log" RELEASE="$release" COMMIT="$commit" FAIL_AT= INSTALL_RC=0 \
    bash "$DIR/.agents/skills/review-gate/scripts/install-latest.sh" >"$TMP/control-out" 2>&1 || rc=$?
  if [ "$rc" = 0 ]; then
    ok "control: bypassed $field grammar fails its malformed-response assertion"
  else
    bad "control: $field grammar did not reach the incorrect success" "$(cat "$TMP/control-out")"
  fi
done <<'GRAMMARS'
tag|{"tag_name":"../main"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}|^version=
commit|{"tag_name":"v7.8.9"}|{"sha":"main"}|^sha=
GRAMMARS
sandbox
file_edit "$DIR" .agents/skills/review-gate/scripts/install-latest.sh 1 '^  printf .*GITHUB_PATH' \
  's/^  printf /  : printf /'
: >"$TMP/github-path"
rc=0
env -i PATH="$TMP/bin:/usr/bin:/bin" HOME="$TMP" TMPDIR="$TMP" \
  CALLS="$TMP/calls" INSTALL_LOG="$TMP/install-log" GITHUB_PATH="$TMP/github-path" RELEASE='{"tag_name":"v7.8.9"}' \
  COMMIT='{"sha":"0123456789abcdef0123456789abcdef01234567"}' FAIL_AT= INSTALL_RC=0 \
  bash "$DIR/.agents/skills/review-gate/scripts/install-latest.sh" >"$TMP/control-out" 2>&1 || rc=$?
if [ "$rc" = 0 ] && [ ! -s "$TMP/github-path" ]; then
  ok 'control: an inert GitHub path write fails the success row assertion'
else
  bad 'control: GitHub path mutation was not detected'
fi
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
