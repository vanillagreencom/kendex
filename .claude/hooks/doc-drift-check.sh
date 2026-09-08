#!/usr/bin/env bash
# ---
# name: doc-drift-check
# event: Stop
# matcher:
# description: Shows the user a notice through stdout systemMessage JSON when unchanged documents may need an update after covered code changes. The notice opens with `doc-drift-check: stale=<count>` and `doc-drift-check: base=<ref>` — the ref it compared against, or `default-branch`, `none` or `unrelated` — and lists the documents under them; stdout carries that one object and nothing else. Uses the nearest tracked non-root AGENTS.md and architecture topic Covers entries. Compares the branch with its default-branch merge-base, or the working tree when no comparison applies. Every Stop reports independently. Claude Code only.
# safety: Read-only notice. Always exits 0, including when discovery fails; failures report that the notice is unavailable. Does not parse session payloads or write session state. Every notice opens with `doc-drift-check: <key>=<value>`; what a command this hook runs writes is captured at the site and replayed under that line, so nothing precedes the key.
# timeout: 30
# harnesses: [claude-code]
# ---

set -euo pipefail

# Every line this hook writes, and the only place its text lives. Each begins
# with the stable first line `doc-drift-check: <key>=<value>`: a stable key for
# the condition and the value acted on — the git subcommand that failed, the
# status a discovery command left, or how many documents the notice names. The
# English explanation follows it.
# The keyed line stands first, at position 1. What a command this hook runs
# wrote is captured where the hook reads it and passed here as the cause, so
# it is replayed under the key rather than ahead of it.
#
# The notice itself is a machine-read protocol Claude Code parses: one JSON
# object on stdout, whose single `systemMessage` string key holds the text the
# user is shown. The keyed first line opens that string; nothing else is
# written to stdout, and a second object there is not the protocol.
notice() { # KEY VALUE [DETAIL]
  case "$1" in
    stale)
      # jq's stderr is captured and its stdout left alone: the notice is the
      # protocol on stdout, and a jq that cannot build it reports under the
      # keyed line rather than ahead of it. The swap is the standard one —
      # stderr becomes this substitution's stdout, jq's stdout goes to fd 3.
      exec 3>&1
      JQ_STATUS=0
      JQ_ERR=$(jq -n --arg systemMessage \
        "$(printf 'doc-drift-check: stale=%s\ndoc-drift-check: base=%s\nThese unchanged documents may need an update:\n%sCompared %s\n' \
          "$2" "$BASE_VALUE" "$STALE" "$JUDGED")" '{systemMessage: $systemMessage}' 2>&1 1>&3) || JQ_STATUS=$?
      exec 3>&-
      [ "$JQ_STATUS" -eq 0 ] || notice exit "$JQ_STATUS" "$JQ_ERR"
      ;;
    git)
      {
        printf 'doc-drift-check: git=%s\n' "$2"
        printf 'notice unavailable: git %s failed, so what changed is unknown:\n' "$2"
        printf '%s\n' "${3:-}"
      } >&2
      ;;
    exit)
      {
        printf 'doc-drift-check: exit=%s\n' "$2"
        printf 'notice unavailable: a discovery command exited %s\n' "$2"
        [ -z "${3:-}" ] || printf '%s\n' "$3"
      } >&2
      ;;
  esac
}

# A notice cannot hold a Stop event, including on a failed discovery command.
# Every filter above captures its own words where the hook reads it; this trap
# is the backstop for a command that has none captured, and its keyed line is
# then the first this hook writes.
trap 'status=$?; if [ "$status" -ne 0 ]; then notice exit "$status" || :; fi; exit 0' EXIT

# Doc paths are matched by byte ranges below; a locale that
# reads them as something else changes what a filename may hold.
export LC_ALL=C

git_failed() { # SUBCOMMAND OUTPUT — an unreadable changed set is not an empty one
  notice git "$1" "$2"
  exit 0
}

