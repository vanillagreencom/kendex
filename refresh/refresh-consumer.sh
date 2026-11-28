#!/usr/bin/env bash
# Runs with the consumer's default-branch checkout as the working directory,
# from the kendex release tree the shared workflow checked out. It rebuilds the rolling branch from the
# checkout and never executes the remote rolling branch. After GitHub shows the
# published head, it merges directly where the base has no rules or protection,
# or requests auto-merge. review-gate references/adoption.md, Publication, defines the arm outcomes. A render this
# run committed first goes to the default branch itself where the landing
# token, KENDEX_LAND_TOKEN, is set, the run is not held, the classifier
# measures the commit as class render, every path the commit removes or
# renames against the base the run fetched lies at or below a path the
# commit's root .kendex-lock.json still emits, every project takes its
# packages from the default catalog at main alone, and that branch's merge
# queue holds no entry: the run pushes its one commit with that token, and where GitHub's
# rulesets let the push through, no pull request, merge group or approval
# follows. Where every other condition holds and the queue holds an entry,
# the run defers the render to a later run and publishes no pull request.
# Output records: refresh-state=current pr=none class=none, or
# refresh-state=landed pr=none class=render head=REVISION, or
# refresh-state=pushed|merged pr=NUMBER class=CLASS, or
# refresh-state=unchanged pr=NUMBER|none class=CLASS head=REVISION published=false, or
# refresh-state=unarmed pr=NUMBER pushed=REVISION head=REVISION, or
# refresh-state=held pr=NUMBER class=CLASS head=REVISION, or
# refresh-state=deferred reason=queued|merged|closed|branch-gone|base-moved.
# A held run's verify failed only on declarations its projects' manifests
# withhold, each project's printing refresh-verify=held project=ENTRY: it
# publishes the head as a draft pull request whose body names each finding
# and its manifest line, arms nothing and lands nothing. A
# render this run committed that it did not push, or whose push GitHub
# refused, and a held run's retained head, where the caller set either
# landing name, also print one landing line ahead of the pull request
# route's record, or, for a queue that holds an entry, ahead of
# refresh-state=deferred reason=queued:
# refresh-land=refused value=STATUS (GitHub refused the push),
# refresh-land=unavailable value=token|lock-read|sources-read|queue-read (no
# landing token reached the run, or the root lock, the project sources or
# the merge queue could not be read), or
# refresh-land=skipped value=verify|class|path-removed|sources-uncovered|queued
# (the run is held, the class is not render, the render removes or renames
# a path no emitted path of the root lock covers, a project takes packages
# from another catalog or revision, or the merge queue holds an entry). An
# unread source answer also writes refresh-sources=unread value=PROJECT to
# stderr, and an unread lock the md-refs lock reader's refresh-lock line.
# A consumer whose render did not run also gets
# refresh-render=skipped package=bot-instructions cause=absent|unconfigured.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# Load from the trusted runner before refresh replaces its installed files.
source "$SCRIPT_DIR/../skills/review-gate/scripts/lib/arm-published-head.sh"
source "$SCRIPT_DIR/lib/landing.sh"
# The landing app's token bypasses the review rulesets and serves the one
# landing push alone, so no child this run starts inherits it.
land_token="${KENDEX_LAND_TOKEN:-}"
unset KENDEX_LAND_TOKEN
# true where the caller set either landing name, so a token that did not
# arrive is reported; the shared workflow sets it.
land_configured="${KENDEX_LAND_CONFIGURED:-false}"
templates="$SCRIPT_DIR"
ROOT="$(git rev-parse --show-toplevel)"
ROOT="$(cd -- "$ROOT" && pwd -P)"
cd -- "$ROOT"
: "${GH_REPO:?GH_REPO names the running repository}"
: "${GH_TOKEN:?GH_TOKEN must be the repository-scoped app installation token}"
: "${REFRESH_APP_SLUG:?REFRESH_APP_SLUG names that app}"
# The shared workflow selects main only after it verifies the released engine.
: "${KENDEX_CATALOG_REV:?KENDEX_CATALOG_REV names the default catalog revision}"
export KENDEX_CATALOG_REV
if ! clean="$(git status --porcelain)"; then
  printf 'refresh-error=read value=clean\n' >&2
  exit 1
fi
[ -z "$clean" ] || { printf 'refresh-error=dirty value=%s\n' "$ROOT" >&2; exit 1; }
if ! default="$(gh api "repos/$GH_REPO" --jq .default_branch)"; then
  printf 'refresh-error=read value=default\n' >&2
  exit 1
fi
[ -n "$default" ] && [ "$default" != null ] || { printf 'refresh-error=default-branch value=missing\n' >&2; exit 1; }
# Private consumer repositories need the app credential for every git read.
gh auth setup-git
git fetch --no-tags origin "$default"
if ! base="$(git rev-parse FETCH_HEAD)"; then
  printf 'refresh-error=read value=expected\n' >&2
  exit 1
