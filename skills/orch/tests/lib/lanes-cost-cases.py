"""Drive real account readers; report observations to the shell assertions."""

import json
from pathlib import Path
import runpy
import shutil
import subprocess
import sys

fixture = runpy.run_path(str(Path(__file__).with_name("lanes-cost-world.py")))
World, PICK = fixture["World"], fixture["PICK"]
root, lanes, bash = sys.argv[1:4]
root = str(Path(root).resolve())
base = sys.argv[4] if len(sys.argv) > 4 else ""
world = World(root, lanes, bash)
results = {}


def same(left, right):
    def keyed(value):
        return [line for line in value.splitlines() if line.startswith("lanes: ")]
    return (left["stdout"] == right["stdout"] and left["exit"] == right["exit"]
            and keyed(left["stderr"]) == keyed(right["stderr"]))


def warm(args, script=lanes):
    cold = world.run(args, script)
    return cold, world.run(args, script)


def mutate(name, old, new, relative="lanes", source_script=lanes):
    directory = Path(root) / "controls" / name
    source = Path(source_script).resolve().parent
    for package in ("orch", "mailbox", "github"):
        source_scripts = source if package == "orch" else source.parent.parent / package / "scripts"
        shutil.copytree(source_scripts, directory / package / "scripts")
    target = directory / "orch" / "scripts" / relative
    before = target.read_text()
    if before.count(old) != 1 or old == new:
        raise RuntimeError(f"control target {relative}: matches={before.count(old)}")
    target.write_text(before.replace(old, new))
    return str(directory / "orch" / "scripts" / "lanes")


for label, args in [("pick", PICK), ("list", ["list"]), ("list-json", ["list", "--json"])]:
    world.reset()
    cold, current = warm(args)
    results[label] = {"count": current["count"], "exit": current["exit"], "cold_warm_equal": same(cold, current),
                      "no_credential_parse": all("credential " not in line for line in current["tools"].splitlines())}
    if label == "list-json":
        rows = json.loads(current["stdout"])
        results["claims"] = all(row["claims"] == world.expected_claims.get(row["config_dir"], 0) for row in rows)
        results["claims_rows"] = [{"actual": row["claims"], "expected": world.expected_claims.get(row["config_dir"], 0)} for row in rows]
        observed = {(row["config_dir"], row["measured_through"]) for row in rows}
        required = {(str(directory), "local") for _, directory in world.accounts if directory.name != ".bclaude"}
        required |= {(str(world.home / f".{name}claude"), "host") for name in list("acdefghij") + ["remote"]}
        results["inventory"] = observed == required
        results["copilot_credits_used"] = all(row["credits_used"] == 19.5 for row in rows if row["harness"] == "copilot")
        results["token_excluded"] = all("fixture-marker" not in path.read_text() for path in (world.state / "usage").glob("*.json"))
        results["readings_only"] = all(not ({"claims", "wall", "verdict", "usage_age_s", "headroom_pct"} & set(account))
                                     for path in (world.state / "usage").glob("*.json")
                                     for account in ([json.loads(path.read_text())["normalized"].get("account", {})]
                                                     + json.loads(path.read_text())["normalized"].get("accounts", [])))
    if base:
        candidate_files = world.cache_files()
        shutil.rmtree(world.state / "usage")
        base_cold, base_warm = warm(args, base)
        results[label]["base_equal"] = same(cold, base_cold) and same(current, base_warm)
        results[label]["base_count"] = base_warm["count"]
        results[label]["cache_files_equal"] = candidate_files == world.cache_files()

results["growth"] = {}
for kind, sizes in [("home", [16, 20, 24]), ("provider", [11, 15, 19]), ("claim", [22, 26, 30])]:
    for label, args in [("pick", PICK), ("list", ["list"])]:
        counts, old_counts = [], []
        for size in sizes:
            settings = {"home_count": 16, "providers": 11, "claims": 22}
            settings[{"home": "home_count", "provider": "providers", "claim": "claims"}[kind]] = size
            world.reset(**settings)
            counts.append(warm(args)[1]["count"])
            if base:
                shutil.rmtree(world.state / "usage")
                old_counts.append(warm(args, base)[1]["count"])
        results["growth"][f"{kind}-{label}"] = {"sizes": sizes, "counts": counts, "base_counts": old_counts}

