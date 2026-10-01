#!/usr/bin/env bash
# Copies the refresh workflow and records exact template copies for kendex
# verification. Refresh copies that equal no shipped template are overwritten
# with one refresh-warning=workflow-edited value=PATH line. The optional
# --workflow-edit-report file holds a Markdown section for refresh-consumer.sh,
# naming PATH:LINE and both first-divergent lines; it is empty without an edit.
# The committed adoption hash proves ownership of a retired writer copy.
# Retired adoption records emit refresh-warning=legacy-writer value=TEMPLATE.
# Only the trusted removal route passes --retire-writer.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = --help ] && [ "$#" -eq 1 ]; then
  printf '%s\n' 'Usage: adopt-refresh.sh [--templates-dir DIR] [--workflow-edit-report FILE] [--retire-writer]' 'Reads the provisioned kendex environment and adopts the refresh workflow. --retire-writer removes an unedited gate workflow and its inventory entry on the trusted removal route.' 'Refresh hand edits are overwritten with a warning; FILE receives the workflow-edit section for the pull request body.'
  exit 0
fi
templates="$SCRIPT_DIR/../templates"
edit_report=""
adoption=refresh
while [ "$#" -gt 0 ]; do
  case "$1" in
    --retire-writer) adoption=retire-writer; shift ;;
    --templates-dir|--workflow-edit-report)
      [ "$#" -ge 2 ] && [ -n "$2" ] || { printf 'refresh-error=arguments value=%s\n' "$1" >&2; exit 2; }
      if [ "$1" = --templates-dir ]; then templates="$2"; else edit_report="$2"; fi
      shift 2 ;;
    *) printf 'refresh-error=arguments value=%s\n' "$1" >&2; exit 2 ;;
  esac
done
templates="$(cd -- "$templates" && pwd)"
[ -z "$edit_report" ] || : >"$edit_report"
repository="$(gh api 'repos/{owner}/{repo}' --jq .full_name)" || exit 1
if [ "$repository" = vanillagreencom/kendex ]; then
  printf 'refresh-adoption=excluded repository=%s\n' "$repository"
  exit 0
fi
# The environment check judges the names the refresh workflow installed here
# reads, its job's environment and the secrets its steps name, whatever the
# consumer's settings say: these process values outrank every settings file. An empty extraction reaches the validator empty, and
# it refuses with standard-setting-missing.
refresh_template="$templates/kendex-refresh.yml"
template_environment="$(sed -n 's/^    environment: \(.*\)$/\1/p' "$refresh_template")" || exit 2
template_secrets="$(sed -n 's/.*\${{ secrets\.\([A-Za-z0-9_]*\) }}.*/\1/p' "$refresh_template" | LC_ALL=C sort -u | paste -sd ';' -)" || exit 2
REVIEW_GATE_STANDARD_ENVIRONMENT="$template_environment" REVIEW_GATE_STANDARD_SECRETS="$template_secrets" \
  "$SCRIPT_DIR/validate-standard.sh" --environment-only
# Python supplies the same SHA-256 on every supported host. Template paths
# remain repository-relative so verification resolves them against its plan.
python3 - "$templates" "$SCRIPT_DIR/../templates" "$edit_report" "$adoption" <<'PY'
import hashlib
from itertools import zip_longest
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
retired_owner = (templates / "review-gate-writer.yml").relative_to(root).as_posix()
retired = [e for e in entries if isinstance(e, dict) and e["template"] == retired_owner]
retiring = retired if sys.argv[4] == "retire-writer" else []
# Core refresh preserves adopted records when their template disappears.
# A renamed copy keeps that owner, so its record still identifies the writer.
prior = {}
if retired:
    print("refresh-warning=legacy-writer value=" + retired_owner, file=sys.stderr)
    previous = subprocess.run(["git", "show", "HEAD:.kendex-generated.json"], cwd=root, capture_output=True, text=True)
    if previous.returncode != 0:
        raise SystemExit("refresh-error=prior-inventory value=HEAD:.kendex-generated.json")
    prior_entries = json.loads(previous.stdout)
    if not isinstance(prior_entries, list):
        raise SystemExit("refresh-error=prior-inventory value=not-array")
    prior = {path_of(e): e for e in prior_entries}