fi
prs="$(gh api --paginate "repos/$GH_REPO/pulls?state=open&head=${GH_REPO%%/*}:kendex/refresh&per_page=100" --jq '.[].number')"
count=0
pr=""
while IFS= read -r number; do
  [ -n "$number" ] || continue
  count=$((count + 1)); pr="$number"
done <<<"$prs"
[ "$count" -le 1 ] || { printf 'refresh-error=multiple-pulls value=%s\n' "$count" >&2; exit 1; }
remote="$(git ls-remote --heads origin refs/heads/kendex/refresh)"
old="${remote%%[[:space:]]*}"
if [ -n "$old" ]; then
  git fetch --no-tags origin refs/heads/kendex/refresh
fi
# GitHub owns the queue and may merge the rolling pull request and delete its
# branch at any moment. The read at run start skips a run whose pull request
# the queue already holds; only a read after GitHub refuses a write, or the
# refusal itself, can establish the lifecycle at that write. Sets reason to
# merged, closed, queued, armed, branch-gone or active for the pull request
# in pr; a failed or malformed read exits.
refresh_lifecycle() {
  local has_pr=false push_state
  if [ -n "$pr" ]; then has_pr=true; fi
  if ! push_state="$(gh api graphql -f owner="${GH_REPO%%/*}" -f repo="${GH_REPO#*/}" \
    -F number="${pr:-0}" -F hasPR="$has_pr" \
    -f query='query($owner: String!, $repo: String!, $number: Int!, $hasPR: Boolean!) { repository(owner: $owner, name: $repo) { ref(qualifiedName: "refs/heads/kendex/refresh") { target { oid } } pullRequest(number: $number) @include(if: $hasPR) { state isInMergeQueue autoMergeRequest { enabledAt } } } }')"; then
    printf 'refresh-error=push-state value=query\n' >&2
    exit 1
  fi
  if ! reason="$(jq -er -s --argjson has_pr "$has_pr" --arg old "$old" '
    if length != 1 then error("expected one response") else .[0] end |
    if (.errors // [] | length) != 0 then error("GraphQL errors") else .data.repository end |
    if type != "object" or (has("ref") | not) or
      (.ref != null and (.ref.target.oid | type != "string" or length == 0)) or
      ($has_pr and (.pullRequest | type != "object" or
        (has("state") and has("isInMergeQueue") and has("autoMergeRequest") | not) or
        (.state != "OPEN" and .state != "MERGED" and .state != "CLOSED") or
        (.isInMergeQueue | type != "boolean") or
        (.autoMergeRequest != null and (.autoMergeRequest.enabledAt | type != "string" or length == 0))))
    then error("incomplete refresh state") else . end |
    if .pullRequest.state == "MERGED" then "merged"
    elif .pullRequest.state == "CLOSED" then "closed"
    elif .pullRequest.isInMergeQueue == true then "queued"
    elif .pullRequest.autoMergeRequest != null then "armed"
    elif .ref == null and $old != "" then "branch-gone"
    else "active" end
  ' <<<"$push_state")"; then
    printf 'refresh-error=push-state value=output\n' >&2
    exit 1
  fi
}
# Closes the open rolling pull request a newer state supersedes. GitHub can
# merge or close it after the read at run start, and gh refuses to close a
# merged pull request, so its state is read again first.
refresh_close_superseded() {
  [ -n "$pr" ] || return 0
  refresh_lifecycle
  case "$reason" in
    merged | closed) return 0 ;;
  esac
  gh pr close "$pr" --repo "$GH_REPO"
}
# The queue can already own the pull request. An arm alone can stay in place
# until this run proves it has a replacement head to publish.
if [ -n "$pr" ]; then
  refresh_lifecycle
  case "$reason" in
    queued | merged | closed | branch-gone)
      printf 'refresh-state=deferred reason=%s\n' "$reason"
      exit 0 ;;
  esac
fi
git checkout -B kendex/refresh "$base"
export KENDEX_UI=plain
TMP="$(mktemp -d)" || { printf 'refresh-error=read value=scratch\n' >&2; exit 1; }
trap 'rm -rf -- "${TMP:?}"' EXIT
# Target selection uses released readers before any consumer package changes.
# The root declaration alone selects projects; installed consumer code has no say.
project_env=()
if [ "${KENDEX_REFRESH_PROJECTS+set}" = set ]; then project_env+=("KENDEX_REFRESH_PROJECTS=$KENDEX_REFRESH_PROJECTS"); fi
if [ "${KENDEX_ENV_FILE+set}" = set ]; then project_env+=("KENDEX_ENV_FILE=$KENDEX_ENV_FILE"); fi
if [ "${REVIEW_GATE_SETTINGS_FILE+set}" = set ]; then project_env+=("REVIEW_GATE_SETTINGS_FILE=$REVIEW_GATE_SETTINGS_FILE"); fi
if ! env -i PATH="$PATH" HOME="$HOME" ${project_env[@]+"${project_env[@]}"} bash -s -- "$SCRIPT_DIR" "$ROOT" >"$TMP/project-entries" <<'PROJECT_SETTINGS'
set -euo pipefail
source "$1/../skills/review-gate/scripts/lib/settings.sh"
source "$1/../skills/orch/scripts/lib/kendex-env.sh"
KENDEX_ENV_FILE="$(rg_setting KENDEX_ENV_FILE "" "")"
kendex_private_env_file private_file "$2"
projects="$(rg_setting KENDEX_REFRESH_PROJECTS "" "$private_file")"
rg_pack "$projects" ';'
PROJECT_SETTINGS
then
  printf 'refresh-error=settings-extraction value=KENDEX_REFRESH_PROJECTS\n' >&2
  exit 1
fi
# Require a manifest here so the CLI cannot walk to a parent project when a
# consumer removes a declared nested manifest. This is local refresh policy.
python3 - "$ROOT" "$TMP/project-entries" >"$TMP/projects" <<'PROJECT_PATHS'
from pathlib import Path
import stat
import sys
root = Path(sys.argv[1])
def refuse(key, entry, operation):
    print(f'refresh-error={key} value={entry}', file=sys.stderr)
    print(operation, file=sys.stderr)
    sys.exit(1)
def inside(path):
    return path == root or root in path.parents
seen = {root}
targets = [(root, '.')]
for entry in Path(sys.argv[2]).read_text().splitlines():
    declared = Path(entry)
    if declared.is_absolute():
        refuse('project-path', entry, 'Project paths must be relative to the checkout.')
    try:
        directory = root / declared
        try:
            directory_stat = directory.stat()
        except FileNotFoundError:
            if directory.is_symlink():
                raise
            refuse('project-missing', entry, 'The declared project directory does not exist.')
        if not stat.S_ISDIR(directory_stat.st_mode):
            refuse('project-missing', entry, 'The declared project directory does not exist.')
        directory = directory.resolve(strict=True)
        if not inside(directory):
            refuse('project-outside', entry, 'The project directory resolves outside the checkout.')
        manifest = directory / 'kendex.toml'
        try:
            manifest_stat = manifest.stat()
        except FileNotFoundError:
            if manifest.is_symlink():
                raise
            refuse('project-manifest', entry, 'The declared project needs a kendex.toml file.')
        if not stat.S_ISREG(manifest_stat.st_mode):
            refuse('project-manifest', entry, 'The declared project needs a kendex.toml file.')
        if not inside(manifest.resolve(strict=True)):
            refuse('project-outside', entry, 'The project manifest resolves outside the checkout.')
        with manifest.open('rb'):
            pass
    except (OSError, RuntimeError) as error:
        refuse('read', entry, f'Could not resolve or read the project: {error}')
    if directory not in seen:
        seen.add(directory)
        targets.append((directory, entry))
for directory, entry in targets:
    sys.stdout.buffer.write(str(directory).encode() + b'\0' + entry.encode() + b'\0')
PROJECT_PATHS
projects=()
project_entries=()
while IFS= read -r -d '' directory && IFS= read -r -d '' entry; do
  projects+=("$directory")
  project_entries+=("$entry")
