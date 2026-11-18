#!/usr/bin/env bash
# Surface: kendex's main-push dispatch workflow and its executed sender.
# Inputs: .github/workflows/consumer-dispatch.yml, refresh/dispatch-consumers.py,
# refresh/kendex-refresh.yml.
set -euo pipefail
TEST_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
ROOT="$TEST_DIR/../../.."

python3 - "$ROOT" <<'PY'
import contextlib
import io
import json
import os
import pathlib
import re
import runpy
import subprocess
import sys
import tempfile
import unittest.mock
import zipfile

root = pathlib.Path(sys.argv[1])
workflow = (root / ".github/workflows/consumer-dispatch.yml").read_text()
caller = ".github/workflows/kendex-refresh.yml"
shipped = (root / "refresh/kendex-refresh.yml").read_bytes()

# The native controls are declarations. The hosted run proves elapsed timing.
trigger = re.search(r"^on:\n((?: +[^\n]+\n)+)", workflow, re.M)[1]
assert trigger.splitlines() == [
    "  push:", "    branches: [main]", "    paths:",
    "      - 'skills/**'", "      - 'agents/**'", "      - 'hooks/**'",
    "      - 'commands/**'", "      - 'pi-extensions/**'",
    "      - 'kendex.toml'",
]
assert not re.search(r"^concurrency:", workflow, re.M)
jobs = dict(re.findall(r"(?m)^  (\w+):\n((?: {4}[^\n]*\n|\n)+)", workflow.split("jobs:\n", 1)[1]))
assert re.search(r"^    environment: consumer-dispatch-wait$", jobs["wait"], re.M)
assert not re.search(r"^    (needs|concurrency|env):|secrets\.", jobs["wait"], re.M)
send_job = jobs["send"]
assert re.search(r"^    needs: wait\n    environment: kendex$", send_job, re.M)
assert re.search(r"^    concurrency:\n(?:      #[^\n]+\n)*      group: \S+\n"
                 r"      queue: max\n      cancel-in-progress: false$", send_job, re.M)

steps = re.split(r"(?m)^      - ", send_job.split("    steps:\n", 1)[1])[1:]
checkout, mint, dispatch, upload = steps
assert re.search(r"^uses: actions/checkout@[0-9a-f]{40}\b", checkout)
assert "ref: ${{ github.workflow_sha }}" in checkout and "persist-credentials: false" in checkout
assert re.search(r"^        id: fleet$", mint, re.M)
dispatch_id = re.search(r"^        id: (\w+)$", dispatch, re.M)[1]
sender_path = re.search(r"^        run: python3 (\S+)$", dispatch, re.M)[1]
assert sender_path == "refresh/dispatch-consumers.py"
sender = root / sender_path
receipt_name = re.search(r"^      DISPATCH_RECEIPT_NAME: (\S+)$", send_job, re.M)[1]
receipt_output = f"steps.{dispatch_id}.outputs.receipt"
assert "if: ${{ always() && " + receipt_output + " != '' }}" in upload
assert re.search(r"^        uses: actions/upload-artifact@[0-9a-f]{40}\b", upload, re.M)
assert "name: ${{ env.DISPATCH_RECEIPT_NAME }}" in upload
assert "path: ${{ " + receipt_output + " }}" in upload

source = "repos/vanillagreencom/kendex"
repo_id = 42
a, b, c, d, e = [char * 40 for char in "abcde"]

def repository(name, identifier, **fields):
    return dict(id=identifier, full_name="vanillagreencom/" + name, default_branch="trunk",
                archived=False, disabled=False, **fields)

repos = [
    repository("kendex", repo_id), repository("private-first", 43),
    repository("private-absent", 44), repository("private-disabled", 45, fork=True),
    repository("private-last", 46, fork=True),
]

