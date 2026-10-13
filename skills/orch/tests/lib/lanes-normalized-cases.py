"""Exercise cache freshness through the production account reader."""

import collections
import datetime
import json
import os
from pathlib import Path
import runpy
import shutil
import sys
import time

World = runpy.run_path(str(Path(__file__).with_name("lanes-cost-world.py")))["World"]
root, lanes, bash = sys.argv[1:4]
root = str(Path(root).resolve())
world = World(root, lanes, bash)
env = {"ORCH_LANE_HOST": "local"}
args = ["list", "--local", "--json"]


def answer(script=lanes):
    result = world.run(args, script, env)
    if result["exit"] != 0:
        raise AssertionError(result)
    return json.loads(result["stdout"])


def prepare():
    world.reset(home_count=1, providers=0, claims=0)
    answer()
    (world.root / "fetch.log").write_text("")


def stage(pct, reset=1791543600):
    path = world.fixture / ".aclaude.json"
    body = json.loads(path.read_text())
    body["five_hour"] = {"utilization": pct, "resets_at": datetime.datetime.fromtimestamp(reset, datetime.timezone.utc).isoformat()}
    path.write_text(json.dumps(body))


def refreshed(rows):
    return rows[0]["session_5h_pct"] == 2 and (world.root / "fetch.log").read_text().splitlines() == [".aclaude"]


def mutate(name, old, new):
    directory = Path(root) / name
    source = Path(lanes).resolve().parent
    for package in ("orch", "mailbox", "github"):
        scripts = source if package == "orch" else source.parent.parent / package / "scripts"
        shutil.copytree(scripts, directory / package / "scripts")
    target = directory / "orch" / "scripts" / "lanes"
    before = target.read_text()
    assert before.count(old) == 1, (name, before.count(old))
    target.write_text(before.replace(old, new))
    return str(target)


prepare()
stage(2)
world.clock.write_text("1791540301\n")
assert refreshed(answer()), "age expiry served the old reading"
print("normalized: age=pass")

reset_control = mutate("reset-control", "$reset != null and $reset <= $now", "false and $reset != null and $reset <= $now")
for script, expected in [(lanes, True), (reset_control, False)]:
    world.reset(home_count=1, providers=0, claims=0)
    stage(10, 1791540010)
    answer(script)
    (world.root / "fetch.log").write_text("")
    stage(2)
    world.clock.write_text("1791540011\n")
    assert refreshed(answer(script)) == expected, "reset refresh assertion did not reject its control"
print("normalized: reset=pass control=red")

mtime_control = mutate("mtime-control", '[[ -f "$file" && -f "$creds" && ! "$creds" -nt "$file" ]]', '[[ -f "$file" && -f "$creds" ]]')
for script, expected in [(lanes, "error"), (mtime_control, "ok")]:
    prepare()
    credentials = world.home / ".aclaude" / ".credentials.json"
    credentials.write_text("{")
    # A future mtime proves the relation without depending on clock resolution.
    os.utime(credentials, (2000000000, 2000000000))
    rows = answer(script)
    assert rows[0]["status"] == expected, ("login refresh assertion did not reject its control", script, expected, rows)
print("normalized: credential-mtime=pass control=red")

prepare()
stage(2)
credentials = world.home / ".aclaude" / ".credentials.json"
credentials.write_text(json.dumps({"claudeAiOauth": {"accessToken": "changed-marker", "expiresAt": 1791547200000}}))
os.utime(credentials, (2000000000, 2000000000))
assert refreshed(answer()), "new credentials served the old usage"
print("normalized: credential-refresh=pass")

world.reset(home_count=1, providers=0, claims=0)
env["FETCH_STATUS"] = "403"
assert answer()[0]["status"] == "refused", "the fixture did not record its endpoint refusal"
(world.root / "fetch.log").write_text("")
stage(2)
credentials = world.home / ".aclaude" / ".credentials.json"
credentials.write_text(json.dumps({"claudeAiOauth": {"accessToken": "changed-marker", "expiresAt": 1791547200000}}))
os.utime(credentials, (2000000000, 2000000000))
del env["FETCH_STATUS"]
assert refreshed(answer()), "a new login replayed the previous login's refusal"
print("normalized: credential-refusal=pass")

prepare()
env["ORCH_LANE_RETIRE"] = "aclaude=2000-01-01"
rows = answer()
assert rows[0]["status"] == "retired" and not (world.root / "fetch.log").read_text(), "retirement served an eligible reading"
del env["ORCH_LANE_RETIRE"]
print("normalized: retire=pass")

prepare()
new = world.add_account("claude", "new")
rows = answer()
assert any(row["config_dir"] == str(new) and row["status"] == "ok" for row in rows), "discovery omitted a new account"
assert (world.root / "fetch.log").read_text().splitlines() == [".newclaude"], "discovery refreshed an already fresh account"
print("normalized: discovery=pass")

# Both readers reach the existing refresh lock before the first fetch finishes.
world.reset(home_count=2, providers=0, claims=0)
gate = world.root / "fetch-gate"
concurrent_env = {**env, "FETCH_GATE": str(gate), "ORCH_LANE_EXCLUDE": "", "ORCH_LANE_RETIRE": ""}
first = world.start(args, overrides=concurrent_env)
second = None
try:
    deadline = time.monotonic() + 15
    while not Path(str(gate) + ".ready").exists():
        assert first[0].poll() is None and time.monotonic() < deadline, "first reader did not reach the endpoint"
        time.sleep(0.01)
    second = world.start(args, overrides=concurrent_env)
    while " flock\n" not in second[2].read_text() and "lock-attempt\n" not in second[2].read_text():
        assert second[0].poll() is None and time.monotonic() < deadline, "second reader did not reach the refresh lock"
        time.sleep(0.01)
    Path(str(gate) + ".release").touch()
    left, right = world.finish(first), world.finish(second)
    assert left["exit"] == right["exit"] == 0, (left, right)
    assert left["stdout"] == right["stdout"], "concurrent readers disagreed"
    assert collections.Counter((world.root / "fetch.log").read_text().splitlines()) == {".aclaude": 1, ".bclaude": 1}, "concurrent readers fetched the same account twice"
finally:
    Path(str(gate) + ".release").touch()
    for started in (first, second):
        if started and started[0].poll() is None:
            started[0].kill()
            started[0].wait(timeout=5)
print("normalized: concurrent=pass fetches=one-per-account")
