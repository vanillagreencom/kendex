#!/usr/bin/env bash
# Drives the actual consumer runner with real local git repositories. Only
# the classifier and GitHub services are replaced; held-render rows use a
# real kendex, an isolated HOME and a local catalog.
set -euo pipefail
REAL_KENDEX=""
# Check the runner requirement before sandbox.sh clears consumer settings.
if ! REAL_KENDEX="$(command -v kendex)"; then
  if [ -n "${REVIEW_GATE_REQUIRE_KENDEX:-}" ]; then
    printf 'refresh-consumer: kendex=missing\n' >&2
    exit 1
  fi
fi
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d)" || { echo 'refresh-consumer: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP && ! -L $TMP ]] || { echo "refresh-consumer: scratch=not-a-directory value=[$TMP]" >&2; exit 1; }
TMP="$(cd -- "$TMP" && pwd -P)" || { echo 'refresh-consumer: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT
# Fixture commits must not use the caller's Git configuration or identity.
for inherited in $(compgen -e); do
  case "$inherited" in GIT_* | EMAIL) unset "$inherited" ;; esac
done
unset inherited
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
. "$TEST_DIR/lib/refresh-fixture.sh"
mkdir -p "$TMP/missing-bin"
RC=0
OUT="$(env -i PATH="$TMP/missing-bin" REVIEW_GATE_REQUIRE_KENDEX=1 \
  "$BASH" "$TEST_DIR/refresh-consumer.test.sh" 2>&1)" || RC=$?
if [ "$RC" -eq 1 ] && [ "$OUT" = 'refresh-consumer: kendex=missing' ]; then
  ok 'control: a required missing binary fails instead of skipping'
else bad 'required missing binary control' "$OUT"; fi
cp "$BIN/gh" "$TMP/standard-gh"
mkdir -p "$TMP/bin" "$TMP/home" "$TMP/state"
cat >"$TMP/bin/gh" <<'SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_STATE/calls"
for arg in "$@"; do
  case "$arg" in body=*) printf '%s\n' "${arg#body=}" >"$TEST_STATE/body" ;; esac