done <"$TMP/projects"
catalog_report=""
# The findings of a verify that failed only on the projects' own
# declarations, and that verify's exit status.
verify_report=""
held_status=""
retired_items=""
setting_notes=()
refresh_project() {
local KENDEX_CATALOG_REV="$KENDEX_CATALOG_REV"
local catalog_note=""
cd -- "$1"
if [ "${#projects[@]}" -gt 1 ]; then printf 'refresh-project=%s\n' "$2"; fi
# This refresh-run edit leaves engine.md rule 15's reader refusal intact.
# It serves only a bump that adds or changes what no existing table means,
# such as KEN-3652's top-level key. A changed table meaning needs its own route.
schema_probe="$(kendex apply --plan --scope project 2>&1 || true)"
schema_pattern='Error: ([^[:cntrl:]]+): this manifest could not be read — it is a schema ([0-9]+) manifest, and this kendex writes schema ([0-9]+)'
if [[ "$schema_probe" =~ $schema_pattern ]]; then
  python3 - "${BASH_REMATCH[2]}" "${BASH_REMATCH[3]}" "${BASH_REMATCH[1]}" <<'SCHEMA_EDIT'
from pathlib import Path
import sys

previous, current = map(int, sys.argv[1:3])
path = Path(sys.argv[3]).resolve()
# The engine owns catalog routing; only this project's install manifest can change.
if path.parent == Path.cwd() and path.name in {"kendex.toml", "kendex-local.toml"} and previous + 1 == current:
    lines = path.read_bytes().splitlines(keepends=True)
    candidates = []
    for index, line in enumerate(lines):
        content = line.rstrip(b"\r\n")
        if content.lstrip().startswith(b"["):
            break
        if content == f"schema = {previous}".encode():
            candidates.append(index)
    if len(candidates) == 1:
        index = candidates[0]
        lines[index] = lines[index].replace(f"schema = {previous}".encode(), f"schema = {current}".encode(), 1)
        path.write_bytes(b"".join(lines))
SCHEMA_EDIT
fi
refresh_status=0
# --prune takes what the catalog retired; a plain refresh keeps it. kendex
# 1.11.0 adds the flag, and the release this runs under can predate
# it, so it is passed where the installed kendex lists it; 1.12.0 drops the
# probe.
refresh_help="$(kendex help refresh 2>/dev/null || true)"
refresh_args=(refresh --scope project --yes --leave)
case "$refresh_help" in
  *--prune*) refresh_args+=(--prune) ;;
esac
refresh_output="$(kendex "${refresh_args[@]}" 2>&1)" || refresh_status=$?
# The engine owns both compatibility and the lock's recorded-commit floor.
# Its refusal precedes package writes. A release retry keeps that floor and
# explicit revisions; it must not turn any other failure into a fallback.
catalog_pattern='^Error: catalog-needs-engine min=([^[:space:]]+) engine=([^[:space:]]+)$'
if [ "$refresh_status" -ne 0 ] && [ "$KENDEX_CATALOG_REV" = main ]; then
  while IFS= read -r line; do
    [[ "$line" =~ $catalog_pattern ]] || continue
    KENDEX_CATALOG_REV="v${BASH_REMATCH[2]}"
    printf -v catalog_held 'catalog-held min=%s engine=%s' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
    printf '%s\n' "$catalog_held"
    printf -v catalog_note 'Packages wait for a CLI release and the v1 move: `%s`. This refresh selected the release catalog `%s`. Declared revisions and the lock record still take precedence.' "$catalog_held" "$KENDEX_CATALOG_REV"
    if [ "${#projects[@]}" -gt 1 ]; then catalog_note="Project \`$2\`: $catalog_note"; fi
    catalog_report="${catalog_report}${catalog_report:+$'\n'}$catalog_note"
    refresh_status=0
    refresh_output="$(kendex "${refresh_args[@]}" 2>&1)" || refresh_status=$?
    break
  done <<<"$refresh_output"
fi
printf '%s\n' "$refresh_output"
if [ "$refresh_status" -ne 0 ]; then
  printf 'refresh-error=refresh value=%s\n' "$refresh_status" >&2
  exit "$refresh_status"
fi
# refresh has no JSON report. Fall back to blocked.rs's plain conflicts
# section and holds.rs's records; verify cannot report discarded edits.
# ledger.rs counts distinct kind/name items, not rows or harnesses.
# setting_notes collects the change-class lines that name a consumer
# setting; a run with no render change runs no classifier and reports none.
# retired_items collects the line refresh prints for each item its catalog
# retired, keyed by the item's name and the catalog, its migration last.
retired_pattern='^[^ :]+: retired by '
held_items=""
held_keys=$'\n'
held_count=0
conflict_count=""
conflict_section=no
ledger_pattern=' · skipped ([1-9][0-9]*) items? on conflict( · |$)'
while IFS= read -r line; do
  case "$line" in
    conflicts:) conflict_section=yes; continue ;;
    '    '*) continue ;;
    '  '*)
      if [ "$conflict_section" = yes ]; then
        case "$line" in
          *': edited on disk and changed upstream — keep your edits as a fork, or apply with edits discarded' | \
          *': edited on disk since install — keep it as a fork, or apply with edits discarded' | \
          *': its files were edited on disk after another tool installed them — keep the edits as a fork, or apply with edits discarded' | \
          *': changed upstream and on disk — kendex cannot tell your edits from the update; keep it as a fork or apply with edits discarded') ;;
          *)
            printf 'refresh-error=conflict-record value=%s\n' "${line#  }" >&2
            exit 1 ;;
        esac
        held_items="$held_items- ${line#  }
"
        item="${line#  }"
        item="${item%: *}"
        item="${item% for *}"
        case "$held_keys" in
          *$'\n'"$item"$'\n'*) ;;
          *) held_keys="$held_keys$item"$'\n'; held_count=$((held_count + 1)) ;;
        esac
      fi ;;
    *) conflict_section=no ;;
  esac
  if [[ "$line" =~ $retired_pattern ]]; then
    if [ "${#projects[@]}" -gt 1 ]; then line="project=$2 $line"; fi
    retired_items="$retired_items$line"$'\n'
  fi
  case "$line" in
    *' · skipped '*' on conflict'*)
      if [ -n "$conflict_count" ] || ! [[ "$line" =~ $ledger_pattern ]]; then
        printf 'refresh-error=conflict-ledger value=%s\n' "$line" >&2
        exit 1
      fi
      conflict_count="${BASH_REMATCH[1]}" ;;
  esac
