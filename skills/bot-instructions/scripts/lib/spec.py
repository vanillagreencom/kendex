"""The spec copy: version, doctrine blocks, and the routing table.

SKILL.md § Doctrine defines a spec copy as a copy of this package whose
`SKILL.md` carries the doctrine section and whose `schemas/renders.md` carries
the routing table. One `--spec` flag names both, because `doctrine-routing`
holds one against the other and reading them from different copies would red
on every legitimate doctrine change.

**The package validates its own spec copy for shape, and trusts it for
content.** The version and the input paths are interpolated into a comment
that no structured-file validator need be in the render to catch, so both are
held to a class that cannot close a comment. Doctrine text is trusted the way
the rest of this package's own bytes are, and is re-checked only against the
content refusals, which `refusals.py` owns.
"""

import re

from .constants import (
    FROZEN_BLOCK_IDS,
    MARKER_PATH_CLASS,
    MARKER_VERSION_CLASS,
    ROUTING_COLUMNS,
)
from .errors import InputError, SpecError
from . import markdown, refusals

# A version reaches a `#` comment and an HTML comment. Anything outside this
# class could close one and put the rest into a generated file as live
# reviewer instructions.
_VERSION_CLASS = re.compile(f"^[{MARKER_VERSION_CLASS}]+$")
_PATH_CLASS = re.compile(f"^[{MARKER_PATH_CLASS}]+$")

_DASH = "–"


class Doctrine:
    def __init__(self, blocks, version, routing, positions):
        self.blocks = blocks            # id -> text
        self.version = version
        self.routing = routing          # column -> [block ids in order]
        # block id -> {column: position}. Its own attribute rather than a
        # `_positions` key inside `routing`, whose documented type is the line
        # above: a sentinel key there makes any iteration over `routing` read
        # one entry that is not a column.
        self.positions = positions


def check_marker_path(path):
    """A path the marker records. Refused rather than encoded.

    An `InputError` rather than a `SpecError`: this judges a render input
    path, not the spec copy, and `run._as_finding` catches the input family,
    so the refusal reaches the operator naming the validator whose clause it
    is instead of as a bare message. WHICH validator is the caller's to say,
    because only the caller knows where the path came from — `model.build`
    re-raises the manifest-derived ones as `ManifestError`, which is
    `exclusion-consistency`'s domain rather than the TOML's.
    """
    if not _PATH_CLASS.match(path):
        raise InputError(
            f"{path!r}: a path this render records in the marker must hold only "
            f"[{MARKER_PATH_CLASS}]; the marker is a comment and this package refuses "
            "rather than escapes"
        )
    return path


def read_version(skill_text, where):
    if not skill_text.startswith("---\n"):
        raise SpecError(f"{where}: no YAML frontmatter, so no version to stamp the marker with")
    end = skill_text.find("\n---\n", 3)
    if end == -1:
        raise SpecError(f"{where}: frontmatter is not closed")
    for line in skill_text[4:end].splitlines():
        m = re.match(r'^\s{2}version:\s*"?([^"\n]*)"?\s*$', line)
        if m:
            version = m.group(1).strip()
            if not _VERSION_CLASS.match(version):
                raise SpecError(
                    f"{where}: version {version!r} is outside [{MARKER_VERSION_CLASS}]. The marker "
                    "interpolates it into a comment, and a version carrying `-->` or a "
                    "newline would end that comment"
                )
            return version
    raise SpecError(
        f"{where}: no `version:` under metadata. A spec copy with no readable version "
        "would land a doctrine change under a stamp naming doctrine it does not carry"
    )


def parse_doctrine(skill_text, where):
    """Blocks are the `###` headings inside the one `## Doctrine` section."""
    lines = skill_text.splitlines()
    starts = [i for i, ln in enumerate(lines) if ln.strip() == "## Doctrine"]
    if len(starts) != 1:
        raise SpecError(
            f"{where}: found {len(starts)} `## Doctrine` sections; exactly one is "
            "required, and zero or more than one is an error rather than a guess"
        )
    start = starts[0]
    end = len(lines)
    for i in range(start + 1, len(lines)):
        if markdown.heading_level(lines[i]) in (1, 2):
            end = i
            break
    blocks = {}
    current = None
    body = []
    for i in range(start + 1, end):
        line = lines[i]
        m = re.match(r"^### (.+?)\s*$", line)
        if m:
            if current is not None:
                blocks[current] = "\n".join(body).strip("\n")
            current = m.group(1).strip()
            if current in blocks:
                raise SpecError(f"{where}: doctrine block id {current!r} appears twice")
            blocks[current] = None
            body = []
            continue
        if current is not None:
            body.append(line)
    if current is not None:
        blocks[current] = "\n".join(body).strip("\n")
    if not blocks:
        raise SpecError(f"{where}: the `## Doctrine` section holds no `###` blocks")
    for bid, text in blocks.items():
        if not text:
            raise SpecError(f"{where}: doctrine block {bid!r} has no text")
        refusals.apply("doctrine block text", text, f"{where} § {bid}")
    return blocks


def parse_routing(renders_text, where):
    """The one table in `renders.md` § Doctrine routing, read as data."""
    rows = [
        ln for ln in renders_text.splitlines()
        if ln.startswith("| `") and ln.count("|") == len(ROUTING_COLUMNS) + 2
    ]
    if not rows:
        raise SpecError(f"{where}: no doctrine routing table found")
    table = {}
    for line in rows:
        cells = [c.strip() for c in line.strip().strip("|").split("|")]
        block = cells[0].strip("`")
        positions = {}
        for column, cell in zip(ROUTING_COLUMNS, cells[1:]):
            if cell.startswith(_DASH) or cell.startswith("-"):
                continue
            m = re.match(r"^(\d+)", cell)
            if not m:
                raise SpecError(
                    f"{where}: routing cell {cell!r} for {block!r} in column {column!r} "
                    "is neither a position nor a dash"
                )
            positions[column] = int(m.group(1))
        if block in table:
            raise SpecError(f"{where}: routing table has two rows for {block!r}")
        table[block] = positions
    routing = {}
    for column in ROUTING_COLUMNS:
        pairs = sorted(
            ((pos[column], block) for block, pos in table.items() if column in pos),
        )
        routing[column] = [block for _, block in pairs]
    return routing, table


def load(spec_tree, skill_rel, renders_rel):
    """Read a spec copy and return its Doctrine."""
    skill_text = spec_tree.read(skill_rel)
    if skill_text is None:
        raise SpecError(f"{skill_rel}: the spec copy has no doctrine source")
    renders_text = spec_tree.read(renders_rel)
    if renders_text is None:
        raise SpecError(f"{renders_rel}: the spec copy has no routing table")
    version = read_version(skill_text, skill_rel)
    blocks = parse_doctrine(skill_text, skill_rel)
    routing, positions = parse_routing(renders_text, renders_rel)
    return Doctrine(blocks, version, routing, positions)


def frozen_ids():
    return FROZEN_BLOCK_IDS
