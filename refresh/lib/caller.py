"""The configurable fields of the shipped refresh caller, and their GitHub reads."""

import json
import re


class InvalidCaller(ValueError):
    pass


CALL = re.compile(r"^    uses: vanillagreencom/kendex/\.github/workflows/refresh-consumer\.yml@[^\n]+\n?", re.M)
DEFAULT_NAMES = ("FLEET_GH_APP_ID", "FLEET_GH_APP_PRIVATE_KEY")
NEUTRAL_NAMES = ("KENDEX_APP_ID", "KENDEX_APP_PRIVATE_KEY")
ALIASES = ("app-id", "app-private-key")


def configuration(data):
    text = data.decode("utf-8")
    calls = list(CALL.finditer(text))
    if not calls:
        return None
    if len(calls) != 1:
        raise InvalidCaller("calls")
    start = calls[0].end()
    end = start
    for line in text[start:].splitlines(keepends=True):
        if line.strip() and not line.startswith("    "):
            break
        end += len(line)
    block = text[start:end]
    inputs, secrets = {}, {}
    section = None
    sections = set()
    for line in block.splitlines():
        if not line.strip():
            continue
        if line in ("    with:", "    secrets:"):
            if line in sections:
                raise InvalidCaller("duplicate")
            sections.add(line)
            section = inputs if line == "    with:" else secrets
            continue
        match = re.fullmatch(r"      ([A-Za-z0-9_-]+): (.+)", line)
        if section is None or not match:
            raise InvalidCaller("not-mapping")
        key, value = match.groups()
        if key in section:
            raise InvalidCaller("duplicate")
        section[key] = value
    if set(secrets) - set(DEFAULT_NAMES + NEUTRAL_NAMES + ALIASES):
        raise InvalidCaller("names")
    for pair in (DEFAULT_NAMES, NEUTRAL_NAMES, ALIASES):
        if set(pair).intersection(secrets) and not set(pair).issubset(secrets):
            raise InvalidCaller("names")
    pairs = [list(pair) for pair in (NEUTRAL_NAMES, DEFAULT_NAMES) if set(pair).issubset(secrets)]
    if not pairs or (set(ALIASES).intersection(secrets) and not set(DEFAULT_NAMES).issubset(secrets)):
        raise InvalidCaller("names")
    references = {}
    for key in secrets:
        match = re.fullmatch(r"\$\{\{ secrets\.([A-Za-z_][A-Za-z0-9_]*) \}\}", secrets[key])
        if not match:
            raise InvalidCaller("expression")
        # GitHub secret references are case insensitive; its API stores names
        # in uppercase, so the declared mapping uses the same comparison form.
        references[key] = match.group(1).upper()
        expected = DEFAULT_NAMES[ALIASES.index(key)] if key in ALIASES else key
        if references[key] != expected:
            raise InvalidCaller("secret-names")
    names = list(dict.fromkeys(references.values()))
    if set(inputs) - {"environment", "app-id-secret-name", "app-private-key-secret-name"}:
        raise InvalidCaller("inputs")
    legacy_fields = [key for key in inputs if key.endswith("-secret-name")] + [key for key in ALIASES if key in secrets]
    environment = inputs.get("environment", "kendex")
    if environment.startswith('"'):
        try:
            environment = json.loads(environment)
        except ValueError as error:
            raise InvalidCaller("environment") from error
    elif environment.startswith("'") and environment.endswith("'"):
        environment = environment[1:-1].replace("''", "'")
    # Literal names make adoption's API read select exactly the called job's
    # environment. Expressions and YAML objects cannot establish that fact.
    if not isinstance(environment, str) or not environment.strip() or any(c in environment for c in "\r\n${}[]#"):
        raise InvalidCaller("environment")
    return {"environment": environment, "names": names, "pairs": pairs, "legacy_fields": legacy_fields,
            "start": start, "end": end,
            "block": block, "text": text}


def normalized(data):
    config = configuration(data)
    if config is None:
        return data
    return (config["text"][:config["start"]] + "    # consumer refresh configuration\n" +
            config["text"][config["end"]:]).encode()


def configured(data, config):
    replacement = configuration(data)
    if replacement is None or config is None:
        return data
    if replacement["environment"] == config["environment"] and replacement["names"] == config["names"]:
        return data
    return (replacement["text"][:replacement["start"]] + config["block"] +
            replacement["text"][replacement["end"]:]).encode()
