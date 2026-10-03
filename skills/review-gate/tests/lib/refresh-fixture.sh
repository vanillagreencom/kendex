# shellcheck shell=bash
# Consumer workflow fixtures use the shared sandbox and real API parser.
. "$TEST_DIR/lib/sandbox.sh"
. "$TEST_DIR/lib/workflow-edit.sh"
# Shipment history is a data-only catalog. Only the transport in disposable
# adopter copies changes; production has no fixture setting or acceptance path.
CATALOG="$TMP/catalog"
mkdir -p "$CATALOG/skills/review-gate/templates"
git -C "$CATALOG" init -q -b main
git -C "$CATALOG" config gc.auto 0
git -C "$CATALOG" config maintenance.auto false
git -C "$CATALOG" config user.name fixture
git -C "$CATALOG" config user.email fixture@example.invalid
git -C "$SKILL_DIR" show f7db7e89:skills/review-gate/templates/kendex-refresh.yml >"$TMP/shipped-historical"
cp "$TMP/shipped-historical" "$CATALOG/skills/review-gate/templates/kendex-refresh.yml"
commit "$CATALOG"
cp "$SKILL_DIR/templates/kendex-refresh.yml" "$CATALOG/skills/review-gate/templates/kendex-refresh.yml"
commit "$CATALOG"

trust_refresh_transport() { # DISPOSABLE_ROOT
  python3 - "$1/.agents/skills/review-gate/scripts/adopt-refresh.sh" "$CATALOG" <<'TRANSPORT'
from pathlib import Path
import sys
p = Path(sys.argv[1]).resolve(); text = p.read_text()
old = 'https://github.com/vanillagreencom/kendex.git'
assert text.count(old) == 1
changed = text.replace(old, sys.argv[2])
assert changed != text
p.write_text(changed)
TRANSPORT
}
trust_refresh_transport "$PRISTINE"

ship_refresh_template() { # TEMPLATE_FILE
  cp "$1" "$CATALOG/skills/review-gate/templates/kendex-refresh.yml"
  commit "$CATALOG"
}

snapshot_adoption() {
  cp "$DIR/.kendex-generated.json" "$TMP/adoption-inventory"
  cp "$DIR/.github/workflows/review-gate-writer.yml" "$TMP/adoption-writer"
  cp "$DIR/.github/workflows/kendex-refresh.yml" "$TMP/adoption-workflow"
}

adoption_preserved() { # EXACT_ERROR_RECORD
  [ "$RC" -ne 0 ] && grep -qxF -- "$1" <<<"$OUT" &&
    cmp -s "$TMP/adoption-inventory" "$DIR/.kendex-generated.json" &&
    cmp -s "$TMP/adoption-writer" "$DIR/.github/workflows/review-gate-writer.yml" &&
    cmp -s "$TMP/adoption-workflow" "$DIR/.github/workflows/kendex-refresh.yml" &&
    ! grep -qE '^(ok|FAIL|note) check=workflow-' <<<"$OUT"
}

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
  rm -f -- "${TMP:?}/state/auth" "$TMP/state/push-refused" "$TMP/state/disable-refused"
  : >"$TMP/state/summary"
  OUT="$(cd "$repo" && env -i PATH="$TMP/bin:$PATH" HOME="$TMP/home" GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GH_TOKEN=test-token GITHUB_TOKEN=other-test-token GITHUB_STEP_SUMMARY="$TMP/state/summary" TEST_VERSION_EXIT="${VERSION_EXIT:-0}" TEST_SECRET=private-test-value GH_REPO=acme/test REFRESH_APP_SLUG=lanes TEST_STATE="$TMP/state" TEST_REAL_GIT="$REAL_GIT" TEST_CONTENT="$1" TEST_VERIFY="$2" TEST_CLASS="$3" TEST_MEASURED="${MEASURED:-true}" TEST_REASON="${CLASS_REASON:-cause=renders-match-their-sources}" TEST_CLASS_EXIT="${CLASS_EXIT:-0}" TEST_LEASE_RACE="${LEASE_RACE:-}" TEST_PUSH_MODE="${PUSH_MODE:-normal}" TEST_PUSH_QUERY="${PUSH_QUERY:-pass}" TEST_DISABLE_MODE="${DISABLE_MODE:-normal}" TEST_LEASE_REMOTE="$TMP/remote" TEST_HOSTILE="${HOSTILE:-}" TEST_FRESH_ORCH="${FRESH_ORCH:-}" TEST_ORCH_MODE="${ORCH_MODE:-keep}" TEST_REFRESH_SKILL="${REFRESH_SKILL:-}" TEST_FRESH_TEMPLATES="$TMP/fresh-templates" TEST_GH_SHIM="$TMP/standard-gh" GH_SHIM_FIXTURES="$FIXTURES" bash "$runner" 2>&1)" || result=$?
  RC="$result"
}

