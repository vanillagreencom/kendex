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
#   neither    GROWTH_GUARDS_MD_SCOPE decides: `touched` (the default) is
#              --staged, and with nothing staged the lane judges nothing
#              and says so; `all` is --all
#
# md-refs widens a triggered check to all configured documents so target edits
# recheck unchanged callers.
#
# Both scopes take the lane's path globs and GROWTH_GUARDS_MD_EXCLUDES, the
# family's `pattern<TAB>reason` list with `!` carve-ins. A symlink, a gitlink
# and a binary blob at a selected path are named as unmeasured, never folded
# into a clean count.

GG_MD_SCOPE_DEFAULT="touched"
GG_MD_EXCLUDES_DEFAULT="tools/md-excludes"

# Resolve the run's scope from the flags and the setting. Sets GG_MD_MODE to
# staged, all, or none — none being the touched scope with nothing staged,
# already announced on stdout.
gg_md_scope() { # LANE STAGED-FLAG ALL-FLAG
  local lane="$1" staged="$2" all="$3" setting
  [ "$staged" -eq 1 ] && [ "$all" -eq 1 ] && gg_config_error "--staged and --all are exclusive"
  if [ "$staged" -eq 1 ]; then
    GG_MD_MODE=staged
    return 0
  fi
  if [ "$all" -eq 1 ]; then
    GG_MD_MODE=all
    return 0
  fi
  setting="$(gg_setting GROWTH_GUARDS_MD_SCOPE "$GG_MD_SCOPE_DEFAULT")" || exit 2
  case "$setting" in
    all)
      GG_MD_MODE=all
      return 0
      ;;
    touched) ;;
    *) gg_config_error "GROWTH_GUARDS_MD_SCOPE must be 'touched' or 'all', got '$(gg_scrubbed "$setting")'" ;;
  esac
  gg_require_merged_index
  if git diff --cached --quiet --diff-filter=AMT 2>/dev/null; then
    GG_MD_MODE=none
    echo "$lane: OK — nothing staged to judge (GROWTH_GUARDS_MD_SCOPE=touched judges the files a commit touches); run with --all, or set GROWTH_GUARDS_MD_SCOPE=all once this repository's markdown is reflowed"
    return 0
  fi
  GG_MD_MODE=staged
}

# Load the lane's path globs and the shared excludes list.
gg_md_load_paths() { # LANE KEY DEFAULT
  local raw excludes
  raw="$(gg_setting "$2" "$3")" || exit 2
  gg_load_path_globs "$raw" "$1" "$2" || exit 2
  excludes="$(gg_resolve_path "" GROWTH_GUARDS_MD_EXCLUDES "$GG_MD_EXCLUDES_DEFAULT" excludes)" || exit 2
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
    *) gg_config_error "gg_md_select: no scope resolved (GG_MD_MODE='$GG_MD_MODE')" ;;
  esac
}

# One selected file: the walk and the staged loop both hand the path, the
# blob file and the sha.
gg_md_take() { # PATH BLOBFILE SHA
  printf '%s\0%s\0' "$3" "$1" >>"$GG_TMP/md-files.z"
  GG_MD_COUNT=$((GG_MD_COUNT + 1))
}

# The phrase a verdict names its scope by.
gg_md_scope_desc() {
  case "$GG_MD_MODE" in
    staged) printf 'staged markdown file(s)' ;;
    all) printf 'tracked markdown file(s)' ;;
  esac
}
