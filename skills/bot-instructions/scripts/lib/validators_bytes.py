"""Byte validators: they judge one render — its inputs and the document it
produced — and nothing around it, so they read the scratch tree, on both verbs.

**None of them parses the render back.** A validator whose input is bytes this
run emitted checks the emitter against itself and needs a reader for every
format this package writes. The structure is in hand before it is serialised —
`render.Build.data` — so the same question costs a dictionary lookup.

Each names the silent failure it exists to catch in `schemas/validators.md`.
Every rejection clause here has one red control in `tests/`, asserting on the
validator's own identity rather than on the run's exit code.
"""

from .constants import (
    ALL_BLOCK_COLUMNS,
    CODERABBIT_SCHEMA_PATH,
    QODO_VERBS,
    ROUTING_COLUMNS,
)
from .errors import Finding
from . import jsonschema, refusals, render_coderabbit


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
    # Before the early return below: an override the vendored copy no longer
    # defines is a question about the schema and the overrides, and a missing
    # render does not make it go away.
    missing = render_coderabbit.unresolved(schema, chosen)
    if missing:
        out.append(Finding(v, render_coderabbit.unresolved_message(missing),
                           CODERABBIT_SCHEMA_PATH))
    doc = ctx.build.data.get(".coderabbit.yaml")
    if doc is None:
        out.append(Finding(v, "[bots] coderabbit is true and no .coderabbit.yaml was rendered"))
        return
    try:
        for message in jsonschema.validate(doc, schema, ".coderabbit.yaml"):
            out.append(Finding(v, message))
    except jsonschema.Unimplemented as exc:
        out.append(Finding(v, str(exc)))
        return
    _completeness(v, doc, schema, chosen, "", out)
    for where, value in _scalars(doc):
        why = refusals.control(value)
        if why is not None:
            out.append(Finding(v, f"{where} {why}. Nothing else refuses it: the value comes "
                                  "from a vendored-schema default or from this package's "
                                  "overrides, neither of which passes through the input "
                                  "table, and a YAML reader would read the rendered file "
                                  "as more lines than it holds",
                               CODERABBIT_SCHEMA_PATH))


def _scalars(node, path=""):
    """Every string in the document, by dotted path."""
    if isinstance(node, dict):
        for key, value in node.items():
            yield from _scalars(value, f"{path}.{key}" if path else str(key))
    elif isinstance(node, list):
        for i, item in enumerate(node):
            yield from _scalars(item, f"{path}[{i}]")
    elif isinstance(node, str):
        yield path, node


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


def copilot_budget(ctx, out):
    """GitHub asks for no longer than 2 pages and documents no numeric cap, so
    an over-long file has no error to produce."""
    v = "copilot-budget"
    text = ctx.build.files.get(".github/copilot-instructions.md")
    if text is None:
        return
    budget = ctx.config.budgets["copilot_chars"]
    if len(text) > budget:
        sizes = "; ".join(f"{head}: {size}" for head, size in _sections(text))
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
    sections = ctx.build.data.get(".pr_agent.toml")
    if sections is None:
        return
    union = sections["pr_agent issues"] + "\n" + sections["pr_agent compliance"]
    for verb in ctx.config.cadence["qodo_commands"]:
        if QODO_VERBS.get(verb) != "review":
            continue
        section = sections["pr_agent extra"] if verb == "/review" else union
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
    lines = len(text.splitlines())
    if lines > budget:
        worst = sorted(
            ((s["name"], len(s["instructions"].splitlines())) for s in ctx.config.surfaces),
            key=lambda p: -p[1],
        )
        top = "; ".join(f"{n}: {c}" for n, c in worst[:5])
        out.append(Finding(v, f"{lines} lines, over this package's budget of {budget}. Qodo "
                              "documents that as writing guidance and states no length at "
                              "which it rejects or truncates, so this render was stopped by "
                              f"this package, not by Qodo. Largest surfaces — {top}",
                           "best_practices.md"))
