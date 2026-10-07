# shellcheck shell=bash
# Every project-scope skills directory a kendex install can write, plus the
# source layout kendex itself has.
#
# One definition because it had four, and they disagreed. Each was correct
# when it was written and none was updated together: the installer, the
# helper it bakes into .git/hooks, the pre-commit chain's sibling discovery,
# and a test asserting the shape of a message. A package installed under a
# root only some of them knew was one the others could not find.
#
# The helper cannot source this — it runs from .git/hooks, where the package
# may be gone, which is the whole reason it has a search at all — so the
# installer interpolates this value into the helper it writes. That is one
# definition with one copy taken from it, rather than four originals.
#
# kendex has its own copy in Rust and pins it against the harness adapters
# that write these directories, and against this file.
#
# Sourced, never executed — strict on its own terms rather than its caller's,
# like the other libraries beside it.
set -euo pipefail

GG_SKILL_ROOTS=".agents/skills .claude/skills .cursor/skills .gemini/skills .github/skills .opencode/skills skills"

# The PROJECT root this copy of the package is installed under, worked out
# from where this script lives.
#
# A kendex project can sit below the git top level — a repository holding
# several, each with its own `.agents/skills` — and kendex renders into the
# PROJECT's root. Anchoring the searches at the git top level looked right
# for the common case where the two are the same directory, and found
# nothing in the case where they are not: a sibling gate that failed
# reported nothing and the chain exited 0.
#
# Derived rather than configured: this script is at
# `<project>/<skill root>/commit-guards/scripts`, so two levels up is the
# skill root, and stripping the root off names the project. Nonzero when
# the copy is not under a root this package knows, which is the source
# layout and a caller that should fall back to the git top level.
gg_project_root() { # VAR SCRIPT_DIR -> sets VAR to the project root
  local __name="$1" holder="" base=""
  gg_path holder gg_physical "$2/../.." || return 1
  for base in $GG_SKILL_ROOTS; do
    case "$holder" in
      */"$base")
        eval "$__name=\${holder%\"/\$base\"}"
        return 0
        ;;
    esac
  done
  return 1
}

# The same anchor, expressed relative to a work tree: what the helper bakes
# so a moved checkout still resolves it.
#
# Empty when the project IS the work-tree root, which is most repositories,
# and carrying its own trailing slash so callers join it without minting a
# `.` segment into every path they then print.
gg_project_rel() { # VAR SCRIPT_DIR WORKTREE -> sets VAR to the prefix
  local __name="$1" project="" worktree=""
  eval "$__name=''"
  gg_project_root project "$2" || return 0
  gg_path worktree gg_physical "$3" || return 0
  case "$project" in
    "$worktree"/*) eval "$__name=\"\${project#\"\$worktree/\"}/\"" ;;
  esac
}

# What a SKILL.md declares: its frontmatter's `name`, then its `metadata:`
# block's `version` on a second line where it states one, double or single
# quotes taken off. Nonzero when the frontmatter or the name is missing, so
# an unreadable package never compares equal to another.
#
# A package reads as versionless only when no frontmatter line is a
# `version:` key, wherever it sits: a version line this cannot place under
# `metadata:`, or one stated empty, is nonzero, never a package that states
# no version, which the changelog check would let change without a raise.
# A YAML comment line holds no key, so it neither ends the metadata block
# nor counts as a version line.
gg_skill_id() { # FILE
  LC_ALL=C awk '
    function value(l) {
      sub(/^[^:]*:[ \t]*/, "", l); sub(/[ \t]+$/, "", l)
      if (l ~ /^".*"$/ || l ~ /^\047.*\047$/) l = substr(l, 2, length(l) - 2)
      return l
    }
    { sub(/\r$/, "") }
    NR == 1 { if ($0 != "---") { bad = 1; exit } next }
    $0 == "---" { closed = 1; exit }
    /^[ \t]*#/ { next }
    /^[^ \t]/ { meta = ($0 ~ /^metadata:[ \t]*$/) }
    /^name:/ { name = value($0) }
    /^[ \t]*version:/ { has = 1 }
    meta && /^[ \t]+version:/ { version = value($0) }
    END { if (bad || !closed || name == "" || (has && version == "")) exit 1; print name; if (has) print version }
  ' "$1"
}
