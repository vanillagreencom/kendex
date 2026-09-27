#!/usr/bin/env bash
# Dispatch reads the installation's repositories and sends consumer events.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
. "$TEST_DIR/lib/refresh-fixture.sh"
DISPATCH='.agents/skills/review-gate/scripts/dispatch-refresh.sh'
printf '{"repositories":[{"full_name":"vanillagreencom/kendex","archived":false},{"full_name":"acme/first","archived":false},{"full_name":"acme/retired","archived":true}]}\n' >"$FIXTURES/installation-repositories.json"
printf '{"repositories":[{"full_name":"acme/last","archived":false}]}\n' >"$FIXTURES/installation-repositories.page2.json"
EXPECTED='POST repos/acme/first/dispatches event_type=kendex-refresh
POST repos/acme/last/dispatches event_type=kendex-refresh'
sandbox
run_refresh_command "$DIR" "$DIR/$DISPATCH"
if [ "$RC" -eq 0 ] && [ "$(cat "$FIXTURES/.writes.log")" = "$EXPECTED" ]; then
  ok 'dispatch reaches every active repository across pages and excludes archived repositories'
else
  bad "repository dispatch (rc=$RC)" "$OUT"
fi

# The same complete write listing is the oracle for both selection controls.
for mutation in pagination archived-filter self-exclusion; do
  sandbox
  rm -f -- "${FIXTURES:?}/.writes.log"
  case "$mutation" in
    self-exclusion) file_edit "$DIR" "$DISPATCH" 1 'if \[ "\$repository" = vanillagreencom/kendex \]; then' 's/if \[ "\$repository" = vanillagreencom\/kendex \]; then/if false; then/' ;;
    pagination) file_edit "$DIR" "$DISPATCH" 1 'gh api --paginate installation/repositories' 's/gh api --paginate installation/gh api installation/' ;;
    archived-filter) file_edit "$DIR" "$DISPATCH" 1 'select\(\.archived == false\)' 's/select(\.archived == false)/select(true)/' ;;
  esac
  chmod +x "$DIR/$DISPATCH"
  run_refresh_command "$DIR" "$DIR/$DISPATCH"
  if [ "$RC" -eq 0 ] && [ -s "$FIXTURES/.writes.log" ] && [ "$(cat "$FIXTURES/.writes.log")" != "$EXPECTED" ]; then
    ok "control: $mutation defect changes dispatched repositories"
  else
    bad "control: $mutation did not break repository selection (rc=$RC)" "$OUT"
  fi
done

sandbox
for failure in installation-repositories POST:dispatches; do
  rm -f -- "${FIXTURES:?}/.writes.log"
  SHIM_FAIL="$failure"
  run_refresh_command "$DIR" "$DIR/$DISPATCH"
  if [ "$failure" = installation-repositories ]; then
    expected='gh-shim-error=api value=installation-repositories'
  else
    expected='refresh-error=dispatch value=acme/last'
  fi
  if [ "$RC" -eq 1 ] && grep -qxF "$expected" <<<"$OUT" && [ ! -e "$FIXTURES/.writes.log" ]; then
    ok "$failure propagates failure without a successful dispatch"
  else
    bad "$failure (rc=$RC)" "$OUT"
  fi
done
SHIM_FAIL=''

# A failed dispatch must stay a failed run after all repositories are tried.
file_edit "$DIR" "$DISPATCH" 1 '^    failed=1$' 's/^    failed=1$/    failed=0/'
chmod +x "$DIR/$DISPATCH"
SHIM_FAIL='POST:dispatches'
run_refresh_command "$DIR" "$DIR/$DISPATCH"
if [ "$RC" -eq 0 ] && grep -qxF 'refresh-error=dispatch value=acme/last' <<<"$OUT"; then
  ok 'control: lost failure status makes failed dispatches pass'
else
  bad "control: dispatch failure status (rc=$RC)" "$OUT"
fi
SHIM_FAIL=''

sandbox
printf '{"repositories":[]}\n' >"$FIXTURES/installation-repositories.json"
printf '{"repositories":[]}\n' >"$FIXTURES/installation-repositories.page2.json"
rm -f -- "${FIXTURES:?}/.writes.log"
run_refresh_command "$DIR" "$DIR/$DISPATCH"
if [ "$RC" -eq 1 ] && grep -qxF 'refresh-error=installation-empty value=0' <<<"$OUT" && [ ! -e "$FIXTURES/.writes.log" ]; then
  ok 'an empty installation list fails before dispatch'
else
  bad "empty installation (rc=$RC)" "$OUT"
fi

file_edit "$DIR" "$DISPATCH" 1 '^\[ -n "\$repositories" \] \|\|' 's/^\[ -n "\$repositories" \]/[ -z "$repositories" ]/'
chmod +x "$DIR/$DISPATCH"
run_refresh_command "$DIR" "$DIR/$DISPATCH"
if [ "$RC" -eq 0 ] && [ -s "$FIXTURES/.writes.log" ]; then ok 'control: disabled empty-list guard attempts an empty dispatch'; else bad "control: empty installation (rc=$RC)" "$OUT"; fi

printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
