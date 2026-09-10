#!/usr/bin/env bash
# ---
# name: doc-drift-check
# event: Stop
# matcher:
# description: Blocks a stop once per set of stale documents — the documents covering changed code that did not change — so the agent, the only party that can update them, is the one given the list. The refusal opens with `doc-drift-check: stale=<count>` and `doc-drift-check: base=<ref>` — the ref it compared against, or `default-branch`, `none` or `unrelated` — and names each document under them; stdout carries nothing and no user-facing notice is written. The set is recorded as `<git common dir>/kendex/doc-drift/<session_id>-<digest of the sorted set>`, so a later stop naming that same set passes and an agent that read the list and changed nothing is not asked again; a set that gains or loses a document is a different set and blocks once. `stop_hook_active` true passes. Uses the nearest tracked non-root AGENTS.md and architecture topic Covers entries. Compares the branch with its default-branch merge-base, or the working tree when no comparison applies. Claude Code only.
# safety: Reads the payload, git state and the topic files; the only write is the per-set marker under the repository's git common dir. Exit 2 names the documents and asks for each to be confirmed or updated, never bypassed. jq reads the payload and a sha256 tool names the set; every command the hook runs is checked before anything is judged, and a payload, git state or marker it cannot read or write is refused, never passed. Every refusal opens with `doc-drift-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 30
# harnesses: [claude-code]
# ---

set -euo pipefail

# Session ids and doc paths are matched by byte ranges below; a locale that
# reads them as something else changes what a filename may hold. The sort that
# feeds the digest reads them the same way, so the locale also decides which
# set two runs agree on.
export LC_ALL=C

# What the refusals name, empty until each is known: which base the changed set
# was read against, that same choice in English, the documents themselves and
# how many, and the marker that records having named them.
BASE_VALUE=""
JUDGED=""
STALE=""
STALE_COUNT=0
# A refusal has written its own keyed line; the EXIT trap writes one only for a
# status no handler claimed.
REFUSED=0

# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `doc-drift-check: <key>=<value>`: a
# stable key for the condition and the value acted on — the missing commands,
# why the payload could not be read, how many documents are named, the git
# subcommand that failed, the marker path, or the status a discovery command
# left. The English explanation follows it, and never a bypass.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so it
# is replayed under the key rather than ahead of it.
#
# The audience is the agent. The documents are work only the agent can do, and
# most sessions in this repository run with nobody watching, so the list goes
# to the channel the harness gives Claude — stderr with exit 2 — and stdout is
# left empty rather than carrying a second copy for a user who cannot act on it.
refuse() { # KEY VALUE [DETAIL]
  {
    printf 'doc-drift-check: %s=%s\n' "$1" "$2"
    case "$1=$2" in
      stale=*)
        printf 'doc-drift-check: base=%s\n' "$BASE_VALUE"
        printf 'code changed at paths these documents cover, and none of them changed:\n'
        printf '%s' "$STALE"
        printf 'Compared %s\n' "$JUDGED"
        printf 'Confirm each document still holds or update it, then finish.\n'
        ;;
      missing-tools=*)
        printf '%s\n' "the commands ${2//,/, } are required to read the payload, the git state and the documents and are not on PATH; refusing rather than skipping the check. sha256sum stands for it or shasum, either of which names the set"
        ;;
      payload=unreadable)
        printf 'the hook payload could not be read from stdin\n'
        ;;
      payload=invalid-json)
        printf 'the hook payload is not valid JSON, or a field it reads is not a string; refusing rather than skipping the check\n'
        ;;
      session-id=invalid)
        printf 'the payload carries no usable session_id, so naming these documents could not be recorded; refusing\n'
        ;;
      marker=*)
        printf 'the marker %s could not be recorded, so a second stop could not be told from the first\n' "$2"
        ;;
      git=*)
        printf 'git %s failed, so what changed is unknown:\n' "$2"
        ;;
      exit=*)
        printf 'a discovery command exited %s\n' "$2"
        ;;
    esac
    # The cause a command this hook ran wrote, captured at the site and
    # replayed here: under the keyed line, never ahead of it.
    [ -z "${3:-}" ] || printf '%s\n' "$3"
  } >&2
  REFUSED=1
  exit 2
}

