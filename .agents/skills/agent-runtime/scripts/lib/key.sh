# shellcheck shell=bash
# The build key of the shipped runtime: one sha256 over every input the
# binary is built from, so a binary in the user cache is selected only by the
# bytes it was built from, never by a repository revision or a directory name.
#
# agent_runtime_key RUNTIME_DIR prints the 64-hex key of RUNTIME_DIR's
# Cargo.toml, Cargo.lock and every file under src/, each entered into the
# manifest as its path relative to RUNTIME_DIR followed by its own digest, in
# byte order of the paths. The manifest's digest is the key. A changed byte
# in any input, an added or removed source file, or a renamed one changes it.
#
# Sourced by scripts/setup and scripts/agent-runtime, never executed. Bash
# 3.2-safe. The caller defines `refuse KEY VALUE...` for the diagnostics.

# agent_runtime_digest reads stdin and prints its sha256 hex. sha256sum is
# coreutils; macOS ships shasum instead.
if command -v sha256sum >/dev/null 2>&1; then
  agent_runtime_digest() { sha256sum | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  agent_runtime_digest() { shasum -a 256 | cut -d' ' -f1; }
else
  agent_runtime_digest() { return 127; }
fi

agent_runtime_key() { # RUNTIME_DIR
  local dir="$1" rel paths manifest key
  agent_runtime_digest </dev/null >/dev/null 2>&1 || refuse digest-tool-missing "wanted=sha256sum|shasum"
  [ -f "$dir/Cargo.toml" ] && [ -f "$dir/Cargo.lock" ] && [ -d "$dir/src" ] ||
    refuse inputs-missing "runtime=$dir"
  # One stable order whatever the filesystem returns: byte order of the
  # relative paths. Source paths are the package's own and hold no newline.
  paths="$(cd -- "$dir" && find src -type f | LC_ALL=C sort)" || refuse inputs-unreadable "runtime=$dir"
  manifest=""
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    key="$(agent_runtime_digest <"$dir/$rel")" || refuse inputs-unreadable "path=$dir/$rel"
    manifest="$manifest$rel $key
"
  done <<EOF
Cargo.toml
Cargo.lock
$paths
EOF
  key="$(printf '%s' "$manifest" | agent_runtime_digest)" || refuse digest-failed "runtime=$dir"
  [ "${#key}" -eq 64 ] || refuse digest-failed "runtime=$dir got=$key"
  printf '%s\n' "$key"
}
