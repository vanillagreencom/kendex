"""Account fixtures and process recording for the lanes entry points."""

import json
import os
from pathlib import Path
import shlex
import shutil
import signal
import subprocess


class World:
    def __init__(self, root, lanes, bash):
        self.root = Path(root).resolve()
        self.lanes = str(Path(lanes).resolve())
        self.bash = bash
        self.home = self.root / "home"
        self.work = self.root / "work"
        self.fixture = self.root / "fixture"
        self.state = self.root / "state"
        self.bin = self.root / "bin"
        for directory in (self.home, self.work, self.fixture, self.bin):
            directory.mkdir(parents=True, exist_ok=True)
        for args in (["init", "-q", str(self.work)], ["-C", str(self.work), "config", "gc.auto", "0"],
                     ["-C", str(self.work), "config", "maintenance.auto", "false"]):
            subprocess.run([shutil.which("git")] + args, check=True)
        self.clock = self.root / "clock"
        self.clock.write_text("1791540000\n")
        self.trace = self.root / "trace.env"
        self.trace.write_text('unset SECONDS; SECONDS=0\nset -T\ncommand_not_found_handle() { printf "%s\\n" "$1" >> "$COST_UNWRAPPED"; return 127; }\ntrap \'if [[ "${_cost_pid:-}" != "${BASHPID:-$$}" ]]; then _cost_pid="${BASHPID:-$$}"; printf "%s\\n" "${BASHPID:-$$}" >> "$COST_COUNTER"; fi\' DEBUG\n')
        tools = "bash env jq awk basename cksum date tr dirname mktemp rm git grep cat sed readlink stat ps sort wc head tail cut sleep find timeout python3 realpath tmux column paste mkdir rmdir touch mv chmod hostname uname xargs tee cp perl flock false true curl kendex".split()
        for name in tools:
            real = shutil.which(name)
            if real is None:
                continue
            wrapper = self.bin / name
            body = f'#!{bash}\nset -euo pipefail\nprintf "%s\\n" "${{BASHPID:-$$}}" >> "$COST_COUNTER"\nprintf "%s %s\\n" "${{BASHPID:-$$}}" {shlex.quote(name)} >> "$COST_TOOLS"\n'
            if name == "mkdir":
                body += 'for arg in "$@"; do case "$arg" in */.usage-refresh.lock.d) printf "lock-attempt\\n" >> "$COST_TOOLS" ;; esac; done\n'
            if name == "jq":
                body += 'for arg in "$@"; do\n  case "$arg" in /*/.credentials.json|*/auth.json|*/config.json) printf "credential %s\\n" "$arg" >> "$COST_TOOLS" ;; esac\ndone\n'
            if name in ("date", "jq"):
                # Clock fixtures must not add command-substitution processes.
                body += 'IFS= read -r clock_value < "$COST_CLOCK"\n'
            if name == "date":
                body += 'for clock_arg in "$@"; do :; done\ncase "$clock_arg" in\n  +%s) printf "%s\\n" "${clock_value}" ;;\n  +%Y-%m-%d) printf "2026-10-09\\n" ;;\n  *) exec ' + shlex.quote(real) + ' "$@" ;;\nesac\n'
            elif name == "jq":
                body += 'args=("$@")\ni=0\nwhile (( i < ${#args[@]} )); do\n  case "${args[i]}" in\n    --arg|--argjson|--slurpfile|--rawfile) i=$((i+3)) ;;\n    -*) i=$((i+1)) ;;\n    *) args[i]="def now: ${clock_value}; ${args[i]}"; break ;;\n  esac\ndone\nexec ' + shlex.quote(real) + ' "${args[@]}"\n'
            else:
                body += f'exec {shlex.quote(real)} "$@"\n'
            wrapper.write_text(body)
            wrapper.chmod(0o755)
        self.fetch = self.root / "fetch"
        self.fetch.write_text(f'''#!{bash}
set -euo pipefail
printf '%s\\n' "${{2##*/}}" >> "$FETCH_LOG"
if [[ -n "${{FETCH_GATE:-}}" ]]; then
  : > "$FETCH_GATE.ready"
  until [[ -e "$FETCH_GATE.release" ]]; do sleep 0.01; done
fi
printf '%s\\n' "${{FETCH_STATUS:-200}}"
cat -- "$FIXTURE_DIR/${{2##*/}}.json"
''')
        self.fetch.chmod(0o755)
        self.provider = self.root / "provider"
        self.provider.write_text(f'''#!{bash}
set -euo pipefail
case "$1" in
  capabilities) printf '%s\\n' 'kind=ssh	launch=ssh	channel=mailbox	files=verb	status=verb	stop=verb	relaunch=resume	park=none	accounts=none	pool=plan	land=lane' ;;
  accounts) printf '%s\\n' provider >> "$FETCH_LOG"; printf '%s\\n' "$(<"$FIXTURE_DIR/provider.tsv")" ;;
  *) exit 2 ;;
esac
''')
        self.provider.chmod(0o755)
        self.run_number = 0
        self.owner_pid = os.environ.get("COST_CLAIM_PID", str(os.getpid()))

    def reset(self, home_count=16, providers=11, claims=22):
        for fixture_root in (self.home, self.work):
            for directory in fixture_root.iterdir():
                if directory.name != ".git":
                    if directory.is_dir():
                        shutil.rmtree(directory)
                    else:
                        directory.unlink()
        shutil.rmtree(self.state, ignore_errors=True)
        shutil.rmtree(self.fixture)
        self.fixture.mkdir()
        self.clock.write_text("1791540000\n")
        self.accounts = []
        base = [("claude", name) for name in "abcdefghijk"] + [("codex", name) for name in "abc"] + [("copilot", name) for name in "ab"]
        base += [("claude", f"extra{i}") for i in range(max(0, home_count - 16))]
        for harness, name in base[:home_count]:
            self.add_account(harness, name)
        provider_names = list("abcdefghij") + ["remote"] + [f"provider{i}" for i in range(max(0, providers - 11))]
        rows = []
        for name in provider_names[:providers]:
            directory = self.home / f".{name}claude"
            row = f"account={directory}\tharness=claude\tsession-5h-pct=10\tweekly-pct=20\tmodel-pct=5\tmodel-label=Opus"
            if name == "h":
                row = f"account={directory}\tharness=claude"
            rows.append(row)
        (self.fixture / "provider.tsv").write_text("\n".join(rows) + "\n")
        claim_dir = self.state / "claims"
        claim_dir.mkdir(parents=True)
        self.expected_claims = {}
        for index in range(claims):
            harness, directory = self.accounts[index % len(self.accounts)]
            pool = "copilot" if harness == "copilot" else "plan"
            self.expected_claims[str(directory)] = self.expected_claims.get(str(directory), 0) + 1
            (claim_dir / f"{index}.claim").write_text(f"{self.owner_pid}\t%{index}\t{directory}\tken-{index}\t2026-10-09T00:00:00Z\t\t{directory}\tlane\t{pool}\n")
        walls = self.state / "walls"
        walls.mkdir()
        directory = self.home / ".kclaude"
        checksum = subprocess.check_output([shutil.which("cksum")], input=str(directory).encode()).decode().split()[0]
        (walls / (checksum + ".json")).write_text(json.dumps({"config_dir": str(directory), "resets_at": 1791543600}))
        (self.root / "fetch.log").write_text("")

    def add_account(self, harness, name):
        directory = self.home / f".{name}{harness}"
        directory.mkdir(exist_ok=True)
        self.accounts.append((harness, directory))
        if harness == "claude":
            credentials = {"claudeAiOauth": {"accessToken": "fixture-marker-token", "refreshToken": "fixture-marker-refresh", "expiresAt": 1791543600000, "subscriptionType": "max"}}
            (directory / ".credentials.json").write_text(json.dumps(credentials))
            usage = {"five_hour": {"utilization": 10, "resets_at": "2026-10-09T11:00:00Z"}, "seven_day": {"utilization": 20, "resets_at": "2099-08-01T06:00:00Z"}, "limits": [{"kind": "weekly_scoped", "percent": 5, "scope": {"model": {"display_name": "Opus"}}, "resets_at": "2099-08-01T06:00:00Z"}]}
        elif harness == "codex":
            (directory / "auth.json").write_text(json.dumps({"tokens": {"access_token": "fixture-marker-token", "account_id": "acct-1"}}))
            usage = {"rate_limit": {"primary_window": {"used_percent": 20, "reset_at": 1791543600, "limit_window_seconds": 18000}, "secondary_window": None}}
        else:
            (directory / "config.json").write_text(json.dumps({"copilotTokens": "fixture-marker-token"}))
            usage = {"copilot_plan": "business", "quota_reset_date_utc": "2099-08-01", "quota_snapshots": {"premium_interactions": {"entitlement": 300, "remaining": 280, "credits_used": 19.5, "unlimited": False}}}
        (self.fixture / (directory.name + ".json")).write_text(json.dumps(usage))
        return directory

    def environment(self, counter, tools, overrides=None):
        retire = ",".join(["cclaude=2000-01-01", "jclaude=2099-01-01"] + [f"absent{i}=2099-01-01" for i in range(8)])
        cloud = ",".join(["work=Owner/Repo"] + [f"absent{i}=Owner/Repo" for i in range(9)])
        env = {"PATH": str(self.bin), "HOME": str(self.home), "LANES_HOME": str(self.home), "ORCH_LANE_HOST": str(self.provider), "ORCH_LANE_ALIASES": "aclaude=work,bclaude=blocked", "ORCH_LANE_EXCLUDE": "blocked", "ORCH_LANE_RETIRE": retire, "ORCH_LANE_CLOUD_REPOS": cloud, "ORCH_LANE_HOST_ACCOUNTS_TIMEOUT_S": "0", "ORCH_LANES_FETCH_CMD": str(self.fetch), "FIXTURE_DIR": str(self.fixture), "FETCH_LOG": str(self.root / "fetch.log"), "OVERSEE_WATCH_STATE_DIR": str(self.state), "GIT_CEILING_DIRECTORIES": str(self.root), "BASH_ENV": str(self.trace), "COST_COUNTER": str(counter), "COST_TOOLS": str(tools), "COST_CLOCK": str(self.clock), "COST_UNWRAPPED": str(counter) + ".unwrapped"}
        env.update(overrides or {})
        return env

    def start(self, args, script=None, overrides=None):
        self.run_number += 1
        counter = self.root / f"pids-{self.run_number}"
        tools = self.root / f"tools-{self.run_number}"
        counter.write_text("")
        tools.write_text("")
        Path(str(counter) + ".unwrapped").write_text("")
        process = subprocess.Popen([self.bash, script or self.lanes] + args, cwd=self.work,
                                   env=self.environment(counter, tools, overrides), stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                   start_new_session=True)
        return process, counter, tools

    def finish(self, started):
        process, counter, tools = started
        try:
            out, err = process.communicate(timeout=60)
        except subprocess.TimeoutExpired:
            if hasattr(os, "killpg"):
                os.killpg(process.pid, signal.SIGKILL)
            else:
                process.kill()
            process.communicate(timeout=5)
            raise
        pids = counter.read_text().splitlines()
        if Path(str(counter) + ".unwrapped").read_text():
            raise RuntimeError("cost command was not wrapped: " + Path(str(counter) + ".unwrapped").read_text())
        if any(not pid.isdecimal() for pid in pids):
            raise RuntimeError("cost trace contains a nonnumeric PID")
        return {"exit": process.returncode, "stdout": out.decode(), "stderr": err.decode(), "count": len(set(pids)), "tools": tools.read_text()}

    def run(self, args, script=None, overrides=None):
        return self.finish(self.start(args, script, overrides))

    def cache_files(self):
        directory = self.state / "usage"
        return sorted(p.name for p in directory.iterdir()) if directory.exists() else []


PICK = ["pick", "--harness", "claude", "--min-headroom-pct", "5", "--model", "claude-opus-5-5", "--for-overseer", "--json"]
