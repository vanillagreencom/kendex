#!/usr/bin/env bash
# ---
# name: doc-drift-check
# event: Stop
# matcher:
# description: Blocks a stop once per set of findings so the agent, the only party that can act on them, is the one given the list. Three kinds are found: stale, a document covering changed code that did not change; dangling, an architecture topic `Covers:` entry that no tracked or untracked non-ignored path on disk matches; uncovered, a changed non-markdown path still on disk that no topic entry and no non-root AGENTS.md covers, judged only where some topic declares an entry and never for a path the repository's `.kendex-generated.json` lists, a render being covered through the source it was rendered from. The refusal opens with one keyed line per kind that holds, in the order `doc-drift-check: stale=<count>`, `doc-drift-check: dangling=<count>`, `doc-drift-check: uncovered=<count>`, then `doc-drift-check: base=<ref>` — the ref it compared against, or `default-branch`, `none` or `unrelated` — and names each finding under them; stdout carries nothing and no user-facing notice is written. The set is recorded as `<git common dir>/kendex/doc-drift/<session_id>-<digest of the sorted set>`, so a later stop naming that same set passes and an agent that read the list and changed nothing is not asked again; a set that gains or loses a finding is a different set and blocks once. `stop_hook_active` true passes, and so does a stop with nothing changed; any change, markdown alone included, has every Covers entry judged. Uses the nearest non-root AGENTS.md, tracked or untracked and not ignored, and architecture topic Covers entries. Compares the branch with its default-branch merge-base, or the working tree when no comparison applies. Claude Code only.
# summary: Stops an agent at the end of its turn when documents covering the code it changed did not change or an architecture topic names a path that does not exist, and hands it the list. Where some topic declares a Covers entry, changed code with no covering document is named too.
# safety: Reads the payload, git state, the topic files, the render inventory `.kendex-generated.json` and git's listing of what each Covers entry matches; the only write is the per-set marker under the repository's git common dir. Exit 2 names the findings and asks for each document to be confirmed or updated and each entry or path to be corrected, never bypassed. jq reads the payload and a sha256 tool names the set; every command the hook runs is checked before it is called, the payload readers ahead of the payload and the rest after `stop_hook_active` has been read, so a discovery command's absence costs one retry rather than refusing the retry too; only a missing payload reader refuses that as well, the flag being in the payload it cannot read. A payload, git state, render inventory or marker the hook cannot read or write is refused, never passed. Every refusal opens with `doc-drift-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
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
# was read against, that same choice in English, and each kind of finding as
# its lines and how many: stale documents, Covers entries that match nothing,
# changed paths no document covers.
BASE_VALUE=""
JUDGED=""
STALE=""
STALE_COUNT=0
DANGLING=""
DANGLING_COUNT=0
UNCOVERED=""
UNCOVERED_COUNT=0
# A refusal has written its own keyed line; the EXIT trap writes one only for a
# status no handler claimed.
REFUSED=0

# Every line this hook writes, and the only place its text lives. The first
# line is the contract a reader parses, `doc-drift-check: <key>=<value>`: a
# stable key for the condition and the value acted on — the missing commands,
# why the payload could not be read, how many findings of a kind are named, the
# git subcommand that failed, the marker path, or the status a discovery
# command left. The English explanation follows it, and never a bypass.
# The keyed line stands first, at position 1; a `drift` refusal writes one per
# kind of finding that holds, in a fixed order, then `base=`. What a command
# this hook runs wrote is captured where the hook reads it and passed here as
# the cause, so it is replayed under the key rather than ahead of it.
#
# The audience is the agent. The documents are work only the agent can do, and
# most sessions in this repository run with nobody watching, so the list goes
# to the channel the harness gives Claude — stderr with exit 2 — and stdout is
# left empty rather than carrying a second copy for a user who cannot act on it.
refuse() { # KEY VALUE [DETAIL], or `drift` alone
  {
    [ "$1" = drift ] || printf 'doc-drift-check: %s=%s\n' "$1" "$2"
    case "$1=${2:-}" in
      drift=)
        [ "$STALE_COUNT" -eq 0 ] || printf 'doc-drift-check: stale=%s\n' "$STALE_COUNT"
        [ "$DANGLING_COUNT" -eq 0 ] || printf 'doc-drift-check: dangling=%s\n' "$DANGLING_COUNT"
        [ "$UNCOVERED_COUNT" -eq 0 ] || printf 'doc-drift-check: uncovered=%s\n' "$UNCOVERED_COUNT"
        printf 'doc-drift-check: base=%s\n' "$BASE_VALUE"
        [ -z "$STALE" ] ||
          printf 'code changed at paths these documents cover, and none of them changed; confirm each still holds or update it:\n%s' "$STALE"
        [ -z "$DANGLING" ] ||
          printf 'these architecture topic Covers entries match no path in the tree, so each covers nothing; correct or remove it:\n%s' "$DANGLING"
        [ -z "$UNCOVERED" ] ||
          printf 'code changed at these paths, and no topic Covers entry or AGENTS.md below the root covers them; add each to the Covers line of the topic that describes it:\n%s' "$UNCOVERED"
        printf 'Compared %s\n' "$JUDGED"
        printf 'Handle each, then finish.\n'
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
      inventory=unreadable)
        printf 'the render inventory .kendex-generated.json is present and could not be read\n'
        ;;
      inventory=invalid-json)
        printf 'the render inventory .kendex-generated.json is not a JSON array of non-empty path strings; refusing rather than judging every render as code no document covers\n'
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