# Git cannot distinguish an absent repository from unreadable metadata here.
REPO_ROOT=$(git rev-parse --show-toplevel 2>&1) || git_failed 'rev-parse' "$REPO_ROOT"

# What counts as changed is everything the branch did: every path that
# differs between the working tree and the branch's merge-base with the
# default branch, committed or not, plus untracked non-ignored paths. The
# workflow commits before it stops, so a set read off the working tree
# alone is empty at the point this notice runs. On the default branch
# itself, or where no merge-base resolves, the working tree alone is
# judged, and the notice says so.
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

# BASE_VALUE is the arm this hook chose, as a value a reader parses: the ref
# it compared against, or which of the three reasons left it the working tree
# alone. The English below the notice describes the same choice for a person;
# the value is what a consumer reads, so the choice is not carried by prose.
BASE=""
BASE_VALUE=""
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
    *) git_failed 'merge-base' "$BASE" ;;
  esac
fi

# `-z` asks for the paths themselves. Line-oriented git output C-quotes a
# non-ASCII path, and a quoted path ends in a quote rather than in its own
# suffix. Against a base, one diff covers the worktree and the index both;
# without one, the two are read separately. Untracked paths are read in
# either case: without them a stop whose only work is an untracked file
# presents an empty changed set and produces no notice.
if [ -n "$BASE" ]; then
  CHANGED=$(git diff --name-only -z "$BASE" 2>&1 | tr '\0' '\n' 2>&1) || git_failed 'diff' "$CHANGED"
  STAGED=""
else
  CHANGED=$(git diff --name-only -z 2>&1 | tr '\0' '\n' 2>&1) || git_failed 'diff' "$CHANGED"
  STAGED=$(git diff --cached --name-only -z 2>&1 | tr '\0' '\n' 2>&1) ||
    git_failed 'diff --cached' "$STAGED"
fi
UNTRACKED=$(git ls-files --others --exclude-standard --full-name -z -- :/ 2>&1 | tr '\0' '\n' 2>&1) ||
  git_failed 'ls-files' "$UNTRACKED"
# Each filter's own words are captured where the hook reads it: a bare
# assignment would let sort or sed write first and leave the trap's keyed line
# second. Both are silent when they succeed.
ALL_CHANGED=$(printf '%s\n%s\n%s' "$CHANGED" "$STAGED" "$UNTRACKED" | sort -u 2>&1 | sed '/^$/d' 2>&1) || {
  notice exit "$?" "$ALL_CHANGED"
  exit 0
}

if [ -z "$ALL_CHANGED" ]; then
  exit 0
fi

# A markdown path is a doc, whatever directory it sits in. Neither filter may
# stop reading early: under pipefail an early-exiting reader turns the
# producer's SIGPIPE into status 141, read as no match.
CODE_CHANGED=$(printf '%s\n' "$ALL_CHANGED" | sed '/\.md$/d' 2>&1) || {
  notice exit "$?" "$CODE_CHANGED"
  exit 0
}
if [ -z "$CODE_CHANGED" ]; then
  exit 0
fi

# Covering docs. `:(top)` roots the pattern at the repository whatever the
# cwd, and `*` crosses `/`, so this is every AGENTS.md below the root and
# not the root's own, which covers nothing.
AGENTS_DOCS=$(git ls-files -z --full-name -- ':(top)*/AGENTS.md' 2>&1 | tr '\0' '\n' 2>&1) ||
  git_failed 'ls-files' "$AGENTS_DOCS"

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
  # a failed read reaches the notice under its keyed line rather than before
  # it. Both are silent when they succeed.
  entries=$(sed -n 's/^Covers:[[:space:]]*//p' "$topic" 2>&1 | tr ',' ' ' 2>&1) || {
    notice exit "$?" "$entries"
    exit 0
  }
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
STALE=""
STALE_COUNT=0
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

notice stale "$STALE_COUNT"
exit 0
