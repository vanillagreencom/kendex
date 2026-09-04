#!/usr/bin/env bash
# ---
# name: doc-drift-check
# event: Stop
# matcher:
# description: Blocks a stop once per session when code changed under a directory a doc covers and no covering doc changed. Changed means every path that differs between the working tree and the branch's merge-base with the default branch (`origin/HEAD`, else `main`, else `master`), committed or not, plus untracked non-ignored paths; on the default branch itself, or where no merge-base resolves, the working tree alone, and the block message says which. A directory is covered by a tracked non-root `AGENTS.md` at or above it (the nearest one counts) and by every `docs/architecture/*.md` whose `Covers:` line names an ancestor (space- or comma-separated repo-relative directories, trailing slash optional). Markdown paths are never code. The block message names each doc to confirm or update; the session is then marked in `<git common dir>/kendex/doc-drift/<session_id>` so later stops in that session pass, and `stop_hook_active` true passes outright. Claude Code only: Codex has no Stop event, and Pi's turn-end dispatch does not exist yet.
# safety: Reads git state and the docs; the only write is the per-session marker under the git common dir. Exit 2 never suggests bypassing — it names the docs and asks for them to be confirmed or updated. jq is required to read the session id; without it a warranted block cannot be recorded, so it is refused each time until the docs change.
# timeout: 30
# harnesses: [claude-code]
# ---

set -euo pipefail

# Session ids and doc paths are matched by byte ranges below; a locale that
# reads them as something else changes what a filename may hold.
export LC_ALL=C

# An unreadable payload is a refusal, never an empty one: the session id in
# it is the only thing that lets a second stop pass.
INPUT=$(cat) || {
  echo "doc-drift-check: could not read the hook payload from stdin" >&2
  exit 2
}

git_failed() { # SUBCOMMAND OUTPUT — an unreadable changed set is not an empty one
  echo "doc-drift-check: git $1 failed, so what changed is unknown:" >&2
  printf '%s\n' "$2" >&2
  exit 2
}

# A git that cannot answer blocks, with no reading of the failure that means
# "nothing to gate": rev-parse exits 128 outside a repository and inside one
# whose metadata it cannot read, and the hook has no way to tell which.
REPO_ROOT=$(git rev-parse --show-toplevel 2>&1) || git_failed 'rev-parse' "$REPO_ROOT"

# What counts as changed is everything the branch did: every path that
# differs between the working tree and the branch's merge-base with the
# default branch, committed or not, plus untracked non-ignored paths. The
# workflow commits before it stops, so a set read off the working tree
# alone is empty at the one moment the gate matters. On the default branch
# itself, or where no merge-base resolves, the working tree alone is
# judged, and the block message says so.
#
# The probes for the default branch exit 1 when the ref is absent and
# otherwise on a repository git cannot read; only the first is an answer.
# The answer lands in REF rather than on stdout: a substitution would run
# the probe in a subshell, where the exit on a failed git ends only that
# subshell and reads to the caller as "absent".
probe_ref() { # ARGS... — sets REF; returns 1 when the ref is absent
  local rc=0
  REF=$(git "$@" 2>&1) || rc=$?
  case "$rc" in
    0) return 0 ;;
    1) return 1 ;;
    *) git_failed "$1" "$REF" ;;
  esac
}
DEFAULT=""
if probe_ref symbolic-ref -q refs/remotes/origin/HEAD; then
  DEFAULT="${REF#refs/remotes/}"
elif probe_ref rev-parse -q --verify refs/heads/main; then
  DEFAULT=main
elif probe_ref rev-parse -q --verify refs/heads/master; then
  DEFAULT=master
fi
# A detached HEAD has no branch name and is never the default branch.
CURRENT=""
if probe_ref symbolic-ref -q --short HEAD; then
  CURRENT="$REF"
fi

BASE=""
if [ -z "$DEFAULT" ]; then
  JUDGED="the working tree alone: no origin/HEAD, main or master to compare against"
