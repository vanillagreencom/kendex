"""Ownership: the marker, at its canonical position.

`renders.md` § Common rules puts the marker at the file's **first comment**,
preceded only by a prologue the format requires, and names the two: YAML
frontmatter in a markdown output that carries it, and the
`yaml-language-server` schema line at the top of `.coderabbit.yaml`. That set
is cited rather than restated — `_after_prologue` below keys on the extension,
so a second copy of the file list here would go stale against both.

**Ownership is the marker at that position, not the marker anywhere.** A
hand-written file at a generated path that merely quotes or preserves the
marker further down would otherwise read as managed, and `render` would
overwrite bytes `adopt` never took over. `render`, `adopt` and `orphan` all
ask this one question of every output.
"""

from .constants import CODERABBIT_SCHEMA_LINE, MARKER_TOKEN

HTML = "html"
HASH = "hash"


def style_for(path):
    if path.endswith((".yaml", ".yml")):
        return HASH
    if path.endswith(".toml"):
        return HASH
    return HTML


def _after_prologue(path, text):
    """The bytes the marker must open, with the format's prologue removed."""
    if path.endswith(".md") and text.startswith("---\n"):
        end = text.find("\n---\n", 3)
        if end != -1:
            return text[end + 5:]
    if path.endswith((".yaml", ".yml")):
        first = text.split("\n", 1)
        if first[0].strip() == CODERABBIT_SCHEMA_LINE and len(first) > 1:
            return first[1]
    return text


def at_canonical_position(path, text):
    """Does this package own `text` at `path`?"""
    if text is None:
        return False
    body = _after_prologue(path, text)
    for line in body.split("\n"):
        if not line.strip():
            continue
        opener = "<!--" if style_for(path) == HTML else "#"
        if not line.lstrip().startswith(opener):
            return False
        return MARKER_TOKEN in _first_comment(body, style_for(path))
    return False


def _first_comment(body, style):
    lines = []
    for line in body.split("\n"):
        if not line.strip() and not lines:
            continue
        if style == HASH:
            if not line.lstrip().startswith("#"):
                break
            lines.append(line)
            continue
        lines.append(line)
        if "-->" in line:
            break
    return "\n".join(lines)


def region_owned(region_body):
    """The `AGENTS.md` owned region, whose marker opens the region's body."""
    return at_canonical_position("AGENTS.md", region_body or "")


def insert(path, text, marker_text):
    """Put the marker at the canonical position of an existing file."""
    if path.endswith(".md") and text.startswith("---\n"):
        end = text.find("\n---\n", 3)
        if end != -1:
            return text[: end + 5] + "\n" + marker_text + "\n" + text[end + 5:]
    if path.endswith((".yaml", ".yml")):
        head, _, rest = text.partition("\n")
        if head.strip() == CODERABBIT_SCHEMA_LINE:
            return head + "\n" + marker_text + "\n" + rest
    return marker_text + "\n\n" + text
