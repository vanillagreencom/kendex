#!/usr/bin/env bash
# Copies the shipped refresh caller, preserving declared consumer inputs, and
# drops any earlier inventory record for the workflow. Adoption records are
# inventory, not permission to replace an edit.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = --help ] && [ "$#" -eq 1 ]; then
  printf '%s\n' 'Usage: adopt-refresh.sh [--templates-dir DIR]' 'Reads the declared consumer environment and adopts the refresh workflow from DIR/kendex-refresh.yml, by default the caller beside this script.' 'Environment, secret-name inputs and matching secret mappings survive adoption. All other bytes must match kendex default-branch template history.' 'Adoption removes any earlier inventory record for the workflow.'
  exit 0
fi
templates="$SCRIPT_DIR"
while [ "$#" -gt 0 ]; do
  case "$1" in
    --templates-dir)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { printf 'refresh-error=arguments value=%s\n' "$1" >&2; exit 2; }
      templates="$2"
      shift 2 ;;
    *) printf 'refresh-error=arguments value=%s\n' "$1" >&2; exit 2 ;;
  esac
done
templates="$(cd -- "$templates" && pwd)"
repository="$(python3 - "$SCRIPT_DIR" <<'REPOSITORY'
from pathlib import Path
import subprocess
import sys

sys.path.insert(0, str(Path(sys.argv[1]).parent / "skills/review-gate/scripts/lib"))
from environment import gh_api
try:
    print(gh_api("repos/{owner}/{repo}", "--jq", ".full_name"), end="")
except subprocess.CalledProcessError as error:
    print(error.stderr, file=sys.stderr, end="")
    raise SystemExit(1) from error
REPOSITORY
)" || exit 1
if [ "$repository" = vanillagreencom/kendex ]; then
  printf 'refresh-adoption=excluded repository=%s\n' "$repository"
  exit 0
fi
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
# The public catalog is shipment evidence. Consumer history and supplied
# metadata cannot license replacement. Fetch data only; execute no catalog code.
python3 - "$templates" "$TMP" "$SCRIPT_DIR" "$repository" <<'PREFLIGHT'
import os
from pathlib import Path
import subprocess
import sys

root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
templates = Path(sys.argv[1])
scratch = Path(sys.argv[2])
sys.path.insert(0, str(Path(sys.argv[3]) / "lib"))
from caller import InvalidCaller, configuration, configured, normalized
sys.path.insert(0, str(Path(sys.argv[3]).parent / "skills/review-gate/scripts/lib"))
from environment import validate_environment
refresh = root / ".github/workflows/kendex-refresh.yml"
if refresh.is_symlink():
    raise SystemExit("refresh-error=workflow-symlink value=" + str(refresh))
try:
    copied = refresh.read_bytes() if refresh.exists() else None
    replacement = (templates / refresh.name).read_bytes()
except OSError as error:
    raise SystemExit("refresh-error=read value=" + str(error.filename)) from error

try:
    template_config = configuration(replacement)
except (InvalidCaller, UnicodeError) as error:
    print("refresh-error=caller-secrets value=" + str(templates / refresh.name) + " cause=" + str(error), file=sys.stderr)
    raise SystemExit(2) from error
try:
    copied_config = configuration(copied) if copied is not None else None
except (InvalidCaller, UnicodeError):
    # Historical shipped callers can lack mappings. Exact shipment evidence
    # still authorizes their replacement, never an unshipped malformed edit.
    copied_config = None
selected_config = copied_config or template_config
if selected_config is not None and selected_config["legacy_fields"]:
    print("refresh-warning=legacy-caller-fields value=" + ",".join(selected_config["legacy_fields"]) +
          " replacement=KENDEX_APP_ID,KENDEX_APP_PRIVATE_KEY,FLEET_GH_APP_ID,FLEET_GH_APP_PRIVATE_KEY")
if selected_config is None:
    # Historical inline templates still declare their own environment.
    import re
    text = replacement.decode()
    environments = re.findall(r"^    environment: (.+)$", text, re.M)
    names = sorted(set(re.findall(r"\$\{\{ secrets\.([A-Za-z0-9_]+) \}\}", text)))
    if len(environments) != 1 or not names:
        raise SystemExit("refresh-error=caller-secrets value=" + str(templates / refresh.name) + " cause=inline")
    selected_config = {"environment": environments[0], "names": names}
