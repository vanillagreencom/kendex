#!/usr/bin/env bash
# Exercise consumer adoption and its declared environment checks.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REFRESH_DIR="$(cd "$TEST_DIR/.." && pwd)"
SKILL_DIR="$REFRESH_DIR/../skills/review-gate"
TMP="$(mktemp -d)" || { echo 'adopt-refresh: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP && ! -L $TMP ]] || { echo "adopt-refresh: scratch=not-a-directory value=[$TMP]" >&2; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)" || { echo 'adopt-refresh: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT
. "$TEST_DIR/lib/refresh-fixture.sh"
ADOPT='refresh/adopt-refresh.sh'
REFRESH='.github/workflows/kendex-refresh.yml'
TEMPLATE='.agents/skills/review-gate/templates/kendex-refresh.yml'
# Seed a committed, owned writer to make retirement ordering observable.
printf 'retired workflow\n' >"$PRISTINE/.github/workflows/review-gate-writer.yml"
record_adoption "$PRISTINE" .github/workflows/review-gate-writer.yml .agents/skills/review-gate/templates/review-gate-writer.yml
commit "$PRISTINE"


sandbox
run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
if [ "$RC" -eq 0 ] && adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE"; then ok 'adoption retires the owned writer and records the refresh copy'; else bad "initial adoption (rc=$RC)" "$OUT"; fi
cp "$DIR/.kendex-generated.json" "$TMP/inventory-before"
run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
if [ "$RC" -eq 0 ] && cmp -s "$TMP/inventory-before" "$DIR/.kendex-generated.json"; then ok 'repeated adoption keeps the inventory unchanged'; else bad "repeated adoption (rc=$RC)" "$OUT"; fi

# The API child keeps the inputs used by GitHub CLI configuration, Linux
# credential storage and Go network routes. The fixture owns its assertions.
while IFS='|' read -r key value mutation expected; do
  sandbox
  run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
  [ "$RC" -eq 0 ] || exit 1
  rm -- "${DIR:?}/$REFRESH"
  printf '[]\n' >"$DIR/.kendex-generated.json"
  cp "$BIN/gh" "$BIN/gh-environment-base"
  api_calls="$TMP/api-environment-calls"
  : >"$api_calls"
  python3 - "$BIN/gh" "$BIN/gh-environment-base" "$key" "$value" "$api_calls" <<'GH_ENVIRONMENT'
from pathlib import Path
import sys
p=Path(sys.argv[1]); p.write_text("#!/usr/bin/env python3\nimport os, sys\n"
    "with open("+repr(sys.argv[5])+", 'a') as calls: calls.write(('validation' if '--paginate' in sys.argv else 'discovery') + '\\n')\n"
    "if os.environ.get("+repr(sys.argv[3])+") != "+repr(sys.argv[4])+" or 'UNRELATED_APPLICATION_SECRET' in os.environ: raise SystemExit(91)\n"
    "if os.environ.get('SSL_CERT_FILE') != 'environment-input' or os.environ.get('SSL_CERT_DIR') != 'environment-input' or os.environ.get('GODEBUG') != 'x509sslcertoverrideplatform=0': raise SystemExit(92)\n"
    "os.execv("+repr(sys.argv[2])+", ["+repr(sys.argv[2])+"] + sys.argv[1:])\n")
GH_ENVIRONMENT
  if [ "$mutation" = dropped ]; then
    python3 - "$DIR/.agents/skills/review-gate/scripts/lib/environment.py" "$key" <<'DROP_ENVIRONMENT'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); old='"'+sys.argv[2]+'", '; assert s.count(old)==1
changed=s.replace(old, ''); assert changed!=s; p.write_text(changed)
DROP_ENVIRONMENT
  elif [ "$mutation" != none ]; then
    python3 - "$DIR/.agents/skills/review-gate/scripts/lib/environment.py" "$mutation" <<'INHERITED_ENVIRONMENT'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); old='env=environment'; assert s.count(old)==1
condition="'--paginate' not in arguments" if sys.argv[2]=='discovery-inherited' else "'--paginate' in arguments"
changed=s.replace(old, 'env=(None if '+condition+' else environment)'); assert changed!=s; p.write_text(changed)
INHERITED_ENVIRONMENT
  fi
  RC=0
  OUT="$(cd "$DIR" && env -i PATH="$BIN:$PATH" HOME="$TMP" GH_TOKEN=fixture \
    SSL_CERT_FILE=environment-input SSL_CERT_DIR=environment-input GODEBUG=x509sslcertoverrideplatform=0 \
    "$key=$value" UNRELATED_APPLICATION_SECRET=fixture \
    "$DIR/$ADOPT" --templates-dir "$DIR/.agents/skills/review-gate/templates" --retire-writer 2>&1)" || RC=$?
  matched=no
  if [ "$RC" -eq 0 ] && adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE" &&
      grep -qxF discovery "$api_calls" && grep -qxF validation "$api_calls"; then matched=yes; fi
  if [ "$matched" = "$expected" ]; then ok "GitHub CLI child input=$key mutation=$mutation";
  else bad "GitHub CLI child input=$key mutation=$mutation" "$OUT"; fi
done <<'GH_ENV_ROWS'
XDG_CONFIG_HOME|environment-input|none|yes
AppData|environment-input|none|yes
DBUS_SESSION_BUS_ADDRESS|environment-input|none|yes
HTTPS_PROXY|environment-input|none|yes
no_proxy|environment-input|none|yes
SSL_CERT_FILE|environment-input|none|yes
SSL_CERT_DIR|environment-input|none|yes
GODEBUG|x509sslcertoverrideplatform=0|none|yes
XDG_CONFIG_HOME|environment-input|dropped|no
GODEBUG|x509sslcertoverrideplatform=0|dropped|no
GODEBUG|x509sslcertoverrideplatform=0|discovery-inherited|no
GODEBUG|x509sslcertoverrideplatform=0|validation-inherited|no
GH_ENV_ROWS

# Only the catalog fixture licenses updates. Consumer records, current
# templates and consumer commits cannot supply shipment evidence.
# input | record | result | writer
while IFS='|' read -r input record result writer; do
  sandbox
  if [ "$writer" = absent ]; then
    rm -- "${DIR:?}/.github/workflows/review-gate-writer.yml"
    printf '[]\n' >"$DIR/.kendex-generated.json"
  fi
  cp "$DIR/$TEMPLATE" "$DIR/$REFRESH"
  case "$input" in
    historical) cp "$TMP/shipped-historical" "$DIR/$REFRESH" ;;
    hand-edit) file_edit "$DIR" "$REFRESH" 1 '^name: ' 's/^name: .*/name: consumer edit/' ;;
    fake-history) printf '# consumer edit\n' >>"$DIR/$TEMPLATE"; cp "$DIR/$TEMPLATE" "$DIR/$REFRESH" ;;
  esac
  if [ "$record" != missing ]; then
    python3 - "$DIR" "$REFRESH" "$TEMPLATE" "$record" <<'RECORD'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1]); inventory = root / '.kendex-generated.json'
