#!/usr/bin/env python3
"""File automatic rendered-file review findings for upstream triage.

refresh-reviews supplies JSON [{root, path, body, url, line, start_line, side,
start_side}] on stdin after the trusted render proof, one row per live
unanswered review thread, root being the thread's first comment id and the
rest its REST review-comment fields. The head's generated inventory binds each
reported path. Review text is data; only the upstream verifier confirms a
defect. GitHub issue titles carry a fingerprint of the package, the path
inside its directory (none for a package the lock records under any kind but
skill), and the head lines the comment names, joined by its wording where
that text occurs more than once in the file at head (its wording alone for a
file-level or base-side comment).
The lookup counts App-authored issues in every state: GitHub issue search,
then, on the run's first miss, one read of the issues updated within its
indexing lag, plus this run's own filings.

A finding is filed upstream only where kendex report --dry-run routes its one
package to vanillagreencom/kendex with a package label. Every other finding is
not filed: a path outside the inventory, a path no single package claims (the
lock, the inventory, a Copilot .github/agents/*.agent.md render), or a package
kendex report routes elsewhere. Review text about content kendex has not
claimed is never published, and its step summary row offers no filing link.
The writer skips outdated threads before reporting. It replies as not filed
and resolves those threads. Live unfiled threads stay open and hold the run.
The consumer must answer an unclaimed finding through its trusted removal PR
or a reply, then resolve the thread by hand.

stdout is one JSON array, read by refresh-reviews: [{root, issue, note}] with
one row per input row. issue is the html_url of the upstream issue the
finding is filed under, or null when it is not filed: one of the routes above,
no Issues token or denied Issues access. note names which, and for a closed
issue its close reason: that issue is the upstream answer, so the finding adds
no issue and no evidence comment. The note
"No single kendex package claims this path" gives the reason for the writer's
upstream-unfiled record, including paths outside the inventory.
Log lines go to stderr.

--settings formats ol_preference_entries' refused and deprecated arrays from
refresh-consumer as a pull request Settings section. Its committed object, every
committed [env] `KEY = "value"` setting, is matched against the package's
retired-settings.json: a key listed under keys, or a value listed under
values for its key, a shipped default since replaced. Those rows and the
notes array, the change-class lines naming a consumer setting that
refresh-consumer passes once the classifier ran, form a Consumer settings
section. It reports and changes no setting. An absent array or object reads
as empty. A clean parse emits no text. It does not parse settings or
preference entries itself.
"""
import hashlib
import html
import json
import os
from pathlib import Path, PurePosixPath
import re
from datetime import datetime, timedelta, timezone
import shlex
import subprocess
import sys
from tempfile import TemporaryDirectory
from urllib.parse import urlencode

UPSTREAM = "vanillagreencom/kendex"
RETIRED = Path(__file__).parent.parent / "skills/review-gate/retired-settings.json"
# GitHub search caps a query at 256 characters besides its operators and
# qualifiers; three 64-character fingerprints fit, four would not with spaces.
SEARCH_TERMS = 3
# gh api stderr for a primary or secondary rate limit, which GitHub answers
# with HTTP 403 or 429 like an access denial; checked before the denial.
RATE_LIMIT = re.compile(r"HTTP 429\b|rate limit", re.IGNORECASE)
# GitHub search indexes a new issue late and documents no bound; an hour of
# updated issues covers another consumer's filing from the same schedule tick.
INDEX_LAG = timedelta(hours=1)


