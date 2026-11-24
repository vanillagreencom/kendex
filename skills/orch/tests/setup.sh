#!/usr/bin/env bash
# Surface: the orch-runtime entry, scripts/orch-runtime, and its setup route,
# scripts/setup, over agent-runtime's builder and key. Inputs:
# skills/orch/scripts/{setup,orch-runtime}, skills/orch/runtime/Cargo.toml,
# runtime/Cargo.lock, runtime/src/**, skills/agent-runtime/scripts/** and
# agent-runtime's runtime inputs, skills/agent-runtime/tests/setup/wrapper-timeout.py.
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
printf '#!/bin/sh\necho "fake-binary argv=$*"\nexit "${FAKE_BINARY_EXIT:-0}"\n' >"$CARGO_TARGET_DIR/release/$bin"
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
key_of() { # OUT — the key the last success line, orch-runtime's, names
  local line="${1##*$'\n'}"
  line="${line#*key=}"
  printf '%s' "${line%% *}"
}

RC=0
python3 -B "$ROOT/skills/agent-runtime/tests/setup/wrapper-timeout.py" "$WRAPPER" "$AGENT/scripts/lib/key.sh" "$TMP_ROOT" 2>"$TMP_ROOT/err" || RC=$?
assert_eq "$RC" 0 'wrapper timeout during a build leaves the keyed binary ready' "$TMP_ROOT/err"
if [ "${1:-}" = wrapper-timeout ]; then
  exit "$((FAIL != 0))"
fi
: >"$FAKE_CARGO_LOG"

CACHE="$TMP_ROOT/cache"

# --- setup builds both runtimes, agent-runtime first, orch's line last -----
run "$CACHE" "$SETUP"
assert_eq "$RC" 0 'first setup exits 0' "$TMP_ROOT/err"
KEY="$(key_of "$OUT")"
AKEY="$(key_of "${OUT%%$'\n'*}")"
assert_eq "${#KEY}" 64 'the key is one sha256 hex'
case "$KEY" in *[!0-9a-f]*) fail 'the key is lower-case hex' "$KEY" ;; *) pass 'the key is lower-case hex' ;; esac
assert_eq "$OUT" "agent-runtime-setup: key=$AKEY binary=$CACHE/bin/agent-runtime-$AKEY"$'\n'"orch-runtime-setup: key=$KEY binary=$CACHE/bin/orch-runtime-$KEY" 'setup prints agent-runtime'"'"'s line, then orch-runtime'"'"'s last'
if [ -x "$CACHE/bin/orch-runtime-$KEY" ] && [ -x "$CACHE/bin/agent-runtime-$AKEY" ]; then pass 'both keyed binaries are executable'; else fail 'both keyed binaries are executable'; fi
assert_eq "$(calls)" 2 'one cargo call per runtime'
assert_eq "$(sed 's/.*--manifest-path //' "$FAKE_CARGO_LOG" | tr '\n' ',')" "$AGENT/runtime/Cargo.toml,$ORCH/runtime/Cargo.toml," 'agent-runtime builds first, then orch-runtime'
assert_contains "$(cat "$FAKE_CARGO_LOG")" "build --release --locked --manifest-path $ORCH/runtime/Cargo.toml" 'cargo builds the locked release of the orch runtime manifest'
assert_eq "$(ls -A "$CACHE/bin" | tr '\n' ' ')" "agent-runtime-$AKEY orch-runtime-$KEY " 'bin/ holds the two binaries and no temporary'
if [ -d "$CACHE/build/orch-runtime/$KEY" ]; then pass 'the build lands under the name and the key'; else fail 'the build lands under the name and the key'; fi
assert_eq "${ERR##*$'\n'}" 'fake-binary argv=ready' 'setup ends by printing the built orch-runtime'"'"'s readiness answer on stderr'

# --- the same key again builds nothing ------------------------------------
FIRST="$OUT"
run "$CACHE" "$SETUP"
assert_eq "$RC" 0 'repeated setup exits 0' "$TMP_ROOT/err"
assert_eq "$OUT" "$FIRST" 'repeated setup prints the same two lines'
assert_eq "$(calls)" 2 'repeated setup calls cargo no second time'

# --- an unready duty leaves the setup's exit the builds' -------------------
FAKE_BINARY_EXIT=1 run "$CACHE" "$SETUP"
assert_eq "$RC" 0 'a readiness answer of 1 leaves the setup exiting 0, its builds'"'"''
assert_eq "${ERR##*$'\n'}" 'fake-binary argv=ready' 'the unready answer is printed all the same'