entries = json.loads(inventory.read_text())
value = hashlib.sha256((root / sys.argv[2]).read_bytes()).hexdigest() if sys.argv[4] == 'matching' else '0' * 64
entries.append({'path': sys.argv[2], 'template': sys.argv[3], 'templateHash': 'sha256:' + value})
inventory.write_text(json.dumps(entries))
RECORD
  fi
  commit "$DIR"
  # Refresh restores the shipped template, not the committed workflow edit.
  if [ "$input" = fake-history ]; then cp "$PRISTINE/$TEMPLATE" "$DIR/$TEMPLATE"; fi
  # The owned writer must remain until refresh shipment is proved.
  cp "$DIR/.kendex-generated.json" "$TMP/adoption-inventory"
  cp "$DIR/$REFRESH" "$TMP/adoption-workflow"
  if [ "$writer" != absent ]; then cp "$DIR/.github/workflows/review-gate-writer.yml" "$TMP/adoption-writer"; fi
  run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
  if [ "$result" = accept ]; then
    if [ "$RC" -eq 0 ] && adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE" && [ ! -e "$DIR/.github/workflows/review-gate-writer.yml" ]; then ok "$input record=$record writer=$writer adopts shipped bytes"
    else bad "$input record=$record writer=$writer (rc=$RC)" "$OUT"; fi
  elif [ "$writer" = absent ]; then
    if [ "$RC" -eq 1 ] && grep -qxF "refresh-error=workflow-edited value=$DIR/$REFRESH" <<<"$OUT" &&
        cmp -s "$TMP/adoption-workflow" "$DIR/$REFRESH" && cmp -s "$TMP/adoption-inventory" "$DIR/.kendex-generated.json" &&
        ! grep -qE '^(ok|FAIL|note) check=workflow-' <<<"$OUT"; then ok 'no-writer edit refuses before adoption'
    else bad 'no-writer edit preservation' "$OUT"; fi
  else
    target="$REFRESH"
    [ "$result" != template-edited ] || target="$TEMPLATE"
    if adoption_preserved "refresh-error=$result value=$DIR/$target"; then
      ok "$input record=$record refuses before writer effects"
    else bad "$input record=$record preservation (rc=$RC)" "$OUT"; fi
    if [ "$input" = fake-history ]; then
      python3 - "$DIR/$ADOPT" <<'CONSUMER_HISTORY_CONTROL'
from pathlib import Path
import sys
p = Path(sys.argv[1]).resolve(); s = p.read_text()
old = 'if not shipped_copy:'
assert s.count(old) == 1
new = '''consumer_path = ".agents/skills/review-gate/templates/kendex-refresh.yml"
consumer_commits = subprocess.check_output(
    ["git", "-C", str(root), "log", "--full-history", "--format=%H", "HEAD", "--", consumer_path],
    env=environment).decode().splitlines()
for consumer_commit in consumer_commits:
    candidate = subprocess.check_output(
        ["git", "-C", str(root), "show", consumer_commit + ":" + consumer_path], env=environment)
    shipped_copy = shipped_copy or copied == candidate
''' + old
changed = s.replace(old, new)
assert changed != s
p.write_text(changed)
CONSUMER_HISTORY_CONTROL
      run_refresh_command "$DIR" "$DIR/$ADOPT"
      if [ "$RC" -eq 0 ] && ! adoption_preserved "refresh-error=$result value=$DIR/$target"; then
        ok 'control: consumer-history acceptance breaks the fake-history preservation assertion'
      else bad 'consumer-history control' "$OUT"; fi
    fi
  fi
done <<'ROWS'
current|missing|accept|present
current|matching|accept|present
current|stale|accept|present
historical|missing|accept|present
historical|matching|accept|present
historical|stale|accept|present
historical|missing|accept|absent
hand-edit|missing|workflow-edited|present
hand-edit|matching|workflow-edited|present
hand-edit|missing|workflow-edited|absent
fake-history|matching|workflow-edited|present
ROWS

# Independent identity, evidence-read and link rules each keep their
# diagnostic text while disabling behavior in a disposable copy.
for rule in workflow template history symlink baseline; do
  sandbox
  cp "$DIR/$TEMPLATE" "$DIR/$REFRESH"
  case "$rule" in
    workflow | baseline) printf '# consumer edit\n' >>"$DIR/$REFRESH"; key=workflow-edited; target="$REFRESH" ;;
    template) printf '# consumer template edit\n' >>"$DIR/$TEMPLATE"; key=template-edited; target="$TEMPLATE" ;;
    history) key=read; target=workflow-history
      python3 - "$DIR/$ADOPT" "$CATALOG" <<'BROKEN_TRANSPORT'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); assert s.count(sys.argv[2]) == 1
p.write_text(s.replace(sys.argv[2], sys.argv[2] + '-missing'))
BROKEN_TRANSPORT
      ;;
    symlink) mv "$DIR/$REFRESH" "$TMP/symlink-target"; ln -s "$TMP/symlink-target" "$DIR/$REFRESH"; key=workflow-symlink; target="$REFRESH" ;;
  esac
  snapshot_adoption
  error="refresh-error=$key value=$DIR/$target"
  [ "$rule" != history ] || error='refresh-error=read value=workflow-history'
  run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
  if adoption_preserved "$error"; then ok "$rule refuses without workflow, writer or inventory changes"
  else bad "$rule refusal" "$OUT"; fi
  if [ "$rule" = baseline ]; then
    git -C "$SKILL_DIR" show b315ac64:skills/review-gate/scripts/adopt-refresh.sh >"$DIR/$ADOPT"
  else
    python3 - "$DIR/$ADOPT" "$rule" <<'CONTROL'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
