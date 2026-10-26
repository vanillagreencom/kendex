#!/usr/bin/env bash
# Surface: the agent-runtime setup route and its wrapper. Inputs:
# skills/agent-runtime/scripts/**, skills/agent-runtime/runtime/Cargo.toml,
# runtime/Cargo.lock, runtime/src/**.
#
# A fake cargo first on PATH records its argv and writes a small executable
# where a real build would, so no row compiles anything. The package under
# test is a copy of scripts/ beside a copy of the runtime inputs, in scratch;
# AGENT_RUNTIME_UNDER_TEST names another package directory whose scripts/ are
# copied instead, which is how a control runs a mutated setup.
set -euo pipefail
ROOT="$(cd -- "${BASH_SOURCE[0]%/*}/../../../.." && pwd -P)"
# shellcheck source=../../../orch/tests/lib/assertions.sh
. "$ROOT/skills/orch/tests/lib/assertions.sh"
TMP_ROOT="$(mktemp -d)" || { echo 'agent-runtime-setup: scratch=mktemp-failed' >&2; exit 1; }
[[ -d $TMP_ROOT && ! -L $TMP_ROOT ]] || { echo 'agent-runtime-setup: scratch=not-a-directory' >&2; exit 1; }
TMP_ROOT="$(cd -- "$TMP_ROOT" && pwd -P)" || { echo 'agent-runtime-setup: scratch=resolve-failed' >&2; exit 1; }
trap 'rm -rf -- "${TMP_ROOT:?}"' EXIT

SRC="$ROOT/skills/agent-runtime"
PKG="$TMP_ROOT/pkg"
mkdir -p "$PKG/runtime" "$TMP_ROOT/bin"
cp -R "${AGENT_RUNTIME_UNDER_TEST:-$SRC}/scripts" "$PKG/scripts"
cp -p "$SRC/runtime/Cargo.toml" "$SRC/runtime/Cargo.lock" "$PKG/runtime/"
cp -R "$SRC/runtime/src" "$PKG/runtime/src"
SETUP="$PKG/scripts/setup"
WRAPPER="$PKG/scripts/agent-runtime"

# The fake cargo: one argv line per call into FAKE_CARGO_LOG, then the
# binary a release build leaves, or FAKE_CARGO_EXIT and nothing.
cat >"$TMP_ROOT/bin/cargo" <<'CARGO'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >>"$FAKE_CARGO_LOG"
if [ "${FAKE_CARGO_EXIT:-0}" -ne 0 ]; then
  echo 'fake cargo: build failed' >&2
  exit "$FAKE_CARGO_EXIT"
fi
mkdir -p "$CARGO_TARGET_DIR/release"
printf '#!/bin/sh\necho "fake-binary argv=$*"\n' >"$CARGO_TARGET_DIR/release/agent-runtime"
chmod 755 "$CARGO_TARGET_DIR/release/agent-runtime"
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

# --- first setup builds once and places the keyed binary ------------------
run "$CACHE" "$SETUP"
assert_eq "$RC" 0 'first setup exits 0' "$TMP_ROOT/err"
KEY="$(key_of "$OUT")"
assert_eq "${#KEY}" 64 'the key is one sha256 hex'
case "$KEY" in *[!0-9a-f]*) fail 'the key is lower-case hex' "$KEY" ;; *) pass 'the key is lower-case hex' ;; esac
assert_eq "$OUT" "agent-runtime-setup: key=$KEY binary=$CACHE/bin/agent-runtime-$KEY" 'setup prints the one machine line'
if [ -x "$CACHE/bin/agent-runtime-$KEY" ]; then pass 'the keyed binary is executable'; else fail 'the keyed binary is executable'; fi
assert_eq "$(calls)" 1 'one cargo call'
assert_contains "$(cat "$FAKE_CARGO_LOG")" "build --release --locked --manifest-path $PKG/runtime/Cargo.toml" 'cargo builds the locked release of the package manifest'
assert_not_contains "$(cat "$FAKE_CARGO_LOG")" '--offline' 'no --offline without the flag'
assert_eq "$(ls -A "$CACHE/bin")" "agent-runtime-$KEY" 'bin/ holds the binary and no temporary'

# --- the same key again builds nothing ------------------------------------
run "$CACHE" "$SETUP"
assert_eq "$RC" 0 'repeated setup exits 0' "$TMP_ROOT/err"
assert_eq "$OUT" "agent-runtime-setup: key=$KEY binary=$CACHE/bin/agent-runtime-$KEY" 'repeated setup prints the same line'
assert_eq "$(calls)" 1 'repeated setup calls cargo no second time'

# --- --offline reaches cargo ----------------------------------------------
run "$TMP_ROOT/cache-offline" "$SETUP" --offline
assert_eq "$RC" 0 'offline setup exits 0' "$TMP_ROOT/err"
assert_contains "$(tail -n 1 "$FAKE_CARGO_LOG")" 'build --release --locked --offline' '--offline passes to cargo'
assert_eq "$(key_of "$OUT")" "$KEY" 'the key is the inputs, not the cache or flags'

# --- one changed source byte is another key -------------------------------
printf '\n' >>"$PKG/runtime/src/lib.rs"
run "$TMP_ROOT/cache-changed" "$SETUP"
assert_eq "$RC" 0 'setup after a source change exits 0' "$TMP_ROOT/err"
KEY2="$(key_of "$OUT")"
if [ "$KEY2" != "$KEY" ]; then pass 'a changed source byte changes the key'; else fail 'a changed source byte changes the key' "$KEY2"; fi
if [ -x "$TMP_ROOT/cache-changed/bin/agent-runtime-$KEY2" ]; then pass 'the new key gets its own binary'; else fail 'the new key gets its own binary'; fi
# Put the byte back: the rows below speak of KEY.
cp -p "$SRC/runtime/src/lib.rs" "$PKG/runtime/src/lib.rs"

# --- the wrapper execs the keyed binary, and never builds -----------------
run "$CACHE" "$WRAPPER" inspect --record r.json
assert_eq "$RC" 0 'wrapper exits with the binary' "$TMP_ROOT/err"
assert_eq "$OUT" 'fake-binary argv=inspect --record r.json' 'wrapper hands every argument to the keyed binary'
before="$(calls)"
run "$TMP_ROOT/cache-empty" "$WRAPPER" version
assert_eq "$RC" 69 'wrapper without a binary exits 69'
assert_eq "$ERR" "agent-runtime: setup-required key=$KEY run=$PKG/scripts/setup" 'wrapper names the key and the setup to run'
assert_eq "$OUT" '' 'wrapper prints no reply without a binary'
assert_eq "$(calls)" "$before" 'wrapper calls cargo never'
if [ ! -e "$TMP_ROOT/cache-empty" ]; then pass 'wrapper writes no cache'; else fail 'wrapper writes no cache'; fi

# --- a failed build leaves bin/ empty --------------------------------------
FAKE_CARGO_EXIT=1 run "$TMP_ROOT/cache-failed" "$SETUP"
assert_eq "$RC" 1 'failed build exits 1'
assert_contains "$ERR" "agent-runtime-setup: build-failed status=1 key=$KEY" 'failed build refuses with its key'
assert_contains "$ERR" 'fake cargo: build failed' "cargo's stderr passes through"
assert_eq "$OUT" '' 'failed build prints no success line'
assert_eq "$(ls -A "$TMP_ROOT/cache-failed/bin")" '' 'bin/ holds nothing after a failed build'

# --- the default cache root is XDG --------------------------------------
RC=0
env -u AGENT_RUNTIME_CACHE XDG_CACHE_HOME="$TMP_ROOT/xdg" "$SETUP" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || RC=$?
assert_eq "$RC" 0 'setup under XDG_CACHE_HOME exits 0' "$TMP_ROOT/err"
assert_eq "$(cat "$TMP_ROOT/out")" "agent-runtime-setup: key=$KEY binary=$TMP_ROOT/xdg/kendex/agent-runtime/bin/agent-runtime-$KEY" 'the default cache is kendex/agent-runtime under XDG_CACHE_HOME'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
