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
url= header= output=
while [ "$#" -gt 0 ]; do
  case "$1" in
    -fsSL) shift ;;
    -H) header="$2"; shift 2 ;;
    -o) output="$2"; shift 2 ;;
    https://*) url="$1"; shift ;;
    *) exit 2 ;;
  esac
done
printf '%s\n' "$url" >>"$CALLS"
printf '%s|%s|%s|%s\n' "$url" "$header" "${GITHUB_TOKEN-unset}" "${GH_TOKEN-unset}" >>"$TRANSPORT_LOG"
case "$url" in
  */releases/latest)
    printf '%s\n' "$RELEASE"
    [ "$FAIL_AT" != release ] || exit 22 ;;
  */commits/*)
    printf '%s\n' "$COMMIT"
    [ "$FAIL_AT" != commit ] || exit 22 ;;
  */install.sh)
    [ -n "$output" ]
    cat >"$output" <<'INSTALL'
printf '%s\n' "$*" >"$INSTALL_LOG"
printf '%s|%s\n' "${GITHUB_TOKEN-unset}" "${GH_TOKEN-unset}" >"$INSTALL_ENV"
exit "$INSTALL_RC"
INSTALL
    [ "$FAIL_AT" != installer ] || exit 22
    ;;
  *) exit 2 ;;
esac
CURL
chmod +x "$TMP/bin/curl"
cat >"$TMP/bin/git" <<'GIT'
#!/usr/bin/env bash
set -euo pipefail
[ "$1 $2" = 'ls-remote --tags' ] && [ "$#" -eq 3 ] || exit 2
printf '%s\n' "$3" >>"$CALLS"
printf '%s||%s|%s\n' "$3" "${GITHUB_TOKEN-unset}" "${GH_TOKEN-unset}" >>"$TRANSPORT_LOG"
printf '%b\n' "$TAGS"
[ "$FAIL_AT" != tags ] || exit 22
GIT
chmod +x "$TMP/bin/git"
installer="$SKILL_DIR/scripts/install-latest.sh"
while IFS='|' read -r name release commit fail_at install_rc expected key github_env gh_env authorization pin tags selected; do
  run_install_latest "$installer" "$release" "$commit" "$fail_at" "$install_rc" "$github_env" "$gh_env" "$pin" "$tags"
  if [ "$RC" = "$expected" ] && grep -qF -- "$key" <<<"$OUT"; then
    ok "$name"
  else
    bad "$name (exit=$RC)" "$OUT"
  fi
  if [ "$expected" = 0 ]; then
    version="$(jq -r .tag_name <<<"$release")" || { bad "$name: unreadable tag fixture"; continue; }
    version="${selected:-$version}"
    sha="$(jq -r .sha <<<"$commit")" || { bad "$name: unreadable commit fixture"; continue; }
    if install_latest_matches "$version" "$sha" "$authorization" "$pin"; then
      ok "$name: release selection, API authorization and installer isolation"
    else
      bad "$name: API transport, installer record or output differs"
    fi
  elif [ "$fail_at" != run ] && [ -e "$TMP/install-log" ]; then
    bad "$name: a failed dependency still executed the installer"
  fi
