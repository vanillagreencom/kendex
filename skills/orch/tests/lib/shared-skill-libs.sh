# shellcheck shell=bash
#
# Lay the github skill's libs beside a fixture's copy of the orch scripts.
#
# An orch lib reaches its github counterpart by a fixed relative path —
# `scripts/lib/../../../github/scripts/lib` — so a fixture that holds only
# `<root>/scripts/lib` leaves that path pointing at nothing, and a script
# sourcing one of those wrappers refuses at source time with
# `<name>: helper-missing`. Every fixture that copies `scripts/lib` calls this
# with the same root, so the copied script finds what the installed one finds.
#
# Source this file; do not execute it directly.

_ORCH_TEST_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_ORCH_TEST_REPO_ROOT="$(cd "$_ORCH_TEST_LIB_DIR/../../../.." && pwd)"
unset _ORCH_TEST_LIB_DIR

# orch_fixture_shared_libs ROOT — ROOT is the directory holding `scripts/`.
orch_fixture_shared_libs() {
  local fixture_root="${1:?orch_fixture_shared_libs: fixture root required}"
  local dest
  dest="$(dirname -- "$fixture_root")/github/scripts/lib"
  mkdir -p "$dest"
  cp "$_ORCH_TEST_REPO_ROOT"/skills/github/scripts/lib/*.sh "$dest/"
  dest="$(dirname -- "$fixture_root")/mailbox/scripts"
  mkdir -p "$dest"
  cp -R "$_ORCH_TEST_REPO_ROOT/skills/mailbox/scripts/." "$dest/"
  # Launch fixtures have no live tracker. Private blocker cases replace this
  # neutral sibling; no fixture can spend the developer's Linear credentials.
  dest="$(dirname -- "$fixture_root")/linear/scripts"
  mkdir -p "$dest"
  cat > "$dest/linear.sh" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-} ${2:-}" == 'issues get' ]] || exit 1
jq -cn --arg id "$3" '{id:$id, parent_id:"", blocked_by_open:[]}'
EOF
  chmod +x "$dest/linear.sh"
}