done <<<"$refresh_output"
if [ -n "$conflict_count" ] || [ "$held_count" -ne 0 ]; then
  if [ "${conflict_count:-0}" != "$held_count" ]; then
    printf 'refresh-error=conflict-count value=%s held=%s\n' "${conflict_count:-0}" "$held_count" >&2
    exit 1
  fi
  printf 'refresh-error=render-edited value=%s\n' "$held_count" >&2
  printf '%s' "$held_items" >&2
  exit 1
fi
# refresh keeps the files of a declaration deleted from kendex.toml by hand;
# apply moves them to the trash as diffs of this pull request. A leftover
# edited on disk is held, not trashed, and the verify below fails on it.
apply_status=0
kendex apply --scope project --yes --leave || apply_status=$?
if [ "$apply_status" -ne 0 ]; then
  printf 'refresh-error=apply value=%s\n' "$apply_status" >&2
  exit 1
fi
# The refresh above skips the bot-instructions render: the arming record that
# licenses it lives in a git directory, and this fresh checkout's has none.
# The consumer's check judges the pull request with the refreshed package, so
# this run asks kendex to render once, which locates the package wherever the
# install put it and writes no record. The invocation is the licence, spent
# in a checkout this run discards, and it runs with no credential. The
# package's unconfigured refusal, which bot-instructions' validators.md
# § orphan defines, leaves that consumer unrendered. The refresh is staged
# first because the render reads the index for the tree's subtrees; the
# later git add -A takes what it writes and removes.
git add -A
render_status=0
render_output=""
render_skip=""
render_output="$(env -i PATH="$PATH" HOME="$HOME" KENDEX_UI=plain kendex bot-instructions-render 2>&1)" || render_status=$?
printf '%s\n' "$render_output"
case "$render_status" in
  0) if grep -qxF 'bot-instructions-render=absent' <<<"$render_output"; then render_skip=absent; fi ;;
esac
# The package's render reports an unconfigured repository with exit 0; a copy
# installed before it did refused one with exit 2.
case "$render_status" in
  0|2) if grep -qx 'bot-instructions: unconfigured=.*' <<<"$render_output"; then render_skip=unconfigured; fi ;;
esac
if [ -n "$render_skip" ]; then
  printf 'refresh-render=skipped package=bot-instructions cause=%s\n' "$render_skip"
elif [ "$render_status" -ne 0 ]; then
  printf 'refresh-error=bot-instructions-render value=%s\n' "$render_status" >&2
  exit 1
fi
# The root caller can still carry an older adoption record after apply.
# Adopt it once before verification judges the refreshed template bytes.
if [ "$1" = "$ROOT" ]; then
  "$SCRIPT_DIR/adopt-refresh.sh" --templates-dir "$templates"
fi
verify_status=0
{
  kendex verify --scope project --json
} >"$TMP/verify.json" 2>"$TMP/verify.said" || verify_status=$?
cat -- "$TMP/verify.said" >&2
[ "$verify_status" -ne 0 ] || return 0
# A verify whose every failure is a declaration this project's manifest
# withholds still publishes, as a draft that names each finding and the
# manifest line it comes from: the edit that clears it belongs in that file
# on the default branch. Prints the findings as list items, or exits 1 with
# refresh-verify=other cause=CAUSE on stderr for any other failure, an
# unread document included, which keeps the run's exit. A row the reader
# does not know is another failure. Repository setup and a tracked-output
# check git could not answer fail verify with no row, so the closing line
# must also count no other failure.
if ! findings="$(python3 - "$TMP/verify.json" "$TMP/verify.said" <<'VERIFY_FINDINGS'
import json, pathlib, re, sys
def other(cause):
    print('refresh-verify=other cause=' + cause, file=sys.stderr)
    sys.exit(1)
try:
    doc = json.loads(pathlib.Path(sys.argv[1]).read_text())
    said = [line for line in pathlib.Path(sys.argv[2]).read_text().splitlines() if line.strip()]
except (OSError, ValueError):
    other('unread')
if not isinstance(doc, dict) or doc.get('version') != 1 or doc.get('clean') is not False or \
        doc.get('failed') != 0 or not isinstance(doc.get('rows'), list):
    other('document')
rows = doc['rows']
if not all(isinstance(row, dict) and isinstance(row.get('kind'), str) and isinstance(row.get('name'), str) and
           isinstance(row.get('detail', ''), str) for row in rows):
    other('document')
if any(row.get('state') not in ('ok', 'notice', 'warning', 'unrecorded') for row in rows):
    other('row')
held = [row for row in rows if row['state'] == 'unrecorded']
if not held or not all(row.get('detail', '').startswith('withheld: ') for row in held):
    other('unrecorded')
# verify prints the record row only where it read the record.
if not any(row['kind'] == 'record' and row['state'] == 'ok' for row in rows):
    other('record')
if not said or not re.fullmatch(r'(nothing checked|[0-9]+ checked, [0-9]+ OK, 0 failed)(; [0-9]+ warnings?)?', said[-1]):
    other('closing')
def declaration(kind, name):
    header = re.compile(r'\s*\[\s*' + re.escape(kind) + r's\s*\.\s*("?)' + re.escape(name) + r'\1\s*\]\s*(#.*)?')
    for manifest in ('kendex.toml', 'kendex-local.toml'):
        path = pathlib.Path(manifest)
        lines = path.read_text().splitlines() if path.is_file() else []
        for start, line in enumerate(lines):
            if not header.fullmatch(line):
                continue
            found = start
            for index in range(start + 1, len(lines)):
                if lines[index].lstrip().startswith('['):
                    break
                if re.match(r'\s*harnesses\s*=', lines[index]):
                    found = index
                    break
            return ' (`%s` line %d: `%s`)' % (manifest, found + 1, lines[found].strip())
    return ''
try:
    for row in rows:
        if row['state'] in ('unrecorded', 'notice'):
            on = ' on ' + row['harness'] if isinstance(row.get('harness'), str) else ''
            print('- %s `%s`%s: %s%s' % (row['kind'], row['name'], on, row.get('detail', ''), declaration(row['kind'], row['name'])))
except (OSError, ValueError):
    other('manifest')
VERIFY_FINDINGS
)"; then
  printf 'refresh-error=verify value=%s\n' "$verify_status" >&2
  exit "$verify_status"
