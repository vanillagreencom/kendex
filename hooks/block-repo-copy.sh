#!/usr/bin/env bash
# ---
# name: block-repo-copy
# event: PreToolUse
# matcher: Bash
# description: Block recursive copies (cp -r/-R/-a, rsync, local git clone, tar pipes) of a source carrying repository history or a build tree into a temp/scratch destination. Suggests reading the source in place or building a minimal fixture.
# safety: Temp destinations are commonly RAM-backed tmpfs; a multi-gigabyte tree copy fills the filesystem and every process writing there then fails with ENOSPC.
# ---

set -euo pipefail

# Read stdin with the shell builtin so the fast exit below reaches no
# subprocess at all. Payload newlines are JSON-escaped, so joining is lossless.
INPUT=''
_line=''
while IFS= read -r _line || [ -n "$_line" ]; do
  INPUT="$INPUT$_line"
done

# Fast exit on every non-copy Bash call, using bash's builtin regex.
COPY_VERB_RE='(^|[^[:alnum:]_-])(cp|rsync|tar)([^[:alnum:]_-]|$)|git[[:space:]]+clone'
if [[ ! $INPUT =~ $COPY_VERB_RE ]]; then
  exit 0
fi

if command -v jq >/dev/null 2>&1; then
  COMMAND=$(printf '%s' "$INPUT" | jq -r '.tool_input.command // .command // ""' 2>/dev/null || true)
else
  # Escape-aware: the value runs to the first quote not preceded by a
  # backslash, so an embedded \" no longer truncates the command.
  COMMAND=$(printf '%s' "$INPUT" \
    | grep -oE '"command"[[:space:]]*:[[:space:]]*"(\\.|[^"\\])*"' \
    | head -1 \
    | sed 's/.*"command"[[:space:]]*:[[:space:]]*"//; s/"$//' \
    | sed 's/\\n/ /g; s/\\t/ /g; s/\\"/"/g; s/\\\\/\\/g' 2>/dev/null || true)
fi
# A guard that cannot read its own input must not allow the call. A payload
# that carries no command at all is not a copy and passes; one that names a
# command the decoder could not recover is refused, because the destination
# can never be established.
if [ -z "$COMMAND" ]; then
  case "$INPUT" in
    *'"command"'*)
      {
        echo "Refusing a Bash call whose payload could not be read."
        echo "  payload: $INPUT"
        echo
        echo "The payload names a command but it could not be decoded, so this hook"
        echo "cannot tell whether it copies a repository or build tree into scratch"
        echo "space. Re-issue the command with a well-formed payload."
      } >&2
      exit 2
      ;;
    *) exit 0 ;;
  esac
fi

# Directory names whose presence one level inside the source proves the tree is
# expensive by construction. Checked with -e only: no traversal, no du.
DANGER_MARKERS='.git target node_modules vendor .venv venv .next .cache .gradle Pods'

# Options that consume the following token, per verb. Without these a value
# like the 1 in `--depth 1` is counted as an operand and shifts which token is
# read as the destination.
CP_ARG_OPTS='-t -S --suffix --target-directory'
RSYNC_ARG_OPTS='-e -f -B -T -M --rsh --exclude --include --exclude-from --include-from --files-from --filter --chmod --log-file --bwlimit --partial-dir --link-dest --copy-dest --compare-dest --timeout --contimeout --port --block-size --modify-window --max-size --min-size --out-format --suffix --backup-dir --temp-dir --address --sockopts --write-batch --read-batch --protocol --iconv --checksum-seed --max-delete --skip-compress --compress-level --info --debug --usermap --groupmap --chown --remote-option'
GIT_ARG_OPTS='-b -o -j -c -u --depth --branch --origin --reference --reference-if-able --separate-git-dir --jobs --filter --config --upload-pack --template --shallow-since --shallow-exclude --server-option --bundle-uri --revision'

in_list() {
  local needle="$1" item
  for item in $2; do
    [ "$needle" = "$item" ] && return 0
  done
  return 1
}

