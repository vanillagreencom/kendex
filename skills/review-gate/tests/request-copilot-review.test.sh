#!/usr/bin/env bash
# Surface: the central request workflow's executed JavaScript.
# Inputs: .github/workflows/request-copilot-review.yml.
set -euo pipefail
TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKFLOW="$TEST_DIR/../../../.github/workflows/request-copilot-review.yml"
TMP_ROOT="$(mktemp -d)" || { echo 'request-copilot-review: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo "request-copilot-review: scratch=not-a-directory value=[$TMP_ROOT]" >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'request-copilot-review: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT
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
    ['lanes refresh', 'pull_request_target', 'kendex/refresh', 'vanillagreen-fleet-lanes[bot]', 'Bot', null, 0, 0],
    ['lanes product', 'pull_request_target', 'feature', 'vanillagreen-fleet-lanes[bot]', 'Bot', null, 1, 0],
    ['human refresh branch', 'pull_request_target', 'kendex/refresh', 'owner', 'User', null, 1, 0],
    ['another app refresh', 'pull_request_target', 'kendex/refresh', 'another-app[bot]', 'Bot', null, 1, 0],
    ['non-app identity', 'pull_request_target', 'kendex/refresh', 'vanillagreen-fleet-lanes[bot]', 'User', null, 1, 0],
    ['similar branch', 'pull_request_target', 'kendex/refresh-extra', 'vanillagreen-fleet-lanes[bot]', 'Bot', null, 1, 0],
    ['fork pull request', 'pull_request_target', 'feature', 'contributor', 'User', null, 1, 0],
    ['request permission failure', 'pull_request_target', 'feature', 'owner', 'User', 403, 1, 1],
    ['request refused', 'pull_request_target', 'feature', 'owner', 'User', 422, 1, 1],
    ['request network failure', 'pull_request_target', 'feature', 'owner', 'User', 'network', 1, 1],
    ['merge group', 'merge_group', null, null, null, null, 0, 0],
  ];
  for (const [name, eventName, ref, login, type, failure, requests, warnings] of cases) {
    const calls = [];
    const notices = [];
    const context = {eventName, repo: {owner: 'acme', repo: 'widgets'}, payload: {}};
    if (eventName !== 'merge_group') {
      context.payload.pull_request = {number: 42, head: {ref, repo: {full_name: name === 'fork pull request' ? 'contributor/widgets' : 'acme/widgets'}}, user: {login, type}};
    }
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
    ["context.eventName === 'merge_group'", 'false'],
    ["pr.head.ref === 'kendex/refresh'", 'true'],
    ["pr.user.login === 'vanillagreen-fleet-lanes[bot]'", 'true'],
    ["pr.user.type === 'Bot'", 'true'],
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
