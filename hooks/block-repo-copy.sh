#!/usr/bin/env bash
# ---
# name: block-repo-copy
# event: PreToolUse
# matcher: Bash
# description: Block recursive copies (cp -r/-R/-a, rsync, local git clone, tar pipes) of a source carrying repository history or a build tree into a temp/scratch destination. Suggests reading the source in place or building a minimal fixture.
# safety: Temp destinations are commonly RAM-backed tmpfs; a multi-gigabyte tree copy fills the filesystem and every process writing there then fails with ENOSPC.
# ---

set -euo pipefail

INPUT=$(cat)

# Fast exit on every non-copy Bash call, using bash's builtin regex so the
# common case forks nothing and touches no filesystem.
COPY_VERB_RE='(^|[^[:alnum:]_-])(cp|rsync|tar)([^[:alnum:]_-]|$)|git[[:space:]]+clone'
if [[ ! $INPUT =~ $COPY_VERB_RE ]]; then
  exit 0
fi

if command -v jq >/dev/null 2>&1; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null || true)
else
  COMMAND=$(echo "$INPUT" | grep -o '"command"[[:space:]]*:[[:space:]]*"[^"]*"' | head -1 | sed 's/.*"command"[[:space:]]*:[[:space:]]*"//;s/"$//' 2>/dev/null || true)
fi
[ -n "$COMMAND" ] || exit 0

# Directory names whose presence one level inside the source proves the tree is
# expensive by construction. Checked with -e only: no traversal, no du.
DANGER_MARKERS='.git target node_modules vendor .venv venv .next .cache .gradle Pods'

expand_path() {
  local p="$1"
  case "$p" in
    '~') p="$HOME" ;;
    '~/'*) p="$HOME/${p#\~/}" ;;
  esac
  case "$p" in
    /*) ;;
    *) p="$PWD/$p" ;;
  esac
  printf '%s' "$p"
}

# A path is scratch when it names a temp root literally (including an
# unexpanded variable reference the shell would resolve at run time) or
# resolves under one.
is_scratch() {
  local raw="$1" p base
  case "$raw" in
    *scratchpad*|*'$TMP'*|*'${TMP'*|*mktemp*) return 0 ;;
  esac
  p="$(expand_path "$raw")"
  for base in /tmp /var/tmp "${TMPDIR:-}" "${CLAUDE_CODE_TMPDIR:-}"; do
    [ -n "$base" ] || continue
    base="${base%/}"
    case "$p" in "$base" | "$base"/*) return 0 ;; esac
  done
  return 1
}

# Print the markers that make a source expensive, or return 1 when it has none.
dangerous_markers() {
  local raw="$1" p m found=''
  p="$(expand_path "${raw%/}")"
  [ -d "$p" ] || return 1
  case "${p##*/}" in
    .git | target | node_modules)
      printf '%s' "${p##*/}"
      return 0
      ;;
  esac
  for m in $DANGER_MARKERS; do
    if [ -e "$p/$m" ]; then found="$found, $m"; fi
  done
  if [ -z "$found" ]; then return 1; fi
  printf '%s' "${found#, }"
}

refuse() {
  local src="$1" markers="$2" dest="$3"
  {
    echo "Refusing a recursive copy of an expensive tree into scratch space."
    echo "  command:     $COMMAND"
    echo "  source:      $(expand_path "${src%/}") (contains $markers)"
    echo "  destination: $dest (temp/scratch)"
    echo
    echo "A source carrying repository history or a build tree is large by construction,"
    echo "and temp/scratch filesystems are commonly RAM-backed tmpfs — the copy can fill"
    echo "the filesystem, after which every process writing there fails with ENOSPC."
    echo
    echo "Do one of these instead:"
    echo "  - Read the source in place. Reading does not mutate it, so no copy is needed"
    echo "    to leave it unchanged."
    echo "  - Build a MINIMAL synthetic fixture:"
    echo '      d=$(mktemp -d); mkdir -p "$d/repo/.git" "$d/repo/target"; touch "$d/repo/f"'
  } >&2
  exit 2
}

verdict() {
  local dest="$1" srcs="$2" src markers
  is_scratch "$dest" || return 0
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    markers="$(dangerous_markers "$src")" || continue
    refuse "$src" "$markers" "$dest"
  done <<EOF
$srcs
EOF
}

# Strip quoting and grouping so operands split on whitespace. A path containing
# a space splits into fragments that resolve to nothing and are skipped.
tokenize() {
  printf '%s\n' "$1" | tr -d "\"'" | tr '()' '  ' | tr -s ' \t' '\n' | sed '/^$/d'
}

last_line() { printf '%s' "$1" | sed -n '$p'; }
drop_last_line() { printf '%s' "$1" | sed '$d'; }

