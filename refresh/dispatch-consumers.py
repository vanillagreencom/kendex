# Send the native main-push workflow's consumer refresh event.
import http.client
import io
import json
import os
import pathlib
import re
import subprocess
import urllib.parse
import urllib.request
import zipfile
import zlib
from collections import Counter
from functools import cache

caller = ".github/workflows/kendex-refresh.yml"
workflow = ".github/workflows/consumer-dispatch.yml"

class ApiError(Exception):
    def __init__(self, code, output=b""):
        super().__init__(code)
        self.code = code
        self.output = output

unreadable = (ApiError, KeyError, TypeError, ValueError, OSError, zipfile.BadZipFile)

def gh(endpoint, *options, fleet=False):
    # Private response bodies and credentials stay out of this public log.
    env = dict(os.environ)
    token = env.pop("FLEET_TOKEN")
    if fleet:
        env["GH_TOKEN"] = token
    try:
        result = subprocess.run(
            ["gh", "api", "--hostname", "github.com", *options, endpoint],
            env=env, capture_output=True, timeout=45,
        )
    except subprocess.TimeoutExpired as error:
        raise ApiError("timeout", error.stdout or b"") from None
    except OSError:
        raise ApiError("launch-failed") from None
    if result.returncode:
        raise ApiError("command-failed", result.stdout)
    return result.stdout

def get(endpoint, *, fleet=False):
    return json.loads(gh(endpoint, fleet=fleet))

def contents(base, path, ref, *, fleet=False):
    return gh(f"{base}/contents/{urllib.parse.quote(path)}?ref={urllib.parse.quote(ref, safe='')}",
              "--header", "Accept: application/vnd.github.raw+json", fleet=fleet)

def pages(endpoint, *, fleet=False):
    # gh's jq filter writes one JSON line per fully read page. A later
    # request can fail before a slurped JSON array would have been closed.
    failure = None
    try:
        output = gh(endpoint, "--paginate", "--jq", "@json", fleet=fleet)
    except ApiError as error:
        output, failure = error.output, error
    for line in output.split(b"\n")[:-1]:
        try:
            yield json.loads(line)
        except ValueError:
            if failure is not None:
                raise failure from None
            raise ApiError("malformed-page") from None
    if failure is not None:
        raise failure
    if not output.endswith(b"\n"):
        raise ApiError("incomplete-page")

def includes(older, newer):
    if not all(re.fullmatch(r"[0-9a-f]{40}", sha) for sha in (older, newer)):
        raise ValueError("invalid-commit")
    if older == newer:
        return True
    status = get(f"{source}/compare/{older}...{newer}")["status"]
    if status not in ("ahead", "behind", "diverged"):
        raise ValueError("invalid-comparison")
    return status == "ahead"

def last_attempt():
    rows, failure = collect(f"{source}/actions/artifacts?name={receipt_name}", "artifacts", fleet=False)
    if failure:
        raise ApiError(failure)
    candidates = [
        artifact for artifact in rows.values()
        if artifact["workflow_run"]["repository_id"] == repo_id
        and artifact["workflow_run"]["head_repository_id"] == repo_id
        and artifact["workflow_run"]["head_branch"] == "main"
    ]
    if not candidates:
        return None
    latest = max(candidates, key=lambda artifact: (artifact["created_at"], artifact["id"]))
    if latest["expired"] is not False:
        raise ValueError("receipt-unavailable")
    origin = latest["workflow_run"]
    run_id = int(origin["id"])
    run = get(f"{source}/actions/runs/{run_id}")
    if (run["id"] != run_id or run["path"] != workflow or run["event"] != "push"
            or run["head_branch"] != "main" or run["head_sha"] != origin["head_sha"]
            or run["repository"]["id"] != repo_id or run["head_repository"]["id"] != repo_id):
        raise ValueError("receipt-origin")
    # Upload is the final business step. It can be visible while
    # GitHub still marks the producer as running.
    artifact_id = int(latest["id"])
    archive = gh(f"{source}/actions/artifacts/{artifact_id}/zip")
    with zipfile.ZipFile(io.BytesIO(archive)) as saved:
        entry = saved.getinfo("receipt.json")
        if entry.file_size > 1024:
            raise ValueError("receipt-size")
        receipt = json.loads(saved.read(entry))
    attempt = int(receipt["attempt"])
    if receipt["run"] != run_id or attempt < 1 or receipt["trigger"] != run["head_sha"]:
        raise ValueError("receipt-identity")
    producer = get(f"{source}/actions/runs/{run_id}/attempts/{attempt}")
    if (producer["id"] != run_id or producer["run_attempt"] != attempt
            or not producer["run_started_at"] <= latest["created_at"]):
        raise ValueError("receipt-attempt")
    attempted = receipt["attempted"]
    if not isinstance(attempted, str):
        raise ValueError("receipt-attempted")
    return attempted

