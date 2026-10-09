"""The configurable fields of the shipped refresh caller, and their GitHub reads."""

import json
import re


class InvalidCaller(ValueError):
    pass


CALL = re.compile(r"^    uses: vanillagreencom/kendex/\.github/workflows/refresh-consumer\.yml@[^\n]+\n?", re.M)
DEFAULT_NAMES = ("FLEET_GH_APP_ID", "FLEET_GH_APP_PRIVATE_KEY")


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
    neutral = ("app-id", "app-private-key")
    legacy = set(secrets) == set(DEFAULT_NAMES)
    expected = DEFAULT_NAMES if legacy else neutral
    if set(secrets) not in (set(DEFAULT_NAMES), set(neutral), set(DEFAULT_NAMES + neutral)):
        raise InvalidCaller("names")
    references = {}
    for key in secrets:
        match = re.fullmatch(r"\$\{\{ secrets\.([A-Za-z_][A-Za-z0-9_]*) \}\}", secrets[key])
        if not match:
            raise InvalidCaller("expression")
        # GitHub secret references are case insensitive; its API stores names
        # in uppercase, so the declared mapping uses the same comparison form.
        references[key] = match.group(1).upper()
    names = [references[key] for key in expected]
    if set(inputs) - {"environment", "app-id-secret-name", "app-private-key-secret-name"}:
        raise InvalidCaller("inputs")
    declared = [inputs.get("app-id-secret-name", DEFAULT_NAMES[0]).upper(),
                inputs.get("app-private-key-secret-name", DEFAULT_NAMES[1]).upper()]
    if names != declared or (legacy and names != list(DEFAULT_NAMES)):
        raise InvalidCaller("secret-names")
    if not legacy:
        for key in DEFAULT_NAMES:
            if key in references and references[key] != key:
                raise InvalidCaller("legacy-secret-names")
    required_names = list(dict.fromkeys(names + (list(DEFAULT_NAMES) if not legacy and set(DEFAULT_NAMES).issubset(secrets) else [])))
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
    return {"environment": environment, "names": names, "required_names": required_names, "start": start, "end": end,
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