mutations={
 'workflow': ('if not shipped_copy:', 'if False and not shipped_copy:', 1),
 'template': ('if not shipped_template:', 'if False and not shipped_template:', 1),
 'symlink': ('if refresh.is_symlink():', 'if False and refresh.is_symlink():', 2),
 'history': ('print("refresh-error=read value=workflow-history", file=sys.stderr)', 'if False: print("refresh-error=read value=workflow-history", file=sys.stderr)', 1),
}
old,new,count=mutations[sys.argv[2]]; assert s.count(old)==count
changed=s.replace(old,new)
if sys.argv[2]=='history':
 old='raise SystemExit(2) from error'; assert changed.count(old)==2
 position=changed.index(old, changed.index('def git(')); changed=changed[:position]+changed[position:].replace(old, 'return b"" # ' + old, 1)
assert changed != s; p.write_text(changed)
CONTROL
  fi
  run_refresh_command "$DIR" "$DIR/$ADOPT"
  if ! adoption_preserved "$error"; then ok "control: $rule breaks its preservation assertion"
  else bad "$rule control" "$OUT"; fi
done

# An exact historical shipped workflow still needs the history lookup.
sandbox
cp "$TMP/shipped-historical" "$DIR/$REFRESH"
file_edit "$DIR" "$ADOPT" 1 '^        shipped_copy = shipped_copy or copied_shape == candidate_shape$' \
  's/copied_shape == candidate_shape/copied == replacement # copied_shape == candidate_shape/'
chmod +x "$DIR/$ADOPT"
run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
if [ "$RC" -eq 1 ] && grep -qxF "refresh-error=workflow-edited value=$DIR/$REFRESH" <<<"$OUT"; then
  ok 'control: removed historical equality breaks the f7db7e89 acceptance row'
else bad 'historical equality control' "$OUT"; fi

# A concurrent writer can change bytes or introduce a link after shipment
# classification. The final check owns that link, not the initial-link preflight.
# Refusal precedes retired-writer removal, refresh replacement and inventory.
for rule in workflow template symlink; do
  sandbox
  cp "$DIR/$TEMPLATE" "$DIR/$REFRESH"
  snapshot_adoption
  python3 - "$DIR/$ADOPT" "$rule" "$DIR" "$TMP" <<'CONCURRENT'
from pathlib import Path
import shlex, sys
p=Path(sys.argv[1]); s=p.read_text(); old='PREFLIGHT\n# Re-read inventory'
assert s.count(old)==1
root=Path(sys.argv[3]); workflow=root/'.github/workflows/kendex-refresh.yml'
if sys.argv[2]=='symlink':
 target=Path(sys.argv[4])/'concurrent-target'; target.write_bytes(workflow.read_bytes())
 effect='rm -- '+shlex.quote(str(workflow))+'; ln -s '+shlex.quote(str(target))+' '+shlex.quote(str(workflow))
else:
 target=workflow if sys.argv[2]=='workflow' else root/'.agents/skills/review-gate/templates/kendex-refresh.yml'
 effect="printf '# concurrent edit\\n' >>"+shlex.quote(str(target))
changed=s.replace(old, 'PREFLIGHT\n'+effect+'\n# Re-read inventory'); assert changed != s; p.write_text(changed)
CONCURRENT
  run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
  if [ "$rule" = template ]; then key=template-changed; target="$TEMPLATE"; else key=workflow-changed; target="$REFRESH"; fi
  [ "$rule" != symlink ] || key=workflow-symlink
  if [ "$RC" -eq 1 ] && grep -qxF "refresh-error=$key value=$DIR/$target" <<<"$OUT" &&
      cmp -s "$TMP/adoption-inventory" "$DIR/.kendex-generated.json" &&
      cmp -s "$TMP/adoption-writer" "$DIR/.github/workflows/review-gate-writer.yml" &&
      { [ "$rule" != workflow ] || grep -qxF '# concurrent edit' "$DIR/$REFRESH"; } &&
      { [ "$rule" != symlink ] || { [ -L "$DIR/$REFRESH" ] && cmp -s "$TMP/concurrent-target" "$TMP/adoption-workflow"; }; }; then
    ok "$rule precondition preserves the concurrent edit and inventory"
  else bad "$rule precondition" "$OUT"; fi
  python3 - "$DIR/$ADOPT" "$rule" <<'PRECONDITION_CONTROL'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text()
old={'workflow':'if (refresh.read_bytes() if refresh.exists() else None) != observed:',
     'template':'if template.read_bytes() != (scratch / "source-template").read_bytes():',
     'symlink':'if refresh.is_symlink():'}[sys.argv[2]]
assert s.count(old)==(2 if sys.argv[2]=='symlink' else 1)
before, after = s.rsplit(old, 1)
changed=before + 'if False: # ' + old + after
assert changed != s; p.write_text(changed)
PRECONDITION_CONTROL
  # The preflight now sees the concurrent edit. Reset it before the mutant
  # runs so the planted change again arrives only after classification.
  if [ "$rule" = symlink ]; then rm -- "$DIR/$REFRESH"; fi
  cp "$TMP/adoption-workflow" "$DIR/$REFRESH"
  if [ "$rule" = template ]; then cp "$TMP/adoption-workflow" "$DIR/$TEMPLATE"; fi
  run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
  if [ "$RC" -eq 0 ]; then ok "control: $rule precondition bypass overwrites after classification"
  else bad "$rule precondition control" "$OUT"; fi
done

# Each environment rule runs against the adopter, with a disabled condition
# in its disposable module copy. Reads still run under each control.
cp "$FIXTURES/environments.json" "$TMP/default-environments"
cp "$FIXTURES/branch-policies.json" "$TMP/default-policies"
cp "$FIXTURES/environment-secrets-kendex.json" "$TMP/default-secrets"
while IFS='|' read -r rule pattern; do
  sandbox
  cp "$TMP/default-environments" "$FIXTURES/environments.json"
  cp "$TMP/default-policies" "$FIXTURES/branch-policies.json"
  cp "$TMP/default-secrets" "$FIXTURES/environment-secrets-kendex.json"
  case "$rule" in
    missing) printf '{"environments":[]}\n' >"$FIXTURES/environments.json" ;;
    branch-policy) printf '{"branch_policies":[{"name":"*","type":"branch"}]}\n' >"$FIXTURES/branch-policies.json" ;;
    policy-type) printf '{"environments":[{"name":"kendex","deployment_branch_policy":null}]}\n' >"$FIXTURES/environments.json" ;;
    read) SHIM_FAIL=environments ;;
  esac
  cp "$DIR/.kendex-generated.json" "$TMP/inventory-before"
  run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
  cause="$rule"; [ "$rule" != policy-type ] || cause=branch-policy
  [ "$rule" != read ] || cause="read operation=repos/acme/widgets/environments"
  if [ "$RC" -eq 1 ] && grep -qxF "refresh-error=environment value=kendex cause=$cause" <<<"$OUT" &&
      [ ! -e "$DIR/$REFRESH" ] && cmp -s "$TMP/inventory-before" "$DIR/.kendex-generated.json"; then
    ok "$rule refuses before workflow or inventory changes"
  else bad "$rule environment refusal" "$OUT"; fi
  python3 - "$DIR/.agents/skills/review-gate/scripts/lib/environment.py" "$pattern" "$rule" <<'ENV_CONTROL'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); old=sys.argv[2].replace("\\n", "\n"); assert s.count(old)==1
