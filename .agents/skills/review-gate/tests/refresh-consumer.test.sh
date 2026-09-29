#!/usr/bin/env bash
# Drives the actual consumer runner with real local git repositories. Only
# the external kendex/classifier and GitHub services are replaced.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf -- "$TMP"' EXIT
. "$TEST_DIR/lib/refresh-fixture.sh"
cp "$BIN/gh" "$TMP/standard-gh"
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state"
cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_STATE/calls"
case "$*" in
  'api repos/acme/test --jq .default_branch') printf 'main\n' ;;
  api\ --paginate\ *pulls*) cat "$TEST_STATE/pr" ;;
  api\ users/*) printf '123\n' ;;
  'api --method POST repos/acme/test/pulls '*) printf '1\n' >"$TEST_STATE/pr"; printf 'created\n' >>"$TEST_STATE/creates"; printf '1\n' ;;
  'auth setup-git') : >"$TEST_STATE/auth" ;;
  'pr merge '*|'pr close '*) ;;
  *) exec "$TEST_GH_SHIM" "$@" ;;
esac
SH
cat >"$TMP/bin/kendex" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_STATE/kendex"
case "$1" in
  refresh)
    printf '%s\n' "$TEST_CONTENT" >rendered.txt
    if [ -n "${TEST_HOSTILE:-}" ]; then
      cp "$TEST_FRESH_TEMPLATES/"*.yml .agents/skills/review-gate/templates/
      for path in adopt-refresh.sh validate-standard.sh validate-workflow.sh lib/diagnostics.sh lib/settings.sh lib/standard.sh; do
        printf '#!/usr/bin/env bash\nprintf "executed=%%s\\n" "$0" >>"$TEST_STATE/hostile"\nexit 89\n' >".agents/skills/review-gate/scripts/$path"
      done
    fi
    ;;
  verify) [ "$TEST_VERIFY" = pass ] ;;
  *) exit 2 ;;
esac
SH
cat >"$TMP/bin/git" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
# A private repository's fetch fails until the app credential is installed.
if [ "${1:-}" = fetch ] && [ ! -f "$TEST_STATE/auth" ]; then exit 88; fi
exec "$TEST_REAL_GIT" "$@"
SH
REAL_GIT="$(command -v git)"
chmod +x "$TMP/bin/gh" "$TMP/bin/kendex" "$TMP/bin/git"

sandbox
repo="$DIR"
git -C "$repo" branch -M main
git -C "$repo" config gc.auto 0
mkdir -p "$repo/.agents/skills/harness-ci/scripts"
cat >"$repo/.agents/skills/harness-ci/scripts/change-class" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_STATE/classifier"
printf 'change_class=%s\n' "$TEST_CLASS"
SH
printf '#!/usr/bin/env bash\nset -euo pipefail\n' >"$repo/.agents/skills/review-gate/scripts/adopt-refresh.sh"
chmod +x "$repo/.agents/skills/harness-ci/scripts/change-class"
chmod +x "$repo/.agents/skills/review-gate/scripts/adopt-refresh.sh"
printf 'current\n' >"$repo/rendered.txt"
commit "$repo"
git init --bare -q "$TMP/remote"
git --git-dir="$TMP/remote" config gc.auto 0
git --git-dir="$TMP/remote" config maintenance.auto false
git -C "$repo" remote add origin "$TMP/remote"
git -C "$repo" push -q origin main
: >"$TMP/state/pr"
: >"$TMP/state/creates"
runner="$repo/.agents/skills/review-gate/scripts/refresh-consumer.sh"

run_refresh() { # CONTENT VERIFY CLASS
  local result=0
  rm -f -- "${TMP:?}/state/auth"
  OUT="$(cd "$repo" && env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" TMPDIR="$TMP" GH_TOKEN=test-token GH_REPO=acme/test REFRESH_APP_SLUG=lanes TEST_STATE="$TMP/state" TEST_REAL_GIT="$REAL_GIT" TEST_CONTENT="$1" TEST_VERIFY="$2" TEST_CLASS="$3" TEST_HOSTILE="${HOSTILE:-}" TEST_FRESH_TEMPLATES="$TMP/fresh-templates" TEST_GH_SHIM="$TMP/standard-gh" GH_SHIM_FIXTURES="$FIXTURES" bash "$runner" 2>&1)" || result=$?
  RC="$result"
}
reset_default() {
  git -C "$repo" reset --hard -q
  git -C "$repo" checkout -q main
}
run_refresh current pass render
if [ "$RC" -eq 0 ] && [ ! -s "$TMP/state/creates" ]; then ok 'current consumer opens no pull request'; else bad 'current consumer opens no pull request' "$OUT"; fi
reset_default
run_refresh stale pass render
first="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)"
if [ "$RC" -eq 0 ] && [ "$(wc -l <"$TMP/state/creates" | tr -d ' ')" -eq 1 ]; then ok 'stale consumer opens one rolling pull request'; else bad 'stale consumer opens one rolling pull request' "$OUT"; fi
reset_default
run_refresh stale pass render
second="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)"
if [ "$RC" -eq 0 ] && [ "$first" = "$second" ] && [ "$(wc -l <"$TMP/state/creates" | tr -d ' ')" -eq 1 ]; then ok 'repeat keeps one pull request and its commit'; else bad 'repeat keeps one pull request and its commit' "$OUT"; fi
for row in 'bad-verify|fail|render' 'unowned|pass|standard'; do
  IFS='|' read -r content verify class <<<"$row"
  reset_default
  run_refresh "$content" "$verify" "$class"
  after="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)"
  if [ "$RC" -ne 0 ] && [ "$after" = "$first" ]; then ok "$content refuses before push"; else bad "$content refuses before push" "$OUT"; fi
done
# One production mutation proves the rolling-PR count assertion observes
# the runner's create decision, rather than merely the fake API's state.
reset_default
python3 - "$runner" <<'PY'
from pathlib import Path
import sys
p = Path(sys.argv[1])
s = p.read_text()
old = 'if [ -z "$pr" ]; then'
assert s.count(old) == 1
p.write_text(s.replace(old, 'if true; then'))
PY
git -C "$repo" add -A
git -C "$repo" commit -qm 'mutate create decision'
git -C "$repo" push -q origin main
run_refresh stale pass render
if [ "$RC" -eq 0 ] && [ "$(wc -l <"$TMP/state/creates" | tr -d ' ')" -gt 1 ]; then ok 'control exposes duplicate pull creation'; else bad 'control exposes duplicate pull creation' "$OUT"; fi
# The shipped workflow preserves a trusted checkout before refresh replaces
# catalog files. Real adoption must read new template bytes without executing
# any refreshed script or shell library, including for a renamed writer.
sandbox
repo="$DIR"
git -C "$repo" branch -M main
git -C "$repo" mv .github/workflows/review-gate-writer.yml .github/workflows/gate.yml
printf '[]\n' >"$repo/.kendex-generated.json"
printf 'current\n' >"$repo/rendered.txt"
cp "$TMP/case.1/.agents/skills/harness-ci/scripts/change-class" "$repo/.agents/skills/harness-ci/scripts/change-class"
commit "$repo"
git init --bare -q "$TMP/secure-remote"
git --git-dir="$TMP/secure-remote" config gc.auto 0
git --git-dir="$TMP/secure-remote" config maintenance.auto false
git -C "$repo" remote add origin "$TMP/secure-remote"
git -C "$repo" push -q origin main
git -C "$repo" worktree add --detach "$TMP/trusted" HEAD
runner="$TMP/trusted/.agents/skills/review-gate/scripts/refresh-consumer.sh"
cp -R "$repo/.agents/skills/review-gate/templates" "$TMP/fresh-templates"
file_edit "$TMP/fresh-templates" review-gate-writer.yml 1 '^    timeout-minutes: 15$' \
  's/^    timeout-minutes: 15$/    timeout-minutes: 16/'
printf '\n# fresh refresh template\n' >>"$TMP/fresh-templates/kendex-refresh.yml"
: >"$TMP/state/pr"
: >"$TMP/state/creates"
HOSTILE=1
run_refresh refreshed pass render
if [ "$RC" -eq 0 ] && [ ! -e "$TMP/state/hostile" ] &&
    cmp -s "$repo/.github/workflows/gate.yml" "$TMP/fresh-templates/review-gate-writer.yml" &&
    cmp -s "$repo/.github/workflows/kendex-refresh.yml" "$TMP/fresh-templates/kendex-refresh.yml" &&
    python3 - "$repo" <<'INVENTORY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]); entries=json.loads((root/'.kendex-generated.json').read_text())
assert {e['path'] for e in entries}=={'.github/workflows/gate.yml','.github/workflows/kendex-refresh.yml'}
for entry in entries:
 assert entry['templateHash']=='sha256:'+hashlib.sha256((root/entry['path']).read_bytes()).hexdigest()
 assert (root/entry['path']).read_bytes()==(root/entry['template']).read_bytes()
INVENTORY
then ok 'trusted adoption reads fresh templates and records a renamed writer without executing refreshed code'
else bad 'trusted adoption boundary and fresh data' "$OUT"; fi
# Restoring execution from the refreshed checkout must reach the hostile
# script before verification, even when that script retains the expected name.
python3 - "$runner" <<'TRUST_CONTROL'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); needle='"$SCRIPT_DIR/adopt-refresh.sh" --templates-dir "$ROOT/.agents/skills/review-gate/templates"'
assert s.count(needle)==1
replacement='.agents/skills/review-gate/scripts/adopt-refresh.sh --templates-dir "$ROOT/.agents/skills/review-gate/templates" # '+needle
p.write_text(s.replace(needle,replacement))
TRUST_CONTROL
reset_default
run_refresh refreshed pass render
if [ "$RC" -eq 89 ] && [ -s "$TMP/state/hostile" ]; then
  ok 'control: refreshed adoption code executes when the trusted path is removed'
else bad 'trusted adoption control' "$OUT"; fi
# A repository with no review gate runs the whole refresh with no writer: the
# trusted adoption records only the refresh copy and the pull request opens.
# HOSTILE stays set, so the refreshed scripts must still never execute.
sandbox
repo="$DIR"
git -C "$repo" branch -M main
rm -- "${repo:?}/.github/workflows/review-gate-writer.yml"
settings "$repo" REVIEW_GATE_WRITER optional
settings "$repo" REVIEW_GATE_MODE off
printf '[]\n' >"$repo/.kendex-generated.json"
printf 'current\n' >"$repo/rendered.txt"
cp "$TMP/case.1/.agents/skills/harness-ci/scripts/change-class" "$repo/.agents/skills/harness-ci/scripts/change-class"
commit "$repo"
git init --bare -q "$TMP/no-writer-remote"
git --git-dir="$TMP/no-writer-remote" config gc.auto 0
git --git-dir="$TMP/no-writer-remote" config maintenance.auto false
git -C "$repo" remote add origin "$TMP/no-writer-remote"
git -C "$repo" push -q origin main
git -C "$repo" worktree add --detach "$TMP/no-writer-trusted" HEAD
runner="$TMP/no-writer-trusted/.agents/skills/review-gate/scripts/refresh-consumer.sh"
: >"$TMP/state/pr"
: >"$TMP/state/creates"
rm -f -- "${TMP:?}/state/hostile"
run_refresh refreshed pass render
if [ "$RC" -eq 0 ] && [ ! -e "$TMP/state/hostile" ] && [ "$(wc -l <"$TMP/state/creates" | tr -d ' ')" -eq 1 ] &&
    [ ! -e "$repo/.github/workflows/review-gate-writer.yml" ] &&
    cmp -s "$repo/.github/workflows/kendex-refresh.yml" "$TMP/fresh-templates/kendex-refresh.yml" &&
    jq -e '[.[] | objects | .path] == [".github/workflows/kendex-refresh.yml"]' "$repo/.kendex-generated.json" >/dev/null; then
  ok 'no-writer refresh adopts the refresh workflow and opens its pull request'
else bad 'no-writer refresh' "$OUT"; fi
printf 'pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