for record in retired:
    copied = root / record["path"]
    if copied.is_symlink():
        raise SystemExit("refresh-error=workflow-symlink value=" + str(copied))
    if copied.exists():
        recorded = prior.get(record["path"])
        if not copied.is_file() or not isinstance(recorded, dict) or recorded["template"] != retired_owner or recorded["templateHash"] != digest(copied):
            raise SystemExit("refresh-error=workflow-edited value=" + str(copied))
# An unrecorded default copy has no ownership proof and must stay untouched.
unrecorded = root / ".github/workflows/review-gate-writer.yml"
if (unrecorded.exists() or unrecorded.is_symlink()) and not any(e["path"] == unrecorded.relative_to(root).as_posix() for e in retired):
    raise SystemExit("refresh-error=workflow-unrecorded value=" + str(unrecorded))
template_bytes = template.read_bytes()
report = ""
if refresh.is_symlink():
    raise SystemExit("refresh-error=workflow-symlink value=" + str(refresh))
if refresh.exists():
    copied_bytes = refresh.read_bytes()
    shipped = copied_bytes == template_bytes
    # The preserved checkout keeps the consumer's pre-refresh vendored
    # template and its history. Records are inventory, not proof of an edit.
    for directory in (Path(sys.argv[2]).resolve(), templates):
        if shipped:
            break
        shipped_template = directory / refresh.name
        if copied_bytes == shipped_template.read_bytes():
            shipped = True
            break
        history_root = Path(subprocess.check_output(["git", "-C", str(directory), "rev-parse", "--show-toplevel"], text=True).strip())
        history_path = shipped_template.relative_to(history_root).as_posix()
        commits = subprocess.check_output(["git", "log", "--format=%H", "--", history_path], cwd=history_root, text=True).splitlines()
        for commit in commits:
            entry = subprocess.check_output(["git", "ls-tree", commit, "--", history_path], cwd=history_root, text=True)
            if not entry:  # A commit that deletes the template ships no bytes.
                continue
            blob = entry.split()[2]
            if copied_bytes == subprocess.check_output(["git", "cat-file", "blob", blob], cwd=history_root):
                shipped = True
                break
    if not shipped:
        relative = refresh.relative_to(root).as_posix()
        for line, (copied, expected) in enumerate(zip_longest(copied_bytes.splitlines(keepends=True), template_bytes.splitlines(keepends=True)), 1):
            if copied != expected:
                break
        else:
            raise AssertionError("different workflow bytes must have a divergent line")
        # JSON quoting keeps workflow content on one line inside the fence.
        copied_line = json.dumps(None if copied is None else copied.decode("utf-8", errors="backslashreplace"))
        expected_line = json.dumps(None if expected is None else expected.decode("utf-8", errors="backslashreplace"))
        report = f"## Workflow edits\n\nReplaced a hand-edited refresh workflow with the shipped template. First divergence: `{relative}:{line}`.\n\n```text\ncopy: {copied_line}\ntemplate: {expected_line}\n```\n"
        print("refresh-warning=workflow-edited value=" + relative, file=sys.stderr)
# Complete the ownership checks before removing or writing any consumer file.
for record in retiring:
    (root / record["path"]).unlink(missing_ok=True)
refresh.parent.mkdir(parents=True, exist_ok=True)
refresh.write_bytes(template_bytes)
owner = template.relative_to(root).as_posix()
entries = [e for e in entries if e not in retiring and (not isinstance(e, dict) or e["template"] != owner)]
entries.append({"path": refresh.relative_to(root).as_posix(), "template": owner, "templateHash": digest(template)})
inventory.write_text("[\n" + ",\n".join("  " + json.dumps(e, ensure_ascii=False, separators=(",", ":")) for e in sorted(entries, key=path_of)) + "\n]\n")
if sys.argv[3]:
    Path(sys.argv[3]).write_text(report)
PY
