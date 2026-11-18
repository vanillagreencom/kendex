#!/usr/bin/env bash
# Surface: kendex's main-push dispatch workflow and its executed sender.
# Inputs: .github/workflows/consumer-dispatch.yml, refresh/dispatch-consumers.py,
# refresh/kendex-refresh.yml, skills/harness-ci/tests/lib/gh-eval.py.
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
import urllib.request
import zipfile

root = pathlib.Path(sys.argv[1])
workflow = (root / ".github/workflows/consumer-dispatch.yml").read_text()
gh_eval = str(root / "skills/harness-ci/tests/lib/gh-eval.py")
caller = ".github/workflows/kendex-refresh.yml"
shipped = (root / "refresh/kendex-refresh.yml").read_bytes()

# The hosted run proves elapsed timing.
trigger = re.search(r"^on:\n((?: +[^\n]+\n)+)", workflow, re.M)[1]
assert trigger.splitlines() == [
    "  push:", "    branches: [main]", "    paths:",
    "      - 'skills/**'", "      - 'agents/**'", "      - 'hooks/**'",
    "      - 'commands/**'", "      - 'pi-extensions/**'",
    "      - 'kendex.toml'",
]
assert not re.search(r"^concurrency:", workflow, re.M)
def workflow_jobs(text):
    return dict(re.findall(r"(?m)^  (\w+):\n((?: {4}[^\n]*\n|\n)+)", text.split("jobs:\n", 1)[1]))

jobs = workflow_jobs(workflow)
assert re.search(r"^    environment: consumer-dispatch-wait$", jobs["wait"], re.M)
assert "needs: priority" in jobs["wait"]
assert not re.search(r"^    (concurrency|env):|secrets\.", jobs["wait"], re.M)
priority_job = jobs["priority"]
assert "environment: kendex" in priority_job
assert "urgent: ${{ steps.linear.outputs.urgent }}" in priority_job
assert "KENDEX_DISPATCH_LINEAR_READ_KEY: ${{ secrets.KENDEX_DISPATCH_LINEAR_READ_KEY }}" in priority_job
assert "run: python3 refresh/dispatch-consumers.py --priority" in priority_job
send_job = jobs["send"]
assert "needs: [priority, wait]" in send_job and "environment: kendex" in send_job
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

def check_routes(text):
    parsed = workflow_jobs(text)
    requests = []
    for name, dependencies in (("wait", "priority"), ("send", "priority,wait")):
        clause = re.search(r"^    if: \$\{\{ (.+) \}\}$", parsed[name], re.M)[1]
        requests.append(f"{name}\t{dependencies}\t{clause}\n")
    flag = re.search(r"^          DISPATCH_URGENT: \$\{\{ (.+) \}\}$", parsed["send"], re.M)[1]
    for priority, urgent, wait, wanted_jobs, wanted_flag in (
        ("success", "true", "skipped", ["send"], True),
        ("success", "false", "skipped", ["wait"], False),
        ("success", "false", "success", ["wait", "send"], False),
        ("failure", "", "success", ["wait", "send"], False),
        ("failure", "true", "skipped", ["wait"], False),
        ("success", "false", "failure", ["wait"], False),
    ):
        context = json.dumps(dict(github=dict(repository="vanillagreencom/kendex"),
                                  needs=dict(priority=dict(result=priority, outputs=dict(urgent=urgent)),
                                             wait=dict(result=wait))))
        def evaluate(*args, **kwargs):
            return subprocess.run([sys.executable, gh_eval, *args], text=True, capture_output=True,
                                  timeout=10, check=True, **kwargs).stdout
        assert evaluate("jobs", context, input="".join(requests)).splitlines() == wanted_jobs, "wrong job route"
        assert json.loads(evaluate("value", context, flag)) is wanted_flag, "wrong urgent flag"

