"""Exercise cache freshness through the production account reader."""

import collections
import datetime
import json
import os
from pathlib import Path
import runpy
import shlex
import shutil
import signal
import subprocess
import sys
import time

World = runpy.run_path(str(Path(__file__).with_name("lanes-cost-world.py")))["World"]
root, lanes, bash = sys.argv[1:4]
root = str(Path(root).resolve())
world = World(root, lanes, bash)
# Expired access tokens reach the CLI version read before renewal refuses a
# missing refresh token. Keep that command inside the offline fixture.
claude_cli = world.bin / "claude"
claude_cli.write_text("#!" + bash + '\nset -euo pipefail\nprintf "%s\\n" "${BASHPID:-$$}" >> "$COST_COUNTER"\nprintf "%s claude\\n" "${BASHPID:-$$}" >> "$COST_TOOLS"\n[[ "${1:-}" == --version ]] || exit 1\nprintf "%s\\n" "2.0.0 (Claude Code)"\n')
claude_cli.chmod(0o755)
clock_env = world.root / "logical-clock.env"
subprocess.run([bash, "-c", 'source "$1"; virtual_clock_bash_env "$2"', "_",
                str(Path(__file__).with_name("virtual-clock.sh")), str(clock_env)], check=True)
clock_env.write_text("source " + shlex.quote(str(world.trace)) + "\n" + clock_env.read_text())
env = {"ORCH_LANE_HOST": "local", "BASH_ENV": str(clock_env), "STUB_CLOCK": str(world.clock),
       "ORCH_LANES_CLAUDE_CLIENT_ID": "fixture-client"}
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

# The claims reader advances the fixture clock after startup and before the
# normalized batch. A controlled advance reaches the same elapsed boundary
# without depending on the runner's wall time.
time_control = mutate("startup-clock-control", 'local now="$((RUN_NOW + SECONDS - RUN_STARTED_SECONDS))" target=', 'local now="$RUN_NOW" target=')
tmux_wrapper = world.bin / "tmux"
tmux_body = tmux_wrapper.read_text()
tmux_wrapper.write_text(tmux_body.replace("set -euo pipefail\n", '''set -euo pipefail
if [[ -n "${CLAIMS_CLOCK:-}" && "${1:-}" == list-panes ]]; then
  printf '%s\\n' "$CLAIMS_CLOCK" > "$COST_CLOCK"
  printf '%s\\n' claims-clock-advanced >> "$COST_TOOLS"
fi
''', 1))
try:
    for through, cause in [("local", "reset"), ("host", "reset"), ("local", "age"),
                           ("host", "age"), ("local", "access"), ("local", "refresh"),
                           ("local", "refusal"), ("local", "fresh-age")]:
        for script, should_pass in [(lanes, True), (time_control, False)]:
            world.reset(home_count=1, providers=int(through == "host"), claims=0)
            clock_start = int(world.clock.read_text())
            settings = {**env, "ORCH_LANE_HOST": str(world.provider) if through == "host" else "local"}
            provider_rows = world.fixture / "provider.tsv"
            delayed_args = ["list", "--json"]
            advance = clock_start + 4
            if cause == "reset":
                if through == "local":
                    stage(100, clock_start + 2)
                else:
                    reset_at = datetime.datetime.fromtimestamp(clock_start + 2, datetime.timezone.utc).isoformat()
                    provider_rows.write_text(provider_rows.read_text().replace("session-5h-pct=10", "session-5h-pct=100\tsession-resets=" + reset_at).replace("weekly-pct=20", "weekly-pct=0").replace("model-pct=5", "model-pct=0"))
                delayed_args = ["pick", "--harness", "claude", "--model", "claude-opus-5-5", "--for-overseer", "--json"]
            elif cause == "age":
                settings["ORCH_LANES_USAGE_TTL"] = "2"
            elif cause in ("access", "refresh"):
                credentials = world.home / ".aclaude/.credentials.json"
                body = json.loads(credentials.read_text())
                if cause == "access":
                    body["claudeAiOauth"].pop("refreshToken")
                    body["claudeAiOauth"]["expiresAt"] = (clock_start + 2) * 1000
                else:
                    body["claudeAiOauth"]["refreshTokenExpiresAt"] = (clock_start + 2) * 1000
                credentials.write_text(json.dumps(body))
            elif cause == "refusal":
                settings["FETCH_STATUS"] = "403"
            warmed = world.run(delayed_args, script, settings)
            assert warmed["exit"] == (3 if cause == "reset" else 0), (cause, warmed)
            if cause == "refusal":
                cached = json.loads(next((world.state / "usage").glob("claude-*.json")).read_text())
                advance = cached["refusal"]["expires_at"] + 1
                del settings["FETCH_STATUS"]
            (world.root / "fetch.log").write_text("")
            if cause in ("reset", "age", "refusal"):
                if through == "local":
                    stage(2)
                else:
                    body = provider_rows.read_text()
                    if cause == "reset":
                        body = body.replace("session-5h-pct=100", "session-5h-pct=2").replace(reset_at, "2099-01-01T00:00:00Z")
                    else:
                        body = body.replace("session-5h-pct=10", "session-5h-pct=2")
                    provider_rows.write_text(body)
            result = world.run(delayed_args, script, {**settings, "CLAIMS_CLOCK": str(advance)})
            assert "claims-clock-advanced" in result["tools"], "the fixture did not advance during the claims read"
            rows = json.loads(result["stdout"])
            fetches = (world.root / "fetch.log").read_text().splitlines()
            if cause == "reset":
                passed = result["exit"] == 0 and rows.get("session_5h_pct") == 2 and fetches == (["provider"] if through == "host" else [".aclaude"])
            elif cause in ("age", "refusal"):
                expected_fetches = [".aclaude", "provider"] if through == "host" else [".aclaude"]
                passed = result["exit"] == 0 and any(row["session_5h_pct"] == 2 and row["status"] == "ok" and row["measured_through"] == through for row in rows) and fetches == expected_fetches
            elif cause in ("access", "refresh"):
                passed = result["exit"] == 0 and rows[0]["status"] == "expired" and not fetches
            else:
                passed = result["exit"] == 0 and rows[0]["usage_age_s"] == 4 and not fetches
            assert passed == should_pass, ("elapsed freshness assertion did not reject its control", through, cause, result, fetches)
        print("normalized: elapsed-" + through + "-" + cause + "=pass control=red")
