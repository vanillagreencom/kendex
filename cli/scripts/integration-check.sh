#!/usr/bin/env bash
# Safe integration check: install everything from this repo into a throwaway
# temp project. `vstack add` resolves PROJECT scope by walking up from the
# CWD (cli/src/config.rs::find_project_root_within) looking for
# .vstack-lock.json or a harness dir (.claude/ .cursor/ .codex/ .opencode/
# .pi/ .agents/), so running it from inside this checkout installs into the
# checkout itself. This wrapper runs the install from a seeded temp dir
# instead, then verifies the printed scope actually landed there.
set -euo pipefail

script_dir=$(cd "$(dirname "$0")" && pwd -P)
cli_dir=$(cd "$script_dir/.." && pwd -P)
repo_root=$(cd "$cli_dir/.." && pwd -P)

cargo build --manifest-path "$cli_dir/Cargo.toml"

tmp_project=$(mktemp -d)
trap 'rm -rf "$tmp_project"' EXIT
mkdir "$tmp_project/.claude" # project marker — .git is not one (see config.rs)
tmp_phys=$(cd "$tmp_project" && pwd -P)

log=$tmp_project/vstack-add.log
if ! (cd "$tmp_project" && "$cli_dir/target/debug/vstack" add "$repo_root" --all --copy -y) >"$log" 2>&1; then
  cat "$log" >&2
  echo "FAIL: vstack add exited non-zero" >&2
  exit 1
fi

# display_path() shortens paths under $HOME to ~/…
tmp_display=$tmp_phys
case $tmp_phys in "$HOME"/*) tmp_display="~${tmp_phys#"$HOME"}" ;; esac

scope_line=$(grep '^Scope:' "$log" || true)
grep '^Installed' "$log" || true
echo "$scope_line"
case $scope_line in
*"($tmp_phys)"* | *"($tmp_display)"*)
  echo "OK: install landed in the temp project; source checkout untouched."
  ;;
*)
  cat "$log" >&2
  echo "FAIL: scope resolved outside the temp project (expected $tmp_phys): $scope_line" >&2
  exit 1
  ;;
esac