fi
printf 'refresh-verify=held project=%s\n' "$2"
if [ "${#projects[@]}" -gt 1 ]; then findings="Project \`$2\`:"$'\n'"$findings"; fi
verify_report="${verify_report}${verify_report:+$'\n'}$findings"
held_status="$verify_status"
}
for ((project_index=0; project_index<${#projects[@]}; project_index++)); do
  refresh_project "${projects[$project_index]}" "${project_entries[$project_index]}"
done
cd -- "$ROOT"
# The release's settings library scans the committed [env] table as data,
# without the refresh app credential. Only this script in the kendex release
# tree consumes its output or publishes.
if ! env -i PATH="$PATH" HOME="$HOME" bash -s -- "$SCRIPT_DIR" >"$TMP/settings.json" <<'SETTINGS_PARSE'
set -euo pipefail
source "$1/../skills/review-gate/scripts/lib/settings.sh"
# List every committed [env] setting as key and value pairs for the
# retired-settings match. The report warns and changes no exit. A comment,
# another table and a private override are not committed [env] values.
committed=()
if [ -f kendex.settings.toml ]; then
  table="$(rg_env_table kendex.settings.toml)"
  assignment='^[[:space:]]*([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=[[:space:]]*"([^"]*)"'
  while IFS= read -r line; do
    [[ $line =~ $assignment ]] || continue
    key="${BASH_REMATCH[1]}" value="${BASH_REMATCH[2]}"
    committed+=("$key" "$value")
  done <<<"$table"
fi
jq -cn --args \
  '{committed: ($ARGS.positional |
      [range(0; length; 2) as $i | {(.[$i]): .[$i + 1]}] | add // {})}' \
  -- ${committed[@]+"${committed[@]}"}
SETTINGS_PARSE
then
  printf 'refresh-error=settings-extraction value=%s\n' "$ROOT/kendex.settings.toml" >&2
  exit 1
fi
# Sets settings_report from the parse and setting_notes. A failed report
# stops publication and auto-merge.
report_settings() {
  if ! settings_report="$(jq -c --args '. + {notes: $ARGS.positional}' -- ${setting_notes[@]+"${setting_notes[@]}"} <"$TMP/settings.json" |
    python3 "$SCRIPT_DIR/refresh-report.py" --settings "$ROOT")"; then
    printf 'refresh-error=settings-report value=%s\n' "$SCRIPT_DIR/refresh-report.py" >&2
    exit 1
  fi
}
if ! engine_version="$(kendex --version)"; then
  printf 'refresh-error=read value=engine-version\n' >&2
  exit 1
fi
printf -v version_report 'Engine version: `%s`.' "$engine_version"
git add -A
# D003 keeps project lock records with the next content-changing refresh.
# Literal exclusions use the verified project list, so other changes still publish.
publication_paths=(.)
for directory in "${projects[@]}"; do
  lock_path="${directory#"$ROOT"}/.kendex-lock.json"
  publication_paths+=(":(top,exclude,literal)${lock_path#/}")
done
publication_status=0
git diff --cached --quiet -- "${publication_paths[@]}" || publication_status=$?
if [ "$publication_status" -gt 1 ]; then
  printf 'refresh-error=read value=publication-diff\n' >&2
  exit 1
fi
# Prints sources=covered where every selected project takes its packages
# from the default catalog at main alone, sources=uncovered where one does
# not, and sources=unread where the evidence could not be read: the engine's
# answer, its shape, or a project manifest. The engine owns source
# resolution. Its subscription JSON identifies remotes but omits item
# overrides, so inspect TOML for any revision. A revision override is never
# covered: only the default catalog at main is. An unread answer writes what kendex said
# and one refresh-sources=unread value=PROJECT line, the cause after it, to
# stderr. Anything but covered keeps the landing route's pull request.
refresh_source_coverage() {
python3 - "${projects[@]}" <<'SOURCE_COVERAGE'
import json, pathlib, subprocess, sys
class Unread(Exception):
    pass
def need(held, what):
    if not held:
        raise Unread(what)
def revision(value):
    if isinstance(value, dict):
        return 'rev' in value or any(revision(child) for child in value.values())
    return isinstance(value, list) and any(revision(child) for child in value)
def covered(project):
    import tomllib
    root = pathlib.Path(project)
    answer = subprocess.run(['kendex', 'marketplace', 'list', '--scope', 'project', '--json'],
                            cwd=root, timeout=30, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    sys.stderr.buffer.write(answer.stderr)
    need(answer.returncode == 0, 'kendex marketplace list exited %d' % answer.returncode)
    listed = json.loads(answer.stdout)
    need(isinstance(listed, dict) and listed.get('schema') == 1, 'the subscription list is not schema 1')
    sources = listed.get('subscriptions')
    need(isinstance(sources, list) and
         all(isinstance(row, dict) and isinstance(row.get('enabled'), bool) for row in sources),
         'a subscription row has no boolean enabled')
    if not sources or not all(row['enabled'] is False or
            (row.get('repo') == 'vanillagreencom/kendex' and 'path' not in row and 'rev' not in row)
            for row in sources):
        return False
    manifests = [root / 'kendex.toml', root / 'kendex-local.toml']
    need(manifests[0].is_file(), 'kendex.toml is not a file')
    for manifest in manifests:
        need(not manifest.is_symlink(), manifest.name + ' is a symlink')
        if manifest.exists() and revision(tomllib.loads(manifest.read_text())):
            return False
    return True
verdict = 'covered'
project = ''
try:
    for project in sys.argv[1:]:
        if not covered(project):
            verdict = 'uncovered'
            break
except (Unread, ImportError, OSError, ValueError, subprocess.SubprocessError) as error:
    print('refresh-sources=unread value=%s\n%s' % (project, error), file=sys.stderr)
    verdict = 'unread'
print('sources=' + verdict)
SOURCE_COVERAGE
}
if [ "$publication_status" -eq 0 ] && [ -n "$verify_report" ]; then
  # No change to carry the findings, so the verify failure stands.
  printf 'Verify failed on these declarations, and no content changed to publish:\n\n%s\n' "$verify_report" >>"${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY names the run summary}"
  printf 'refresh-error=verify value=%s\n' "$held_status" >&2
  exit "$held_status"
fi
if [ "$publication_status" -eq 0 ]; then
  report_settings
  refresh_close_superseded
  printf 'refresh-state=current pr=none class=none\n'
  printf '%s\n\nNo content changes to publish. Project lock records publish with the next content change.\n' "$version_report" >>"${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY names the run summary}"
  [ -z "$catalog_report" ] || printf '\n%s\n' "$catalog_report" >>"$GITHUB_STEP_SUMMARY"
  # A run with no render change opens no pull request; its settings report
  # still reaches the run summary.
  [ -z "$settings_report" ] || printf '\n%s\n' "$settings_report" >>"$GITHUB_STEP_SUMMARY"
  exit 0
fi
if ! tree="$(git write-tree)"; then
  printf 'refresh-error=read value=tree\n' >&2
  exit 1
fi
report_settings
if ! changelog_report="$(python3 "$SCRIPT_DIR/refresh-report.py" --catalog "$base" "$TMP/catalog-history" "${projects[@]}")"; then
  printf 'refresh-warning=catalog-report\n' >&2
  changelog_report=$'## Kendex changelog\n\nCould not read the recorded kendex catalog changes.'
fi
if [ -n "$old" ] && [ "$tree" = "$(git rev-parse "$old^{tree}")" ]; then
  # A new scheduled run must not replace an identical commit and reset CI.
  head="$old"
  state=unchanged
else
  user_id="$(gh api "users/${REFRESH_APP_SLUG}[bot]" --jq .id)"
  git config user.name "${REFRESH_APP_SLUG}[bot]"
  git config user.email "$user_id+${REFRESH_APP_SLUG}[bot]@users.noreply.github.com"
  # No consumer hook executes under the app token. Verification checks the
  # installed files; the repository's checks run on its pull request.
  # The default-branch push carries the notices in its commit message.
  {
    printf 'chore: refresh kendex renders\n'
    [ -z "$changelog_report" ] || printf '\n%s\n' "$changelog_report"
    [ -z "$settings_report" ] || printf '\n%s\n' "$settings_report"
  } >"$TMP/commit-message"
  git -c core.hooksPath=/dev/null commit --cleanup=verbatim -F "$TMP/commit-message"
  head="$(git rev-parse HEAD)"
  state=pushed
fi
class_result=0
class_output="$("$SCRIPT_DIR/../skills/harness-ci/scripts/change-class" --event pull_request --base "$base" --head "$head" --repo "$ROOT" 2>&1)" || class_result=$?
printf '%s\n' "$class_output" >&2
class=""
class_line=""
while IFS= read -r line; do
  case "$line" in
    change_class=*) class="${line#change_class=}" ;;
    'class: class='*) class_line="$line" ;;
    # Every verdict carries a queue-only line; only these causes name the
    # repository's own settings.
    'setting-unset: '* | 'queue-only: '*' cause=queue-list-undeclared' | \
      'queue-only: '*' cause=queue-settings-unreadable') setting_notes+=("$line") ;;
  esac