if sys.argv[3]=='read':
 # Keep the failed API request and refusal text. Valid fallback data lets
 # the later policy checks pass, so only the ignored read changes adoption.
 replacement = old.replace('refuse("read", endpoint)', '# refuse("read", endpoint)\n            return [{"environments": [{"name": "kendex", "deployment_branch_policy": {"custom_branch_policies": True, "protected_branches": False}}]}]')
 s=s.replace(old, replacement)
else:
 s=s.replace(old, 'if False and ('+old[3:-1]+'):' )
if sys.argv[3]=='missing':
 old='policy = selected[0].get("deployment_branch_policy")'; assert s.count(old)==1
 s=s.replace(old, 'policy = selected[0].get("deployment_branch_policy") if selected else {"custom_branch_policies": True, "protected_branches": False}')
assert s != p.read_text(); p.write_text(s)
ENV_CONTROL
  run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
  if [ "$RC" -eq 0 ] && adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE"; then
    ok "control: disabled $rule check permits adoption"
  else bad "$rule environment control" "$OUT"; fi
  SHIM_FAIL=''
done <<'ENV_ROWS'
missing|if len(selected) != 1:
branch-policy|if len(policies) != 1 or policies[0].get("name") != branch or policies[0].get("type", "branch") != "branch":
policy-type|if not isinstance(policy, dict) or policy.get("custom_branch_policies") is not True or policy.get("protected_branches") is not False:
read|            print(error.stderr, file=sys.stderr, end="")\n            refuse("read", endpoint)
ENV_ROWS
cp "$TMP/default-environments" "$FIXTURES/environments.json"
cp "$TMP/default-policies" "$FIXTURES/branch-policies.json"
cp "$TMP/default-secrets" "$FIXTURES/environment-secrets-kendex.json"

sandbox
printf '{"full_name":"vanillagreencom/kendex","default_branch":"main"}\n' >"$FIXTURES/repository.json"
cp "$DIR/.kendex-generated.json" "$TMP/self-inventory"
run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
if [ "$RC" -eq 0 ] && [ ! -e "$DIR/$REFRESH" ] && cmp -s "$TMP/self-inventory" "$DIR/.kendex-generated.json"; then
  ok 'kendex adoption leaves workflows and inventory unchanged'
else bad 'kendex self-exclusion' "$OUT"; fi
file_edit "$DIR" "$ADOPT" 1 'if \[ "\$repository" = vanillagreencom/kendex \]; then' \
  's/if \[ "\$repository" = vanillagreencom\/kendex \]; then/if false; then/'
chmod +x "$DIR/$ADOPT"
printf '{"environments":[{"name":"kendex","deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}]}\n' >"$FIXTURES/environments.json"
run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
if [ "$RC" -eq 0 ] && [ -e "$DIR/$REFRESH" ]; then
  ok 'control: removed self-exclusion adopts the consumer workflow in kendex'
else bad 'self-exclusion control did not reach adoption' "$OUT"; fi

sandbox
rm -- "$DIR/.github/workflows/review-gate-writer.yml"
printf '[]\n' >"$DIR/.kendex-generated.json"
printf '{"full_name":"acme/widgets","default_branch":"main"}\n' >"$FIXTURES/repository.json"
run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
[ "$RC" -eq 0 ] && adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE" || exit 1
# Refresh records the new template hash before adoption, as above.
commit "$DIR"
printf '\n# new template bytes\n' >>"$DIR/$TEMPLATE"
ship_refresh_template "$DIR/$TEMPLATE"
record_template_hash
run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
if [ "$RC" -eq 0 ] && adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE"; then
  ok 'no-writer refresh updates an unedited refresh workflow'
else bad "no-writer template update (rc=$RC)" "$OUT"; fi
commit "$DIR"
printf '# consumer edit\n' >>"$DIR/$REFRESH"
cp "$DIR/$REFRESH" "$TMP/adoption-workflow"
cp "$DIR/.kendex-generated.json" "$TMP/adoption-inventory"
run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
if [ "$RC" -eq 1 ] && grep -qxF "refresh-error=workflow-edited value=$DIR/$REFRESH" <<<"$OUT" &&
    cmp -s "$TMP/adoption-workflow" "$DIR/$REFRESH" && cmp -s "$TMP/adoption-inventory" "$DIR/.kendex-generated.json"; then
  ok 'no-writer adoption preserves a later workflow edit'
else bad 'no-writer later edit' "$OUT"; fi

OWNER=".agents/skills/review-gate/templates/review-gate-writer.yml"
# The automatic runner invokes its preserved adopter without retirement
# input, while reading templates from the refreshed checkout.
while IFS='|' read -r mutation expected; do
  sandbox
  rm -- "$DIR/.github/workflows/review-gate-writer.yml"
  printf '[]\n' >"$DIR/.kendex-generated.json"
  writer='.github/workflows/retired.yml'
  printf 'retired workflow\n' >"$DIR/$writer"
  record_adoption "$DIR" "$writer" "$OWNER"
  commit "$DIR"
  trusted="$TMP/automatic-$SANDBOX_N"
  git -C "$DIR" worktree add --detach -q "$trusted" HEAD
  case "$mutation" in
    none) ;;
    retirement)
      file_edit "$trusted" "$ADOPT" 1 '^retiring = retired if ' 's/else \[\]$/else retired/' ;;
    warning)
      file_edit "$trusted" "$ADOPT" 1 '^    print\("refresh-warning=legacy-writer' \
        's/^    print("refresh-warning=legacy-writer/    # print("refresh-warning=legacy-writer/' ;;
    *) exit 2 ;;
  esac
  run_refresh_command "$DIR" "$trusted/$ADOPT" --templates-dir "$DIR/.agents/skills/review-gate/templates"
  warning_count="$(awk '/^refresh-warning=legacy-writer / { count++ } END { print count + 0 }' <<<"$OUT")" || exit 1
  matched=no
  if retirement_matches "$DIR" "$writer" "$OWNER" preserved &&
      [ "$warning_count" -eq 1 ] && grep -qxF "refresh-warning=legacy-writer value=$OWNER" <<<"$OUT"; then matched=yes; fi
  if [ "$RC" -eq 0 ] && [ "$matched" = "$expected" ]; then ok "automatic legacy writer mutation=$mutation"; else bad "automatic legacy writer mutation=$mutation (rc=$RC)" "$OUT"; fi