def package(path):
    if not isinstance(path, str):
        raise ValueError("comparison-path")
    directory, *parts = path.split("/")
    if directory in ("skills", "pi-extensions") and len(parts) >= 2:
        return directory.removesuffix("s"), parts[0]
    if directory in ("agents", "commands", "hooks") and len(parts) == 1:
        extension = ".sh" if directory == "hooks" else ".md"
        if parts[0].endswith(extension):
            return directory.removesuffix("s"), parts[0].removesuffix(extension)
    return None

def changed_packages(previous, snapshot):
    if previous is None:
        return None, "no-attempt-receipt"

    @cache
    def generated(ref):
        paths = json.loads(contents(source, ".kendex-generated.json", ref))
        if not isinstance(paths, list) or not all(isinstance(path, str) for path in paths):
            raise ValueError("generated-inventory")
        return set(paths)

    @cache
    def pi_name(directory, ref):
        name = json.loads(contents(source, f"pi-extensions/{directory}/package.json", ref))["name"]
        if not isinstance(name, str) or not name:
            raise ValueError("pi-package-name")
        return name

    try:
        comparison = get(f"{source}/compare/{previous}...{snapshot}")
        files = comparison["files"]
        # Compare returns at most 300 files for the entire range.
        if comparison["status"] != "ahead" or not isinstance(files, list) or len(files) >= 300:
            return None, "comparison-incomplete"
        changed = set()
        for row in files:
            status, name = row["status"], row["filename"]
            if status == "renamed":
                paths = [(row["previous_filename"], previous), (name, snapshot)]
            elif status == "removed":
                paths = [(name, previous)]
            elif status in ("added", "copied"):
                paths = [(name, snapshot)]
            elif status in ("modified", "changed"):
                paths = [(name, previous), (name, snapshot)]
            else:
                return None, "comparison-incomplete"
            for path, ref in paths:
                if path == "kendex.toml":
                    return None, "shared-input"
                key = package(path)
                if key is None:
                    # D007's install record and kendex-generated renders
                    # describe this checkout, not additional catalog inputs.
                    if path in (".kendex-lock.json", ".kendex-generated.json") or path in generated(ref):
                        continue
                    return None, "shared-input"
                changed.add(key)
                if key[0] == "pi-extension":
                    changed.add((key[0], pi_name(key[1], ref)))
        return changed, None
    except unreadable as error:
        return None, f"comparison-{failure_code(error)}"

def lock_match(base, path, ref, changed):
    lock = json.loads(contents(base, path, ref, fleet=True))
    version = lock["version"]
    if version not in (11, 12):
        return "lock-version-unknown"
    # Version 11 recorded agent names before the catalog's alias migration.
    # The engine owns those aliases in source/config/agent_names.rs.
    legacy_agents = version == 11 and any(kind == "agent" for kind, _ in changed)
    catalog = source.removeprefix("repos/").casefold()
    fallback = None
    for row in lock["entries"].values():
        item = lock["installations"][row["installation"]] if version == 12 else row
        provenance, kind, name = row["sourceRepo"], item["kind"], item["name"]
        if not all(isinstance(value, str) and value for value in (provenance, kind, name)):
            return "lock-malformed-response"
        exact = (kind, name) in changed
        if not exact and not (legacy_agents and kind == "agent"):
            continue
        if provenance.casefold() == catalog:
            if exact:
                return "installed-package-changed"
        # Only a plain, distinct GitHub owner/repo proves a non-match.
        # The engine also accepts URL spellings; keep them conservative.
        elif re.fullmatch(r"[a-zA-Z0-9-]+/[a-zA-Z0-9_.-]+", provenance) and not provenance.casefold().endswith(".git"):
            continue
        if exact:
            fallback = "lock-source-unrecognized"
        elif fallback is None:
            fallback = "lock-legacy-agent-ambiguous"
    return fallback