# Every external command this hook runs is checked before it is called: an
# absence the shell reports for itself writes "command not found" ahead of the
# keyed line and leaves a status the harness reads as a plain error rather than
# a refusal. Each value names every command PATH is missing, in the order
# checked.
#
# The two commands that read the payload come first and alone. The flag that
# ends a stop hook's retry is in that payload, so a refusal for any other
# absence has to wait until the flag has been read; refusing ahead of it would
# refuse the retry as well, which is the loop the flag exists to end. These two
# refuse that retry because without them the flag cannot be read at all, and a
# hook that passes what it cannot read is the defect this one is not allowed to
# have.
MISSING=""
for dependency in jq cat; do
  command -v "$dependency" >/dev/null 2>&1 || MISSING="$MISSING,$dependency"
done
[ -z "$MISSING" ] || refuse missing-tools "${MISSING#,}"

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

# The rest of what the hook runs: the commands that read what changed and
# record the set. An absence here refuses this stop, and the retry it costs
# passes at the flag above.
MISSING=""
for dependency in git sed sort tr dirname grep mkdir; do
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

# Every git read that yields paths goes through here, one path per line in
# PATHS. `-z` asks for the paths themselves: line-oriented git output C-quotes a
# non-ASCII path, and a quoted path ends in a quote rather than in its own
# suffix. Only stdout becomes the list. A run that succeeds may still write to
# stderr (core.autocrlf's line-ending warning, the rename limit), and a warning
# read as a path would be named, so git's and tr's stderr are captured apart
# and replayed under the git= key only when the read fails.
git_paths() { # LABEL ARGS... — sets PATHS; LABEL is the git= value on failure
  local label="$1"
  shift
  PATHS=$(
    {
      cause=$( { git "$@" | tr '\0' '\n' >&3; } 2>&1) || {
        printf '%s\n' "$cause"
        exit 1
      }
    } 3>&1
  ) || refuse git "$label" "$PATHS"
}

# The paths present in the tree for one pathspec, one per line in PATHS: tracked
# and untracked non-ignored, as the changed set reads them, and only those on
# disk, since the index still lists a file deleted and not yet staged.
tree_paths() { # PATHSPEC — sets PATHS
  local listed="" path
  git_paths 'ls-files' ls-files -z --cached --others --exclude-standard --full-name -- "$1"
  while IFS= read -r path; do
    [ -z "$path" ] || ! on_disk "$path" || listed="$listed$path"$'\n'
  done <<EOF
$PATHS
EOF
  PATHS=$listed
}

on_disk() { # REPOSITORY-RELATIVE PATH
  [ -e "$REPO_ROOT/$1" ]
}

# Against a base, one diff covers the worktree and the index both; without
# one, the two are read separately. Untracked paths are read in either case:
# without them a stop whose only work is an untracked file presents an empty
# changed set and nothing is named.
STAGED=""
if [ -n "$BASE" ]; then
  git_paths 'diff' diff --name-only -z "$BASE"
  CHANGED=$PATHS
else
  git_paths 'diff' diff --name-only -z
  CHANGED=$PATHS
  git_paths 'diff --cached' diff --cached --name-only -z
  STAGED=$PATHS
fi
git_paths 'ls-files' ls-files --others --exclude-standard --full-name -z -- :/
UNTRACKED=$PATHS
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
# producer's SIGPIPE into status 141, read as no match. A markdown-only change
# still has its Covers entries judged below, since editing a topic is how an
# entry comes to match nothing.
CODE_CHANGED=$(printf '%s\n' "$ALL_CHANGED" | sed '/\.md$/d' 2>&1) ||
  refuse exit "$?" "$CODE_CHANGED"