done <<'CASES'
no refresh caller uses latest release|{"tag_name":"v7.8.9","target_commitish":"main"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}||0|0|kendex-install: version=v7.8.9 commit=0123456789abcdef0123456789abcdef01234567
empty workflow token|{"tag_name":"v7.8.9"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}||0|0|kendex-install: version=v7.8.9|GITHUB_TOKEN=||
app token alone is ignored|{"tag_name":"v7.8.9"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}||0|0|kendex-install: version=v7.8.9||GH_TOKEN=fixture-app-token|
workflow token authorizes both API reads|{"tag_name":"v7.8.9"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}||0|0|kendex-install: version=v7.8.9|GITHUB_TOKEN=fixture-read-token||Authorization: Bearer fixture-read-token
workflow token wins over app token|{"tag_name":"v7.8.9"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}||0|0|kendex-install: version=v7.8.9|GITHUB_TOKEN=fixture-read-token|GH_TOKEN=fixture-app-token|Authorization: Bearer fixture-read-token
a later release|{"tag_name":"v7.8.10"}|{"sha":"abcdef0123456789abcdef0123456789abcdef01"}||0|0|kendex-install: version=v7.8.10 commit=abcdef0123456789abcdef0123456789abcdef01
release read fails|{"tag_name":"v7.8.9"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}|release|0|1|kendex-install: cause=release-read
release version missing|{}|{}||0|1|kendex-install: cause=release-version
release version malformed|{"tag_name":"../main"}|{}||0|1|kendex-install: cause=release-version
commit read fails|{"tag_name":"v7.8.9"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}|commit|0|1|kendex-install: cause=commit-read
commit SHA missing|{"tag_name":"v7.8.9"}|{}||0|1|kendex-install: cause=commit-sha
commit SHA malformed|{"tag_name":"v7.8.9"}|{"sha":"main"}||0|1|kendex-install: cause=commit-sha
installer read fails|{"tag_name":"v7.8.9"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}|installer|0|1|kendex-install: cause=installer-read
installer exits nonzero|{"tag_name":"v7.8.9"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}|run|3|1|kendex-install: cause=installer-run
caller before major tag moves|{"tag_name":"v1.16.0"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}||0|0|kendex-install: version=v1.15.0|GITHUB_TOKEN=fixture-read-token|GH_TOKEN=fixture-app-token|Authorization: Bearer fixture-read-token|v1|0123456789abcdef0123456789abcdef01234567 refs/tags/v1.15.0\nabcdef0123456789abcdef0123456789abcdef01 refs/tags/v1.16.0|v1.15.0
annotated stable tag with peeled commit first|{"tag_name":"v1.16.0"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}||0|0|kendex-install: version=v1.15.0||||v1|0123456789abcdef0123456789abcdef01234567 refs/tags/v1.15.0^{}\nabcdef0123456789abcdef0123456789abcdef01 refs/tags/v1.15.0|v1.15.0
annotated stable tag with object first|{"tag_name":"v1.16.0"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}||0|0|kendex-install: version=v1.15.0||||v1|abcdef0123456789abcdef0123456789abcdef01 refs/tags/v1.15.0\n0123456789abcdef0123456789abcdef01234567 refs/tags/v1.15.0^{}|v1.15.0
no stable tag on caller commit|{"tag_name":"v1.16.0"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}||0|1|kendex-install: cause=release-tags||||v1|0123456789abcdef0123456789abcdef01234567 refs/tags/v1.15.0-rc.1\n0123456789abcdef0123456789abcdef01234567 refs/tags/v2.15.0
multiple stable tags on caller commit|{"tag_name":"v1.16.0"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}||0|1|kendex-install: cause=release-tags||||v1|0123456789abcdef0123456789abcdef01234567 refs/tags/v1.15.0\n0123456789abcdef0123456789abcdef01234567 refs/tags/v1.15.1
caller tag read fails|{"tag_name":"v1.16.0"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}|tags|0|1|kendex-install: cause=tags-read||||v1|0123456789abcdef0123456789abcdef01234567 refs/tags/v1.15.0
caller needs major tag|{"tag_name":"v1.16.0"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}||0|1|kendex-install: cause=caller-ref||||main|
CASES

# Keep both selection branches but bypass the caller, as the base did.
sandbox
file_edit "$DIR" .agents/skills/review-gate/scripts/install-latest.sh 2 '^if \[ -e "\$caller" \]; then' \
  's/; then/ \&\& false; then/'
run_install_latest "$DIR/.agents/skills/review-gate/scripts/install-latest.sh" '{"tag_name":"v1.16.0"}' \
  '{"sha":"0123456789abcdef0123456789abcdef01234567"}' '' 0 '' '' v1 \
  '0123456789abcdef0123456789abcdef01234567 refs/tags/v1.15.0'