done
case "$*" in
  'api repos/acme/test --jq .default_branch') printf 'main\n' ;;
  api\ --paginate\ *pulls*) cat "$TEST_STATE/pr" ;;
  api\ users/*) printf '123\n' ;;
  'api --method POST repos/acme/test/pulls '*) printf '1\n' >"$TEST_STATE/pr"; printf 'created\n' >>"$TEST_STATE/creates"; printf '1\n' ;;
  'api --method PATCH repos/acme/test/pulls/1 '*) : ;;
  'auth setup-git') : >"$TEST_STATE/auth" ;;
  'pr merge '*)
    case " $* " in
      *' --auto '*) : >"$TEST_STATE/armed" ;;
      *' --disable-auto '*) rm -f -- "$TEST_STATE/armed" ;;
      *) exit 2 ;;
    esac ;;
  'pr close '*) : ;;
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
    if [ -n "$TEST_REFRESH_SKILL" ]; then
      rm -rf -- .agents/skills/review-gate
      cp -R "$TEST_REFRESH_SKILL" .agents/skills/review-gate
    fi
    case "$TEST_ORCH_MODE" in
      keep) ;;
      absent) rm -rf -- .agents/skills/orch ;;
      install) rm -rf -- .agents/skills/orch; cp -R "$TEST_FRESH_ORCH" .agents/skills/orch ;;
      *) exit 2 ;;
    esac
    if [ -n "${TEST_HOSTILE:-}" ]; then
      cp "$TEST_FRESH_TEMPLATES/"*.yml .agents/skills/review-gate/templates/
      for path in adopt-refresh.sh validate-standard.sh lib/diagnostics.sh lib/settings.sh lib/standard.sh; do
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
if [ "$TEST_CLASS_EXIT" -ne 0 ]; then
  printf 'wiring-error: cause=output-unwritable\n' >&2
  exit "$TEST_CLASS_EXIT"
fi
printf 'class: class=%s measured=%s %s\n' "$TEST_CLASS" "$TEST_MEASURED" "$TEST_REASON" >&2
printf 'change_class=%s\n' "$TEST_CLASS"
SH
printf '#!/usr/bin/env bash\nset -euo pipefail\n: >"$4"\n' >"$repo/.agents/skills/review-gate/scripts/adopt-refresh.sh"
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

run_refresh current pass render
if [ "$RC" -eq 0 ] && [ ! -s "$TMP/state/creates" ] && grep -qxF 'refresh-state=current pr=none class=none' <<<"$OUT"; then ok 'current consumer opens no pull request'; else bad 'current consumer opens no pull request' "$OUT"; fi
reset_default
run_refresh stale pass render
first="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)"
if [ "$RC" -eq 0 ] && [ "$(wc -l <"$TMP/state/creates" | tr -d ' ')" -eq 1 ]; then ok 'stale consumer opens one rolling pull request'; else bad 'stale consumer opens one rolling pull request' "$OUT"; fi
reset_default
run_refresh stale pass render
second="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)"
if [ "$RC" -eq 0 ] && [ "$first" = "$second" ] && [ "$(wc -l <"$TMP/state/creates" | tr -d ' ')" -eq 1 ]; then ok 'repeat keeps one pull request and its commit'; else bad 'repeat keeps one pull request and its commit' "$OUT"; fi
cp "$TMP/state/body" "$TMP/clean-body"
# Committed settings and private overrides are real consumer inputs. Neither
# the parse nor the report is doubled in these rolling-refresh fixtures.
for row in \
  'claude:1:high||deprecated|claude:1:high' \
  'claude:fable:high||clean|' \
  'claude:fable:high|codex:2:low|deprecated|codex:2:low' \
  'claude::high,codex:0:low||refused|claude::high' \
  'claude:1:high|claude:fable:high|clean|' \
  'claude:1:high|claude:fable:high|clean||private.env'; do
  IFS='|' read -r committed private status entry private_path <<<"$row"
  private_path="${private_path:-.env.local}"
  reset_default
  printf '[env]\nORCH_OVERSEER_PREFERENCE = "%s"\n' "$committed" >"$repo/kendex.settings.toml"
  if [ "$private_path" != .env.local ]; then
    printf 'KENDEX_ENV_FILE = "%s"\n' "$private_path" >>"$repo/kendex.settings.toml"
  fi
  printf '.env.local\nprivate.env\n' >"$repo/.gitignore"
  commit "$repo"
  git -C "$repo" push -q origin main
  rm -f -- "$repo/.env.local" "$repo/private.env"
  if [ -n "$private" ]; then
    printf 'ORCH_OVERSEER_PREFERENCE=%s\n' "$private" >"$repo/$private_path"
  fi
  run_refresh stale pass render
  if [ "$status" = clean ]; then
    if [ "$RC" -eq 0 ] && cmp -s "$TMP/clean-body" "$TMP/state/body"; then ok 'clean preference leaves the whole body unchanged'; else bad 'clean preference body' "$OUT"; fi
  elif [ "$RC" -eq 0 ] && grep -qxF '## Settings' "$TMP/state/body" &&
    grep -qF "ORCH_OVERSEER_PREFERENCE: $status entry <code>$entry</code>; use \`harness:model:effort\`." "$TMP/state/body"; then
    ok "$status effective preference appears in Settings"
  else bad "$status effective preference report" "$OUT"; fi
  if [ "$status" = refused ]; then
    if grep -qF 'refused entry <code>codex:0:low</code>' "$TMP/state/body"; then ok 'report includes every refused entry'; else bad 'report omitted a refused entry'; fi
  fi
done
# A resolver that ignores PRIVATE_FILE reports the committed numeric value
# rather than the clean custom override. It must turn that clean-body row red.
reset_default
cp "$repo/.agents/skills/review-gate/scripts/lib/settings.sh" "$TMP/settings-lib"
python3 - "$repo/.agents/skills/review-gate/scripts/lib/settings.sh" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1]).resolve()
text = path.read_text()
old = 'private_file="${3-.env.local}"'
assert text.count(old) == 1
changed = '# ' + old + '\n' + text.replace(old, 'private_file=".env.local"')
assert changed != text
path.write_text(changed)
PY
commit "$repo"
git -C "$repo" push -q origin main
run_refresh stale pass render
if [ "$RC" -eq 0 ] && ! cmp -s "$TMP/clean-body" "$TMP/state/body"; then ok 'control: ignored private path turns the clean-body assertion red'; else bad 'private path resolver control' "$OUT"; fi
reset_default
cp "$TMP/settings-lib" "$repo/.agents/skills/review-gate/scripts/lib/settings.sh"
# Removing the Settings append from a private runner must make the same
# deprecated-entry assertion red without changing the parser or formatter.
reset_default
printf '[env]\nORCH_OVERSEER_PREFERENCE = "claude:1:high"\n' >"$repo/kendex.settings.toml"
rm -f -- "$repo/.env.local"
cp "$runner" "$TMP/settings-runner"
python3 - "$runner" <<'PY'
from pathlib import Path
import sys
path = Path(sys.argv[1]).resolve()
text = path.read_text()
old = 'if [ -n "$settings_report" ]; then'
assert text.count(old) == 1
changed = text.replace(old, '# ' + old + '\nif false; then')
assert changed != text
path.write_text(changed)
PY
commit "$repo"
git -C "$repo" push -q origin main
run_refresh stale pass render
if [ "$RC" -eq 0 ] && ! grep -qxF '## Settings' "$TMP/state/body"; then ok 'control: dropped Settings append turns the deprecated-entry assertion red'; else bad 'Settings append control' "$OUT"; fi
reset_default
cp "$TMP/settings-runner" "$runner"
commit "$repo"
git -C "$repo" push -q origin main
# The setting-fixture commits changed the rolling head used by later rows.
first="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)"
reset_default
run_refresh bad-verify fail render
after="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)"
if [ "$RC" -ne 0 ] && [ "$after" = "$first" ]; then ok 'bad-verify refuses before push'; else bad 'bad-verify refuses before push' "$OUT"; fi
# The body must update with the current class, including when the rolling
# tree is unchanged. A render-to-standard transition must remove the old arm.
for row in \
  'standard|open|no|cause=excluded-path path=.agents/skills/commit-guards/scripts/install-git-hooks glob=*skills/commit-guards/scripts/*' \
  'render|update|yes|cause=renders-match-their-sources' \
  'standard|update|no|cause=excluded-path path=.agents/skills/commit-guards/scripts/install-git-hooks glob=*skills/commit-guards/scripts/*' \
  'standard|unchanged|no|cause=excluded-path path=.agents/skills/commit-guards/scripts/install-git-hooks glob=*skills/commit-guards/scripts/*' \
  'trivial|update|no|cause=documentation-paths lines=8' \
  'micro|update|no|cause=production-within-micro production=8' \
  'small|update|no|cause=production-within-small subsystem=skills' \
  'render|update|yes|cause=renders-match-their-sources'; do
  IFS='|' read -r class mode arm CLASS_REASON <<<"$row"
  state=pushed; method=PATCH
  if [ "$mode" = open ]; then
    : >"$TMP/state/pr"
    rm -f -- "$TMP/state/armed"
    method=POST
  fi
  [ "$mode" != unchanged ] || state=unchanged
  : >"$TMP/state/calls"
  reset_default
  # The unchanged row deliberately repeats the preceding content.
  [ "$mode" = unchanged ] || content="class-$class"
  run_refresh "$content" pass "$class"
  if refresh_class_matches "$class" "$state" "$arm" "$CLASS_REASON" "$method"; then
    ok "$class $mode publishes its class and cause with arm=$arm"
  else bad "$class $mode class publication" "$OUT"; fi
done
# change-class prints removed dependency names in render-path-unowned paths.
# A name accepted by kendex can contain text that resembles protocol fields.
for row in \
  'fallback|false|0|cause=paths-unread' \
  'false-marker|false|0|cause=render-path-unowned path=.claude/skills/helper measured=true extra/SKILL.md' \
  'call-failed|true|2|cause=paths-unread'; do
  IFS='|' read -r name MEASURED CLASS_EXIT CLASS_REASON <<<"$row"
  reset_default
  before="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)"
  : >"$TMP/state/calls"
  run_refresh "$name" pass standard
  if refresh_stopped_at_class "$before"; then ok "$name stops before publication"; else bad "$name class stop" "$OUT"; fi
done
# Each class rule has a control on a disposable runner. Keeping the matched
# condition as a comment proves that its behavior, not its spelling, matters.
reset_default
cp "$runner" "$TMP/class-runner"
for mutation in measured arm; do
  cp "$TMP/class-runner" "$runner"
  python3 - "$runner" "$mutation" <<'CLASS_CONTROL'
from pathlib import Path
import sys
p = Path(sys.argv[1]).resolve()
s = p.read_text()
mutations = {
 'measured': ('[[ "$class_line" != "class: class=$class measured=true "* ]]', '[[ " $class_line " != *\' measured=true \'* ]]'),
 'arm': ('if [ "$class" = render ]; then\n  gh pr merge', 'if true; then\n  gh pr merge'),
}
old, new = mutations[sys.argv[2]]
assert s.count(old) == 1
changed = '# ' + old.replace('\n', '\n# ') + '\n' + s.replace(old, new)
assert changed != s
p.write_text(changed)
CLASS_CONTROL
  git -C "$repo" add -A
  git -C "$repo" commit -qm 'mutate class rule'
  git -C "$repo" push -q origin main
  MEASURED=true; CLASS_EXIT=0
  case "$mutation" in
    measured) MEASURED=false; CLASS_REASON='cause=render-path-unowned path=.claude/skills/helper measured=true extra/SKILL.md' ;;
    arm) CLASS_REASON='cause=excluded-path path=.agents/skills/commit-guards/scripts/install-git-hooks glob=*skills/commit-guards/scripts/*' ;;
  esac
  before="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)"
  : >"$TMP/state/calls"
  run_refresh "control-$mutation" pass standard
  if [ "$mutation" = arm ]; then
    if [ "$RC" -eq 0 ] && ! refresh_class_matches standard pushed no "$CLASS_REASON" PATCH; then
      ok 'control: standard arm breaks the class assertion'
    else bad 'standard arm control' "$OUT"; fi
  else
    if [ "$RC" -eq 0 ] && grep -qxF 'refresh-state=pushed pr=1 class=standard' <<<"$OUT" && ! refresh_stopped_at_class "$before"; then
      ok "control: $mutation bypass breaks the class stop assertion"
    else bad "$mutation class stop control" "$OUT"; fi
  fi
  reset_default
done
cp "$TMP/class-runner" "$runner"
git -C "$repo" add -A
git -C "$repo" commit -qm 'restore class rules'
git -C "$repo" push -q origin main
MEASURED=true; CLASS_EXIT=0; CLASS_REASON='cause=renders-match-their-sources'
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
creates_before="$(wc -l <"$TMP/state/creates" | tr -d ' ')"
run_refresh stale pass render
if [ "$RC" -eq 0 ] && [ "$(wc -l <"$TMP/state/creates" | tr -d ' ')" -gt "$creates_before" ]; then ok 'control exposes duplicate pull creation'; else bad 'control exposes duplicate pull creation' "$OUT"; fi
# Keep the report runner in a distinct default-branch checkout. Refresh can
# install orch for the first time, replace its parser, or remove it entirely.
reset_default
cp "$TMP/class-runner" "$runner"
printf '[env]\nORCH_OVERSEER_PREFERENCE = "claude:1:high"\n' >"$repo/kendex.settings.toml"
commit "$repo"
git -C "$repo" push -q origin main
git -C "$repo" worktree add --detach "$TMP/settings-trusted" HEAD
runner="$TMP/settings-trusted/.agents/skills/review-gate/scripts/refresh-consumer.sh"
cp "$runner" "$TMP/boundary-runner"
cp -R "$repo/.agents/skills/orch" "$TMP/release-orch"
FRESH_ORCH="$TMP/release-orch"
# The release parser reads the real setting but refuses inherited credentials.
python3 - "$FRESH_ORCH/scripts/lib/overseer-launch.sh" <<'PY_GUARD'
from pathlib import Path
import sys
p = Path(sys.argv[1]).resolve()
s = p.read_text()
old = 'ol_preference_entries() { # VALUE'
assert s.count(old) == 1
changed = s.replace(old, old + '''
  if [[ -n ${GH_TOKEN+x} || -n ${GITHUB_TOKEN+x} || -n ${TEST_SECRET+x} ]]; then
    printf 'parse-error=credential-present\\n' >&2
    return 87
  fi''')
assert changed != s
p.write_text(changed)
PY_GUARD
cp "$FRESH_ORCH/scripts/lib/overseer-launch.sh" "$TMP/release-parser"
# The preserved parser must not decide the refreshed release's answer.
printf 'exit 89\n' >>"$TMP/settings-trusted/.agents/skills/orch/scripts/lib/overseer-launch.sh"
for row in 'absent|absent' 'parser-update|install' 'first-install|install' 'token-absence|install'; do
  IFS='|' read -r name ORCH_MODE <<<"$row"
  reset_default
  if [ "$name" = first-install ]; then
    rm -rf -- "$repo/.agents/skills/orch" "$TMP/settings-trusted/.agents/skills/orch"
    commit "$repo"
    git -C "$repo" push -q origin main
  fi
  : >"$TMP/state/calls"
  run_refresh "boundary-$name" pass render
  if [ "$name" = absent ]; then
    if [ "$RC" -eq 0 ] && ! grep -qxF '## Settings' "$TMP/state/body" &&
        grep -qxF "refresh-settings=orch-absent value=$repo/.agents/skills/orch" <<<"$OUT"; then
      ok 'absent optional orch refreshes without Settings'
    else bad 'absent optional orch' "$OUT"; fi
  elif [ "$RC" -eq 0 ] && grep -qF 'deprecated entry <code>claude:1:high</code>' "$TMP/state/body"; then
    ok "$name uses the credential-free release parser"
  else bad "$name parser boundary" "$OUT"; fi
  if [ "$name" = parser-update ]; then
    python3 - "$runner" <<'PY_PARSER_CONTROL'
from pathlib import Path
import sys
p = Path(sys.argv[1]).resolve()
s = p.read_text()
for lib in ('kendex-env.sh', 'overseer-launch.sh'):
    old = 'source "$2/.agents/skills/orch/scripts/lib/' + lib + '"'
    assert s.count(old) == 1
    changed = s.replace(old, '# ' + old + '\n' + old.replace('$2/.agents/skills', '$1/../..'))
    assert changed != s
    s = changed
p.write_text(s)
PY_PARSER_CONTROL
    reset_default
    before="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)" || exit 1
    : >"$TMP/state/calls"
    run_refresh parser-update-control pass render
    if refresh_stopped_at_settings "$before" "refresh-error=settings-extraction value=$repo/.agents/skills/orch"; then
      ok 'control: preserved parser breaks the release parser assertion'
    else bad 'post-refresh parser control' "$OUT"; fi
    cp "$TMP/boundary-runner" "$runner"
  fi
  if [ "$name" = absent ]; then
    # A forced parser block must break the same successful absent-orch row.
    file_edit "$TMP/settings-trusted" .agents/skills/review-gate/scripts/refresh-consumer.sh 1 \
      '^if \[ -e "\$ROOT/.agents/skills/orch" \]' \
      's/^if \[ -e "\$ROOT\/\.agents\/skills\/orch" \].*; then$/if true; then # &/'
    reset_default
    before="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)" || exit 1
    : >"$TMP/state/calls"
    run_refresh absent-control pass render
    if refresh_stopped_at_settings "$before" "refresh-error=settings-extraction value=$repo/.agents/skills/orch"; then
      ok 'control: forced parser block breaks absent optional orch'
    else bad 'absent optional orch control' "$OUT"; fi
    cp "$TMP/boundary-runner" "$runner"
  fi
done
# Inheriting the environment exposes the token and makes the parser refuse.
python3 - "$runner" <<'PY_ENV_CONTROL'
from pathlib import Path
import sys
p = Path(sys.argv[1]).resolve()
s = p.read_text()
old = '  if ! env -i PATH="$PATH" HOME="$HOME" bash -s -- "$SCRIPT_DIR" "$ROOT" >"$TMP/settings.json" <<\'SETTINGS_PARSE\''
assert s.count(old) == 1
changed = s.replace(old, '# ' + old + '\n' + old.replace('env -i ', 'env '))
assert changed != s
p.write_text(changed)
PY_ENV_CONTROL
reset_default
before="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)" || exit 1
: >"$TMP/state/calls"
run_refresh token-control pass render
if refresh_stopped_at_settings "$before" "refresh-error=settings-extraction value=$repo/.agents/skills/orch" &&
    grep -qxF 'parse-error=credential-present' <<<"$OUT"; then
  ok 'control: inherited environment breaks token absence'
else bad 'token absence control' "$OUT"; fi
cp "$TMP/boundary-runner" "$runner"
# Unexpected parser stdout is data, never a command or a clean report.
for output in noise extra-field empty; do
  cp "$TMP/release-parser" "$FRESH_ORCH/scripts/lib/overseer-launch.sh"
  case "$output" in
    noise) printf '\nprintf "not-json\\n"\n' >>"$FRESH_ORCH/scripts/lib/overseer-launch.sh" ;;
    extra-field) printf '\nprintf '\''{"refused":[],"deprecated":[],"extra":true}\\n'\''\nexit 0\n' >>"$FRESH_ORCH/scripts/lib/overseer-launch.sh" ;;
    empty) printf '\nexit 0\n' >>"$FRESH_ORCH/scripts/lib/overseer-launch.sh" ;;
  esac
  reset_default
  before="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)" || exit 1
  : >"$TMP/state/calls"
  run_refresh "malformed-$output" pass render
  if refresh_stopped_at_settings "$before" "refresh-error=settings-output value=$repo/.agents/skills/orch"; then
    ok "$output parser output stops before publication or merge changes"
  else bad "$output parser output refusal" "$OUT"; fi
  if [ "$output" = extra-field ]; then
    file_edit "$TMP/settings-trusted" .agents/skills/review-gate/scripts/refresh-consumer.sh 1 \
      '^  if \[ "\$settings_lines" -ne 1 \] \|\|' \
      's/^  if \[ "\$settings_lines" -ne 1 \].*; then$/  if false; then # &/'
    reset_default
    : >"$TMP/state/calls"
    run_refresh malformed-control pass render
    if [ "$RC" -eq 0 ] && ! refresh_stopped_at_settings "$before" "refresh-error=settings-output value=$repo/.agents/skills/orch"; then
      ok 'control: dropped output refusal publishes malformed extraction as clean'
    else bad 'parser data validation control' "$OUT"; fi
    cp "$TMP/boundary-runner" "$runner"
  fi
done
cp "$TMP/release-parser" "$FRESH_ORCH/scripts/lib/overseer-launch.sh"
# tail and sed extract private and TOML values. Failures must name the source.
cp "$TMP/settings-lib" "$TMP/boundary-settings"
for command in tail sed; do
  real_command="$(command -v "$command")" || exit 1
  cat >"$TMP/bin/$command" <<SH
#!/usr/bin/env bash
set -euo pipefail
input="\$(cat)" || exit 1
if [[ "\$input" == *ORCH_OVERSEER_PREFERENCE* ]]; then exit 7; fi
exec "$real_command" "\$@" <<<"\$input"
SH
  chmod +x "$TMP/bin/$command"
  reset_default
  rm -f -- "$repo/.env.local" "$repo/private.env"
  source_path=kendex.settings.toml
  committed=claude:1:high
  [ "$command" != tail ] || committed=claude:fable:high
  printf '[env]\nORCH_OVERSEER_PREFERENCE = "%s"\n' "$committed" >"$repo/kendex.settings.toml"
  commit "$repo"
  git -C "$repo" push -q origin main
  if [ "$command" = tail ]; then
    source_path="$repo/.env.local"
    printf 'ORCH_OVERSEER_PREFERENCE=claude:1:high\n' >"$source_path"
  fi
  before="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)" || exit 1
  : >"$TMP/state/calls"
  run_refresh "extract-$command" pass render
  printf -v expected 'review-gate-error=settings-extract value=%q' "${source_path#"$repo/"}"
  if refresh_stopped_at_settings "$before" "refresh-error=settings-extraction value=$repo/.agents/skills/orch" &&
      grep -qxF -- "$expected" <<<"$OUT"; then
    ok "$command extraction failure names its source and stops publication"
  else bad "$command extraction failure" "$OUT"; fi
  # Dropping the class-owned error return must turn both refusal rows red.
  python3 - "$TMP/settings-trusted/.agents/skills/review-gate/scripts/lib/settings.sh" <<'PY_EXTRACT'
from pathlib import Path
import sys
p = Path(sys.argv[1]).resolve()
s = p.read_text()
a = s.index('rg_settings_extract() {')
b = s.index('\n}', a)
old = s[a:b]
assert old.count('return 2') == 1
changed = s[:a] + old.replace('return 2', 'return 0 # return 2') + s[b:]
assert changed != s
p.write_text(changed)
PY_EXTRACT
  reset_default
  : >"$TMP/state/calls"
  run_refresh "extract-$command-control" pass render
  if [ "$RC" -eq 0 ] && ! grep -qxF '## Settings' "$TMP/state/body"; then
    ok "control: ignored $command failure publishes a clean report"
  else bad "$command extraction failure control" "$OUT"; fi
  cp "$TMP/boundary-settings" "$TMP/settings-trusted/.agents/skills/review-gate/scripts/lib/settings.sh"
  rm -f -- "$TMP/bin/$command"
done
unset FRESH_ORCH ORCH_MODE
rm -f -- "$repo/.env.local" "$repo/private.env"

# Scripts from the consumer's committed pre-platform checkout must adopt
# refreshed catalog data before its PR can bring the new scripts. Fixtures
# are verbatim renders from 672eb6013185427ba9cb109fece86dbe08f668b5.
sandbox
repo="$DIR"
git -C "$repo" branch -M main
cp "$TEST_DIR/fixtures/pre-platform/"*.sh "$repo/.agents/skills/review-gate/scripts/"
chmod +x "$repo/.agents/skills/review-gate/scripts/"*.sh
# The old validator checks the engine's tracked path, never its body.
printf '#!/usr/bin/env bash\nexit 1\n' >"$repo/.agents/skills/review-gate/scripts/review-writer.sh"
cp "$SKILL_DIR/templates/review-gate-writer.yml" "$repo/.github/workflows/review-gate-writer.yml"
record_adoption "$repo" .github/workflows/review-gate-writer.yml .agents/skills/review-gate/templates/review-gate-writer.yml
cp "$TMP/case.1/.agents/skills/harness-ci/scripts/change-class" "$repo/.agents/skills/harness-ci/scripts/change-class"
commit "$repo"
git init --bare -q "$TMP/legacy-remote"
git --git-dir="$TMP/legacy-remote" config gc.auto 0
git --git-dir="$TMP/legacy-remote" config maintenance.auto false
git -C "$repo" remote add origin "$TMP/legacy-remote"
git -C "$repo" push -q origin main
git -C "$repo" worktree add --detach "$TMP/legacy-trusted" HEAD
runner="$TMP/legacy-trusted/.agents/skills/review-gate/scripts/refresh-consumer.sh"
for bridge in retained missing; do
  reset_default
  REFRESH_SKILL="$TMP/catalog-$bridge"
  cp -R "$SKILL_DIR" "$REFRESH_SKILL"
  if [ "$bridge" = missing ]; then
    rm -- "$REFRESH_SKILL/templates/review-gate-writer.yml"
  fi
  : >"$TMP/state/pr"
  : >"$TMP/state/creates"
  : >"$TMP/state/calls"
  run_refresh legacy pass standard
  if [ "$bridge" = retained ]; then
    if [ "$RC" -eq 0 ] && grep -qxF 'refresh-state=pushed pr=1 class=standard' <<<"$OUT" &&
        [ -s "$TMP/state/creates" ] && [ ! -e "$repo/.agents/skills/review-gate/scripts/validate-workflow.sh" ]; then
      ok 'pre-platform refresh opens its PR against the current catalog'
    else bad 'pre-platform refresh bridge' "$OUT"; fi
  elif [ "$RC" -eq 2 ] &&
      grep -qxF "review-gate-error=template-missing value=$repo/.agents/skills/review-gate/templates/review-gate-writer.yml" <<<"$OUT" &&
      [ ! -s "$TMP/state/creates" ] && ! grep -qE '^api --method (POST|PATCH)|^pr merge ' "$TMP/state/calls"; then
    ok 'control: removing the bridge fails old refresh at template-missing'
  else bad 'pre-platform bridge removal control' "$OUT"; fi
done
unset REFRESH_SKILL

# The shipped workflow preserves a trusted checkout before refresh replaces
# catalog files. Real adoption must read new template bytes without executing
# refreshed adoption code, including for a renamed writer. Only orch's read-only
# parse runs from the refreshed tree, without the app credential.
sandbox
repo="$DIR"
git -C "$repo" branch -M main
printf 'retired workflow\n' >"$repo/.github/workflows/gate.yml"
record_adoption "$repo" .github/workflows/gate.yml .agents/skills/review-gate/templates/review-gate-writer.yml
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
printf '\n# fresh refresh template\n' >>"$TMP/fresh-templates/kendex-refresh.yml"
: >"$TMP/state/pr"
: >"$TMP/state/creates"
HOSTILE=1
run_refresh refreshed pass render
warning_count="$(awk '/^refresh-warning=legacy-writer / { count++ } END { print count + 0 }' <<<"$OUT")" || exit 1
if [ "$RC" -eq 0 ] && [ ! -e "$TMP/state/hostile" ] &&
    retirement_matches "$repo" .github/workflows/gate.yml .agents/skills/review-gate/templates/review-gate-writer.yml preserved &&
    [ "$warning_count" -eq 1 ] && grep -qxF 'refresh-warning=legacy-writer value=.agents/skills/review-gate/templates/review-gate-writer.yml' <<<"$OUT" &&
    cmp -s "$repo/.github/workflows/kendex-refresh.yml" "$TMP/fresh-templates/kendex-refresh.yml" &&
    python3 - "$repo" <<'INVENTORY'
import hashlib,json,sys
from pathlib import Path
root=Path(sys.argv[1]); entries=json.loads((root/'.kendex-generated.json').read_text())
assert {e['path'] for e in entries}=={'.github/workflows/kendex-refresh.yml', '.github/workflows/gate.yml'}
for entry in (e for e in entries if e['path'] == '.github/workflows/kendex-refresh.yml'):
 assert entry['templateHash']=='sha256:'+hashlib.sha256((root/entry['path']).read_bytes()).hexdigest()
 assert (root/entry['path']).read_bytes()==(root/entry['template']).read_bytes()
INVENTORY
then ok 'automatic adoption reads fresh templates and keeps the retired writer and record without executing refreshed code'
else bad 'automatic adoption boundary and fresh data' "$OUT"; fi
# A hand edit committed on the default branch must reach the rolling body's
# own section, even when adoption produces the same rolling tree as before.
reset_default
cp "$repo/.agents/skills/review-gate/templates/kendex-refresh.yml" "$repo/.github/workflows/kendex-refresh.yml"
file_edit "$repo" .github/workflows/kendex-refresh.yml 1 '^name: ' 's/^name: .*/name: consumer edit/'
commit "$repo"
git -C "$repo" push -q origin main
run_refresh refreshed pass render
if workflow_edit_matches "$TMP/state/body" '.github/workflows/kendex-refresh.yml:8' &&
    grep -qxF 'refresh-state=unchanged pr=1 class=render' <<<"$OUT" &&
    cmp -s "$repo/.github/workflows/kendex-refresh.yml" "$TMP/fresh-templates/kendex-refresh.yml"; then
  ok 'hand-edit adoption warns once and updates the unchanged rolling pull request body with its first divergence'
