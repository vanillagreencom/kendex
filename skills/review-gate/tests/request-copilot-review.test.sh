#!/usr/bin/env bash
# Surface: the central request workflow's job declarations and executed JavaScript.
# Inputs: .github/workflows/request-copilot-review.yml,
# skills/harness-ci/tests/lib/workflow.sh.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="$TEST_DIR/../../../.github/workflows/request-copilot-review.yml"
TMP_ROOT="$(mktemp -d)" || { echo 'request-copilot-review: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "request-copilot-review: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'request-copilot-review: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
. "$TEST_DIR/../../harness-ci/tests/lib/workflow.sh"
EXPECTED_IF="github.event_name != 'merge_group' && !github.event.pull_request.draft && !(github.event.pull_request.head.ref == 'kendex/refresh' && github.event.pull_request.user.login == 'vanillagreen-fleet-lanes[bot]' && github.event.pull_request.user.type == 'Bot')"

# GitHub Actions evaluates these declarations before allocating a runner.
# This check proves their source shape; GitHub owns their execution.
check_declarations() {
  local events condition
  events="$(triggers "$1")" || return 2
  condition="$(job_ifs "$1")" || return 2
  [ "$events" = $'merge_group\npull_request_target' ] &&
    [ "$condition" = $'request\t'"$EXPECTED_IF" ] &&
    python3 - "$1" <<'PY'
import pathlib, re, sys
text = pathlib.Path(sys.argv[1]).read_text().replace('\r\n', '\n')
job = dict(re.findall(r'^    (runs-on): (.+)$', text, re.M))
assert job['runs-on'] == "${{ vars.CI_RUNNER_2V || 'ubuntu-latest' }}"
assert 'kendex/refresh' not in text.split('          script: |\n')[1]
PY
}
check_declarations "$WORKFLOW"
for control in no-if no-draft no-merge-group hosted-runner no-head no-author no-type script-refresh-branch; do
  case "$control" in
    no-if) needle='    if:'; replacement='    # if:' ;;
    no-draft) needle=' && !github.event.pull_request.draft'; replacement=$'\n    # && !github.event.pull_request.draft' ;;
    no-merge-group) needle='  merge_group:'; replacement='  # merge_group:' ;;
    hosted-runner) needle="    runs-on: \${{ vars.CI_RUNNER_2V || 'ubuntu-latest' }}"; replacement='    runs-on: ubuntu-latest' ;;
    no-head|no-author|no-type)
      case "$control" in
        no-head) clause="github.event.pull_request.head.ref == 'kendex/refresh' && " ;;
        no-author) clause="github.event.pull_request.user.login == 'vanillagreen-fleet-lanes[bot]' && " ;;
        no-type) clause=" && github.event.pull_request.user.type == 'Bot'" ;;
      esac
      needle="    if: $EXPECTED_IF"
      replacement="    if: ${EXPECTED_IF/"$clause"/}"$'\n'"    # if: $EXPECTED_IF"
      ;;
    script-refresh-branch)
      needle='              const pr = context.payload.pull_request;'
      replacement="$needle"$'\n'"              if (pr.head.ref === 'kendex/refresh') return;"
      ;;
  esac
  plant "$WORKFLOW" "$needle" "$replacement" "$TMP_ROOT/$control.yml"
  status=0
  check_declarations "$TMP_ROOT/$control.yml" || status=$?
  if [ "$status" != 1 ]; then
    printf 'request-copilot-review: control=%s unexpected-exit=%s\n' "$control" "$status" >&2
    exit 1
  fi
  printf 'request-copilot-review: control=%s rejected-defect\n' "$control"
done
python3 - "$WORKFLOW" "$TMP_ROOT/body.js" <<'PY'
import pathlib, sys, textwrap
text = pathlib.Path(sys.argv[1]).read_text().replace('\r\n', '\n')
assert text.count('          script: |\n') == 1
body = textwrap.dedent(text.split('          script: |\n')[1])
assert body.strip()
pathlib.Path(sys.argv[2]).write_text(body)
PY
cat >"$TMP_ROOT/check.cjs" <<'JS'
const assert = require('node:assert/strict');
const fs = require('node:fs');
const AsyncFunction = Object.getPrototypeOf(async function () {}).constructor;
const original = fs.readFileSync(process.argv[2], 'utf8');
async function check(source) {
  const run = new AsyncFunction('context', 'github', 'core', source);
  const cases = [
    ['lanes product', 'pull_request_target', 'feature', 'vanillagreen-fleet-lanes[bot]', 'Bot', null, 1, 0],
    ['fork pull request', 'pull_request_target', 'feature', 'contributor', 'User', null, 1, 0],
    ['request permission failure', 'pull_request_target', 'feature', 'owner', 'User', 403, 1, 1],
    ['request refused', 'pull_request_target', 'feature', 'owner', 'User', 422, 1, 1],
    ['request network failure', 'pull_request_target', 'feature', 'owner', 'User', 'network', 1, 1],
  ];
  for (const [name, eventName, ref, login, type, failure, requests, warnings] of cases) {
    const calls = [];
    const notices = [];
    const context = {eventName, repo: {owner: 'acme', repo: 'widgets'}, payload: {}};
    context.payload.pull_request = {number: 42, head: {ref, repo: {full_name: name === 'fork pull request' ? 'contributor/widgets' : 'acme/widgets'}}, user: {login, type}};
    const github = {rest: {pulls: {requestReviewers: async (args) => {
      calls.push(args);
      if (failure) throw Object.assign(new Error('upstream request failed'), typeof failure === 'number' ? {status: failure} : {});
    }}}};
    await run(context, github, {info() {}, warning(value) {notices.push(value);}});
    assert.equal(calls.length, requests, name);
    assert.equal(notices.length, warnings, name);
    if (requests) assert.deepEqual(calls[0], {owner: 'acme', repo: 'widgets', pull_number: 42, reviewers: ['copilot-pull-request-reviewer[bot]']}, name);
  }
}
(async () => {
  await check(original);
  // Each control changes executed behavior while retaining its matched text.
  const controls = [
    ['await github.rest.pulls.requestReviewers({', 'await Promise.resolve({'],
    ['core.warning(', 'core.info('],
  ];
  for (const [needle, replacement] of controls) {
    assert.equal(original.split(needle).length - 1, 1, needle);
    const mutant = original.replace(needle, `/* ${needle} */ ${replacement}`);
    assert.notEqual(mutant, original);
    await assert.rejects(() => check(mutant), {name: 'AssertionError'}, needle);
  }
  console.log('request-copilot-review: pass');
})().catch(error => { console.error(error); process.exitCode = 1; });
JS
NODE="$(command -v node)"
env -i PATH="$PATH" HOME="$HOME" "$NODE" "$TMP_ROOT/check.cjs" "$TMP_ROOT/body.js"
