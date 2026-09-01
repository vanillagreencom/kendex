"""Byte validators: they judge one render — its inputs and the bytes it
produced — and nothing around it, so they read the scratch tree, on both verbs.

Each names the silent failure it exists to catch in `schemas/validators.md`.
Every rejection clause here has one red control in `tests/`, asserting on the
validator's own identity rather than on the run's exit code.
"""

import tomllib

from .constants import (
    ALL_BLOCK_COLUMNS,
    CODERABBIT_SCHEMA_PATH,
    MARKER_TOKEN,
    QODO_VERBS,
    ROUTING_COLUMNS,
)
from .errors import Finding
from . import globs, jsonschema, render_coderabbit, yamlread


def doctrine_routing(ctx, out):
    """The routing table is the generator's single routing input, so a
    one-character edit to it is a silent policy change."""
    v = "doctrine-routing"
    doc = ctx.doctrine
    headings = set(doc.blocks)
    rows = set(doc.positions)
    for bid in sorted(headings - rows):
        out.append(Finding(v, f"doctrine block {bid!r} has no row in the routing table; "
                              "an unrouted block renders into nothing at all"))
    for bid in sorted(rows - headings):
        out.append(Finding(v, f"routing table row {bid!r} names no `###` heading in the "
                              "doctrine source, so it renders a hole"))
    frozen = set(ctx.frozen_ids)
    for bid in sorted(frozen - headings):
        out.append(Finding(v, f"block id {bid!r} is frozen and the doctrine source no longer "
                              "defines it. A consuming repo's [doctrine.append] keyed on it "
                              "would silently reach nothing"))
    for bid in sorted(headings - frozen):
        out.append(Finding(v, f"block id {bid!r} is not in the frozen set. Renaming a heading "
                              "and its row together leaves both sides agreeing, which is why "
                              "the comparison is against the frozen set and not the pair"))
    for column in ROUTING_COLUMNS:
        order = doc.routing[column]
        positions = [doc.positions[b][column] for b in order]
        if len(set(positions)) != len(positions):
            out.append(Finding(v, f"column {column!r} repeats a position"))
        if positions and positions != list(range(1, len(positions) + 1)):
            out.append(Finding(v, f"column {column!r} positions are {positions}, not 1..n"))
    for column in ALL_BLOCK_COLUMNS:
        missing = headings - set(doc.routing[column])
        for bid in sorted(missing):
            out.append(Finding(v, f"column {column!r} omits {bid!r}. That bot reads no second "
                                  "surface, so the block reaches it nowhere"))


def coderabbit_schema(ctx, out):
    """CodeRabbit rejects an invalid file whole and reviews with resolved
    defaults, saying nothing on the pull request."""
    v = "coderabbit-schema"
    if not ctx.config.bots["coderabbit"]:
        return
    schema = ctx.schema
    chosen = render_coderabbit.overrides(ctx.model)
    # Before the early returns below: an override the vendored copy no longer
    # defines is a question about the schema and the overrides, and neither a
    # missing render nor an unreadable one makes it go away.
    missing = render_coderabbit.unresolved(schema, chosen)
    if missing:
        out.append(Finding(v, render_coderabbit.unresolved_message(missing),
                           CODERABBIT_SCHEMA_PATH))
    text = ctx.build.files.get(".coderabbit.yaml")
    if text is None:
        out.append(Finding(v, "[bots] coderabbit is true and no .coderabbit.yaml was rendered"))
        return
    try:
        doc = yamlread.loads(text, ".coderabbit.yaml")
    except Exception as exc:
        out.append(Finding(v, f"the rendered file is not readable: {exc}"))
        return
    try:
        for message in jsonschema.validate(doc, schema, ".coderabbit.yaml"):
            out.append(Finding(v, message))
    except jsonschema.Unimplemented as exc:
        out.append(Finding(v, str(exc)))
        return
    _completeness(v, doc, schema, chosen, "", out)


def _completeness(v, doc, schema, chosen, path, out):
    """Every property the vendored schema defines a default for, at every depth.

    Root-only completeness passes a render that dropped a nested option under
    an existing object, and the setting silently resumes resolving down the
    unversioned ladder while the file reports as full state.
    """
    for key, sub in (schema.get("properties") or {}).items():
        here = f"{path}.{key}" if path else key
        nested = sub.get("type") == "object" and sub.get("properties")
        # The render's own predicate, so the two cannot disagree about a key
        # and leave a state no config can satisfy.
        if not render_coderabbit.in_full_state(sub, chosen, here):
            continue
        if key not in doc:
            out.append(Finding(v, f"the render omits {here!r}, which the vendored schema "
                                  "defines. An omitted key resumes resolving down a "
                                  "precedence ladder this package does not control"))
            continue
        if nested and isinstance(doc[key], dict):
            _completeness(v, doc[key], sub, chosen, here, out)


