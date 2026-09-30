#!/usr/bin/env bash
# Copies the refresh workflow and records exact template copies for kendex
# verification. Refresh copies that equal no shipped template are overwritten
# with one refresh-warning=workflow-edited value=PATH line. The optional
# --workflow-edit-report file holds a Markdown section for refresh-consumer.sh,
# naming PATH:LINE and both first-divergent lines; it is empty without an edit.
# validate-workflow.sh owns writer adoption and whether its absence is allowed.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ "${1:-}" = --help ] && [ "$#" -eq 1 ]; then
  printf '%s\n' 'Usage: adopt-refresh.sh [--templates-dir DIR] [--workflow-edit-report FILE]' 'Reads the provisioned kendex environment, adopts the refresh workflow, and records byte-identical writer and refresh copies in .kendex-generated.json.' 'Refresh hand edits are overwritten with a warning; FILE receives the workflow-edit section for the pull request body.' 'A repository with REVIEW_GATE_WRITER=optional and REVIEW_GATE_MODE=off may have no writer; only the refresh copy is then recorded.'
  exit 0
fi
templates="$SCRIPT_DIR/../templates"
edit_report=""
while [ "$#" -gt 0 ]; do
  case "$1" in
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
TMP="$(mktemp -d)"
trap 'rm -rf -- "${TMP:?}"' EXIT
"$SCRIPT_DIR/validate-workflow.sh" --adopt --templates-dir "$templates" --adopted-path-file "$TMP/writer-path"
# Python supplies the same SHA-256 on every supported host. Template paths
# remain repository-relative so verification resolves them against its plan.
python3 - "$templates" "$TMP/writer-path" "$SCRIPT_DIR/../templates" "$edit_report" <<'PY'
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
template_bytes = template.read_bytes()
report = ""
if refresh.is_symlink():
    raise SystemExit("refresh-error=workflow-symlink value=" + str(refresh))
if refresh.exists():
    copied_bytes = refresh.read_bytes()
    shipped = copied_bytes == template_bytes
    # The preserved checkout keeps the consumer's pre-refresh vendored
    # template and its history. Records are inventory, not proof of an edit.
    for directory in (Path(sys.argv[3]).resolve(), templates):
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
refresh.parent.mkdir(parents=True, exist_ok=True)
refresh.write_bytes(template_bytes)
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
if sys.argv[4]:
    Path(sys.argv[4]).write_text(report)
PY
