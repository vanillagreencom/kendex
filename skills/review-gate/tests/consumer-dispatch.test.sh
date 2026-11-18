#!/usr/bin/env bash
# Surface: kendex's main-push dispatch workflow and its executed sender.
# Inputs: .github/workflows/consumer-dispatch.yml, refresh/kendex-refresh.yml.
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
import subprocess
import sys
import tempfile
import textwrap
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
]
assert not re.search(r"^concurrency:", workflow, re.M)
jobs = dict(re.findall(r"(?m)^  (\w+):\n((?: {4}[^\n]*\n|\n)+)", workflow.split("jobs:\n", 1)[1]))
assert re.search(r"^    environment: consumer-dispatch-wait$", jobs["wait"], re.M)
assert not re.search(r"^    (needs|concurrency|env):|secrets\.", jobs["wait"], re.M)
assert re.search(r"^    needs: wait\n    environment: kendex$", jobs["send"], re.M)
assert re.search(r"^    concurrency:\n(?:      #[^\n]+\n)*      group: \S+\n"
                 r"      queue: max\n      cancel-in-progress: false$", jobs["send"], re.M)
assert re.search(r"^        if: steps\.dispatch\.outputs\.receipt != ''$", jobs["send"], re.M)
body = textwrap.dedent(re.search(r"^          python3 - <<'PY'\n(.*?)^          PY$", workflow, re.M | re.S)[1])

source = "repos/vanillagreencom/kendex"
repo_id = 42
a, b, c, d = [char * 40 for char in "abcd"]

def repository(name, identifier, **fields):
    return dict(id=identifier, full_name="vanillagreencom/" + name, default_branch="trunk",
                archived=False, disabled=False, **fields)

repos = [
    repository("kendex", repo_id), repository("private-first", 43),
    repository("private-absent", 44), repository("private-disabled", 45, fork=True),
    repository("private-last", 46, fork=True),
]

def run(sender, trigger, main, *, previous=None, denied=False, incomplete=False, refused=False):
    log = []
    run_id = 101 if previous is None else 102
    conf = dict(
        GITHUB_REPOSITORY=source.removeprefix("repos/"), GITHUB_REPOSITORY_ID=str(repo_id),
        GITHUB_SHA=trigger, GITHUB_RUN_ID=str(run_id), GITHUB_RUN_ATTEMPT="1",
        GH_TOKEN="source-fixture", FLEET_TOKEN="fleet-fixture",
    )

    def api(args, *, env, capture_output, timeout):
        assert args[:4] == ["gh", "api", "--hostname", "github.com"]
        endpoint = args[-1]
        log.append(endpoint)
        assert "FLEET_TOKEN" not in env and capture_output and timeout > 0
        assert env["GH_TOKEN"] == ("source-fixture" if endpoint.startswith(source + "/") else "fleet-fixture")

        def answer(value=b"", status=200):
            data = value if isinstance(value, bytes) else json.dumps(value).encode()
            if "--include" in args:
                data = f"HTTP/2.0 {status} Test\nContent-Type: application/json\r\n\r\n".encode() + data
            return subprocess.CompletedProcess(args, int(status >= 400), data, b"private-api-error")

        if endpoint == source + "/actions/artifacts?name=kendex-consumer-dispatch-receipt":
            assert "--paginate" in args and "--slurp" in args
            artifacts = []
            if previous is not None:
                artifacts.append(dict(id=7, expired=False, created_at="2026-11-18T08:00:00Z",
                                      workflow_run=dict(id=101, head_branch="main", head_sha=a,
                                                        repository_id=repo_id, head_repository_id=repo_id)))
            return answer([{"artifacts": artifacts}])
        if endpoint == source + "/actions/runs/101":
            return answer(dict(id=101, path=".github/workflows/consumer-dispatch.yml", event="push",
                               head_branch="main", head_sha=a, repository=dict(id=repo_id),
                               head_repository=dict(id=repo_id), status="in_progress"))
        if endpoint == source + "/actions/runs/101/attempts/1":
            return answer(dict(id=101, run_attempt=1, run_started_at="2026-11-18T00:00:00Z"))
        if endpoint == source + "/actions/runs/101/attempts/2":
            return answer({}, 404)
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
            assert "--paginate" in args and "--slurp" in args
            pages = [{"total_count": len(repos), "repositories": repos[:3]}]
            if incomplete:
                return answer(pages + [{"message": "private-api-error"}], 503)
            return answer(pages + [{"total_count": len(repos), "repositories": repos[3:]}])

        _, owner, repo, tail = endpoint.split("/", 3)
        assert owner == "vanillagreencom" and repo != "kendex"
        if tail == "actions/workflows":
            assert "--paginate" in args and "--slurp" in args
            workflows = [] if repo == "private-absent" else [dict(
                id=8, path=caller, state="disabled_manually" if repo == "private-disabled" else "active",
            )]
            return answer([dict(total_count=len(workflows), workflows=workflows)])
        if tail == f"contents/{caller}?ref=trunk":
            assert repo not in {"private-absent", "private-disabled"}
            if repo == "private-first" and denied:
                return answer({}, 404)
            return answer(shipped)
        if tail == "dispatches":
            assert "--method" in args and args[args.index("--method") + 1] == "POST"
            assert "event_type=kendex-refresh" in args
            return answer(status=422 if refused and repo == "private-first" else 204)
        raise AssertionError(endpoint)

    with tempfile.TemporaryDirectory() as owner:
        temp = pathlib.Path(owner).resolve()
        output = temp / "output"
        printed = io.StringIO()
        with unittest.mock.patch.dict(os.environ, dict(conf, RUNNER_TEMP=str(temp), GITHUB_OUTPUT=str(output)), clear=True):
            with unittest.mock.patch.object(subprocess, "run", side_effect=api), contextlib.redirect_stdout(printed):
                try:
                    exec(compile(sender, "<workflow sender>", "exec"), {})
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
    return result, posts, receipt, log