named = ["aclaude", "bclaude", "cclaude", "kclaude", "hclaude", "remoteclaude", "acodex", "acopilot"]
results["named"] = {}
for name in named:
    harness = "codex" if "codex" in name else "copilot" if "copilot" in name else "claude"
    args = ["pick", "--lane", str(world.home / ("." + name)), "--harness", harness, "--for-overseer", "--json"]
    world.reset()
    cold, current = warm(args)
    entry = {"cold_warm_equal": same(cold, current), "exit": current["exit"]}
    if base:
        shutil.rmtree(world.state / "usage")
        base_cold, base_warm = warm(args, base)
        entry["base_equal"] = same(cold, base_cold) and same(current, base_warm)
    results["named"][name] = entry

world.reset()
retired = world.run(["check", str(world.home / ".cclaude")])
results["retired"] = retired["exit"] == 4 and retired["stderr"].splitlines()[0].startswith("lanes: lane-retired ")
counter = mutate("counter", 'printf \'%s\\n\' "${NORMALIZED_ROWS[normalized_i]}"',
                 '_cost_control="$( : )"\n\t\tprintf \'%s\\n\' "${NORMALIZED_ROWS[normalized_i]}"')
world.reset(home_count=1, providers=0, claims=0)
args = ["pick", "--lane", str(world.home / ".aclaude"), "--for-overseer", "--json"]
overrides = {"ORCH_LANE_HOST": "local"}
world.run(args, overrides=overrides)
normal = world.run(args, overrides=overrides)
extra = world.run(args, counter, overrides)
results["counter"] = {"delta": extra["count"] - normal["count"], "same_output": same(normal, extra)}

# Run the actual turn-end caller against a private, live tmux pane.
tmux = shutil.which("tmux")
socket = str(Path(root).resolve() / "named.sock")
tm = [tmux, "-S", socket]
claims_tm = [tmux, "-S", str(Path(root).resolve() / "claims.sock")]
subprocess.run(tm + ["-f", "/dev/null", "new-session", "-d", "-s", "cost", "-c", str(world.work), "exec /bin/sleep 300"], check=True)
try:
    server = subprocess.check_output(tm + ["display-message", "-p", "#{pid}"], text=True).strip()
    pane = subprocess.check_output(tm + ["display-message", "-p", "#{pane_id}"], text=True).strip()
    server_start = subprocess.check_output(tm + ["display-message", "-p", "#{start_time}"], text=True).strip()
    world.reset()
    subprocess.run(claims_tm + ["-f", "/dev/null", "new-session", "-d", "-s", "claims", "-c", str(world.home), "exec /bin/sleep 300"], check=True)
    for index in range(21):
        subprocess.run(claims_tm + ["new-window", "-d", "-t", "claims", "exec /bin/sleep 300"], check=True)
    claim_server = subprocess.check_output(claims_tm + ["display-message", "-p", "#{pid}"], text=True).strip()
    panes = subprocess.check_output(claims_tm + ["list-panes", "-a", "-F", "#{pane_id}"], text=True).splitlines()
    assert len(panes) == 22
    for index, claim in enumerate(sorted((world.state / "claims").glob("*.claim"))):
        fields = claim.read_text().rstrip("\n").split("\t")
        fields[:2] = [claim_server, panes[index]]
        claim.write_text("\t".join(fields) + "\n")
    lane = str(world.home / ".aclaude")
    state = world.work / "tmp" / "workflow-state-oversee.json"
    state.parent.mkdir(exist_ok=True)
    state.write_text(json.dumps({"issue_id": "oversee", "overseer": {"pane": pane, "server": server,
                                "server_start": server_start, "harness": "claude", "account": lane,
                                "model": "claude-opus-5-5", "cwd": str(world.work)}}))
    caller_env = {"ORCH_LANE_HOST": "local", "CLAUDE_CONFIG_DIR": lane,
                  "TMUX": f"{socket},{server},0", "TMUX_PANE": pane}
    named_args = ["pick", "--lane", lane, "--harness", "claude", "--for-overseer", "--json"]
    world.run(named_args, overrides=caller_env)
    actual = world.run(["--check-marks", "--harness", "claude"], str(Path(lanes).with_name("oversee-succeed")), caller_env)
    stub = mutate("caller", Path(lanes).read_text(), '#!/usr/bin/env bash\nprintf \'%s\\n\' \'{"alias":"work","wall":20,"binding_resets_at":null,"usage_rate_state":"one-sample","projected_wall_minutes":null}\'\n')
    caller_only = world.run(["--check-marks", "--harness", "claude"], str(Path(stub).with_name("oversee-succeed")), caller_env)
    results["caller"] = {"total": actual["count"], "stub": caller_only["count"],
                         "share": actual["count"] - caller_only["count"], "calibration_share": actual["count"] - 90, "equal": same(actual, caller_only),
                         "exit": actual["exit"]}
    if base:
        shutil.rmtree(world.state / "usage")
        world.run(named_args, base, caller_env)
        old = world.run(["--check-marks", "--harness", "claude"], str(Path(base).with_name("oversee-succeed")), caller_env)
        old_stub = mutate("caller-base", Path(base).read_text(), Path(stub).read_text(), source_script=base)
        old_caller = world.run(["--check-marks", "--harness", "claude"], str(Path(old_stub).with_name("oversee-succeed")), caller_env)
        results["caller"]["base_total"] = old["count"]
        results["caller"]["base_stub"] = old_caller["count"]
        results["caller"]["base_share"] = old["count"] - old_caller["count"]
        results["caller"]["base_calibration_share"] = old["count"] - 90
