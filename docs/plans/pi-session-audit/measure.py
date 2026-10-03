#!/usr/bin/env python3
"""KEN-2343 measure script: one lane's session measures as one JSON object.

usage: measure.py archive (--root ARCHIVE_ROOT | --dir ITEM_DIR) [--since DATE]
                          [--oversee-state REPO=FILE]... [--brief-tail REPO=FILE]...
                          [--min-free-gb N]
       measure.py live [--home DIR] [--item ITEM] [--repo REPO]
       measure.py aggregate [FILE...]

Python 3.8+, standard library only. Reads, never writes. Notices go to stderr,
first line `measure: KEY=VALUE`.

archive  Runs on the control host, first. --root is the archive root
         (/home/admin/.fleet/archive): every <repo>/<item> directory under it is
         one item; --dir reads one item directory. For each item it prints
         `df -h /` to stderr, stops with exit 3 when free space on / is under
         --min-free-gb (default 3), then reads every tokens-*.json and every
         tmp-*.tgz whose close falls on or after --since (default 2026-10-01;
         a record's `at`, else the file's mtime; "" reads everything). It lists
         each archive with `tar -tzf` and streams only the members it needs, one
         at a time, with `tar -xzOf ARCHIVE -- MEMBER`; it never extracts an
         archive. It prints one JSON line per item with at least one kept
         record, and a last `measure: archive-done=` notice on stderr.
         --oversee-state names a repository's tmp/workflow-state-oversee.json,
         --brief-tail its tmp/brief-tail-template.md; repeat per repository.
         Measures 1, 4 and 5.

live     Runs inside one open Pi lane's sandbox (`lane-host-daytona exec --item
         ITEM`), before its close. Walks the session stores under --home
         (default $HOME):
           pi            .pi/agent/sessions/**/*.jsonl
           pi-kendex     .pi/agent/kendex/sessions/**/*.jsonl (pi-agents-tmux
                         subagent sessions; files that are no Pi session are
                         counted under skipped_non_session)
           claude        .claude-shared/projects/**/*.jsonl, then
                         .claude/projects/**/*.jsonl (a file both reach is read once)
           copilot       .copilot*/session-state/*/events.jsonl
         and prints one JSON line: measures 2 and 3 per session, plus token
         totals per session.

aggregate  Reads archive and live lines (files, or stdin) and prints the
         measure-by-harness table as one JSON line. Every cell carries n, its
         item count and the measure's source. A measure with fewer than 8 Pi
         items reads "too small to judge" in every cell, with n kept and no
         median or p90. Median is the middle value (mean of the two middle
         values for even n); p90 is the nearest-rank 90th percentile.

Exit status: 0 done; 2 bad arguments or an unreadable required input; 3
stopped on low disk (the lines already printed are complete items).

Output schema, live (`schema`: "pi-session-audit/live/1"):
  mode, item, repo, read_at, home
  stores.<name>         {root, present, files, unreadable, skipped_non_session}
  append_system         installed ~/.pi/agent/APPEND_SYSTEM.md bytes per package,
                        "other" for text outside package markers; null if absent
  output_policy_artifacts {files, bytes} saved full outputs under the kendex store
  duplicate_assistant_messages  Pi assistant messages seen in an earlier file
  sessions[]            one per transcript file:
    harness             pi | claude | copilot
    store, path         store name and path relative to its root
    session_id, parent_session, subagent, cwd, started_at, ended_at
    models              {"provider/model": assistant message count}
    tokens              {input, output, cache_read, cache_write, total,
                         recorded, unrecorded} or "not recorded"
    context             measure 2 (Pi only; "not applicable" elsewhere):
      system_messages   system messages in the file (each one patches the prompt)
      sections_bytes    final prompt section name -> bytes
      addendum_by_package  addendum section bytes per package marker, "other"
      tool_definitions  {ours: {package: {tools: [...], bytes}},
                         builtin: {tools, bytes}, unattributed: {tools: [...], bytes}}
      tools_section_by_package  bytes of `- name: snippet` lines per package
      custom_entries    customType -> {package, count, bytes}
      custom_messages   customType -> {package, count, bytes, hidden}
      nested_agents_md  {parts, bytes} text parts pi-nested-agents-md appended
      output_policy     {results, truncated, minimized_only, minimized_lines,
                         sanitized_details, before_bytes, after_bytes}
      tool_result_bytes text bytes of every tool result as recorded
      forced_prompt_appends  "not recorded" (see method section)
    tools               measure 3: {calls, results, errors, interrupted,
                         by_tool: {name: {calls, errors}},
                         errors_by_class: {extension, model, provider,
                         repository, unclassified}, error_rows[]}
      error_rows[]      {source, tool, class, rule, package, excerpt}; excerpt
                        (first 200 characters) only for extension and
                        unclassified rows; at most 50 rows per session
    owed_turns          turn ends a Stop hook refused, or "not recorded"
  errors[]              {path, error}: files or lines that could not be read

Output schema, archive, one line per item (`schema`: "pi-session-audit/archive/2"):
  mode, read_at, dir, repo, item
  harness               the oversee lane record's harness, else the one harness
                        with tokens in the kept records, "mixed" for several
  token_harnesses       harnesses with tokens in the kept records
  outcome               {merged, wall_secs, paused_secs, fix_rounds,
                         stopped_parked_or_paused, tier}; null fields
                         without an oversee lane record
  token_field_order_assumed  the four names given to models.<model>[0..3]
  token_records[]       {file, at, harnesses: {h: {files, unreadable, unrecorded,
                         models: {m: {input, output, cache_read, cache_write, total,
                         unknown?}}}}}; a null count stays null and is named in
                         `unknown`; total sums the known counts
  token_totals          {h: {input, output, cache_read, cache_write, total, unknown}}
                        `unknown` counts the null counts summed as 0
  tmp_archives[]        {file, members, read: [{member, kind, bytes}], skipped}
  lane_status[]         {member, keys} top-level keys of each lane-status member
  lane_mail             {envelopes, by_kind, asks: [{id, at, terms, excerpt}]}
                        from the item's own `lane-mail/<item>/to-overseer.jsonl`,
                        each envelope id once
  item_state            {cycles, rereview_cycles, pr_comment_iterations,
                         fixes, skipped, escalated_items} or null
  oversee               {lanes: [lane record subset], fleet_log: {rows, by_kind,
                         relaunch_rows}} or null
  brief_tail            {clauses, harness_only: {h: n}} for the repository, or null
  disk                  {before, free_bytes} read before this item
  errors[]              {path, error}

Output schema, aggregate (`schema`: "pi-session-audit/aggregate/1"):
  rule                  the reporting rule as text
  inputs                archive_lines, probe_items_excluded (item keys that are
                        no tracker id), no_harness_excluded, items, items_by_lead,
                        items_with_lane_record, items_with_tokens_by_harness,
                        mixed_token_items_by_lead, foreign_mailbox_items_by_lead
                        (schema-1 lines that read another item's mailbox; their
                        asks are left out), tokens_under_another_lead
                        ("<harness> under <lead>": {items, median_total,
                        max_total}), incomplete_token_items_by_harness,
                        items_with_issue_fields, matched_strata, live_sessions
  model_mix             {lead: {lane_record: {model: items}, token_record:
                         {model: records}}}
  ask_groups            {lead: {items, asks, <ASK_GROUPS group | other>: asks}}
                        over the items the lane-mail ask measure counts
  all.<measure>         {source, unit (item | session), pi_items, verdict
                         ("judged" | "too small to judge" | "not sampled (n=0)"),
                         cells: {harness: {n, items, median, p90} or {n, items,
                         share} or {n, items, verdict}}}; a harness outside
                        pi, claude and copilot reads "outside the comparison"
  by_model.<measure>.<model family>  the same over items of one model
  matched.<measure>."<repo>|<agent label>|<band>"  the same over one stratum
                        holding Pi and Claude Code or Copilot CLI items
  unmatched.<measure>   the same over every item outside a matched stratum
  --issues FILE is {item: {estimate, agent}} from the tracker; without it no
  stratum matches. An item key is a work item when it has a tracker id's
  shape (`ABC-123` in any case, or a GitHub `issue-123`) and, when --issues
  is given, its canonical id is a key there; every other key is a probe and
  left out. A GitHub key's id is `<repo>/issue-N`, the form --issues keys it
  by. The rule reads no environment and no repository setting.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import glob
import gzip
import json
import math
import os
import re
import shutil
import subprocess
import sys
from typing import Any, Dict, Iterator, List, Optional, Tuple

LIVE_SCHEMA = "pi-session-audit/live/1"
ARCHIVE_SCHEMA = "pi-session-audit/archive/2"
AGGREGATE_SCHEMA = "pi-session-audit/aggregate/1"

# The owner's sample start: every kept close record from this date on.
DEFAULT_SINCE = "2026-10-01"
# Reporting rule: a measure with fewer Pi items than this is not a finding.
MIN_PI_ITEMS = 8
TOO_SMALL = "too small to judge"

# Every package directory under pi-extensions/. test_measure.py holds this
# list equal to the directory listing.
PACKAGES = (
    "pi-agents-tmux", "pi-background-tasks", "pi-caveman", "pi-claude-bridge",
    "pi-codex-minimal-tools", "pi-extension-manager", "pi-hooks",
    "pi-nested-agents-md", "pi-output-policy", "pi-prompt-stash", "pi-qol",
    "pi-questions", "pi-session-bridge", "pi-session-manager",
    "pi-skills-manager", "pi-task-panel", "pi-tool-renderer", "pi-web-tools",
)

# Tools our packages register that Pi does not ship. test_measure.py extracts
# the registered names from pi-extensions source and holds this table equal.
TOOL_OWNERS = {
    "subagent": "pi-agents-tmux", "delegate_subagent": "pi-agents-tmux",
    "complete_subagent": "pi-agents-tmux", "get_subagent_result": "pi-agents-tmux",
    "wait_for_subagent_idle": "pi-agents-tmux", "steer_subagent": "pi-agents-tmux",
    "stop_subagent": "pi-agents-tmux",
    "bg_task": "pi-background-tasks", "bg_status": "pi-background-tasks",
    "question": "pi-questions",
    "tasks_write": "pi-task-panel",
    "tool_batch": "pi-tool-renderer",
    "image_generation": "pi-codex-minimal-tools", "view_image": "pi-codex-minimal-tools",
    "apply_patch": "pi-codex-minimal-tools",
    "web_search": "pi-web-tools", "web_fetch": "pi-web-tools",
    "web_research": "pi-web-tools", "web_answer": "pi-web-tools",
    "web_find_similar": "pi-web-tools", "code_search": "pi-web-tools",
    "get_web_content": "pi-web-tools", "fetch_content": "pi-web-tools",
    "get_search_content": "pi-web-tools", "web_search_exa": "pi-web-tools",
    "web_fetch_exa": "pi-web-tools", "web_research_exa": "pi-web-tools",
    "web_answer_exa": "pi-web-tools", "web_find_similar_exa": "pi-web-tools",
}

# Pi built-ins pi-tool-renderer registers again under the same name. Each
# override takes the built-in's contract and runs the built-in's execute, so
# its definition bytes and its errors are Pi's, not the package's.
PASS_THROUGH_OVERRIDES = frozenset(("read", "bash", "edit", "write", "grep", "find", "ls"))

# customType prefix -> owning package, first match wins. test_measure.py
# checks every customType literal in pi-extensions source maps to its own
# package here.
CUSTOM_TYPE_OWNERS = (
    ("kendex-hook", "pi-hooks"), ("kendex-drift", "pi-hooks"),
    ("kendex-clippy", "pi-hooks"), ("kendex-lane-mail-wake", "pi-hooks"),
    ("kendex-task-panel:", "pi-task-panel"),
    ("kendex-background-tasks:", "pi-background-tasks"),
    ("kendex-subagents:", "pi-agents-tmux"), ("subagent-", "pi-agents-tmux"),
    ("qol-", "pi-qol"),
    ("claude-bridge-", "pi-claude-bridge"),
    ("codex-", "pi-codex-minimal-tools"),
    ("pi-web-tools.", "pi-web-tools"),
    ("pi.", "pi"),
)

# The order a kept tokens-<sandbox-id>.json lists the four counts of
# models.<model>. Assumed, not read from the writer: the overseer verifies it
# against a real record before the run.
TOKEN_RECORD_FIELDS = ("input", "output", "cache_read", "cache_write")

EXCERPT_CHARS = 200
MAX_ERROR_ROWS = 50
MEMBER_CAP_BYTES = 16 * 1024 * 1024
HARNESS_WORDS = {
    "pi": re.compile(r"\bpi\b|\bpi-[a-z]", re.I),
    "claude": re.compile(r"\bclaude\b", re.I),
    "copilot": re.compile(r"\bcopilot\b", re.I),
    "codex": re.compile(r"\bcodex\b", re.I),
}
HARNESS_DEFECT_TERMS = re.compile(
    r"\b(pi-[a-z-]+|extension|harness|tool (?:error|failed)|crash(?:ed)?|hang(?:s|ing)?|"
    r"relaunch|stuck|wedged|output-policy|truncat\w*|subagent)\b", re.I)

_PACKAGE_ALT = "|".join(re.escape(p) for p in sorted(PACKAGES, key=len, reverse=True))
PACKAGE_NAMED = re.compile(r"(?:@vanillagreen/|pi-extensions/|\b)(" + _PACKAGE_ALT + r")\b")

# Error classification, one table, first matching row wins. `kind` limits a
# row to tool results ("tool"), turn-level errors ("turn") or both ("any").
# `tool` limits a row to calls of our tools ("ours"). Each `example` is a real
# message text from the cited source; test_measure.py classifies every one.
ERROR_RULES = (
    # Not a failure of the call: the lane or person stopped it.
    {"rule": "interrupted", "class": "interrupted", "kind": "tool",
     "pattern": r"^(Operation aborted|aborted|Command aborted)\b|\[Request interrupted|The user doesn't want to proceed",
     "example": "Operation aborted"},  # pi-agent-core agent-loop.js:438
    {"rule": "pi-arguments-invalid", "class": "model", "kind": "tool",
     "pattern": r"^Validation failed for tool ",
     "example": 'Validation failed for tool "read":\n  - path: must be string'},  # pi-ai utils/validation.js:306
    {"rule": "pi-tool-unknown", "class": "model", "kind": "tool",
     "pattern": r"^Tool \S+ not found$",
     "example": "Tool web_serach not found"},  # pi-agent-core agent-loop.js:486
    {"rule": "pi-arguments-truncated", "class": "model", "kind": "tool",
     "pattern": r"was not executed: the response hit the output token limit",
     "example": 'Tool call "write" was not executed: the response hit the output token limit, so its arguments may be truncated. Re-issue the tool call with complete arguments.'},  # agent-loop.js:353
    {"rule": "claude-tool-use-error", "class": "model", "kind": "tool",
     "pattern": r"^<tool_use_error>",
     "example": "<tool_use_error>InputValidationError: Read failed due to the following issue:\nThe required parameter `file_path` is missing</tool_use_error>"},
    {"rule": "pi-hooks-registry-unreadable", "class": "extension", "kind": "tool",
     "pattern": r"^hook-registry-unreadable=", "package": "pi-hooks",
     "example": "hook-registry-unreadable=tool_call\nNo hook ran. unexpected token"},  # pi-hooks dispatch.ts:227
    {"rule": "our-tool", "class": "extension", "kind": "tool", "tool": "ours",
     "pattern": r"",
     "example": "Stored content id not found: web-123."},  # pi-web-tools get-web-content.ts:102
    {"rule": "hook-refusal", "class": "repository", "kind": "tool",
     "pattern": r"^(PreToolUse:\S+ hook error|[a-z0-9][a-z0-9-]*: [a-z][a-z0-9_-]*=)",
     "example": "skill-load-check: unloaded=linear\nthe agent making this call has not loaded the linear skill"},
    {"rule": "command-exit", "class": "repository", "kind": "tool",
     "pattern": r"Command exited with code \d+|^Exit code \d+|Command timed out after \d+ seconds",
     "example": "error: could not compile\n\nCommand exited with code 101"},  # pi bash.js:297
    {"rule": "names-package", "class": "extension", "kind": "any",
     "pattern": PACKAGE_NAMED.pattern,
     "example": "TypeError: x is undefined\n    at /home/u/.pi/agent/packages/@vanillagreen/pi-qol/extensions/qol.ts:10:3"},
    {"rule": "file-arguments", "class": "model", "kind": "tool",
     "pattern": r"^(ENOENT|EISDIR|ENOTDIR)\b|^Could not (find|edit)|^Found \d+ occurrences|^Offset \d+ is beyond|"
                r"^No changes made to|oldText must not be empty|^File does not exist|File has not been read yet|"
                r"^String to replace not found|^Working directory does not exist",
     "example": "Could not find the exact text in src/a.ts. The old text must match exactly including all whitespace and newlines."},  # pi edit-diff.js:184
    {"rule": "turn-error", "class": "provider", "kind": "turn",
     "pattern": r"",
     "example": "429 Too Many Requests: rate limited"},
)
_COMPILED_RULES = [dict(r, regex=re.compile(r["pattern"])) for r in ERROR_RULES]
ERROR_CLASSES = ("extension", "model", "provider", "repository", "unclassified")


def classify(text: str, kind: str, tool: Optional[str] = None) -> Tuple[str, str, Optional[str]]:
    """Return (class, rule, package) for one error. `kind` is "tool" or "turn"."""
    ours = tool is not None and tool in TOOL_OWNERS
    for row in _COMPILED_RULES:
        if row["kind"] not in (kind, "any"):
            continue
        if row.get("tool") == "ours" and not ours:
            continue
        match = row["regex"].search(text)
        if match is None:
            continue
        package = row.get("package")
        if row["rule"] == "our-tool":
            package = TOOL_OWNERS[tool]  # type: ignore[index]
        elif row["rule"] == "names-package":
            package = match.group(1)
        return row["class"], row["rule"], package
    return "unclassified", "none", None


def custom_type_owner(custom_type: str) -> str:
    for prefix, package in CUSTOM_TYPE_OWNERS:
        if custom_type.startswith(prefix):
            return package
    return "unattributed"


def now_iso() -> str:
    return _dt.datetime.now(_dt.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def notice(key: str, value: Any, explanation: str) -> None:
    print("measure: %s=%s" % (key, json.dumps(value, sort_keys=True)), file=sys.stderr)
    print(explanation, file=sys.stderr)


def nbytes(value: Any) -> int:
    if isinstance(value, str):
        return len(value.encode("utf-8"))
    return len(json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8"))


def text_of(content: Any) -> str:
    """Joined text of a Pi/Claude content value: a string or a block list."""
    if isinstance(content, str):
        return content
    if not isinstance(content, list):
        return ""
    parts = []
    for block in content:
        if isinstance(block, dict):
            if isinstance(block.get("text"), str):
                parts.append(block["text"])
            elif isinstance(block.get("content"), (str, list)):
                parts.append(text_of(block["content"]))
    return "\n".join(parts)


def read_jsonl(path: str, errors: List[Dict[str, Any]]) -> Iterator[Dict[str, Any]]:
    """Yield each JSON object line. A bad line is reported, never skipped silently."""
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        for number, line in enumerate(handle, 1):
            line = line.strip()
            if not line:
                continue
            try:
                value = json.loads(line)
            except ValueError as error:
                errors.append({"path": path, "error": "line %d: %s" % (number, error)})
                continue
            if isinstance(value, dict):
                yield value
            else:
                errors.append({"path": path, "error": "line %d: not an object" % number})


def new_tokens() -> Dict[str, int]:
    return {"input": 0, "output": 0, "cache_read": 0, "cache_write": 0, "total": 0, "recorded": 0, "unrecorded": 0}


def add_tokens(tokens: Dict[str, int], inp: Any, out: Any, read: Any, write: Any) -> None:
    values = [v if isinstance(v, int) and not isinstance(v, bool) else None for v in (inp, out, read, write)]
    if any(v is None for v in values):
        tokens["unrecorded"] += 1
        return
    tokens["recorded"] += 1
    for name, value in zip(("input", "output", "cache_read", "cache_write"), values):
        tokens[name] += value  # type: ignore[operator]
        tokens["total"] += value  # type: ignore[operator]


def new_tools() -> Dict[str, Any]:
    return {"calls": 0, "results": 0, "errors": 0, "interrupted": 0, "by_tool": {},
            "errors_by_class": {c: 0 for c in ERROR_CLASSES}, "error_rows": []}


def record_call(tools: Dict[str, Any], name: str) -> None:
    tools["calls"] += 1
    tools["by_tool"].setdefault(name, {"calls": 0, "errors": 0})["calls"] += 1


def record_error(tools: Dict[str, Any], source: str, tool: Optional[str], text: str, kind: str) -> None:
    cls, rule, package = classify(text, kind, tool)
    if cls == "interrupted":
        tools["interrupted"] += 1
        return
    tools["errors"] += 1
    tools["errors_by_class"][cls] += 1
    if tool is not None:
        tools["by_tool"].setdefault(tool, {"calls": 0, "errors": 0})["errors"] += 1
    if len(tools["error_rows"]) < MAX_ERROR_ROWS:
        row = {"source": source, "tool": tool, "class": cls, "rule": rule, "package": package}
        if cls in ("extension", "unclassified"):
            row["excerpt"] = text[:EXCERPT_CHARS]
        tools["error_rows"].append(row)


# ---------------------------------------------------------------- Pi sessions

def split_addendum(text: str) -> Dict[str, int]:
    """Bytes of an addendum section per kendex:append-system package marker."""
    out: Dict[str, int] = {}
    covered = 0
    for match in re.finditer(r"<!-- kendex:append-system @vanillagreen/(\S+) begin -->(.*?)"
                             r"<!-- kendex:append-system @vanillagreen/\1 end -->", text, re.S):
        size = nbytes(match.group(2))
        out[match.group(1)] = out.get(match.group(1), 0) + size
        covered += size
    out["other"] = nbytes(text) - covered
    return out


def tool_definition_bytes(tool: Dict[str, Any]) -> int:
    return nbytes({k: tool.get(k) for k in ("name", "description", "parameters")})


def pi_context_from_system(sections: Dict[str, str], tools: Dict[str, int]) -> Dict[str, Any]:
    by_owner: Dict[str, Dict[str, Any]] = {}
    builtin = {"tools": 0, "bytes": 0}
    for name, size in sorted(tools.items()):
        owner = TOOL_OWNERS.get(name)
        if owner is not None:
            slot = by_owner.setdefault(owner, {"tools": [], "bytes": 0})
            slot["tools"].append(name)
            slot["bytes"] += size
        else:
            builtin["tools"] += 1
            builtin["bytes"] += size
    tools_section: Dict[str, int] = {}
    for line in sections.get("tools", "").splitlines():
        match = re.match(r"^- ([A-Za-z0-9_]+): ", line)
        if match and match.group(1) in TOOL_OWNERS:
            owner = TOOL_OWNERS[match.group(1)]
            tools_section[owner] = tools_section.get(owner, 0) + nbytes(line) + 1
    addendum = sections.get("addendum")
    return {
        "sections_bytes": {k: nbytes(v) for k, v in sorted(sections.items())},
        "addendum_by_package": split_addendum(addendum) if addendum else {},
        "tool_definitions": {"ours": by_owner, "builtin": builtin},
        "tools_section_by_package": tools_section,
    }


def apply_system(message: Dict[str, Any], sections: Dict[str, str], tools: Dict[str, int]) -> None:
    """Replay one Pi system message onto the running prompt sections and tool set."""
    if message.get("replace"):
        sections.clear()
        tools.clear()
    for name, value in (message.get("sections") or {}).items():
        if value is None:
            sections.pop(name, None)
        elif isinstance(value, str):
            sections[name] = value
    for tool in message.get("toolsAdded") or []:
        if isinstance(tool, dict) and isinstance(tool.get("name"), str):
            tools[tool["name"]] = tool_definition_bytes(tool)
    for tool in message.get("toolsRemoved") or []:
        if isinstance(tool, dict):
            tools.pop(tool.get("name"), None)


def assistant_key(message: Dict[str, Any]) -> str:
    if isinstance(message.get("responseId"), str):
        return "r:" + message["responseId"]
    usage = message.get("usage") or {}
    return "t:%s:%s:%s" % (message.get("timestamp"), message.get("model"), usage.get("output"))


# Pi's session JSONL is a documented interface (the Session File Format and
# Message Types documents of @earendil-works/pi-coding-agent); this reads it.
def measure_pi(path: str, store: str, root: str, seen: set, state: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    errors = state["errors"]
    entries = read_jsonl(path, errors)
    header = next(entries, None)
    if header is None or header.get("type") != "session":
        return None
    tokens = new_tokens()
    tools = new_tools()
    models: Dict[str, int] = {}
    sections: Dict[str, str] = {}
    declared: Dict[str, int] = {}
    system_messages = 0
    custom_entries: Dict[str, Dict[str, Any]] = {}
    custom_messages: Dict[str, Dict[str, Any]] = {}
    nested = {"parts": 0, "bytes": 0}
    policy = {"results": 0, "truncated": 0, "minimized_only": 0, "minimized_lines": 0,
              "sanitized_details": 0, "before_bytes": 0, "after_bytes": 0}
    result_bytes = 0
    owed = 0
    call_names: Dict[str, str] = {}
    last_at = header.get("timestamp")
    for entry in entries:
        last_at = entry.get("timestamp", last_at)
        etype = entry.get("type")
        if etype == "message":
            message = entry.get("message") or {}
            role = message.get("role")
            if role == "system":
                system_messages += 1
                apply_system(message, sections, declared)
            elif role == "assistant":
                key = "a:" + assistant_key(message)
                if key in seen:
                    state["duplicates"] += 1
                    continue
                seen.add(key)
                label = "%s/%s" % (message.get("provider"), message.get("model"))
                models[label] = models.get(label, 0) + 1
                usage = message.get("usage") or {}
                add_tokens(tokens, usage.get("input"), usage.get("output"), usage.get("cacheRead"), usage.get("cacheWrite"))
                for block in message.get("content") or []:
                    if isinstance(block, dict) and block.get("type") == "toolCall":
                        name = str(block.get("name"))
                        call_names[str(block.get("id"))] = name
                        record_call(tools, name)
                if message.get("stopReason") == "error":
                    record_error(tools, "turn", None, str(message.get("errorMessage") or ""), "turn")
            elif role == "toolResult":
                result_key = "c:%s" % message.get("toolCallId")
                if result_key in seen:
                    continue
                seen.add(result_key)
                tools["results"] += 1
                text = text_of(message.get("content"))
                size = nbytes(text)
                result_bytes += size
                for block in message.get("content") or []:
                    if isinstance(block, dict) and isinstance(block.get("text"), str) and block["text"].startswith("instructions_path="):
                        nested["parts"] += 1
                        nested["bytes"] += nbytes(block["text"])
                details = message.get("details") if isinstance(message.get("details"), dict) else {}
                metas = details.get("kendexOutputPolicy")
                policy["results"] += 1
                if details.get("kendexOutputPolicySanitized"):
                    policy["sanitized_details"] += 1
                if isinstance(metas, list) and metas and isinstance(metas[0], dict):
                    meta = metas[0]
                    policy["truncated"] += 1
                    policy["before_bytes"] += int(meta.get("shownBytes") or 0) + int(meta.get("savedBytes") or 0)
                    policy["after_bytes"] += size
                else:
                    minimized = re.search(r"\[output-policy:minimized-lines=(\d+)\]", text)
                    if minimized:
                        policy["minimized_only"] += 1
                        policy["minimized_lines"] += int(minimized.group(1))
                    policy["before_bytes"] += size
                    policy["after_bytes"] += size
                if isinstance(message.get("usage"), dict):
                    u = message["usage"]
                    add_tokens(tokens, u.get("input"), u.get("output"), u.get("cacheRead"), u.get("cacheWrite"))
                if message.get("isError"):
                    tool = message.get("toolName") or call_names.get(str(message.get("toolCallId")))
                    record_error(tools, "tool", tool, text, "tool")
        elif etype in ("usage", "compaction", "branch_summary"):
            u = entry.get("usage")
            if isinstance(u, dict):
                add_tokens(tokens, u.get("input"), u.get("output"), u.get("cacheRead"), u.get("cacheWrite"))
            if etype == "compaction" and isinstance(entry.get("systemMessage"), dict):
                system_messages += 1
                apply_system(dict(entry["systemMessage"], replace=True), sections, declared)
        elif etype == "custom":
            ctype = str(entry.get("customType"))
            slot = custom_entries.setdefault(ctype, {"package": custom_type_owner(ctype), "count": 0, "bytes": 0})
            slot["count"] += 1
            slot["bytes"] += nbytes(entry.get("data"))
        elif etype == "custom_message":
            ctype = str(entry.get("customType"))
            slot = custom_messages.setdefault(ctype, {"package": custom_type_owner(ctype), "count": 0, "bytes": 0, "hidden": 0})
            slot["count"] += 1
            slot["bytes"] += nbytes(text_of(entry.get("content")))
            if entry.get("display") is False:
                slot["hidden"] += 1
                # pi-hooks delivers a refused Stop as a hidden kendex-hook
                # entry at settle (hooks.ts:362); its other entries display.
                if ctype == "kendex-hook":
                    owed += 1
    context = pi_context_from_system(sections, declared)
    context.update({
        "system_messages": system_messages,
        "custom_entries": custom_entries,
        "custom_messages": custom_messages,
        "nested_agents_md": nested,
        "output_policy": policy,
        "tool_result_bytes": result_bytes,
        "forced_prompt_appends": "not recorded",
    })
    return {
        "harness": "pi", "store": store, "path": os.path.relpath(path, root),
        "session_id": header.get("id"), "parent_session": header.get("parentSession"),
        "subagent": store == "pi-kendex", "cwd": header.get("cwd"),
        "started_at": header.get("timestamp"), "ended_at": last_at,
        "models": models, "tokens": tokens, "context": context, "tools": tools,
        "owed_turns": owed,
    }


# ------------------------------------------------------------ Claude sessions

# Fallback read of Claude Code's own transcript files, standing in for the
# Agent SDK's listSessions, getSessionMessages and getSubagentMessages
# (@anthropic-ai/claude-agent-sdk 0.3.288 sdk.d.ts). Those cannot serve here:
# they need the Node package installed in the lane sandbox, where this script
# runs as stdlib Python streamed on stdin and writes nothing; getSessionMessages
# returns only the parentUuid chain, dropping abandoned branches whose requests
# were billed, and system entries unless asked; and it types each message's
# body, usage included, as `unknown`, so the usage fields read below are no
# more a contract there than here.
def measure_claude(path: str, store: str, root: str, state: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    errors = state["errors"]
    usage_by_message: Dict[str, Tuple[Any, ...]] = {}
    models: Dict[str, int] = {}
    tools = new_tools()
    call_names: Dict[str, str] = {}
    seen_calls: set = set()
    seen_results: set = set()
    session_id = None
    cwd = None
    first_at = None
    last_at = None
    owed = 0
    any_entry = False
    for entry in read_jsonl(path, errors):
        any_entry = True
        session_id = session_id or entry.get("sessionId")
        cwd = cwd or entry.get("cwd")
        if entry.get("timestamp"):
            first_at = first_at or entry["timestamp"]
            last_at = entry["timestamp"]
        etype = entry.get("type")
        message = entry.get("message") if isinstance(entry.get("message"), dict) else {}
        if etype == "assistant":
            # Claude Code writes one line per content block of a response,
            # each repeating the response's usage: key usage by message id.
            mid = str(message.get("id") or entry.get("uuid"))
            usage = message.get("usage") or {}
            usage_by_message[mid] = (message.get("model"), usage.get("input_tokens"), usage.get("output_tokens"),
                                     usage.get("cache_read_input_tokens"), usage.get("cache_creation_input_tokens"))
            for block in message.get("content") or []:
                if isinstance(block, dict) and block.get("type") == "tool_use" and block.get("id") not in seen_calls:
                    seen_calls.add(block.get("id"))
                    call_names[str(block.get("id"))] = str(block.get("name"))
                    record_call(tools, str(block.get("name")))
            if entry.get("isApiErrorMessage"):
                record_error(tools, "turn", None, text_of(message.get("content")), "turn")
        elif etype == "user":
            content = message.get("content")
            if isinstance(content, str) and content.startswith("Stop hook feedback"):
                owed += 1
            for block in content if isinstance(content, list) else []:
                if not isinstance(block, dict):
                    continue
                if block.get("type") == "text" and str(block.get("text", "")).startswith("Stop hook feedback"):
                    owed += 1
                if block.get("type") != "tool_result" or block.get("tool_use_id") in seen_results:
                    continue
                seen_results.add(block.get("tool_use_id"))
                tools["results"] += 1
                if block.get("is_error"):
                    tool = call_names.get(str(block.get("tool_use_id")))
                    record_error(tools, "tool", tool, text_of(block.get("content")), "tool")
        elif etype == "system" and entry.get("subtype") == "api_error":
            record_error(tools, "turn", None, json.dumps(entry.get("error") or entry.get("content") or ""), "turn")
    if not any_entry:
        return None
    tokens = new_tokens()
    for model, *counts in usage_by_message.values():
        models[str(model)] = models.get(str(model), 0) + 1
        add_tokens(tokens, *counts)
    return {
        "harness": "claude", "store": store, "path": os.path.relpath(path, root),
        "session_id": session_id, "parent_session": None,
        "subagent": "/subagents/" in path, "cwd": cwd,
        "started_at": first_at, "ended_at": last_at,
        "models": models, "tokens": tokens, "context": "not applicable", "tools": tools,
        "owed_turns": owed,
    }


# ----------------------------------------------------------- Copilot sessions

# Fallback read of Copilot CLI's events.jsonl, standing in for the Copilot
# SDK's CopilotClient.resumeSession(...).getEvents() (@github/copilot-sdk
# 1.0.16), whose event types (generated/session-events.d.ts) this parser
# follows. That interface cannot serve: it starts a Copilot CLI process and
# resumes the session, which a read must not do to a live lane, and it needs
# the Node package in the sandbox.
def measure_copilot(path: str, store: str, root: str, state: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    errors = state["errors"]
    tools = new_tools()
    models: Dict[str, int] = {}
    shutdowns: List[Dict[str, Any]] = []
    session_id = None
    cwd = None
    first_at = None
    last_at = None
    call_names: Dict[str, str] = {}
    any_entry = False
    for event in read_jsonl(path, errors):
        any_entry = True
        data = event.get("data") if isinstance(event.get("data"), dict) else {}
        if event.get("timestamp"):
            first_at = first_at or event["timestamp"]
            last_at = event["timestamp"]
        etype = event.get("type")
        if etype == "session.start":
            session_id = data.get("sessionId") or session_id
            context = data.get("context") if isinstance(data.get("context"), dict) else {}
            cwd = context.get("cwd") or cwd
        elif etype == "tool.execution_start":
            name = str(data.get("toolName"))
            call_names[str(data.get("toolCallId"))] = name
            record_call(tools, name)
        elif etype == "tool.execution_complete":
            tools["results"] += 1
            if data.get("success") is False:
                err = data.get("error") if isinstance(data.get("error"), dict) else {}
                record_error(tools, "tool", call_names.get(str(data.get("toolCallId"))), str(err.get("message") or ""), "tool")
        elif etype == "session.error":
            record_error(tools, "turn", None, "%s: %s" % (data.get("errorType"), data.get("message")), "turn")
        elif etype == "session.shutdown":
            shutdowns.append(data)
    if not any_entry:
        return None
    tokens: Any = "not recorded"
    # assistant.usage is ephemeral and never reaches events.jsonl; each
    # session.shutdown carries the process's modelMetrics, summed here.
    for shutdown in shutdowns:
        if not isinstance(shutdown.get("modelMetrics"), dict):
            continue
        if tokens == "not recorded":
            tokens = new_tokens()
        for model, metric in shutdown["modelMetrics"].items():
            usage = (metric or {}).get("usage") or {}
            requests = int(((metric or {}).get("requests") or {}).get("count") or 0)
            models[model] = models.get(model, 0) + requests
            add_tokens(tokens, usage.get("inputTokens"), usage.get("outputTokens"),
                       usage.get("cacheReadTokens"), usage.get("cacheWriteTokens"))
    return {
        "harness": "copilot", "store": store, "path": os.path.relpath(path, root),
        "session_id": session_id or os.path.basename(os.path.dirname(path)), "parent_session": None,
        "subagent": False, "cwd": cwd, "started_at": first_at, "ended_at": last_at,
        "models": models, "tokens": tokens, "context": "not applicable", "tools": tools,
        "owed_turns": "not recorded",
    }


# ----------------------------------------------------------------------- live

def first_line_is_pi_session(path: str) -> bool:
    with open(path, "r", encoding="utf-8", errors="replace") as handle:
        line = handle.readline()
    try:
        value = json.loads(line)
    except ValueError:
        return False
    return isinstance(value, dict) and value.get("type") == "session"


def walk(root: str, pattern: str) -> List[str]:
    return sorted(glob.glob(os.path.join(root, pattern), recursive=True))


def run_live(home: str, item: Optional[str]) -> Dict[str, Any]:
    state: Dict[str, Any] = {"errors": [], "duplicates": 0}
    sessions: List[Dict[str, Any]] = []
    stores: Dict[str, Dict[str, Any]] = {}
    seen_pi: set = set()
    seen_real: set = set()

    def store_row(name: str, root: str) -> Dict[str, Any]:
        row = {"root": root, "present": os.path.isdir(root), "files": 0, "unreadable": 0, "skipped_non_session": 0}
        stores[name] = row
        return row

    def read_one(name: str, root: str, path: str, reader) -> None:
        row = stores[name]
        real = os.path.realpath(path)
        if real in seen_real:
            return
        seen_real.add(real)
        row["files"] += 1
        try:
            result = reader(path)
        except OSError as error:
            row["unreadable"] += 1
            state["errors"].append({"path": path, "error": str(error)})
            return
        if result is None:
            row["skipped_non_session"] += 1
        else:
            sessions.append(result)

    pi_root = os.path.join(home, ".pi", "agent")
    for name, root in (("pi", os.path.join(pi_root, "sessions")), ("pi-kendex", os.path.join(pi_root, "kendex", "sessions"))):
        store_row(name, root)
        for path in walk(root, "**/*.jsonl"):
            read_one(name, root, path, lambda p, n=name, r=root: measure_pi(p, n, r, seen_pi, state)
                     if first_line_is_pi_session(p) else None)
    for name, root in (("claude", os.path.join(home, ".claude-shared", "projects")),
                       ("claude-local", os.path.join(home, ".claude", "projects"))):
        store_row(name, root)
        for path in walk(root, "**/*.jsonl"):
            read_one(name, root, path, lambda p, n=name, r=root: measure_claude(p, n, r, state))
    for account in sorted(glob.glob(os.path.join(home, ".copilot*"))):
        root = os.path.join(account, "session-state")
        name = "copilot:" + os.path.basename(account)
        store_row(name, root)
        for path in walk(root, "*/events.jsonl"):
            read_one(name, root, path, lambda p, n=name, r=root: measure_copilot(p, n, r, state))

    append_path = os.path.join(pi_root, "APPEND_SYSTEM.md")
    append_system = None
    if os.path.isfile(append_path):
        with open(append_path, "r", encoding="utf-8", errors="replace") as handle:
            append_system = split_addendum(handle.read())
    artifacts = {"files": 0, "bytes": 0}
    for path in walk(os.path.join(pi_root, "kendex", "sessions"), "*/pi-output-policy/artifacts/**/*"):
        if os.path.isfile(path):
            artifacts["files"] += 1
            artifacts["bytes"] += os.path.getsize(path)
    return {
        "schema": LIVE_SCHEMA, "mode": "live", "item": item, "read_at": now_iso(), "home": home,
        "stores": stores, "append_system": append_system, "output_policy_artifacts": artifacts,
        "duplicate_assistant_messages": state["duplicates"], "sessions": sessions, "errors": state["errors"],
    }


# -------------------------------------------------------------------- archive

class DiskLow(Exception):
    pass


def check_disk(min_free_bytes: int, disk: Dict[str, Any]) -> None:
    shown = subprocess.run(["df", "-h", "/"], stdout=subprocess.PIPE, stderr=subprocess.STDOUT, universal_newlines=True)
    sys.stderr.write(shown.stdout)
    free = shutil.disk_usage("/").free
    disk["free_bytes"] = free
    if free < min_free_bytes:
        raise DiskLow(free)


def tar_list(archive: str) -> List[str]:
    done = subprocess.run(["tar", "-tzf", archive], stdout=subprocess.PIPE, stderr=subprocess.PIPE, universal_newlines=True)
    if done.returncode != 0:
        raise OSError("tar -tzf exit %d: %s" % (done.returncode, done.stderr.strip()[:200]))
    return [line for line in done.stdout.splitlines() if line and not line.endswith("/")]


def tar_member(archive: str, member: str) -> bytes:
    """Stream one member through `tar -xzOf`, refusing one past MEMBER_CAP_BYTES."""
    child = subprocess.Popen(["tar", "-xzOf", archive, "--", member], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    data = child.stdout.read(MEMBER_CAP_BYTES + 1)  # type: ignore[union-attr]
    if len(data) > MEMBER_CAP_BYTES:
        child.kill()
        child.wait()
        raise OSError("member over %d bytes" % MEMBER_CAP_BYTES)
    _, err = child.communicate()
    if child.returncode != 0:
        raise OSError("tar -xzOf exit %d: %s" % (child.returncode, err.decode("utf-8", "replace").strip()[:200]))
    return data


def own_mailbox(member: str, item: str) -> bool:
    """A close archive also holds other mailboxes: the overseer's and test
    scratch ones. A lane's own is `lane-mail/<item>/`, the item compared
    case-insensitively."""
    parts = [p.lower() for p in member.split("/")]
    return any(parts[i] == "lane-mail" and parts[i + 1] == item.lower() for i in range(len(parts) - 1))


def member_kind(member: str, item: str) -> Optional[str]:
    base = os.path.basename(member)
    if base == "to-overseer.jsonl":
        return "to-overseer" if own_mailbox(member, item) else None
    if base.lower().startswith("lane-status-%s" % item.lower()) or (base.startswith("lane-status") and own_mailbox(member, item)):
        return "lane-status"
    if base == "workflow-state-%s.json" % item:
        return "item-state"
    return None


def read_token_record(path: str, errors: List[Dict[str, Any]]) -> Optional[Dict[str, Any]]:
    try:
        with open(path, "r", encoding="utf-8") as handle:
            record = json.load(handle)
    except (OSError, ValueError) as error:
        errors.append({"path": path, "error": str(error)})
        return None
    harnesses: Dict[str, Any] = {}
    for harness, body in (record.get("harnesses") or {}).items():
        models: Dict[str, Any] = {}
        for model, counts in (body.get("models") or {}).items():
            # A null count is the writer's "not recorded" (a Codex cache
            # write): the row keeps its known counts and names the unknown one.
            if not (isinstance(counts, list) and len(counts) == len(TOKEN_RECORD_FIELDS)
                    and all(c is None or (isinstance(c, int) and not isinstance(c, bool)) for c in counts)):
                errors.append({"path": path, "error": "token-record-shape harness=%s model=%s" % (harness, model)})
                continue
            row: Dict[str, Any] = dict(zip(TOKEN_RECORD_FIELDS, counts))
            row["total"] = sum(c for c in counts if c is not None)
            unknown = [f for f, c in zip(TOKEN_RECORD_FIELDS, counts) if c is None]
            if unknown:
                row["unknown"] = unknown
            models[model] = row
        harnesses[harness] = {"files": body.get("files"), "unreadable": body.get("unreadable"),
                              "unrecorded": body.get("unrecorded"), "models": models}
    return {"file": os.path.basename(path), "at": record.get("at"), "harnesses": harnesses}


def lane_mail_summary(raw: bytes, mail: Dict[str, Any], seen: set) -> None:
    """Fold one to-overseer.jsonl into `mail`. A close archive can hold the
    mailbox twice (the worktree's and the close-out evidence copy), so an
    envelope id already in `seen` is skipped."""
    for line in raw.decode("utf-8", "replace").splitlines():
        try:
            envelope = json.loads(line)
        except ValueError:
            continue
        if not isinstance(envelope, dict):
            continue
        key = envelope.get("id") or line
        if key in seen:
            continue
        seen.add(key)
        mail["envelopes"] += 1
        kind = str(envelope.get("kind"))
        mail["by_kind"][kind] = mail["by_kind"].get(kind, 0) + 1
        if kind == "ask":
            text = str(envelope.get("text") or "")
            terms = sorted({m.group(0).lower() for m in HARNESS_DEFECT_TERMS.finditer(text)})
            mail["asks"].append({"id": envelope.get("id"), "at": envelope.get("at"), "terms": terms,
                                 "excerpt": text[:EXCERPT_CHARS]})


def item_state_summary(raw: bytes) -> Dict[str, Any]:
    state = json.loads(raw.decode("utf-8"))
    review = state.get("pr_comment_review") or {}
    return {"cycles": state.get("cycles"), "rereview_cycles": state.get("rereview_cycles"),
            "pr_comment_iterations": review.get("iterations"), "fixes": len(review.get("fixes") or []),
            "skipped": len(review.get("skipped") or []), "escalated_items": len(state.get("escalated_items") or [])}


def load_oversee(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as handle:
        state = json.load(handle)
    if isinstance(state.get("oversee"), dict):
        state = state["oversee"]
    return state


def parse_at(value: Any) -> Optional[_dt.datetime]:
    """An ISO 8601 UTC stamp as an aware datetime; None for anything else."""
    if not isinstance(value, str):
        return None
    try:
        return _dt.datetime.strptime(value.replace("Z", "+00:00")[:19] + "+00:00", "%Y-%m-%dT%H:%M:%S%z")
    except ValueError:
        return None


def estimate_band(estimate: Any) -> str:
    """A tracker estimate's band. 0 and no estimate are "none": unmatched."""
    if isinstance(estimate, bool) or not isinstance(estimate, (int, float)) or estimate <= 0:
        return "none"
    return "1-2" if estimate <= 2 else "3+"


def oversee_summary(state: Dict[str, Any], item: str) -> Dict[str, Any]:
    keep = ("item", "repo", "harness", "model", "effort", "status", "launched_at", "running_at",
            "session_id", "pauses", "parked", "tier", "tier_inputs", "cycle")
    lanes = [{k: lane.get(k) for k in keep} for lane in state.get("lanes") or [] if lane.get("item") == item]
    rows = [row for row in state.get("fleet_log") or [] if row.get("item") == item]
    by_kind: Dict[str, int] = {}
    for row in rows:
        by_kind[str(row.get("kind"))] = by_kind.get(str(row.get("kind")), 0) + 1
    relaunch = sum(1 for row in rows if re.search(r"\brelaunch", str(row.get("text")), re.I))
    return {"lanes": lanes, "fleet_log": {"rows": len(rows), "by_kind": by_kind, "relaunch_rows": relaunch}}


def paused_within(lane: Dict[str, Any], start: _dt.datetime, end: _dt.datetime) -> int:
    """Seconds of START..END the lane stood paused: each `pauses` stretch and a
    standing `parked` (running on to END), clipped to the window, overlaps
    counted once. This is oversee-cycle's `paused` rule (its pauses and
    paused() at oversee-cycle:363-381); that script judges the gate gap of
    one lane through its own state reads, so it cannot be called for the
    launch-to-merge window of an archive line."""
    spans = []
    for pause in lane.get("pauses") or []:
        a, b = parse_at((pause or {}).get("from")), parse_at((pause or {}).get("to"))
        if a is not None:
            spans.append((a, b or end))
    parked = lane.get("parked")
    if isinstance(parked, dict) and parse_at(parked.get("at")) is not None:
        spans.append((parse_at(parked["at"]), end))
    clipped = sorted((max(a, start), min(b, end)) for a, b in spans if min(b, end) > max(a, start))
    total = 0
    cursor = start
    for a, b in clipped:
        a = max(a, cursor)
        if b > a:
            total += int((b - a).total_seconds())
            cursor = b
    return total


def lane_outcome(lane: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    """Measure 5 inputs from one oversee lane record. oversee-cycle writes a
    lane's `cycle` only at merge, so kept records never show a non-merge:
    `merged` is True where the cycle holds a merged stamp, and None (unknown)
    for every other lane, one with no lane record or no cycle included."""
    if lane is None:
        return {"merged": None, "wall_secs": None, "paused_secs": None, "fix_rounds": None,
                "stopped_parked_or_paused": None, "tier": None}
    cycle = lane.get("cycle") if isinstance(lane.get("cycle"), dict) else None
    stamps = (cycle or {}).get("stamps") or {}
    launched = parse_at(stamps.get("launched") or lane.get("launched_at"))
    merged_at = parse_at(stamps.get("merged"))
    paused = paused_within(lane, launched, merged_at) if launched and merged_at else None
    wall = int((merged_at - launched).total_seconds()) - paused if paused is not None else None
    rounds = (cycle or {}).get("rounds") or {}
    return {
        "merged": True if merged_at is not None else None,
        "wall_secs": wall,
        "paused_secs": paused,
        "fix_rounds": rounds.get("fix") if isinstance(rounds.get("fix"), int) else None,
        # Parking is the `parked` object; no lane status reads "parked".
        "stopped_parked_or_paused": lane.get("status") == "stopped" or bool(lane.get("parked")) or bool(lane.get("pauses")),
        # tier_inputs.estimate is item-tier's estimate of added production
        # lines, not the tracker estimate; the band comes from --issues.
        "tier": lane.get("tier") or (cycle or {}).get("tier"),
    }


def brief_tail_summary(path: str) -> Dict[str, Any]:
    with open(path, "r", encoding="utf-8") as handle:
        text = handle.read()
    clauses = [c for c in re.split(r"\n\s*\n|\n(?=\s*[-*] )", text) if c.strip()]
    only: Dict[str, int] = {}
    for clause in clauses:
        named = [h for h, rx in HARNESS_WORDS.items() if rx.search(clause)]
        if len(named) == 1:
            only[named[0]] = only.get(named[0], 0) + 1
    return {"clauses": len(clauses), "harness_only": only}


def kept_since(path: str, since: Optional[_dt.datetime], at: Any = None) -> bool:
    """A close record counts from `since` on: its `at`, else the file's mtime."""
    if since is None:
        return True
    stamp = parse_at(at)
    if stamp is None:
        stamp = _dt.datetime.fromtimestamp(os.path.getmtime(path), _dt.timezone.utc)
    return stamp >= since


def archive_item(directory: str, repo: str, item: str, since: Optional[_dt.datetime],
                 oversee: Optional[Dict[str, Any]], brief: Optional[Dict[str, Any]],
                 disk: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    """Every kept close record of one `<repo>/<item>` directory; None when none counts."""
    errors: List[Dict[str, Any]] = []
    records = []
    for path in walk(directory, "tokens-*.json"):
        record = read_token_record(path, errors)
        if record is not None and kept_since(path, since, record["at"]):
            records.append(record)
    tgzs = [p for p in walk(directory, "tmp-*.tgz") if kept_since(p, since)]
    if not records and not tgzs:
        return None
    totals: Dict[str, Dict[str, int]] = {}
    for record in records:
        for harness, body in record["harnesses"].items():
            slot = totals.setdefault(harness, {k: 0 for k in TOKEN_RECORD_FIELDS + ("total", "unknown")})
            for row in body["models"].values():
                slot["unknown"] += len(row.get("unknown", ()))
                for key in TOKEN_RECORD_FIELDS + ("total",):
                    slot[key] += row[key] or 0
    archives = []
    lane_status = []
    mail = {"envelopes": 0, "by_kind": {}, "asks": []}  # type: Dict[str, Any]
    item_state: Optional[Dict[str, Any]] = None
    seen_mail: set = set()
    for archive in tgzs:
        row = {"file": os.path.basename(archive), "members": 0, "read": [], "skipped": 0}
        archives.append(row)
        try:
            members = tar_list(archive)
        except OSError as error:
            errors.append({"path": archive, "error": str(error)})
            continue
        row["members"] = len(members)
        for member in members:
            kind = member_kind(member, item)
            if kind is None:
                row["skipped"] += 1
                continue
            try:
                raw = tar_member(archive, member)
                row["read"].append({"member": member, "kind": kind, "bytes": len(raw)})
                if kind == "lane-status":
                    try:
                        value = json.loads(raw.decode("utf-8"))
                        keys = sorted(value) if isinstance(value, dict) else type(value).__name__
                    except ValueError:
                        keys = "not json"
                    lane_status.append({"member": member, "keys": keys})
                elif kind == "to-overseer":
                    lane_mail_summary(raw, mail, seen_mail)
                else:
                    item_state = item_state_summary(raw)
            except (OSError, ValueError) as error:
                errors.append({"path": "%s:%s" % (archive, member), "error": str(error)})
    lanes = oversee_summary(oversee, item) if oversee is not None else None
    lane = lanes["lanes"][-1] if lanes and lanes["lanes"] else None
    token_harnesses = sorted(h for h, t in totals.items() if t["total"] > 0) or sorted(totals)
    harness = (lane or {}).get("harness") or (token_harnesses[0] if len(token_harnesses) == 1 else
                                              ("mixed" if token_harnesses else None))
    return {
        "schema": ARCHIVE_SCHEMA, "mode": "archive", "read_at": now_iso(), "dir": directory,
        "repo": repo, "item": item, "harness": harness, "token_harnesses": token_harnesses,
        "outcome": lane_outcome(lane),
        "token_field_order_assumed": list(TOKEN_RECORD_FIELDS),
        "token_records": records, "token_totals": totals, "tmp_archives": archives,
        "lane_status": lane_status, "lane_mail": mail, "item_state": item_state,
        "oversee": lanes, "brief_tail": brief, "disk": disk, "errors": errors,
    }


def repo_map(values: List[str], flag: str) -> Dict[str, str]:
    out: Dict[str, str] = {}
    for value in values:
        repo, sep, path = value.partition("=")
        if not sep or not repo or not path:
            raise ValueError("%s takes REPO=PATH, got %r" % (flag, value))
        out[repo] = path
    return out


def run_archive(root: str, single: bool, since: Optional[_dt.datetime], oversee_paths: Dict[str, str],
                brief_paths: Dict[str, str], min_free_gb: float, emit) -> Dict[str, int]:
    """Emit one object per `<repo>/<item>` (or for `root` itself when `single`)."""
    root = os.path.abspath(root)
    if single:
        items = [(os.path.basename(os.path.dirname(root)), os.path.basename(root), root)]
    else:
        items = [(repo, item, os.path.join(root, repo, item))
                 for repo in sorted(os.listdir(root)) if os.path.isdir(os.path.join(root, repo))
                 for item in sorted(os.listdir(os.path.join(root, repo))) if os.path.isdir(os.path.join(root, repo, item))]
    oversee_cache: Dict[str, Dict[str, Any]] = {}
    brief_cache: Dict[str, Dict[str, Any]] = {}
    counts = {"items": 0, "emitted": 0, "no_records": 0}
    for repo, item, directory in items:
        counts["items"] += 1
        disk = {"before": "%s/%s" % (repo, item)}  # type: Dict[str, Any]
        check_disk(int(min_free_gb * 1024 ** 3), disk)
        if repo in oversee_paths and repo not in oversee_cache:
            oversee_cache[repo] = load_oversee(oversee_paths[repo])
        if repo in brief_paths and repo not in brief_cache:
            brief_cache[repo] = brief_tail_summary(brief_paths[repo])
        result = archive_item(directory, repo, item, since, oversee_cache.get(repo), brief_cache.get(repo), disk)
        if result is None:
            counts["no_records"] += 1
            continue
        counts["emitted"] += 1
        emit(result)
    return counts


# ------------------------------------------------------------------ aggregate

# Harnesses the audit compares. Any other harness in the records gets n and an
# item count only, marked outside the comparison.
COMPARED = ("pi", "claude", "copilot")
NOT_SAMPLED = "not sampled (n=0)"
# A tracker id's shape: a Linear-style `ABC-123` or a GitHub `issue-123`.
WORK_ITEM_SHAPE = re.compile(r"^(?:issue-[0-9]+|[A-Za-z][A-Za-z0-9]*-[0-9]+)$", re.I)


# Lane-mail asks grouped by what they report, first matching group wins.
# Each example is a real ask's opening from the 2026-10 archive run.
ASK_GROUPS = (
    {"group": "failing receipt or validation", "pattern": r"receipt|FAILING|validation|\bfails?\b|failed",
     "example": "KEN-2089's dev round committed c889f403 but returned FAILING."},
    {"group": "merge or review gate", "pattern": r"merge|review|approv|armed|queue|thread",
     "example": "FLT-614 micro, PR #628 (head a045334): CI green, tier=micro, gate=approval, no open threads."},
    {"group": "ruling or choice", "pattern": r"ruling|choose|option|decide|A\.|\bcut\b",
     "example": "The configured Pi-to-Codex fallback has no authorized Codex permission choice.  A. Stop a fallback"},
)
_ASK_GROUPS = [dict(g, regex=re.compile(g["pattern"], re.I)) for g in ASK_GROUPS]


def ask_group(text: str) -> str:
    for group in _ASK_GROUPS:
        if group["regex"].search(text):
            return group["group"]
    return "other"


def work_item_id(key: str, issues: Dict[str, Any], repo: str) -> Optional[str]:
    """The canonical id of an archive item key, or None for a probe.

    This audit owns the rule, and it reads no environment: the archive spans
    repositories whose trackers differ, so one checkout's GH_ISSUE_PATTERN
    would drop the others' items. A key needs a tracker id's shape and, where
    tracker data was read (--issues), an entry there, which keeps out a probe
    key of that shape such as `proof-3342777`. A GitHub `issue-N` names an
    item only within its repository, so its id is `<repo>/issue-N`; a Linear
    id is unique across the workspace and stays bare."""
    if not WORK_ITEM_SHAPE.match(key):
        return None
    canonical = "%s/%s" % (repo, key.lower()) if key.lower().startswith("issue-") else key.upper()
    if issues and canonical not in issues:
        return None
    return canonical


def model_family(model: Any) -> Optional[str]:
    """A model name without its provider, in one spelling: `github-copilot/
    claude-opus-5.5` and `claude-opus-5-5` are both `claude-opus-5.5`."""
    if not isinstance(model, str) or not model:
        return None
    name = model.split("/")[-1]
    return re.sub(r"-(\d+)-(\d+)$", r"-\1.\2", name)


def normalize(o: Dict[str, Any], issues: Dict[str, Any]) -> Dict[str, Any]:
    """One archive line (schema 1 or 2) as the fields every measure reads.

    The lead harness is the oversee lane record's harness, else the one
    harness with tokens in the kept token records. An item whose token
    records hold another harness beside the lead is `mixed_tokens`: its
    measure 1 is left out, since those tokens may be a side run or a
    relaunch on another harness. Measures 4 and 5 charge the item to its
    lead.
    """
    lanes = (o.get("oversee") or {}).get("lanes") or []
    lane = lanes[-1] if lanes else None
    totals = o.get("token_totals") or {}
    # A harness is incomplete for the item where a record says files or
    # sessions went unread, a count is null, or a model row was refused.
    incomplete = {h for r in o.get("token_records") or [] for h, b in r["harnesses"].items()
                  if (b.get("unreadable") or 0) > 0 or (b.get("unrecorded") or 0) > 0
                  or any(row.get("unknown") for row in (b.get("models") or {}).values())}
    for error in o.get("errors") or []:
        refused = re.match(r"token-record-shape harness=(\S+) ", str(error.get("error")))
        if refused:
            incomplete.add(refused.group(1))
    # Tokens a record holds but cannot count still mark the harness present.
    with_tokens = sorted({h for h, t in totals.items() if t.get("total", 0) > 0} | incomplete)
    lead = (lane or {}).get("harness") or (with_tokens[0] if len(with_tokens) == 1 else None)
    token_models: Dict[str, int] = {}
    for record in o.get("token_records") or []:
        for model in ((record["harnesses"].get(lead) or {}).get("models") or {}):
            token_models[model] = token_models.get(model, 0) + 1
    # A schema-1 line counted every to-overseer.jsonl in the archive; one
    # that read another item's mailbox has asks that are not all its own.
    foreign = any(r.get("kind") == "to-overseer" and not own_mailbox(r["member"], o["item"])
                  for a in o.get("tmp_archives") or [] for r in a.get("read") or [])
    asks: Dict[str, Any] = {}
    for ask in (o.get("lane_mail") or {}).get("asks") or []:
        asks.setdefault(str(ask.get("id")), ask)
    canonical = work_item_id(o["item"], issues, o["repo"])
    issue = issues.get(canonical or o["item"]) or {}
    fleet_log = (o.get("oversee") or {}).get("fleet_log")
    return {
        "repo": o["repo"], "item": canonical or o["item"], "work_item": canonical is not None,
        "lead": lead, "with_tokens": with_tokens,
        "mixed_tokens": bool(with_tokens) and with_tokens != [lead],
        "incomplete": sorted(incomplete), "tokens": totals.get(lead),
        "totals": {h: (totals.get(h) or {}).get("total", 0) for h in with_tokens},
        "token_models": token_models, "lane_model": (lane or {}).get("model"),
        "token_family": model_family(next(iter(token_models))) if len(token_models) == 1 else None,
        "lane_family": model_family((lane or {}).get("model")),
        "outcome": lane_outcome(lane),
        "has_lane": lane is not None, "fleet_log": fleet_log,
        "asks": [] if foreign else list(asks.values()),
        "has_mail": bool(o.get("tmp_archives")) and not foreign, "foreign_mailbox": foreign,
        "agent": issue.get("agent"), "band": estimate_band(issue.get("estimate")) if issue else "none",
    }


def _sum_pkg(values: Dict[str, Any], skip: Tuple[str, ...] = ("other",)) -> int:
    return sum(v for k, v in values.items() if k not in skip)


def _bytes_by_owner(table: Dict[str, Any]) -> int:
    return sum(v["bytes"] for v in table.values() if v.get("package") not in ("pi", "unattributed"))


def _token(field: str):
    def value(n: Dict[str, Any]) -> Optional[float]:
        if not n["outcome"]["merged"] or n["mixed_tokens"] or not n["tokens"] or n["lead"] in n["incomplete"]:
            return None
        return n["tokens"].get(field)
    return value


def _context(fn):
    return lambda s: fn(s["context"]) if isinstance(s.get("context"), dict) else None


def _log(fn):
    return lambda n: fn(n["fleet_log"]) if n["has_lane"] and n["fleet_log"] is not None else None


def _outcome(field: str, merged_only: bool = False):
    def value(n: Dict[str, Any]) -> Optional[float]:
        out = n["outcome"]
        if out.get(field) is None or (merged_only and not out.get("merged")):
            return None
        return int(out[field]) if isinstance(out[field], bool) else out[field]
    return value


# (measure, unit, source, value of one normalized item or live session).
MEASURES = (
    ("1 input tokens per merged item", "item", "tokens-*.json models.<model>[0], lead harness only", _token("input")),
    ("1 output tokens per merged item", "item", "tokens-*.json models.<model>[1], lead harness only", _token("output")),
    ("1 cache read tokens per merged item", "item", "tokens-*.json models.<model>[2], lead harness only", _token("cache_read")),
    ("1 cache write tokens per merged item", "item", "tokens-*.json models.<model>[3], lead harness only", _token("cache_write")),
    ("1 total tokens per merged item", "item", "tokens-*.json sum of the four counts, lead harness only", _token("total")),
    ("2 system-prompt append bytes", "session", "live: Pi addendum section, package markers",
     _context(lambda c: _sum_pkg(c["addendum_by_package"]))),
    ("2 our tool definition bytes", "session", "live: Pi system message toolsAdded",
     _context(lambda c: sum(v["bytes"] for v in c["tool_definitions"]["ours"].values()))),
    ("2 custom and custom_message bytes", "session", "live: Pi custom and custom_message entries",
     _context(lambda c: _bytes_by_owner(c["custom_entries"]) + _bytes_by_owner(c["custom_messages"]))),
    ("2 tool-result bytes before budget", "session", "live: Pi toolResult details.kendexOutputPolicy",
     _context(lambda c: c["output_policy"]["before_bytes"])),
    ("2 tool-result bytes after budget", "session", "live: Pi toolResult content", _context(lambda c: c["output_policy"]["after_bytes"])),
    ("3 tool calls per session", "session", "live: transcript tool calls", lambda s: s["tools"]["calls"]),
) + tuple(
    ("3 %s errors per session" % cls, "session", "live: transcript errors, ERROR_RULES", (lambda c: lambda s: s["tools"]["errors_by_class"][c])(cls))
    for cls in ERROR_CLASSES
) + (
    ("4 relaunches per item", "item", "oversee fleet_log rows naming relaunch", _log(lambda f: f["relaunch_rows"])),
    ("4 overseer rulings per item", "item", "oversee fleet_log rows of kind ruling", _log(lambda f: f["by_kind"].get("ruling", 0))),
    ("4 lane-mail asks per item", "item", "to-overseer.jsonl asks, one per envelope id",
     lambda n: len(n["asks"]) if n["has_mail"] else None),
    ("4 candidate harness-defect asks per item", "item", "to-overseer.jsonl asks naming harness words; a reviewer confirms each",
     lambda n: sum(1 for a in n["asks"] if a["terms"]) if n["has_mail"] else None),
    ("4 turns ended with work owed per session", "session", "live: Stop hook refusals in the transcript",
     lambda s: s["owed_turns"] if isinstance(s["owed_turns"], int) else None),
    ("5 share stopped, parked or paused", "item", "oversee lane record status, pauses", _outcome("stopped_parked_or_paused")),
    ("5 share not merged", "item", "oversee lane record cycle.stamps.merged; 0 by construction, kept records never show a non-merge",
     lambda n: None if n["outcome"]["merged"] is None else int(not n["outcome"]["merged"])),
    ("5 wall seconds launch to merge, less pauses", "item", "oversee lane record cycle.stamps, pauses", _outcome("wall_secs", True)),
    ("5 fix rounds per merged item", "item", "oversee lane record cycle.rounds.fix", _outcome("fix_rounds", True)),
)


def nearest_rank(values: List[float], share: float) -> float:
    ordered = sorted(values)
    return ordered[max(1, math.ceil(share * len(ordered))) - 1]


def cell(points: List[Tuple[str, float]]) -> Dict[str, Any]:
    values = [v for _, v in points]
    items = len({i for i, _ in points})
    ordered = sorted(values)
    middle = len(ordered) // 2
    median = ordered[middle] if len(ordered) % 2 else (ordered[middle - 1] + ordered[middle]) / 2
    return {"n": len(values), "items": items, "median": median, "p90": nearest_rank(values, 0.9)}


# Measures whose value is 0 or 1 per item: a cell reports the share, not a
# median and p90.
SHARE_MEASURES = frozenset(("5 share stopped, parked or paused", "5 share not merged"))


def share_cell(points: List[Tuple[str, float]]) -> Dict[str, Any]:
    values = [v for _, v in points]
    return {"n": len(values), "items": len({i for i, _ in points}), "share": round(sum(values) / len(values), 4)}


def measure_row(source: str, unit: str, points: Dict[str, List[Tuple[str, float]]], share: bool = False) -> Dict[str, Any]:
    """One measure's cells under the reporting rule."""
    if not points:
        return {"source": source, "unit": unit, "pi_items": 0, "verdict": NOT_SAMPLED, "cells": {}}
    cells = {h: (share_cell(p) if share else cell(p)) for h, p in sorted(points.items())}
    pi_items = cells.get("pi", {}).get("items", 0)
    judged = pi_items >= MIN_PI_ITEMS
    out = {}
    for harness, c in cells.items():
        if harness not in COMPARED:
            out[harness] = {"n": c["n"], "items": c["items"], "verdict": "outside the comparison"}
        elif not judged:
            out[harness] = {"n": c["n"], "items": c["items"], "verdict": TOO_SMALL}
        else:
            out[harness] = c
    return {"source": source, "unit": unit, "pi_items": pi_items, "verdict": "judged" if judged else TOO_SMALL, "cells": out}


def aggregate(objects: List[Dict[str, Any]], issues: Dict[str, Any]) -> Dict[str, Any]:
    """The measure-by-harness table, its matched strata and unmatched totals."""
    normalized = [normalize(o, issues) for o in objects if o.get("mode") == "archive"]
    probes = [n for n in normalized if not n["work_item"]]
    items = [n for n in normalized if n["work_item"] and n["lead"] is not None]
    sessions = [(work_item_id(live["item"], {}, str(live.get("repo"))) if live.get("item") else None, s)
                for live in objects if live.get("mode") == "live" for s in live["sessions"]]

    def item_points(fn, pool):
        points: Dict[str, List[Tuple[str, float]]] = {}
        for n in pool:
            v = fn(n)
            if v is not None:
                points.setdefault(n["lead"], []).append((n["item"], v))
        return points

    def session_points(fn):
        points: Dict[str, List[Tuple[str, float]]] = {}
        for item, s in sessions:
            v = fn(s)
            if v is not None:
                points.setdefault(s["harness"], []).append((item or s["path"], v))
        return points

    strata: Dict[Tuple[str, str, str], List[Dict[str, Any]]] = {}
    for n in items:
        if n["agent"] not in (None, "several") and n["band"] != "none":
            strata.setdefault((n["repo"], n["agent"], n["band"]), []).append(n)
    table: Dict[str, Any] = {}
    matched: Dict[str, Any] = {}
    unmatched: Dict[str, Any] = {}
    by_model: Dict[str, Any] = {}
    for name, unit, source, fn in MEASURES:
        if unit == "session":
            table[name] = measure_row(source, unit, session_points(fn))
            continue
        share = name in SHARE_MEASURES
        table[name] = measure_row(source, unit, item_points(fn, items), share)
        families: Dict[str, List[Dict[str, Any]]] = {}
        for n in items:
            family = n["token_family"] if name.startswith("1 ") else n["lane_family"]
            if family is not None:
                families.setdefault(family, []).append(n)
        by_model[name] = {f: measure_row(source, unit, item_points(fn, pool), share) for f, pool in sorted(families.items())}
        in_matched: set = set()
        cells = {}
        for key, pool in sorted(strata.items()):
            points = item_points(fn, pool)
            if "pi" in points and ("claude" in points or "copilot" in points):
                cells["|".join(key)] = measure_row(source, unit, points, share)
                in_matched.update(n["item"] for n in pool)
        matched[name] = cells
        unmatched[name] = measure_row(source, unit, item_points(fn, [n for n in items if n["item"] not in in_matched]), share)
    model_mix: Dict[str, Dict[str, Dict[str, int]]] = {}
    for n in items:
        mix = model_mix.setdefault(n["lead"], {"lane_record": {}, "token_record": {}})
        if n["lane_model"]:
            mix["lane_record"][n["lane_model"]] = mix["lane_record"].get(n["lane_model"], 0) + 1
        for model, count in n["token_models"].items():
            mix["token_record"][model] = mix["token_record"].get(model, 0) + count
    incomplete: Dict[str, int] = {}
    for n in items:
        for harness in n["incomplete"]:
            incomplete[harness] = incomplete.get(harness, 0) + 1
    ask_groups: Dict[str, Dict[str, int]] = {}
    for n in items:
        if not n["has_mail"]:
            continue
        slot = ask_groups.setdefault(n["lead"], {"items": 0, "asks": 0})
        slot["items"] += 1
        for ask in n["asks"]:
            slot["asks"] += 1
            group = ask_group(str(ask.get("excerpt") or ask.get("text") or ""))
            slot[group] = slot.get(group, 0) + 1
    with_tokens: Dict[str, int] = {}
    for n in normalized:
        for harness in n["with_tokens"]:
            with_tokens[harness] = with_tokens.get(harness, 0) + 1
    # A harness's tokens in an item whose lane record names another lead: a
    # side run (a second opinion) or a lane moved to another harness. The
    # token size tells them apart for a reader; this records both.
    under_other: Dict[str, List[int]] = {}
    for n in items:
        for harness, total in n["totals"].items():
            if harness != n["lead"]:
                under_other.setdefault("%s under %s" % (harness, n["lead"]), []).append(total)
    under_other_cells = {k: {"items": len(v), "median_total": cell([("", x) for x in v])["median"], "max_total": max(v)}
                         for k, v in sorted(under_other.items())}
    return {
        "schema": AGGREGATE_SCHEMA, "mode": "aggregate",
        "rule": "every cell carries n, item count and source; a measure with fewer than %d Pi items reads %r" % (MIN_PI_ITEMS, TOO_SMALL),
        "inputs": {
            "archive_lines": len(normalized), "probe_items_excluded": len(probes),
            "no_harness_excluded": sum(1 for n in normalized if n["work_item"] and n["lead"] is None),
            "items": len(items), "items_by_lead": _count(n["lead"] for n in items),
            "items_with_lane_record": _count(n["lead"] for n in items if n["has_lane"]),
            "items_with_tokens_by_harness": with_tokens,
            "mixed_token_items_by_lead": _count(n["lead"] for n in items if n["mixed_tokens"]),
            "foreign_mailbox_items_by_lead": _count(n["lead"] for n in items if n["foreign_mailbox"]),
            "tokens_under_another_lead": under_other_cells,
            "incomplete_token_items_by_harness": incomplete,
            "items_with_issue_fields": sum(1 for n in items if n["agent"] is not None or n["band"] != "none"),
            "matched_strata": sum(1 for pool in strata.values()
                                  if {"pi"} & {n["lead"] for n in pool} and {"claude", "copilot"} & {n["lead"] for n in pool}),
            "live_sessions": len(sessions),
        },
        "model_mix": model_mix,
        "ask_groups": ask_groups,
        "all": table, "by_model": by_model, "matched": matched, "unmatched": unmatched,
    }


def _count(values) -> Dict[str, int]:
    out: Dict[str, int] = {}
    for value in values:
        out[str(value)] = out.get(str(value), 0) + 1
    return out


def read_objects(paths: List[str]) -> List[Dict[str, Any]]:
    """Archive and live lines from files (plain or .gz), or stdin."""
    objects = []
    for path in paths or ["-"]:
        if path == "-":
            stream = sys.stdin
        elif path.endswith(".gz"):
            stream = gzip.open(path, "rt", encoding="utf-8")
        else:
            stream = open(path, "r", encoding="utf-8")
        try:
            for number, line in enumerate(stream, 1):
                if line.strip():
                    value = json.loads(line)
                    if not isinstance(value, dict) or value.get("mode") not in ("archive", "live"):
                        raise ValueError("%s line %d is no archive or live object" % (path, number))
                    objects.append(value)
        finally:
            if stream is not sys.stdin:
                stream.close()
    return objects


def print_json(value: Dict[str, Any]) -> None:
    json.dump(value, sys.stdout, ensure_ascii=False, sort_keys=True)
    sys.stdout.write("\n")
    sys.stdout.flush()


def main(argv: List[str]) -> int:
    parser = argparse.ArgumentParser(prog="measure.py", description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="mode")
    live = sub.add_parser("live", help="one lane sandbox's session stores")
    live.add_argument("--home", default=os.path.expanduser("~"))
    live.add_argument("--item")
    live.add_argument("--repo")
    arch = sub.add_parser("archive", help="every <repo>/<item> under --root, or one --dir")
    where = arch.add_mutually_exclusive_group(required=True)
    where.add_argument("--root")
    where.add_argument("--dir")
    arch.add_argument("--since", default=DEFAULT_SINCE)
    arch.add_argument("--oversee-state", action="append", default=[], metavar="REPO=PATH")
    arch.add_argument("--brief-tail", action="append", default=[], metavar="REPO=PATH")
    arch.add_argument("--min-free-gb", type=float, default=3.0)
    agg = sub.add_parser("aggregate", help="the measure table from archive and live output lines")
    agg.add_argument("--issues", help="JSON {item: {estimate, agent}} read from the tracker")
    agg.add_argument("files", nargs="*")
    args = parser.parse_args(argv)
    if args.mode == "live":
        result = run_live(os.path.abspath(args.home), args.item)
        result["repo"] = args.repo
        print_json(result)
        return 0
    if args.mode == "aggregate":
        try:
            issues: Dict[str, Any] = {}
            if args.issues:
                with open(args.issues, "r", encoding="utf-8") as handle:
                    issues = json.load(handle)
            objects = read_objects(args.files)
        except (OSError, ValueError) as error:
            notice("aggregate-input", str(error), "An input file is unreadable, or a line is not the output of this script's live or archive mode.")
            return 2
        print_json(aggregate(objects, issues))
        return 0
    if args.mode != "archive":
        parser.print_help(sys.stderr)
        return 2
    target = args.root or args.dir
    if not os.path.isdir(target):
        notice("archive-dir", target, "The archive directory does not exist or is not a directory.")
        return 2
    since = parse_at(args.since + "T00:00:00Z" if len(args.since) == 10 else args.since) if args.since else None
    if args.since and since is None:
        notice("since", args.since, "--since takes a date (YYYY-MM-DD) or an ISO 8601 UTC time.")
        return 2
    try:
        counts = run_archive(target, args.dir is not None, since, repo_map(args.oversee_state, "--oversee-state"),
                             repo_map(args.brief_tail, "--brief-tail"), args.min_free_gb, print_json)
    except DiskLow as low:
        notice("disk-low", low.args[0], "Free space on / is under --min-free-gb; stopped before the next item. Lines above are complete.")
        return 3
    except (OSError, ValueError) as error:
        notice("input-unreadable", str(error), "A required input (--oversee-state or --brief-tail) could not be read.")
        return 2
    notice("archive-done", counts, "Items under the root, items emitted, and items with no kept record since --since.")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
