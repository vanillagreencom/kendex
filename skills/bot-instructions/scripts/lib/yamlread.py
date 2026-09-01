"""A reader for exactly the YAML this package emits.

`coderabbit-schema`, `coderabbit-filters`, `copilot-frontmatter` and
`macroscope-render` all judge the rendered file rather than the model it came
from, so a future generator change cannot route around them. That needs a
parser, and this package ships one rather than depending on a third-party
runtime in every repo that vendors it.

It reads the subset `yamlemit` writes and **fails on anything else**. A file
it cannot read is a finding, never a pass: an under-reading parser would let a
malformed render validate, which is the silent failure this package exists to
remove.
"""

from .errors import RenderError

INDENT = 2


class YamlSubsetError(RenderError):
    pass


def loads(text, where="<yaml>"):
    # Every line is kept: a blank line inside a block scalar is content, and
    # dropping it up front would silently rewrite the value being judged.
    rows = list(enumerate(text.split("\n")))
    value, pos = _parse(rows, _skip(rows, 0), 0, where)
    pos = _skip(rows, pos)
    if pos != len(rows):
        raise YamlSubsetError(f"{where}: line {rows[pos][0] + 1} is outside the subset this reads")
    return value


def _skip(rows, pos):
    """Past blank and comment lines, which carry no structure."""
    while pos < len(rows) and (not rows[pos][1].strip() or _is_comment(rows[pos][1])):
        pos += 1
    return pos


def _is_comment(line):
    return line.lstrip().startswith("#")


def _indent(line):
    return len(line) - len(line.lstrip(" "))


def _parse(rows, pos, level, where):
    pos = _skip(rows, pos)
    if pos >= len(rows):
        return None, pos
    if rows[pos][1].lstrip().startswith("- "):
        return _sequence(rows, pos, level, where)
    return _mapping(rows, pos, level, where)


def _mapping(rows, pos, level, where):
    out = {}
    while True:
        pos = _skip(rows, pos)
        if pos >= len(rows):
            break
        lineno, line = rows[pos]
        if _indent(line) != level:
            break
        body = line.strip()
        if body.startswith("- "):
            break
        if ":" not in body:
            raise YamlSubsetError(f"{where}:{lineno + 1}: not a `key: value` line")
        key, _, rest = body.partition(":")
        key, rest = key.strip(), rest.strip()
        pos += 1
        out[key], pos = _value(rest, rows, pos, level, where, lineno)
    return out, pos


def _sequence(rows, pos, level, where):
    out = []
    while True:
        pos = _skip(rows, pos)
        if pos >= len(rows):
            break
        lineno, line = rows[pos]
        if _indent(line) != level or not line.strip().startswith("- "):
            break
        rest = line.strip()[2:]
        if ":" in rest and not rest.startswith(("|", ">")):
            # An inline mapping opener: re-read this row as the mapping's
            # first key at the item's own indentation.
            rows[pos] = (lineno, " " * (level + INDENT) + rest)
            item, pos = _mapping(rows, pos, level + INDENT, where)
            out.append(item)
            continue
        pos += 1
        value, pos = _value(rest, rows, pos, level, where, lineno)
        out.append(value)
    return out, pos


def _value(rest, rows, pos, level, where, lineno):
    if rest in ("|2-", ">2-"):
        return _block(rows, pos, level + INDENT, rest.startswith(">"), where)
    if rest == "":
        nxt = _skip(rows, pos)
        if nxt < len(rows) and _indent(rows[nxt][1]) > level:
            return _parse(rows, nxt, _indent(rows[nxt][1]), where)
        raise YamlSubsetError(f"{where}:{lineno + 1}: a key with no value and no block under it")
    return _scalar(rest, where, lineno), pos


def _block(rows, pos, level, folded, where):
    body = []
    while pos < len(rows):
        line = rows[pos][1]
        if line.strip() and _indent(line) < level:
            break
        body.append(line[level:] if line.strip() else "")
        pos += 1
    while body and not body[-1]:
        # `|2-` and `>2-` strip trailing newlines, so trailing blanks are the
        # separator before the next node rather than content.
        body.pop()
        pos -= 1
    text = "\n".join(body) if not folded else " ".join(x.strip() for x in body if x.strip())
    return text, pos


def _scalar(text, where, lineno):
    if text == '""':
        return ""
    if len(text) > 1 and text[0] == '"' and text[-1] == '"':
        # The one quoted form this package emits: a `.instructions.md`
        # `applyTo` and a Macroscope `include`/`exclude` entry. The glob
        # dialect refuses `"`, so there is nothing to unescape.
        inner = text[1:-1]
        if '"' in inner:
            raise YamlSubsetError(f"{where}:{lineno + 1}: a quoted scalar carrying a quote")
        return inner
    if text == "[]":
        return []
    if text == "{}":
        return {}
    if text in ("true", "false"):
        return text == "true"
    try:
        return int(text)
    except ValueError:
        pass
    try:
        return float(text)
    except ValueError:
        pass
    raise YamlSubsetError(
        f"{where}:{lineno + 1}: {text!r} is a plain scalar. This package emits every "
        "string as a block scalar, so a plain one is not something it wrote"
    )