def coderabbit_filters(ctx, out):
    """One entry lacking `!` is an allowlist, and every unlisted file in the
    repo stops being reviewed."""
    v = "coderabbit-filters"
    text = ctx.build.files.get(".coderabbit.yaml")
    if text is None:
        return
    try:
        entries = yamlread.loads(text)["reviews"]["path_filters"]
    except Exception as exc:
        out.append(Finding(v, f"cannot read reviews.path_filters: {exc}"))
        return
    for entry in entries:
        if not entry.startswith("!"):
            out.append(Finding(v, f"path_filters entry {entry!r} does not start with `!`. "
                                  "One such entry turns the list into an allowlist and "
                                  "un-reviews every file no entry names"))
            continue
        try:
            globs.check(entry[1:], "reviews.path_filters")
        except Exception as exc:
            out.append(Finding(v, f"{exc}. CodeRabbit feeds these to `git sparse-checkout`, "
                                  "which reads plain globs only"))


def copilot_frontmatter(ctx, out):
    """A file with no `applyTo` matches nothing and never loads; `excludeAgent`
    fails in the direction that looks fine."""
    v = "copilot-frontmatter"
    by_name = {s["name"]: s for s in ctx.config.surfaces}
    for path, text in ctx.build.files.items():
        if not path.startswith(".github/instructions/"):
            continue
        name = path.rsplit("/", 1)[1].removesuffix(".instructions.md")
        front, why = _frontmatter(text)
        if front is None:
            out.append(Finding(v, why or "no YAML frontmatter", path))
            continue
        if "applyTo" not in front:
            out.append(Finding(v, "no `applyTo`, so the file matches nothing and never "
                                  "loads", path))
        else:
            raw = front["applyTo"]
            if isinstance(raw, list):
                out.append(Finding(v, "`applyTo` is a YAML array; it must be a single "
                                      "comma-separated string", path))
            elif not str(raw).strip():
                out.append(Finding(v, "`applyTo` is empty or whitespace", path))
        _exclude_agent(v, front, by_name.get(name), path, out)


def _exclude_agent(v, front, surface, path, out):
    value = front.get("excludeAgent")
    if surface is not None and surface["reviewer_only"]:
        if value is None:
            out.append(Finding(v, "reviewer_only surface with no `excludeAgent`, so its "
                                  "reviewer doctrine loads into the working agent", path))
        elif value != "cloud-agent":
            out.append(Finding(v, f"reviewer_only surface with excludeAgent {value!r}. "
                                  "`code-review` is the documented opposite: it hides the "
                                  "file from the reviewer and leaves the working agent "
                                  "reading it", path))
        return
    if value is not None:
        out.append(Finding(v, f"ordinary surface carries excludeAgent {value!r}. The render "
                              "emits none here, so its presence is a renderer regression; "
                              "`code-review` would hide the surface's path rules from code "
                              "review with the file present and parsing", path))


def _frontmatter(text):
    """`(mapping, why)`. Exactly one of the two is None.

    Absent frontmatter and frontmatter the reader could not parse are
    different failures with different fixes, and collapsing them into one
    `None` sent the author looking for a dropped block when the render had
    emitted one nothing could read — the wrong half of the renderer. A body
    that parses to something other than a mapping is its own answer too,
    rather than a value the callers then reach `.get` on.
    """
    if not text.startswith("---\n"):
        return None, None
    end = text.find("\n---\n", 3)
    if end == -1:
        return None, "frontmatter opens with `---` and never closes"
    try:
        front = yamlread.loads(text[4:end], "frontmatter")
    except Exception as exc:
        return None, f"frontmatter is present and does not parse: {exc}"
    if not isinstance(front, dict):
        return None, ("frontmatter parses to a "
                      f"{type(front).__name__}, and only a mapping carries keys")
    return front, None


def copilot_budget(ctx, out):
    """GitHub asks for no longer than 2 pages and documents no numeric cap, so
    an over-long file has no error to produce."""
    v = "copilot-budget"
    text = ctx.build.files.get(".github/copilot-instructions.md")
    if text is None:
        return
    budget = ctx.config.budgets["copilot_chars"]
    if len(text) > budget:
        sizes = "; ".join(
            f"{head}: {size}" for head, size in _sections(text)
        )
        out.append(Finding(v, f"{len(text)} characters, over [budgets] copilot_chars "
                              f"{budget}. Sections by size — {sizes}",
                           ".github/copilot-instructions.md"))


def _sections(text):
    out, head, size = [], "(head)", 0
    for line in text.split("\n"):
        if line.startswith("#"):
            out.append((head, size))
            head, size = line.strip("# "), 0
        size += len(line) + 1
    out.append((head, size))
    return sorted(out, key=lambda p: -p[1])