finally:
    tmux_wrapper.write_text(tmux_body)

# A cold provider can finish after a local normalized reading resets. Both
# pick forms must recheck the same owner before their local-model fallback.
consume_control = mutate("consumption-clock-control", '\tlocal normalized_i\n\tload_normalized "$NORMALIZED_TARGET" || return 1', '\tlocal normalized_i')
provider_body = world.provider.read_text()
late_jq = world.bin / "jq"
late_jq_body = late_jq.read_text()
late_decoder_ready = world.root / "late-decoder.ready"
try:
    for verb, cause in [("pick", "reset"), ("named", "reset"), ("pick", "decoder"), ("named", "decoder")]:
        for script, should_refresh in [(lanes, True), (consume_control, False)]:
            world.reset(home_count=1, providers=1, claims=0)
            late_decoder_ready.unlink(missing_ok=True)
            late_jq.write_text(late_jq_body)
            now = int(world.clock.read_text())
            settings = {**env, "ORCH_LANE_HOST": str(world.provider), "LATE_DECODER_READY": str(late_decoder_ready)}
            stage(100, now + 2)
            usage_file = world.fixture / ".aclaude.json"
            body = json.loads(usage_file.read_text())
            body["seven_day"]["utilization"] = 0
            body["limits"][0]["percent"] = 0
            usage_file.write_text(json.dumps(body))
            provider_rows = world.fixture / "provider.tsv"
            provider_rows.write_text(provider_rows.read_text().replace("\tmodel-pct=5\tmodel-label=Opus", ""))
            entry = ["pick", "--harness", "claude", "--model", "claude-opus-5-5", "--for-overseer", "--json"]
            if verb == "named":
                entry += ["--lane", str(world.home / ".aclaude")]
            world.provider.write_text(provider_body)
            assert world.run(entry, script, settings)["exit"] == 3, "late-provider fixture did not warm the full local account"
            cache = next((world.state / "usage").glob("host-accounts-*.json"))
            record = json.loads(cache.read_text())
            record["fetched_at"] -= 301
            record["normalized"]["fetched_at"] = record["fetched_at"]
            cache.write_text(json.dumps(record))
            stage(2, 2000000000)
            if cause == "decoder":
                injection = 'if [[ -e "$LATE_DECODER_READY" ]]; then\n  for arg in "$@"; do\n    [[ "$arg" != *"| select((.normalized | usage_policy_current($policy))"* ]] || exit 70\n  done\nfi\n'
                # Literal jq variables belong to the selector, not this wrapper.
                injection = injection.replace('"| select((.normalized | usage_policy_current($policy))"', shlex.quote('| select((.normalized | usage_policy_current($policy))'))
                late_jq.write_text(late_jq_body.replace('args=("$@")', injection + 'args=("$@")'))
            world.provider.write_text(provider_body.replace('accounts) printf', 'accounts) printf "%s\\n" ' + str(now + 4) + ' > "$COST_CLOCK"; : > "$LATE_DECODER_READY"; printf', 1))
            (world.root / "fetch.log").write_text("")
            result = world.run(entry, script, settings)
            if cause == "decoder":
                passed = result["exit"] == 1 and not result["stdout"] and "lanes: account-read-failed step=normalized exit=70" in result["stderr"]
            else:
                row = json.loads(result["stdout"])
                passed = result["exit"] == 0 and row["session_5h_pct"] == 2 and (world.root / "fetch.log").read_text().splitlines() == ["provider", ".aclaude"]
            assert passed == should_refresh, ("consumption freshness assertion did not reject its control", verb, cause, result)
        print("normalized: late-provider-" + verb + "-" + cause + "=pass control=red")
