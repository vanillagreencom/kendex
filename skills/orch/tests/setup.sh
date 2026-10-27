#!/usr/bin/env bash
# Surface: the orch-runtime entry, scripts/orch-runtime, and its setup route,
# scripts/setup, over agent-runtime's builder and key. Inputs:
# skills/orch/scripts/{setup,orch-runtime}, skills/orch/runtime/Cargo.toml,
# runtime/Cargo.lock, runtime/src/**, skills/agent-runtime/scripts/** and
# agent-runtime's runtime inputs.
#
# The package under test is a copy of both skills in the sibling layout an
# install produces, in scratch: <skills>/orch and <skills>/agent-runtime, each
# with its scripts/ and its runtime inputs (never target/). A fake cargo first
# on PATH records its argv and writes a small executable where a real build
# would, so no row compiles anything. ORCH_UNDER_TEST names another orch
# package directory whose scripts/ are copied instead, which is how a control
# runs a mutated wrapper.
set -euo pipefail
source "$(dirname "${BASH_SOURCE[0]}")/lib/git-env.sh"
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../.." && pwd -P)"
# shellcheck source=lib/assertions.sh
. "$ROOT/skills/orch/tests/lib/assertions.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'orch-setup: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'orch-setup: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'orch-setup: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

SKILLS="$TMP_ROOT/skills"
ORCH="$SKILLS/orch"
AGENT="$SKILLS/agent-runtime"
copy_runtime() { # SRC_SKILL DEST_SKILL
  mkdir -p "$2/runtime"
  cp -p "$1/runtime/Cargo.toml" "$1/runtime/Cargo.lock" "$2/runtime/"
  cp -R "$1/runtime/src" "$2/runtime/src"
}
mkdir -p "$ORCH/scripts" "$AGENT" "$TMP_ROOT/bin"
cp -p "${ORCH_UNDER_TEST:-$ROOT/skills/orch}/scripts/setup" "${ORCH_UNDER_TEST:-$ROOT/skills/orch}/scripts/orch-runtime" "$ORCH/scripts/"
copy_runtime "$ROOT/skills/orch" "$ORCH"
cp -R "$ROOT/skills/agent-runtime/scripts" "$AGENT/scripts"
copy_runtime "$ROOT/skills/agent-runtime" "$AGENT"
SETUP="$ORCH/scripts/setup"
WRAPPER="$ORCH/scripts/orch-runtime"

# The fake cargo: one argv line per call into FAKE_CARGO_LOG, then the
# binary a release build leaves, named as the manifest's [[bin]] names it,
# or FAKE_CARGO_EXIT and nothing.
cat >"$TMP_ROOT/bin/cargo" <<'CARGO'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$FAKE_CARGO_LOG"
if [ "${FAKE_CARGO_EXIT:-0}" -ne 0 ]; then
  echo 'fake cargo: build failed' >&2
  exit "$FAKE_CARGO_EXIT"
fi
manifest=""
while [ "$#" -gt 0 ]; do
  [ "$1" != --manifest-path ] || manifest="$2"
  shift
done
bin="$(awk '/^\[\[bin\]\]/ { in_bin = 1; next } /^\[/ { in_bin = 0 } in_bin && /^name = / { gsub(/^name = "|"$/, ""); print; exit }' "$manifest")"
[ -n "$bin" ] || { echo "fake cargo: no [[bin]] name in $manifest" >&2; exit 101; }
mkdir -p "$CARGO_TARGET_DIR/release"
printf '#!/bin/sh\necho "fake-binary argv=$*"\n' >"$CARGO_TARGET_DIR/release/$bin"
chmod 755 "$CARGO_TARGET_DIR/release/$bin"
CARGO
chmod 755 "$TMP_ROOT/bin/cargo"
export PATH="$TMP_ROOT/bin:$PATH"
export FAKE_CARGO_LOG="$TMP_ROOT/cargo.log"
: >"$FAKE_CARGO_LOG"

run() { # CACHE CMD ARGS... — stdout to $OUT, stderr to $ERR, status to $RC
  local cache="$1"
  shift
  RC=0
  AGENT_RUNTIME_CACHE="$cache" "$@" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || RC=$?
  OUT="$(cat "$TMP_ROOT/out")"
  ERR="$(cat "$TMP_ROOT/err")"
}
calls() { wc -l <"$FAKE_CARGO_LOG" | tr -d ' '; }
key_of() { # OUT — the key the success line names
  local line="$1"
  line="${line#*key=}"
  printf '%s' "${line%% *}"
}

CACHE="$TMP_ROOT/cache"

# --- setup builds once through agent-runtime's builder ---------------------
run "$CACHE" "$SETUP"
assert_eq "$RC" 0 'first setup exits 0' "$TMP_ROOT/err"
KEY="$(key_of "$OUT")"
assert_eq "${#KEY}" 64 'the key is one sha256 hex'
case "$KEY" in *[!0-9a-f]*) fail 'the key is lower-case hex' "$KEY" ;; *) pass 'the key is lower-case hex' ;; esac
assert_eq "$OUT" "orch-runtime-setup: key=$KEY binary=$CACHE/bin/orch-runtime-$KEY" 'setup prints the one machine line under the orch-runtime name'
if [ -x "$CACHE/bin/orch-runtime-$KEY" ]; then pass 'the keyed binary is executable'; else fail 'the keyed binary is executable'; fi
assert_eq "$(calls)" 1 'one cargo call'
assert_contains "$(cat "$FAKE_CARGO_LOG")" "build --release --locked --manifest-path $ORCH/runtime/Cargo.toml" 'cargo builds the locked release of the orch runtime manifest'
assert_eq "$(ls -A "$CACHE/bin")" "orch-runtime-$KEY" 'bin/ holds the binary and no temporary'
if [ -d "$CACHE/build/orch-runtime/$KEY" ]; then pass 'the build lands under the name and the key'; else fail 'the build lands under the name and the key'; fi

