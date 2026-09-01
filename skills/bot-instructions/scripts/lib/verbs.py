"""`render`, `check`, `adopt`.

`render` builds and validates a complete scratch tree, then replaces each
path. What this does not claim is an atomic multi-file replacement: no
filesystem offers one, and a mixed tree that says so beats one that does not.
Each individual replacement is atomic, so every path holds either its old
bytes or its new ones.
"""

import re

from . import marker, render, run, writer
from .errors import RenderError, ValidationFailed


def _cause(exc):
    """What to print for a failure. Its message, or its class when it has none."""
    return str(exc) or type(exc).__name__


def render_verb(ctx, root, dry_run=False):
    """Validate, then write. A validator failure leaves the repo untouched."""
    run.require_clean(ctx)
    paths = sorted(ctx.build.files)
    if ctx.build.region_body is not None:
        paths.append("AGENTS.md")
    if not paths:
        return ["nothing to render: every [bots] flag is false"] + ctx.skipped
    if dry_run:
        return [f"would write {p}" for p in paths] + ctx.skipped
    written = []
    try:
        for path in sorted(ctx.build.files):
            writer.replace(root, path, ctx.build.files[path])
            written.append(path)
        if ctx.build.region_body is not None:
            _splice(ctx, root)
            written.append("AGENTS.md")
    except BaseException as exc:
        # `KeyboardInterrupt` and `SystemExit` stringify to NOTHING, and a
        # Ctrl-C part way through is the case this report exists for. The test
        # is on the string: an exception instance is truthy whatever its
        # message, so `exc or ...` would still print the empty one.
        raise RenderError("\n".join([
            f"write phase failed: {_cause(exc)}",
            "replaced before the failure: " + (", ".join(written) or "none"),
            "every path above holds either its old bytes or its new ones — re-run "
            "render to finish the set",
        ])) from exc
    return [f"wrote {p}" for p in written] + ctx.skipped


def _splice(ctx, root):
    """Replace the region in the bytes the write phase itself opened.

    Nothing outside the region is carried through the build, so an edit
    landing between the build and the write survives instead of being
    overwritten by a copy taken before it.
    """
    def transform(existing):
        if existing is None:
            raise RenderError("AGENTS.md: absent at write time")
        current = render.region_of(existing)
        if current is None:
            raise RenderError(
                "AGENTS.md: the owned region could not be located at write time — the "
                "heading is gone or duplicated since the build read it"
            )
        if not marker.owns("AGENTS.md", current):
            # No whitespace test: a region whose body is empty is still a
            # region this package does not own, and treating it as writable
            # would be the bootstrap exemption `renders.md` § `AGENTS.md`
            # refuses. The bootstrap is adopt, then render.
            raise RenderError(
                "AGENTS.md: the `## Code Review Rules` region carries no marker at its "
                "canonical position, so it is the repo's own — run `adopt` to take it over"
            )
        return render.splice(existing, ctx.build.region_body)

    writer.replace(root, "AGENTS.md", transform=transform, require_marker=False)


def check_verb(ctx):
    findings = run.validate(ctx)
    if findings:
        raise ValidationFailed(findings)
    return [f"check clean: {len(ctx.build.files)} generated path(s) agree with a fresh render"]


def adopt_verb(ctx, root):
    """Take hand-written files at generated paths over, and say what they held.

    A file it takes over keeps its bytes and gains the marker: the next render
    replaces it, and the diff between the two is the content that has to
    survive in the TOML.
    """
    lines, pointers = [], set()
    try:
        for path in sorted(ctx.build.files):
            held = _adopt_file(ctx, root, path)
            if held is None:
                continue
            lines.append(f"adopted {path} ({len(held.splitlines())} lines it held)")
            pointers |= points_at(held)
        if ctx.build.region_body is not None:
            lines.extend(_adopt_region(ctx, root, pointers))
    except BaseException as exc:
        # The report IS the output of this verb: what each file held is the
        # diff the TOML has to absorb, and the pointer list is what the
        # operator is told to read against it. A second adopt finishes the set
        # and finds neither, because those files now carry the marker.
        raise RenderError("\n".join(
            lines
            + _pointer_lines(pointers)
            + [f"adopt failed: {_cause(exc)}",
               "the paths named above were taken over before the failure and "
               "nothing else was — re-run adopt to finish the set"]
        )) from exc
    lines.extend(_pointer_lines(pointers))
    if not lines:
        lines.append("nothing to adopt: every generated path is already this package's")
    return lines


def _pointer_lines(pointers):
    """The markdown files the adopted content points at, in one place."""
    return [f"points at {t} — read it against the TOML" for t in sorted(pointers)]


def _adopt_file(ctx, root, path):
    """Take one generated path over, or leave it. Returns the bytes it held.

    Ownership is decided on the bytes being replaced rather than on an earlier
    read of the same path: `adopt` writes with the marker gate off, so an edit
    landing between a separate read and the write would be overwritten by a
    marked copy of the pre-edit file with nothing to refuse it.
    """
    held = []

    def transform(existing):
        if existing is None or marker.owns(path, existing):
            return None
        held.append(existing)
        return marker.insert(existing, ctx.model.marker(marker.style_for(path)))

    if not writer.replace(root, path, transform=transform, require_marker=False):
        return None
    return held[0]


def _adopt_region(ctx, root, pointers):
    """The region form of `_adopt_file`, and it shares the reason: the region
    read, the ownership decision and the splice come from one open."""
    held = []

    def transform(existing):
        if existing is None:
            return None
        current = render.region_of(existing)
        if current is None or marker.owns("AGENTS.md", current):
            return None
        held.append(current)
        body = ctx.model.marker("html") + ("\n\n" + current if current.strip() else "")
        return render.splice(existing, body)

    if not writer.replace(root, "AGENTS.md", transform=transform, require_marker=False):
        return []
    pointers |= points_at(held[0])
    return [f"adopted AGENTS.md § Code Review Rules ({len(held[0].splitlines())} lines it held)"]


# `adopt` names every repo-root or `.github/` markdown file an adopted file
# points at. Three forms, one level, no recursion: an inline link's target, a
# reference definition's target, and a backticked path. Anything else is prose
# a person reads, and following it would make the report unbounded.
_INLINE = re.compile(r"\]\(([^)\s]+)\)")
_REFDEF = re.compile(r"^\[[^\]]+\]:\s*(\S+)", re.M)
_TICKED = re.compile(r"`([A-Za-z0-9._/-]+\.md)`")


def points_at(text):
    out = set()
    for rx in (_INLINE, _REFDEF, _TICKED):
        for hit in rx.findall(text):
            # A leading `./` only. `lstrip("./")` would eat the dot of
            # `.github/`, which is one of the two places this report looks.
            target = hit.split("#", 1)[0]
            while target.startswith("./"):
                target = target[2:]
            if not target.endswith(".md"):
                continue
            if "/" not in target or target.startswith(".github/"):
                out.add(target)
    return out