else bad 'workflow edit body publication' "$OUT"; fi
cp "$runner" "$TMP/body-runner"
file_edit "$TMP/trusted" .agents/skills/review-gate/scripts/refresh-consumer.sh 1 '^if \[ -n "\$workflow_edits" \]; then$' \
  's/^if \[ -n "\$workflow_edits" \]; then$/if false; then # if [ -n "$workflow_edits" ]; then/'
reset_default
run_refresh refreshed pass render
if [ "$RC" -eq 0 ] && grep -q '^refresh-warning=workflow-edited value=' <<<"$OUT" &&
    ! workflow_edit_matches "$TMP/state/body" '.github/workflows/kendex-refresh.yml:8'; then
  ok 'control: skipped body section breaks the workflow edit publication assertion'
else bad 'workflow edit body control' "$OUT"; fi
cp "$TMP/body-runner" "$runner"
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
# The CLI producer succeeds on a hold. The runner must read its ledger,
# discard only a fully classified set, then retain verify as the final gate.
if [ -z "$REAL_KENDEX" ]; then
  printf '  SKIP: real held-render consumer rows need kendex on PATH\n'
else
  cat >"$TMP/bin/kendex" <<'REAL_KENDEX_SH'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$TEST_STATE/kendex"
if [ "$TEST_KENDEX_OUTPUT" = failed ] && [ "$1" = refresh ]; then
  printf 'catalog read failed\n' >&2
  exit 17