# Hours 0 and 7 are both on main at hour 8. Record the offered state,
# including the second push, after every destination accepts the event.
result, posts, receipt, log = run(body, a, b)
both = ["private-first", "private-last"]
assert result == 0 and posts == both
assert receipt == dict(covered=b, trigger=a, run=101, attempt=1)
snapshot = log.index(source + "/git/ref/heads/main")
assert log.index(f"repos/vanillagreencom/private-last/contents/{caller}?ref=trunk") < snapshot
assert snapshot < log.index("repos/vanillagreencom/private-first/dispatches")

def assert_covered(sender):
    # At hour 15 the hour-7 timer matures. C has already merged at 8:05.
    result, posts, receipt_output, log = run(sender, b, c, previous=receipt)
    assert (result, posts, receipt_output) == (0, [], None), "covered push dispatched again"
    assert "installation/repositories" not in log

assert_covered(body)
# C matures at 16:05. A still later D can be included by that batch.
result, posts, newer, _ = run(body, c, d, previous=receipt)
assert result == 0 and posts == both and newer["covered"] == d

# A receipt from an unproved attempt cannot suppress a send.
result, posts, replacement, _ = run(body, b, c, previous=dict(receipt, attempt=2))
assert result == 0 and posts == both and replacement["covered"] == c

# The live main SHA cannot attest a trigger that is outside its ancestry.
result, posts, receipt_output, _ = run(body, c, b)
assert (result, posts, receipt_output) == (1, [], None)

for flags, expected_posts in [
    ({"denied": True}, ["private-last"]),
    ({"incomplete": True}, ["private-first"]),
    ({"refused": True}, both),
]:
    result, posts, receipt_output, _ = run(body, a, b, **flags)
    assert (result, posts, receipt_output) == (1, expected_posts, None), flags

# The fixture must catch a sender that ignores a valid receipt.
needle = "if covered():"
assert body.count(needle) == 1
mutant = body.replace(needle, "if False:  # " + needle)
try:
    assert_covered(mutant)
except AssertionError as error:
    assert error.args == ("covered push dispatched again",)
else:
    raise AssertionError("must-fail control skipped the coverage check")
print("pass: 9   fail: 0")
PY
