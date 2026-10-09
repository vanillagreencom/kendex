"""The configurable fields of the shipped refresh caller, and their GitHub reads."""

import json
import re
import subprocess
import sys
from urllib.parse import quote


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
    legacy = set(secrets) == set(DEFAULT_NAMES)
    expected = DEFAULT_NAMES if legacy else ("app-id", "app-private-key")
    if set(secrets) != set(expected):
        raise InvalidCaller("names")
    names = []
    for key in expected:
        match = re.fullmatch(r"\$\{\{ secrets\.([A-Za-z_][A-Za-z0-9_]*) \}\}", secrets[key])
        if not match:
            raise InvalidCaller("expression")
        # GitHub secret references are case insensitive; its API stores names
        # in uppercase, so the declared mapping uses the same comparison form.
        names.append(match.group(1).upper())
    if set(inputs) - {"environment", "app-id-secret-name", "app-private-key-secret-name"}:
        raise InvalidCaller("inputs")
    declared = [inputs.get("app-id-secret-name", DEFAULT_NAMES[0]).upper(),
                inputs.get("app-private-key-secret-name", DEFAULT_NAMES[1]).upper()]
    if names != declared or (legacy and names != list(DEFAULT_NAMES)):
        raise InvalidCaller("secret-names")
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
    return {"environment": environment, "names": names, "start": start, "end": end,
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


def validate_environment(repository, config, environment):
    """Refuse missing secrets or a policy admitting other branches before adoption."""
    def refuse(cause, operation=None):
        raise SystemExit("refresh-error=environment value=" + config["environment"] + " cause=" + cause +
                         (" operation=" + operation if operation else ""))

    def read(endpoint):
        try:
            output = subprocess.check_output(["gh", "api", endpoint, "--paginate"],
                                             env=environment, stderr=subprocess.PIPE, text=True)
            pages = []
            decoder = json.JSONDecoder()
            while output.strip():
                page, end = decoder.raw_decode(output.lstrip())
                pages.append(page)
                output = output.lstrip()[end:]
            if not pages:
                refuse("read", endpoint)
            return pages
        except subprocess.CalledProcessError as error:
            print(error.stderr, file=sys.stderr, end="")
            refuse("read", endpoint)
        except ValueError:
            refuse("read", endpoint)

    def rows(endpoint, key):
        pages = read(endpoint)
        if not all(isinstance(page, dict) and isinstance(page.get(key), list) for page in pages):
            refuse("read", endpoint)
        return [row for page in pages for row in page[key]]

    repos = read("repos/{owner}/{repo}")
    branch = repos[0].get("default_branch") if isinstance(repos[0], dict) else None
    if not isinstance(branch, str) or not branch:
        refuse("read")
    envs = rows("repos/" + repository + "/environments", "environments")
    if not all(isinstance(row, dict) and isinstance(row.get("name"), str) for row in envs):
        refuse("read")
    selected = [row for row in envs if row["name"] == config["environment"]]
    if len(selected) != 1:
        refuse("missing")
    policy = selected[0].get("deployment_branch_policy")
    if not isinstance(policy, dict) or policy.get("custom_branch_policies") is not True or policy.get("protected_branches") is not False:
        refuse("branch-policy")
    endpoint = "repos/" + repository + "/environments/" + quote(config["environment"], safe="")
    policies = rows(endpoint + "/deployment-branch-policies", "branch_policies")
    if len(policies) != 1 or not isinstance(policies[0], dict) or policies[0].get("name") != branch or policies[0].get("type", "branch") != "branch":
        refuse("branch-policy")
    secrets = rows(endpoint + "/secrets", "secrets")
    if not all(isinstance(row, dict) and isinstance(row.get("name"), str) for row in secrets):
        refuse("read")
    if not set(config["names"]).issubset({row["name"].upper() for row in secrets}):
        refuse("secrets")