expand_path() {
  local p="$1" base="${2:-$PWD}"
  # Temp roots named by variable resolve to the directory they stand for.
  p="${p//\$\{CLAUDE_CODE_TMPDIR\}/${CLAUDE_CODE_TMPDIR:-/tmp}}"
  p="${p//\$CLAUDE_CODE_TMPDIR/${CLAUDE_CODE_TMPDIR:-/tmp}}"
  p="${p//\$\{TMPDIR\}/${TMPDIR:-/tmp}}"
  p="${p//\$TMPDIR/${TMPDIR:-/tmp}}"
  case "$p" in
    '~') p="$HOME" ;;
    '~/'*) p="$HOME/${p#\~/}" ;;
  esac
  case "$p" in
    /*) ;;
    *) p="${base%/}/$p" ;;
  esac
  printf '%s' "$p"
}

# Variables assigned a scratch path earlier in the same command, so a
# destination written as "$d" is classified by what $d was set to.
SCRATCH_VARS=''

# A path is scratch when it names a temp root literally, is written as a
# variable that resolves to one, or resolves under one.
is_scratch() {
  local raw="$1" base="${2:-$PWD}" p root name
  case "$raw" in
    *scratchpad* | *mktemp* | *'$TMP'* | *'${TMP'*) return 0 ;;
  esac
  name="$raw"
  case "$name" in
    '${'*)
      name="${name#\$\{}"
      name="${name%%\}*}"
      ;;
    '$'*)
      name="${name#\$}"
      name="${name%%/*}"
      ;;
    *) name='' ;;
  esac
  if [ -n "$name" ] && in_list "$name" "$SCRATCH_VARS"; then
    return 0
  fi
  p="$(expand_path "$raw" "$base")"
  for root in /tmp /var/tmp "${TMPDIR:-}" "${CLAUDE_CODE_TMPDIR:-}"; do
    [ -n "$root" ] || continue
    root="${root%/}"
    case "$p" in "$root" | "$root"/*) return 0 ;; esac
  done
  return 1
}

# Print the markers that make a source expensive, or return 1 when it has none.
dangerous_markers() {
  local raw="$1" base="${2:-$PWD}" p m found=''
  p="$(expand_path "${raw%/}" "$base")"
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
  local src="$1" markers="$2" dest="$3" base="$4"
  {
    echo "Refusing a recursive copy of an expensive tree into scratch space."
    echo "  command:     $COMMAND"
    echo "  source:      $(expand_path "${src%/}" "$base") (contains $markers)"
    echo "  destination: $(expand_path "$dest" "$base") (temp/scratch)"
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
  local dest="$1" srcs="$2" base="$3" src markers
  is_scratch "$dest" "$base" || return 0
  while IFS= read -r src; do
    [ -n "$src" ] || continue
    markers="$(dangerous_markers "$src" "$base")" || continue
    refuse "$src" "$markers" "$dest" "$base"
  done <<EOF
$srcs
EOF
}

# --- tokenizer ---------------------------------------------------------------
# Split the command into tokens honoring quotes, so a path containing a space
# stays one operand instead of splitting into fragments that resolve to
# nothing. Command substitutions are kept whole so an inline $(mktemp -d) stays
# visible. List and pipeline separators become SEP lines, which is what lets a
# leading `cd` be attributed to the commands that follow it.
SEP=$'\001'

tokenize() {
  local s="$1" n i ch tok='' out='' q='' depth
  n=${#s}
  i=0
  while [ "$i" -lt "$n" ]; do
    ch="${s:i:1}"
    if [ "$q" = "'" ]; then
      if [ "$ch" = "'" ]; then q=''; else tok="$tok$ch"; fi
      i=$((i + 1))
      continue
    fi
    if [ "$q" = '"' ]; then
      if [ "$ch" = '"' ]; then
        q=''
      elif [ "$ch" = '\' ]; then
        i=$((i + 1))
        tok="$tok${s:i:1}"
      else
        tok="$tok$ch"
      fi
      i=$((i + 1))
      continue
    fi
    case "$ch" in
      "'" | '"') q="$ch" ;;
      '\')
        i=$((i + 1))
        tok="$tok${s:i:1}"
        ;;
      '$')
        if [ "${s:i+1:1}" = '(' ]; then
          depth=1
          tok="$tok\$("
          i=$((i + 2))
          while [ "$i" -lt "$n" ] && [ "$depth" -gt 0 ]; do
            ch="${s:i:1}"
            case "$ch" in
              '(') depth=$((depth + 1)) ;;
              ')') depth=$((depth - 1)) ;;
            esac
            if [ "$depth" -gt 0 ]; then tok="$tok$ch"; fi
            i=$((i + 1))
          done
          tok="$tok)"
          continue
        fi
        tok="$tok$ch"
        ;;
      ' ' | $'\t')
        if [ -n "$tok" ]; then
          out="$out$tok"$'\n'
          tok=''
        fi
        ;;
      '&' | '|' | ';' | $'\n' | '(' | ')')
        if [ -n "$tok" ]; then
          out="$out$tok"$'\n'
          tok=''
        fi
        out="$out$SEP"$'\n'
        ;;
      *) tok="$tok$ch" ;;
    esac
    i=$((i + 1))
  done
  if [ -n "$tok" ]; then out="$out$tok"$'\n'; fi
  printf '%s' "$out"
}

TOKENS="$(tokenize "$COMMAND")"

# Any variable assigned a scratch path is itself a scratch name from here on.
while IFS= read -r tok; do
  case "$tok" in
    [A-Za-z_]*=*)
      name="${tok%%=*}"
      value="${tok#*=}"
      case "$name" in
        *[!A-Za-z0-9_]*) continue ;;
      esac
      if [ -n "$value" ] && is_scratch "$value"; then
        SCRATCH_VARS="$SCRATCH_VARS $name"
      fi
      ;;
  esac
done <<EOF
$TOKENS
EOF

last_line() { printf '%s' "$1" | sed -n '$p'; }
drop_last_line() { printf '%s' "$1" | sed '$d'; }

# --- cp / rsync / git clone --------------------------------------------------
# Recognize one invocation and split it into operands. Sets SEG_VERB,
# SEG_RECURSIVE, SEG_OPERANDS, SEG_DEST (set only by an explicit
# target-directory option); returns 1 for anything else.
classify_segment() {
  SEG_VERB=''
  SEG_RECURSIVE=0
  SEG_OPERANDS=''
  SEG_DEST=''
  local tok base pending_git=0 skip_next=0 arg_opts=''
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
            arg_opts="$GIT_ARG_OPTS"
            ;;
          -C) skip_next=1 ;;
          -*) ;;
          *) return 1 ;;
        esac
        continue
      fi
      case "$tok" in
        [A-Za-z_]*=*) continue ;;
        command | env | nohup | sudo | time) continue ;;
      esac
      base="${tok##*/}"
      case "$base" in
        cp)
          SEG_VERB=cp
          arg_opts="$CP_ARG_OPTS"
          ;;
        rsync)
          SEG_VERB=rsync
          arg_opts="$RSYNC_ARG_OPTS"
          ;;
        git) pending_git=1 ;;
        *) return 1 ;;
      esac
      continue
    fi
    case "$tok" in
      --target-directory=*) SEG_DEST="${tok#*=}" ;;
      --recursive | --archive) SEG_RECURSIVE=1 ;;
      --*)
        if in_list "$tok" "$arg_opts"; then skip_next=1; fi
        ;;
      -?*)
        # cp -t DIR: every operand is a source and DIR is the destination.
        # rsync's -t is --times and its -R is --relative, so neither applies.
        if [ "$SEG_VERB" = cp ] && [ "$tok" = "-t" ]; then
          SEG_DEST='@next@'
          continue
        fi
        if in_list "$tok" "$arg_opts"; then
          skip_next=1
          continue
        fi
        case "$SEG_VERB" in
          cp) case "$tok" in *[rRa]*) SEG_RECURSIVE=1 ;; esac ;;
          rsync) case "$tok" in *[ra]*) SEG_RECURSIVE=1 ;; esac ;;
        esac
        # A cp short cluster can carry the target flag, as in -rt DIR.
        if [ "$SEG_VERB" = cp ]; then
          case "$tok" in
            --*) ;;
            *t*) SEG_DEST='@next@' ;;
          esac
        fi
        ;;
      *)
        if [ "$SEG_DEST" = '@next@' ]; then
          SEG_DEST="$tok"
        else
          SEG_OPERANDS="$SEG_OPERANDS$tok
