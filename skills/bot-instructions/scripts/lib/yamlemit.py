"""A YAML emitter for the one file this package writes in YAML.

`renders.md` § `.coderabbit.yaml` fixes the escaping rule: every string is
emitted as a block or folded scalar with explicit indentation, never a quoted
one-line scalar. Repo text is then passed through with no escaping, which
block scalars make safe for everything a YAML scalar can hold — and everything
they cannot hold is refused at input by `repo-toml.md` § The content refusals,
whose `control` predicate covers a YAML scalar and a TOML one at once.

Emitting rather than depending on PyYAML is deliberate: this package is
vendored into repos that need no third-party runtime to render or to check.
"""

from .errors import RenderError

INDENT = "  "


def block(value, indent, folded=False):
    """One string as a block scalar with an explicit indentation indicator.

    The indicator is required rather than cosmetic: without it a value whose
    first line begins with a space changes the block's indentation and the
    parse silently shifts.
    """
    if not isinstance(value, str):
        raise RenderError(f"block scalar wants a string, got {type(value).__name__}")
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
