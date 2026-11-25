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
# that depend on this one, never executed. Wrappers also share the
# foreground setup launch here. Bash 3.2-safe. The caller defines
# `refuse KEY VALUE...` for the diagnostics: digest-tool-missing,
# inputs-missing, inputs-unreadable, manifest-unreadable, digest-failed.
#
# Fleet's fleet-sync fills its runtime cache from artifacts named
# orch-runtime-<key> and agent-runtime-<key>, uploaded by
# .github/workflows/skill-tests.yml in a push run on main or a merge_group
# run on a gh-readonly-queue/main/ branch. Each artifact holds two members:
# the binary and its <name>-<key>.sha256. Fleet relies on the key
# agent_runtime_key computes, that function staying defined in the wrapper's
# shell, the <cache>/bin/<name>-<key> layout, those artifact names, members
# and workflow path, and the wrappers exiting 69 for a missing binary without
# an EXIT trap of their own. Send changes to any of these dependencies to
# Fleet's overseer by peer mail before they land.

# agent_runtime_digest reads stdin and prints its sha256 hex. sha256sum is
# coreutils; macOS ships shasum instead.
# agent_runtime_digest_files FILE... prints `<hex>  <file>` for each FILE in
# argument order, in one process, so a key costs a few processes per crate
# rather than several per input.
if command -v sha256sum >/dev/null 2>&1; then
  agent_runtime_digest() { sha256sum | cut -d' ' -f1; }
  agent_runtime_digest_files() { sha256sum "$@"; }
elif command -v shasum >/dev/null 2>&1; then
  agent_runtime_digest() { shasum -a 256 | cut -d' ' -f1; }
  agent_runtime_digest_files() { shasum -a 256 "$@"; }
else
  agent_runtime_digest() { return 127; }
  agent_runtime_digest_files() { return 127; }
fi

agent_runtime_cache() {
  printf '%s\n' "${AGENT_RUNTIME_CACHE:-${XDG_CACHE_HOME:-$HOME/.cache}/kendex/agent-runtime}"
}

# The publisher in skill-tests.yml builds on Linux x86_64. Its executable
# can still require libraries the host lacks, so probe it before placement.
agent_runtime_fetch() ( # BINARY
  local binary="$1" name="${1##*/}" tool scratch candidates artifact run record expected actual status
  local run_cause="" unread_run=""
  local api="repos/vanillagreencom/kendex/actions"
  for tool in gh jq unzip timeout; do command -v "$tool" >/dev/null 2>&1 || return 1; done
  [ "$(uname -sm)" = 'Linux x86_64' ] || return 1
  # Jarvis matches keyed runtime refusals by prefix. Fetch notices use their own.
  unavailable() {
    printf '%s-fetch: fetch-unavailable cause=%s artifact=%s%s\n' "${name%-*}" "$1" "$name" "${2:+ run=$2}" >&2
    return 1
  }
  mkdir -p -- "${binary%/*}" || { unavailable cache-unwritable; return 1; }
  scratch="$(mktemp -d -- "${binary%/*}/.fetch.XXXXXXXX")" || { unavailable cache-unwritable; return 1; }
  trap 'rm -rf -- "${scratch:?}"' EXIT
  # Leave time to start detached setup before Jarvis's 10-second
  # op_fifo.py record read expires. The version probe shares this budget.
  SECONDS=0
  within_budget() {
    local left=$((6 - SECONDS))
    [ "$left" -gt 0 ] || return 124
    timeout -k 1s "${left}s" "$@" </dev/null
  }
  api_read() { GH_PROMPT_DISABLED=1 within_budget gh api --hostname github.com "$@"; }
  candidates="$(api_read --paginate "$api/artifacts?name=$name&per_page=100" |
    jq -rs --arg name "$name" '
      if length == 0 or any(.[]; (.artifacts | type) != "array") then error("artifact listing") else
        [.[] .artifacts[] | select(.name == $name and .expired == false)
          | [.id, .workflow_run.id] | select(all(.[]; type == "number" and . > 0 and floor == .))]
        | unique | reverse[] | @tsv
      end')" || { unavailable listing; return 1; }
  while read -r artifact run; do
    [ -n "$artifact" ] || break
    if ! record="$(api_read "$api/runs/$run")"; then
      run_cause=run-lookup unread_run="$run"
      continue
    fi
    # The installed wrapper has no repo-local tools/ci-job-set. Its
    # PUBLISHED_RUN contract takes provenance from the run record because
    # GitHub's artifact listing omits the event and workflow.
    status=0
    jq -es --argjson run "$run" '
      if length != 1 or (.[0] | type != "object"
        or (all(.id, .repository.id, .head_repository.id; type == "number") | not)
        or (all(.repository.full_name, .path, .event, .head_branch; type == "string") | not))
      then error("workflow run record") else (.[0] | .id == $run
      and .repository.full_name == "vanillagreencom/kendex"
      and .head_repository.id == .repository.id
      and .path == ".github/workflows/skill-tests.yml"
      and ((.event == "push" and .head_branch == "main")
        or (.event == "merge_group" and (.head_branch | startswith("gh-readonly-queue/main/"))))) end' \
      <<<"$record" >/dev/null || status=$?
    case "$status" in
      0) ;;
      1) continue ;;
      *) run_cause=run-parse unread_run="$run"; continue ;;
    esac
    printf '%s-fetch: fetching artifact=%s run=%s\n' "${name%-*}" "$name" "$run" >&2
    if ! { api_read "$api/artifacts/$artifact/zip" >"$scratch/build.zip" &&
      unzip -p "$scratch/build.zip" "$name" >"$scratch/$name" &&
      expected="$(unzip -p "$scratch/build.zip" "$name.sha256")"; }; then
      unavailable download
      return 1
    fi
    actual="$(agent_runtime_digest <"$scratch/$name")" &&
      [ "$expected" = "$actual  $name" ] || { unavailable checksum; return 1; }
    chmod -- 755 "$scratch/$name" || { unavailable placement; return 1; }
    status=0
    within_budget "$scratch/$name" --version >/dev/null || status=$?
    case "$status" in
      0) ;;
      124) unavailable fetch-timeout; return 1 ;;
      137) unavailable probe-interrupted; return 1 ;;
      *) unavailable incompatible; return 1 ;;
    esac
    # Both paths are in bin/, so even concurrent installers expose the
    # whole executable in one rename.
    mv -fT -- "$scratch/$name" "$binary" || { unavailable placement; return 1; }
    return 0
  done <<<"$candidates"
  unavailable "${run_cause:-no-published-artifact}" "$unread_run"
)

agent_runtime_setup_required() { # BINARY SETUP_PATH KEY
  local name="${1##*/}"
  printf '%s: setup-required key=%s run=%s\n' "${name%-*}" "$3" "$2" >&2
}