def run(trigger, main, *, script=sender, previous=None, inventory="full", denied=False, post_failure=None):
    log = []
    run_id = 101 if previous is None else 102
    conf = dict(
        GITHUB_REPOSITORY=source.removeprefix("repos/"), GITHUB_REPOSITORY_ID=str(repo_id),
        GITHUB_SHA=trigger, GITHUB_RUN_ID=str(run_id), GITHUB_RUN_ATTEMPT="1",
        GH_TOKEN="source-fixture", FLEET_TOKEN="fleet-fixture", DISPATCH_RECEIPT_NAME=receipt_name,
    )

    def api(args, *, env, capture_output, timeout):
        assert args[:4] == ["gh", "api", "--hostname", "github.com"]
        endpoint = args[-1]
        log.append(endpoint)
        assert "FLEET_TOKEN" not in env and capture_output and timeout > 0
        assert env["GH_TOKEN"] == ("source-fixture" if endpoint.startswith(source + "/") else "fleet-fixture")

        def answer(value=b"", code=0, stderr=b""):
            data = value if isinstance(value, bytes) else json.dumps(value).encode()
            return subprocess.CompletedProcess(args, code, data, stderr)

        def page(value):
            assert args[4:-1] == ["--paginate", "--jq", "@json"]
            return json.dumps(value).encode() + b"\n"

        if endpoint == source + f"/actions/artifacts?name={receipt_name}":
            artifacts = []
            if previous is not None:
                artifacts.append(dict(id=7, expired=False, created_at="2026-11-18T08:00:00Z",
                                      workflow_run=dict(id=101, head_branch="main", head_sha=a,
                                                        repository_id=repo_id, head_repository_id=repo_id)))
            return answer(page({"artifacts": artifacts}))
        if endpoint == source + "/actions/runs/101":
            return answer(dict(id=101, path=".github/workflows/consumer-dispatch.yml", event="push",
                               head_branch="main", head_sha=a, repository=dict(id=repo_id),
                               head_repository=dict(id=repo_id), status="in_progress"))
        if endpoint == source + "/actions/runs/101/attempts/1":
            return answer(dict(id=101, run_attempt=1, run_started_at="2026-11-18T00:00:00Z"))
        if endpoint == source + "/actions/runs/101/attempts/2":
            return answer(code=1, stderr=b"gh: missing (HTTP 404)\n")
        if endpoint == source + "/actions/artifacts/7/zip":
            archive = io.BytesIO()
            with zipfile.ZipFile(archive, "w") as saved:
                saved.writestr("receipt.json", json.dumps(previous))
            return answer(archive.getvalue())
        if endpoint == source + "/git/ref/heads/main":
            return answer({"object": {"sha": main}})
        if endpoint.startswith(source + "/compare/"):
            old, new = endpoint.rsplit("/", 1)[1].split("...")
            return answer({"status": "ahead" if old < new else "behind"})

        if endpoint == "installation/repositories":
            first_page = page({"total_count": len(repos), "repositories": repos[:3]})
            if inventory == "timeout":
                raise subprocess.TimeoutExpired(args, timeout, output=first_page, stderr=b"private-transport-error")
            if inventory == "interrupted":
                return answer(first_page + b'{"total_count":', code=1, stderr=b"private-transport-error")
            if inventory == "missing-page":
                return answer(first_page)
            if inventory == "no-source":
                return answer(page({"total_count": len(repos) - 1, "repositories": repos[1:]}))
            if inventory == "source-only":
                return answer(page({"total_count": 1, "repositories": repos[:1]}))
            return answer(first_page + page({"total_count": len(repos), "repositories": repos[3:]}))

        _, owner, repo, tail = endpoint.split("/", 3)
        assert owner == "vanillagreencom" and repo != "kendex"
        if tail == "actions/workflows":
            workflows = [] if repo == "private-absent" else [dict(
                id=8, path=caller, state="disabled_manually" if repo == "private-disabled" else "active",
            )]
            return answer(page(dict(total_count=len(workflows), workflows=workflows)))
        if tail == f"contents/{caller}?ref=trunk":
            assert repo not in {"private-absent", "private-disabled"}
            if repo == "private-first" and denied:
                return answer(code=1, stderr=b"gh: private-api-error (HTTP 404)\n")
            return answer(shipped)
        if tail == "dispatches":
            assert args[4:-1] == ["--method", "POST", "--raw-field", "event_type=kendex-refresh"]
            if repo == "private-first" and post_failure == "refused":
                return answer(code=1, stderr=b"gh: private-api-error (HTTP 422)\n")
            if repo == "private-first" and post_failure == "timeout":
                raise subprocess.TimeoutExpired(args, timeout, stderr=b"private-transport-error")
            return answer()
        raise AssertionError(endpoint)

    with tempfile.TemporaryDirectory() as owner:
        temp = pathlib.Path(owner).resolve()
        output = temp / "output"
        printed = io.StringIO()
        with unittest.mock.patch.dict(os.environ, dict(conf, RUNNER_TEMP=str(temp), GITHUB_OUTPUT=str(output)), clear=True):
            with unittest.mock.patch.object(subprocess, "run", side_effect=api), contextlib.redirect_stdout(printed):
                try:
                    runpy.run_path(str(script), run_name="__main__")
                except SystemExit as exit:
                    result = exit.code
                else:
                    raise AssertionError("sender exited without a verdict")
        receipt = None
        if output.exists():
            record = temp / "receipt.json"
            assert output.read_text().splitlines() == [f"receipt={record}"]
            receipt = json.loads(record.read_text())
        assert "private-" not in printed.getvalue()

    posts = [endpoint.split("/")[2] for endpoint in log if endpoint.endswith("/dispatches")]
    summary = dict(re.findall(r"(\w+)=(\S+)", printed.getvalue()))
    return result, posts, receipt, log, summary