finally:
    world.provider.write_text(provider_body)
    late_jq.write_text(late_jq_body)

# A login can expire while its cached reading is still inside the serve age.
# Each expiry filter has its own defect copy and the same expired-status rule.
for kind, field, predicate in [
    ("access", "expiresAt", "select((.expires_ms // 0) <= 0 or .expires_ms > $now * 1000)"),
    ("refresh", "refreshTokenExpiresAt", "select((.refresh_expires_ms // 0) <= 0 or .refresh_expires_ms > $now * 1000)"),
]:
    expiry_control = mutate(kind + "-expiry-control", predicate, "select(true)")
    for script, should_expire in [(lanes, True), (expiry_control, False)]:
        world.reset(home_count=1, providers=0, claims=0)
        now = int(world.clock.read_text())
        credentials = world.home / ".aclaude/.credentials.json"
        body = json.loads(credentials.read_text())
        body["claudeAiOauth"][field] = (now + 5) * 1000
        if kind == "access":
            body["claudeAiOauth"].pop("refreshToken")
        credentials.write_text(json.dumps(body))
        assert answer(script)[0]["status"] == "ok", "the expiry fixture did not warm a live login"
        (world.root / "fetch.log").write_text("")
        world.clock.write_text(str(now + 6) + "\n")
        rows = answer(script)
        assert (rows[0]["status"] == "expired") == should_expire, ("warm expiry assertion did not reject its control", kind, rows)
        assert not (world.root / "fetch.log").read_text(), "the expiry row fetched usage after its login ended"
    print("normalized: " + kind + "-expiry=pass control=red")

