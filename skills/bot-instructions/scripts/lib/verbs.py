"""`render`, `check`, `adopt`.

`render` builds and validates a complete scratch tree, writes a manifest of
every path it is about to replace, then replaces them. What this does not
claim is an atomic multi-file replacement: no filesystem offers one, and a
mixed tree that says so beats one that does not. Each individual replacement
is atomic, so every path holds either its old bytes or its new ones.
"""

from . import marker, render, run, writer
from .errors import RenderError, ValidationFailed
from .fsutil import open_root


def render_verb(ctx, root, dry_run=False):
    """Validate, then write. A validator failure leaves the repo untouched."""
    root_fd = open_root(root)
    lines = []
    with writer.RenderLock(root_fd):
        pending = writer.read_manifest(root_fd)
        if pending:
            lines.append(
                "an earlier render left a manifest naming "
                + ", ".join(pending)
                + "; this run finishes the set"
            )
        run.require_clean(ctx)
        paths = sorted(ctx.build.files)
        if ctx.build.region_body is not None:
            paths.append("AGENTS.md")
        if not paths:
            return ["nothing to render: every [bots] flag is false"] + ctx.skipped
        if dry_run:
            return [f"would write {p}" for p in paths] + ctx.skipped
        writer.write_manifest(root_fd, paths)
        written = []
        try:
            for path in sorted(ctx.build.files):
                writer.replace(root_fd, path, ctx.build.files[path])
                written.append(path)
            if ctx.build.region_body is not None:
                _splice(ctx, root_fd)
                written.append("AGENTS.md")
        except BaseException as exc:
            lines.append(f"write phase failed: {exc}")
            lines.append("replaced before the failure: " + (", ".join(written) or "none"))
            lines.append(
                "every path above holds either its old bytes or its new ones, and the "
                "manifest names the rest — re-run render to finish the set"
            )
            raise RenderError("\n".join(lines)) from exc
        writer.clear_manifest(root_fd)
        lines.extend(f"wrote {p}" for p in written)
    return lines + ctx.skipped


def _splice(ctx, root_fd):
    """The write re-reads `AGENTS.md` and replaces the region in those bytes.

    Nothing outside the region is carried through the build, so an edit
    landing between the build and the write survives instead of being
    overwritten by a copy taken before it.
    """
    from .fsutil import read_text

    existing = read_text(root_fd, "AGENTS.md")
    if existing is None:
        raise RenderError("AGENTS.md: absent at write time")
    current = render.region_of(existing)
    if current is None:
        raise RenderError(
            "AGENTS.md: the owned region could not be located at write time — the heading "
            "is gone or duplicated since the build read it"
        )
    if not marker.region_owned(current) and current.strip():
        raise RenderError(
            "AGENTS.md: the `## Code Review Rules` region carries no marker at its "
            "canonical position, so it is the repo's own — run `adopt` to take it over"
        )
    writer.replace(root_fd, "AGENTS.md", render.splice(existing, ctx.build.region_body),
                   require_marker=False)


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
    root_fd = open_root(root)
    lines, pointers = [], set()
    for path in sorted(ctx.build.files):
        text = ctx.read(path)
        if text is None or marker.at_canonical_position(path, text):
            continue
        style = marker.style_for(path)
        writer.replace(root_fd, path, marker.insert(path, text, ctx.model.marker(style)),
                       require_marker=False)
        lines.append(f"adopted {path} ({len(text.splitlines())} lines it held)")
        pointers |= points_at(text)
    if ctx.build.region_body is not None:
        lines.extend(_adopt_region(ctx, root_fd, pointers))
    for target in sorted(pointers):
        lines.append(f"points at {target} — read it against the TOML")
    if not lines:
        lines.append("nothing to adopt: every generated path is already this package's")
    return lines


def _adopt_region(ctx, root_fd, pointers):
    from .fsutil import read_text

    existing = read_text(root_fd, "AGENTS.md")
    if existing is None:
        return []
    current = render.region_of(existing)
    if current is None or marker.region_owned(current):
        return []
    pointers |= points_at(current)
    body = ctx.model.marker("html") + ("\n\n" + current if current.strip() else "")
    writer.replace(root_fd, "AGENTS.md", render.splice(existing, body), require_marker=False)
    return [f"adopted AGENTS.md § Code Review Rules ({len(current.splitlines())} lines it held)"]


import re

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
