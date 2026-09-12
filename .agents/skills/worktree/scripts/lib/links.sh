#!/usr/bin/env bash
# Worktree link management: the symlinks a worktree gets from WORKTREE_SYMLINKS,
# the info/exclude entries that keep them out of `git status`, the health
# reports over them, and the repair paths that rebuild them after a rebase
# materializes the harness directory.
#
# Sourced by scripts/worktree after lib/messages.sh and lib/kendex-env.sh: the
# refusals here call worktree_message and the paths come from the loaded project
# configuration. The git-hook auto-repair installer stays in that script, beside
# the hook text it writes.

# Idempotently append a worktree-relative path to the COMMON git-dir's
# info/exclude so git treats the symlink we lay down as ignored content.
# Required because .gitignore patterns with a trailing slash (e.g. `.agents/`)
# match only real directories, not symlinks pointing at directories — without
# the exclude entry, `git status` lists the symlink as untracked and
# `worktree remove` refuses without --force. Git does NOT consult the
# per-worktree git-dir's info/exclude; only the common dir's is read
# (https://git-scm.com/docs/gitignore#_pattern_format), so we must write
# there.
#
# That shared file is the problem this function has to work around. The
# entry is meant for a SYMLINK in a worktree, but it lands in a file every
# checkout of the repo reads — including main, where the same path is a REAL
# directory. A bare `harness` entry therefore marks that whole directory ignored
# in main, and `git add harness/tracked-file` starts refusing with "The
# following paths are ignored by one of your .gitignore files" while `git
# status` still lists the file as modified. It outlives the worktree, too.
#
# The fix uses the very asymmetry documented above: a TRAILING-SLASH pattern
# matches a real directory but NOT a symlink pointing at one. So when the path
# has tracked content, follow the bare entry with `!<path>/`, which re-includes
# the real directory in main while leaving the worktree's symlink ignored. Order
# matters — gitignore takes the LAST matching pattern — so the negation is
# always rewritten after the bare entry.
#
# The negation is written ONLY when the path actually holds tracked files.
# Runtime-only paths (the common case — kendex's own `.agents` mirror is hidden
# in main by this entry alone, with no .gitignore rule behind it) must keep the
# plain blanket entry, or main fills with untracked noise. The condition is
# re-evaluated on every call, so a path that gains or loses tracked content
# self-heals in both directions.
#
# Other tools write to this file too (Claude Code writes its own `**/.claude/*`
# entries), so only our own exact lines are ever written or removed.
exclude_from_worktree_index() {
  local wt="$1" path="$2" has_tracked="${3:-false}"
  [[ -z "$path" ]] && return 0
  local common_dir info_exclude negation tmp
  common_dir="$(git -C "$wt" rev-parse --git-common-dir 2>/dev/null)" || return 0
  info_exclude="$common_dir/info/exclude"
  negation="!$path/"
  mkdir -p "$(dirname "$info_exclude")"

  # Drop any existing negation first: when it is still wanted it gets appended
  # below, which also guarantees it sits AFTER the bare entry.
  if [[ -f "$info_exclude" ]] && grep -qxF "$negation" "$info_exclude" 2>/dev/null; then
    tmp="$info_exclude.wt-tmp.$$"
    if grep -vxF "$negation" "$info_exclude" > "$tmp" 2>/dev/null; then
      mv "$tmp" "$info_exclude"
    else
      rm -f "$tmp" 2>/dev/null
    fi
  fi

  grep -qxF "$path" "$info_exclude" 2>/dev/null || echo "$path" >> "$info_exclude"
  [[ "$has_tracked" == true ]] && echo "$negation" >> "$info_exclude"
  return 0
}