# --- --detach starts both builds and answers the worse ---------------------
# agent-runtime built and orch-runtime's binary gone: with --hold on a
# standing path the built one answers 0 and the started one 3, and the
# setup answers 3, both lines printed in the build order.
cp -R "$CACHE" "$TMP_ROOT/cache-detach"
rm -f -- "$TMP_ROOT/cache-detach/bin/orch-runtime-$KEY"
: >"$TMP_ROOT/held"
run "$TMP_ROOT/cache-detach" "$SETUP" --detach --hold "$TMP_ROOT/held"
assert_eq "$RC" 3 'a detached setup holding a building runtime answers 3, the worse'
assert_eq "${OUT%% key=*}" 'agent-runtime-setup:' 'the detached setup answers agent-runtime first'
assert_contains "${OUT##*$'\n'}" "orch-runtime-setup: runtime-building key=$KEY" 'the detached setup starts orch-runtime'"'"'s build last'
for _ in $(seq 200); do [ ! -x "$TMP_ROOT/cache-detach/bin/orch-runtime-$KEY" ] || break; sleep 0.1; done
if [ -x "$TMP_ROOT/cache-detach/bin/orch-runtime-$KEY" ]; then pass 'the detached build places orch-runtime'; else fail 'the detached build places orch-runtime'; fi
for _ in $(seq 200); do [ -e "$TMP_ROOT/cache-detach/build/orch-runtime/$KEY.lock" ] || break; sleep 0.1; done

# --- a detached setup answers a refusal over a held build over a served one -
# agent-runtime's builder planted beside a copy of the setup as a stub that
# logs which runtime it was asked for and answers as told: each build starts
# whatever the other answered, and the setup answers the worse.
STUB="$TMP_ROOT/stub"
mkdir -p "$STUB/orch/scripts" "$STUB/agent-runtime/scripts"
cp -p "$ORCH/scripts/setup" "$STUB/orch/scripts/setup"
cat >"$STUB/agent-runtime/scripts/setup" <<'BUILDER'
#!/usr/bin/env bash
set -eu
runtime=agent-runtime
for arg in "$@"; do [ "$arg" != --runtime ] || runtime=orch-runtime; done
printf '%s\n' "$runtime" >>"$STUB_LOG"
[ "$runtime" = orch-runtime ] || exit "$STUB_AGENT_EXIT"
exit "$STUB_ORCH_EXIT"
BUILDER
chmod 755 "$STUB/agent-runtime/scripts/setup"
detached() { # AGENT_EXIT ORCH_EXIT — the stub setup's detached answer in $RC, the builds it asked in $BUILDS
  : >"$TMP_ROOT/stub.log"
  STUB_LOG="$TMP_ROOT/stub.log" STUB_AGENT_EXIT="$1" STUB_ORCH_EXIT="$2" run "$TMP_ROOT/cache-stub" "$STUB/orch/scripts/setup" --detach
  BUILDS="$(tr '\n' ' ' <"$TMP_ROOT/stub.log")"
}
detached 1 3
assert_eq "$RC" 1 'a detached setup answers agent-runtime'"'"'s refusal over orch-runtime'"'"'s held build'
assert_eq "$BUILDS" 'agent-runtime orch-runtime ' 'a refused agent-runtime build still starts orch-runtime'"'"'s'
detached 3 0
assert_eq "$RC" 3 'a detached setup answers agent-runtime'"'"'s held build over orch-runtime'"'"'s served one'
assert_eq "$BUILDS" 'agent-runtime orch-runtime ' 'a held agent-runtime build still starts orch-runtime'"'"'s'
detached 3 2
assert_eq "$RC" 2 'a detached setup answers orch-runtime'"'"'s refusal over agent-runtime'"'"'s held build'

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

# --- the wrapper execs the keyed binary, and builds a missing one ----------
run "$CACHE" "$WRAPPER" op --file state.json --request req.json
assert_eq "$RC" 0 'wrapper exits with the binary' "$TMP_ROOT/err"
assert_eq "$OUT" 'fake-binary argv=op --file state.json --request req.json' 'wrapper hands every argument to the keyed binary'

