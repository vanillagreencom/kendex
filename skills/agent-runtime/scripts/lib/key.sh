# shellcheck shell=bash
# The build key of a shipped runtime crate and the cache it is built into:
# one sha256 over every input the binary is built from, so a binary in the
# user cache is selected only by the bytes it was built from, never by a
# repository revision or a directory name.
#
# agent_runtime_key RUNTIME_DIR prints the 64-hex key of RUNTIME_DIR's
# Cargo.toml, Cargo.lock and every file under src/, each entered into the
# manifest as its path relative to RUNTIME_DIR followed by its own digest, in
# byte order of the paths; then, for every `path = "..."` dependency the
# manifest's [dependencies] tables declare, that crate's inputs the same way,
# under the declared path, recursively. The manifest's digest is the key. A
# changed byte in any input, an added or removed source file, a renamed one,
# or a changed dependency path changes it. orch-runtime declares agent-runtime
# by path, so its key covers both crates.
#
# agent_runtime_cache prints the cache root: $AGENT_RUNTIME_CACHE, else
# $XDG_CACHE_HOME/kendex/agent-runtime, else ~/.cache/kendex/agent-runtime.
# A binary sits at <cache>/bin/<name>-<key>, its build at
# <cache>/build/<name>/<key>; setup and every wrapper read that layout here.
#
# Sourced by scripts/setup, scripts/agent-runtime and the wrappers of crates
# that depend on this one, never executed. Bash 3.2-safe. The caller defines
# `refuse KEY VALUE...` for the diagnostics: digest-tool-missing,
# inputs-missing, inputs-unreadable, manifest-unreadable, digest-failed.

# agent_runtime_digest reads stdin and prints its sha256 hex. sha256sum is
# coreutils; macOS ships shasum instead.
if command -v sha256sum >/dev/null 2>&1; then
  agent_runtime_digest() { sha256sum | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  agent_runtime_digest() { shasum -a 256 | cut -d' ' -f1; }
else
  agent_runtime_digest() { return 127; }
fi

agent_runtime_cache() {
  printf '%s\n' "${AGENT_RUNTIME_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/kendex/agent-runtime}"
}

# agent_runtime_path_dependencies RUNTIME_DIR prints the `path` of every
# dependency the manifest's [dependencies] tables declare, one per line, in
# file order: `name = { path = "..." }` inline, or `path = "..."` under a
# `[dependencies.name]` table. [dev-dependencies] and [build-dependencies]
# build no shipped binary and are not read. A comment line is skipped.
agent_runtime_path_dependencies() { # RUNTIME_DIR
  awk '
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[/ { in_deps = ($0 ~ /^[[:space:]]*\[dependencies(\.[^]]*)?\][[:space:]]*$/); next }
    in_deps && match($0, /path[[:space:]]*=[[:space:]]*"[^"]*"/) {
      s = substr($0, RSTART, RLENGTH)
      sub(/^path[[:space:]]*=[[:space:]]*"/, "", s)
      sub(/"$/, "", s)
      print s
    }
  ' "$1/Cargo.toml"
}

# agent_runtime_manifest RUNTIME_DIR PREFIX prints the manifest lines of
# RUNTIME_DIR and its path dependencies, each path under PREFIX.
agent_runtime_manifest() { # RUNTIME_DIR PREFIX
  local dir="$1" prefix="$2" rel paths digest deps dep
  [ -f "$dir/Cargo.toml" ] && [ -f "$dir/Cargo.lock" ] && [ -d "$dir/src" ] ||
    refuse inputs-missing "runtime=$dir"
  [ -r "$dir/Cargo.toml" ] || refuse manifest-unreadable "path=$dir/Cargo.toml"
  # One stable order whatever the filesystem returns: byte order of the
  # relative paths. Source paths are the package's own and hold no newline.
  paths="$(cd -- "$dir" && find src -type f | LC_ALL=C sort)" || refuse inputs-unreadable "runtime=$dir"
  while IFS= read -r rel; do
    [ -n "$rel" ] || continue
    digest="$(agent_runtime_digest <"$dir/$rel")" || refuse inputs-unreadable "path=$dir/$rel"
    printf '%s%s %s\n' "$prefix" "$rel" "$digest"
  done <<EOF
Cargo.toml
Cargo.lock
$paths
EOF
  deps="$(agent_runtime_path_dependencies "$dir")" || refuse manifest-unreadable "path=$dir/Cargo.toml"
  while IFS= read -r dep; do
    [ -n "$dep" ] || continue
    agent_runtime_manifest "$dir/$dep" "$prefix$dep/"
  done <<EOF
$deps
EOF
}

agent_runtime_key() { # RUNTIME_DIR
  local manifest key
  agent_runtime_digest </dev/null >/dev/null 2>&1 || refuse digest-tool-missing "wanted=sha256sum|shasum"
  manifest="$(agent_runtime_manifest "$1" "")" || exit 1
  key="$(printf '%s\n' "$manifest" | agent_runtime_digest)" || refuse digest-failed "runtime=$1"
  [ "${#key}" -eq 64 ] || refuse digest-failed "runtime=$1 got=$key"
  printf '%s\n' "$key"
}