def qodo_parity(ctx, out):
    """`/review` reads `[pr_reviewer] extra_instructions`; `/agentic_review`
    reads `[review_agent]`. Guidance in one is absent from the other's path."""
    v = "qodo-parity"
    text = ctx.build.files.get(".pr_agent.toml")
    if text is None:
        return
    try:
        doc = tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        out.append(Finding(v, f".pr_agent.toml is not valid TOML ({exc})"))
        return
    extra = doc.get("pr_reviewer", {}).get("extra_instructions", "")
    union = (doc.get("review_agent", {}).get("issues_user_guidelines", "")
             + "\n" + doc.get("review_agent", {}).get("compliance_user_guidelines", ""))
    # Identity is recovered from the inputs, not from the rendered TOML: the
    # Qodo render drops block headings, and two overrides may give two blocks
    # identical text, so nothing in the output can name a block. What the
    # render emitted for each id is re-derived here and looked for.
    for column, section, label in (
        ("pr_agent extra", extra, "[pr_reviewer] extra_instructions"),
        ("pr_agent issues", union, "the [review_agent] keys"),
        ("pr_agent compliance", union, "the [review_agent] keys"),
    ):
        for bid, _ in ctx.model.blocks_for(column):
            # The whole assembled block, not its first line: `[doctrine.append]`
            # and the tracker substitution are already applied, and the render
            # only ever adds after a block's text, so the block is a prefix of
            # what was emitted for it.
            if ctx.model.block(bid) not in section:
                out.append(Finding(v, f"doctrine block {bid!r} is routed to {column!r} and "
                                      f"is absent from {label}"))
    for verb in ctx.config.cadence["qodo_commands"]:
        if QODO_VERBS.get(verb) != "review":
            continue
        section = extra if verb == "/review" else union
        if not section.strip():
            out.append(Finding(v, f"[github_app] pr_commands runs {verb!r}, whose role is "
                                  "review, and the section it reads carries no guidance"))


def qodo_best_practices(ctx, out):
    """A generated file nobody bounded is a file nobody reads."""
    v = "qodo-best-practices"
    text = ctx.build.files.get("best_practices.md")
    if text is None:
        return
    budget = ctx.config.budgets["qodo_best_practices_lines"]
    lines = len(text.split("\n"))
    if lines > budget:
        worst = sorted(
            ((s["name"], len(s["instructions"].split("\n"))) for s in ctx.config.surfaces),
            key=lambda p: -p[1],
        )
        top = "; ".join(f"{n}: {c}" for n, c in worst[:5])
        out.append(Finding(v, f"{lines} lines, over this package's budget of {budget}. Qodo "
                              "documents that as writing guidance and states no length at "
                              f"which it rejects or truncates, so this render was stopped by "
                              f"this package, not by Qodo. Largest surfaces — {top}",
                           "best_practices.md"))


def macroscope_render(ctx, out):
    """A correctness file whose frontmatter Macroscope cannot read is a file it
    will not apply, and the only signal is a comment that never arrives."""
    v = "macroscope-render"
    names = {s["name"] for s in ctx.config.surfaces}
    for path, text in ctx.build.files.items():
        if path.startswith(".macroscope/correctness/"):
            name = path.rsplit("/", 1)[1].removesuffix(".md")
            if name in names:
                _correctness(v, path, text, out)
        elif path == ".macroscope/ignore.md":
            _ignore(v, path, text, out)


def _correctness(v, path, text, out):
    front, why = _frontmatter(text)
    if front is None:
        out.append(Finding(v, why or
                           "no frontmatter. Omitted frontmatter applies repo-wide, so a "
                           "dropped `include` silently widens a path-scoped surface to "
                           "the whole repository", path))
        return
    for key in front:
        if key not in ("include", "exclude"):
            out.append(Finding(v, f"frontmatter key {key!r} is not `include` or `exclude`", path))
    if "include" not in front:
        out.append(Finding(v, "`include` is absent, which applies the file repo-wide", path))
    for key in ("include", "exclude"):
        if key in front:
            value = front[key]
            if not isinstance(value, list) or not all(isinstance(x, str) for x in value):
                out.append(Finding(v, f"`{key}` is not a YAML array of strings", path))
            elif key == "include" and not value:
                out.append(Finding(v, "`include` is empty", path))
    body = text.split(MARKER_TOKEN, 1)[-1]
    body = body.split("-->", 1)[-1].strip()
    if not body:
        out.append(Finding(v, "no instruction text below the marker. A marker and "
                              "frontmatter with nothing under them tell Macroscope "
                              "nothing", path))


def _ignore(v, path, text, out):
    """Every non-blank line is a pattern; everything else stays in a comment."""
    for i, line in enumerate(text.split("\n"), 1):
        if not line.strip():
            continue
        if line.lstrip().startswith("<!--"):
            if not line.rstrip().endswith("-->") or line.count("-->") != 1:
                out.append(Finding(v, f"line {i} is a comment that does not close on its "
                                      "own line, or carries content after `-->`", path))
            continue
        try:
            globs.check(line, f"{path}:{i}")
        except Exception as exc:
            out.append(Finding(v, f"line {i} is neither a glob in the dialect nor a "
                                  f"single-line HTML comment: {exc}", path))
