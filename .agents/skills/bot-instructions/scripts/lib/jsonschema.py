"""A JSON Schema validator that refuses what it does not implement.

`validators.md` § `coderabbit-schema` fixes the rule: a schema keyword this
validator does not implement is a failure naming the keyword, never a skip. A
validator that ignores an unknown constraint under-validates while reporting
success. That means a schema refresh can block renders until this catches up,
which is why the vendored copy's refresh step is a checklist line.

Lengths count Unicode code points, which is what `maxLength` counts.
"""

import re

# Keywords that carry no constraint. Ignoring one under-validates nothing.
ANNOTATIONS = frozenset(
    {"$schema", "$id", "$comment", "title", "description", "default",
     "examples", "deprecated", "enumNames", "readOnly", "writeOnly"}
)

IMPLEMENTED = frozenset(
    {"type", "enum", "const", "properties", "additionalProperties", "required",
     "items", "minItems", "maxItems", "minLength", "maxLength", "minimum",
     "maximum", "pattern", "anyOf", "allOf", "propertyNames"}
)

_TYPES = {
    "object": dict,
    "array": list,
    "string": str,
    "integer": int,
    "number": (int, float),
    "boolean": bool,
    "null": type(None),
}


class Unimplemented(Exception):
    """A keyword this validator does not implement."""


def validate(instance, schema, path="$"):
    """Every violation, as a list of human-readable strings."""
    out = []
    for keyword in schema:
        if keyword not in ANNOTATIONS and keyword not in IMPLEMENTED:
            raise Unimplemented(
                f"{path}: schema keyword {keyword!r} is not implemented by this validator. "
                "Failing rather than ignoring it: an ignored constraint under-validates "
                "while reporting success"
            )
    _type(instance, schema, path, out)
    if "const" in schema and instance != schema["const"]:
        out.append(f"{path}: is {instance!r}, not the required {schema['const']!r}")
    if "enum" in schema and instance not in schema["enum"]:
        out.append(f"{path}: {instance!r} is not one of {schema['enum']}")
    if "pattern" in schema and isinstance(instance, str):
        if not re.search(schema["pattern"], instance):
            out.append(f"{path}: {instance!r} does not match {schema['pattern']!r}")
    _bounds(instance, schema, path, out)
    if isinstance(instance, dict):
        _object(instance, schema, path, out)
    if isinstance(instance, list) and "items" in schema:
        for i, item in enumerate(instance):
            out.extend(validate(item, schema["items"], f"{path}[{i}]"))
    for branch in schema.get("allOf", []):
        out.extend(validate(instance, branch, path))
    if "anyOf" in schema:
        if not any(not validate(instance, b, path) for b in schema["anyOf"]):
            out.append(f"{path}: matches none of the {len(schema['anyOf'])} permitted forms")
    return out


def _type(instance, schema, path, out):
    if "type" not in schema:
        return
    wanted = schema["type"]
    names = wanted if isinstance(wanted, list) else [wanted]
    for name in names:
        if name not in _TYPES:
            raise Unimplemented(f"{path}: schema type {name!r} is not implemented")
        want = _TYPES[name]
        # `bool` is a subclass of `int` in Python and of nothing in JSON
        # Schema, so a boolean never satisfies `integer` or `number` here.
        if name != "boolean" and isinstance(instance, bool):
            continue
        if isinstance(instance, want):
            return
    out.append(f"{path}: is {type(instance).__name__}, not {'/'.join(names)}")


def _bounds(instance, schema, path, out):
    if isinstance(instance, str):
        if "maxLength" in schema and len(instance) > schema["maxLength"]:
            out.append(
                f"{path}: {len(instance)} code points, over the schema's maxLength "
                f"{schema['maxLength']} — CodeRabbit discards the whole file over this"
            )
        if "minLength" in schema and len(instance) < schema["minLength"]:
            out.append(f"{path}: {len(instance)} code points, under minLength {schema['minLength']}")
    if isinstance(instance, list):
        if "maxItems" in schema and len(instance) > schema["maxItems"]:
            out.append(f"{path}: {len(instance)} entries, over maxItems {schema['maxItems']}")
        if "minItems" in schema and len(instance) < schema["minItems"]:
            out.append(f"{path}: {len(instance)} entries, under minItems {schema['minItems']}")
    if isinstance(instance, (int, float)) and not isinstance(instance, bool):
        if "maximum" in schema and instance > schema["maximum"]:
            out.append(f"{path}: {instance} is over maximum {schema['maximum']}")
        if "minimum" in schema and instance < schema["minimum"]:
            out.append(f"{path}: {instance} is under minimum {schema['minimum']}")


def _object(instance, schema, path, out):
    props = schema.get("properties", {})
    for key in schema.get("required", []):
        if key not in instance:
            out.append(f"{path}: required property {key!r} is absent")
    extra = [k for k in instance if k not in props]
    if schema.get("additionalProperties") is False and extra:
        out.append(
            f"{path}: unknown key {extra[0]!r} — the root sets additionalProperties false, "
            "so one misspelled key makes CodeRabbit discard the whole file"
        )
    if "propertyNames" in schema:
        for key in instance:
            out.extend(validate(key, schema["propertyNames"], f"{path}.{key} (name)"))
    for key, value in instance.items():
        if key in props:
            out.extend(validate(value, props[key], f"{path}.{key}"))
        elif isinstance(schema.get("additionalProperties"), dict):
            out.extend(validate(value, schema["additionalProperties"], f"{path}.{key}"))