# The acceptance assertion also holds ordering and no publication after refusal.
refresh_push_matches() { # EXIT REASON
  local deferred_count
  [ "$RC" -eq "$1" ] || return 1
  if [ "$1" -eq 0 ]; then
    deferred_count="$(grep -c '^refresh-state=deferred ' <<<"$OUT")" || return 1
    [ "$deferred_count" -eq 1 ] || return 1
    grep -qxF "refresh-state=deferred reason=$2" <<<"$OUT" || return 1
  else
    case "$2" in
      active) grep -qxF 'refresh-error=push value=73' <<<"$OUT" || return 1 ;;
      query|output) grep -qxF "refresh-error=push-state value=$2" <<<"$OUT" || return 1 ;;
      *) return 1 ;;
    esac
    if grep -q '^refresh-state=deferred ' <<<"$OUT"; then return 1; fi
  fi
  awk '
    /^git push$/ { pushes++; pushed = 1 }
    /^api graphql / { queries++; if (!pushed) exit 1 }
    END { if (pushes != 1 || queries != 1) exit 1 }
  ' "$TMP/state/calls" || return 1
  ! grep -qE '^api --method (POST|PATCH)|^pr merge .*--auto' "$TMP/state/calls"
}

# A refused disable reads the lifecycle once, after the refusal, and leaves
# the branch and the pull request alone.
refresh_disable_matches() { # EXIT REASON
  local deferred_count
  [ "$RC" -eq "$1" ] || return 1
  if [ "$1" -eq 0 ]; then
    deferred_count="$(grep -c '^refresh-state=deferred ' <<<"$OUT")" || return 1
    [ "$deferred_count" -eq 1 ] || return 1
    grep -qxF "refresh-state=deferred reason=$2" <<<"$OUT" || return 1
  else
    case "$2" in queued | merged | closed) return 1 ;; esac
    grep -qxF 'refresh-error=disable value=1' <<<"$OUT" || return 1
    if grep -q '^refresh-state=deferred ' <<<"$OUT"; then return 1; fi
  fi
  awk '
    /^pr merge .* --disable-auto$/ { disables++; disabled = 1 }
    /^api graphql / { queries++; if (!disabled) exit 1 }
    /^git push$/ { exit 1 }
    END { if (disables != 1 || queries != 1) exit 1 }
  ' "$TMP/state/calls" || return 1
  ! grep -qE '^api --method (POST|PATCH)|^pr merge .*--auto' "$TMP/state/calls"
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
  printf '#!/usr/bin/env bash\nset -euo pipefail\n: >"$TEST_STATE/adopted"\n' >"$repo/.agents/skills/review-gate/scripts/adopt-refresh.sh"
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
  rm -f -- "$TMP/state/body" "$TMP/state/adopted"
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

real_refresh_preserved() { # DISTINCT_ITEM_COUNT
  real_refresh_stopped "refresh-error=render-edited value=$1" &&
    [ ! -e "$TMP/state/adopted" ] &&
    while IFS= read -r hold; do
      grep -qxF -- "- $hold" <<<"$OUT" || return 1
    done <<<"$expected_holds" &&
    while IFS= read -r edited; do
      cmp -s "$real_root/before/$edited" "$repo/$edited" || return 1
    done <<<"$expected_edits"
}

real_refresh_stopped() { # ERROR_RECORD_PREFIX
  [ "$RC" -ne 0 ] && grep -qF -- "$1" <<<"$OUT" &&
    ! grep -qF -- '--discard-edits' "$TMP/state/kendex" &&
    ! grep -qF 'verify ' "$TMP/state/kendex" &&
    [ ! -s "$TMP/state/creates" ] &&
    ! git --git-dir="$real_root/remote" show-ref --verify --quiet refs/heads/kendex/refresh
}