done <<'AUTOMATIC'
none|yes
retirement|no
warning|no
AUTOMATIC

while IFS='|' read -r kind expected; do
  sandbox
  rm -- "$DIR/.github/workflows/review-gate-writer.yml"
  printf '[]\n' >"$DIR/.kendex-generated.json"
  writer="$DIR/.github/workflows/retired.yml"
  printf 'retired workflow\n' >"$writer"
  record_adoption "$DIR" .github/workflows/retired.yml "$OWNER"
  commit "$DIR"
  case "$kind" in
    initial) rm -- "${writer:?}"; printf '[]\n' >"$DIR/.kendex-generated.json" ;;
    new-install)
      rm -- "${writer:?}"
      git -C "$DIR" rm -q .kendex-generated.json
      commit "$DIR"
      printf '[]\n' >"$DIR/.kendex-generated.json" ;;
    retired|repeat) ;;
    missing) rm "$writer" ;;
    edited) printf 'consumer edit\n' >>"$writer" ;;
    symlink) mv "$writer" "$DIR/target"; ln -s ../../target "$writer" ;;
    unrecorded) mv "$writer" "$DIR/.github/workflows/review-gate-writer.yml"; writer="$DIR/.github/workflows/review-gate-writer.yml" ;;
    refresh-symlink|update)
      cp "$DIR/$TEMPLATE" "$DIR/$REFRESH"
      record_adoption "$DIR" "$REFRESH" "$TEMPLATE"
      commit "$DIR"
      case "$kind" in
        refresh-symlink) mv "$DIR/$REFRESH" "$DIR/refresh-target"; ln -s ../../refresh-target "$DIR/$REFRESH" ;;
        update) printf '\n# updated template\n' >>"$DIR/$TEMPLATE"; ship_refresh_template "$DIR/$TEMPLATE" ;;
      esac ;;
    environment) SHIM_FAIL='environments' ;;
    excluded) printf '{"full_name":"vanillagreencom/kendex","default_branch":"main"}\n' >"$FIXTURES/repository.json" ;;
    *) exit 2 ;;
  esac
  cp "$DIR/.kendex-generated.json" "$TMP/before"
  run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
  if [ "$expected" = pass ]; then
    if [ "$RC" -eq 0 ] && [ ! -e "$writer" ] && adoption_metadata "$DIR" "$REFRESH" "$TEMPLATE"; then ok "$kind"; else bad "$kind (rc=$RC)" "$OUT"; fi
    if [ "$kind" = retired ]; then
      if retirement_matches "$DIR" .github/workflows/retired.yml "$OWNER" removed; then
        ok 'explicit trusted retirement removes the writer and record'
      else bad 'explicit trusted retirement' "$OUT"; fi
      cp "$TMP/before" "$DIR/.kendex-generated.json"
      printf 'retired workflow\n' >"$writer"
      file_edit "$DIR" "$ADOPT" 1 '^retiring = retired if ' 's/^retiring = retired if /retiring = [] if /'
      run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
      if [ "$RC" -eq 0 ] && ! retirement_matches "$DIR" .github/workflows/retired.yml "$OWNER" removed; then
        ok 'control: disabled explicit retirement breaks the removal assertion'
      else bad 'explicit retirement control' "$OUT"; fi
    fi
    if [ "$kind" = repeat ]; then
      cp "$DIR/.kendex-generated.json" "$TMP/repeated"
      run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
      if [ "$RC" -eq 0 ] && cmp -s "$TMP/repeated" "$DIR/.kendex-generated.json" &&
          ! grep -q '^refresh-warning=legacy-writer ' <<<"$OUT"; then ok 'repeat unchanged without a legacy warning'; else bad 'repeat unchanged' "$OUT"; fi
    fi
  elif [ "$expected" = excluded ]; then
    if [ "$RC" -eq 0 ] && cmp -s "$TMP/before" "$DIR/.kendex-generated.json" && [ ! -e "$DIR/$REFRESH" ]; then ok "$kind"; else bad "$kind" "$OUT"; fi
  else
    if [ "$RC" -ne 0 ] && cmp -s "$TMP/before" "$DIR/.kendex-generated.json" && [ -e "$writer" ] && { [ "$expected" = environment ] || grep -q "^refresh-error=$expected value=" <<<"$OUT"; }; then ok "$kind"; else bad "$kind (rc=$RC)" "$OUT"; fi
  fi
  SHIM_FAIL=''
  printf '{"full_name":"acme/widgets","default_branch":"main"}\n' >"$FIXTURES/repository.json"
done <<'CASES'
initial|pass
new-install|pass
retired|pass
repeat|pass
missing|pass
edited|workflow-edited
symlink|workflow-symlink
unrecorded|workflow-unrecorded
refresh-symlink|workflow-symlink
update|pass
environment|environment
excluded|excluded
CASES

# Each independent ownership guard keeps its diagnostic and operands while
# the control disables its condition in a disposable script copy.
while IFS='|' read -r kind pattern replacement; do
  sandbox
  rm -- "$DIR/.github/workflows/review-gate-writer.yml"
  printf '[]\n' >"$DIR/.kendex-generated.json"
  writer="$DIR/.github/workflows/retired.yml"
  printf 'retired workflow\n' >"$writer"
  record_adoption "$DIR" .github/workflows/retired.yml "$OWNER"
  commit "$DIR"
  case "$kind" in
    retired-edited) printf 'consumer edit\n' >>"$writer" ;;
    retired-symlink) mv "$writer" "$DIR/target"; ln -s ../../target "$writer" ;;
    unrecorded) mv "$writer" "$DIR/.github/workflows/review-gate-writer.yml" ;;
  esac
  file_edit "$DIR" "$ADOPT" 1 "$pattern" "$replacement" 1
  run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
  if [ "$RC" -eq 0 ]; then ok "$kind control allows the forbidden mutation"; else bad "$kind control did not reach the guard" "$OUT"; fi
