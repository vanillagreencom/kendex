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
query=""
for arg in "$@"; do
  case "$arg" in
    body=*) printf '%s\n' "${arg#body=}" >"$TEST_STATE/body" ;;
    query=*) query="${arg#query=}" ;;
  esac
done
case "$*" in
  'api repos/acme/test --jq .default_branch') printf 'main\n' ;;
  api\ --paginate\ *pulls*) cat "$TEST_STATE/pr" ;;
  api\ users/*) printf '123\n' ;;
  'api --method POST repos/acme/test/pulls '*) printf '1\n' >"$TEST_STATE/pr"; printf 'created\n' >>"$TEST_STATE/creates"; printf '1\n' ;;
  'api --method PATCH repos/acme/test/pulls/1 '*) : ;;
  'api repos/acme/test/pulls?state=open&'*) cat "$TEST_STATE/pr" ;;
  'api graphql '*)
    [ -f "$TEST_STATE/push-refused" ] || [ -f "$TEST_STATE/disable-refused" ] || exit 89
    [ "${TEST_PUSH_QUERY:-pass}" != fail ] || exit 87
    # GitHub returns only requested fields. Never supply a complete fixture
    # to a query that omits the branch or pull-request state selections.
    for selection in \
      'ref(qualifiedName: "refs/heads/kendex/refresh") { target { oid } }' \
      'pullRequest(number: $number) @include(if: $hasPR) { state isInMergeQueue autoMergeRequest { enabledAt } }'; do
      case "$query" in *"$selection"*) ;; *) exit 86 ;; esac
    done
    cat "$TEST_STATE/push-state.json" ;;
  'auth setup-git') : >"$TEST_STATE/auth" ;;
  'pr merge '*)
    case " $* " in
      *' --auto '*) : >"$TEST_STATE/armed" ;;
      *' --disable-auto '*)
        if [ "${TEST_DISABLE_MODE:-normal}" = refused ]; then
          : >"$TEST_STATE/disable-refused"
          printf "GraphQL: Can't disable auto-merge for this pull request. (disablePullRequestAutoMerge)\n" >&2
          exit 1
        fi
        rm -f -- "$TEST_STATE/armed" ;;
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
  --version) printf 'kendex 7.8.9 (release-build)\n'; exit "${TEST_VERSION_EXIT:-0}" ;;
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
if [ "${1:-}" = push ]; then
  printf 'git push\n' >>"$TEST_STATE/calls"
  case "${TEST_PUSH_MODE:-normal}" in
    queued)
      : >"$TEST_STATE/push-refused"
      printf 'remote: error: GH006: Protected branch update failed for refs/heads/kendex/refresh\n' >&2
      exit 1 ;;
    deleted)
      "$TEST_REAL_GIT" --git-dir="$TEST_LEASE_REMOTE" update-ref -d refs/heads/kendex/refresh ;;
    failure)
      : >"$TEST_STATE/push-refused"
      printf 'fatal: unable to access remote: connection refused\n' >&2
      exit 73 ;;
    normal) ;;
    *) exit 2 ;;
  esac
  : >"$TEST_STATE/push-refused"
fi
if [ "${1:-}" = push ] && [ -n "${TEST_LEASE_RACE:-}" ]; then
  old="$("$TEST_REAL_GIT" --git-dir="$TEST_LEASE_REMOTE" rev-parse refs/heads/kendex/refresh)"
  tree="$("$TEST_REAL_GIT" rev-parse 'main^{tree}')"
  competing="$(GIT_AUTHOR_NAME=competitor GIT_AUTHOR_EMAIL=competitor@example.invalid GIT_COMMITTER_NAME=competitor GIT_COMMITTER_EMAIL=competitor@example.invalid "$TEST_REAL_GIT" commit-tree "$tree" -p "$old" -m competitor)"
  "$TEST_REAL_GIT" --git-dir="$TEST_LEASE_REMOTE" fetch -q "$PWD" "$competing"
  "$TEST_REAL_GIT" --git-dir="$TEST_LEASE_REMOTE" update-ref refs/heads/kendex/refresh "$competing" "$old"
  printf '%s\n' "$competing" >"$TEST_STATE/competing"
fi
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
printf '#!/usr/bin/env bash\nset -euo pipefail\n: >"$TEST_STATE/adopted"\n' >"$repo/.agents/skills/review-gate/scripts/adopt-refresh.sh"
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
printf '{"data":{"repository":{"ref":{"target":{"oid":"abc"}},"pullRequest":{"state":"OPEN","isInMergeQueue":false,"autoMergeRequest":null}}}}\n' >"$TMP/state/push-state.json"
runner="$repo/.agents/skills/review-gate/scripts/refresh-consumer.sh"

run_refresh current pass render
if [ "$RC" -eq 0 ] && [ ! -s "$TMP/state/creates" ] && grep -qxF 'refresh-state=current pr=none class=none' <<<"$OUT"; then ok 'current consumer opens no pull request'; else bad 'current consumer opens no pull request' "$OUT"; fi
if grep -qxF 'Engine version: `kendex 7.8.9 (release-build)`.' "$TMP/state/summary"; then ok 'current run summary reports the exact engine version'; else bad 'current run engine version missing'; fi
reset_default
run_refresh stale pass render
first="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)"
if [ "$RC" -eq 0 ] && [ "$(wc -l <"$TMP/state/creates" | tr -d ' ')" -eq 1 ]; then ok 'stale consumer opens one rolling pull request'; else bad 'stale consumer opens one rolling pull request' "$OUT"; fi
if grep -qxF 'Engine version: `kendex 7.8.9 (release-build)`.' "$TMP/state/body"; then ok 'pushed body reports the exact engine version'; else bad 'pushed body engine version missing'; fi
reset_default
run_refresh stale pass render
second="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)"
if [ "$RC" -eq 0 ] && [ "$first" = "$second" ] && [ "$(wc -l <"$TMP/state/creates" | tr -d ' ')" -eq 1 ]; then ok 'repeat keeps one pull request and its commit'; else bad 'repeat keeps one pull request and its commit' "$OUT"; fi
cp "$TMP/state/body" "$TMP/clean-body"
# GitHub reads a published version line. A failed CLI version read must stop
# publication, not leave that line blank or report the selected release tag.
reset_default
VERSION_EXIT=73
before="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)"
: >"$TMP/state/calls"
run_refresh version-failure pass render
if [ "$RC" -eq 1 ] && grep -qxF 'refresh-error=read value=engine-version' <<<"$OUT" &&
    [ "$before" = "$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)" ] &&
    ! grep -qE '^api --method (POST|PATCH)|^pr merge ' "$TMP/state/calls"; then
  ok 'failed engine version read stops publication'
else bad 'failed engine version read' "$OUT"; fi
unset VERSION_EXIT
reset_default
cp "$runner" "$TMP/version-runner"
for mutation in body summary failure; do
  reset_default
  cp "$TMP/version-runner" "$runner"
  case "$mutation" in
    body)
      file_edit "$repo" .agents/skills/review-gate/scripts/refresh-consumer.sh 1 '^printf -v body ' \
        's/"\$version_report"/""/' ;;
    summary)
      file_edit "$repo" .agents/skills/review-gate/scripts/refresh-consumer.sh 1 '^  printf .*GITHUB_STEP_SUMMARY' \
        's/"\$version_report"/""/' ;;
    failure)
      file_edit "$repo" .agents/skills/review-gate/scripts/refresh-consumer.sh 1 '^if ! engine_version=' \
        '/^if ! engine_version=/,/^fi$/s/exit 1/: # exit 1/' ;;
  esac
  commit "$repo"
  git -C "$repo" push -q origin main
  content=version-control
  [ "$mutation" != summary ] || content=current
  [ "$mutation" != failure ] || VERSION_EXIT=73
  run_refresh "$content" pass render
  case "$mutation" in
    body | summary)
      if [ "$RC" -eq 0 ] && ! grep -qxF 'Engine version: `kendex 7.8.9 (release-build)`.' "$TMP/state/$mutation"; then
        ok "control: dropped $mutation version turns its assertion red"
      else bad "$mutation version control" "$OUT"; fi ;;
    failure)
      if [ "$RC" -eq 0 ] && grep -qxF 'refresh-error=read value=engine-version' <<<"$OUT"; then
        ok 'control: bypassed version failure turns the stop assertion red'
      else bad 'version failure control' "$OUT"; fi ;;
  esac
  unset VERSION_EXIT
done
reset_default
cp "$TMP/version-runner" "$runner"
commit "$repo"
git -C "$repo" push -q origin main
# Committed settings and private overrides are real consumer inputs. Neither
# the parse nor the report is doubled in these rolling-refresh fixtures. A
# private Fable override stays clean: only committed settings are scanned.
for row in \
  'claude:1:high||deprecated|claude:1:high' \
  'claude:opus:high||clean|' \
  'claude:opus:high|codex:2:low|deprecated|codex:2:low' \
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
# A committed Fable or Astra pin is a warning: the run publishes and arms as a
# clean render does. Comments, other tables and clean values add no row.
cp "$runner" "$TMP/models-runner"
cp "$repo/kendex.settings.toml" "$TMP/models-settings"
for mode in report control; do
  reset_default
  cat >"$repo/kendex.settings.toml" <<'TOML'
[env]
ORCH_OVERSEER_PREFERENCE = "claude:opus:high"
# SECOND_OPINION_CODEX_MODEL = "gpt-6-astra"
SECOND_OPINION_CODEX_CMD = "codex exec -m gpt-6-astra" # pinned
SECOND_OPINION_CLAUDE_MODEL = "claude-opus-5-5"
REVIEW_MODEL = "FaBlE"
[other]
OTHER_MODEL = "fable"
TOML
  if [ "$mode" = control ]; then
    file_edit "$repo" .agents/skills/review-gate/scripts/refresh-consumer.sh 1 \
      '^      deprecated_models\+=\(' 's/^      deprecated_models+=(/      : # &/'
  fi
  commit "$repo"
  git -C "$repo" push -q origin main
  rm -f -- "$repo/.env.local" "$TMP/state/armed"
  : >"$TMP/state/calls"
  run_refresh "models-$mode" pass render
  rows="$(grep -F -- '- <code>' "$TMP/state/body")" || rows=""
  if [ "$mode" = report ]; then
    printf -v expected '%s\n%s' \
      '- <code>SECOND_OPINION_CODEX_CMD = &quot;codex exec -m gpt-6-astra&quot;</code>' \
      '- <code>REVIEW_MODEL = &quot;FaBlE&quot;</code>'
    if refresh_class_matches render pushed yes cause=renders-match-their-sources PATCH &&
        grep -qxF '## Deprecated models' "$TMP/state/body" && [ "$rows" = "$expected" ] &&
        ! grep -qxF '## Settings' "$TMP/state/body"; then
      ok 'committed Fable and Astra pins appear under Deprecated models and the render still arms'
    else bad 'deprecated model report' "$OUT"; fi
  elif [ "$RC" -eq 0 ] && ! grep -qxF '## Deprecated models' "$TMP/state/body"; then
    ok 'control: dropped model scan turns the Deprecated models assertion red'
  else bad 'deprecated model scan control' "$OUT"; fi
  reset_default
  cp "$TMP/models-runner" "$runner"
done
cp "$TMP/models-settings" "$repo/kendex.settings.toml"
commit "$repo"
git -C "$repo" push -q origin main
# A consumer without committed settings keeps the clean body. A run with no
# render change opens no pull request, so its run summary carries the warning.
cp "$runner" "$TMP/summary-runner"
for mode in absent absent-control current current-control; do
  reset_default
  cp "$TMP/summary-runner" "$runner"
  case "$mode" in
    absent*) rm -f -- "$repo/kendex.settings.toml" ;;
    current*) printf '[env]\nSECOND_OPINION_CODEX_CMD = "codex exec -m gpt-6-astra"\n' >"$repo/kendex.settings.toml" ;;
  esac
  case "$mode" in
    absent-control)
      file_edit "$repo" .agents/skills/review-gate/scripts/refresh-consumer.sh 1 \
        '^if \[ -f kendex\.settings\.toml \]; then$' 's/^if \[ -f kendex\.settings\.toml \]; then$/if true; then # &/' ;;
    current-control)
      file_edit "$repo" .agents/skills/review-gate/scripts/refresh-consumer.sh 1 \
        '^  \[ -z "\$settings_report" \] \|\| ' 's/^  \[ -z "\$settings_report" \] || /  : # &/' ;;
  esac
  commit "$repo"
  git -C "$repo" push -q origin main
  rm -f -- "$repo/.env.local"
  before="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)"
  : >"$TMP/state/calls"
  case "$mode" in
    absent*) run_refresh stale pass render ;;
    current*) run_refresh current pass render ;;
  esac
  case "$mode" in
    absent)
      if [ "$RC" -eq 0 ] && cmp -s "$TMP/clean-body" "$TMP/state/body"; then
        ok 'absent committed settings leave the whole body unchanged'
      else bad 'absent committed settings body' "$OUT"; fi ;;
    absent-control)
      if refresh_stopped_at_settings "$before" "refresh-error=settings-extraction value=$repo/.agents/skills/orch"; then
        ok 'control: an unguarded scan of absent settings turns the clean-body assertion red'
      else bad 'absent settings guard control' "$OUT"; fi ;;
    current)
      if [ "$RC" -eq 0 ] && grep -qxF 'refresh-state=current pr=none class=none' <<<"$OUT" &&
          grep -qxF 'Engine version: `kendex 7.8.9 (release-build)`.' "$TMP/state/summary" &&
          grep -qxF '## Deprecated models' "$TMP/state/summary" &&
          grep -qxF -- '- <code>SECOND_OPINION_CODEX_CMD = &quot;codex exec -m gpt-6-astra&quot;</code>' "$TMP/state/summary"; then
        ok 'a run with no render change reports the Astra pin in its run summary'
      else bad 'no-change deprecated model summary' "$OUT"; fi ;;
    current-control)
      if [ "$RC" -eq 0 ] && grep -qxF 'refresh-state=current pr=none class=none' <<<"$OUT" &&
          ! grep -qxF '## Deprecated models' "$TMP/state/summary"; then
        ok 'control: a dropped summary append turns the no-change warning assertion red'
      else bad 'no-change summary append control' "$OUT"; fi ;;
  esac
done
reset_default
cp "$TMP/summary-runner" "$runner"
cp "$TMP/models-settings" "$repo/kendex.settings.toml"
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
# A remote head can change after the runner reads its lease. The real Git
# remote must keep the competitor, with no pull request or merge call.
for row in lease lease-control; do
  reset_default
  runner="$repo/.agents/skills/review-gate/scripts/refresh-consumer.sh"
  if [ "$row" = lease-control ]; then
    python3 - "$runner" <<'LEASE_CONTROL'
from pathlib import Path
import sys
p=Path(sys.argv[1]).resolve(); s=p.read_text()
old='"--force-with-lease=refs/heads/kendex/refresh:$old"'; assert s.count(old)==1
changed='# '+old+'\n'+s.replace(old,'--force'); assert changed != s; p.write_text(changed)
LEASE_CONTROL
    commit "$repo"
    git -C "$repo" push -q origin main
  fi
  LEASE_RACE=1
  : >"$TMP/state/calls"
  run_refresh "$row" pass render
  after="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)"
  competing="$(cat "$TMP/state/competing")"
  if [ "$row" = lease ]; then
    if [ "$RC" -ne 0 ] && [ "$after" = "$competing" ] &&
        ! grep -qE '^api --method (POST|PATCH)|^pr merge .*--auto' "$TMP/state/calls"; then
      ok 'lease refuses a competing remote head before publication'
    else bad 'lease competing head' "$OUT"; fi
  elif [ "$RC" -eq 0 ] && [ "$after" != "$competing" ]; then
    ok 'control: force without lease replaces the competing head'
  else bad 'lease control' "$OUT"; fi
  unset LEASE_RACE
  reset_default
  cp "$TMP/class-runner" "$runner"
  commit "$repo"
  git -C "$repo" push -q origin main
done
# GitHub can own the rolling branch after fetch, even with serialized runs.
# Every state fixture is consumed only after the Git push refusal.
cp "$runner" "$TMP/push-runner"
push_head="$(git --git-dir="$TMP/remote" rev-parse refs/heads/kendex/refresh)"
for row in \
  'queued|queued|OPEN|true|false|present|0|queued' \
  'armed|queued|OPEN|false|true|present|0|armed' \
  'merged-deleted|deleted|MERGED|false|false|gone|0|merged' \
  'closed|queued|CLOSED|false|false|present|0|closed' \
  'branch-gone|deleted|OPEN|false|false|gone|0|branch-gone' \
  'genuine-failure|failure|OPEN|false|false|present|1|active' \
  'branch-gone-no-pr|deleted|OPEN|false|false|gone|0|branch-gone' \
  'new-branch-failure|failure|OPEN|false|false|gone|1|active' \
  'query-failure|queued|OPEN|true|false|present|1|query' \
  'partial-response|queued|OPEN|true|false|present|1|output' \
  'missing-field|queued|OPEN|true|false|present|1|output' \
  'malformed-response|queued|OPEN|true|false|present|1|output'; do
  IFS='|' read -r name PUSH_MODE pr_state queued armed branch expected reason <<<"$row"
  reset_default
  git --git-dir="$TMP/remote" update-ref refs/heads/kendex/refresh "$push_head"
  printf '1\n' >"$TMP/state/pr"
  case "$name" in
    branch-gone-no-pr|new-branch-failure) : >"$TMP/state/pr" ;;
  esac
  if [ "$name" = new-branch-failure ]; then
    git --git-dir="$TMP/remote" update-ref -d refs/heads/kendex/refresh
  fi
  PUSH_QUERY=pass
  [ "$name" != query-failure ] || PUSH_QUERY=fail
  jq -cn --arg state "$pr_state" --argjson queued "$queued" --argjson armed "$armed" --arg branch "$branch" \
    '{data:{repository:{ref:(if $branch == "gone" then null else {target:{oid:"abc"}} end),pullRequest:{state:$state,isInMergeQueue:$queued,autoMergeRequest:(if $armed then {enabledAt:"2026-10-02T01:09:07Z"} else null end)}}}}' >"$TMP/state/push-state.json"
  case "$name" in
    branch-gone-no-pr|new-branch-failure) jq 'del(.data.repository.pullRequest)' "$TMP/state/push-state.json" >"$TMP/partial"; mv "$TMP/partial" "$TMP/state/push-state.json" ;;
    partial-response) jq '. + {errors:[{message:"permission denied"}]}' "$TMP/state/push-state.json" >"$TMP/partial"; mv "$TMP/partial" "$TMP/state/push-state.json" ;;
    missing-field) jq 'del(.data.repository.pullRequest.isInMergeQueue)' "$TMP/state/push-state.json" >"$TMP/partial"; mv "$TMP/partial" "$TMP/state/push-state.json" ;;
    malformed-response) printf 'not-json\n' >"$TMP/state/push-state.json" ;;
  esac
  : >"$TMP/state/calls"
  run_refresh "push-$name" pass render
  if refresh_push_matches "$expected" "$reason"; then ok "$name post-refusal state"; else bad "$name post-refusal state" "$OUT"; fi
  # Each acceptance path and the failure path has a planted behavior defect.
  # Copies keep the tracked script untouched and retain the matched condition.
  mutations=""
  case "$name" in
    queued) mutations='defer ordering queue-field' ;;
    merged-deleted) mutations=defer ;;
    genuine-failure) mutations=fail-open ;;
    new-branch-failure) mutations=no-old ;;
    query-failure) mutations=query-open ;;
    partial-response) mutations=output-open ;;
  esac
  for mutation in $mutations; do
    reset_default
    python3 - "$runner" "$mutation" <<'PUSH_CONTROL'
from pathlib import Path
import sys
p = Path(sys.argv[1]).resolve()
s = p.read_text()
mutations = {
    'defer': ('if [ "$reason" != active ]; then', 'if false; then'),
    'fail-open': ('if [ "$reason" != active ]; then', 'if true; then'),
    'query-open': ("printf 'refresh-error=push-state value=query\\n' >&2\n    exit 1", "printf 'refresh-error=push-state value=query\\n' >&2\n    exit 0"),
    'output-open': ("printf 'refresh-error=push-state value=output\\n' >&2\n    exit 1", "printf 'refresh-error=push-state value=output\\n' >&2\n    exit 0"),
    'ordering': ('  push_status=0', "  gh api graphql -f query='query { viewer { login } }'\n  push_status=0"),
    'queue-field': ('{ state isInMergeQueue autoMergeRequest { enabledAt } }', '{ state autoMergeRequest { enabledAt } }'),
    'no-old': ('elif .ref == null and $old != "" then "branch-gone"', 'elif .ref == null then "branch-gone"'),
}
old, new = mutations[sys.argv[2]]
assert s.count(old) == 1
if sys.argv[2] == 'queue-field':
    # Retain the selection outside the query argument, not in its payload.
    changed = s.replace(old, new) + '\n# ' + old + '\n'
else:
    changed = s.replace(old, '# ' + old.replace('\n', '\n# ') + '\n' + new)
assert changed != s
p.write_text(changed)
PUSH_CONTROL
    commit "$repo"
    git -C "$repo" push -q origin main
    git --git-dir="$TMP/remote" update-ref refs/heads/kendex/refresh "$push_head"
    if [ "$name" = new-branch-failure ]; then
      git --git-dir="$TMP/remote" update-ref -d refs/heads/kendex/refresh
    fi
    : >"$TMP/state/calls"
    run_refresh "control-$name" pass render
    if ! refresh_push_matches "$expected" "$reason"; then ok "control: $name $mutation assertion turns red"; else bad "$name $mutation push control" "$OUT"; fi
    reset_default
    cp "$TMP/push-runner" "$runner"
    commit "$repo"
    git -C "$repo" push -q origin main
  done
done
unset PUSH_MODE PUSH_QUERY
reset_default
git --git-dir="$TMP/remote" update-ref refs/heads/kendex/refresh "$push_head"
printf '{"data":{"repository":{"ref":{"target":{"oid":"abc"}},"pullRequest":{"state":"OPEN","isInMergeQueue":false,"autoMergeRequest":null}}}}\n' >"$TMP/state/push-state.json"
# A non-render run disables auto-merge on the open rolling pull request.
# GitHub refuses that once the pull request is queued, merged or closed. The
# run then defers on those post-refusal states; armed, branch-gone and active
# still exit 1.
cp "$runner" "$TMP/disable-runner"
DISABLE_MODE=refused
CLASS_REASON='cause=excluded-path path=.agents/skills/commit-guards/scripts/install-git-hooks glob=*skills/commit-guards/scripts/*'
for row in \
  'queued|OPEN|true|false|present|0|queued' \
  'merged|MERGED|false|false|gone|0|merged' \
  'closed|CLOSED|false|false|present|0|closed' \
  'armed|OPEN|false|true|present|1|armed' \
  'active|OPEN|false|false|present|1|active'; do
  IFS='|' read -r name pr_state queued armed branch expected reason <<<"$row"
  jq -cn --arg state "$pr_state" --argjson queued "$queued" --argjson armed "$armed" --arg branch "$branch" \
    '{data:{repository:{ref:(if $branch == "gone" then null else {target:{oid:"abc"}} end),pullRequest:{state:$state,isInMergeQueue:$queued,autoMergeRequest:(if $armed then {enabledAt:"2026-10-02T01:09:07Z"} else null end)}}}}' >"$TMP/state/push-state.json"
  # The queued row and the active row each carry a planted behavior defect on
  # a disposable copy.
  controls=""
  case "$name" in
    queued) controls=bare ;;
    active) controls=open ;;
  esac
  for mutation in none $controls; do
    reset_default
    if [ "$mutation" != none ]; then
      python3 - "$runner" "$mutation" <<'DISABLE_CONTROL'
from pathlib import Path
import sys
p = Path(sys.argv[1]).resolve()
s = p.read_text()
mutations = {
    'bare': ('gh pr merge "$pr" --repo "$GH_REPO" --disable-auto || disable_status=$?', 'gh pr merge "$pr" --repo "$GH_REPO" --disable-auto'),
    'open': ('        queued | merged | closed)', '        *)'),
}
old, new = mutations[sys.argv[2]]
assert s.count(old) == 1
changed = s.replace(old, '# ' + old.strip() + '\n' + new)
assert changed != s
p.write_text(changed)
DISABLE_CONTROL
      commit "$repo"
      git -C "$repo" push -q origin main
    fi
    git --git-dir="$TMP/remote" update-ref refs/heads/kendex/refresh "$push_head"
    printf '1\n' >"$TMP/state/pr"
    : >"$TMP/state/calls"
    run_refresh "disable-$name-$mutation" pass standard
    if [ "$mutation" = none ]; then
      if refresh_disable_matches "$expected" "$reason"; then ok "$name refused disable state"; else bad "$name refused disable state" "$OUT"; fi
    else
      if ! refresh_disable_matches "$expected" "$reason"; then ok "control: $name $mutation disable assertion turns red"; else bad "$name $mutation disable control" "$OUT"; fi
      reset_default
      cp "$TMP/disable-runner" "$runner"
      commit "$repo"
      git -C "$repo" push -q origin main
    fi
  done
done
unset DISABLE_MODE
CLASS_REASON='cause=renders-match-their-sources'
reset_default
git --git-dir="$TMP/remote" update-ref refs/heads/kendex/refresh "$push_head"
printf '{"data":{"repository":{"ref":{"target":{"oid":"abc"}},"pullRequest":{"state":"OPEN","isInMergeQueue":false,"autoMergeRequest":null}}}}\n' >"$TMP/state/push-state.json"
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
    extra-field) printf '\nprintf '\''{"refused":[],"deprecated":[],"deprecated_models":[],"extra":true}\\n'\''\nexit 0\n' >>"$FRESH_ORCH/scripts/lib/overseer-launch.sh" ;;
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
  [ "$command" != tail ] || committed=claude:opus:high
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
ship_refresh_template "$TMP/fresh-templates/kendex-refresh.yml"
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
# A committed hand edit refuses before writer adoption and every publication.
reset_default
cp "$repo/.agents/skills/review-gate/templates/kendex-refresh.yml" "$repo/.github/workflows/kendex-refresh.yml"
file_edit "$repo" .github/workflows/kendex-refresh.yml 1 '^name: ' 's/^name: .*/name: consumer edit/'
commit "$repo"
git -C "$repo" push -q origin main
cp "$repo/.github/workflows/kendex-refresh.yml" "$TMP/workflow-before"
cp "$repo/.github/workflows/gate.yml" "$TMP/writer-before"
cp "$repo/.kendex-generated.json" "$TMP/inventory-before"
before="$(git --git-dir="$TMP/secure-remote" rev-parse refs/heads/kendex/refresh)"
: >"$TMP/state/calls"
run_refresh refreshed pass render
if [ "$RC" -eq 1 ] && grep -qxF "refresh-error=workflow-edited value=$repo/.github/workflows/kendex-refresh.yml" <<<"$OUT" &&
    cmp -s "$TMP/workflow-before" "$repo/.github/workflows/kendex-refresh.yml" &&
    cmp -s "$TMP/writer-before" "$repo/.github/workflows/gate.yml" &&
    cmp -s "$TMP/inventory-before" "$repo/.kendex-generated.json" &&
    [ "$before" = "$(git --git-dir="$TMP/secure-remote" rev-parse refs/heads/kendex/refresh)" ] &&
    ! grep -qE '^api --method (POST|PATCH)|^pr merge ' "$TMP/state/calls"; then
  ok 'workflow hand edit preserves files and stops publication'