fi
if [ "$TEST_KENDEX_OUTPUT" = truncated ] && [ "$1" = refresh ]; then
  # A lost held-item record must never authorize a discard pass.
  "$TEST_REAL_KENDEX" "$@" 2>&1 | sed '/^  .*: edited on disk since install /d'
else
  exec "$TEST_REAL_KENDEX" "$@"
fi
REAL_KENDEX_SH
  for row in local upstream shared body-control; do
    real_refresh_fixture "$row"
    expected_edits='.agents/skills/probe/SKILL.md'
    expected_holds='skill probe for Claude Code: edited on disk since install — keep it as a fork, or apply with edits discarded'
    if [ "$row" = upstream ]; then
      printf 'New upstream content.\n' >>"$real_root/git/owner/catalog/skills/probe/SKILL.md"
      commit "$real_root/git/owner/catalog"
      expected_holds='skill probe for Claude Code: edited on disk and changed upstream — keep your edits as a fork, or apply with edits discarded'
    elif [ "$row" = shared ]; then
      file_edit "$repo" kendex.toml 1 '^harnesses = \["claude"\]$' \
        's/harnesses = \["claude"\]/harnesses = ["claude", "pi"]/'
      expected_holds="$expected_holds
skill probe for Pi: its files were edited on disk after another tool installed them — keep the edits as a fork, or apply with edits discarded"
    else
      mkdir -p "$real_root/git/owner/catalog/skills/second"
      cp "$real_root/git/owner/catalog/skills/probe/SKILL.md" "$real_root/git/owner/catalog/skills/second/SKILL.md"
      file_edit "$real_root/git/owner/catalog" skills/second/SKILL.md 1 '^name: probe$' 's/^name: probe$/name: second/'
      commit "$real_root/git/owner/catalog"
      printf '\n[skills.second]\nsource = "cat"\n' >>"$repo/kendex.toml"
      (cd -- "$repo" && env -i PATH="$PATH" HOME="$real_root/home" KENDEX_REAL_HOME=1 \
        GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
        KENDEX_GIT_BASE="file://$real_root/git" KENDEX_UI=plain "$REAL_KENDEX" refresh --scope project --yes --leave)
      printf 'Hand edit.\n' >>"$repo/.agents/skills/second/SKILL.md"
      expected_holds="$expected_holds