check_routes(workflow)
for old, new, verdict in (
    ("!cancelled() && (needs.wait.result", "success() && (needs.wait.result", "wrong job route"),
    ("DISPATCH_URGENT: ${{ needs.priority.result == 'success' && ", "DISPATCH_URGENT: ${{ ", "wrong urgent flag"),
):
    assert workflow.count(old) == 1
    try:
        check_routes(workflow.replace(old, new))
    except AssertionError as error:
        assert error.args == (verdict,)
    else:
        raise AssertionError("must-fail control accepted a changed dispatch job route")

source = "repos/vanillagreencom/kendex"
repo_id = 42
a, b, c, d, e, f = [char * 40 for char in "abcdef"]

def repository(name, identifier, **fields):
    return dict(id=identifier, full_name="vanillagreencom/" + name, default_branch="trunk",
                archived=False, disabled=False, **fields)

repos = [
    repository("kendex", repo_id), repository("private-first", 43),
    repository("private-absent", 44), repository("private-disabled", 45, fork=True),
    repository("public-last", 46, fork=True, private=False),
]

def run(trigger, main, *, script=sender, previous=None, receipt_failure=None, inventory="full",
        denied=False, post_failure=None, files=None, locks=None, urgent=False, expected_lines=(), gates=None,
        compares=None, trees=None, catalog_files=None):
    log = []
    gates = gates or {}
    ranges = list(compares if compares is not None else [(trigger, main, "ahead" if trigger < main else "behind")])
    run_id = 101 if previous is None else 102
    conf = dict(
        GITHUB_REPOSITORY=source.removeprefix("repos/"), GITHUB_REPOSITORY_ID=str(repo_id),
        GITHUB_SHA=trigger, GITHUB_RUN_ID=str(run_id), GITHUB_RUN_ATTEMPT="1",
        GH_TOKEN="source-fixture", FLEET_TOKEN="fleet-fixture", DISPATCH_RECEIPT_NAME=receipt_name,
        DISPATCH_URGENT=str(urgent).lower(),
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
            if receipt_failure == "listing":
                return answer(b"private-api-body", code=1, stderr=b"private-transport-error")
            artifacts = []
            if previous is not None:
                artifacts.append(dict(id=7, expired=False, created_at="2026-11-18T08:00:00Z",
                                      workflow_run=dict(id=101, head_branch="main", head_sha=a,
                                                        repository_id=repo_id, head_repository_id=repo_id)))
            total = len(artifacts) + (receipt_failure == "incomplete")
            return answer(page({"total_count": total, "artifacts": artifacts}))
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
            assert ranges, "unexpected comparison"
            requested_old, requested_new, status, *with_files = ranges.pop(0)
            assert (old, new) == (requested_old, requested_new), "wrong comparison range"
            if receipt_failure == "comparison":
                return answer({"status": None})
            return answer(dict(status=status, **({"files": files} if with_files else {})))
        if endpoint.startswith(source + "/contents/"):
            assert args[4:-1] == ["--header", "Accept: application/vnd.github.raw+json"]
            key = endpoint.removeprefix(source + "/contents/")
            data = (catalog_files or {}).get(key)
            return answer(data) if data is not None else answer(code=1)

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
        if tail == "git/ref/heads/trunk":
            return answer(dict(object=dict(sha=f)))
        if tail.startswith("contents/"):
            assert args[4:-1] == ["--header", "Accept: application/vnd.github.raw+json"]
            path, ref = tail.removeprefix("contents/").split("?ref=")
            assert ref == f
            lock = (locks or {}).get(repo if path == ".kendex-lock.json" else (repo, path))
            return answer(lock) if lock is not None else answer(code=1, stderr=b"private-api-error")
        if tail == f"git/trees/{f}?recursive=1":
            default = dict(truncated=False, tree=[dict(path=".kendex-lock.json")])
            tree = (trees or {}).get(repo, default)
            return answer(tree) if tree is not None else answer(code=1, stderr=b"private-api-error")
        if tail == "actions/workflows/kendex-refresh.yml/runs?status=waiting&per_page=1":
            case = gates.get(repo, "clear")
            if case == "unreadable":
                return answer(code=1, stderr=b"private-api-error")
            waiting = [dict(id=12, status="waiting")] if case == "waiting" else []
            return answer(dict(total_count=len(waiting), workflow_runs=waiting))
        if tail == "dispatches":
            clear = str(gates.get(repo, "clear") == "clear").lower()
            assert args[4:-1] == ["--method", "POST", "--raw-field", "event_type=kendex-refresh",
                                  "--field", f"client_payload[gate_clear]={clear}"]
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
            with unittest.mock.patch.object(subprocess, "run", side_effect=api), \
                 unittest.mock.patch.object(sys, "argv", [str(script)]), contextlib.redirect_stdout(printed):
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
    if compares is not None:
        assert not ranges, "missing comparison"
    lines = printed.getvalue().splitlines()
    for line in expected_lines:
        assert any(row.split(" gate-clear=")[0] == "consumer-dispatch: " + line for row in lines), "wrong consumer log"
    summary = dict(re.findall(r"(\w+)=(\S+)", lines[-1]))
    return result, posts, receipt, log, summary

both = ["private-first", "public-last"]
private, public = "43", "vanillagreencom/public-last"
result, posts, receipt, log, summary = run(a, b)
assert result == 0 and posts == both
assert receipt == dict(attempted=b, trigger=a, run=101, attempt=1)
assert summary == dict(installation="5", eligible="2", attempted="2", accepted="2", failures="none")
snapshot = log.index(source + "/git/ref/heads/main")
assert log.index(f"repos/vanillagreencom/public-last/contents/{caller}?ref=trunk") < snapshot
assert snapshot < log.index("repos/vanillagreencom/private-first/dispatches")

# The sender attempted all callers at C even though the first POST failed.
# B is later than the original trigger A and earlier than the attempt's C.
result, posts, partial, _, summary = run(a, c, post_failure="refused")
assert result == 1 and posts == both
assert partial == dict(attempted=c, trigger=a, run=101, attempt=1)
assert summary == dict(installation="5", eligible="2", attempted="2", accepted="1", failures="post-command-failed:1")

def assert_covered(script):
    result, posts, receipt_output, log, _ = run(b, d, previous=partial, script=script,
                                                compares=[(b, c, "ahead")])
    assert (result, posts, receipt_output) == (0, [], None), "covered push dispatched again"
    assert f"{source}/compare/{b}...{c}" in log
    assert "installation/repositories" not in log

assert_covered(sender)
# D matures on its own timer. A still later E can be included in that batch.
normal_compares = [(d, c, "behind"), (d, e, "ahead"), (c, e, "ahead", "files")]
result, posts, newer, _, _ = run(d, e, previous=partial, compares=normal_compares)
assert result == 0 and posts == both and newer["attempted"] == e
result, posts, urgent_receipt, _, _ = run(d, e, previous=partial, urgent=True,
    compares=[(d, c, "behind"), (d, e, "ahead"), (c, d, "ahead", "files")])
assert result == 0 and posts == both and urgent_receipt["attempted"] == d
result, posts, _, _, _ = run(a, b, gates={both[0]: "waiting", both[1]: "unreadable"})
assert result == 0 and posts == both

def entry(kind, name, provenance="vanillagreencom/kendex"):
    return dict(kind=kind, name=name, sourceRepo=provenance)

first = dict(version=12, installations={"ref": dict(kind="skill", name="review-gate")},
             entries={"item": dict(installation="ref", sourceRepo="vanillagreencom/kendex")})
last = dict(version=11, entries={"alias": entry("skill", "review-gate", "vanillagreencom/another"),
                                 "hook": entry("hook", "cloud-git-hooks")})
renamed = [dict(status="renamed", filename="skills/new/references/deep.md",
                previous_filename="skills/review-gate/references/deep.md")]
def row(path, status="modified"):
    return dict(status=status, filename=path)

def lock_for(kind, name, provenance="vanillagreencom/kendex"):
    return dict(version=11, entries={"item": entry(kind, name, provenance)})

render = ".agents/skills/jarvis/references/finance.md"
source_files = {f".kendex-generated.json?ref={ref}": [render] for ref in (c, e)}
source_files[f"pi-extensions/pi-hooks/package.json?ref={c}"] = dict(name="@vanillagreen/pi-hooks")
source_files[f"pi-extensions/pi-hooks-next/package.json?ref={e}"] = dict(name="@vanillagreen/pi-hooks-next")
nested_path = "nested/.kendex-lock.json"
nested_lock = dict(truncated=False, tree=[dict(path=nested_path, type="blob", mode="100644")])
pi_renamed = [dict(status="renamed", filename="pi-extensions/pi-hooks-next/index.ts",
                   previous_filename="pi-extensions/pi-hooks/index.ts")]

selection_rows = [
    (renamed, dict(zip(both, [first, last])), both[:1],
     [f"{private} outcome=sent reason=installed-package-changed", f"{public} outcome=skipped reason=no-installed-package-changed"], {}),
    (renamed, {both[0]: first}, both,
     [f"{public} outcome=sent reason=lock-command-failed"], {}),
    (renamed, {both[0]: first, both[1]: dict(version=12, entries=first["entries"])}, both,
     [f"{public} outcome=sent reason=lock-malformed-response"], {}),
    ([row("kendex.toml")], {}, both,
     [f"{private} outcome=sent reason=shared-input", f"{public} outcome=sent reason=shared-input"], {}),
    ([row("docs/unmapped.md")], {}, both, [f"{private} outcome=sent reason=shared-input"], {}),
    ([row("skills/review-gate/" + str(i)) for i in range(300)], {}, both,
     [f"{private} outcome=sent reason=comparison-incomplete"], {}),
    ([row("hooks/cloud-git-hooks.sh")], dict(zip(both, [first, last])), both[1:],
     [f"{private} outcome=skipped reason=no-installed-package-changed", f"{public} outcome=sent reason=installed-package-changed"], {}),
    ([row("skills/jarvis/references/finance.md"), row(render), row(".kendex-lock.json")],
     {both[0]: lock_for("skill", "jarvis"), both[1]: last}, both[:1],
     [f"{public} outcome=skipped reason=no-installed-package-changed"], {}),
    (renamed, {both[0]: first, both[1]: last, (both[1], nested_path): first}, both,
     [f"{public} outcome=sent reason=installed-package-changed"], {both[1]: nested_lock}),
    (renamed, {both[0]: first, both[1]: last}, both,
     [f"{public} outcome=sent reason=lock-tree-incomplete"], {both[1]: dict(tree=[], truncated=True)}),
    (renamed, {both[0]: first, both[1]: last}, both,
     [f"{public} outcome=sent reason=lock-command-failed"], {both[1]: nested_lock}),
    (renamed, {both[0]: lock_for("skill", "review-gate", "git@github.com:VanillaGreenCom/kendex.git"), both[1]: last}, both[:1],
     [f"{private} outcome=sent reason=lock-source-unrecognized", f"{public} outcome=skipped reason=no-installed-package-changed"], {}),
    (pi_renamed, {both[0]: lock_for("pi-extension", "@vanillagreen/pi-hooks"), both[1]: last}, both[:1],
     [f"{private} outcome=sent reason=installed-package-changed", f"{public} outcome=skipped reason=no-installed-package-changed"], {}),
    ([row("pi-extensions/unreadable/index.ts", "removed")], {}, both,
     [f"{private} outcome=sent reason=comparison-command-failed", f"{public} outcome=sent reason=comparison-command-failed"], {}),
]

def assert_selection(script, case):
    files, locks, expected, reasons, trees = case
    result, posts, record, log, _ = run(d, e, script=script, previous=partial, files=files, locks=locks,
        expected_lines=["consumer=" + line for line in reasons], compares=normal_compares,
        catalog_files=source_files, trees=trees)
    assert (result, posts, record["attempted"]) == (0, expected, e)
    if locks:
        assert all(f"repos/vanillagreencom/{name}/contents/.kendex-lock.json?ref={f}" in log for name in both)

for case in selection_rows:
    assert_selection(sender, case)

# Unreadable evidence supplies no coverage decision, so even the inventory waits.
for flags in [
    {"previous": dict(partial, attempt=2), "compares": []},
    {"previous": dict(partial, attempted=None), "compares": []},
    {"receipt_failure": "listing", "compares": []},
    {"receipt_failure": "incomplete", "compares": []},
    {"previous": partial, "receipt_failure": "comparison", "compares": [(b, c, "ahead")]},
]:
    result, posts, receipt_output, log, summary = run(b, d, **flags)
    assert (result, posts, receipt_output) == (1, [], None), flags
    assert "installation/repositories" not in log, flags
    assert summary == dict(receipt="unreadable"), flags

# The live main SHA cannot attest a trigger outside its ancestry.
result, posts, receipt_output, _, summary = run(c, b)
assert (result, posts, receipt_output) == (1, [], None)
assert summary["failures"] == "main-trigger-missing:1"

for flags, expected_posts, accepted, installed, failure in [
    ({"denied": True}, ["public-last"], 1, 5, "caller-command-failed"),
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

body = sender.read_text()
with tempfile.TemporaryDirectory() as owner:
    mutant = pathlib.Path(owner) / sender.name
    for old, new, probe, verdict in (
        ("previous is not None and includes(trigger, previous)", "False",
         assert_covered, "wrong comparison range"),
        ("compare/{previous}...{snapshot}", "compare/{trigger}...{snapshot}",
         lambda path: assert_selection(path, selection_rows[0]), "wrong comparison range"),
        ('repo["full_name"] if repo.get("private") is False else str(repo["id"])', 'str(repo["id"])',
         lambda path: assert_selection(path, selection_rows[0]), "wrong consumer log"),
    ):
        assert body.count(old) == 1
        mutant.write_text(body.replace(old, new))
        try:
            probe(mutant)
        except AssertionError as error:
            assert error.args == (verdict,), error.args
        else:
            raise AssertionError("must-fail control did not catch sender change")

scoped_subject = "fix(KEN-5294): Follow KEN-5283"
for key, subject, reply, output, reason in [
    ("fixture", scoped_subject, {"data": {"issue": {"priority": 1}}}, "true", "linear-urgent"),
    ("fixture", "Refresh KEN-5294", {"data": {"issue": {"priority": 2}}}, "false", "linear-not-urgent"),
    ("fixture", scoped_subject, {"errors": [{"message": "private-error"}]}, "false", "linear-response-unreadable"),
    ("fixture", "Refresh KEN-5294 and KEN-5283", None, "false", "subject-issue-ambiguous"),
    ("", scoped_subject, None, "false", "secret-missing"),
]:
    def linear(request, *, timeout):
        assert request.full_url == "https://api.linear.app/graphql" and timeout > 0
        assert request.get_header("Authorization") == key
        assert json.loads(request.data)["variables"] == {"id": "KEN-5294"}
        return io.BytesIO(json.dumps(reply).encode())

    with tempfile.TemporaryDirectory() as owner:
        event = pathlib.Path(owner) / "event.json"
        github_output = pathlib.Path(owner) / "output"
        event.write_text(json.dumps(dict(head_commit=dict(message=subject + "\n\nKEN-5284"))))
        conf = dict(GITHUB_EVENT_PATH=str(event), GITHUB_OUTPUT=str(github_output), KENDEX_DISPATCH_LINEAR_READ_KEY=key)
        printed = io.StringIO()
        with unittest.mock.patch.dict(os.environ, conf, clear=True), \
             unittest.mock.patch.object(sys, "argv", [str(sender), "--priority"]), \
             unittest.mock.patch.object(urllib.request, "urlopen", side_effect=linear) as request, \
             contextlib.redirect_stdout(printed):
            runpy.run_path(str(sender), run_name="__main__")
        assert request.call_count == (reply is not None)
        assert github_output.read_text() == f"urgent={output}\n"
        assert printed.getvalue().strip().endswith(f"reason={reason}") and "private-error" not in printed.getvalue()
print(f"pass: {35 + len(selection_rows)}   fail: 0")
PY
