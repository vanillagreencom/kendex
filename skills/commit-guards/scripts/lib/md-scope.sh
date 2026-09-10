# shellcheck shell=bash
# The scope the markdown lanes share: which files a run judges, and where it
# reads them. Sourced by md-format, md-refs and md-reflow after lib/common.sh
# and lib/settings.sh; the caller runs under `set -f`, has cd'd to the
# repository root, and calls gg_tmpdir before selecting.
#
# Three scopes, one setting:
#   --staged   every markdown file the staged diff adds, modifies or
#              type-changes, renames held to exact content as byte-ceiling
#              holds them, judged in full from the index
#   --all      every tracked markdown file matching the lane's path globs
#   neither    COMMIT_GUARDS_MD_SCOPE decides: `touched` (the default) is
#              --staged, and with nothing staged the lane judges nothing
#              and says so; `all` is --all. gg_md_bare_scope reports which,
#              for a caller that has to know before running the lane
#
# md-refs widens a triggered check to all configured documents so target edits
# recheck unchanged callers.
#
# Both scopes take the lane's path globs and COMMIT_GUARDS_MD_EXCLUDES, the
# family's `pattern<TAB>reason` list with `!` carve-ins. A symlink, a gitlink
# and a binary blob at a selected path are named as unmeasured, never folded
# into a clean count.

GG_MD_SCOPE_DEFAULT="touched"
GG_MD_EXCLUDES_DEFAULT="tools/md-excludes"

# What a run with no scope flag resolves to, without resolving it.
#
# Two callers. gg_md_scope below, so the setting is read once and the answer
# and the run cannot disagree. And a batch caller that needs to know, BEFORE
# running a lane, whether a bare run would open any file: `touched` selects
# from the staged diff and opens none where nothing is staged, while `all`
# needs nothing staged and sweeps the tree. A caller that inferred that from
# the lane merely deferring to this file would withhold a lane the project
# explicitly asked to run over everything.
#
# Side-effect-free: it prints nothing, reads no index and leaves GG_MD_MODE
# alone, so it needs neither `set -f` nor gg_tmpdir — only the repository
# root, which every settings read needs. An invalid value is refused here
# rather than by each caller, so the refusal has one spelling; the refusal
# runs in the CALLER's shell, which is why the answer comes back in a
# variable rather than on stdout.
gg_md_bare_scope() { # VAR — VAR gets touched or all; refuses anything else
  local __v="$1" value=""
  value="$(gg_setting COMMIT_GUARDS_MD_SCOPE "$GG_MD_SCOPE_DEFAULT")" || exit 2
  case "$value" in
    all | touched) ;;
    *) gg_fail scope "$value" "COMMIT_GUARDS_MD_SCOPE must be touched or all." ;;
  esac
  eval "$__v=\$value"
}

# Resolve the run's scope from the flags and the setting. Sets GG_MD_MODE to
# staged, all, or none — none being the touched scope with nothing staged,
# already announced on stdout.
gg_md_scope() { # LANE STAGED-FLAG ALL-FLAG
  local lane="$1" staged="$2" all="$3" setting
  [ "$staged" -eq 1 ] && [ "$all" -eq 1 ] && gg_fail scope-flags "--staged,--all" "The scope flags are exclusive."
  if [ "$staged" -eq 1 ]; then
    GG_MD_MODE=staged
    return 0
  fi
  if [ "$all" -eq 1 ]; then
    GG_MD_MODE=all
    return 0
  fi
  gg_md_bare_scope setting
  case "$setting" in
    all)
      GG_MD_MODE=all
      return 0
      ;;
  esac
  gg_require_merged_index
  if git diff --cached --quiet --diff-filter=AMT 2>/dev/null; then
    GG_MD_MODE=none
    gg_message staged-count 0 "Nothing is staged for $lane. Use --all to check the configured files."
    return 0
  fi
  GG_MD_MODE=staged
}

# Load the lane's path globs and the shared excludes list.
gg_md_load_paths() { # LANE KEY DEFAULT
  local raw excludes
  raw="$(gg_setting "$2" "$3")" || exit 2
  gg_load_path_globs "$raw" "$1" "$2" || exit 2
  excludes="$(gg_resolve_path "" COMMIT_GUARDS_MD_EXCLUDES "$GG_MD_EXCLUDES_DEFAULT" excludes)" || exit 2
  gg_load_excludes "$excludes"
}

# The selected files, as alternating "sha NUL path NUL" records in
# $GG_TMP/md-files.z, every one a text blob the lane may read. Sets
# GG_MD_COUNT; the skips are counted in GG_WALK_SKIPPED.
gg_md_select() { # NOUN — what the lane calls its content, for the skip lines
  local noun="$1"
  GG_MD_COUNT=0
  : >"$GG_TMP/md-files.z"
  case "$GG_MD_MODE" in
    all)
      gg_walk_configured_paths "$noun" file gg_md_take
      ;;
    staged)
      gg_walk_staged_paths "$noun" gg_md_take
      ;;
    *) gg_fail unresolved-scope "$GG_MD_MODE" "The Markdown selector requires a resolved scope." ;;
  esac
}

# One selected file: the walk and the staged loop both hand the path, the
# blob file and the sha.
gg_md_take() { # PATH BLOBFILE SHA
  printf '%s\0%s\0' "$3" "$1" >>"$GG_TMP/md-files.z"
  GG_MD_COUNT=$((GG_MD_COUNT + 1))
}

# Present the shared block-parser enum without putting prose in its records.
gg_md_block_message() { # RULE PATH LINE — sets GG_MD_RULE and GG_MD_DETAIL
  local rule="$1" path="$2" line="$3"
  GG_MD_RULE="${rule%%:*}"
  GG_MD_DETAIL="$path:$line"
  case "$rule" in
    block-unclosed:*) GG_MD_DETAIL="$GG_MD_DETAIL:${rule#*:}" ;;
  esac
  case "$GG_MD_RULE" in
    heading-before) GG_MD_EXPLANATION="Put a blank line before the heading." ;;
    heading-after) GG_MD_EXPLANATION="Put a blank line after the heading." ;;
    fence-before) GG_MD_EXPLANATION="Put a blank line before the fence." ;;
    fence-after) GG_MD_EXPLANATION="Put a blank line after the fence." ;;
    list-before) GG_MD_EXPLANATION="Put a blank line before the list." ;;
    paragraph-wrap) GG_MD_EXPLANATION="Put the whole paragraph on one line." ;;
    item-wrap) GG_MD_EXPLANATION="Put the whole list item on one line." ;;
    trailing-space) GG_MD_EXPLANATION="Remove the trailing double-space break." ;;
    crlf) GG_MD_EXPLANATION="Use LF line endings. The file cannot be read past this line." ;;
    fence-unclosed) GG_MD_EXPLANATION="Close the fence before the file ends." ;;
    front-unclosed) GG_MD_EXPLANATION="Close the front matter before the file ends." ;;
    html-unclosed | block-unclosed) GG_MD_EXPLANATION="Close the block before the file ends." ;;
    *) gg_fail block-rule "$rule" "The block parser returned an unknown rule." ;;
  esac
}