skill second for Claude Code: edited on disk since install — keep it as a fork, or apply with edits discarded"
      expected_edits="$expected_edits
.agents/skills/second/SKILL.md"
    fi
    publish_real_fixture
    if [ "$row" = body-control ]; then
      python3 - "$runner" <<'BODY_CONTROL'
from pathlib import Path
import sys
p = Path(sys.argv[1]).resolve()
s = p.read_text()
old = '        held_items="$held_items- ${line#  }'
assert s.count(old) == 1
changed = s.replace(old, '        held_items="" # reset accumulator\n' + old)
assert changed != s
p.write_text(changed)
BODY_CONTROL
      commit "$repo"
      git -C "$repo" push -q origin main
    fi
    run_real_refresh
    if [ "$row" = body-control ]; then
      if [ "$RC" -eq 0 ] && ! real_refresh_published; then
        ok 'control: resetting the accumulator breaks the complete body assertion'
      else bad 'held-item body control' "$OUT"; fi
    elif real_refresh_published; then ok "$row hand edits refresh and their pull request lists every held record"
    else bad "$row real consumer publication" "$OUT"; fi
  done
  real_refresh_fixture no-discard
  publish_real_fixture
  # Only the disposable runner changes; the tracked source is never mutated.
  python3 - "$runner" <<'DISCARD_CONTROL'
