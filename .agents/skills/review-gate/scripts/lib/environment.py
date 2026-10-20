"""Environment judgments for refresh adoption."""

import json
import os
import subprocess
import sys
from urllib.parse import quote


def environment_policy(branch, name, environments, policies=None):
    if not isinstance(environments, list) or not all(isinstance(row, dict) and isinstance(row.get("name"), str) for row in environments):
        raise ValueError("environments")
    selected = [row for row in environments if row["name"] == name]
    if len(selected) != 1:
        return {"cause": "missing"}
    policy = selected[0].get("deployment_branch_policy")
    if not isinstance(policy, dict) or policy.get("custom_branch_policies") is not True or policy.get("protected_branches") is not False:
        return {"cause": "branch-policy"}
    if policies is None:
        return {"cause": "pending"}
    if not isinstance(policies, list) or not all(isinstance(row, dict) and isinstance(row.get("name"), str) and isinstance(row.get("type", "branch"), str) for row in policies):
        raise ValueError("branch-policies")
    if len(policies) != 1 or policies[0].get("name") != branch or policies[0].get("type", "branch") != "branch":
        return {"cause": "branch-policy"}
    return {"cause": ""}


def environment_secrets(names, secrets):
    if not isinstance(secrets, list) or not all(isinstance(row, dict) and isinstance(row.get("name"), str) for row in secrets):
        raise ValueError("secrets")
    held = {row["name"].upper() for row in secrets}
    if not set(names).issubset(held):
        cause = "secrets"
    else:
        cause = ""
    return {"cause": cause, "held": ";".join(name for name in names if name in held)}


def secret_placement(names, scopes):
    """Judge named secret copies."""
    outside, unreadable = [], []
    for row in scopes:
        label = row["scope"]
        try:
            held = environment_secrets(names, row["secrets"])["held"]
        except ValueError:
            unreadable.append(label)
            continue
        outside.extend(label + ":" + name for name in held.split(";") if name)
    return {"cause": "read" if unreadable else "secrets-outside" if outside else "",
            "outside": ";".join(outside), "unreadable": ",".join(unreadable)}


def gh_api(*arguments):
    """Use the same explicit launch contract for every adopter API read."""
    # GitHub CLI config and credential-store inputs accompany Go's proxy and
    # certificate inputs. GODEBUG selects native verification with configured
    # certificate files on macOS and Windows (crypto/x509 SystemCertPool).
    environment = {key: os.environ[key] for key in
                   ("PATH", "HOME", "GH_TOKEN", "GITHUB_TOKEN", "GH_HOST", "GH_REPO", "GH_CONFIG_DIR",
                    "GH_ENTERPRISE_TOKEN", "GITHUB_ENTERPRISE_TOKEN", "XDG_CONFIG_HOME", "AppData", "APPDATA",
                    "DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR", "DISPLAY", "XAUTHORITY",
                    "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
                    "GODEBUG", "SSL_CERT_FILE", "SSL_CERT_DIR") if key in os.environ}
    return subprocess.check_output(["gh", "api", *arguments], env=environment,
                                   stderr=subprocess.PIPE, text=True)


def validate_environment(repository, config):
    """Refuse unreadable evidence before the adopter can change any file."""
    def refuse(cause, operation=None):
        raise SystemExit("refresh-error=environment value=" + config["environment"] + " cause=" + cause +
                         (" operation=" + operation if operation else ""))

    def read(endpoint):
        try:
            output = gh_api(endpoint, "--paginate")
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
            raise
        except ValueError:
            refuse("read", endpoint)
            raise

    def rows(endpoint, key):
        pages = read(endpoint)
        if not all(isinstance(page, dict) and isinstance(page.get(key), list) for page in pages):
            refuse("read", endpoint)
        return [row for page in pages for row in page[key]]

    repos = read("repos/{owner}/{repo}")
    branch = repos[0].get("default_branch") if isinstance(repos[0], dict) else None
    if not isinstance(branch, str) or not branch:
        refuse("read")
    owner = repos[0].get("owner")
    owner_type = owner.get("type") if isinstance(owner, dict) else None
    # GitHub repository metadata defines the applicable secret namespaces.
    # Unknown owner evidence cannot authorize skipping a placement check.
    if owner_type not in ("User", "Organization"):
        refuse("read", "repos/{owner}/{repo}")
    endpoint = "repos/" + repository + "/environments/" + quote(config["environment"], safe="")
    try:
        envs = rows("repos/" + repository + "/environments", "environments")
        judgment = environment_policy(branch, config["environment"], envs)
        if judgment["cause"] == "pending":
            policies = rows(endpoint + "/deployment-branch-policies", "branch_policies")
            judgment = environment_policy(branch, config["environment"], envs, policies)
        if judgment["cause"]:
            refuse(judgment["cause"])
        secrets = rows(endpoint + "/secrets", "secrets")
        # The shared job selects a complete fixed pair, never credentials
        # from different pairs. Historical inline callers require all names.
        pairs = config.get("pairs", [config["names"]])
        if not any(not environment_secrets(pair, secrets)["cause"] for pair in pairs):
            refuse("secrets")
        # GitHub's same-name environment precedence cannot prevent an
        # outside value from filling a name absent from that environment.
        # Both token steps read fixed names, including the FLEET issue pair.
        # Only Actions repository/organization secrets can reach these
        # caller mappings.
        names = ["KENDEX_APP_ID", "KENDEX_APP_PRIVATE_KEY",
                 "FLEET_GH_APP_ID", "FLEET_GH_APP_PRIVATE_KEY"] if "pairs" in config else config["names"]
        namespaces = [("repository", "repos/" + repository + "/actions/secrets")]
        if owner_type == "Organization":
            namespaces.append(("organization", "orgs/" + repository.split("/", 1)[0] + "/actions/secrets"))
        scopes = [{"scope": label, "secrets": rows(scope, "secrets")} for label, scope in namespaces]
        placement = secret_placement(names, scopes)
        if placement["cause"]:
            refuse(placement["cause"], placement["outside"] or placement["unreadable"])
    except ValueError:
        refuse("read")