def refresh_reason(repo, changed, fallback):
    if changed is None:
        return fallback
    if not changed:
        return None
    base = "repos/" + repo["full_name"]
    branch = urllib.parse.quote(repo["default_branch"], safe="")
    lock_path = ".kendex-lock.json"
    try:
        ref = get(f"{base}/git/ref/heads/{branch}", fleet=True)["object"]["sha"]
        if not re.fullmatch(r"[0-9a-f]{40}", ref):
            return "lock-head-unreadable"
        reason = lock_match(base, lock_path, ref, changed)
        if reason is not None:
            return reason
        # A root non-match alone cannot rule out nested project scopes. Use
        # one immutable branch snapshot for all lock and Git tree reads.
        tree = get(f"{base}/git/trees/{ref}?recursive=1", fleet=True)
        if tree["truncated"] is not False or not isinstance(tree["tree"], list):
            return "lock-tree-incomplete"
        expected_locks = set()
        checked_locks = set()
        for entry in tree["tree"]:
            path = entry["path"]
            directory, _, name = path.rpartition("/")
            if not directory:
                continue
            if name == "kendex.toml" and entry["type"] == "blob":
                expected_locks.add(f"{directory}/{lock_path}")
            elif name == lock_path:
                if entry["type"] != "blob" or entry["mode"] not in ("100644", "100755"):
                    return "lock-tree-incomplete"
                reason = lock_match(base, path, ref, changed)
                if reason is not None:
                    return reason
                checked_locks.add(path)
        # A refresh can install into a project without publishing a lock-only
        # update. A pinned manifest still needs usable sibling lock evidence.
        return None if expected_locks <= checked_locks else "lock-scope-missing"
    except unreadable + (AttributeError,) as error:
        return f"lock-{failure_code(error)}"

def failure_code(error):
    return error.code if isinstance(error, ApiError) else "malformed-response"

def collect(endpoint, key, *, fleet=True):
    rows = {}
    totals = set()
    duplicate = False
    try:
        for page in pages(endpoint, fleet=fleet):
            total, items = page["total_count"], page[key]
            if type(total) is not int or not isinstance(items, list):
                return rows, "malformed-response"
            totals.add(total)
            for row in items:
                duplicate |= row["id"] in rows
                rows[row["id"]] = row
    except unreadable as error:
        return rows, failure_code(error)
    return rows, "incomplete" if duplicate or totals != {len(rows)} else None

def receives(repo):
    base = "repos/" + repo["full_name"]
    # A complete workflow inventory distinguishes no caller from an
    # unreadable repository. A known caller still needs source proof.
    rows, failure = collect(f"{base}/actions/workflows", "workflows")
    matches = [row for row in rows.values() if row["path"] == caller]
    if len(matches) > 1:
        raise ApiError("duplicate-caller")
    if not matches or matches[0]["state"] != "active":
        return False, failure
    body = contents(base, caller, repo["default_branch"], fleet=True)
    # Adoption preserves this event declaration from the shipped
    # caller. An unfamiliar caller needs investigation before a
    # receipt can claim the fleet was covered.
    blocks = re.split(rb"(?m)^(?=[^\s#])", body)
    events = next((block for block in blocks if re.match(rb"(?:on|\"on\"|'on'):[ \t]*\r?\n", block)), b"")
    if not re.search(rb"^  repository_dispatch:[ \t]*\r?\n    types: \[kendex-refresh\]\r?$", events, re.M):
        raise ApiError("receiver-unrecognized")
    return True, failure

def destinations(failures):
    repos, failure = collect("installation/repositories", "repositories")
    if failure:
        failures[f"inventory-{failure}"] += 1
    if repo_id not in repos:
        failures["inventory-source-missing"] += 1
    targets = []
    for repo in repos.values():
        try:
            if repo["id"] == repo_id or repo["archived"] or repo["disabled"]:
                continue
            eligible, failure = receives(repo)
            if failure:
                failures[f"workflows-{failure}"] += 1
            if eligible:
                targets.append(repo)
        except unreadable as error:
            failures[f"caller-{failure_code(error)}"] += 1
    return len(repos), targets

def gate_clear(target):
    # A dispatch can bypass the consumer's release job only when no run is
    # waiting now. An unreadable inspection leaves recovery to the caller.
    try:
        reply = get(f"repos/{target}/actions/workflows/kendex-refresh.yml/runs?status=waiting&per_page=1",
                    fleet=True)
        total = reply["total_count"]
        return type(total) is int and total == 0 and reply["workflow_runs"] == []
    except unreadable:
        return False