finally:
    subprocess.run(claims_tm + ["kill-server"], check=False)
    subprocess.run(tm + ["kill-server"], check=False)

# The same missing-command check also runs when a caller masks exit 127.
unwrapped = mutate("unwrapped", "load_lane_claims() {", "load_lane_claims() {\n\t_cost_unwrapped_command || true")
try:
    world.run(PICK, unwrapped)
except RuntimeError as error:
    results["unwrapped_control"] = "_cost_unwrapped_command" in str(error)
else:
    results["unwrapped_control"] = False
bad_claims = mutate("claims", '\t[[ "${4:-}" == silent ]] || printf \'%s\\n\' "$ACCOUNT_CLAIMS"',
                    '\tACCOUNT_CLAIMS=$((ACCOUNT_CLAIMS + 1))\n\t[[ "${4:-}" == silent ]] || printf \'%s\\n\' "$ACCOUNT_CLAIMS"')
world.reset()
good = world.run(["list", "--json"])
bad = world.run(["list", "--json"], bad_claims)
results["claims_control"] = bad["exit"] == 0 and bad["stdout"] != good["stdout"]
results["claims_control_rows"] = [{"actual": row["claims"], "expected": world.expected_claims.get(row["config_dir"], 0)} for row in json.loads(bad["stdout"])]

controls = {
    "total": mutate("total", 'load_lane_claims() {', 'load_lane_claims() {\n\tfor ((_cost_i=0; _cost_i<301; _cost_i++)); do _cost_control="$( : )"; done'),
    "home": mutate("home", '\t\tfields+=("$json"', '\t\tif [[ "$kind" == local ]]; then for ((_cost_i=0; _cost_i<3; _cost_i++)); do _cost_control="$( : )"; done; fi\n\t\tfields+=("$json"'),
    "provider": mutate("provider", '\t\tfields+=("$json"', '\t\tif [[ "$kind" == host ]]; then for ((_cost_i=0; _cost_i<5; _cost_i++)); do _cost_control="$( : )"; done; fi\n\t\tfields+=("$json"'),
    "claim": mutate("claim", 'lane_claims_canon "$cfg" silent || return 2', '_cost_control="$( : )"\n      lane_claims_canon "$cfg" silent || return 2', "lib/lane-claims.sh"),
}
results["controls"] = {}
for label, args in [("pick", PICK), ("list", ["list"])]:
    world.reset()
    results["controls"][f"total-{label}"] = warm(args, controls["total"])[1]["count"]
    for kind, sizes in [("home", [16, 20, 24]), ("provider", [11, 15, 19]), ("claim", [22, 26, 30])]:
        counts = []
        for size in sizes:
            settings = {"home_count": 16, "providers": 11, "claims": 22}
            settings[{"home": "home_count", "provider": "providers", "claim": "claims"}[kind]] = size
            world.reset(**settings)
            counts.append(warm(args, controls[kind])[1]["count"])
        results["controls"][f"{kind}-{label}"] = {"sizes": sizes, "counts": counts}

print(json.dumps(results))