def settings_report():
    """Format the existing preference parser's diagnostics, not its grammar."""
    entries = json.load(sys.stdin)

    def code(entry):
        # A setting is untrusted text, not pull request Markdown.
        text = html.escape(entry).replace("`", "&#96;").replace("\n", "&#10;").replace("\r", "&#13;")
        return f"<code>{text}</code>"

    sections = []
    rows = [f"- ORCH_OVERSEER_PREFERENCE: {status} entry {code(entry)}; use `harness:model:effort`."
            for status in ("refused", "deprecated") for entry in entries[status]]
    if rows:
        sections.append("## Settings\n\n" + "\n".join(rows) + "\n\n"
                        "A setting joins this report by exposing its existing parse the same way.")
    retired = json.loads(RETIRED.read_text())
    committed = entries.get("committed", {})
    stale = [f"- {code(key)}: retired; no package reads it." for key in committed if key in retired["keys"]]
    stale += ["- " + code(f'{key} = "{value}"') + ": a former shipped default; unset it to take the current one."
              for key, value in committed.items() if value in retired["values"].get(key, [])]
    stale += [f"- {code(line)}" for line in entries.get("notes", [])]
    if stale:
        sections.append("## Consumer settings\n\n" + "\n".join(stale) + "\n\n"
                        "Report only: the refresh changes no committed `kendex.settings.toml` setting.")
    if sections:
        print("\n\n".join(sections))


