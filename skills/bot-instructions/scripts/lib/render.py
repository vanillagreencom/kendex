"""One render: every enabled surface's bytes, plus the `AGENTS.md` region body.

`AGENTS.md` is outside the whole-file scheme, because it is the one output
whose non-owned bytes belong to the repo. The build produces the region's body
alone; the write re-reads the file, locates the region in those bytes, and
splices there. Carrying a build-phase copy of the whole file through
validation would discard anything written to it in that window — an editor, a
formatter, another lane of the repo's commit chain — silently.
"""

import json

from .constants import CODERABBIT_SCHEMA_PATH, CODERABBIT_TOP_LEVEL
from .errors import InputError, RenderError
from . import render_coderabbit, render_markdown, render_qodo

AGENTS_REGION = "AGENTS.md#region"


class Build:
    def __init__(self, model, files, region_body):
        self.model = model
        self.files = files              # repo-relative path -> text
        self.region_body = region_body  # None when [bots] codex is false

    def paths(self):
        return list(self.files)


def build(tree, model):
    bots = model.config.bots
    files = {}
    region = None
    if bots["codex"]:
        region = render_markdown.agents_region_body(model)
    if bots["copilot"]:
        files[".github/copilot-instructions.md"] = render_markdown.copilot_instructions(model)
        for surface in model.config.surfaces:
            files[f".github/instructions/{surface['name']}.instructions.md"] = (
                render_markdown.instructions_file(model, surface)
            )
    if bots["coderabbit"]:
        files[".coderabbit.yaml"] = render_coderabbit.render(model, load_schema(tree))
    if bots["qodo"]:
        files[".pr_agent.toml"] = render_qodo.render(model)
    if bots["qodo_best_practices"] and model.config.surfaces:
        # No surfaces: the file is not written. An existing marked one becomes
        # an orphan, so retiring the last surface says so rather than leaving
        # a marker-only file that looks like current guidance.
        files["best_practices.md"] = render_markdown.best_practices(model)
    if bots["qodo_review_md"]:
        files["REVIEW.md"] = render_markdown.review_md(model)
    if bots["macroscope"]:
        files[".macroscope/ignore.md"] = render_markdown.macroscope_ignore(model)
        files[".macroscope/correctness/doctrine.md"] = render_markdown.macroscope_doctrine(model)
        for surface in model.config.surfaces:
            files[f".macroscope/correctness/{surface['name']}.md"] = (
                render_markdown.macroscope_surface(model, surface)
            )
    return Build(model, files, region)


def load_schema(tree):
    """The vendored CodeRabbit schema. Absent is a failure, never a skip.

    No verb writes this file, so every repo starts without one, and a
    validator that skipped on its absence would be silent for the life of a
    repo that never vendored it.
    """
    raw = tree.read(CODERABBIT_SCHEMA_PATH)
    if raw is None:
        raise InputError(
            f"{CODERABBIT_SCHEMA_PATH}: absent, and `[bots] coderabbit` is true. "
            "references/checklist.md § Adding a repo carries the step that puts the "
            "first copy there; no verb writes it"
        )
    try:
        schema = json.loads(raw)
    except ValueError as exc:
        raise InputError(f"{CODERABBIT_SCHEMA_PATH}: unparseable JSON ({exc})") from exc
    # `renders.md` § Keys fixes the top-level order, and a vendored copy that
    # defines fewer properties than that order names is a copy too old or too
    # trimmed to render full state against. This is about the schema, not
    # about what the render produced: the render dropping a key it built is
    # `coderabbit-schema`'s completeness clause, and a fixture reds one or the
    # other, never both.
    defined = schema.get("properties") or {}
    missing = [k for k in CODERABBIT_TOP_LEVEL if k not in defined]
    if missing:
        raise InputError(
            f"{CODERABBIT_SCHEMA_PATH}: defines no top-level {missing[0]!r}, which "
            "renders.md § Keys requires in full state. Refresh the vendored copy"
        )
    return schema


def splice(existing, region_body, path="AGENTS.md"):
    """Replace the owned region's body in `existing`, returning new bytes.

    The opening matches `^## Code Review Rules$` exactly — no trailing
    whitespace, no CR, no leading BOM — because kendex's `tools/guard` slices
    this section the same way, and a heading a looser generator accepted would
    be one that repo's guard reports as missing. The terminator uses the wide
    heading predicate at level 1 or 2, because markdown reads `#` after one to
    three spaces as a heading and a narrower terminator would let the splice
    swallow that section and everything below it.
    """
    lines = existing.split("\n")
    opens = [i for i, ln in enumerate(lines) if ln == render_markdown.AGENTS_HEADING]
    if len(opens) != 1:
        raise RenderError(
            f"{path}: found {len(opens)} `{render_markdown.AGENTS_HEADING}` headings; "
            "exactly one is required. Zero is an error and two is an error rather than "
            "a guess about which one to replace"
        )
    start = opens[0]
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if _is_heading_1_or_2(lines[i]):
            end = i
            break
    body = region_body.strip("\n").split("\n")
    # One blank line each side of the body, so the region never runs into the
    # heading that terminates it.
    return "\n".join(lines[: start + 1] + [""] + body + [""] + lines[end:])


def _is_heading_1_or_2(line):
    stripped = line.lstrip(" ")
    if len(line) - len(stripped) > 3:
        return False
    if not stripped.startswith("#"):
        return False
    hashes = len(stripped) - len(stripped.lstrip("#"))
    return hashes in (1, 2)


def region_of(existing, path="AGENTS.md"):
    """The owned region's body in `existing`, for `drift` to compare."""
    lines = existing.split("\n")
    opens = [i for i, ln in enumerate(lines) if ln == render_markdown.AGENTS_HEADING]
    if len(opens) != 1:
        return None
    start = opens[0]
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if _is_heading_1_or_2(lines[i]):
            end = i
            break
    return "\n".join(lines[start + 1 : end]).strip("\n")