# A status no handler claimed still reports under a keyed line: errexit ends the
# script where a helper died, and this is the backstop for one whose own words
# were not captured at the site.
trap 'status=$?; if [ "$status" -ne 0 ] && [ "$REFUSED" -eq 0 ]; then refuse exit "$status"; fi' EXIT

# Every external command this hook runs, checked before anything is judged: an
# absence the shell reports for itself writes "command not found" ahead of the
# keyed line and leaves a status the harness reads as a plain error rather than
# a refusal. The value names every one PATH is missing, in the order checked.
MISSING=""
for dependency in jq git cat sed sort tr dirname grep mkdir; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
# macOS ships shasum and no sha256sum; either one names the set.
HASH_TOOL=""
if command -v sha256sum >/dev/null 2>&1; then
  HASH_TOOL=sha256sum
elif command -v shasum >/dev/null 2>&1; then
  HASH_TOOL=shasum
else
  MISSING="$MISSING,sha256sum"
fi
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"

hash_set() { # the set on stdin; its digest and the reader's own trailing word
  if [ "$HASH_TOOL" = sha256sum ]; then
    sha256sum
  else
    shasum -a 256
  fi
}

# cat's words are captured, not left to precede the refusal: on failure the
# substitution holds what it wrote, and the refusal replays it under the keyed
# line. A cat that succeeds is silent, so the payload is not mixed with a
# diagnostic on the passing side.
INPUT=$(cat 2>&1) || refuse payload unreadable "$INPUT"

# The session names the reader being told, and jq alone reads it: the keys are
# top-level, and a text scan finds the same characters inside a transcript path
# or a cwd. jq's own words are captured where a failure would otherwise write
# them ahead of the keyed line; a jq that answers writes none.
FIELDS=$(printf '%s' "$INPUT" | jq -r '
  def str($v): if $v == null then "" elif ($v | type) == "string" then $v else error("not a string") end;
  [str(.session_id), (.stop_hook_active == true | tostring)] | @tsv' 2>&1) ||
  refuse payload invalid-json "$FIELDS"
TAB=$'\t'
SESSION=${FIELDS%%"$TAB"*}
ACTIVE=${FIELDS#*"$TAB"}

# The harness sets stop_hook_active on the turn it continued because a stop
# hook blocked. Refusing that turn as well is the loop the flag exists to end,
# and the harness caps a hook that does it anyway.
if [ "$ACTIVE" = "true" ]; then
  exit 0
fi

# Git cannot distinguish an absent repository from unreadable metadata here.
REPO_ROOT=$(git rev-parse --show-toplevel 2>&1) || refuse git 'rev-parse' "$REPO_ROOT"

# What counts as changed is everything the branch did: every path that
# differs between the working tree and the branch's merge-base with the
# default branch, committed or not, plus untracked non-ignored paths. The
# workflow commits before it stops, so a set read off the working tree
# alone is empty at the point this hook runs. On the default branch
# itself, or where no merge-base resolves, the working tree alone is
# judged, and the refusal says so.
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
    *) refuse git "$1" "$REF" ;;
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

# BASE_VALUE is the arm this hook chose, as a value a reader parses: the ref
# it compared against, or which of the three reasons left it the working tree
# alone. The English below it describes the same choice for a person; the
# value is what a consumer reads, so the choice is not carried by prose.
BASE=""
if [ -z "$DEFAULT" ]; then
  BASE_VALUE=none
  JUDGED="the working tree alone: no origin/HEAD, main or master to compare against"
elif [ "$CURRENT" = "${DEFAULT#origin/}" ]; then
  BASE_VALUE=default-branch
  JUDGED="the working tree alone: $CURRENT is the default branch"
else
  rc=0
  BASE=$(git merge-base HEAD "$DEFAULT" 2>&1) || rc=$?
  case "$rc" in
    0)
      BASE_VALUE="$DEFAULT"
      JUDGED="every change since $BASE, the merge-base with $DEFAULT"
      ;;
    1)
      BASE=""
      BASE_VALUE=unrelated
      JUDGED="the working tree alone: HEAD shares no history with $DEFAULT"
      ;;
    *) refuse git 'merge-base' "$BASE" ;;
  esac
