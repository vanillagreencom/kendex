"""Environment judgments shared by refresh adoption and the standard report."""

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
        return {"present": "no", "cause": "missing", "value": "absent"}
    policy = selected[0].get("deployment_branch_policy")
    if not isinstance(policy, dict) or policy.get("custom_branch_policies") is not True or policy.get("protected_branches") is not False:
        kind = "unrestricted" if policy is None else "protected-branches" if isinstance(policy, dict) and policy.get("protected_branches") is True else "malformed"
        return {"present": "yes", "cause": "branch-policy", "value": kind}
    if policies is None:
        return {"present": "yes", "cause": "pending", "value": "custom"}
    if not isinstance(policies, list) or not all(isinstance(row, dict) and isinstance(row.get("name"), str) and isinstance(row.get("type", "branch"), str) for row in policies):
        raise ValueError("branch-policies")
    observed = "custom:" + ",".join(row.get("type", "branch") + ":" + row["name"] for row in policies)
    if len(policies) != 1 or policies[0].get("name") != branch or policies[0].get("type", "branch") != "branch":
        return {"present": "yes", "cause": "branch-policy", "value": observed}
    return {"present": "yes", "cause": "", "value": observed}


def environment_secrets(names, secrets):
    if not isinstance(secrets, list) or not all(isinstance(row, dict) and isinstance(row.get("name"), str) for row in secrets):
        raise ValueError("secrets")
    held = {row["name"].upper() for row in secrets}
    if not set(names).issubset(held):
        cause = "secrets"
    else:
        cause = ""
    return {"cause": cause, "held": ";".join(name for name in names if name in held),
            "missing": ";".join(name for name in names if name not in held)}


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
        judgment = environment_secrets(config.get("required_names", config["names"]), secrets)
        if judgment["cause"]:
            refuse(judgment["cause"])
    except ValueError:
        refuse("read")


if __name__ == "__main__":
    # validate-standard supplies API data through stdin and consumes JSON.
    try:
        data = json.load(sys.stdin)
        if sys.argv[1] == "policy":
            result = environment_policy(sys.argv[2], sys.argv[3], data["environments"], data.get("policies"))
        elif sys.argv[1] == "secrets":
            result = environment_secrets(sys.argv[2].split(), data)
        else:
            raise ValueError("operation")
        print(json.dumps(result))
    except (ValueError, KeyError, TypeError) as error:
        print("review-gate-error=environment-data value=" + str(error), file=sys.stderr)
        raise SystemExit(2) from error
