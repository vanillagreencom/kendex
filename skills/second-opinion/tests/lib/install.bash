# shellcheck shell=bash
# ONE JUDGE OF WHAT AN INSTALL OF THIS SKILL HOLDS. second-opinion declares
# github required in its SKILL.md frontmatter, because the runtime forks every
# child through that skill's scripts/lib/group-leader.sh. A fixture that copies
# this skill alone therefore builds a project no honoured declaration produces,
# and the runtime in it refuses at startup with group-leader-missing. Sourced,
# never run as a suite: the runners glob tests/*.sh, so the subdirectory and
# the .bash name keep this file out of every run.
second_opinion_install() { # SKILL_DIR SKILLS_DIR — the skill and what it requires
  local skill_dir="$1" skills_dir="$2" lib="scripts/lib/group-leader.sh"
  cp -R "$skill_dir" "$skills_dir/second-opinion" || return 1
  mkdir -p "$skills_dir/github/scripts/lib" || return 1
  cp "$skill_dir/../github/$lib" "$skills_dir/github/$lib"
}