if [ "$RC" = 0 ] && [ "$(cat "$TMP/install-log")" = '--version v1.16.0 --cli-only' ] &&
    ! install_latest_matches v1.15.0 0123456789abcdef0123456789abcdef01234567 '' v1; then
  ok 'control: latest selects v1.16.0 and fails the caller-selected release assertion'
else
  bad 'control: the latest-release defect was not detected' "$OUT"
fi

# Preserve selection while bypassing one rule at a time.
while IFS='|' read -r name pin tags fail_at match edit; do
  sandbox
  file_edit "$DIR" .agents/skills/review-gate/scripts/install-latest.sh 1 "$match" "$edit"
  run_install_latest "$DIR/.agents/skills/review-gate/scripts/install-latest.sh" '{"tag_name":"v1.16.0"}' \
    '{"sha":"0123456789abcdef0123456789abcdef01234567"}' "$fail_at" 0 '' '' "$pin" "$tags"
  if [ "$RC" = 0 ]; then
    ok "control: bypassed $name fails its refusal row assertion"
  else
    bad "control: $name did not reach the incorrect success" "$OUT"
  fi
done <<'CALLER_CONTROLS'
major tag rule|main|0123456789abcdef0123456789abcdef01234567 refs/tags/v.15.0||^  \[\[ \$pin |s/\^v\[0-9\]+\$/^.*$/
tag transfer status|v1|0123456789abcdef0123456789abcdef01234567 refs/tags/v1.15.0|tags|^    fail tags-read |s/^    fail /    : fail /
exactly one stable tag|v1|0123456789abcdef0123456789abcdef01234567 refs/tags/v1.15.0\n0123456789abcdef0123456789abcdef01234567 refs/tags/v1.15.1||^      if \(count == 1\)|s/count == 1/count > 0/
matching major stable grammar|v1|0123456789abcdef0123456789abcdef01234567 refs/tags/v2.15.0||^      if \(name !~|s/if (name !~/if (0 \&\& name !~/
CALLER_CONTROLS

# Control: keep the install command text but pass a different version. The
# success row's installer arguments must detect this production defect.
sandbox
file_edit "$DIR" .agents/skills/review-gate/scripts/install-latest.sh 1 '^env .* sh .*--version "\$version" --cli-only' \
  's/--version "\$version"/--version latest/'
run_install_latest "$DIR/.agents/skills/review-gate/scripts/install-latest.sh" '{"tag_name":"v7.8.9"}' \
  '{"sha":"0123456789abcdef0123456789abcdef01234567"}' '' 0
if [ "$RC" = 0 ] && ! install_latest_matches v7.8.9 0123456789abcdef0123456789abcdef01234567 ''; then
  ok 'control: a changed installed version fails the success row assertion'
else
  bad 'control: installed-version mutation was not detected'
fi
# Each dependency status is its own refusal. Preserve its diagnostic text
# but make its fail call inert. A response followed by a failed transfer is
# still a failed read, even when its body happens to contain valid JSON.
while IFS='|' read -r key fail_at install_rc; do
  sandbox
  file_edit "$DIR" .agents/skills/review-gate/scripts/install-latest.sh 1 "^ *fail $key " \
    "s/^ *fail $key /  : fail $key /"
  run_install_latest "$DIR/.agents/skills/review-gate/scripts/install-latest.sh" '{"tag_name":"v7.8.9"}' \
    '{"sha":"0123456789abcdef0123456789abcdef01234567"}' "$fail_at" "$install_rc"
  if [ "$RC" = 0 ]; then
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
  run_install_latest "$DIR/.agents/skills/review-gate/scripts/install-latest.sh" "$release" "$commit" '' 0
  if [ "$RC" = 0 ]; then
    ok "control: bypassed $field grammar fails its malformed-response assertion"
  else
    bad "control: $field grammar did not reach the incorrect success" "$OUT"
  fi
done <<'GRAMMARS'
tag|{"tag_name":"../main"}|{"sha":"0123456789abcdef0123456789abcdef01234567"}|^  version=.*jq
commit|{"tag_name":"v7.8.9"}|{"sha":"main"}|^sha=
GRAMMARS
sandbox
file_edit "$DIR" .agents/skills/review-gate/scripts/install-latest.sh 1 '^  printf .*GITHUB_PATH' \
  's/^  printf /  : printf /'
run_install_latest "$DIR/.agents/skills/review-gate/scripts/install-latest.sh" '{"tag_name":"v7.8.9"}' \
  '{"sha":"0123456789abcdef0123456789abcdef01234567"}' '' 0
if [ "$RC" = 0 ] && ! install_latest_matches v7.8.9 0123456789abcdef0123456789abcdef01234567 ''; then
  ok 'control: an inert GitHub path write fails the success row assertion'
else
  bad 'control: GitHub path mutation was not detected'
fi

# The workflow token and the app token have different owners. These mutants
# retain the API/download/install commands but break one token boundary.
while IFS='|' read -r name github_env gh_env authorization match edit; do
  sandbox
  file_edit "$DIR" .agents/skills/review-gate/scripts/install-latest.sh 1 "$match" "$edit"
  run_install_latest "$DIR/.agents/skills/review-gate/scripts/install-latest.sh" '{"tag_name":"v7.8.9"}' \
    '{"sha":"0123456789abcdef0123456789abcdef01234567"}' '' 0 "$github_env" "$gh_env"
  if [ "$RC" = 0 ] && ! install_latest_matches v7.8.9 0123456789abcdef0123456789abcdef01234567 "$authorization"; then
    ok "control: $name fails the transport assertion"
  else
    bad "control: $name was not detected" "$OUT"
  fi
done <<'TOKEN_CONTROLS'
missing API authorization|GITHUB_TOKEN=fixture-read-token|GH_TOKEN=fixture-app-token|Authorization: Bearer fixture-read-token|^  if .*GITHUB_TOKEN|s/; then/ \&\& false; then/
empty token sends authorization|GITHUB_TOKEN=|||^  if .*GITHUB_TOKEN|s/-n /-z /
app token authorizes API reads|GITHUB_TOKEN=fixture-read-token|GH_TOKEN=fixture-app-token|Authorization: Bearer fixture-read-token|^    args\+=|s/\$GITHUB_TOKEN/\$GH_TOKEN/
authorization reaches raw download|GITHUB_TOKEN=fixture-read-token|GH_TOKEN=fixture-app-token|Authorization: Bearer fixture-read-token|^env .* curl .*raw.githubusercontent|s/curl -fsSL /curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" /
credentials reach raw download|GITHUB_TOKEN=fixture-read-token|GH_TOKEN=fixture-app-token|Authorization: Bearer fixture-read-token|^env .* curl .*raw.githubusercontent|s/env -u GH_TOKEN -u GITHUB_TOKEN /env /
workflow token reaches installer|GITHUB_TOKEN=fixture-read-token|GH_TOKEN=fixture-app-token|Authorization: Bearer fixture-read-token|^env .* sh |s/-u GITHUB_TOKEN //
app token reaches installer|GITHUB_TOKEN=fixture-read-token|GH_TOKEN=fixture-app-token|Authorization: Bearer fixture-read-token|^env .* sh |s/-u GH_TOKEN //
workflow token reaches logs|GITHUB_TOKEN=fixture-read-token|GH_TOKEN=fixture-app-token|Authorization: Bearer fixture-read-token|^printf .*version=%s|s/"\$version" "\$sha"/"$version" "$sha"; printf "%s" "$GITHUB_TOKEN"/
TOKEN_CONTROLS
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
