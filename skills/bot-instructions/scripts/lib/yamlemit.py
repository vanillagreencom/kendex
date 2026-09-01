"""A YAML emitter for the one file this package writes in YAML.

`renders.md` § `.coderabbit.yaml` fixes the escaping rule: every string is
emitted as a block or folded scalar with explicit indentation, never a quoted
one-line scalar. Repo text is then passed through with no escaping, which
block scalars make safe for everything a YAML scalar can hold — and everything
they cannot hold is refused at input by `repo-toml.md` § The content refusals,
whose `control` predicate covers a YAML scalar and a TOML one at once.

**This module runs that same predicate rather than a copy of it.** Not every
string reaching here comes through a refusal row: doctrine text, schema
defaults and derived globs do not, and a narrower test here — `\n` and `\r`,
say, where the class also holds U+0085, U+2028 and U+2029 — is how a character
the table refuses reaches the rendered file anyway. `refusals.control` is the
one statement of the class; below it is applied, never restated.

Emitting rather than depending on PyYAML is deliberate: this package is
vendored into repos that need no third-party runtime to render or to check.
"""

from .errors import RenderError
from . import refusals

INDENT = "  "


class Commented:
    """One sequence item and the comment line above it.

    `reviews.path_filters` is the one place a rendered value needs a reason
    beside it — `renders.md` § `reviews.path_filters` requires one per entry,
    for the reason `repo-toml.md` § `[exclusions]` gives for requiring the key
    at all: an exclusion with no stated reason is indistinguishable from a
    mistake at the next read. A YAML comment runs to end of line, so the text
    is refused rather than escaped if it could leave that line — and what
    could leave it is every character `refusals.control` names, not the two a
    `\n`/`\r` test would catch. A comment that ends early becomes structure:
    the rest of the reason is read as a mapping key beside `path_filters`.
    """

    def __init__(self, value, comment):
        why = refusals.control(comment)
        if why is not None or "\n" in comment:
            raise RenderError(
                f"a YAML comment carries one line; this one {why or 'carries a newline'}"
            )
        self.value = value
        self.comment = comment


def block(value, indent, folded=False):
    """One string as a block scalar with an explicit indentation indicator.

    The indicator is required rather than cosmetic: without it a value whose
    first line begins with a space changes the block's indentation and the
    parse silently shifts.

    The lines this indents are `\n`-separated, which is the only break the
    block form carries. A character a READER also breaks on lands mid-line
    here, so the text after it reaches the parser unindented, ends the block
    scalar, and is read as structure — refused rather than emitted.
    """
    if not isinstance(value, str):
        raise RenderError(f"block scalar wants a string, got {type(value).__name__}")
    why = refusals.control(value)
    if why is not None:
        raise RenderError(f"a block scalar cannot carry this value: it {why}")
    head = (">" if folded else "|") + "2-"
    body = "\n".join(f"{indent}{INDENT}{line}" if line else "" for line in value.split("\n"))
    return f"{head}\n{body}"


def scalar(value, indent):
    if isinstance(value, bool):
        return "true" if value else "false"
    if isinstance(value, (int, float)):
        return repr(value) if isinstance(value, float) else str(value)
    if isinstance(value, str):
        # The one exception to the block-scalar rule, and it is a property of
        # the form rather than a choice: a block scalar cannot carry an empty
        # string. `""` needs no escaping, so nothing the rule protects is lost.
        return '""' if value == "" else block(value, indent)
    raise RenderError(f"no YAML form for {type(value).__name__}")


def emit(node, indent=""):
    """A mapping or sequence, rendered depth-first in the order given."""
    lines = []
    if isinstance(node, dict):
        for key, value in node.items():
            if isinstance(value, (dict, list)) and value:
                lines.append(f"{indent}{key}:")
                lines.extend(emit(value, indent + INDENT))
            elif isinstance(value, dict):
                lines.append(f"{indent}{key}: {{}}")
            elif isinstance(value, list):
                lines.append(f"{indent}{key}: []")
            else:
                lines.append(f"{indent}{key}: {scalar(value, indent)}")
        return lines
    if isinstance(node, list):
        for item in node:
            if isinstance(item, Commented):
                lines.append(f"{indent}# {item.comment}")
                item = item.value
            if isinstance(item, dict):
                inner = emit(item, indent + INDENT)
                lines.append(f"{indent}- {inner[0].lstrip()}")
                lines.extend(inner[1:])
            else:
                lines.append(f"{indent}- {scalar(item, indent)}")
        return lines
    raise RenderError(f"emit wants a mapping or a sequence, got {type(node).__name__}")


def document(node):
    return "\n".join(emit(node)) + "\n"
