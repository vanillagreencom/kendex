#!/usr/bin/env bash
# ---
# name: doc-drift-check
# event: Stop
# matcher:
# description: Retired: runs no check and exits 0. Delete [hooks.doc-drift-check] from kendex.toml. Not run on gemini: it has no Stop event. Not run on antigravity: its Stop payload carries no `stop_hook_active`.
# summary: Retired. Runs no check; delete [hooks.doc-drift-check] from kendex.toml.
# safety: Reads nothing and writes nothing.
# timeout: 5
# harnesses: [claude, codex, pi, copilot, opencode, cursor]
# ---

set -euo pipefail

# Kept so a consumer on kendex 1.10.1 that still declares the hook keeps
# refreshing; remove it one minor release after the release that carries the
# KEN-2779 retire route.
exit 0
