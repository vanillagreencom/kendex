#!/usr/bin/env bash
# LINEAR_CACHE_ROOT named the local store's root. With the store gone, the
# setting is refused wherever it is set, even empty: every command exits 1
# before any request, its first stderr line `linear-setting:
# retired=LINEAR_CACHE_ROOT`.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)" || exit 1
source "$SCRIPT_DIR/lib/assert.sh"
SKILL_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd -P)" || exit 1
assert_tmpdir TMP_ROOT
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || exit 1

mkdir -p "$TMP_ROOT/.agents/skills" "$TMP_ROOT/bin"
git -C "$TMP_ROOT" init -q -b main
cp -R "$SKILL_DIR" "$TMP_ROOT/.agents/skills/linear"
cat >"$TMP_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'called\n' >>"$CALLS"
printf '%s' '{"data":{"viewer":{"id":"v","name":"n"}}}___HTTP_CODE___200'
STUB
chmod +x "$TMP_ROOT/bin/curl"

# label|where the setting is: none, env, settings or envfile|value|outcome
while IFS='|' read -r label where value want; do
    rm -f -- "${TMP_ROOT:?}/kendex.settings.toml" "${TMP_ROOT:?}/.env.local"
    : >"$TMP_ROOT/calls"
    extra=()
    case "$where" in
    env) extra=(LINEAR_CACHE_ROOT="$value") ;;
    settings) printf '[env]\nLINEAR_CACHE_ROOT = "%s"\n' "$value" >"$TMP_ROOT/kendex.settings.toml" ;;
    envfile) printf 'LINEAR_CACHE_ROOT="%s"\n' "$value" >"$TMP_ROOT/.env.local" ;;
    none) ;;
    esac
    rc=0
    (cd -- "$TMP_ROOT" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" CALLS="$TMP_ROOT/calls" \
        LINEAR_API_KEY_OVERRIDE=test-key ${extra[@]+"${extra[@]}"} \
        bash .agents/skills/linear/scripts/linear.sh users me >/dev/null 2>"$TMP_ROOT/err") || rc=$?
    if [[ "$want" == refused ]]; then
        assert_eq "$label: refuses" "$rc" 1
        assert_eq "$label: names the retired setting" "$(head -n 1 "$TMP_ROOT/err")" 'linear-setting: retired=LINEAR_CACHE_ROOT'
        assert_not "$label: sends no request" test -s "$TMP_ROOT/calls"
    else
        assert_eq "$label: runs" "$rc" 0
    fi
done <<'ROWS'
unset|none||runs
environment, valued|env|/tmp/linear-root|refused
environment, empty|env||refused
kendex.settings.toml|settings|/tmp/linear-root|refused
.env.local|envfile|/tmp/linear-root|refused
ROWS