# Replace "$2" with a symlink to "$1" without ever leaving "$2" absent.
#
# The naive `rm` + `ln` pair has an observable window between the two calls in
# which the destination exists in neither state, so a crash, a signal, or a
# concurrent reader lands on a missing path. Building the link under a
# temp name in the same directory and renaming it over the destination closes
# that window: rename(2) is atomic and replaces the old entry in place.
#
# The destination must NOT be followed when it is a symlink to a directory —
# which is the normal steady state here, since these links point at dirs like
# `.agents`. A plain `mv` would deposit the temp link *inside* the target. GNU
# spells "treat the destination as a plain name" as `mv -T`, BSD/macOS spells
# it `mv -h`, and neither accepts the other's flag; try both so this works on
# the Bash 3.2 / BSD-userland macOS boxes the skill supports.
#
# Returns non-zero WITHOUT touching the destination when neither flag is
# available, so callers fall back to rm+ln.
atomic_symlink_swap() {
  local src="$1" dst="$2" tmp
  tmp="$dst.wt-tmp.$$"
  rm -f "$tmp" 2>/dev/null
  ln -s "$src" "$tmp" 2>/dev/null || return 1
  if mv -T "$tmp" "$dst" 2>/dev/null || mv -h "$tmp" "$dst" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

# The one untracked child COPIED into the worktree, not symlinked:
# a regular file named .gitignore. Git refuses to read .gitignore through a
# symlink ("unable to access ...: Too many levels of symbolic links") and
# applies none of its rules, so whatever main's file ignores becomes stageable
# and `git add -A` commits it. The repair path and both detectors share this
# predicate so they agree by construction. $1 is the name, $2 its path in main.
is_copied_ignore_child() {
  [[ "$1" == .gitignore && -f "$2" ]]
}

# Drift policy: main owns the file. Every create/fix-links/auto-repair pass
# re-copies when the content differs, so a change on main reaches the
# worktrees next pass and an edit to the worktree copy is overwritten. The
# copy is the tool's own artifact, not user data, so the
# never-overwrite rule does not apply; a symlink at the path is replaced the
# same way. It gets the info/exclude entry a symlink gets: main's file is
# untracked, so nothing else hides the copy when it does not ignore itself.
ignore_file_copy_matches() {
  local src="$1" dst="$2"
  [[ -f "$dst" && ! -L "$dst" ]] && cmp -s "$src" "$dst"
}

copy_ignore_file_into_worktree() {
  local wt="$1" path="$2"
  local src="$PROJECT_ROOT/$path" dst="$wt/$path" tmp="" err="" effect=""
  ensure_worktree_path_safe "$wt" "$path" false || return 1
  exclude_from_worktree_index "$wt" "$path" false
  ignore_file_copy_matches "$src" "$dst" && return 0
  if [[ -d "$dst" && ! -L "$dst" ]]; then
    worktree_message ignore-copy-directory "$wt/$path" "Warning: '$path' in $wt is a directory where main's .gitignore should be copied; leaving it alone." >&2
    return 1
  fi
  # Built beside the destination and renamed over it (atomic_symlink_swap's
  # GNU -T / BSD -h pair, no delete-first fallback), so a reader never finds
  # the path absent; rename(2) replaces a symlink destination, not its target.
  # The temp name is cleared first: cp writes THROUGH a stale symlink there.
  tmp="$dst.wt-tmp.$$"
  rm -f "$tmp" 2>/dev/null
  if err="$(cp "$src" "$tmp" 2>&1)" &&
     { err="$(mv -T "$tmp" "$dst" 2>&1)" || err="$(mv -h "$tmp" "$dst" 2>&1)"; }; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  effect="its ignore rules are not applied there"
  [[ -f "$dst" && ! -L "$dst" ]] && effect="the previous copy stays in effect, not main's current rules"
  worktree_message ignore-copy-failed "$wt/$path" "Warning: could not copy '$path' into $wt (${err:-no diagnostic}); $effect." >&2
  return 1
}

# Sets $CIE_EXACT and $CIE_DESCENDANTS (non-empty = true) for whether $rel is
# tracked as an exact leaf entry (file, symlink, or gitlink), or has tracked
# descendants beneath it, in $repo's index.
#
# NUL-delimited throughout: git's default `ls-files` output quotes
# names containing quotes, backslashes, tabs, or non-ASCII bytes (e.g. prints
# `"a\"b"` for a file literally named `a"b`), so comparing that display form
# against the raw filesystem name with `grep -Fx` silently mismatches those
# names — misclassifying a tracked leaf as untracked and symlinking over it.
# `-z` output is never quoted, so the NUL-split entries can be compared
# byte-for-byte against $rel.
classify_index_entry() {
  local repo="$1" rel="$2" hit=""
  CIE_EXACT=""
  CIE_DESCENDANTS=""
  while IFS= read -r -d '' hit; do
    if [[ "$hit" == "$rel" ]]; then
      CIE_EXACT=1
    else
      CIE_DESCENDANTS=1
    fi
  done < <(git -C "$repo" ls-files -z -- ":(literal)$rel" 2>/dev/null)
}

# The one child walk under a WORKTREE_SYMLINKS entry. The repair that lays the
# per-child links down and the two diagnostics that judge them differ only in
# what they do with a classified child, so the glob set, the exists-or-symlink
# filter and the both-index classification live here alone: spelled once per
# pass, a diagnostic could classify a child differently from the repair that
# just created it and disagree with the shape on disk.
#
# The visitor is called for each child as
#   <visitor> "$wt" "$rel" "$name" "$child" "$exact" "$descendants" "$depth"
# with $exact set when $rel is a tracked leaf in EITHER index and $descendants
# when either tracks something beneath it. Recursion and the depth cap stay
# with the visitor. The walk is ALWAYS 0: no pass reads a visitor's status --
# the repair banks unsettled children in LUC_UNRESOLVED, the diagnostics print
# theirs -- so a failing visitor cannot take the repair down through set -e.
walk_symlink_entry_children() {
  local visitor="$1" path="$2" wt="$3" depth="$4"
  local src="$PROJECT_ROOT/$path" child="" name="" rel="" exact="" descendants=""
  for child in "$src"/* "$src"/.[!.]* "$src"/..?*; do
    [[ -e "$child" || -L "$child" ]] || continue
    name="${child##*/}"
    rel="$path/$name"
    classify_index_entry "$wt" "$rel"
    exact="$CIE_EXACT"; descendants="$CIE_DESCENDANTS"
    classify_index_entry "$PROJECT_ROOT" "$rel"
    [[ -n "$CIE_EXACT" ]] && exact=1
    [[ -n "$CIE_DESCENDANTS" ]] && descendants=1
    "$visitor" "$wt" "$rel" "$name" "$child" "$exact" "$descendants" "$depth" || true
  done
  return 0
}

# link_untracked_children's visitor: decide one classified child, and append
# to that call's LUC_UNRESOLVED the ones this pass could not settle. The
# classification is read, never re-derived from the filesystem type of $child:
# [[ -d ]] follows symlinks, so a tracked symlink whose target is a directory
# would be misread as a mixed tracked directory and recursed into, and the
# recursive call would replace that tracked symlink with a real one.
link_untracked_child() {
  local wt="$1" rel="$2" name="$3" child="$4" exact="$5" descendants="$6" depth="$7"
  if [[ -z "$exact" && -z "$descendants" ]] && is_copied_ignore_child "$name" "$child"; then
    copy_ignore_file_into_worktree "$wt" "$rel" || LUC_UNRESOLVED="$LUC_UNRESOLVED  - $rel (copy failed — see warning above)"$'\n'
  elif [[ -z "$exact" && -z "$descendants" ]]; then
    # Nothing tracked here: ordinary symlink treatment, own exclude entry.
    # This child may have materialized with untracked user data since the last
    # repair, so apply the same content check as a top-level entry.
    repair_materialized_path "$wt" "$rel" || LUC_UNRESOLVED="$LUC_UNRESOLVED  - $rel (linking failed or blocked — see warning above)"$'\n'
  elif [[ -n "$exact" ]]; then
    # A tracked leaf is git's — here, or on main and not yet merged here. A
    # symlink would collide with the checkout's copy or with that merge.
    :
  else
    local nest_reason="nested link failure"
    [[ $((depth + 1)) -ge 8 ]] && nest_reason="nested past the 8-level depth limit"
    link_untracked_children "$rel" "$wt" $((depth + 1)) || LUC_UNRESOLVED="$LUC_UNRESOLVED  - $rel ($nest_reason — see warning above)"$'\n'
  fi
  return 0
}

