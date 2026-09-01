"""Repo-state validators: they judge the repository, so a scratch tree is the
one place they cannot fail.

`orphan` looks for what the current TOML does not produce, and the scratch
tree holds only what it does. `drift` compares a path's bytes against a fresh
render, which in the scratch tree are the same bytes. `exclusion-consistency`'s
derived-set clause compares a rendered set against an independent fresh
derivation — which is not vacuous even at render time, because a serializer
that drops one derived tree from every destination leaves the derivation
holding it, so that clause runs on both verbs against whichever tree the verb
produced.
"""

import tomllib

from .constants import EXCLUSION_PROSE_COLUMNS
from .errors import Finding, RenderError
from . import globs, manifest, marker, render, render_markdown

# Every root-level path this package may have written, plus
# `.macroscope/approvability.md`, the one Macroscope read path it never
# writes: a marked generated file moved there stays active and nothing else
# here would judge it. `.macroscope/ignore.md` IS written — `render.build`
# emits it whenever `[bots] macroscope` is true — and it is in this tuple for
# the ordinary reason, so that a marked copy survives the flag going false.
# The other never-written read path, `.macroscope/check-run-agents`, is a
# directory and belongs to SCANNED_TREES below.
ROOT_OUTPUTS = (
    ".github/copilot-instructions.md",
    ".coderabbit.yaml",
    ".pr_agent.toml",
    "best_practices.md",
    "REVIEW.md",
    ".macroscope/ignore.md",
    ".macroscope/approvability.md",
)
SCANNED_TREES = (
    ".github/instructions",
    ".macroscope/correctness",
    ".macroscope/check-run-agents",
)


def agents_section(ctx, out):
    """Codex reads `AGENTS.md` § Code Review Rules and nothing else."""
    v = "agents-section"
    heading = render_markdown.AGENTS_HEADING
    for path in _nested_agents_files(ctx):
        text = ctx.read(path)
        if text and any(ln == heading for ln in text.split("\n")):
            out.append(Finding(v, "a nested AGENTS.md carries a `## Code Review Rules` "
                                  "section. Codex reads the nearest nested file covering "
                                  "each changed path, so it reaches Codex without passing "
                                  "through doctrine, and the generator writes only the "
                                  "root one", path))
    if not ctx.config.bots["codex"]:
        # With the flag off there is no managed region to judge, and rejecting
        # a missing heading would fail a repo that never asked for one.
        return
    text = ctx.read("AGENTS.md")
    if text is None:
        out.append(Finding(v, "[bots] codex is true and the repo has no AGENTS.md. The "
                              "generator never creates it and never adds the heading",
                           "AGENTS.md"))
        return
    count = len(render.headings(text))
    if count != 1:
        out.append(Finding(v, f"found {count} `{heading}` headings; exactly one is "
                              "required", "AGENTS.md"))


def _nested_agents_files(ctx):
    tracked = ctx.tracked_paths()
    return [p for p in tracked if p.endswith("/AGENTS.md")]


def orphan(ctx, out):
    """A retired surface's file is still there and the bot still loads it."""
    v = "orphan"
    produced = set(ctx.build.files)
    for path in sorted(set(ROOT_OUTPUTS) | _scanned(ctx)):
        if path in produced:
            continue
        text = ctx.read(path)
        if marker.at_canonical_position(path, text):
            out.append(Finding(v, "carries this package's marker and the current TOML does "
                                  "not produce it. Retiring one is delete-then-render, in "
                                  "that order", path))
    if ctx.config.bots["codex"] or ctx.build.region_body is not None:
        return
    text = ctx.read("AGENTS.md")
    if text is not None:
        region = render.region_of(text)
        if marker.region_owned(region):
            out.append(Finding(v, "the `## Code Review Rules` region carries the marker and "
                                  "[bots] codex is false. De-orphaning it is not a deletion "
                                  "of the file: the heading is the repo's and has to "
                                  "survive; what goes is the marker and the body below it",
                               "AGENTS.md"))


def _scanned(ctx):
    found = set()
    for tree in SCANNED_TREES:
        found.update(ctx.walk(tree))
    return found


_UNREADABLE = object()


def _readable(v, ctx, path, out):
    """One produced path's bytes, or `_UNREADABLE` with the finding recorded.

    A path this package produces whose bytes it cannot decode differs from a
    fresh render — the render's bytes decode and these do not — so saying so
    is this validator's clause. Read outside a guard it left `check` with a
    bare message naming no validator, no finding count, and no remedy, while
    `render` quietly replaced the file.
    """
    try:
        return ctx.read_output(path)
    except RenderError as exc:
        out.append(Finding(v, f"{exc}, so it cannot be compared with a fresh render. "
                              "A render replaces it", path))
        return _UNREADABLE


