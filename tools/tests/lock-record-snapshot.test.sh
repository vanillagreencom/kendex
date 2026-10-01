#!/usr/bin/env bash
# Snapshot mode reuses lock-record's real local Git publication and API parser.
set -euo pipefail
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
TEST_DIR="$ROOT/skills/review-gate/tests"
SKILL_DIR="$ROOT/skills/review-gate"
TMP="$(mktemp -d)" || { echo 'lock-record-snapshot-test: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP && ! -L $TMP ]] || { echo "lock-record-snapshot-test: scratch=not-a-directory value=[$TMP]" >&2; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)" || { echo 'lock-record-snapshot-test: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
. "$TEST_DIR/lib/refresh-fixture.sh"
sandbox
repo="$DIR"
git -C "$repo" branch -M main
git -C "$repo" config core.hooksPath /dev/null
printf 'original lock\n' >"$repo/.kendex-lock.json"
commit "$repo"
git init -q --bare "$TMP/remote"
git --git-dir="$TMP/remote" config gc.auto 0
git --git-dir="$TMP/remote" config maintenance.auto false
git -C "$repo" remote add origin "$TMP/remote"
git -C "$repo" push -q origin main
mkdir -p "$TMP/publish-bin"
cat >"$TMP/publish-bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$PUB_CALLS"
case "$*" in
  'pr list '*)
    [ "${PUB_FAIL:-}" != list ] || exit 9
    if [ -f "$PUB_PR" ]; then printf '1 PR_fixture\n'; fi ;;
  'pr create '*) : >"$PUB_PR"; printf 'https://github.com/acme/widgets/pull/1\n' ;;
  'pr view '*) git --git-dir="$PUB_REMOTE" rev-parse refs/heads/kendex/consumer-snapshots ;;
  'pr merge '* | 'pr edit '*) : ;;
  *) exec "$PUB_API" "$@" ;;
esac
SH
# Snapshot publication must never invoke the lock's refresh/verify commands.
cat >"$TMP/publish-bin/kendex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf 'unexpected-kendex=%s\n' "$*" >&2
exit 87
SH
chmod +x "$TMP/publish-bin/"*
printf '[]\n' >"$FIXTURES/rules.json"
printf '{"allow_squash_merge":true,"allow_merge_commit":false,"allow_rebase_merge":false}\n' >"$FIXTURES/repository.json"
printf '{"data":{"node":{"autoMergeRequest":null,"isInMergeQueue":false}}}\n' >"$FIXTURES/graphql.json"
printf 'first snapshot\n' >"$TMP/input.gz"
publish() {
  RC=0
  OUT="$(env -i PATH="$TMP/publish-bin:$PATH" HOME="$TMP" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GIT_AUTHOR_NAME=fixture GIT_AUTHOR_EMAIL=fixture@example.invalid \
    GIT_COMMITTER_NAME=fixture GIT_COMMITTER_EMAIL=fixture@example.invalid \
    GH_TOKEN=publish-fixture GH_SHIM_FIXTURES="$FIXTURES" PUB_CALLS="$TMP/calls" PUB_PR="$TMP/pr" \
    PUB_REPO="$repo" PUB_REMOTE="$TMP/remote" PUB_API="$BIN/gh" PUB_FAIL="${PUB_FAIL:-}" \
    bash "${PUBLISHER:-$ROOT/tools/lock-record}" --repo "$repo" --base main \
    --branch kendex/consumer-snapshots --snapshot "$TMP/input.gz" 2>&1)" || RC=$?
}
publish
if [ "$RC" -eq 0 ] && cmp -s "$TMP/input.gz" "$repo/.github/consumer-snapshots.json.gz" &&
  grep -qF 'pr merge 1 --squash --auto --match-head-commit ' "$TMP/calls" &&
  [ "$(cat "$repo/.kendex-lock.json")" = 'original lock' ]; then
  ok 'snapshot uses the rolling PR owner and never refreshes the lock'
else bad 'snapshot publication' "$OUT"; fi
git -C "$repo" checkout -q main
publish
if [ "$RC" -eq 0 ] && grep -qF 'lock-record: rolling-current=' <<<"$OUT"; then ok 'identical rolling snapshot is reused'; else bad 'rolling snapshot reuse' "$OUT"; fi
printf 'second snapshot\n' >"$TMP/input.gz"
publish
if [ "$RC" -eq 0 ] && cmp -s "$TMP/input.gz" "$repo/.github/consumer-snapshots.json.gz"; then ok 'changed snapshot updates the rolling branch'; else bad 'snapshot update' "$OUT"; fi
git -C "$repo" checkout -q main
PUB_FAIL=list publish
if [ "$RC" -eq 1 ] && grep -qxF 'lock-record: pull-request-list=kendex/consumer-snapshots' <<<"$OUT"; then ok 'control: failed platform read blocks publication'; else bad 'platform read refusal' "$OUT"; fi
# Keep the byte-compare line visible but disable the decision it owns.
python3 - "$ROOT/tools/lock-record" "$TMP/mutant" <<'PY'
from pathlib import Path
import sys
text = Path(sys.argv[1]).read_text()
old = '[[ -f "$repo/$snapshot_path" ]] && cmp -s -- "$snapshot" "$repo/$snapshot_path"'
assert text.count(old) == 1
changed = text.replace(old, '# ' + old + '\n    [[ -f "$repo/$snapshot_path" ]] && true')
assert changed != text
# Preserve the production libraries when a disposable script moves directories.
old_here = 'here="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"'
assert changed.count(old_here) == 1
changed = changed.replace(old_here, 'here=' + repr(str(Path(sys.argv[1]).resolve().parent)))
Path(sys.argv[2]).write_text(changed)
PY
printf 'third snapshot\n' >"$TMP/input.gz"
PUBLISHER="$TMP/mutant" publish
if [ "$RC" -eq 0 ] && [ ! -f "$repo/.github/consumer-snapshots.json.gz" ]; then
  ok 'control: disabled compare turns the changed-snapshot assertion red'
else bad 'snapshot equality mutant' "$OUT"; fi
printf '\nlock-record-snapshot-test: pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