# --- the same key again builds nothing ------------------------------------
run "$CACHE" "$SETUP"
assert_eq "$RC" 0 'repeated setup exits 0' "$TMP_ROOT/err"
assert_eq "$OUT" "orch-runtime-setup: key=$KEY binary=$CACHE/bin/orch-runtime-$KEY" 'repeated setup prints the same line'
assert_eq "$(calls)" 1 'repeated setup calls cargo no second time'

# --- --offline reaches cargo ----------------------------------------------
run "$TMP_ROOT/cache-offline" "$SETUP" --offline
assert_eq "$RC" 0 'offline setup exits 0' "$TMP_ROOT/err"
assert_contains "$(tail -n 1 "$FAKE_CARGO_LOG")" 'build --release --locked --offline' '--offline passes to cargo'
assert_eq "$(key_of "$OUT")" "$KEY" 'the key is the inputs, not the cache or flags'

# --- the key covers both crates ---------------------------------------------
printf '\n' >>"$ORCH/runtime/src/lib.rs"
run "$TMP_ROOT/cache-orch-changed" "$SETUP"
assert_eq "$RC" 0 'setup after an orch source change exits 0' "$TMP_ROOT/err"
if [ "$(key_of "$OUT")" != "$KEY" ]; then pass 'a changed byte in the orch runtime changes the key'; else fail 'a changed byte in the orch runtime changes the key' "$KEY"; fi
cp -p "$ROOT/skills/orch/runtime/src/lib.rs" "$ORCH/runtime/src/lib.rs"
printf '\n' >>"$AGENT/runtime/src/lib.rs"
run "$TMP_ROOT/cache-agent-changed" "$SETUP"
assert_eq "$RC" 0 'setup after an agent-runtime source change exits 0' "$TMP_ROOT/err"
if [ "$(key_of "$OUT")" != "$KEY" ]; then pass 'a changed byte in agent-runtime changes the key'; else fail 'a changed byte in agent-runtime changes the key' "$KEY"; fi
cp -p "$ROOT/skills/agent-runtime/runtime/src/lib.rs" "$AGENT/runtime/src/lib.rs"
run "$CACHE" "$SETUP"
assert_eq "$(key_of "$OUT")" "$KEY" 'the restored inputs give the first key again'

# --- the wrapper execs the keyed binary, and never builds -----------------
run "$CACHE" "$WRAPPER" op --file state.json --request req.json
assert_eq "$RC" 0 'wrapper exits with the binary' "$TMP_ROOT/err"
assert_eq "$OUT" 'fake-binary argv=op --file state.json --request req.json' 'wrapper hands every argument to the keyed binary'
before="$(calls)"
run "$TMP_ROOT/cache-empty" "$WRAPPER" version
assert_eq "$RC" 69 'wrapper without a binary exits 69'
assert_eq "$ERR" "orch-runtime: setup-required key=$KEY run=$ORCH/scripts/setup" 'wrapper names the key and the setup to run'
assert_eq "$OUT" '' 'wrapper prints no reply without a binary'
assert_eq "$(calls)" "$before" 'wrapper calls cargo never'
if [ ! -e "$TMP_ROOT/cache-empty" ]; then pass 'wrapper writes no cache'; else fail 'wrapper writes no cache'; fi

# --- a failed build leaves bin/ empty --------------------------------------
FAKE_CARGO_EXIT=1 run "$TMP_ROOT/cache-failed" "$SETUP"
assert_eq "$RC" 1 'failed build exits 1'
assert_contains "$ERR" "orch-runtime-setup: build-failed status=1 key=$KEY" 'failed build refuses with its key'
assert_contains "$ERR" 'fake cargo: build failed' "cargo's stderr passes through"
assert_eq "$OUT" '' 'failed build prints no success line'
assert_eq "$(ls -A "$TMP_ROOT/cache-failed/bin")" '' 'bin/ holds nothing after a failed build'

# --- a copy without agent-runtime beside it refuses ------------------------
LONE="$TMP_ROOT/lone/orch"
mkdir -p "$LONE"
cp -R "$ORCH/scripts" "$LONE/scripts"
cp -R "$ORCH/runtime" "$LONE/runtime"
before="$(calls)"
run "$TMP_ROOT/cache-lone" "$LONE/scripts/setup"
assert_eq "$RC" 2 'setup without the sibling exits 2'
assert_eq "$ERR" "orch-runtime-setup: dependency-absent skill=agent-runtime path=$LONE/scripts/../../agent-runtime/scripts/setup" 'setup names the absent dependency'
run "$TMP_ROOT/cache-lone" "$LONE/scripts/orch-runtime" version
assert_eq "$RC" 2 'wrapper without the sibling exits 2'
assert_eq "$ERR" "orch-runtime: dependency-absent skill=agent-runtime path=$LONE/scripts/../../agent-runtime/scripts/lib/key.sh" 'wrapper names the absent dependency'
assert_eq "$(calls)" "$before" 'neither builds without the sibling'
if [ ! -e "$TMP_ROOT/cache-lone" ]; then pass 'neither writes a cache without the sibling'; else fail 'neither writes a cache without the sibling'; fi

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
