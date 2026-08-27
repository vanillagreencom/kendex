# shellcheck shell=bash
# Whether another work tree still carries this package.
#
# Its own file because it is one question, and an expensive one to get
# wrong in either direction. Answer yes when nobody is left and a shared
# hooks directory keeps shims whose scripts are gone, so every commit in
# every work tree fails closed. Answer no when somebody IS left and their
# commits stop being gated at all.
#
# So every uncertainty here returns 2 — could not tell — and the caller
# keeps the shims. A directory that cannot be searched is not an empty one.
#
# Sourced by install-git-hooks, which owns REPO_ABS, COMMON_DIR, HOOKS_DIR,
# HELPER_NAME, PROJECT_REL and tracked_here.
set -euo pipefail

other_worktree_still_installed() {
  local repo_phys="" main_root="" gitdir="" root="" root_phys="" base="" dir="" phys="" entry=""
  local tracked_status=0
  local own_gitdir="" own_phys="" common_phys="" guess_gitdir="" guess_phys="" parent=""
  local roots=() rels=() rel="" baked=() one="" seen=0
  gg_path repo_phys gg_physical "$REPO_ABS" || return 2
  # The helper is shared and records every project that has armed it. An
  # uninstall from any one of them has to look for survivors under all of
  # them: the shims a project leaves behind are the shims another is still
  # committing through.
  rels=("$PROJECT_REL")
  if [ -f "$HOOKS_DIR/$HELPER_NAME" ]; then
    gg_baked_project_rels baked "$HOOKS_DIR/$HELPER_NAME" || return 2
    for rel in ${baked[@]+"${baked[@]}"}; do
      # Element by element. Joining the array and testing for a substring
      # made one recorded project hide another: a project named `a b/`
      # contains ` b/ `, so a real `b/` read as already present and was
      # never searched — a survivor missed by the machinery meant to find
      # it. A project name is a string that may contain the separator.
      seen=0
      for one in ${rels[@]+"${rels[@]}"}; do
        [ "$one" = "$rel" ] && seen=1
      done
      [ "$seen" -eq 1 ] || rels+=("$rel")
    done
  fi
  # This checkout IS the main work tree exactly when its own git directory is
  # the common one; a linked worktree's is <common>/worktrees/<name>.
  gg_git_path own_gitdir "$REPO_ABS" rev-parse --git-dir || own_gitdir=""
  [ -n "$own_gitdir" ] || return 2
  case "$own_gitdir" in /*) ;; *) own_gitdir="$REPO_ABS/$own_gitdir" ;; esac
  gg_path own_phys gg_physical "$own_gitdir" || return 2
  gg_path common_phys gg_physical "$COMMON_DIR" || return 2
  if [ "$own_phys" = "$common_phys" ]; then
    main_root="$REPO_ABS"
  else
    # <root>/.git holds the git directory in the ordinary layout. Under
    # --separate-git-dir it does not, and git records the main work tree
    # nowhere a linked worktree can read — so it cannot be ruled out as a
    # survivor, and guessing would disarm it.
    main_root="${COMMON_DIR%/*}"
    # Owning it is the test, not merely having some `.git`: the parent of an
    # external git directory can be an unrelated checkout, and treating that
    # as the main work tree would rule out the real one.
    if [ -z "$main_root" ]; then
      return 2
    fi
    gg_git_path guess_gitdir "$main_root" rev-parse --git-common-dir || guess_gitdir=""
    [ -n "$guess_gitdir" ] || return 2
    case "$guess_gitdir" in /*) ;; *) guess_gitdir="$main_root/$guess_gitdir" ;; esac
    gg_path guess_phys gg_physical "$guess_gitdir" || return 2
    [ "$guess_phys" = "$common_phys" ] || return 2
  fi
  roots+=("$main_root")
  if [ -d "$COMMON_DIR/worktrees" ]; then
    # A directory that cannot be read or searched enumerates as nothing: the
    # glob stays literal, the loop body never runs, and every linked work
    # tree goes unseen — so the shims come out while other work trees are
    # still committing through them. Unreadable is not empty, which is this
    # module's whole contract.
    if [ ! -r "$COMMON_DIR/worktrees" ] || [ ! -x "$COMMON_DIR/worktrees" ]; then
      return 2
    fi
    for entry in "$COMMON_DIR"/worktrees/*/; do
      # The literal glob, which is what an empty directory leaves behind.
      # Empty is genuinely no linked work trees, and that is not a refusal.
      [ -e "$entry" ] || continue
      [ -d "$entry" ] || return 2
      [ -f "$entry/gitdir" ] || return 2
      gg_path gitdir cat -- "$entry/gitdir" || return 2
      [ -n "$gitdir" ] || return 2
      # git may register the path relative to the registration directory
      # (relocatable worktrees); resolving it against this process's cwd
      # would point somewhere else entirely.
      case "$gitdir" in /*) ;; *) gitdir="$entry/$gitdir" ;; esac
      # <root>/.git -> <root>
      roots+=("${gitdir%/*}")
    done
  fi
  for root in ${roots[@]+"${roots[@]}"}; do
    # A registration whose directory is gone (pruned, moved) can hold no
    # install; one that cannot be INSPECTED is unknown, not empty — an
    # unsearchable parent answers "not a directory" exactly like an absent
    # one, and another user's worktree under it may still carry the skill.
    if [ ! -d "$root" ]; then
      # Walk up until an ancestor can be stat'd: one that EXISTS but cannot be
      # searched hides everything under it, and at any depth. Only a
      # searchable ancestor proves the path is genuinely gone.
      parent="$root"
      while :; do
        case "$parent" in
          "" | "/") break ;;
        esac
        parent="${parent%/*}"
        [ -n "$parent" ] || parent="/"
        if [ -d "$parent" ]; then
          [ -x "$parent" ] || return 2
          break
        fi
      done
      continue
    fi
    gg_path root_phys gg_physical "$root" || return 2
    for rel in ${rels[@]+"${rels[@]}"}; do
    for base in $GG_SKILL_ROOTS; do
      # Under the project, wherever the project sits in that work tree —
      # the same anchor the helper and the chain use.
      dir="$root/$rel$base/growth-guards/scripts"
      # BOTH entry points, because both hooks are retained: a survivor that
      # cannot serve commit-msg would leave that hook failing closed forever.
      if [ ! -x "$dir/pre-commit" ] || [ ! -x "$dir/commit-msg" ]; then
        continue
      fi
      gg_path phys gg_physical "$dir" || continue
      # The install being removed: the caller's own project, inside the
      # repository being uninstalled. PHYSICALLY inside — another work tree
      # may reach the very same directory through a symlink, and that is
      # the same install, not a survivor of it.
      #
      # Excluding the whole work tree instead skipped a SECOND armed project
      # in the same checkout, so two nested projects were never survivors of
      # each other and disarming either took the shims the other was still
      # committing through.
      if [ "$rel" = "$PROJECT_REL" ]; then
        case "$phys" in
          "$repo_phys" | "$repo_phys"/*) continue ;;
        esac
      fi
      # A copy git tracks is this repository's own content, checked out
      # again. Every work tree of a repository that commits its skills
      # carries one, so treating those as separate installs would find a
      # survivor in every sibling and keep the shims armed forever — a
      # repository nobody could ever disarm. One repository, one install:
      # only a copy the repository does not track is somebody else's.
      tracked_status=0
      tracked_here "$root" "$dir/pre-commit" || tracked_status=$?
      case "$tracked_status" in
        0) continue ;;
        1) ;;
        *) return 2 ;;
      esac
      printf '%s\n' "$dir"
      return 0
    done
    done
  done
  return 1
}