fi

# `-z` asks for the paths themselves. Line-oriented git output C-quotes a
# non-ASCII path, and a quoted path ends in a quote rather than in its own
# suffix. Against a base, one diff covers the worktree and the index both;
# without one, the two are read separately. Untracked paths are read in
# either case: without them a stop whose only work is an untracked file
# presents an empty changed set and nothing is named.
if [ -n "$BASE" ]; then
  CHANGED=$(git diff --name-only -z "$BASE" 2>&1 | tr '\0' '\n' 2>&1) || refuse git 'diff' "$CHANGED"
  STAGED=""
else
  CHANGED=$(git diff --name-only -z 2>&1 | tr '\0' '\n' 2>&1) || refuse git 'diff' "$CHANGED"
  STAGED=$(git diff --cached --name-only -z 2>&1 | tr '\0' '\n' 2>&1) ||
    refuse git 'diff --cached' "$STAGED"
fi
UNTRACKED=$(git ls-files --others --exclude-standard --full-name -z -- :/ 2>&1 | tr '\0' '\n' 2>&1) ||
  refuse git 'ls-files' "$UNTRACKED"
# Each filter's own words are captured where the hook reads it: a bare
# assignment would let sort or sed write first and leave the trap's keyed line
# second. Both are silent when they succeed.
ALL_CHANGED=$(printf '%s\n%s\n%s' "$CHANGED" "$STAGED" "$UNTRACKED" | sort -u 2>&1 | sed '/^$/d' 2>&1) ||
  refuse exit "$?" "$ALL_CHANGED"

if [ -z "$ALL_CHANGED" ]; then
  exit 0
fi

# A markdown path is a doc, whatever directory it sits in. Neither filter may
# stop reading early: under pipefail an early-exiting reader turns the
# producer's SIGPIPE into status 141, read as no match.
CODE_CHANGED=$(printf '%s\n' "$ALL_CHANGED" | sed '/\.md$/d' 2>&1) ||
  refuse exit "$?" "$CODE_CHANGED"
if [ -z "$CODE_CHANGED" ]; then
  exit 0
fi

# Covering docs. `:(top)` roots the pattern at the repository whatever the
# cwd, and `*` crosses `/`, so this is every AGENTS.md below the root and
# not the root's own, which covers nothing.
AGENTS_DOCS=$(git ls-files -z --full-name -- ':(top)*/AGENTS.md' 2>&1 | tr '\0' '\n' 2>&1) ||
  refuse git 'ls-files' "$AGENTS_DOCS"

