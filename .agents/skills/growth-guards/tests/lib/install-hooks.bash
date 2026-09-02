# Shared fixtures for the install-git-hooks suites: an isolated consumer
# repository with the skill installed where a consumer has it, the four
# ways these tests invoke the installer, and the pass/fail tally.
#
# TMP, TMPDIR and the git isolation come from lib/harness.bash, which each
# suite sources itself rather than reaching it through this file: the
# adoption test reads that line out of every suite, and a transitive source
# would turn a line it can read into a chain it has to follow.

SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
INSTALL="$SKILL_DIR/scripts/install-git-hooks"
# Outside the namespace new_repo allocates fixtures from: a fixture named for
# the template would satisfy the build guard below and be copied into the skill
# slot as a git repository, with nothing checking the shape.
GG_SKILL_TEMPLATE="$TMP/.templates/growth-guards"

unset GROWTH_GUARDS_CHECKS GROWTH_GUARDS_PRE_COMMIT_LOCAL GROWTH_GUARDS_SETTINGS_FILE \
  GROWTH_GUARDS_COMMIT_TYPES SIZE_RATCHET_THRESHOLD 2>/dev/null || true

# Marker words are assembled from split tokens so this file never contains a
# marker shape itself — the kendex repo runs todo-ban over its own tree.
TD="TO""DO"
FX="FIX""ME"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

# A consumer project carries its skills under .agents/skills, and the
# installer it runs is the one installed THERE — so the tests exercise the
# same path resolution a consumer gets, and can take the tree away again.
new_repo() { # NAME -> repo path on stdout
  local r="$TMP/$1"
  mkdir -p "$r/.agents/skills"
  git -C "$r" -c init.defaultBranch=main init -q
  git -C "$r" config user.email test@example.com
  git -C "$r" config user.name test
  # A real directory, the shape a project install has: path resolution and
  # the shared-worktree check both key on where the copy physically is.
  #
  # The copy is cloned from a template built once per suite, with tests/ cut:
  # that subtree is more than half the skill and nothing a consumer install
  # reaches, and these suites build dozens of fixtures.
  if [ ! -d "$GG_SKILL_TEMPLATE" ]; then
    mkdir -p "$(dirname "$GG_SKILL_TEMPLATE")"
    cp -R "$SKILL_DIR" "$GG_SKILL_TEMPLATE"
    rm -rf -- "${GG_SKILL_TEMPLATE:?}/tests"
  fi
  cp -R "$GG_SKILL_TEMPLATE" "$r/.agents/skills/growth-guards"
  ln -s "$SKILL_DIR/../size-ratchet" "$r/.agents/skills/size-ratchet"
  printf '%s' "$r"
}

install_in() { # REPO — sets OUT and RC
  local installer="$1/.agents/skills/growth-guards/scripts/install-git-hooks"
  [ -x "$installer" ] || installer="$INSTALL"
  OUT=""
  RC=0
  OUT="$("$installer" --repo "$1" 2>&1)" || RC=$?
}

commit_in() { # REPO MSG — sets OUT and RC
  OUT=""
  RC=0
  OUT="$(git -C "$1" commit -m "$2" 2>&1)" || RC=$?
}

check_in() { # REPO — sets OUT and RC
  local installer="$1/.agents/skills/growth-guards/scripts/install-git-hooks"
  [ -x "$installer" ] || installer="$INSTALL"
  OUT=""
  RC=0
  OUT="$("$installer" --repo "$1" --check 2>&1)" || RC=$?
}

# A core.hooksPath directory wired by hand to this skill's entry points —
# the shape that really does gate and that `--check` declines to judge.
wire_hooks_dir() { # REPO DIR
  local scripts="$1/.agents/skills/growth-guards/scripts"
  mkdir -p "$2"
  printf '#!/bin/sh\nexec %s/pre-commit "$@"\n' "$scripts" >"$2/pre-commit"
  printf '#!/bin/sh\nexec %s/commit-msg "$1"\n' "$scripts" >"$2/commit-msg"
  chmod +x "$2/pre-commit" "$2/commit-msg"
}