both = ["private-first", "private-last"]
result, posts, receipt, log, summary = run(a, b)
assert result == 0 and posts == both
assert receipt == dict(attempted=b, trigger=a, run=101, attempt=1)
assert summary == dict(installation="5", eligible="2", attempted="2", accepted="2", failures="none")
snapshot = log.index(source + "/git/ref/heads/main")
assert log.index(f"repos/vanillagreencom/private-last/contents/{caller}?ref=trunk") < snapshot
assert snapshot < log.index("repos/vanillagreencom/private-first/dispatches")

# The sender attempted all callers at C even though the first POST failed.
# B is later than the original trigger A and earlier than the attempt's C.
result, posts, partial, _, summary = run(a, c, post_failure="refused")
assert result == 1 and posts == both
assert partial == dict(attempted=c, trigger=a, run=101, attempt=1)
assert summary == dict(installation="5", eligible="2", attempted="2", accepted="1", failures="post-command-failed:1")

def assert_covered(script):
    result, posts, receipt_output, log, _ = run(b, d, previous=partial, script=script)
    assert (result, posts, receipt_output) == (0, [], None), "covered push dispatched again"
    assert f"{source}/compare/{b}...{c}" in log
    assert "installation/repositories" not in log

assert_covered(sender)
# D matures on its own timer. A still later E can be included in that batch.
result, posts, newer, _, _ = run(d, e, previous=partial)
assert result == 0 and posts == both and newer["attempted"] == e

# A receipt from an unproved attempt cannot suppress a send.
result, posts, replacement, _, _ = run(b, d, previous=dict(partial, attempt=2))
assert result == 0 and posts == both and replacement["attempted"] == d

# The live main SHA cannot attest a trigger outside its ancestry.
result, posts, receipt_output, _, summary = run(c, b)
assert (result, posts, receipt_output) == (1, [], None)
assert summary["failures"] == "main-trigger-missing:1"

for flags, expected_posts, accepted, installed, failure in [
    ({"denied": True}, ["private-last"], 1, 5, "caller-command-failed"),
    ({"inventory": "timeout"}, ["private-first"], 1, 3, "inventory-timeout"),
    ({"inventory": "interrupted"}, ["private-first"], 1, 3, "inventory-command-failed"),
    ({"inventory": "missing-page"}, ["private-first"], 1, 3, "inventory-incomplete"),
    ({"inventory": "no-source"}, both, 2, 4, "inventory-source-missing"),
    ({"post_failure": "timeout"}, both, 1, 5, "post-timeout"),
]:
    result, posts, attempt, _, summary = run(a, b, **flags)
    assert (result, posts, attempt) == (1, expected_posts, receipt), flags
    assert summary == dict(installation=str(installed), eligible=str(len(expected_posts)),
                           attempted=str(len(expected_posts)), accepted=str(accepted), failures=f"{failure}:1"), flags

result, posts, receipt_output, _, summary = run(a, b, inventory="source-only")
assert (result, posts, receipt_output) == (1, [], None)
assert summary == dict(installation="1", eligible="0", attempted="0", accepted="0", failures="no-eligible-callers:1")

# The fixture must catch a sender that ignores a valid attempt receipt.
needle = "if covered():"
body = sender.read_text()
assert body.count(needle) == 1
with tempfile.TemporaryDirectory() as owner:
    mutant = pathlib.Path(owner) / sender.name
    mutant.write_text(body.replace(needle, "if False:  # " + needle))
    try:
        assert_covered(mutant)
    except AssertionError as error:
        assert error.args == ("covered push dispatched again",)
    else:
        raise AssertionError("must-fail control skipped the coverage check")
print("pass: 14   fail: 0")
PY