done <<<"$class_output"
# An unmeasured standard verdict widens review and CI. Narrower classes still
# need measurement, with leading fields that agree with stdout.
if [ "$class_result" -ne 0 ] || [ -z "$class" ] ||
    { [[ "$class_line" != "class: class=$class measured=true "* ]] &&
      { [ "$class" != standard ] || [[ "$class_line" != "class: class=standard measured=false "* ]]; }; }; then
  printf 'refresh-error=read value=class\n' >&2
  exit 1
fi
[ -z "${setting_notes[0]:-}" ] || report_settings
# An identical tree publishes no new head. Only a new publication belongs to
# this automatic admission route; absence of an open PR proves no first arm.
# A held run still names its findings on the retained head and keeps it a
# draft.
if [ "$state" = unchanged ] && [ -z "$verify_report" ]; then
  printf 'refresh-state=unchanged pr=%s class=%s head=%s published=false\n' "${pr:-none}" "$class" "$head"
  printf 'Refresh retained head `%s`; no new head was published. Automatic admission was deferred.\n\n%s\n\n%s\n' "$head" "$version_report" "$class_line" >>"${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY names the run summary}"
  [ -z "$catalog_report" ] || printf '\n%s\n' "$catalog_report" >>"$GITHUB_STEP_SUMMARY"
  [ -z "$settings_report" ] || printf '\n%s\n' "$settings_report" >>"$GITHUB_STEP_SUMMARY"
  [ -z "$changelog_report" ] || printf '\n%s\n' "$changelog_report" >>"$GITHUB_STEP_SUMMARY"
  exit 0