def drift(ctx, out):
    """A hand edit to a generated file survives until the next render, then
    vanishes; between those moments the repo's behavior does not match its
    source, and the edit's author has no reason to suspect it."""
    v = "drift"
    for path, rendered in sorted(ctx.build.files.items()):
        actual = _readable(v, ctx, path, out)
        if actual is _UNREADABLE:
            continue
        if actual is None:
            out.append(Finding(v, "the current TOML produces this path and it is absent",
                               path))
        elif actual != rendered:
            out.append(Finding(v, f"differs from a fresh render, first at line "
                                  f"{_first_diff(actual, rendered)}", path))
    if ctx.build.region_body is None:
        return
    existing = _readable(v, ctx, "AGENTS.md", out)
    if existing is _UNREADABLE:
        return
    if existing is None:
        out.append(Finding(v, "[bots] codex is true and AGENTS.md is absent", "AGENTS.md"))
        return
    region = render.region_of(existing)
    if region is None:
        out.append(Finding(v, "the owned region could not be located", "AGENTS.md"))
    elif region != ctx.build.region_body.strip("\n"):
        out.append(Finding(v, "the `## Code Review Rules` owned region differs from a fresh "
                              "render. This validator is that comparison's only owner: the "
                              "file always holds content the render did not write, so a "
                              "whole-file comparison would differ on every repo",
                           "AGENTS.md"))


def _first_diff(a, b):
    for i, (x, y) in enumerate(zip(a.split("\n"), b.split("\n")), 1):
        if x != y:
            return i
    return min(len(a.split("\n")), len(b.split("\n"))) + 1


def exclusion_consistency(ctx, out):
    """The exclusion lists name the skills that existed when someone last wrote
    them, so a newly rendered tree is reviewed as if it were this repo's code."""
    v = "exclusion-consistency"
    # The flag gates the derived-set clause and nothing else: it says where
    # the exclusions come from, not whether they are checked. Every clause
    # BELOW that branch judges a hand-written `[[exclusions.path]]` set just
    # as well — stated by where they sit rather than counted, because a count
    # here went stale the moment one was added. `derive_render` defaults to
    # false, so gating them on it left every repo on the default with
    # `_prose_destinations` — the only enforcer of SKILL.md § Every rendered
    # config excludes the render trees — never run.
    sources, unreadable = ctx.exclusion_sources()
    scratch, scratch_bad = ctx.scratch_exclusions()
    for name, why in sorted({**scratch_bad, **unreadable}.items()):
        # Named as the read failure it is. A surface whose exclusion list
        # cannot be read is left out of the comparisons below rather than
        # compared against a stand-in value, which would arrive as a set
        # mismatch naming a glob nobody wrote.
        out.append(Finding(v, f"{why}, so this surface cannot be compared", name))
    if ctx.config.exclusions["derive_render"]:
        _derived_set(v, ctx, sources, out)
    _cross_surface(v, ctx, scratch, out)
    _prose_destinations(v, ctx, out)
    _dead_globs(v, ctx, out)


def _derived_set(v, ctx, sources, out):
    """The rendered derived part against an independent fresh derivation.

    The manifest read is not guarded here. It runs only under
    `[exclusions] derive_render`, and `model.build` calls the same two
    functions on the same tree under that same flag while `Context` is being
    built — where `run._as_finding` attributes a `ManifestError` to this
    validator already. A second handler here can only ever be dead, and a dead
    handler is a clause with no control.
    """
    resolved, _ = manifest.resolve(ctx.tree)
    fresh = {e["glob"] for e in manifest.derive(ctx.tree, resolved)}
    hand = {e["glob"] for e in ctx.config.exclusions["path"]}
    for name, listed in sources.items():
        rendered_derived = set(listed) - hand
        for missing in sorted(fresh - rendered_derived):
            out.append(Finding(v, f"{missing!r} is derived from the resolved manifest and "
                                  f"is absent from the rendered exclusions", name))
        for extra in sorted(rendered_derived - fresh):
            out.append(Finding(v, f"{extra!r} is in the rendered exclusions and the "
                                  "resolved manifest derives no such tree", name))