agent_runtime_prepare() { # BINARY SETUP_PATH KEY
  local binary="$1" setup="$2" key="$3" fetch_log name="${1##*/}"
  if fetch_log="$(agent_runtime_fetch "$binary" 2>&1)" || [ -x "$binary" ]; then
    [ -z "$fetch_log" ] || printf '%s\n' "$fetch_log" >&2
    return 0
  fi
  if command -v cargo >/dev/null 2>&1; then
    printf '%s: setup-building key=%s run=%s\n' "${name%-*}" "$key" "$setup" >&2
    [ -z "$fetch_log" ] || printf '%s\n' "$fetch_log" >&2
    agent_runtime_run_setup "$setup"
    return
  fi
  # Jarvis's jarvis_bound forwards only the first line of a refusal.
  agent_runtime_setup_required "$binary" "$setup" "$key"
  [ -z "$fetch_log" ] || printf '%s\n' "$fetch_log" >&2
  return 69
}

# The setup job has its own process group, so it survives a caller's
# group timeout. Relay both streams to the caller's stderr while it reads.
# If that pipe closes, keep draining so setup never writes to a broken pipe.
agent_runtime_run_setup() { # SETUP_PATH
  set -m
  (
    trap '' HUP
    "$1" </dev/null 2>&1 | (
      # TOSTOP can stop this background writer at the caller's terminal.
      trap '' TTOU
      cat 2>/dev/null || cat >/dev/null
    )
  ) >&2 &
  set +m
  wait "$!"
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
  local dir="$1" prefix="$2" rel paths digests deps dep
  local -a inputs
  [ -f "$dir/Cargo.toml" ] && [ -f "$dir/Cargo.lock" ] && [ -d "$dir/src" ] ||
    refuse inputs-missing "runtime=$dir"
  [ -r "$dir/Cargo.toml" ] || refuse manifest-unreadable "path=$dir/Cargo.toml"
  # One stable order whatever the filesystem returns: byte order of the
  # relative paths. Source paths are the package's own and hold no newline
  # and no backslash, so each digest line is the hex, two spaces and the path.
  paths="$(cd -- "$dir" && find src -type f | LC_ALL=C sort)" || refuse inputs-unreadable "runtime=$dir"
  inputs=(Cargo.toml Cargo.lock)
  while IFS= read -r rel; do
    [ -z "$rel" ] || inputs+=("$rel")
  done <<EOF
$paths
EOF
  digests="$(cd -- "$dir" && agent_runtime_digest_files "${inputs[@]}")" || refuse inputs-unreadable "runtime=$dir"
  [ "$(printf '%s\n' "$digests" | wc -l)" -eq "${#inputs[@]}" ] || refuse inputs-unreadable "runtime=$dir"
  printf '%s\n' "$digests" | awk -v prefix="$prefix" '{ print prefix substr($0, 67) " " substr($0, 1, 64) }'
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