fi
# Writes the emitted paths of the root .kendex-lock.json to FILE, one per
# line, through md-refs' own reader, so the landing check and the consumer's
# next md-refs run agree on what is rendered. That reader reads the index,
# which the commit above left at head; it prints its own cause and fails on
# a lock it cannot read.
refresh_emitted_paths() { # FILE
  # shellcheck disable=SC2034 # the sourced library reads GG_CHECK and GG_TMP
  (
    GG_CHECK=refresh-lock
    source "$SCRIPT_DIR/../skills/commit-guards/scripts/lib/common.sh" &&
      source "$SCRIPT_DIR/../skills/commit-guards/scripts/lib/md-scope.sh" &&
      GG_TMP="$TMP" && gg_md_lock_paths "$1"
  )
}
# Only a commit this run made lands on the default branch: the retained head
# above may be one a failed merge group left, and this run proved only its
# own commit, on the base it fetched. land_token is the landing app's
# token, which only the protected environment mints, and the push uses it
# alone. The default branch's rulesets decide the push: the run asks
# nothing about them first. The render proof covers a package's bytes, and
# kendex's merge queue proved only the default catalog's content, so a
# project that takes packages from any other catalog or revision keeps the
# pull request, where the consumer reviews them. A render that takes a
# path out of every emitted position of the root lock, such as a pruned
# package or a removed or renamed per-file agent, can break a file the
# consumer still cites, which the render proof does not read, so it keeps
# the pull request too; a removal inside a position the lock still emits
# lands. No token, a held run, a class other than render, such a removal,
# an unread lock, that coverage, and a merge queue that could not be read
# keep the pull request route. A merge queue that holds an entry defers
# the render below instead.
# Sets land_check to try, to unconfigured where the caller set neither
# landing name, or to unavailable:CAUSE or skipped:CAUSE for the first
# precondition the run does not meet. The one reporter below prints every
# CAUSE, and refuses an answer it does not know, so no precondition keeps
# the pull request route unsaid.
refresh_land_check() {
  local queued path position
  land_check=""
  if [ -z "$land_token" ]; then
    # A half pair, or a mint that failed, leaves the token empty.
    if [ "$land_configured" = true ]; then land_check=unavailable:token; else land_check=unconfigured; fi
    return 0
  fi
  if [ -n "$verify_report" ]; then land_check=skipped:verify; return 0; fi
  if [ "$class" != render ]; then land_check=skipped:class; return 0; fi
  # --no-renames reports a renamed path as removed.
  if ! git diff -z --no-renames --diff-filter=D --name-only "$base" "$head" >"$TMP/removed-paths"; then
    printf 'refresh-error=read value=removed-paths\n' >&2
    exit 1
  fi
  if [ -s "$TMP/removed-paths" ]; then
    # md-refs reads only the head lock, so it cannot skip a citation into a position the render dropped.
    if ! refresh_emitted_paths "$TMP/emitted-paths"; then land_check=unavailable:lock-read; return 0; fi
    while IFS= read -r -d '' path; do
      position="$path"
      until grep -qxF -- "$position" "$TMP/emitted-paths"; do
        case "$position" in
          */*) position="${position%/*}" ;;
          *) land_check=skipped:path-removed; return 0 ;;
        esac
      done
    done <"$TMP/removed-paths"
  fi
  case "$(refresh_source_coverage)" in
    sources=covered) ;;
    sources=uncovered) land_check=skipped:sources-uncovered; return 0 ;;
    *) land_check=unavailable:sources-read; return 0 ;;
  esac
  if ! queued="$(kendex_land_queue_entries "$GH_REPO" "$default")"; then
    land_check=unavailable:queue-read
    return 0
  fi
  if [ "$queued" != 0 ]; then land_check=skipped:queued; return 0; fi
  land_check=try
}
refresh_land_check
case "$land_check" in
  try | unconfigured) ;;
  unavailable:?* | skipped:?*) printf 'refresh-land=%s value=%s\n' "${land_check%%:*}" "${land_check#*:}" ;;
  *) printf 'refresh-error=land-check value=%s\n' "${land_check:-unset}" >&2; exit 1 ;;
esac
# A proved render owes no pull request, CI run or approval, and a push into
# a busy queue rebuilds every running group, so it waits for a run that
# meets an empty queue: the next daily or release-dispatched run renders
# again and tries the landing. Nothing re-dispatches this run, so a queue busy at every
# run holds the render until one finds it empty.
if [ "$land_check" = skipped:queued ]; then
  printf 'refresh-state=deferred reason=queued\n'
  exit 0
fi
if [ "$land_check" = try ]; then
  kendex_land_push "$ROOT" origin "$head" "$default" "$land_token"
  if [ "$KENDEX_LAND_RESULT" = landed ]; then
    refresh_close_superseded
    printf 'refresh-state=landed pr=none class=%s head=%s\n' "$class" "$head"
    {
      printf 'Landed `%s` on `%s` with no pull request.\n\n%s\n\nChange class: `%s`.\n\nClassifier:\n```text\n%s\n```\n' \
        "$head" "$default" "$version_report" "$class" "$class_line"
      [ -z "$catalog_report" ] || printf '\n%s\n' "$catalog_report"
      [ -z "$settings_report" ] || printf '\n%s\n' "$settings_report"
      [ -z "$changelog_report" ] || printf '\n%s\n' "$changelog_report"
      [ -z "$retired_items" ] || printf '\nRetired items:\n```text\n%s```\n' "$retired_items"
    } >>"${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY names the run summary}"
    exit 0
  fi
  # A default branch that moved after this run's fetch defers to the next
  # run, which renders on the new base. GitHub's own refusal keeps the pull
  # request route.
  if [ "$KENDEX_LAND_RESULT" = base-moved ]; then
    printf 'refresh-state=deferred reason=base-moved\n'
    exit 0
  fi
  printf 'refresh-land=refused value=%s\n' "$KENDEX_LAND_STATUS"
fi
merge_note='The refresh workflow waits for GitHub to show the published head. It merges directly where the base branch has no rules or protection, or requests auto-merge. If the head stays unseen, the run reports an unarmed warning. Check the run result for the arm outcome. The merge queue controls merging after auto-merge is enabled or this pull request is queued.'
printf -v body 'Generated kendex updates.\n\n%s\n\nChange class: `%s`.\n\nClassifier:\n```text\n%s\n```\n\n%s\n' "$version_report" "$class" "$class_line" "$merge_note"
if [ -n "$catalog_report" ]; then
  printf -v body '%s\n\n%s\n' "$body" "$catalog_report"
fi
if [ -n "$settings_report" ]; then
  printf -v body '%s\n%s\n' "$body" "$settings_report"
fi
if [ -n "$retired_items" ]; then
  printf -v body '%s\nRetired items:\n```text\n%s```\n' "$body" "$retired_items"
fi
if [ -n "$verify_report" ]; then
  printf -v verify_note 'kendex verify failed on declarations this repository holds, so this pull request stays a draft and unarmed until verify passes. Make the edit each finding names on the default branch; the next refresh renders on it and marks this pull request ready.\n\n%s' "$verify_report"
  printf -v body '%s\n%s\n' "$body" "$verify_note"
fi
pull_body="$TMP/pull-body"
printf '%s' "$body" >"$pull_body"
report_location="[Read the full catalog report in the refresh commit](https://github.com/$GH_REPO/commit/$head)."
if [ "$state" = unchanged ] &&
    ! git show -s --format=%B "$head" | grep -Fx '## Kendex changelog' >/dev/null; then
  report_location='The full report exceeds GitHub’s limit. The retained commit predates the catalog report.'
fi
# Stream the report to keep it outside argv and check GitHub's character limit before publication.
printf '%s' "${changelog_report:+$'\n'$changelog_report$'\n'}" | python3 -c '
from pathlib import Path
import sys
path = Path(sys.argv[1])
body = path.read_text(encoding="utf-8", errors="replace")
report = sys.stdin.buffer.read().decode("utf-8", errors="replace")
if report and len(body + report) > 65536:
    report = f"\n## Kendex changelog\n\n{sys.argv[2]}\n"
    if len(body + report) > 65536:
        body = body.replace(sys.argv[3] + "\n", "", 1)
if len(body + report) > 65536:
    raise SystemExit("refresh-error=pull-body value=too-large")
path.write_text(body + report, encoding="utf-8")
' "$pull_body" "$report_location" "$merge_note"
if [ "$state" = pushed ] || [ -n "$verify_report" ]; then
  # An old arm survives a push and could merge the replacement before review,
  # and a held head must not merge at all. Read lifecycle again after
  # rendering; disarm only for this new publication or a held head.
  if [ -n "$pr" ] || [ -n "$old" ]; then
    refresh_lifecycle
    if [ "$reason" = armed ] && ! gh pr merge "$pr" --repo "$GH_REPO" --disable-auto; then
      refresh_lifecycle
      case "$reason" in
        queued | merged | closed) ;;
        *)
          printf 'refresh-error=disarm pr=%s value=%s\n' "$pr" "$reason" >&2
          exit 1 ;;
      esac
    fi
    case "$reason" in
      queued | merged | closed | branch-gone)
        printf 'refresh-state=deferred reason=%s\n' "$reason"
        exit 0 ;;
    esac
  fi
fi
if [ "$state" = pushed ]; then
  push_status=0
  git push "--force-with-lease=refs/heads/kendex/refresh:$old" origin HEAD:refs/heads/kendex/refresh 2>"$TMP/push-stderr" || push_status=$?
  cat -- "$TMP/push-stderr" >&2
  if [ "$push_status" -ne 0 ]; then
    if [ "$pr" = "" ]; then
      if ! pr="$(gh api "repos/$GH_REPO/pulls?state=open&head=${GH_REPO%%/*}:kendex/refresh&sort=created&direction=desc&per_page=1" --jq '.[0].number // empty')"; then
        printf 'refresh-error=push-state value=pulls\n' >&2
        exit 1
      fi
    fi
    refresh_lifecycle
    # GitHub's GH006 refusal for a queued branch, as git relays it. The read
    # can still answer active after that refusal, so the refusal decides.
    # GitHub wraps the message, so the lines are joined before matching.
    if ! refusal="$(sed 's/^remote://' "$TMP/push-stderr" | tr -s ' \t\r\n' ' ')"; then
      printf 'refresh-error=read value=push-stderr\n' >&2
      exit 1
    fi
    case "$refusal" in
      *'GH006: Protected branch update failed'*'has been added to a merge queue. Branches that are queued for merging cannot be updated.'*)
        case "$reason" in active | armed) reason=queued ;; esac ;;
    esac
    # An armed or active pull request that GitHub has not taken leaves the
    # refusal unexplained, so the push failure stands.
    case "$reason" in
      queued | merged | closed | branch-gone)
        printf 'refresh-state=deferred reason=%s\n' "$reason"
        exit 0 ;;
    esac
    printf 'refresh-error=push value=%s\n' "$push_status" >&2
    exit 1
  fi
fi
# The refresh owns its rolling pull request's draft state: a draft is one
# GitHub merges by no route, and a held run leaves it one.
if [ -z "$pr" ]; then
  draft=()
  if [ -n "$verify_report" ]; then draft=(-F draft=true); fi
  pr="$(gh api --method POST "repos/$GH_REPO/pulls" -f head=kendex/refresh -f base="$default" -f title='chore: refresh kendex renders' -F body=@"$pull_body" ${draft[@]+"${draft[@]}"} --jq .number)"
else
  if ! drafted="$(gh api --method PATCH "repos/$GH_REPO/pulls/$pr" -F body=@"$pull_body" --jq .draft)"; then
    printf 'refresh-error=pull-update pr=%s\n' "$pr" >&2
    exit 1
  fi
  if [ -n "$verify_report" ] && [ "$drafted" != true ]; then
    gh pr ready "$pr" --repo "$GH_REPO" --undo || { printf 'refresh-error=draft pr=%s\n' "$pr" >&2; exit 1; }
  elif [ -z "$verify_report" ] && [ "$drafted" = true ]; then
    gh pr ready "$pr" --repo "$GH_REPO" || { printf 'refresh-error=ready pr=%s\n' "$pr" >&2; exit 1; }
  fi
fi
if [ -n "$verify_report" ]; then
  printf 'refresh-state=held pr=%s class=%s head=%s\n' "$pr" "$class" "$head"
  printf '::warning title=refresh held::pull request %s stays a draft until kendex verify passes; its body names each finding\n' "$pr"
  printf 'Held pull request %s at `%s` as a draft.\n\n%s\n' "$pr" "$head" "$verify_note" >>"${GITHUB_STEP_SUMMARY:?GITHUB_STEP_SUMMARY names the run summary}"
  exit 0
fi
merge_route=auto
# The completed render proof permits a direct merge only when GitHub confirms
# that the base requires nothing else. Unreadable evidence keeps the arm route.
if branch_rules="$(gh api "repos/$GH_REPO/rules/branches/$default")" &&
    branch_protected="$(gh api "repos/$GH_REPO/branches/$default" --jq .protected)" &&
    [ "$branch_protected" = false ] &&
    jq -e 'type == "array" and length == 0' <<<"$branch_rules" >/dev/null; then
  merge_route=direct
fi
arm_status=0
rg_arm_published_head "$GH_REPO" "$pr" "$head" squash "$merge_route" || arm_status=$?
if [ "$arm_status" -ne 0 ]; then
  if [ "$RG_ARM_RESULT" = merged ]; then
    printf 'refresh-error=merge pr=%s pushed=%s value=%s\n' "$pr" "$head" "$arm_status" >&2
    exit "$arm_status"
  fi
  printf 'refresh-error=arm pr=%s pushed=%s head=%s value=%s\n' "$pr" "$head" "$RG_ARM_SEEN" "$arm_status" >&2
  exit "$arm_status"
fi
if [ "$RG_ARM_RESULT" = unmatched ]; then
  printf 'refresh-state=unarmed pr=%s pushed=%s head=%s\n' "$pr" "$head" "$RG_ARM_SEEN"
  printf '::warning title=refresh unarmed::pull request %s left unarmed: GitHub showed %s, pushed %s\n' "$pr" "$RG_ARM_SEEN" "$head"
  exit 0
fi
if [ "$RG_ARM_RESULT" = merged ]; then
  printf 'refresh-state=merged pr=%s class=%s\n' "$pr" "$class"
  exit 0
fi
# gh can succeed on a merge-queue repository without enabling auto-merge.
refresh_lifecycle
case "$reason" in
  armed | queued | merged) ;;
  *)
    printf 'refresh-error=arm-state pr=%s pushed=%s value=%s\n' "$pr" "$head" "$reason" >&2
    exit 1 ;;
esac
printf 'refresh-state=%s pr=%s class=%s\n' "$state" "$pr" "$class"