done <<'CONTROLS'
retired-edited|^        if not copied.is_file|s/^        if \(.*\):$/        if False and (\1):/
retired-symlink|^    if copied.is_symlink|s/^    if \(.*\):$/    if False and (\1):/
unrecorded|^if.*unrecorded.exists|s/^if \(.*\):$/if False and (\1):/
CONTROLS

# The rendered template becomes the caller. The adopter checks the shared
# workflow's names and records the copy; the v1.5.1 adopter extracts empty
# names from the caller and refuses it.
sandbox
cp "$DIR/$TEMPLATE" "$DIR/$REFRESH"
record_adoption "$DIR" "$REFRESH" "$TEMPLATE"
commit "$DIR"
cp "$CALLER" "$DIR/$TEMPLATE"
ship_refresh_template "$CALLER"
record_template_hash
cp "$DIR/.kendex-generated.json" "$TMP/caller-inventory"
cp "$DIR/$REFRESH" "$TMP/caller-workflow"
run_refresh_command "$DIR" "$DIR/$ADOPT"
if [ "$RC" -eq 0 ] && cmp -s "$DIR/$REFRESH" "$CALLER" &&
    retirement_matches "$DIR" .github/workflows/review-gate-writer.yml "$OWNER" preserved &&
    python3 - "$DIR" "$REFRESH" "$TEMPLATE" <<'RECORD'
import hashlib, json, sys
from pathlib import Path
root = Path(sys.argv[1]); path, template = sys.argv[2:]
record = [e for e in json.loads((root / '.kendex-generated.json').read_text()) if isinstance(e, dict) and e['path'] == path]
assert record == [{'path': path, 'template': template, 'templateHash': 'sha256:' + hashlib.sha256((root / template).read_bytes()).hexdigest()}]
RECORD
then ok 'the rendered caller template adopts with the shared workflow names'
else bad "rendered caller adoption (rc=$RC)" "$OUT"; fi
cp "$TMP/caller-inventory" "$DIR/.kendex-generated.json"
cp "$TMP/caller-workflow" "$DIR/$REFRESH"
historical_adopt="$DIR/.agents/skills/review-gate/scripts/adopt-refresh.sh"
git -C "$SKILL_DIR" show 5a8c5d71f2670d2d26710a11475d17d091c3cd9a:skills/review-gate/scripts/adopt-refresh.sh >"$historical_adopt"
chmod +x "$historical_adopt"
trust_refresh_transport "$DIR" "$historical_adopt"
run_refresh_command "$DIR" "$historical_adopt"
if [ "$RC" -ne 0 ] && cmp -s "$DIR/$REFRESH" "$TMP/caller-workflow" && grep -q '^review-gate-error=standard-setting-missing ' <<<"$OUT"; then
  ok 'control: the v1.5.1 adopter refuses the rendered caller template'
else bad "v1.5.1 adopter control (rc=$RC)" "$OUT"; fi

# The shared workflow passes its release tree, outside the consumer. The
# caller ships only at refresh/ in the catalog. The copy gets no record, the
# earlier refresh record goes and every other record stays.
RELEASE="$TMP/release-refresh"
mkdir -p "$RELEASE"
cp "$CALLER" "$RELEASE/kendex-refresh.yml"
ship_caller_template "$CALLER"
for mutation in none record history; do
  sandbox
  cp "$DIR/$TEMPLATE" "$DIR/$REFRESH"
  record_adoption "$DIR" "$REFRESH" "$TEMPLATE"
  commit "$DIR"
  case "$mutation" in
    none) ;;
    record)
      file_edit "$DIR" "$ADOPT" 1 '^    entries = \[e for e in entries if not isinstance\(e, dict\) or e\["path"\] != ' \
        's/^    entries = \[e for e in entries if not isinstance(e, dict) or e\["path"\] != .*$/    pass  # &/' ;;
    history)
      file_edit "$DIR" "$ADOPT" 1 '^paths = \(' 's/, "refresh\/kendex-refresh.yml")/) # "refresh\/kendex-refresh.yml"/' ;;
  esac
  run_refresh_command "$DIR" "$DIR/$ADOPT" --templates-dir "$RELEASE"
  matched=no
  if [ "$RC" -eq 0 ] && cmp -s "$DIR/$REFRESH" "$CALLER" &&
      retirement_matches "$DIR" .github/workflows/review-gate-writer.yml "$OWNER" preserved &&
      jq -e --arg path "$REFRESH" '[.[] | objects | select(.path == $path)] == []' "$DIR/.kendex-generated.json" >/dev/null; then matched=yes; fi
  case "$mutation:$matched" in
    none:yes) ok 'release-tree adoption writes the caller and drops its record' ;;
    record:no | history:no) ok "control: $mutation turns the release-tree adoption assertion red" ;;
    *) bad "release-tree adoption mutation=$mutation (rc=$RC)" "$OUT" ;;
  esac
  if [ "$mutation" = none ]; then
    commit "$DIR"
    cp "$DIR/.kendex-generated.json" "$TMP/release-inventory"
    run_refresh_command "$DIR" "$DIR/$ADOPT" --templates-dir "$RELEASE"
    if [ "$RC" -eq 0 ] && cmp -s "$TMP/release-inventory" "$DIR/.kendex-generated.json" && cmp -s "$DIR/$REFRESH" "$CALLER"; then
      ok 'repeated release-tree adoption accepts the shipped caller and keeps the inventory'
    else bad "repeated release-tree adoption (rc=$RC)" "$OUT"; fi
  fi
done

# The v1.8.0 caller passes no secrets, so its called job reads them empty. A
# consumer holding those shipped bytes takes the current caller.
git -C "$SKILL_DIR" show 22391ad71dab8ee853f53622ade4b532216ee691:refresh/kendex-refresh.yml >"$TMP/caller-no-secrets"
ship_caller_template "$TMP/caller-no-secrets"
ship_caller_template "$CALLER"
sandbox
cp "$TMP/caller-no-secrets" "$DIR/$REFRESH"
commit "$DIR"
run_refresh_command "$DIR" "$DIR/$ADOPT" --templates-dir "$RELEASE"
if [ "$RC" -eq 0 ] && cmp -s "$DIR/$REFRESH" "$CALLER" &&
    jq -e --arg path "$REFRESH" '[.[] | objects | select(.path == $path)] == []' "$DIR/.kendex-generated.json" >/dev/null; then
  ok 'a consumer holding the v1.8.0 caller bytes takes the current caller'