# Recognize one cp / rsync / git clone invocation and split it into operands.
# Sets SEG_VERB, SEG_RECURSIVE, SEG_OPERANDS; returns 1 for anything else.
classify_segment() {
  SEG_VERB=''
  SEG_RECURSIVE=0
  SEG_OPERANDS=''
  local tok base pending_git=0 skip_next=0
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    if [ "$skip_next" = 1 ]; then
      skip_next=0
      continue
    fi
    if [ -z "$SEG_VERB" ]; then
      if [ "$pending_git" = 1 ]; then
        case "$tok" in
          clone)
            SEG_VERB=git-clone
            SEG_RECURSIVE=1
            ;;
          -C)
            skip_next=1
            ;;
          -*) ;;
          *) return 1 ;;
        esac
        continue
      fi
      case "$tok" in
        *=*) continue ;;
        sudo | command | env | nohup | time) continue ;;
      esac
      base="${tok##*/}"
      case "$base" in
        cp) SEG_VERB=cp ;;
        rsync) SEG_VERB=rsync ;;
        git) pending_git=1 ;;
        *) return 1 ;;
      esac
      continue
    fi
    case "$tok" in
      --recursive | --archive) SEG_RECURSIVE=1 ;;
      --*) ;;
      -?*)
        # Short clusters. rsync's -R is --relative, not recursion.
        case "$SEG_VERB" in
          cp) case "$tok" in *[rRa]*) SEG_RECURSIVE=1 ;; esac ;;
          rsync) case "$tok" in *[ra]*) SEG_RECURSIVE=1 ;; esac ;;
        esac
        ;;
      *) SEG_OPERANDS="$SEG_OPERANDS$tok
" ;;
    esac
  done <<EOF
$(tokenize "$1")
EOF
  [ -n "$SEG_VERB" ] || return 1
  return 0
}

check_copy_segments() {
  local seg dest srcs count
  while IFS= read -r seg; do
    [ -n "$seg" ] || continue
    classify_segment "$seg" || continue
    [ "$SEG_RECURSIVE" = 1 ] || continue
    count=$(printf '%s' "$SEG_OPERANDS" | grep -c . || true)
    if [ "$SEG_VERB" = git-clone ] && [ "$count" = 1 ]; then
      dest="$PWD"
      srcs="$SEG_OPERANDS"
    else
      [ "${count:-0}" -ge 2 ] || continue
      dest="$(last_line "$SEG_OPERANDS")"
      srcs="$(drop_last_line "$SEG_OPERANDS")"
    fi
    verdict "$dest" "$srcs"
  done <<EOF
$(printf '%s' "$1" | sed 's/&&/\n/g; s/||/\n/g; s/;/\n/g; s/|/\n/g')
EOF
}

# One piped tar stage: its mode (create/extract), its working directory
# (-C or a leading cd), and its non-flag operands.
tar_stage() {
  STAGE_MODE=''
  STAGE_DIR=''
  STAGE_OPERANDS=''
  local tok in_tar=0 want_dir=0 want_file=0 want_cd=0
  while IFS= read -r tok; do
    [ -n "$tok" ] || continue
    if [ "$want_cd" = 1 ]; then
      STAGE_DIR="$tok"
      want_cd=0
      continue
    fi
    if [ "$in_tar" = 0 ]; then
      case "${tok##*/}" in
        cd) want_cd=1 ;;
        tar) in_tar=1 ;;
      esac
      continue
    fi
    if [ "$want_dir" = 1 ]; then
      STAGE_DIR="$tok"
      want_dir=0
      continue
    fi
    if [ "$want_file" = 1 ]; then
      want_file=0
      continue
    fi
    case "$tok" in
      -C) want_dir=1 ;;
      --directory=*) STAGE_DIR="${tok#*=}" ;;
      --create) STAGE_MODE=c ;;
      --extract | --get) STAGE_MODE=x ;;
      --*) ;;
      -?*)
        case "$tok" in *c*) STAGE_MODE=c ;; esac
        case "$tok" in *x*) STAGE_MODE=x ;; esac
        case "$tok" in *f*) want_file=1 ;; esac
        ;;
      # Old-style bundled flags carry no leading dash.
      [cxtrudA]*)
        if [ -z "$STAGE_MODE" ] && [ -z "$(printf '%s' "$tok" | tr -d 'cxvfzjJtC')" ]; then
          case "$tok" in *c*) STAGE_MODE=c ;; esac
          case "$tok" in *x*) STAGE_MODE=x ;; esac
          case "$tok" in *f*) want_file=1 ;; esac
          continue
        fi
        STAGE_OPERANDS="$STAGE_OPERANDS$tok
"
        ;;
      *) STAGE_OPERANDS="$STAGE_OPERANDS$tok
" ;;
    esac
  done <<EOF
$(tokenize "$1")
EOF
  [ -n "$STAGE_MODE" ]
}

check_tar_pipe() {
  local cmd="$1" stage srcs='' dest='' src_dir='' line
  case "$cmd" in *'|'*) ;; *) return 0 ;; esac
  while IFS= read -r stage; do
    [ -n "$stage" ] || continue
    tar_stage "$stage" || continue
    case "$STAGE_MODE" in
      c)
        src_dir="$STAGE_DIR"
        srcs="$STAGE_OPERANDS"
        ;;
      x) dest="${STAGE_DIR:-$PWD}" ;;
    esac
  done <<EOF
$(printf '%s' "$cmd" | sed 's/||/\n/g; s/|/\n/g')
EOF
  { [ -n "$srcs" ] || [ -n "$src_dir" ]; } && [ -n "$dest" ] || return 0
  if [ -n "$src_dir" ]; then
    if [ -z "$srcs" ]; then
      srcs="$src_dir
"
    else
      local resolved=''
      while IFS= read -r line; do
        [ -n "$line" ] || continue
        case "$line" in
          /* | '~'*) resolved="$resolved$line
" ;;
          *) resolved="$resolved${src_dir%/}/$line
" ;;
        esac
      done <<EOF
$srcs
EOF
      srcs="$resolved"
    fi
  fi
  verdict "$dest" "$srcs"
}

check_tar_pipe "$COMMAND"
check_copy_segments "$COMMAND"

exit 0