from pathlib import Path
import sys
p = Path(sys.argv[1]).resolve()
s = p.read_text()
old = '  kendex refresh --scope project --yes --leave --discard-edits'
assert s.count(old) == 1
changed = s.replace(old, '  : # ' + old.strip())
assert changed != s
p.write_text(changed)
DISCARD_CONTROL
  commit "$repo"
  git -C "$repo" push -q origin main
  run_real_refresh
  if [ "$RC" -eq 1 ] && ! real_refresh_published &&
      grep -qxF 'verify --scope project' "$TMP/state/kendex" &&
      grep -qF '✗ skill probe [claude]: edited on disk since install' <<<"$OUT" &&
      [ ! -s "$TMP/state/creates" ]; then
    ok 'control: removing discard reaches verify and fails on the held row'
  else bad 'discard control' "$OUT"; fi
  # An unmanaged render is another real CLI conflict producer. It is not a
  # hold from holds.rs, even when the same run also holds a hand-edited item.
  for row in non-hold mixed same-unmanaged same-orphan truncated failed count-control record-control; do
    real_refresh_fixture "$row"
    KENDEX_OUTPUT=normal
    case "$row" in
      non-hold | mixed)
        mkdir -p "$real_root/git/owner/catalog/skills/unmanaged" "$repo/.agents/skills/unmanaged"
        cp "$real_root/git/owner/catalog/skills/probe/SKILL.md" "$real_root/git/owner/catalog/skills/unmanaged/SKILL.md"
        file_edit "$real_root/git/owner/catalog" skills/unmanaged/SKILL.md 1 '^name: probe$' 's/^name: probe$/name: unmanaged/'
        commit "$real_root/git/owner/catalog"
        printf '\n[skills.unmanaged]\nsource = "cat"\n' >>"$repo/kendex.toml"
        printf 'Unmanaged content.\n' >"$repo/.agents/skills/unmanaged/SKILL.md"
        expected_error='refresh-error=conflict-record value=skill unmanaged for Claude Code: '
        if [ "$row" = non-hold ]; then
          sed '/^Hand edit\.$/d' "$repo/.agents/skills/probe/SKILL.md" >"$real_root/unedited"
          cp "$real_root/unedited" "$repo/.agents/skills/probe/SKILL.md"
        fi ;;
      same-unmanaged | same-orphan | record-control)
        mkdir -p "$real_root/git/owner/catalog/agents"
        printf '%s\n' '---' 'name: writer' 'description: fixture agent' '---' 'Upstream content.' >"$real_root/git/owner/catalog/agents/writer.md"
        commit "$real_root/git/owner/catalog"
        if [ "$row" = same-orphan ]; then
          file_edit "$repo" kendex.toml 1 '^harnesses = \["claude"\]$' \
            's/harnesses = \["claude"\]/harnesses = ["claude", "codex"]/'
        fi
        printf '\n[agents.writer]\nsource = "cat"\n' >>"$repo/kendex.toml"
        (cd -- "$repo" && env -i PATH="$PATH" HOME="$real_root/home" KENDEX_REAL_HOME=1 \
          GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
          KENDEX_GIT_BASE="file://$real_root/git" KENDEX_UI=plain "$REAL_KENDEX" refresh --scope project --yes --leave)
        printf 'Hand edit.\n' >>"$repo/.claude/agents/writer.md"
        if [ "$row" = same-orphan ]; then
          printf '\n# Hand edit.\n' >>"$repo/.codex/agents/writer.toml"
          file_edit "$repo" kendex.toml 1 '^harnesses = \["claude", "codex"\]$' \
            's/harnesses = \["claude", "codex"\]/harnesses = ["claude"]/'
          expected_error='refresh-error=conflict-record value=agent writer for Codex: no longer wanted, but its files were edited on disk'
        else
          mkdir -p "$repo/.codex/agents"
          printf '# Unmanaged content.\n' >"$repo/.codex/agents/writer.toml"
          file_edit "$repo" kendex.toml 1 '^harnesses = \["claude"\]$' \
            's/harnesses = \["claude"\]/harnesses = ["claude", "codex"]/'
          expected_error='refresh-error=conflict-record value=agent writer for Codex: '
        fi ;;
      truncated | count-control)
        KENDEX_OUTPUT=truncated
        expected_error='refresh-error=conflict-count value=1 held=0' ;;
      failed)
        KENDEX_OUTPUT=failed
        expected_error='refresh-error=refresh value=17' ;;
    esac
    publish_real_fixture
    if [ "$row" = count-control ]; then
      python3 - "$runner" <<'COUNT_CONTROL'