else bad "v1.8.0 caller re-adoption (rc=$RC)" "$OUT"; fi
# A shipped caller on the earlier secret names needs no new declaration.
git -C "$SKILL_DIR" show f24599cab98369094567af9dd1668706a348507c:refresh/kendex-refresh.yml >"$TMP/legacy-caller"
ship_caller_template "$TMP/legacy-caller"

# Each accepted declaration owns its expected environment and complete secret
# set independently of the production parser. Every such row checks missing
# secrets through the same refusal assertion, including retained legacy names.
while IFS='|' read -r rule mutation pattern selected_environment expected_names; do
  sandbox
  cp "$CALLER" "$DIR/$TEMPLATE"
  if [ "$rule" = legacy ]; then cp "$TMP/legacy-caller" "$DIR/$REFRESH"; fi
  python3 - "$DIR/$TEMPLATE" "$rule" <<'CUSTOM'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); assert s.count('environment: kendex')==1
rule=sys.argv[2]
if rule in ('default', 'legacy'): raise SystemExit(0)
for key in ('FLEET_GH_APP_ID', 'FLEET_GH_APP_PRIVATE_KEY'):
 s=s.replace('      '+key+': ${{ secrets.'+key+' }}\n', '')
s=s.replace('environment: kendex', 'environment: delivery').replace('FLEET_GH_APP_ID', 'DELIVERY_ID').replace('FLEET_GH_APP_PRIVATE_KEY', 'DELIVERY_KEY')
if rule=='combined':
 s += '      FLEET_GH_APP_ID: ${{ secrets.FLEET_GH_APP_ID }}\n      FLEET_GH_APP_PRIVATE_KEY: ${{ secrets.FLEET_GH_APP_PRIVATE_KEY }}\n'
if rule=='legacy-secret-names':
 s += '      FLEET_GH_APP_ID: ${{ secrets.DELIVERY_ID }}\n      FLEET_GH_APP_PRIVATE_KEY: ${{ secrets.FLEET_GH_APP_PRIVATE_KEY }}\n'
if rule=='missing': s=s.replace('      app-private-key: ${{ secrets.DELIVERY_KEY }}\n', '')
elif rule=='mixed-case':
 s=s.replace('app-id-secret-name: DELIVERY_ID', 'app-id-secret-name: Delivery_ID').replace('app-private-key-secret-name: DELIVERY_KEY', 'app-private-key-secret-name: Delivery_Key')
 s=s.replace('secrets.DELIVERY_ID', 'secrets.delivery_iD').replace('secrets.DELIVERY_KEY', 'secrets.delivery_kEY')
elif rule=='inherit': s=s.replace('    secrets:\n      app-id: ${{ secrets.DELIVERY_ID }}\n      app-private-key: ${{ secrets.DELIVERY_KEY }}', '    secrets: inherit')
elif rule=='expression': s=s.replace('${{ secrets.DELIVERY_ID }}', '${{ secrets.DELIVERY_ID || secrets.FALLBACK }}')
elif rule=='secret-names': s=s.replace('app-id-secret-name: DELIVERY_ID', 'app-id-secret-name: WRONG_ID')
elif rule=='environment': s=s.replace('environment: delivery', "environment: ${{ vars.DELIVERY_ENV }}")
elif rule=='duplicate': s=s.replace('      environment: delivery', '      environment: delivery\n      environment: delivery')
elif rule=='inputs': s=s.replace('    with:', '    with:\n      unexpected: value')
assert s != p.read_text(); p.write_text(s)
CUSTOM
  printf '{"environments":[{"name":"delivery","deployment_branch_policy":{"protected_branches":false,"custom_branch_policies":true}}]}\n' >"$FIXTURES/environments.json"
  printf '{"secrets":[{"name":"DELIVERY_ID"},{"name":"DELIVERY_KEY"}]}\n' >"$FIXTURES/environment-secrets-delivery.json"
  if [ "$rule" = mixed-case ]; then
    printf '{"secrets":[{"name":"dELIVERY_ID"},{"name":"dELIVERY_KEY"}]}\n' >"$FIXTURES/environment-secrets-delivery.json"
  fi
  if [ "$rule" = legacy-secret-names ]; then
    printf '{"secrets":[{"name":"DELIVERY_ID"},{"name":"DELIVERY_KEY"},{"name":"FLEET_GH_APP_ID"},{"name":"FLEET_GH_APP_PRIVATE_KEY"}]}\n' >"$FIXTURES/environment-secrets-delivery.json"
  fi
  if [ -n "$expected_names" ]; then
    python3 - "$FIXTURES" "$selected_environment" "$expected_names" "$rule" <<'DECLARED_ENVIRONMENT'
import json
from pathlib import Path
import sys
fixtures=Path(sys.argv[1]); environment=sys.argv[2]; names=sys.argv[3].split()
(fixtures/'environments.json').write_text(json.dumps({'environments': [{'name': environment, 'deployment_branch_policy': {'protected_branches': False, 'custom_branch_policies': True}}]}))
(fixtures/('environment-secrets-'+environment+'.json')).write_text(json.dumps({'secrets': [{'name': name.lower() if sys.argv[4]=='mixed-case' else name} for name in names]}))
DECLARED_ENVIRONMENT
  fi
  if [[ "$mutation" = case-sensitive-* ]]; then
    owner="$DIR/refresh/lib/caller.py"
    [ "$mutation" != case-sensitive-api ] || owner="$DIR/.agents/skills/review-gate/scripts/lib/environment.py"
    python3 - "$owner" "$pattern" <<'CASE_CONTROL'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); old=sys.argv[2]; assert s.count(old)==1
changed=s.replace(old, old.replace('.upper()', ''))
assert changed != s; p.write_text(changed)
CASE_CONTROL
  fi
  if [ "$mutation" = disabled ]; then
    python3 - "$DIR/refresh/lib/caller.py" "$pattern" <<'MAPPING_CONTROL'
from pathlib import Path
import sys
p=Path(sys.argv[1]); s=p.read_text(); old=sys.argv[2]; assert s.count(old)==1
s=s.replace(old, 'if False and ('+old[3:-1]+'):' ); assert s != p.read_text(); p.write_text(s)
MAPPING_CONTROL
  fi
  run_refresh_command "$DIR" "$DIR/$ADOPT"
  if [ -n "$expected_names" ] && [ "$mutation" = none ]; then
    if [ "$RC" -eq 0 ] && cmp -s "$DIR/$REFRESH" "$DIR/$TEMPLATE"; then
      ok "$rule declaration adopts with all expected credentials"
    else bad "$rule declaration adoption" "$OUT"; fi
    snapshot_adoption
    for absent_name in $expected_names; do
      python3 - "$FIXTURES/environment-secrets-$selected_environment.json" "$expected_names" "$absent_name" <<'MISSING_DECLARED_SECRET'