elif [ "$CURRENT" = "${DEFAULT#origin/}" ]; then
  JUDGED="the working tree alone: $CURRENT is the default branch"
else
  rc=0
  BASE=$(git merge-base HEAD "$DEFAULT" 2>&1) || rc=$?
  case "$rc" in
    0) JUDGED="every change since $BASE, the merge-base with $DEFAULT" ;;
    1)
      BASE=""
      JUDGED="the working tree alone: HEAD shares no history with $DEFAULT"
      ;;
    *) git_failed 'merge-base' "$BASE" ;;
  esac
fi

# `-z` asks for the paths themselves. Line-oriented git output C-quotes a
# non-ASCII path, and a quoted path ends in a quote rather than in its own
# suffix. Against a base, one diff covers the worktree and the index both;
# without one, the two are read separately. Untracked paths are read in
# either case: without them a stop whose only work is an untracked file
# presents an empty changed set and skips the gate entirely.
if [ -n "$BASE" ]; then
  CHANGED=$(git diff --name-only -z "$BASE" 2>&1 | tr '\0' '\n') || git_failed 'diff' "$CHANGED"
  STAGED=""
else
  CHANGED=$(git diff --name-only -z 2>&1 | tr '\0' '\n') || git_failed 'diff' "$CHANGED"
  STAGED=$(git diff --cached --name-only -z 2>&1 | tr '\0' '\n') ||
    git_failed 'diff --cached' "$STAGED"
fi
UNTRACKED=$(git ls-files --others --exclude-standard --full-name -z -- :/ 2>&1 | tr '\0' '\n') ||
  git_failed 'ls-files' "$UNTRACKED"
ALL_CHANGED=$(printf '%s\n%s\n%s' "$CHANGED" "$STAGED" "$UNTRACKED" | sort -u | sed '/^$/d')

if [ -z "$ALL_CHANGED" ]; then
  exit 0
fi

# A markdown path is a doc, whatever directory it sits in. Neither filter may
# stop reading early: under pipefail an early-exiting reader turns the
# producer's SIGPIPE into status 141, read as no match.
CODE_CHANGED=$(printf '%s\n' "$ALL_CHANGED" | sed '/\.md$/d')
if [ -z "$CODE_CHANGED" ]; then
  exit 0
fi

# Covering docs. `:(top)` roots the pattern at the repository whatever the
# cwd, and `*` crosses `/`, so this is every AGENTS.md below the root and
# not the root's own, which covers nothing.
AGENTS_DOCS=$(git ls-files -z --full-name -- ':(top)*/AGENTS.md' 2>&1 | tr '\0' '\n') ||
  git_failed 'ls-files' "$AGENTS_DOCS"