# A failed batch is an account-read failure for each consumer, even when a
# valid local reading has room and the provider's valid reading is full.
load_control = mutate("load-result-control", 'decode_normalized "$target" || { rc=$?; NORMALIZED_FAILED=true; message account-read-failed normalized "$rc" >&2; return 1; }', 'decode_normalized "$target" || true')
jq_wrapper = world.bin / "jq"
jq_body = jq_wrapper.read_text()
try:
    for phase, selector in [("metadata", "| select((.normalized | usage_policy_current($policy))"),
                            ("rows", "$ARGS.positional as $args | range(0; $args | length; 7)")]:
        for verb, entry in [("pick", ["pick", "--harness", "claude", "--model", "claude-opus-5-5", "--for-overseer", "--json"]),
                            ("named", ["pick", "--lane", str(world.home / ".aclaude"), "--harness", "claude", "--model", "claude-opus-5-5", "--for-overseer", "--json"]),
                            ("list", ["list", "--json"]), ("host", ["host-accounts", "--json"]), ("context", ["context", "--json"])]:
            for script, should_refuse in [(lanes, True), (load_control, False)]:
                world.reset(home_count=1, providers=1, claims=0)
                settings = {**env, "ORCH_LANE_HOST": str(world.provider)}
                provider_rows = world.fixture / "provider.tsv"
                provider_rows.write_text(provider_rows.read_text().replace("weekly-pct=20", "weekly-pct=100").replace("model-pct=5", "model-pct=100"))
                jq_wrapper.write_text(jq_body)
                cold = world.run(entry, script, settings)
                warm = world.run(entry, script, settings)
                expected = 3 if verb in ("pick", "named") else 0
                assert cold["exit"] == warm["exit"] == expected, ("decoder fixture did not prove its valid full-provider state", verb, cold, warm)
                injection = 'for arg in "$@"; do\n  [[ "$arg" != *' + shlex.quote(selector) + '* ]] || exit 70\ndone\n'
                assert jq_body.count('args=("$@")') == 1
                jq_wrapper.write_text(jq_body.replace('args=("$@")', injection + 'args=("$@")'))
                failed = world.run(entry, script, settings)
                refused = failed["exit"] == 1 and not failed["stdout"] and "lanes: account-read-failed step=normalized exit=70" in failed["stderr"]
                assert refused == should_refuse, ("failed decoder assertion did not reject its control", phase, verb, failed)
            print("normalized: decoder-" + phase + "-" + verb + "=pass control=red")
finally:
    jq_wrapper.write_text(jq_body)

# The provider has already answered before its parser acknowledges the pause.
# TERM reaches the owned process group while the real directory mutex is held.
flock_wrapper = world.bin / "flock"
flock_body = flock_wrapper.read_bytes() if flock_wrapper.exists() else None
provider_body = world.provider.read_text()
try:
    if flock_wrapper.exists():
        flock_wrapper.unlink()
    for phase, old in [("answered", '\trm -f -- "$err"\n\torch_arm_lock_signals'),
                       ("absent", '\t\trm -f -- "$err"\n\t\torch_arm_lock_signals')]:
        signal_control = mutate("signal-" + phase + "-control", old, old.replace("orch_arm_lock_signals", "trap - INT TERM"))
        for script, should_clean in [(lanes, True), (signal_control, False)]:
            world.reset(home_count=1, providers=1, claims=0)
            world.provider.write_text(provider_body if phase == "answered" else provider_body.replace('accounts) printf', 'accounts) printf "%s\\n" provider >> "$FETCH_LOG"; exit 2 ;;\n  unused) printf', 1))
            ready = world.root / "provider-parser.ready"
            ready.unlink(missing_ok=True)
            selector = '[[ "$*" == *"--arg mode discovery"* ]]' if phase == "answered" else '[[ "$*" == *\'.rows // ""\'* ]]'
            jq_wrapper.write_text(jq_body.replace('args=("$@")', 'if ' + selector + '; then\n  : > "$PARSER_READY"\n  while :; do ' + shlex.quote(shutil.which("sleep")) + ' 0.1; done\nfi\nargs=("$@")'))
            started = world.start(["host-accounts", "--json", "--no-cache"], script, {**env, "ORCH_LANE_HOST": str(world.provider), "PARSER_READY": str(ready)})
            try:
                deadline = time.monotonic() + 15
                while not ready.exists():
                    assert started[0].poll() is None and time.monotonic() < deadline, "provider parser did not acknowledge progress"
                    time.sleep(0.01)
                mutex = world.state / "usage/.usage-refresh.lock.d"
                assert mutex.is_dir() and (world.root / "fetch.log").read_text().splitlines() == ["provider"], "the interruption fixture did not hold the fallback lock after its answer"
                os.killpg(started[0].pid, signal.SIGTERM)
                stopped = world.finish(started)
                assert stopped["exit"] != 0, "TERM was not observed by the provider read"
                assert (not mutex.exists()) == should_clean, ("lock cleanup assertion did not reject its control", phase, stopped)
            finally:
                if started[0].poll() is None:
                    os.killpg(started[0].pid, signal.SIGKILL)
                    started[0].wait(timeout=5)
        print("normalized: provider-term-" + phase + "=pass control=red")
finally:
    jq_wrapper.write_text(jq_body)
    world.provider.write_text(provider_body)
    if flock_body is not None:
        flock_wrapper.write_bytes(flock_body)
        flock_wrapper.chmod(0o755)

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