else bad 'workflow hand edit preservation' "$OUT"; fi
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
# preserve a fully classified edit set before adoption or publication.
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
  # A lost held-item record must never permit adoption or publication.
  "$TEST_REAL_KENDEX" "$@" 2>&1 | sed '/^  .*: edited on disk since install /d'
else
  exec "$TEST_REAL_KENDEX" "$@"
fi
REAL_KENDEX_SH
  for row in local upstream shared multiple discard-control baseline; do
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
    elif [ "$row" != local ]; then
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
    mkdir -p "$real_root/before"
    while IFS= read -r edited; do
      mkdir -p "$real_root/before/${edited%/*}"
      cp "$repo/$edited" "$real_root/before/$edited"
    done <<<"$expected_edits"
    if [ "$row" = discard-control ]; then
      python3 - "$runner" <<'DISCARD_CONTROL'
from pathlib import Path
import sys
p=Path(sys.argv[1]).resolve(); s=p.read_text()
old='  exit 1\nfi\nTMP="$(mktemp -d)"'
assert s.count(old)==1
changed=s.replace(old, '  kendex refresh --scope project --yes --leave --discard-edits\nfi\nTMP="$(mktemp -d)"')
assert changed != s; p.write_text(changed)
DISCARD_CONTROL
      commit "$repo"
      git -C "$repo" push -q origin main
    elif [ "$row" = baseline ]; then
      git -C "$SKILL_DIR" show b315ac64:skills/review-gate/scripts/refresh-consumer.sh >"$runner"
      commit "$repo"
      git -C "$repo" push -q origin main
    fi
    run_real_refresh
    items=2
    case "$row" in local | upstream | shared) items=1 ;; esac
    if [ "$row" = discard-control ] || [ "$row" = baseline ]; then
      if ! real_refresh_preserved "$items" &&
          grep -qxF 'refresh --scope project --yes --leave --discard-edits' "$TMP/state/kendex" &&
          ! cmp -s "$real_root/before/.agents/skills/probe/SKILL.md" "$repo/.agents/skills/probe/SKILL.md"; then
        ok "control: $row breaks byte preservation"
      else bad "$row discard control" "$OUT"; fi
    elif real_refresh_preserved "$items"; then ok "$row preserves exact edit bytes and refuses before adoption or publication"
    else bad "$row real edit preservation" "$OUT"; fi
  done
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
      # Mutants retain the conflict diagnostic, so assert the later refusal
      # rather than treating that diagnostic as proof of an early exit.
      items=0
      [ "$row" != record-control ] || items=2
      if real_refresh_stopped "refresh-error=render-edited value=$items" &&
          grep -qxF "refresh-error=render-edited value=$items" <<<"$OUT"; then
        ok "control: $row bypass misclassifies a conflict as an edit hold"
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
