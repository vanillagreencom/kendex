# shellcheck shell=bash
# Consumer workflow fixtures use the shared sandbox and real API parser.
. "$TEST_DIR/lib/sandbox.sh"
. "$TEST_DIR/lib/workflow-edit.sh"
# Refresh settings reporting uses the optional installed orch parser.
cp -R "$SKILL_DIR/../orch" "$PRISTINE/.agents/skills/orch"
BIN="$TMP/bin"
FIXTURES="$TMP/github"
mkdir -p "$BIN" "$FIXTURES"
cp "$TEST_DIR/lib/gh-shim.sh" "$BIN/gh"
chmod +x "$BIN/gh"
printf '{"full_name":"acme/widgets","default_branch":"main"}\n' >"$FIXTURES/repository.json"
printf '{"environments":[{"name":"kendex","deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}]}\n' >"$FIXTURES/environments.json"
printf '{"branch_policies":[{"name":"main","type":"branch"}]}\n' >"$FIXTURES/branch-policies.json"
printf '{"secrets":[{"name":"FLEET_GH_APP_ID"},{"name":"FLEET_GH_APP_PRIVATE_KEY"}]}\n' >"$FIXTURES/environment-secrets-kendex.json"

# run_refresh_command ROOT SCRIPT [ARGS...] keeps host credentials outside the
# child and reports through the sandbox's OUT and RC contract.
run_refresh_command() {
  local root="$1" script="$2"
  shift 2
  RC=0
  OUT="$(cd "$root" && env -i PATH="$BIN:/usr/bin:/bin" HOME="$TMP" \
    GH_SHIM_FIXTURES="$FIXTURES" GH_SHIM_FAIL="${SHIM_FAIL:-}" \
    "$script" "$@" 2>&1)" || RC=$?
}

# The rolling refresh runner uses real git and isolates all service inputs.
run_refresh() { # CONTENT VERIFY CLASS
  local result=0
  rm -f -- "${TMP:?}/state/auth"
  OUT="$(cd "$repo" && env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GH_TOKEN=test-token GITHUB_TOKEN=other-test-token TEST_SECRET=private-test-value GH_REPO=acme/test REFRESH_APP_SLUG=lanes TEST_STATE="$TMP/state" TEST_REAL_GIT="$REAL_GIT" TEST_CONTENT="$1" TEST_VERIFY="$2" TEST_CLASS="$3" TEST_MEASURED="${MEASURED:-true}" TEST_REASON="${CLASS_REASON:-cause=renders-match-their-sources}" TEST_CLASS_EXIT="${CLASS_EXIT:-0}" TEST_HOSTILE="${HOSTILE:-}" TEST_FRESH_ORCH="${FRESH_ORCH:-}" TEST_ORCH_MODE="${ORCH_MODE:-keep}" TEST_REFRESH_SKILL="${REFRESH_SKILL:-}" TEST_FRESH_TEMPLATES="$TMP/fresh-templates" TEST_GH_SHIM="$TMP/standard-gh" GH_SHIM_FIXTURES="$FIXTURES" bash "$runner" 2>&1)" || result=$?
  RC="$result"
}

reset_default() {
  git -C "$repo" reset --hard -q
  git -C "$repo" clean -fdq
  git -C "$repo" checkout -q main
}

# Assert the runner's publication record, body data and arm decision together.
refresh_class_matches() { # CLASS STATE ARM REASON METHOD
  [ "$RC" -eq 0 ] &&
    grep -qxF -- "refresh-state=$2 pr=1 class=$1" <<<"$OUT" &&
    grep -qxF -- "class: class=$1 measured=true $4" "$TMP/state/body" &&
    grep -qF -- "api --method $5 repos/acme/test/pulls" "$TMP/state/calls" &&
    if [ "$3" = yes ]; then [ -f "$TMP/state/armed" ]; else [ ! -f "$TMP/state/armed" ]; fi
}

refresh_stopped_at_class() { # REMOTE_HEAD
  local after
  after="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)" || return 1
  [ "$RC" -eq 1 ] && [ "$after" = "$1" ] &&
    grep -qxF 'refresh-error=read value=class' <<<"$OUT" &&
    ! grep -qE '^api --method (POST|PATCH)|^pr merge ' "$TMP/state/calls"
}