# A PATH holding every tool the wrapper reads but cargo.
NOCARGO="$TMP_ROOT/no-cargo-bin"
mkdir -p "$NOCARGO"
for tool in awk bash cat cut find sh sha256sum shasum sort tr wc; do
  if found="$(command -v "$tool")"; then ln -s "$found" "$NOCARGO/$tool"; fi
done
before="$(calls)"
RC=0
OUT="$(PATH="$NOCARGO" AGENT_RUNTIME_CACHE="$TMP_ROOT/cache-empty" "$WRAPPER" version 2>"$TMP_ROOT/err")" || RC=$?
assert_eq "$RC|$(cat "$TMP_ROOT/err")|$OUT|$(calls)" "69|orch-runtime: setup-required key=$KEY run=$ORCH/scripts/setup||$before" \
  'wrapper on a computer with no cargo exits 69, names the key and the setup to run, and prints no reply'
if [ ! -e "$TMP_ROOT/cache-empty" ]; then pass 'wrapper with no cargo writes no cache'; else fail 'wrapper with no cargo writes no cache'; fi

# The checkout moves to new orch runtime sources by a plain fast-forward, as
# a person's or an automation's pull moves it, and the next call answers.
MOVED="$TMP_ROOT/moved"
mkdir -p "$MOVED"
cp -R "$SKILLS" "$MOVED/skills"
git -C "$MOVED" init -q -b main
git -C "$MOVED" config gc.auto 0
git -C "$MOVED" config maintenance.auto false
git -C "$MOVED" add -A
git -C "$MOVED" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m base
git -C "$MOVED" checkout -q -b topic
printf '// moved\n' >>"$MOVED/skills/orch/runtime/src/lib.rs"
git -C "$MOVED" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -am moved
git -C "$MOVED" checkout -q main
MC="$TMP_ROOT/cache-moved"
run "$MC" "$MOVED/skills/orch/scripts/setup"
assert_eq "$RC|$(key_of "$OUT")" "0|$KEY" 'premise: the checkout before the move holds the program for its key' "$TMP_ROOT/err"
git -C "$MOVED" merge -q --ff-only topic
before="$(calls)"
run "$MC" "$MOVED/skills/orch/scripts/orch-runtime" version
MOVED_KEY="$(key_of "$(grep '^orch-runtime-setup: key=' "$TMP_ROOT/err")")"
assert_eq "$RC|$OUT|$(calls)" "0|fake-binary argv=version|$((before + 1))" \
  'after a fast-forward past an orch runtime change the next call builds it once and answers' "$TMP_ROOT/err"
assert_eq "$(head -n 1 "$TMP_ROOT/err")" "orch-runtime: setup-building key=$MOVED_KEY run=$MOVED/skills/orch/scripts/setup" \
  'the call names the runtime and key it builds on its first stderr line'
if [ "$MOVED_KEY" != "$KEY" ] && [ -x "$MC/bin/orch-runtime-$MOVED_KEY" ]; then pass 'the build placed the moved sources'"'"' own key'; else fail 'the build placed the moved sources'"'"' own key' "$MOVED_KEY"; fi

# A build that fails ends the call with the setup's refusal, last on stderr.
printf '// failing\n' >>"$MOVED/skills/orch/runtime/src/lib.rs"
FAKE_CARGO_EXIT=1 run "$MC" "$MOVED/skills/orch/scripts/orch-runtime" version
assert_eq "$RC|$OUT" '69|' 'a call whose build fails exits 69 with no reply'
case "$(head -n 1 "$TMP_ROOT/err")" in
  "orch-runtime: setup-building key="*" run=$MOVED/skills/orch/scripts/setup") pass 'a call whose build fails names the build first' ;;
  *) fail 'a call whose build fails names the build first' "$ERR" ;;
esac
case "${ERR##*$'\n'}" in
  'orch-runtime-setup: build-failed status=1 key='*) pass "the setup's refusal is the call's last stderr line" ;;
  *) fail "the setup's refusal is the call's last stderr line" "$ERR" ;;
esac

# --- a failed build leaves bin/ empty --------------------------------------
before="$(calls)"
FAKE_CARGO_EXIT=1 run "$TMP_ROOT/cache-failed" "$SETUP"
assert_eq "$RC" 1 'failed build exits 1'
assert_contains "$ERR" "agent-runtime-setup: build-failed status=1 key=$AKEY" 'failed build refuses with its key'
assert_eq "$(calls)" "$((before + 1))" 'a failed agent-runtime build ends the setup before orch-runtime'"'"'s'
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