"
        fi
        ;;
    esac
  done <<EOF
$1
EOF
  [ -n "$SEG_VERB" ] || return 1
  [ "$SEG_DEST" != '@next@' ] || SEG_DEST=''
  return 0
}

# --- tar stages --------------------------------------------------------------
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
$1
EOF
  [ -n "$STAGE_MODE" ]
}

# --- walk the command --------------------------------------------------------
# Segments are visited in order so a `cd` updates the base directory that later
# relative operands resolve against.
BASE_DIR="$PWD"
SEGMENT=''
TAR_SRCS=''
TAR_SRC_DIR=''
TAR_SRC_BASE=''
TAR_DEST=''

flush_segment() {
  local seg="$1" first target dest srcs count
  [ -n "$seg" ] || return 0

  first="$(printf '%s' "$seg" | sed -n '1p')"
  if [ "${first##*/}" = cd ]; then
    target="$(printf '%s' "$seg" | sed -n '2p')"
    if [ -n "$target" ]; then BASE_DIR="$(expand_path "$target" "$BASE_DIR")"; fi
  fi

  if tar_stage "$seg"; then
    case "$STAGE_MODE" in
      c)
        TAR_SRC_DIR="$STAGE_DIR"
        TAR_SRCS="$STAGE_OPERANDS"
        TAR_SRC_BASE="$BASE_DIR"
        ;;
      x) TAR_DEST="$(expand_path "${STAGE_DIR:-.}" "$BASE_DIR")" ;;
    esac
  fi

  classify_segment "$seg" || return 0
  [ "$SEG_RECURSIVE" = 1 ] || return 0

  count=$(printf '%s' "$SEG_OPERANDS" | grep -c . || true)
  if [ -n "$SEG_DEST" ]; then
    dest="$SEG_DEST"
    srcs="$SEG_OPERANDS"
  elif [ "$SEG_VERB" = git-clone ] && [ "${count:-0}" = 1 ]; then
    dest="$BASE_DIR"
    srcs="$SEG_OPERANDS"
  else
    [ "${count:-0}" -ge 2 ] || return 0
    dest="$(last_line "$SEG_OPERANDS")"
    srcs="$(drop_last_line "$SEG_OPERANDS")"
  fi
  verdict "$dest" "$srcs" "$BASE_DIR"
}

while IFS= read -r tok; do
  if [ "$tok" = "$SEP" ]; then
    flush_segment "$SEGMENT"
    SEGMENT=''
    continue
  fi
  SEGMENT="$SEGMENT$tok
"
done <<EOF
$TOKENS
EOF
flush_segment "$SEGMENT"

# A tar create stage feeding a tar extract stage is one copy across two
# segments, so it is judged after the whole command has been walked.
if [ -n "$TAR_DEST" ] && { [ -n "$TAR_SRCS" ] || [ -n "$TAR_SRC_DIR" ]; }; then
  SRC_BASE="${TAR_SRC_BASE:-$PWD}"
  if [ -n "$TAR_SRC_DIR" ]; then
    SRC_BASE="$(expand_path "$TAR_SRC_DIR" "$SRC_BASE")"
  fi
  if [ -z "$TAR_SRCS" ]; then TAR_SRCS="$SRC_BASE"$'\n'; fi
  verdict "$TAR_DEST" "$TAR_SRCS" "$SRC_BASE"
fi

exit 0