# Topic files are read from the working tree, so a file written this session
# already covers what it says it covers; a tracked one deleted this session
# covers nothing, and is in the changed set besides. Each pair is one line,
# "<path pattern><TAB><topic path>". An entry of "." would cover the root, which
# nothing does. `set -f` around the split: an entry is split on blanks,
# never globbed, while the topic glob itself still expands.
COVERS=""
for topic in "$REPO_ROOT"/docs/architecture/*.md; do
  [ -f "$topic" ] || continue
  rel="docs/architecture/${topic##*/}"
  # sed and tr write their own reason where their output would have gone, so
  # a failed read reaches the refusal under its keyed line rather than before
  # it. Both are silent when they succeed.
  entries=$(sed -n 's/^Covers:[[:space:]]*//p' "$topic" 2>&1 | tr ',' ' ' 2>&1) ||
    refuse exit "$?" "$entries"
  set -f
  for covered in $entries; do
    covered="${covered#./}"
    covered="${covered%/}"
    case "$covered" in
      "" | . | /*) continue ;;
    esac
    COVERS="$COVERS$covered"$'\t'"$rel"$'\n'
  done
  set +f
done

# Whole-line fixed-string membership. Never `grep -q`: an early exit turns
# the producer's SIGPIPE into status 141, read here as "absent".
in_list() { # LIST NEEDLE
  printf '%s\n' "$1" | grep -Fx -- "$2" >/dev/null
}

# One matcher for every Covers entry. A plain path covers itself and anything
# below it; that makes a file exact because a file cannot have descendants.
# A shell glob matches the whole repository-relative changed path, and `*`
# crosses `/` as it does in the other kendex path settings.
covers_path() { # ENTRY PATH
  local entry="$1" path="$2"
  [ "$path" = "$entry" ] && return 0
  case "$path" in "$entry"/*) return 0 ;; esac
  # $entry must stay unquoted here so shell glob syntax remains active.
  # shellcheck disable=SC2254
  case "$path" in $entry) return 0 ;; esac
  return 1
}

# The covering docs of a changed code path, one per line: the nearest
# AGENTS.md at or above it, and every topic file whose entry matches it.
covering_docs() {
  local path="$1" dir nearest="" covered cdoc
  while IFS=$'\t' read -r covered cdoc; do
    covers_path "$covered" "$path" && printf '%s\n' "$cdoc"
  done <<EOF
$COVERS
EOF
  dir=$(dirname "$path")
  while [ "$dir" != "." ] && [ "$dir" != "/" ]; do
    if [ -z "$nearest" ] && in_list "$AGENTS_DOCS" "$dir/AGENTS.md"; then
      nearest="$dir/AGENTS.md"
      printf '%s\n' "$nearest"
    fi
    dir=$(dirname "$dir")
  done
}

# Every doc left unchanged while code it covers changed, with the first such
# path; a doc is named once however many paths reached it.
STALE_DOCS=""
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
    STALE_COUNT=$((STALE_COUNT + 1))
  done <<EOF
$docs
EOF
done <<EOF
$CODE_CHANGED
EOF

if [ -z "$STALE" ]; then
  exit 0
fi

SESSION_SHAPE='^[A-Za-z0-9._-]+$'
if ! [[ "$SESSION" =~ $SESSION_SHAPE ]]; then
  refuse session-id invalid
fi

# The marker's name has to tell one stale set from another, and a doc path can
# hold bytes a filename cannot, so the set is hashed. The sort is what makes
# two runs that reached the same documents by different paths agree on one
# name; without it the block would repeat for a set already named.
DIGEST=$( { printf '%s' "$STALE_DOCS" | sort | hash_set; } 2>&1 ) || refuse exit "$?" "$DIGEST"

# The marker lives under the git COMMON dir so every linked worktree of the
# repository shares it. rev-parse answers relative to the cwd when the dir
# is nearby.
COMMON_DIR=$(git rev-parse --git-common-dir 2>&1) ||
  refuse git 'rev-parse --git-common-dir' "$COMMON_DIR"
case "$COMMON_DIR" in
  /*) ;;
  *) COMMON_DIR="$PWD/$COMMON_DIR" ;;
esac
MARKER_DIR="$COMMON_DIR/kendex/doc-drift"
MARKER="$MARKER_DIR/$SESSION-${DIGEST%% *}"
if [ -e "$MARKER" ]; then
  exit 0
fi
# Both probes are captured rather than left to write first: the group runs the
# redirection in a subshell so the shell's own "cannot create" reaches the same
# variable mkdir's message would.
if ! MARKER_ERR=$(mkdir -p -- "$MARKER_DIR" 2>&1) ||
  ! MARKER_ERR=$( { : >"$MARKER"; } 2>&1 ); then
  refuse marker "$MARKER" "$MARKER_ERR"
fi

refuse stale "$STALE_COUNT"