def attempt(targets, failures, previous):
    if not targets:
        # A known Fleet with no eligible callers gets a red run. There was
        # no POST to duplicate, so a later trigger can retry discovery.
        failures["no-eligible-callers"] += 1
        return 0, 0

    # Snapshot after discovery and before the first POST. A merge
    # during fan-out must still get its own chance to dispatch.
    try:
        snapshot = get(f"{source}/git/ref/heads/main")["object"]["sha"]
        if not includes(trigger, snapshot):
            raise ApiError("trigger-missing")
    except unreadable as error:
        failures[f"main-{failure_code(error)}"] += 1
        return 0, 0
    # A newer normal push still goes through its own timer.
    if os.environ.get("DISPATCH_URGENT") == "true":
        snapshot = trigger

    changed, fallback = changed_packages(previous, snapshot)
    attempted = accepted = 0
    for repo in targets:
        # The source run is public. Repository IDs identify private targets
        # without disclosing their names.
        label = repo["full_name"] if repo.get("private") is False else str(repo["id"])
        reason = refresh_reason(repo, changed, fallback)
        if reason is None:
            print(f"consumer-dispatch: consumer={label} outcome=skipped reason=no-installed-package-changed")
            continue
        attempted += 1
        clear = gate_clear(repo["full_name"])
        try:
            gh(
                f"repos/{repo['full_name']}/dispatches", "--method", "POST",
                "--raw-field", "event_type=kendex-refresh",
                "--field", f"client_payload[gate_clear]={str(clear).lower()}", fleet=True,
            )
        except ApiError as error:
            failures[f"post-{error.code}"] += 1
            outcome = "failed"
        else:
            accepted += 1
            outcome = "sent"
        print(f"consumer-dispatch: consumer={label} outcome={outcome} reason={reason} gate-clear={str(clear).lower()}")

    # The daily backstop retries missed deliveries. The attempt receipt
    # keeps later matured triggers from resending to healthy recipients.
    record = pathlib.Path(os.environ["RUNNER_TEMP"]) / "receipt.json"
    try:
        record.write_text(json.dumps(dict(
            attempted=snapshot, trigger=trigger,
            run=int(os.environ["GITHUB_RUN_ID"]), attempt=int(os.environ["GITHUB_RUN_ATTEMPT"]),
        )))
        with open(os.environ["GITHUB_OUTPUT"], "a") as output:
            output.write(f"receipt={record}\n")
    except (OSError, ValueError):
        failures["receipt-write"] += 1
    return attempted, accepted

def read_priority():
    key = os.environ.get("KENDEX_DISPATCH_LINEAR_READ_KEY")
    if not key:
        return False, "secret-missing"
    try:
        event = json.loads(pathlib.Path(os.environ["GITHUB_EVENT_PATH"]).read_text())
        subject = event["head_commit"]["message"].partition("\n")[0]
        # A scoped conventional commit can cite other issues in its title.
        scope = re.match(r"^[a-z]+\((KEN-[0-9]+)\)!?:", subject)
        ids = {scope[1]} if scope else set(re.findall(r"\bKEN-[0-9]+\b", subject))
        if len(ids) != 1:
            return False, "subject-issue-missing" if not ids else "subject-issue-ambiguous"
        payload = dict(query="query($id: String!) { issue(id: $id) { priority } }",
                       variables={"id": ids.pop()})
        request = urllib.request.Request("https://api.linear.app/graphql", json.dumps(payload).encode(),
                                         {"Authorization": key, "Content-Type": "application/json"})
        with urllib.request.urlopen(request, timeout=10) as reply:
            result = json.load(reply)
        priority = result["data"]["issue"]["priority"]
        if result.get("errors") or type(priority) is not int or not 0 <= priority <= 4:
            return False, "linear-response-unreadable"
        return priority == 1, "linear-urgent" if priority == 1 else "linear-not-urgent"
    except (AttributeError, KeyError, TypeError, ValueError, OSError, http.client.HTTPException):
        return False, "linear-response-unreadable"

def priority_route():
    urgent, reason = read_priority()
    with open(os.environ["GITHUB_OUTPUT"], "a") as output:
        output.write(f"urgent={str(urgent).lower()}\n")
    print(f"consumer-dispatch: arrival={'immediate' if urgent else 'normal-wait'} reason={reason}")

def send():
    try:
        previous = last_attempt()
        if previous is not None and includes(trigger, previous):
            print("consumer-dispatch: outcome=covered")
            return 0
    except unreadable + (EOFError, RuntimeError, zlib.error):
        # Preserve the throttle during a receipt outage. The daily
        # backstop handles any event this sender cannot decide to send.
        print("::error::consumer-dispatch: receipt=unreadable")
        return 1
    failures = Counter()
    repos, targets = destinations(failures)
    attempted, accepted = attempt(targets, failures, previous)
    causes = ",".join(f"{code}:{count}" for code, count in sorted(failures.items()))
    print(f"consumer-dispatch: installation={repos} eligible={len(targets)} "
          f"attempted={attempted} accepted={accepted} failures={causes or 'none'}")
    return int(bool(failures))


if __name__ == "__main__":
    import sys
    if sys.argv[1:] == ["--priority"]:
        priority_route()
    else:
        source = "repos/" + os.environ["GITHUB_REPOSITORY"]
        trigger = os.environ["GITHUB_SHA"]
        repo_id = int(os.environ["GITHUB_REPOSITORY_ID"])
        receipt_name = os.environ["DISPATCH_RECEIPT_NAME"]
        raise SystemExit(send())
