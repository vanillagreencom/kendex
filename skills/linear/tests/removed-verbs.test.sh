#!/usr/bin/env bash
# The sync and cache verbs are gone with the local store. Each spelling exits
# nonzero before any request, prints nothing on stdout, and names on one
# stderr line, `linear: removed=VERB replacement=...`, the live command that
# reads what the cache verb read (`none` for sync): a whole-set store list
# takes --max, and a store cycle type its live name.
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
# Any request is a defect here: the refusal comes first.
cat >"$TMP_ROOT/bin/curl" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
printf 'called\n' >>"$CALLS"
exit 1
STUB
chmod +x "$TMP_ROOT/bin/curl"

# label|args|the stderr line's key fields
while IFS='|' read -r label args key; do
    : >"$TMP_ROOT/calls"
    rc=0
    # shellcheck disable=SC2086  # args is one command line of plain words
    out=$(cd -- "$TMP_ROOT" && env -i PATH="$TMP_ROOT/bin:$PATH" HOME="$TMP_ROOT" CALLS="$TMP_ROOT/calls" \
        LINEAR_API_KEY_OVERRIDE=test-key bash .agents/skills/linear/scripts/linear.sh $args 2>"$TMP_ROOT/err") || rc=$?
    assert_eq "$label: exits 1" "$rc" 1
    assert_eq "$label: prints nothing on stdout" "$out" ''
    assert_eq "$label: one stderr line" "$(wc -l <"$TMP_ROOT/err" | tr -d ' ')" 1
    assert_eq "$label: names the live command" "$(cut -d: -f1-2 <"$TMP_ROOT/err")" "$key"
    assert_not "$label: sends no request" test -s "$TMP_ROOT/calls"
    assert_not "$label: writes no local store" test -e "$TMP_ROOT/.cache"
done <<'ROWS'
sync|sync|linear: removed=sync replacement=none
sync --reconcile|sync --reconcile|linear: removed=sync replacement=none
sync --if-stale|sync --if-stale 15|linear: removed=sync replacement=none
cache issues get|cache issues get KEN-1 --with-bundle|linear: removed=cache replacement=linear.sh issues get KEN-1 --with-bundle
cache comments bulk-list|cache comments bulk-list KEN-1 KEN-2|linear: removed=cache replacement=linear.sh comments bulk-list KEN-1 KEN-2
cache status|cache status|linear: removed=cache replacement=linear.sh auth-check
cache labels list|cache labels list --format=safe|linear: removed=cache replacement=linear.sh labels list --format=safe --max
cache projects list --limit|cache projects list --limit 5|linear: removed=cache replacement=linear.sh projects list --limit 5
cache cycles list --type past|cache cycles list --type past|linear: removed=cache replacement=linear.sh cycles list --type previous
cache cycles list --type upcoming|cache cycles list --type upcoming|linear: removed=cache replacement=linear.sh cycles list --type next
cache issues list-comments|cache issues list-comments KEN-1|linear: removed=cache replacement=linear.sh comments list KEN-1
bare cache|cache|linear: removed=cache replacement=linear.sh <resource> <action>
ROWS
