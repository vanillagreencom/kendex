#!/usr/bin/env bash
# Under Codex `approval=never` an env-assignment prefix (`VAR=value cmd args`,
# e.g. `LC_ALL=C tools/test-ci-changes`) is rejected purely for its prefix
# shape — the inner command is irrelevant. The canonical normalization
# (references/codex-runtime.md § Env-assignment prefixes) happens where a
# required command is ACCEPTED into a workflow: confirm the ambient
# environment satisfies the precondition, then run the bare command. So no
# fenced ```bash/```sh command line in the orch or dev docs may open with one.
#
# A plain assignment with no command after it is a value, not a prefix, and it
# stays legal whether its value is bare, quoted, or spaced. What the shell
# treats as a prefix is flagged whatever the value looks like: `LC_ALL= cmd`,
# `LC_ALL="C" cmd` and `LC_ALL=C"UTF-8" cmd` are each one.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
source "$(dirname "${BASH_SOURCE[0]}")/lib/md.sh"

# NAME=, then a value that may be empty, unquoted, quoted, or a mix of those,
# then whitespace and a command word. Quote-aware, so `KEYWORDS="a b"` reads as
# one assignment with a spaced value rather than a prefix over `b"`.
ENV_PREFIX="^[[:space:]]*[A-Za-z_][A-Za-z0-9_]*=([^\"'[:space:]]|\"[^\"]*\"|'[^']*')*[[:space:]]+[^[:space:]]"

echo "=== orch/dev env-assignment-prefix command lint ==="

forbid_fenced "no fenced command opens with an env-assignment prefix" "$ENV_PREFIX" \
  'LC_ALL=C tools/test-ci-changes' \
  "$SKILL_DIR/SKILL.md" "$SKILL_DIR"/workflows/*.md "$SKILL_DIR"/references/*.md \
  "$SKILLS_ROOT/dev/SKILL.md" "$SKILLS_ROOT"/dev/workflows/*.md

forbid_fenced "no fenced command opens with an empty-value prefix" "$ENV_PREFIX" \
  'LC_ALL= tools/test-ci-changes' \
  "$SKILL_DIR/SKILL.md" "$SKILL_DIR"/workflows/*.md "$SKILL_DIR"/references/*.md \
  "$SKILLS_ROOT/dev/SKILL.md" "$SKILLS_ROOT"/dev/workflows/*.md
forbid_fenced "no fenced command opens with a quoted-value prefix" "$ENV_PREFIX" \
  'LC_ALL="C" tools/test-ci-changes' \
  "$SKILL_DIR/SKILL.md" "$SKILL_DIR"/workflows/*.md "$SKILL_DIR"/references/*.md \
  "$SKILLS_ROOT/dev/SKILL.md" "$SKILLS_ROOT"/dev/workflows/*.md

permits_fenced "a bare assignment is a value, not a prefix" "$ENV_PREFIX" \
  'LC_ALL=C tools/test-ci-changes' 'RATCHET_RAISE=1' "$SKILL_DIR/SKILL.md"
permits_fenced "an assignment whose quoted value holds a space is not a prefix" "$ENV_PREFIX" \
  'LC_ALL=C tools/test-ci-changes' 'KEYWORDS="worktree lease"' "$SKILL_DIR/SKILL.md"

md_report