# Settings failures stop both rolling-branch publication and merge changes.
refresh_stopped_at_settings() { # REMOTE_HEAD ERROR_RECORD
  local after
  after="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)" || return 1
  [ "$RC" -ne 0 ] && [ "$after" = "$1" ] &&
    grep -qxF -- "$2" <<<"$OUT" &&
    ! grep -qE '^api --method (POST|PATCH)|^pr merge ' "$TMP/state/calls"
}

# Seed the inventory shape core refresh and adoption use.
record_adoption() { # ROOT PATH TEMPLATE
  python3 - "$@" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
path, template = sys.argv[2:]
inventory = root / ".kendex-generated.json"
entries = json.loads(inventory.read_text())
entries.append({"path": path, "template": template, "templateHash": "sha256:" + hashlib.sha256((root / path).read_bytes()).hexdigest()})
inventory.write_text(json.dumps(entries) + "\n")
PY
}

# The committed writer and record are independent expected values for both
# automatic preservation and explicit trusted retirement.
retirement_matches() { # ROOT PATH TEMPLATE preserved|removed
  [ "$RC" -eq 0 ] || return 1
  python3 - "$@" <<'PY'
import json
from pathlib import Path
import subprocess
import sys
root = Path(sys.argv[1])
path, owner, disposition = sys.argv[2:]
before = json.loads(subprocess.check_output(["git", "show", "HEAD:.kendex-generated.json"], cwd=root, text=True))
expected = [e for e in before if isinstance(e, dict) and e["template"] == owner]
assert len(expected) == 1 and expected[0]["path"] == path
after = json.loads((root / ".kendex-generated.json").read_text())
actual = [e for e in after if isinstance(e, dict) and e["template"] == owner]
if disposition == "preserved":
    assert actual == expected
    assert (root / path).read_bytes() == subprocess.check_output(["git", "show", "HEAD:" + path], cwd=root)
elif disposition == "removed":
    assert actual == [] and not (root / path).exists()
else:
    raise AssertionError("unknown retirement disposition: " + disposition)
PY
}

adoption_metadata() { # ROOT PATH TEMPLATE
  python3 - "$@" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
path, template = sys.argv[2:]
data = (root / template).read_bytes()
assert (root / path).read_bytes() == data
assert json.loads((root / ".kendex-generated.json").read_text()) == [{"path": path, "template": template, "templateHash": "sha256:" + hashlib.sha256(data).hexdigest()}]
PY
}

# kendex refresh updates the inventory's hash before workflow adoption.
record_template_hash() {
  python3 - "$DIR" "$TEMPLATE" "$REFRESH" <<'PY'
import hashlib
import json
from pathlib import Path
import sys
root = Path(sys.argv[1])
path = root / ".kendex-generated.json"
entries = json.loads(path.read_text())
record = next(e for e in entries if isinstance(e, dict) and e["path"] == sys.argv[3])
record["templateHash"] = "sha256:" + hashlib.sha256((root / sys.argv[2]).read_bytes()).hexdigest()
path.write_text(json.dumps(entries) + "\n")
PY
}

# The diagnostic count and the PATH:LINE report token are adoption's output
# contract. Prose surrounding the token is not part of the assertion.
workflow_edit_matches() { # REPORT PATH:LINE
  local count
  count="$(grep -c '^refresh-warning=workflow-edited value=' <<<"$OUT")" || return 1
  [ "$RC" -eq 0 ] && [ "$count" -eq 1 ] &&
    grep -qxF "refresh-warning=workflow-edited value=${2%:*}" <<<"$OUT" &&
    grep -qF -- "\`$2\`" "$1"
}