validate_environment(sys.argv[4], selected_config)

history = scratch / "history"
# Git's documented transport supplies full default-branch ancestry. Strip
# consumer Git redirection, configuration and credentials for this public read.
environment = {key: value for key, value in os.environ.items()
               if not key.startswith("GIT_") and key not in ("GH_TOKEN", "GITHUB_TOKEN")}
environment.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0")

def git(*arguments):
    try:
        return subprocess.check_output(["git", "-C", str(history), *arguments], env=environment, stderr=subprocess.PIPE)
    except subprocess.CalledProcessError as error:
        print("refresh-error=read value=workflow-history", file=sys.stderr)
        print(error.stderr.decode("utf-8", errors="replace"), file=sys.stderr)
        raise SystemExit(2) from error

history.mkdir()
git("init", "--bare", "--quiet")
git("fetch", "--no-tags", "https://github.com/vanillagreencom/kendex.git", "HEAD")
# Consumer copies can hold bytes either path shipped: the template kendex
# once rendered into consumers, and the shared workflow's caller.
paths = ("skills/review-gate/templates/kendex-refresh.yml", "refresh/kendex-refresh.yml")
commits = git("log", "--full-history", "--format=%H", "FETCH_HEAD", "--", *paths).decode().splitlines()
shipped_copy = copied is None
shipped_template = False
for commit in commits:
    for path in paths:
        entry = git("ls-tree", commit, "--", path).split()
        if not entry:  # Deleting the template ships no bytes.
            continue
        candidate = git("cat-file", "blob", entry[2].decode())
        try:
            candidate_shape = normalized(candidate)
        except (InvalidCaller, UnicodeError):
            candidate_shape = candidate
        copied_shape = normalized(copied) if copied_config else copied
        shipped_copy = shipped_copy or copied_shape == candidate_shape
        shipped_template = shipped_template or normalized(replacement) == candidate_shape
if not shipped_template:
    raise SystemExit("refresh-error=template-edited value=" + str(templates / refresh.name))
if not shipped_copy:
    raise SystemExit("refresh-error=workflow-edited value=" + str(refresh))
(scratch / "source-template").write_bytes(replacement)
(scratch / "template").write_bytes(configured(replacement, copied_config))
if copied is not None:
    (scratch / "workflow").write_bytes(copied)
PREFLIGHT
# Re-read inventory before replacement. Recheck workflow and template bytes
# before replacement; another writer supplies no overwrite consent.
python3 - "$templates" "$TMP" <<'PY'
import json
from pathlib import Path
import subprocess
import sys

root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip()).resolve()
templates = Path(sys.argv[1]).resolve()
scratch = Path(sys.argv[2])
inventory = root / ".kendex-generated.json"
entries = json.loads(inventory.read_text())
if not isinstance(entries, list):
    raise SystemExit("refresh-error=inventory value=not-array")

def path_of(entry):
    return entry if isinstance(entry, str) else entry["path"]

refresh = root / ".github/workflows/kendex-refresh.yml"
template = templates / refresh.name
template_bytes = (scratch / "template").read_bytes()
observed = (scratch / "workflow").read_bytes() if (scratch / "workflow").exists() else None
if refresh.is_symlink():
    raise SystemExit("refresh-error=workflow-symlink value=" + str(refresh))
if (refresh.read_bytes() if refresh.exists() else None) != observed:
    raise SystemExit("refresh-error=workflow-changed value=" + str(refresh))
if template.read_bytes() != (scratch / "source-template").read_bytes():
    raise SystemExit("refresh-error=template-changed value=" + str(template))
refresh.parent.mkdir(parents=True, exist_ok=True)
refresh.write_bytes(template_bytes)
entries = [e for e in entries if not isinstance(e, dict) or e["path"] != refresh.relative_to(root).as_posix()]
inventory.write_text("[\n" + ",\n".join("  " + json.dumps(e, ensure_ascii=False, separators=(",", ":")) for e in sorted(entries, key=path_of)) + "\n]\n")
PY