# Topic files are read from the working tree, so a file written this session
# already covers what it says it covers; a tracked one deleted this session
# covers nothing, and is in the changed set besides. Each pair is one line,
# "<dir><TAB><topic path>". An entry of "." would cover the root, which
# nothing does. `set -f` around the split: an entry is split on blanks,
# never globbed, while the topic glob itself still expands.
COVERS=""
for topic in "$REPO_ROOT"/docs/architecture/*.md; do
  [ -f "$topic" ] || continue
  rel="docs/architecture/${topic##*/}"
  entries=$(sed -n 's/^Covers:[[:space:]]*//p' "$topic" | tr ',' ' ')
  set -f
  for dir in $entries; do
    dir="${dir#./}"
    dir="${dir%/}"
    case "$dir" in
      "" | . | /*) continue ;;
    esac
    COVERS="$COVERS$dir"$'\t'"$rel"$'\n'
  done
  set +f
done

# Whole-line fixed-string membership. Never `grep -q`: an early exit turns
# the producer's SIGPIPE into status 141, read here as "absent".
in_list() { # LIST NEEDLE
  printf '%s\n' "$1" | grep -Fx -- "$2" >/dev/null
}

# The covering docs of a changed code path, one per line: the nearest
# AGENTS.md at or above it, and every topic file naming an ancestor.
covering_docs() {
  local dir="$1" nearest="" cdir cdoc
  dir=$(dirname "$dir")
  while [ "$dir" != "." ] && [ "$dir" != "/" ]; do
    if [ -z "$nearest" ] && in_list "$AGENTS_DOCS" "$dir/AGENTS.md"; then
      nearest="$dir/AGENTS.md"
      printf '%s\n' "$nearest"
    fi
    while IFS=$'\t' read -r cdir cdoc; do
      [ "$cdir" = "$dir" ] && printf '%s\n' "$cdoc"
    done <<EOF
$COVERS
EOF
    dir=$(dirname "$dir")
  done
}

# Every doc left unchanged while code it covers changed, with the first such
# path; a doc is named once however many paths reached it.
STALE_DOCS=""
STALE=""
while IFS= read -r path; do
  docs=$(covering_docs "$path")
  [ -n "$docs" ] || continue
  touched=0
  while IFS= read -r doc; do
    if in_list "$ALL_CHANGED" "$doc"; then
      touched=1
      break
    fi
  done <<EOF
$docs
EOF
  [ "$touched" -eq 0 ] || continue
  while IFS= read -r doc; do
    in_list "$STALE_DOCS" "$doc" && continue
    STALE_DOCS="$STALE_DOCS$doc"$'\n'
    STALE="$STALE  $doc ($path changed)"$'\n'
  done <<EOF
$docs
EOF
done <<EOF
$CODE_CHANGED
EOF

if [ -z "$STALE" ]; then
  exit 0
fi

# A block is warranted. Whether this session was already told is in the
# payload, read by jq alone: the keys are top-level, and a text scan finds
# the same characters inside a transcript path or a cwd.
if ! command -v jq >/dev/null 2>&1; then
  printf '%s' "$STALE" >&2
  echo "doc-drift-check: judged $JUDGED" >&2
  echo "doc-drift-check: jq is not on PATH, so the session id cannot be read and this block cannot be recorded. Confirm each doc above still holds or update it, then finish." >&2
  exit 2
fi
if ! ACTIVE=$(printf '%s' "$INPUT" | jq -r '.stop_hook_active == true' 2>&1); then
  echo "doc-drift-check: the hook payload is not valid JSON:" >&2
  printf '%s\n' "$ACTIVE" >&2
  exit 2
fi
if [ "$ACTIVE" = "true" ]; then
  exit 0
fi
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id // ""')
SESSION_SHAPE='^[A-Za-z0-9._-]+$'
if ! [[ "$SESSION" =~ $SESSION_SHAPE ]]; then
  echo "doc-drift-check: the payload carries no usable session_id, so this block cannot be recorded" >&2
  exit 2
fi

# The marker lives under the git COMMON dir so every linked worktree of the
# repository shares it. rev-parse answers relative to the cwd when the dir
# is nearby.
COMMON_DIR=$(git rev-parse --git-common-dir 2>&1) || git_failed 'rev-parse --git-common-dir' "$COMMON_DIR"
case "$COMMON_DIR" in
  /*) ;;
  *) COMMON_DIR="$PWD/$COMMON_DIR" ;;
esac
MARKER_DIR="$COMMON_DIR/kendex/doc-drift"
MARKER="$MARKER_DIR/$SESSION"
if [ -e "$MARKER" ]; then
  exit 0
fi
if ! mkdir -p -- "$MARKER_DIR" || ! : >"$MARKER"; then
  echo "doc-drift-check: could not record the session marker $MARKER, so a second stop could not be told from the first" >&2
  exit 2
fi

echo "doc-drift-check: code changed under directories these docs cover, and none of them changed:" >&2
printf '%s' "$STALE" >&2
echo "doc-drift-check: judged $JUDGED" >&2
echo "Confirm each doc still holds or update it, then finish." >&2
exit 2