import json
from pathlib import Path
import sys
Path(sys.argv[1]).write_text(json.dumps({'secrets': [{'name': name} for name in sys.argv[2].split() if name!=sys.argv[3]]}))
MISSING_DECLARED_SECRET
      run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
      if adoption_preserved "refresh-error=environment value=$selected_environment cause=secrets"; then
        ok "$rule declaration refuses missing $absent_name before adoption"
      else bad "$rule missing secret=$absent_name" "$OUT"; fi
    done
    if [ "$rule" = combined ]; then
      # Retain the valid combined mapping and the refusal text. Dropping the
      # retained legacy requirement must make the shared refusal assertion false.
      file_edit "$DIR" refresh/lib/caller.py 1 '^    required_names = list\(dict.fromkeys' \
        's/^    required_names = /    required_names = names # /'
      run_refresh_command "$DIR" "$DIR/$ADOPT" --retire-writer
      if [ "$RC" -eq 0 ] && ! adoption_preserved "refresh-error=environment value=$selected_environment cause=secrets"; then
        ok 'control: removed legacy requirement turns the combined missing-secret refusal red'
      else bad 'combined all-mapped-secrets control' "$OUT"; fi
    fi
    python3 - "$FIXTURES/environment-secrets-$selected_environment.json" "$expected_names" <<'RESTORE_DECLARED_SECRETS'
import json
from pathlib import Path
import sys
Path(sys.argv[1]).write_text(json.dumps({'secrets': [{'name': name} for name in sys.argv[2].split()]}))
RESTORE_DECLARED_SECRETS
  elif [ "$rule" = mixed-case ]; then
    matched=no
    if [ "$RC" -eq 0 ] && cmp -s "$DIR/$REFRESH" "$DIR/$TEMPLATE"; then matched=yes; fi
    case "$mutation:$matched" in
      case-sensitive-*:no)
        cause=secret-names; [ "$mutation" != case-sensitive-api ] || cause=secrets
        if [ ! -e "$DIR/$REFRESH" ] &&
            { { [ "$RC" -eq 2 ] && grep -qxF "refresh-error=caller-secrets value=$DIR/$TEMPLATE cause=$cause" <<<"$OUT"; } ||
              { [ "$RC" -eq 1 ] && grep -qxF "refresh-error=environment value=delivery cause=$cause" <<<"$OUT"; }; }; then
          ok "control: $mutation turns mixed-case adoption red"
        else bad "mixed-case control=$mutation" "$OUT"; fi ;;
      *) bad "mixed-case adoption mutation=$mutation" "$OUT" ;;
    esac
  else
    cause="$rule"; [ "$rule" != missing ] || cause=names; [ "$rule" != inherit ] || cause=not-mapping
    matched=no
    if [ "$RC" -eq 2 ] && grep -qxF "refresh-error=caller-secrets value=$DIR/$TEMPLATE cause=$cause" <<<"$OUT" && [ ! -e "$DIR/$REFRESH" ]; then matched=yes; fi
    case "$mutation:$matched" in
      none:yes) ok "$rule mapping refuses before adoption" ;;
      disabled:no) ok "control: disabled $rule rule turns the refusal assertion red" ;;
      *) bad "$rule mapping mutation=$mutation" "$OUT" ;;
    esac
  fi
  if [ "$rule" = custom ]; then
    # A refreshed default template must not overwrite the installed choice.
    cp "$DIR/$REFRESH" "$TMP/custom-workflow"
    run_refresh_command "$DIR" "$DIR/$ADOPT" --templates-dir "$RELEASE"
    if [ "$RC" -eq 0 ] && cmp -s "$DIR/$REFRESH" "$TMP/custom-workflow" &&
        jq -e --arg path "$REFRESH" '[.[] | objects | select(.path == $path)] == []' "$DIR/.kendex-generated.json" >/dev/null; then
      ok 'refresh keeps the custom mapping and environment without a byte-identical render record'
    else bad 'custom refresh preservation' "$OUT"; fi
    file_edit "$DIR" refresh/lib/caller.py 1 '^    if replacement is None or config is None:' \
      's/if replacement is None or config is None:/if True or replacement is None or config is None:/'
    run_refresh_command "$DIR" "$DIR/$ADOPT" --templates-dir "$RELEASE"
    if [ "$RC" -eq 0 ] && ! cmp -s "$DIR/$REFRESH" "$TMP/custom-workflow"; then
      ok 'control: discarded configuration turns custom refresh preservation red'
    else bad 'custom preservation control' "$OUT"; fi
  fi
done <<'MAPPING_ROWS'
default|none||kendex|FLEET_GH_APP_ID FLEET_GH_APP_PRIVATE_KEY
legacy|none||kendex|FLEET_GH_APP_ID FLEET_GH_APP_PRIVATE_KEY
custom|none||delivery|DELIVERY_ID DELIVERY_KEY
combined|none||delivery|DELIVERY_ID DELIVERY_KEY FLEET_GH_APP_ID FLEET_GH_APP_PRIVATE_KEY
mixed-case|none||delivery|DELIVERY_ID DELIVERY_KEY
mixed-case|case-sensitive-reference|references[key] = match.group(1).upper()
mixed-case|case-sensitive-declaration|inputs.get("app-id-secret-name", DEFAULT_NAMES[0]).upper()
mixed-case|case-sensitive-api|{row["name"].upper() for row in secrets}
missing|none|
missing|disabled|if set(secrets) not in (set(DEFAULT_NAMES), set(neutral), set(DEFAULT_NAMES + neutral)):
inherit|none|
inherit|disabled|if section is None or not match:
expression|none|
expression|disabled|if not match:
secret-names|none|
secret-names|disabled|if names != declared or (legacy and names != list(DEFAULT_NAMES)):
legacy-secret-names|none|
legacy-secret-names|disabled|if key in references and references[key] != key:
environment|none|
environment|disabled|if not isinstance(environment, str) or not environment.strip() or any(c in environment for c in "\r\n${}[]#"):
duplicate|none|
duplicate|disabled|if key in section:
inputs|none|
inputs|disabled|if set(inputs) - {"environment", "app-id-secret-name", "app-private-key-secret-name"}:
MAPPING_ROWS
cp "$TMP/default-environments" "$FIXTURES/environments.json"
printf 'pass: %d   fail: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