from pathlib import Path
import sys
p = Path(sys.argv[1]).resolve()
s = p.read_text()
old = 'if [ "${conflict_count:-0}" != "$held_count" ]; then'
assert s.count(old) == 1
changed = s.replace(old, 'if false; then # ' + old)
assert changed != s
p.write_text(changed)
COUNT_CONTROL
      commit "$repo"
      git -C "$repo" push -q origin main
    elif [ "$row" = record-control ]; then
      python3 - "$runner" <<'RECORD_CONTROL'
from pathlib import Path
import sys
p = Path(sys.argv[1]).resolve()
s = p.read_text()
old = '            exit 1 ;;\n        esac'
assert s.count(old) == 1
changed = s.replace(old, '            continue ;; # ' + old.splitlines()[0].strip() + '\n        esac')
assert changed != s
p.write_text(changed)
RECORD_CONTROL
      commit "$repo"
      git -C "$repo" push -q origin main
    fi
    run_real_refresh
    if [ "$row" = count-control ] || [ "$row" = record-control ]; then
      if ! real_refresh_stopped "$expected_error" &&
          grep -qxF 'refresh --scope project --yes --leave --discard-edits' "$TMP/state/kendex"; then
        ok "control: $row bypass permits an unauthorized discard"
      else bad 'conflict count control' "$OUT"; fi
    elif real_refresh_stopped "$expected_error"; then
      if { grep -qF 'Hand edit.' "$repo/.agents/skills/probe/SKILL.md" || [ "$row" = non-hold ]; } &&
          { { [ "$row" != same-unmanaged ] && [ "$row" != same-orphan ]; } || grep -qF 'Hand edit.' "$repo/.claude/agents/writer.md"; } &&
          { [ "$row" != same-orphan ] || grep -qF '# Hand edit.' "$repo/.codex/agents/writer.toml"; }; then
        ok "$row stops before any discard or publication"
      else bad "$row preserved edit" "$OUT"; fi
    else bad "$row refusal" "$OUT"; fi
  done
fi
printf 'pass=%s fail=%s\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