def _cross_surface(v, ctx, sources, out):
    names = list(sources)
    for i, a in enumerate(names):
        for b in names[i + 1:]:
            for glob in sorted(set(sources[a]) - set(sources[b])):
                out.append(Finding(v, f"{glob!r} is excluded in {a} and not in {b}"))
            for glob in sorted(set(sources[b]) - set(sources[a])):
                out.append(Finding(v, f"{glob!r} is excluded in {b} and not in {a}"))


PROSE_LEAD = "Those paths here: "


def _prose_entries(text):
    """The exact entries the `Those paths here:` sentence lists, or None.

    A SET, parsed once, rather than a substring search per glob. `if glob not
    in text` answers yes for `src/**` whenever `vendor/src/**` is listed, so
    dropping the first from every carrier produced no finding at all. An
    earlier round answered that cause by narrowing WHICH text is searched,
    which left the predicate intact and put the same hole one nesting away.
    Parsing the sentence removes it: containment cannot stand in for
    membership at any destination.

    Line-scoped, because every emitter writes the sentence on one line and
    ends it with a full stop. `None` says the sentence is absent, which is a
    different finding from one listing the wrong set.
    """
    for line in text.split("\n"):
        at = line.find(PROSE_LEAD)
        if at == -1:
            continue
        listed = line[at + len(PROSE_LEAD):].strip().removesuffix(".")
        return {entry.strip() for entry in listed.split(",") if entry.strip()}
    return None


def _prose_destinations(v, ctx, out):
    """Without this a render could drop the paths from the one surface Codex
    reads and violate nothing checkable."""
    wanted = set(ctx.model.exclusion_globs)
    if not wanted:
        return
    carriers = {"AGENTS.md": ctx.build.region_body}
    carriers.update(_qodo_guidance(v, ctx, out))
    for column in EXCLUSION_PROSE_COLUMNS:
        text = carriers.get(column)
        if text is None:
            continue
        listed = _prose_entries(text)
        if listed is None:
            out.append(Finding(v, f"the routing table marks {column!r} as carrying the "
                                  f"exclusion paths and it carries no {PROSE_LEAD!r} "
                                  "sentence at all"))
            continue
        for glob in sorted(wanted - listed):
            out.append(Finding(v, f"the routing table marks {column!r} as carrying the "
                                  f"exclusion paths and {glob!r} is not among the "
                                  f"{len(listed)} it lists"))
        for extra in sorted(listed - wanted):
            out.append(Finding(v, f"the routing table marks {column!r} as carrying the "
                                  f"exclusion paths and it lists {extra!r}, which the "
                                  "TOML does not exclude"))


def _qodo_guidance(v, ctx, out):
    """The two Qodo destinations, read as the keys the review agent reads.

    Asking whether a glob appears anywhere in `.pr_agent.toml` is satisfied by
    `[ignore] glob`, which lists every exclusion and is an unrelated
    mechanism: it filters what Qodo analyzes for `/improve`, not what the
    review agent reads, which is why the prose exists as well. A render that
    dropped the paths from both guidance keys passed this clause on the
    strength of the list beside them.
    """
    text = ctx.build.files.get(".pr_agent.toml")
    if text is None:
        return {}
    try:
        doc = tomllib.loads(text)
    except tomllib.TOMLDecodeError as exc:
        # Unreadable is not "carries the paths": `qodo-parity` names the same
        # failure, and a clause that cannot read its destination says so.
        out.append(Finding(v, f".pr_agent.toml is not valid TOML ({exc}), so whether the "
                              "guidance keys carry the exclusion paths cannot be read"))
        return {}
    return {
        "pr_agent issues": doc.get("review_agent", {}).get("issues_user_guidelines", ""),
        "pr_agent extra": doc.get("pr_reviewer", {}).get("extra_instructions", ""),
    }


def _dead_globs(v, ctx, out):
    """A glob matching no tracked path silences nothing and reads clean."""
    if not ctx.model.exclusions:
        # No exclusion is declared, so none can be dead. The unreachability
        # finding below exists to stop this clause reporting each exclusion as
        # dead for a reason that is not the author's; with nothing to report
        # it would be a finding about an empty set.
        return
    tracked = ctx.tracked_paths()
    if not tracked:
        out.append(Finding(v, "the repo tracks no files, so the dead-exclusion verdict is "
                              "unreachable and this clause cannot answer its question"))
        return
    for entry in ctx.model.exclusions:
        if not globs.matching(entry["glob"], tracked):
            out.append(Finding(v, f"exclusion {entry['glob']!r} matches no tracked path, so "
                                  "it silences nothing — a typo or a wrong anchor is dead "
                                  "config that reads as an exclusion"))