# Each row owns its local catalog, HOME, edit and install record.
real_refresh_fixture() { # NAME
  sandbox
  repo="$DIR"
  real_root="$TMP/real-$1"
  mkdir -p "$real_root/home/.claude" "$real_root/git/owner/catalog/skills/probe" "$repo/.claude"
  printf '%s\n' '---' 'name: probe' 'description: fixture skill' '---' 'Upstream content.' >"$real_root/git/owner/catalog/skills/probe/SKILL.md"
  git -C "$real_root/git/owner/catalog" init -q -b main
  git -C "$real_root/git/owner/catalog" config gc.auto 0
  git -C "$real_root/git/owner/catalog" config maintenance.auto false
  git -C "$real_root/git/owner/catalog" config user.name fixture
  git -C "$real_root/git/owner/catalog" config user.email fixture@example.invalid
  git -C "$real_root/git/owner/catalog" add -A
  git -C "$real_root/git/owner/catalog" commit -qm fixture
  printf 'schema = 6\n[sources.cat]\nrepo = "owner/catalog"\n[install]\nharnesses = ["claude"]\nmethod = "symlink"\n[skills.probe]\nsource = "cat"\n' >"$repo/kendex.toml"
  (cd -- "$repo" && env -i PATH="$PATH" HOME="$real_root/home" KENDEX_REAL_HOME=1 \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    KENDEX_GIT_BASE="file://$real_root/git" KENDEX_UI=plain "$REAL_KENDEX" refresh --scope project --yes --leave)
  git -C "$repo" branch -M main
  git -C "$repo" config gc.auto 0
  git -C "$repo" config maintenance.auto false
  git -C "$repo" config user.name fixture
  git -C "$repo" config user.email fixture@example.invalid
  cp "$TMP/case.1/.agents/skills/harness-ci/scripts/change-class" "$repo/.agents/skills/harness-ci/scripts/change-class"
  printf '#!/usr/bin/env bash\nset -euo pipefail\n: >"$4"\n' >"$repo/.agents/skills/review-gate/scripts/adopt-refresh.sh"
  printf 'Hand edit.\n' >>"$repo/.agents/skills/probe/SKILL.md"
}

publish_real_fixture() {
  commit "$repo"
  git init --bare -q "$real_root/remote"
  git --git-dir="$real_root/remote" config gc.auto 0
  git --git-dir="$real_root/remote" config maintenance.auto false
  git -C "$repo" remote add origin "$real_root/remote"
  git -C "$repo" push -q origin main
  runner="$repo/.agents/skills/review-gate/scripts/refresh-consumer.sh"
  : >"$TMP/state/pr"
  : >"$TMP/state/creates"
  : >"$TMP/state/calls"
  : >"$TMP/state/kendex"
  rm -f -- "$TMP/state/body"
}

run_real_refresh() {
  RC=0
  OUT="$(cd -- "$repo" && env -i PATH="$TMP/bin:$PATH" HOME="$real_root/home" \
    GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    GH_TOKEN=test-token GH_REPO=acme/test REFRESH_APP_SLUG=lanes TEST_STATE="$TMP/state" \
    TEST_REAL_GIT="$REAL_GIT" TEST_REAL_KENDEX="$REAL_KENDEX" TEST_KENDEX_OUTPUT="${KENDEX_OUTPUT:-normal}" \
    TEST_GH_SHIM="$TMP/standard-gh" GH_SHIM_FIXTURES="$FIXTURES" \
    TEST_CLASS=render TEST_MEASURED=true TEST_CLASS_EXIT=0 TEST_REASON=cause=renders-match-their-sources \
    KENDEX_REAL_HOME=1 KENDEX_GIT_BASE="file://$real_root/git" KENDEX_UI=plain bash "$runner" 2>&1)" || RC=$?
}

real_refresh_published() {
  [ "$RC" -eq 0 ] &&
    grep -qxF 'refresh --scope project --yes --leave' "$TMP/state/kendex" &&
    grep -qxF 'refresh --scope project --yes --leave --discard-edits' "$TMP/state/kendex" &&
    grep -qxF 'verify --scope project' "$TMP/state/kendex" &&
    grep -qxF 'refresh-state=pushed pr=1 class=render' <<<"$OUT" &&
    [ -s "$TMP/state/creates" ] &&
    while IFS= read -r hold; do
      grep -qxF -- "- $hold" "$TMP/state/body" || return 1
    done <<<"$expected_holds" &&
    while IFS= read -r edited; do
      [ -s "$repo/$edited" ] && ! grep -qF 'Hand edit.' "$repo/$edited" || return 1
    done <<<"$expected_edits"
}

real_refresh_stopped() { # ERROR_RECORD_PREFIX
  [ "$RC" -ne 0 ] && grep -qF -- "$1" <<<"$OUT" &&
    ! grep -qF -- '--discard-edits' "$TMP/state/kendex" &&
    ! grep -qF 'verify ' "$TMP/state/kendex" &&
    [ ! -s "$TMP/state/creates" ] &&
    ! git --git-dir="$real_root/remote" show-ref --verify --quiet refs/heads/kendex/refresh
}
