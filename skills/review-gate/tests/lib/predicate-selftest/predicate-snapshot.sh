# shellcheck shell=bash
# Caller snapshots must be a single object bound to this head. A valid
# snapshot replaces the statuses read; malformed endpoint pages also refuse.
# name|body|contexts|publisher reject|source|override|verdict|exit
rows="$(cat <<EOF
snapshot replaces read|{"sha":"$HEAD","statuses":[{"context":"mech-ctx","state":"success","description":"analysis complete","created_at":"2026-01-01T00:00:00Z","creator":{"login":"trusted-publisher"}}]}|mech-ctx|ACTIVE|snapshot-skip||approved|0
unreadable snapshot||ACTIVE|ACTIVE|missing|||2
malformed snapshot|not json|ACTIVE|ACTIVE|snapshot|||2
array snapshot|[]|ACTIVE|ACTIVE|snapshot|||2
empty snapshot||ACTIVE|ACTIVE|snapshot|||2
snapshot for other head|{"sha":"$OTHER","statuses":[{"context":"mech-ctx","state":"success","description":"analysis complete","creator":{"login":"trusted-publisher"}}]}|mech-ctx|ACTIVE|snapshot|||2
unbound snapshot|{"statuses":[{"context":"mech-ctx","state":"success","description":"analysis complete","creator":{"login":"trusted-publisher"}}]}|mech-ctx|ACTIVE|snapshot|||2
concatenated snapshot pages|{"sha":"$HEAD","statuses":[{"context":"mech-ctx","state":"success","description":"analysis complete","creator":{"login":"trusted-publisher"}}]} {"sha":"$HEAD","statuses":[]}|mech-ctx|ACTIVE|snapshot|||2
concatenated snapshots without contexts|{"sha":"$HEAD","statuses":[]} {"sha":"$HEAD","statuses":[]}||ACTIVE|snapshot|mech-outage||2
object status page|{}|ACTIVE|ACTIVE|statuses|||2
combined endpoint page|{"statuses":[]}|ACTIVE|ACTIVE|statuses|||2
whitespace status page|\n   \n|ACTIVE|ACTIVE|statuses|||2
non-array snapshot statuses|{"sha":"$HEAD","statuses":{}}|mech-ctx|ACTIVE|snapshot|||2
null creator with filter|{"sha":"$HEAD","statuses":[{"context":"mech-ctx","state":"success","description":"analysis complete","created_at":"2026-01-01T00:00:00Z","creator":null}]}|mech-ctx|github-actions[bot]|snapshot|||2
null creator without filter|{"sha":"$HEAD","statuses":[{"context":"mech-ctx","state":"success","description":"analysis complete","created_at":"2026-01-01T00:00:00Z","creator":null}]}|mech-ctx||snapshot-skip||approved|0
object creator login|{"sha":"$HEAD","statuses":[{"context":"mech-ctx","state":"success","description":"analysis complete","created_at":"2026-01-01T00:00:00Z","creator":{"login":{}}}]}|mech-ctx|github-actions[bot]|snapshot|||2
malformed later status page|{}|mech-ctx|ACTIVE|page2|||2
EOF
)" || exit 1
while IFS='|' read -r name body contexts reject source override want expected_exit; do
  reset
  [ "$contexts" = ACTIVE ] || CFG_CONTEXTS="$contexts"
  [ "$reject" = ACTIVE ] || CFG_PUBLISHER_REJECT="$reject"
  [ -z "$override" ] || CFG_OUTAGE="$override"
  case "$source" in
    snapshot|snapshot-skip)
      CFG_SNAPSHOT="$work/snapshot.json"
      printf '%b\n' "$body" >"$CFG_SNAPSHOT"
      # Empty means zero bytes, not jq's whitespace-only input shape.
      [ -n "$body" ] || : >"$CFG_SNAPSHOT"
      [ "$source" != snapshot-skip ] || export GH_SHIM_FAIL=statuses
      ;;
    missing) CFG_SNAPSHOT="$work/no-such-snapshot.json" ;;
    statuses) printf '%b\n' "$body" >"$fixtures/statuses.json" ;;
    page2)
      status_ctx mech-ctx success 'analysis complete'
      printf '%s\n' "$body" >"$fixtures/statuses.page2.json"
      ;;
    *) exit 1 ;;
  esac
  run "$name" "$want" "$expected_exit"
  if [ "$expected_exit" = 2 ]; then
    case "$source" in
      statuses|page2) code=predicate-statuses-pages; value="$HEAD" ;;
      *) code=predicate-status-snapshot; value="$CFG_SNAPSHOT" ;;
    esac
    printf -v quoted '%q' "$value"
    if ! grep -qxF "review-gate-error=$code value=$quoted" <<<"$LAST_ERROR"; then
      echo "FAIL  $name: expected $code value=$quoted" >&2
      failures=$((failures + 1))
    fi
  fi
done <<<"$rows"