# Provision a WORKTREE_SYMLINKS directory entry that shadows tracked paths by
# linking its UNTRACKED children individually. Linking the parent wholesale
# would force the tracked files underneath it assume-unchanged, leaving git
# unable to WRITE them in the worktree: checkout/merge/cherry-pick touching the
# tracked subtree fails while `git status` looks clean, and a PR updating that
# subtree cannot be taken in any worktree. So the entry stays a REAL
# directory, tracked paths stay real files git owns, and each
# untracked child gets the ordinary symlink treatment — recursing into children
# that mix tracked and untracked content. Same result as hand-enumerating the
# untracked subpaths in WORKTREE_SYMLINKS, with nothing to maintain per
# consumer (a newly installed skill is linked on the next create/repair).
link_untracked_children() {
  local path="$1" wt="$2" depth="${3:-0}"
  local dst="$wt/$path"
  local f="" restore_failed=false
  local -a shadowed=()
  # link_untracked_child appends each unresolved child here. `local` keeps
  # recursion honest: a nested call shadows this copy and restores it on return.
  local LUC_UNRESOLVED=""

  # Symlinked sources make the tracked/untracked walk cyclic; eight levels is
  # far beyond any real layout, so deeper nesting is reported, not resolved.
  if [[ "$depth" -ge 8 ]]; then
    worktree_message link-depth-exceeded "$path" "Warning: WORKTREE_SYMLINKS entry '$path' nests tracked content deeper than 8 levels; its children were not linked." >&2
    return 1
  fi

  # A parent link over this entry hides the tracked files and holds their
  # assume-unchanged bits: undo both, then restore only the tracked files that
  # are MISSING — a blanket checkout of the pathspec would also revert files
  # the branch legitimately modified.
  # NUL-delimited throughout: a line-oriented list, or piping it through
  # xargs, breaks on filenames with spaces, tabs, or quotes, silently leaving
  # their assume-unchanged bit set. `xargs -r` is also GNU-only and unavailable
  # on the BSD userland this script supports.
  while IFS= read -r -d '' f; do
    shadowed[${#shadowed[@]}]="$f"
  done < <(git -C "$wt" ls-files -z -- "$path/" 2>/dev/null)
  if [[ -L "$dst" ]] && ! rm -f "$dst" 2>/dev/null; then
    worktree_message link-unshadow-failed "$wt/$path" "Warning: could not replace the '$path' symlink in $wt with a real directory; its tracked files stay shadowed." >&2
    return 1
  fi
  if ! mkdir -p "$dst" 2>/dev/null; then
    worktree_message link-directory-failed "$wt/$path" "Warning: could not create '$path' in $wt; tracked files under it may be missing." >&2
    return 1
  fi
  if [[ ${#shadowed[@]} -gt 0 ]]; then
    # Failures here are not swallowed: a locked index or unwritable
    # destination must surface as a blocked repair, not a silent success —
    # callers (repair_worktree_links, the auto-repair hooks) key their own
    # success reporting off this function's return value.
    if ! git -C "$wt" update-index --no-assume-unchanged -- "${shadowed[@]}" 2>/dev/null; then
      worktree_message index-flags-failed "$wt/$path" "Warning: could not clear the assume-unchanged bit on tracked file(s) under '$path' in $wt; they may still be hidden from git writes." >&2
      restore_failed=true
    fi
    for f in "${shadowed[@]}"; do
      [[ ! -e "$wt/$f" && ! -L "$wt/$f" ]] || continue
      if ! git -C "$wt" checkout -- "$f" 2>/dev/null; then
        worktree_message index-restore-failed "$wt/$f" "Warning: could not restore tracked file '$f' under '$path' in $wt from the index; it may be missing." >&2
        restore_failed=true
      fi
    done
  fi

  # A failed tracked-restore leaves this entry's git-owned state unknown;
  # proceeding to (re)link children around it would layer further writes on a
  # worktree the heal could not bring to a known-good base. Leave the entry
  # exactly as found (the warnings above name what failed) and re-signal —
  # repair-links is the retry.
  if [[ "$restore_failed" == true ]]; then
    worktree_message child-links-deferred "$wt/$path" "Warning: skipping child linking under '$path' in $wt until the tracked restore above succeeds; re-run repair-links." >&2
    return 1
  fi

  walk_symlink_entry_children link_untracked_child "$path" "$wt" "$depth"

  # restore_failed returned early above; only unresolved children reach here.
  if [[ -n "$LUC_UNRESOLVED" ]]; then
    {
      worktree_message child-links-unresolved "$path" "Warning: WORKTREE_SYMLINKS entry '$path' shadows tracked paths and these children could not be resolved:"
      printf '%s' "$LUC_UNRESOLVED"
      echo "  Tracked paths were left to git; narrow the entry to the untracked subpaths to silence this."
    } >&2
    return 1
  fi
  return 0
}

symlink_into_worktree() {
  local path="$1" wt="$2"
  local src="$PROJECT_ROOT/$path"
  local dst="$wt/$path"

  # Every worktree-local symlink we create should be invisible to git status
  # in this worktree, regardless of whether the source dir has tracked files.
  ensure_worktree_path_safe "$wt" "$path" false || return 1
  if [[ -f "$src" && -e "$dst" && ! -L "$dst" && ! -f "$dst" ]]; then
    worktree_message file-link-nonfile "$wt/$path" "Error: refusing to replace non-file worktree path '$path' with a file symlink." >&2
    return 1
  fi
  # Whether this path holds tracked content decides the SHAPE of the exclude
  # entry: a path with tracked files needs the `!<path>/` negation so the
  # real directory in the main checkout stays stageable. Covers both the file
  # entry and the directory's contents, so it is computed once here rather than
  # separately in each branch below.
  #
  # Ask BOTH indexes. The damage this guards against lands in the main checkout,
  # so main is the authority — a worktree branch that predates the commit which
  # started tracking the path would otherwise report "untracked" and leave main
  # broken. Either index seeing tracked content is enough: the negation only
  # re-includes a REAL directory, so it is inert in a worktree where the path is
  # a symlink.
  local tracked_here=false
  if [[ -n "$(git -C "$wt" ls-files -- "$path" "$path/" 2>/dev/null || true)" ]] ||
     [[ -n "$(git -C "$PROJECT_ROOT" ls-files -- "$path" "$path/" 2>/dev/null || true)" ]]; then
    tracked_here=true
  fi
  exclude_from_worktree_index "$wt" "$path" "$tracked_here"

  if [[ -f "$src" ]]; then
    # File symlink — if the path is tracked in the worktree (a project that
    # commits its harness config files), mark it assume-unchanged
    # so replacing it with a symlink does not leave a noisy typechange.
    if git -C "$wt" ls-files --error-unmatch "$path" >/dev/null 2>&1; then
      # The bit is cosmetic: the link below is correct without it, so a failure
      # warns rather than refusing. Discarding the status instead would leave
      # the operator reading a typechange with nothing naming its cause.
      local assume_rc=0
      git -C "$wt" update-index --assume-unchanged "$path" 2>/dev/null || assume_rc=$?
      [[ "$assume_rc" -eq 0 ]] ||
        worktree_message assume-unchanged-failed "$wt/$path" "Warning: git update-index --assume-unchanged exited $assume_rc for '$path'; it stays visible as a typechange in git status." >&2
    fi
    mkdir -p "$(dirname "$dst")"
    if [[ -e "$dst" && ! -L "$dst" && ! -f "$dst" ]]; then
      worktree_message file-link-nonfile "$wt/$path" "Error: refusing to replace non-file worktree path '$path' with a file symlink." >&2
      return 1
    fi
    # File/symlink destinations can be replaced by rename with no window at all.
    atomic_symlink_swap "$src" "$dst" || { rm -f "$dst"; ln -s "$src" "$dst"; }
  elif [[ -d "$src" ]]; then
    # Directory entry. When this worktree tracks files under it, linking the
    # parent would shadow them (assume-unchanged leaves git unable to WRITE
    # them: cherry-pick/checkout/merge fail while `git status` looks clean, and
    # tracked files under a symlinked dir are the generator of link clobbering
    # — a rebase that must write them replaces the symlink with a real
    # directory). Act on the detection instead: keep the entry a real
    # directory and link only its untracked children.
    # Ask BOTH indexes (the exclude-entry shape above does the same):
    # a worktree branch that predates the commit which started tracking this
    # path sees nothing in its own index, but main tracking it is still enough
    # reason to reserve the real-directory shape now, before the merge that
    # brings the tracked content into this branch lands. Restoring files below
    # still reads only the worktree's own index — main's content isn't checked
    # out here yet.
    local shadowed=false
    if [[ -n "$(git -C "$wt" ls-files -- ":(literal)$path/" 2>/dev/null)" ]] ||
       [[ -n "$(git -C "$PROJECT_ROOT" ls-files -- ":(literal)$path/" 2>/dev/null || true)" ]]; then
      shadowed=true
    fi
    if [[ "$shadowed" == true ]]; then
      link_untracked_children "$path" "$wt"
      return $?
    fi

    mkdir -p "$(dirname "$dst")"
    # A REAL directory here (rebase replaces symlinks with real directories when
    # tracked files exist underneath) cannot be replaced by rename, so it still
    # has to be removed first and that window is unavoidable. Everything else —
    # including the normal case, a symlink to a directory — goes through the
    # atomic swap. Where the removal is needed, the replacement link is already
    # built, so the gap is a single rename rather than an rm plus a symlink.
    if [[ -d "$dst" && ! -L "$dst" ]]; then
      rm -rf "$dst" 2>/dev/null
    fi
    atomic_symlink_swap "$src" "$dst" || { rm -rf "$dst" 2>/dev/null; ln -sfn "$src" "$dst"; }
  fi
}

# Detect a materialized harness directory at USE time.
#
# A rebase replaces a configured symlink with a real directory holding only the
# tracked files underneath it, dropping every kendex-installed path there. The
# worktree then looks clean to git — `git status` reports nothing, so
# `git checkout --` is a no-op — and the damage only surfaces later as scripts
# failing exit 127 on files the link had provided.
#
# This is deliberately a WARNING, not a failure: the command the operator asked
# for may not touch the affected paths, and a hard error would be a failure
# for them. It runs at the points where materialization has just become likely
# (post-rebase). The stock post-checkout/post-merge/post-rewrite hooks also
# auto-repair (see install_worktree_autorepair_hooks); this warning is the
# backstop for repos where the hooks could not be installed. `core.hooksPath`
# is the wrong mechanism either way: it replaces the hooks directory wholesale
# and would disable the consumer's own hooks.
# Recurse through a tracked-content WORKTREE_SYMLINKS entry the same way
# link_untracked_children does, printing (one per line) any untracked child
# that should be a symlink but is a real path instead. warn_if_links_
# materialized's parent-only check treats "real directory with tracked
# content underneath" as proof the whole entry is healthy, but a rebase or
# checkout can materialize just an untracked CHILD several levels down while
# leaving the tracked files at the top untouched — that damage needs the same
# per-child walk to surface.
collect_materialized_child_links() {
  local path="$1" wt="$2" depth="${3:-0}"
  # Depth-capped like link_untracked_children, but reporting rather than
  # repairing: a silent "no damage found" past the cap would give
  # warn_if_links_materialized a false-negative "healthy" verdict for a
  # subtree with a materialized child in it. Emit a line the caller folds
  # into its own warning instead.
  if [[ "$depth" -ge 8 ]]; then
    printf '%s (nests deeper than 8 levels — not inspected)\n' "$path"
    return 1
  fi
  walk_symlink_entry_children collect_materialized_child "$path" "$wt" "$depth"
}

# collect_materialized_child_links' visitor. Damage is an untracked child that
# should be a link and is a real path instead; everything else is silence. A
# capped deeper subtree prints an uninspected line; no status comes back.
collect_materialized_child() {
  local wt="$1" rel="$2" name="$3" child="$4" exact="$5" descendants="$6" depth="$7"
  if [[ -z "$exact" && -z "$descendants" ]]; then
    # A copied child is a real file by design; fix-links judges its content.
    is_copied_ignore_child "$name" "$child" && return 0
    [[ -e "$wt/$rel" && ! -L "$wt/$rel" ]] && printf '%s\n' "$rel"
    return 0
  fi
  [[ -n "$exact" ]] && return 0  # a tracked leaf is git's; only mixed content recurses
  collect_materialized_child_links "$rel" "$wt" $((depth + 1))
}

# One expected symlink, judged by its actual SHAPE: it must be a symlink and it
# must resolve to the target this command would have given it. Absent and
# wrong-target are unhealthy too — those are exactly the states that re-trigger
# the sync error naming fix-links as its remediation.
report_link_health() {
  local wt="$1" rel="$2" want="$3" actual=""
  if [[ -L "$wt/$rel" ]]; then
    actual="$(readlink "$wt/$rel" 2>/dev/null || true)"
    [[ "$actual" == "$want" ]] && return 0
    printf '%s (a symlink to %s, expected %s)\n' "$rel" "${actual:-<unreadable>}" "$want"
    return 0
  fi
  if [[ -e "$wt/$rel" ]]; then
    printf '%s (still a real path, not a link)\n' "$rel"
  else
    printf '%s (absent)\n' "$rel"
  fi
}

# Health check for the untracked children of a tracked-content WORKTREE_SYMLINKS
# entry, which setup keeps as a real directory with per-child links. Mirrors
# link_untracked_children's index classification so this agrees with what the
# repair path actually creates.
#
# collect_materialized_child_links cannot serve here: it is a MATERIALIZATION
# detector, emitting an untracked child only when one exists as a non-symlink.
# An absent child and a child linked somewhere wrong both read healthy through
# it, which is the same false success this postcondition exists to stop.
collect_unhealthy_child_links() {
  local path="$1" wt="$2" depth="${3:-0}"
  # Depth-capped like link_untracked_children. Reporting the cap rather
  # than returning silently: an uninspected subtree is not a healthy one.
  if [[ "$depth" -ge 8 ]]; then
    printf '%s (nests deeper than 8 levels — not inspected)\n' "$path"
    return 0
  fi
  # Reporting only: every unhealthy child is a printed line, never a status,
  # so this stays 0 for the command substitutions that read it under set -e.
  walk_symlink_entry_children collect_unhealthy_child "$path" "$wt" "$depth"
  return 0
}

# collect_unhealthy_child_links' visitor: one child judged against the shape
# the repair path would have given it.
collect_unhealthy_child() {
  local wt="$1" rel="$2" name="$3" child="$4" exact="$5" descendants="$6" depth="$7"
  # A tracked leaf: git owns it and no link belongs here.
  [[ -n "$exact" ]] && return 0
  if [[ -n "$descendants" ]]; then
    collect_unhealthy_child_links "$rel" "$wt" $((depth + 1))
    return 0
  fi
  if is_copied_ignore_child "$name" "$child"; then
    # Healthy is a real file with main's content; a symlink is the shape git
    # refuses to read, stale content the drift the repair pass closes.
    ignore_file_copy_matches "$child" "$wt/$rel" && return 0
    if [[ -L "$wt/$rel" ]]; then
      printf '%s (a symlink, expected a copy of main'"'"'s .gitignore)\n' "$rel"
    elif [[ -e "$wt/$rel" ]]; then
      printf '%s (differs from main'"'"'s .gitignore)\n' "$rel"
    else
      printf '%s (absent)\n' "$rel"
    fi
    return 0
  fi
  report_link_health "$wt" "$rel" "$PROJECT_ROOT/$rel"
}

# Postcondition for `fix-links`: name every configured entry that is NOT in
# its healthy shape, one per line. Reporting only — it changes nothing, and is
# silent when everything is healthy.
#
# The repair path's return codes cannot gate the success message: an entry can
# be skipped before any repair is attempted (no such path in the main
# checkout), and an unsafe materialized entry is left in place. A "Restored
# symlinks" through either would keep the sync error naming fix-links as its
# remediation firing, looping the operator on it. Judging the RESULT covers
# whatever mechanism leaves a path unrestored, not only those two.
#
# Scope: the link shapes this command creates — WORKTREE_SYMLINKS and
# WORKTREE_RELATIVE_SYMLINKS. WORKTREE_MKDIRS and WORKTREE_COPIES are not link
# shapes and are left to setup_worktree_links' own checked return.
collect_unrestored_links() {
  local wt="$1" path="" spec="" target=""
  [[ -n "$wt" && -d "$wt" ]] || return 0
  validate_worktree_setup_config >/dev/null 2>&1 || return 0

  split_worktree_config_words "${WORKTREE_SYMLINKS:-}"
  for path in ${WORKTREE_CONFIG_WORDS[@]+"${WORKTREE_CONFIG_WORDS[@]}"}; do
    path="$(normalize_worktree_config_path WORKTREE_SYMLINKS "$path" 2>/dev/null)" || continue
    if [[ ! -e "$PROJECT_ROOT/$path" ]]; then
      # setup skips this entry entirely; outside a node_modules entry it prints
      # nothing, so only this line names it.
      printf '%s (no such path in the main checkout — create it there, or drop it from WORKTREE_SYMLINKS)\n' "$path"
      continue
    fi
    # An entry with tracked content underneath is a real directory BY DESIGN;
    # its untracked children are what must be links. The layout is decided
    # from the INDEX alone — both, either one enough, matching how the repair
    # path decides it — never from what the destination happens to be right
    # now. Reading the destination first would let a parent symlink still
    # shadowing the tracked subtree answer as a plain-symlink
    # entry, and a symlink to exactly $PROJECT_ROOT/$path is what that check
    # calls healthy: the unrestored path would drop out of this diagnostic.
    if [[ -n "$(git -C "$wt" ls-files -- ":(literal)$path/" 2>/dev/null)" ]] ||
       [[ -n "$(git -C "$PROJECT_ROOT" ls-files -- ":(literal)$path/" 2>/dev/null || true)" ]]; then
      if [[ -L "$wt/$path" || ! -d "$wt/$path" ]]; then
        printf '%s (must be a real directory holding per-child links, tracked content lives under it)\n' "$path"
        continue
      fi
      collect_unhealthy_child_links "$path" "$wt"
      continue
    fi
    report_link_health "$wt" "$path" "$PROJECT_ROOT/$path"
  done

  # Relative-target entries this command also creates. Same postcondition, with
  # the expected target read from the config verbatim: it resolves from inside
  # the worktree, not from the main checkout.
  split_worktree_config_words "${WORKTREE_RELATIVE_SYMLINKS:-}"
  for spec in ${WORKTREE_CONFIG_WORDS[@]+"${WORKTREE_CONFIG_WORDS[@]}"}; do
    # Malformed entries: setup warns and ignores them, so there is no link to
    # expect here and nothing for this check to say.
    [[ "$spec" == *=* ]] || continue
    path="${spec%%=*}"
    target="${spec#*=}"
    path="$(normalize_worktree_config_path WORKTREE_RELATIVE_SYMLINKS "$path" 2>/dev/null)" || continue
    report_link_health "$wt" "$path" "$target"
  done
}

warn_if_links_materialized() {
  local wt="$1" path="" materialized="" rel="" child_damage=""
  [[ -n "$wt" && -d "$wt" ]] || return 0
  validate_worktree_setup_config >/dev/null 2>&1 || return 0

  split_worktree_config_words "${WORKTREE_SYMLINKS:-}"
  for path in ${WORKTREE_CONFIG_WORDS[@]+"${WORKTREE_CONFIG_WORDS[@]}"}; do
    path="$(normalize_worktree_config_path WORKTREE_SYMLINKS "$path" 2>/dev/null)" || continue
    # Only a path that SHOULD be a link and exists as a non-link is damage.
    [[ -e "$PROJECT_ROOT/$path" ]] || continue
    if [[ -e "$wt/$path" && ! -L "$wt/$path" ]]; then
      # An entry with tracked content underneath is a real directory BY
      # DESIGN: per-child links live inside it, not a parent link — but its
      # untracked children still need to be actual links.
      if [[ -d "$wt/$path" && -n "$(git -C "$wt" ls-files -- "$path/" 2>/dev/null)" ]]; then
        # `|| true`: the collector returns nonzero when a depth-capped
        # subtree could not be fully inspected — that is a REPORTING
        # outcome folded into the warning below, and under set -e an
        # unguarded substitution would abort the whole command (push) over
        # a warning-grade condition.
        child_damage="$(collect_materialized_child_links "$path" "$wt")" || true
        if [[ -n "$child_damage" ]]; then
          while IFS= read -r rel; do
            [[ -n "$rel" ]] || continue
            materialized="$materialized  - $rel"$'\n'
          done <<<"$child_damage"
        fi
        continue
      fi
      materialized="$materialized  - $path"$'\n'
    fi
  done

  [[ -n "$materialized" ]] || return 0
  {
    worktree_message links-materialized "$wt" "Warning: harness paths in this worktree are real directories, not symlinks:"
    printf '%s' "$materialized"
    echo "  A rebase materialized them, so kendex-installed files under those paths are gone."
    echo "  git status will look clean — it tracks only the files that survived."
    echo "  Restore them by running fix-links FROM THE MAIN CHECKOUT, because this"
    echo "  worktree's own copy of the script may be among the missing files:"
    echo "    cd '$PROJECT_ROOT' && .agents/skills/worktree/scripts/worktree fix-links '$wt'"
  } >&2
  return 0
}

# Entries inside a materialized path that forbid an
# automatic re-link. The tracked skeleton (e.g. a lone .cache/.gitkeep) is
# exactly what a git operation re-materializes, so a copy holding ONLY tracked
# files at their index content is safe to discard; anything beyond it is not:
#   - any entry git does not track, of ANY type — FIFOs, sockets, devices and
#     empty untracked directories included (untracked OR ignored data — a
#     worktree-local cache is ignored data);
#   - a tracked name whose content, kind, or exec bit differs from the index
#     (assume-unchanged hides such edits from git status, so only a direct
#     compare sees them);
#   - anything that could not be scanned or read — fail closed, never "empty".
# Names print relative to the configured path; any output means blocked.
worktree_unsafe_entries() {
  local wt="$1" path="$2" qdir="$3" rc=0 raw="" empties="" disk="" tracked=""
  local name="" meta="" mode="" oid="" actual=""

  if [[ ! -d "$qdir" || -L "$qdir" ]]; then
    # The materialized path is a single non-directory entry: safe only when
    # git tracks $path itself as a regular file with identical content.
    if [[ "$(git -C "$wt" ls-files -- "$path" 2>/dev/null)" != "$path" ]]; then
      printf '%s (untracked)\n' "$path"
      return 0
    fi
    worktree_tracked_entry_mismatch "$wt" "$path" "$path" "$qdir"
    return 0
  fi

  raw="$(find "$qdir" ! -type d 2>/dev/null)" || rc=$?
  if [[ "$rc" -eq 0 ]]; then
    empties="$(find "$qdir" -mindepth 1 -type d -empty 2>/dev/null)" || rc=$?
  fi
  if [[ "$rc" -ne 0 ]]; then
    printf '[scan failed: could not enumerate entries under %s (exit %s)]\n' "$path" "$rc"
    return 0
  fi
  # An empty untracked directory is never part of the skeleton — git creates
  # directories only to hold tracked files. No regex: paths are stripped with
  # literal parameter expansion (a path may contain sed metacharacters, and a
  # broken sed expression would fail OPEN as an empty listing).
  if [[ -n "$empties" ]]; then
    while IFS= read -r name; do
      [[ -n "$name" ]] || continue
      printf '%s/%s (empty untracked directory)\n' "$path" "${name#"$qdir"/}"
    done <<<"$empties"
  fi
  disk="$(while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    printf '%s\n' "${name#"$qdir"/}"
  done <<<"$raw" | LC_ALL=C sort)" || {
    printf '[scan failed: could not sort the inventory]\n'
    return 0
  }
  # A filename containing a newline shreds a line-delimited inventory into
  # fragments (or, for a pure-newline name, into nothing once command
  # substitution strips trailing newlines). Cross-check the reconstructed
  # entry count against a NUL-delimited pass — any mismatch blocks rather
  # than risking a deletion decision on a listing that cannot represent the
  # names it saw.
  local n_disk=0 n_nul=0
  n_disk="$(printf '%s' "$disk" | grep -c . || true)"
  n_nul="$(find "$qdir" ! -type d -print0 2>/dev/null | tr -cd '\0' | wc -c | tr -d '[:space:]')" || n_nul=-1
  if [[ "$n_disk" != "$n_nul" ]]; then
    printf '[scan mismatch: %s entries by NUL count vs %s reconstructed line entries — a name this listing cannot represent]\n' "$n_nul" "$n_disk"
    return 0
  fi
  # A failed tracked-listing sort collapses to an empty set, which reads as
  # "everything is untracked" — fail-closed on its own. The comm calls are
  # NOT: a failed comm yields empty output in both directions, which reads
  # as "nothing extra and nothing to verify" — so their exit status must be
  # checked explicitly.
  tracked="$(git -C "$wt" ls-files -- "$path/" 2>/dev/null | while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    printf '%s\n' "${name#"$path"/}"
  done | LC_ALL=C sort)" || tracked=""
  local untracked="" present_tracked="" cmp_rc=0
  untracked="$(LC_ALL=C comm -23 <(printf '%s\n' "$disk") <(printf '%s\n' "$tracked") 2>/dev/null)" || cmp_rc=$?
  if [[ "$cmp_rc" -eq 0 ]]; then
    present_tracked="$(LC_ALL=C comm -12 <(printf '%s\n' "$disk") <(printf '%s\n' "$tracked") 2>/dev/null)" || cmp_rc=$?
  fi
  if [[ "$cmp_rc" -ne 0 ]]; then
    printf '[scan failed: name-set comparison failed (exit %s)]\n' "$cmp_rc"
    return 0
  fi
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    printf '%s/%s\n' "$path" "$name"
  done <<<"$untracked"
  # Tracked names present in the copy must match the index exactly.
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    worktree_tracked_entry_mismatch "$wt" "$path/$name" "$path/$name" "$qdir/$name"
  done <<<"$present_tracked"
}

# Print a blocking line iff the on-disk entry differs from the index record
# for the tracked pathspec (content oid, symlink target, kind, or exec bit).
worktree_tracked_entry_mismatch() {
  local wt="$1" spec="$2" label="$3" file="$4" meta="" mode="" oid="" actual=""
  meta="$(git -C "$wt" ls-files -s -- "$spec" 2>/dev/null | head -n 1)"
  mode="${meta%% *}"
  oid="$(printf '%s\n' "$meta" | awk '{print $2}')"
  if [[ -z "$mode" || -z "$oid" ]]; then
    printf '%s (index record unreadable)\n' "$label"
    return 0
  fi
  case "$mode" in
    120000)
      if [[ ! -L "$file" ]]; then
        printf '%s (symlink differs from index)\n' "$label"
        return 0
      fi
      # Sentinel-preserved comparison: bare command substitution strips ALL
      # trailing newlines from both sides, so targets differing only by
      # trailing newline bytes would compare equal and the difference would
      # be discarded. readlink appends exactly one newline of its own;
      # cat-file emits the blob verbatim.
      local disk_target="" index_target=""
      disk_target="$(readlink "$file" 2>/dev/null; printf x)"
      disk_target="${disk_target%x}"
      disk_target="${disk_target%$'\n'}"
      index_target="$(git -C "$wt" cat-file blob "$oid" 2>/dev/null; printf x)"
      index_target="${index_target%x}"
      if [[ "$disk_target" != "$index_target" ]]; then
        printf '%s (symlink differs from index)\n' "$label"
      fi
      ;;
    100644 | 100755)
      if [[ ! -f "$file" || -L "$file" ]]; then
        printf '%s (not the regular file the index records)\n' "$label"
        return 0
      fi
      actual="$(git -C "$wt" hash-object -- "$file" 2>/dev/null)" || actual=""
      if [[ -z "$actual" ]]; then
        printf '%s (unreadable)\n' "$label"
      elif [[ "$actual" != "$oid" ]]; then
        printf '%s (local edits vs index)\n' "$label"
      elif [[ "$mode" == 100755 && ! -x "$file" ]] || [[ "$mode" == 100644 && -x "$file" ]]; then
        printf '%s (exec bit differs from index)\n' "$label"
      fi
      ;;
    *)
      printf '%s (unsupported index mode %s)\n' "$label" "$mode"
      ;;
  esac
}

# Re-link a WORKTREE_SYMLINKS path only when its materialized copy contains no
# untracked data or tracked data that differs from the index.
REPAIR_LINK_CHANGED=false
repair_materialized_path() {
  local wt="$1" path="$2" src="$PROJECT_ROOT/$2" dst="$wt/$2" extras="" extra_count=0
  REPAIR_LINK_CHANGED=false

  if [[ -L "$dst" ]] && [[ "$(readlink "$dst" 2>/dev/null || true)" == "$src" ]]; then
    return 0
  fi
  if [[ -e "$dst" && ! -L "$dst" ]]; then
    extras="$(worktree_unsafe_entries "$wt" "$path" "$dst")"
    if [[ -n "$extras" ]]; then
      extra_count="$(printf '%s\n' "$extras" | grep -c .)"
      {
        worktree_message link-data-preserved "path=$wt/$path count=$extra_count" "Warning: '$path' in $wt should be a symlink to '$src' but is a real path holding $extra_count entr(y/ies) git does not track or that differ from the index:"
        printf '%s\n' "$extras" | head -n 10 | sed 's/^/  - /'
        [[ "$extra_count" -le 10 ]] || echo "  ... and $((extra_count - 10)) more"
        echo "  Auto-repair refuses to destroy untracked data. Move it into '$src' (or delete it),"
        echo "  then restore the link from the main checkout:"
        echo "    cd '$PROJECT_ROOT' && $0 fix-links '$wt'"
      } >&2
      return 1
    fi
  fi
  if symlink_into_worktree "$path" "$wt"; then
    REPAIR_LINK_CHANGED=true
    return 0
  fi
  return 1
}

# The one test and message for a WORKTREE_SYMLINKS entry with no main-checkout
# source, shared by the two skip sites so they cannot drift. Warns, and returns
# 0, only for a node_modules entry beside a worktree package.json: skipping
# that one in silence surfaces later as the worktree's own checks failing.
warn_missing_symlink_source() {
  local wt="$1" path="$2"
  [[ "${path##*/}" == node_modules && -f "$wt/${path%node_modules}package.json" ]] || return 1
  worktree_message dependency-source-missing "$PROJECT_ROOT/$path" "Warning: dependencies were not installed — WORKTREE_SYMLINKS entry '$path' has no source at $PROJECT_ROOT/$path. Run the install in the main checkout ($PROJECT_ROOT), then rerun fix-links to link it." >&2
}

# Re-assert configured WORKTREE_SYMLINKS in one worktree. Cheap on the healthy
# path (one readlink per entry); repair is repair_materialized_path above.
repair_worktree_links() {
  local wt="$1" path="" src="" repaired="" blocked=false
  validate_worktree_setup_config || return 1

  split_worktree_config_words "${WORKTREE_SYMLINKS:-}"
  for path in ${WORKTREE_CONFIG_WORDS[@]+"${WORKTREE_CONFIG_WORDS[@]}"}; do
    path="$(normalize_worktree_config_path WORKTREE_SYMLINKS "$path" 2>/dev/null)" || continue
    src="$PROJECT_ROOT/$path"
    [[ -e "$src" ]] || { warn_missing_symlink_source "$wt" "$path" || true; continue; }
    # An entry with tracked content underneath never becomes a parent link
    # its healthy state is a real directory holding per-child links,
    # which symlink_into_worktree heals idempotently — stale assume-unchanged
    # bits cleared, missing tracked files restored, untracked children re-linked
    # through the same safety check as any other child.
    # Ask BOTH indexes: checking only $wt here means a branch that predates a
    # path becoming tracked on main takes the repair branch below instead,
    # where an already healthy destination returns success on sight without
    # ever re-deciding the shape — so the entry never converts to the
    # per-child layout main's content requires.
    if [[ -d "$src" ]] &&
       { [[ -n "$(git -C "$wt" ls-files -- "$path/" 2>/dev/null)" ]] ||
         [[ -n "$(git -C "$PROJECT_ROOT" ls-files -- "$path/" 2>/dev/null || true)" ]]; }; then
      symlink_into_worktree "$path" "$wt" || blocked=true
      continue
    fi
    if repair_materialized_path "$wt" "$path"; then
      [[ "$REPAIR_LINK_CHANGED" == true ]] && repaired="$repaired $path"
    else
      blocked=true
    fi
  done

  if [[ -n "$repaired" ]]; then
    worktree_message links-repaired "path=$wt links=$repaired" "worktree auto-repair: restored symlink(s) in $wt:$repaired" >&2
  fi
  [[ "$blocked" != true ]]
}

# Undo symlink shadowing so git can check out through the configured paths.
#
# `symlink_into_worktree` never links a directory entry with tracked content
# underneath (it links the untracked children instead), but a worktree can
# still hold the shadowed layout: the configured directory replaced by a
# symlink and the tracked files under it marked --assume-unchanged. Git then
# refuses any checkout that would
# rewrite those paths — "Your local changes to the following files would be
# overwritten by checkout", ending in "could not detach HEAD" — so `git
# rebase` in the create --reuse/--restack path dies before it starts.
# `git status --porcelain` is empty throughout, because assume-unchanged is
# exactly what hides them, which is what makes the failure so confusing.
#
# Restoring the index's own content as real files removes the conflict without
# touching any user work: what we discard is a symlink the tool itself laid
# down, and the tracked content it hid is recreated from the index verbatim.
# Callers re-apply setup afterwards, which re-links and re-marks the paths.
#
# No-op unless a configured entry actually shadows tracked files, so the
# ordinary runtime-only symlink case is left completely alone.
unshadow_tracked_symlink_paths() {
  local wt="$1" path="" f="" checkout_err="" clear_rc=0
  local -a shadowed=() tracked=()
  [[ -n "$wt" && -d "$wt" ]] || return 0
  validate_worktree_setup_config >/dev/null 2>&1 || return 0

  split_worktree_config_words "${WORKTREE_SYMLINKS:-}"
  for path in ${WORKTREE_CONFIG_WORDS[@]+"${WORKTREE_CONFIG_WORDS[@]}"}; do
    path="$(normalize_worktree_config_path WORKTREE_SYMLINKS "$path" 2>/dev/null)" || continue
    # NUL-delimited: a line-oriented list piped through xargs breaks on
    # filenames with spaces, tabs, or quotes, silently leaving their
    # assume-unchanged bit set; `xargs -r` is also GNU-only.
    tracked=()
    while IFS= read -r -d '' f; do
      tracked[${#tracked[@]}]="$f"
    done < <(git -C "$wt" ls-files -z -- "$path" "$path/" 2>/dev/null)
    [[ ${#tracked[@]} -gt 0 ]] || continue

    # Clear the bit first: while it is set, git will not write these paths even
    # once the link is gone. The checkout at the end is what the bit actually
    # blocks and it refuses there with git's own words, so a failure here warns
    # and leaves that checkout to judge: it names the bit, which the checkout's
    # "local changes would be overwritten" does not.
    clear_rc=0
    git -C "$wt" update-index --no-assume-unchanged -- "${tracked[@]}" 2>/dev/null || clear_rc=$?
    [[ "$clear_rc" -eq 0 ]] ||
      worktree_message assume-unchanged-clear-failed "$wt/$path" "Warning: git update-index --no-assume-unchanged exited $clear_rc for the tracked files under '$path'; the restore below fails if the bit is still set." >&2

    # Only a symlink needs removing. A real directory here means a rebase
    # already materialized it; its tracked content is genuine and
    # a checkout can write straight through it.
    if [[ -L "$wt/$path" ]] && ! rm -f "$wt/$path" 2>/dev/null; then
      worktree_message link-remove-failed "$wt/$path" "Error: Could not remove the '$path' symlink in $wt to restore the tracked files it shadows." >&2
      return 1
    fi
    shadowed[${#shadowed[@]}]="$path"
  done

  [[ ${#shadowed[@]} -gt 0 ]] || return 0

  if ! checkout_err="$(git -C "$wt" checkout -- ${shadowed[@]+"${shadowed[@]}"} 2>&1)"; then
    worktree_message index-unshadow-failed "$wt" "Error: Could not restore the tracked files shadowed by WORKTREE_SYMLINKS in $wt:" >&2
    sed 's/^/  /' <<<"$checkout_err" >&2
    echo "Re-link the worktree, then retry:" >&2
    echo "  cd '$PROJECT_ROOT' && $0 fix-links '$wt'" >&2
    return 1
  fi
  return 0
}

# Re-apply setup after a reuse/restack attempt that un-shadowed the configured
# paths and then failed. Without this the worktree is left holding real tracked
# directories where the harness links belong, which is a valid git state but a
# broken harness.
restore_unshadowed_worktree_setup() {
  local wt="$1"
  setup_app_worktree "$wt" && return 0
  worktree_message setup-restore-failed "$wt" "Warning: Worktree setup could not be reapplied after the failed rebase; harness links may be missing." >&2
  echo "  Restore them from the main checkout: cd '$PROJECT_ROOT' && $0 fix-links '$wt'" >&2
  return 0
}

setup_worktree_links() {
  local wt="$1" root_nm_warned=0
  validate_worktree_setup_config || return 1

  # Project-configured mkdirs (run first so subsequent symlinks/copies can
  # land inside them if needed). Idempotent; ignores empty entries.
  split_worktree_config_words "${WORKTREE_MKDIRS:-}"
  for path in ${WORKTREE_CONFIG_WORDS[@]+"${WORKTREE_CONFIG_WORDS[@]}"}; do
    path="$(normalize_worktree_config_path WORKTREE_MKDIRS "$path")" || return 1
    mkdir_inside_worktree "$wt" "$path" || return 1
    exclude_from_worktree_index "$wt" "$path"
  done

  # Project-configured symlinks
  split_worktree_config_words "${WORKTREE_SYMLINKS:-}"
  for path in ${WORKTREE_CONFIG_WORDS[@]+"${WORKTREE_CONFIG_WORDS[@]}"}; do
    path="$(normalize_worktree_config_path WORKTREE_SYMLINKS "$path")" || return 1
    if [[ -e "$PROJECT_ROOT/$path" ]]; then
      symlink_into_worktree "$path" "$wt" || return 1
    elif warn_missing_symlink_source "$wt" "$path"; then
      [[ "$path" == node_modules ]] && root_nm_warned=1
    fi
  done

  # Project-configured copies
  split_worktree_config_words "${WORKTREE_COPIES:-}"
  for path in ${WORKTREE_CONFIG_WORDS[@]+"${WORKTREE_CONFIG_WORDS[@]}"}; do
    path="$(normalize_worktree_config_path WORKTREE_COPIES "$path")" || return 1
    if [[ -f "$PROJECT_ROOT/$path" ]]; then
      ensure_worktree_path_safe "$wt" "$path" true || return 1
      exclude_from_worktree_index "$wt" "$path"
      # Checked, not left to implicit set -e: fix-links calls this function
      # on the left of ||, which disables errexit for everything inside it.
      # Unchecked, a failure here would return whatever the next command
      # returns, and the caller would read that as a clean pass.
      if ! mkdir -p "$(dirname "$wt/$path")" 2>/dev/null ||
         ! cp "$PROJECT_ROOT/$path" "$wt/$path" 2>/dev/null; then
        worktree_message copy-failed "$wt/$path" "Error: could not copy WORKTREE_COPIES entry '$path' into $wt." >&2
        return 1
      fi
    fi
  done

  # Project-configured symlinks whose targets should resolve from inside the
  # worktree, not from the main checkout. A tracked file arrives through git
  # and needs no entry here.
  split_worktree_config_words "${WORKTREE_RELATIVE_SYMLINKS:-}"
  for spec in ${WORKTREE_CONFIG_WORDS[@]+"${WORKTREE_CONFIG_WORDS[@]}"}; do
    if [[ "$spec" != *=* ]]; then
      worktree_message relative-spec-invalid "$spec" "Warning: Ignoring invalid WORKTREE_RELATIVE_SYMLINKS entry '$spec' (expected path=target)" >&2
      continue
    fi
    local path="${spec%%=*}" target="${spec#*=}"
    path="$(normalize_worktree_config_path WORKTREE_RELATIVE_SYMLINKS "$path")" || return 1
    validate_relative_symlink_target "$spec" "$target" || return 1
    ensure_worktree_path_safe "$wt" "$path" false || return 1
    if [[ -e "$wt/$path" && ! -L "$wt/$path" && ! -f "$wt/$path" ]]; then
      worktree_message relative-link-nonfile "$wt/$path" "Error: refusing to replace non-file worktree path '$path' with a relative symlink." >&2
      return 1
    fi
    # Same reason as WORKTREE_COPIES above. A relative entry nested below a
    # tracked regular file fails both the mkdir and the ln; unchecked, the
    # exclude update that follows would supply the function's exit status and
    # fix-links would report success with the link absent.
    if ! mkdir -p "$(dirname "$wt/$path")" 2>/dev/null; then
      worktree_message relative-parent-failed "$wt/$path" "Error: could not create the parent directory for relative symlink '$path' in $wt." >&2
      return 1
    fi
    if [[ -L "$wt/$path" || -f "$wt/$path" ]]; then
      if ! rm -f "$wt/$path" 2>/dev/null; then
        worktree_message relative-remove-failed "$wt/$path" "Error: could not remove the existing relative symlink '$path' in $wt." >&2
        return 1
      fi
    fi
    if ! ln -s "$target" "$wt/$path" 2>/dev/null; then
      worktree_message relative-link-failed "$wt/$path" "Error: could not create relative symlink '$path' -> '$target' in $wt." >&2
      return 1
    fi
    exclude_from_worktree_index "$wt" "$path"
  done

  # Installs run only in the main checkout: inside a linked worktree they write
  # node_modules through into the checkout every worktree shares, and a pnpm
  # workspace install records its deps as links into the installing tree. A root
  # package.json with nothing linked warns, unless the root entry warned above.
  if [[ "$root_nm_warned" -eq 0 && -f "$wt/package.json" && ! -e "$wt/node_modules" ]]; then
    worktree_message dependencies-missing "$PROJECT_ROOT" "Warning: dependencies were not installed — installs run only in the main checkout. Run the install in $PROJECT_ROOT, then link its node_modules into worktrees with a WORKTREE_SYMLINKS entry." >&2
  fi

  # Explicit: the last loop's trailing command must not decide this function's
  # exit status — every failure above returns 1 on its own.
  return 0
}
