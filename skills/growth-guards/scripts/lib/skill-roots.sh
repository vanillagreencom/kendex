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