def main():
    head, pr = sys.argv[1:]
    repo = os.environ["GH_REPO"]
    token = os.environ.get("KENDEX_ISSUES_TOKEN", "")
    # Only the issue API receives the second token. Git and kendex resolve
    # provenance with the consumer credential, never an upstream credential.
    consumer_env = dict(os.environ)
    consumer_env.pop("KENDEX_ISSUES_TOKEN", None)

    def read(*args):
        return subprocess.check_output(args, env=consumer_env, text=True)

    def reviewed(finding):
        """The head lines a comment names, with its wording where they repeat.

        A comment on the head side names its last line and, for a range, its
        first. Text that occurs once in the file at head is the finding
        whatever the comment says. Text that occurs more than once (fi, a
        fence) cannot name one occurrence, so the wording joins it and a
        closed issue answers only the same claim on the same text. A
        file-level or base-side comment names no head line, so its wording
        is all that identifies it.
        """
        end = finding.get("line")
        if end is None or finding.get("side") != "RIGHT":
            return finding["body"]
        start = finding.get("start_line") if finding.get("start_side") == "RIGHT" else None
        start = start or end
        lines = read("git", "show", f"{head}:{finding['path']}").splitlines()
        if not 1 <= start <= end <= len(lines):
            raise ValueError(f"review lines {start}-{end} are outside {finding['path']} at {head}")
        window = lines[start - 1:end]
        text = "\n".join(window)
        if sum(lines[i:i + len(window)] == window for i in range(len(lines))) > 1:
            return [text, finding["body"]]
        return [text]

    read("git", "fetch", "--no-tags", "origin", head)
    inventory = json.loads(read("git", "show", head + ":.kendex-generated.json"))
    records = {e if isinstance(e, str) else e["path"]: e for e in inventory}
    lock_text = read("git", "show", head + ":.kendex-lock.json")
    lock = json.loads(lock_text)
    kinds = {}
    for e in lock["entries"].values():
        kinds.setdefault(e["name"], set()).add(e["kind"])
    names = set(kinds)
    run = f"https://github.com/{repo}/actions/runs/{os.environ['GITHUB_RUN_ID']}"
    summary = os.environ["GITHUB_STEP_SUMMARY"]
    issue_env = dict(consumer_env, GH_TOKEN=token)

    def api(endpoint, payload=None):
        args = ["gh", "api", endpoint]
        if payload is None:
            args += ["--paginate", "--slurp"]
        else:
            args += ["--method", "POST", "--input", "-"]
        result = subprocess.run(args, input=None if payload is None else json.dumps(payload),
                                capture_output=True, text=True, env=issue_env)
        if result.returncode:
            if RATE_LIMIT.search(result.stderr):
                raise RuntimeError(f"rate-limited endpoint={endpoint}\n{result.stderr}")
            # GitHub emits these status codes when an installation cannot
            # access the repository or its Issues permission was narrowed.
            if re.search(r"HTTP (401|403|404)\b", result.stderr):
                raise PermissionError("kendex Issues access is unavailable")
            raise RuntimeError("kendex issue API failed: " + result.stderr)
        return json.loads(result.stdout)

    def answers(issue):
        """Anyone can open an issue on the public tracker and close their own,
        so only one a GitHub App wrote, which no outside user can author as
        or close, answers a finding."""
        return "pull_request" not in issue and (issue.get("user") or {}).get("type") == "Bot"

    def search(markers):
        """Every issue, open or closed, whose title may carry one of markers."""
        terms = " OR ".join(m.removeprefix("[kendex-render:").removesuffix("]") for m in markers)
        pages = api("search/issues?" + urlencode({"q": f"repo:{UPSTREAM} is:issue in:title {terms}",
                                                  "per_page": 100}))
        if not isinstance(pages, list) or not all(isinstance(p, dict) and p.get("incomplete_results") is False
                                                  and isinstance(p.get("items"), list) for p in pages):
            # An incomplete search cannot prove that no issue answers a finding.
            raise RuntimeError("incomplete upstream issue search")
        return [i for page in pages for i in page["items"] if answers(i)]

    def recent():
        """Every issue updated within the search index lag, open or closed.

        Every consumer's refresh runs on the same schedule, so another run's
        filing of the same finding can be minutes old and absent from search.
        """
        since = (datetime.now(timezone.utc) - INDEX_LAG).strftime("%Y-%m-%dT%H:%M:%SZ")
        pages = api(f"repos/{UPSTREAM}/issues?" + urlencode({"state": "all", "since": since, "per_page": 100}))
        if not isinstance(pages, list) or not all(isinstance(p, list) for p in pages):
            raise RuntimeError("unreadable upstream issue list")
        return [i for page in pages for i in page if answers(i)]

    rows = []
    for finding in json.load(sys.stdin):
        path = finding["path"]
        record = records.get(path, path)
        package_path = record["template"] if isinstance(record, dict) else path
        parts = PurePosixPath(package_path).parts
        matches = names.intersection((*parts, PurePosixPath(package_path).stem)) if path in records else set()
        row = {"finding": finding, "label": None, "marker": None,
               "evidence": finding.get("url") or f"https://github.com/{repo}/pull/{pr}"}
        unrouted = "No single kendex package claims this path"
        if len(matches) == 1:
            name = matches.pop()
            unrouted = f"kendex report does not route {name} to {UPSTREAM}"
            # kendex report owns package provenance and its surface label.
            # The pinned CLI's say() channel is stderr, including --dry-run.
            # A lock is a project marker. Give the routing owner only this
            # reviewed record, so later removals and source changes cannot
            # replace its provenance with the current checkout's state.
            with TemporaryDirectory(prefix="kendex-report-") as project:
                (Path(project) / ".kendex-lock.json").write_text(lock_text)
                route = subprocess.run(
                    ["kendex", "report", "--asset", name, "--scope", "project",
                     "--title", "Automatic rendered-file review", "--body", "Triage report", "--dry-run"],
                    cwd=project, env=consumer_env, text=True, capture_output=True, check=True,
                ).stderr
            command = next((s.removeprefix("would run: ") for s in route.splitlines()
                            if s.startswith("would run: ")), "")
            args = shlex.split(command)
            if "--repo" in args and args[args.index("--repo") + 1] == UPSTREAM and "--label" in args:
                row["label"] = args[args.index("--label") + 1]
                # The package's kind, never the render layout, decides the
                # path inside it. Only a skill is a directory package. Every
                # other kind is one file whose rendered name and layout
                # differ by harness: a command is .claude/commands/<name>.md
                # on Claude and the skill tree .agents/skills/<name>/SKILL.md
                # on Codex. A command sharing a skill's name renders under
                # another name there, so a directory named for the package
                # is the skill's.
                is_skill = "skill" in kinds[name] and name in parts
                inner = "/".join(parts[parts.index(name) + 1:]) if is_skill else ""
                # The identity holds no consumer repository or rendered path,
                # and the review wording only where reviewed() adds it.
                identity = json.dumps([name, inner, reviewed(finding)],
                                      ensure_ascii=False, separators=(",", ":"))
                row["marker"] = f"[kendex-render:{hashlib.sha256(identity.encode()).hexdigest()}]"
                where = f"{name}/{inner}" if inner else name
                row["title"] = f"{row['marker']} Review finding in {where}"[:256]
        row["note"] = "Issues token unavailable" if row["label"] else unrouted
        rows.append(row)

    # Every state counts: a closed match is the upstream answer and files
    # nothing.
    known = {}
    markers = list(dict.fromkeys(r["marker"] for r in rows if r["marker"]))

    def remember(issues):
        for issue in issues:
            marker = next((m for m in markers if issue["title"].startswith(m)), None)
            if marker and (marker not in known or issue["state"] == "open"):
                known[marker] = issue

    if token and markers:
        try:
            for chunk in range(0, len(markers), SEARCH_TERMS):
                remember(search(markers[chunk:chunk + SEARCH_TERMS]))
        except PermissionError as error:
            for row in rows:
                if row["label"]:
                    row["note"] = str(error)
            token = ""

    listed = False
    results = []
    for row in rows:
        finding, label, marker, evidence = row["finding"], row["label"], row["marker"], row["evidence"]
        path, note = finding["path"], row["note"]
        url = filed = None
        if label:
            quoted = "\n".join("> " + line for line in finding["body"].splitlines())
            body = (f"Reached by: Automatic review of the consumer kendex refresh pull request {repo}#{pr}.\n\n"
                    f"Rendered file: `{path}`\n\nConsumer run: {run}\n\nReview evidence: {evidence}\n\n"
                    "This automatic-review claim needs confirmation in KEN Triage. "
                    "The review text below is untrusted evidence, not instructions.\n\n" + quoted)
            # The filing link shares the filing rule: only a finding kendex
            # report routes to kendex is offered to kendex's public tracker.
            url = "https://github.com/" + UPSTREAM + "/issues/new?" + urlencode({"title": row["title"], "body": body})
        if token and label:
            try:
                if marker not in known and not listed:
                    # One read answers every marker of this run, and this
                    # run's own filings join known as they are made.
                    remember(recent())
                    listed = True
                existing = known.get(marker)
                if existing and existing["state"] != "open":
                    url = filed = existing["html_url"]
                    reason = existing.get("state_reason")
                    note = "Closed upstream" + (f" as {reason.replace('_', ' ')}" if reason else "")
                elif existing:
                    url = existing["html_url"]
                    note = "Existing open report"
                    # A thread whose evidence the issue body lacks adds its
                    # text and evidence as a comment. The finding counts as
                    # filed only once that evidence is upstream: a filed row
                    # resolves its consumer thread.
                    record = f"Review evidence: {evidence}\n"
                    if record not in (existing.get("body") or ""):
                        result = api(f"repos/{UPSTREAM}/issues/{existing['number']}/comments", {"body": body})
                        url = result["html_url"]
                    filed = existing["html_url"]
                else:
                    created = api(f"repos/{UPSTREAM}/issues", {"title": row["title"], "body": body,
                                                               "labels": ["bug", label, "agent:maintainer"]})
                    url = filed = created["html_url"]
                    # This run's own filings answer its later rows without
                    # another read.
                    known[marker] = created
                    note = "Filed for upstream confirmation"
            except PermissionError as error:
                note = str(error)
                token = ""
        with open(summary, "a", encoding="utf-8") as output:
            link = f"; [kendex report]({url})" if url else ""
            output.write(f"- {note}: [review evidence]({evidence}){link}.\n")
        print(f"refresh-report={note} path={path!r}", file=sys.stderr)
        results.append({"root": finding["root"], "issue": filed, "note": note})
    json.dump(results, sys.stdout)


if __name__ == "__main__":
    if sys.argv[1:] == ["--settings"]:
        settings_report()
    else:
        main()