# What kendex rendered into this repository, one path per line. The render
# writer keeps this inventory and is the one judge of whether a path is a
# render, so the hook reads it rather than matching harness directory names of
# its own. A render is never the thing a document covers — the source it was
# rendered from is — so a changed render is not named uncovered below.
#
# The read discipline is the one commit-guards' suppression-ban applies to the
# same file: an absent inventory is a repository with nothing rendered and
# excludes nothing, while a present one that does not parse is refused rather
# than read as empty, which would name every render as uncovered and say
# nothing about why. It is read from the working tree, as the topic files are:
# a refresh writes the inventory and the renders it lists together, so the
# working-tree copy is the one that describes the renders being judged.
GENERATED=""
INVENTORY="$REPO_ROOT/.kendex-generated.json"
if [ -f "$INVENTORY" ]; then
  # cat's and jq's own words are captured where each is read, so a failure
  # reaches the refusal under its keyed line rather than ahead of it. Both are
  # silent when they succeed.
  INVENTORY_JSON=$(cat -- "$INVENTORY" 2>&1) || refuse inventory unreadable "$INVENTORY_JSON"
  GENERATED=$(printf '%s' "$INVENTORY_JSON" | jq -r '
    if type == "array" and all(.[]; type == "string" and length > 0)
    then .[] else "" | halt_error(21) end' 2>&1) ||
    refuse inventory invalid-json "$GENERATED"
fi

# Covering docs. `:(top)` roots the pattern at the repository whatever the
# cwd, and `*` crosses `/`, so this is every AGENTS.md below the root and
# not the root's own, which covers nothing. Untracked non-ignored ones count,
# as a topic written this session does: a new directory's AGENTS.md covers the
# code beside it before either is committed.
tree_paths ':(top)*/AGENTS.md'
AGENTS_DOCS=$PATHS

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

# Every finding, one per line as `<kind><TAB><what it names>`, is the set the
# marker records. The kind prefix keeps an entry, a path and a document from
# reading as one another.
NAMED=""

# A Covers entry that no path in the tree matches covers nothing, and its topic
# reads as covered while it is not. Git's own pathspec lists what an entry
# reaches, and without `:(glob)` magic it matches as covers_path does: a plain
# path is itself or anything below it, and a glob matches the whole path with
# `*` crossing `/`. One git call per entry, rather than covers_path over every
# file, keeps a large tree inside the hook's timeout.
while IFS=$'\t' read -r covered cdoc; do
  # The empty line the here-document ends on.
  [ -n "$covered" ] || continue
  tree_paths ":(top)$covered"
  [ -z "$PATHS" ] || continue
  member="dangling"$'\t'"$covered"$'\t'"$cdoc"
  in_list "$NAMED" "$member" && continue
  NAMED="$NAMED$member"$'\n'
  DANGLING="$DANGLING  $cdoc (Covers: $covered)"$'\n'
  DANGLING_COUNT=$((DANGLING_COUNT + 1))
done <<EOF
$COVERS
EOF

# Every doc left unchanged while code it covers changed, with the first such
# path; a doc is named once however many paths reached it. A changed path no
# doc covers is named as uncovered only where some topic declares an entry: a
# repository without one has no map to be incomplete, and naming every changed
# path there would block each stop of a repository that never adopted topics.
# A deleted path is never uncovered: an entry added for it would match nothing.
# Nor is a render the inventory lists: the document to correct covers its
# source, and an entry added for the render would name a generated file.
while IFS= read -r path; do
  # An empty code set reads as one empty line.
  [ -n "$path" ] || continue
  docs=$(covering_docs "$path")
  if [ -z "$docs" ]; then
    [ -n "$COVERS" ] || continue
    on_disk "$path" || continue
    in_list "$GENERATED" "$path" && continue
    NAMED="$NAMED"uncovered$'\t'"$path"$'\n'
    UNCOVERED="$UNCOVERED  $path"$'\n'
    UNCOVERED_COUNT=$((UNCOVERED_COUNT + 1))
    continue
  fi
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
    member="stale"$'\t'"$doc"
    in_list "$NAMED" "$member" && continue
    NAMED="$NAMED$member"$'\n'
    STALE="$STALE  $doc ($path changed)"$'\n'
    STALE_COUNT=$((STALE_COUNT + 1))
  done <<EOF
$docs
EOF
done <<EOF
$CODE_CHANGED
EOF

if [ -z "$NAMED" ]; then
  exit 0
fi

SESSION_SHAPE='^[A-Za-z0-9._-]+$'
if ! [[ "$SESSION" =~ $SESSION_SHAPE ]]; then
  refuse session-id invalid
fi

# The marker's name has to tell one set from another, and a path can hold bytes
# a filename cannot, so the set is hashed. The sort is what makes two runs that
# reached the same documents by different paths agree on one name; without it
# the block would repeat for a set already named.
DIGEST=$( { printf '%s' "$NAMED" | sort | hash_set; } 2>&1 ) || refuse exit "$?" "$DIGEST"

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

refuse drift
