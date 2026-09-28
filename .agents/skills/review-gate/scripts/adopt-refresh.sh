#!/usr/bin/env bash
# Copies the refresh workflow and records exact template copies for kendex
# verification. Existing refresh copies are writable only while their bytes
# still match the hash recorded by their previous adoption. The writer is
# validated by validate-workflow.sh, which also decides whether its absence
# is allowed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = --help ] && [ "$#" -eq 1 ]; then
  printf '%s\n' 'Usage: adopt-refresh.sh [--templates-dir DIR]' 'Reads the provisioned kendex environment, adopts the refresh workflow, and records byte-identical writer and refresh copies in .kendex-generated.json.' 'A repository with REVIEW_GATE_WRITER=optional and REVIEW_GATE_MODE=off may have no writer; only the refresh copy is then recorded.'
  exit 0
fi
templates="$SCRIPT_DIR/../templates"
if [ "$#" -eq 2 ] && [ "$1" = --templates-dir ]; then
  templates="$2"
  shift 2
fi
templates="$(cd -- "$templates" && pwd)"
[ "$#" -eq 0 ] || { printf 'refresh-error=arguments value=%s\n' "$#" >&2; exit 2; }
repository="$(gh api 'repos/{owner}/{repo}' --jq .full_name)" || exit 1
if [ "$repository" = vanillagreencom/kendex ]; then
  printf 'refresh-adoption=excluded repository=%s\n' "$repository"
  exit 0
fi
"$SCRIPT_DIR/validate-standard.sh" --environment-only
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
"$SCRIPT_DIR/validate-workflow.sh" --adopt --templates-dir "$templates" --adopted-path-file "$TMP/writer-path"
# Python supplies the same SHA-256 on every supported host. Template paths
# remain repository-relative so verification resolves them against its plan.
python3 - "$templates" "$TMP/writer-path" <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import sys

root = Path(subprocess.check_output(["git", "rev-parse", "--show-toplevel"], text=True).strip())
templates = Path(sys.argv[1]).resolve()
inventory = root / ".kendex-generated.json"
entries = json.loads(inventory.read_text())
if not isinstance(entries, list):
    raise SystemExit("refresh-error=inventory value=not-array")

def digest(path):
    return "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()

def path_of(entry):
    return entry if isinstance(entry, str) else entry["path"]

refresh = root / ".github/workflows/kendex-refresh.yml"
template = templates / refresh.name
if refresh.is_symlink():
    raise SystemExit("refresh-error=workflow-symlink value=" + str(refresh))
if refresh.exists() and refresh.read_bytes() != template.read_bytes():
    # Refresh has already recorded the new template hash. Only the committed
    # adoption record can prove that the old workflow copy remains unedited.
    previous = subprocess.run(["git", "show", "HEAD:.kendex-generated.json"], cwd=root, capture_output=True, text=True)
    if previous.returncode != 0:
        raise SystemExit("refresh-error=prior-inventory value=HEAD:.kendex-generated.json")
    recorded = next((e for e in json.loads(previous.stdout) if isinstance(e, dict) and e["path"] == refresh.relative_to(root).as_posix()), None)
    if recorded is None or recorded["template"] != template.relative_to(root).as_posix() or recorded["templateHash"] != digest(refresh):
        raise SystemExit("refresh-error=workflow-edited value=" + str(refresh))
refresh.parent.mkdir(parents=True, exist_ok=True)
refresh.write_bytes(template.read_bytes())
# An empty selection is a writer absent by setting; its record is retired.
selected = Path(sys.argv[2]).read_text()
writer = root / selected if selected else None
for copied, shipped in ((writer, templates / "review-gate-writer.yml"), (refresh, template)):
    relative = None if copied is None else copied.relative_to(root).as_posix()
    owner = shipped.relative_to(root).as_posix()
    entries = [e for e in entries if not isinstance(e, dict) or e["template"] != owner]
    if copied is not None and copied.is_file() and not copied.is_symlink() and copied.read_bytes() == shipped.read_bytes():
        entries.append({"path": relative, "template": owner, "templateHash": digest(shipped)})
inventory.write_text("[\n" + ",\n".join("  " + json.dumps(e, ensure_ascii=False, separators=(",", ":")) for e in sorted(entries, key=path_of)) + "\n]\n")
PY
