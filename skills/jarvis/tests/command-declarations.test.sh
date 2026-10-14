#!/usr/bin/env bash
# Surface: Jarvis external command requirements through kendex check.
# Inputs: skills/jarvis/SKILL.md, skills/jarvis/tests/command_declarations_test.py,
# skills/jarvis/tests/desktop_world.py, crates/core/src/engine/deps/commands.rs,
# crates/cli/src/commands/check.rs.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/.." && pwd -P)"
exec python3 -B "$ROOT/tests/command_declarations_test.py" "$@"
