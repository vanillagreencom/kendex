#!/usr/bin/env bash
# Surface: the agent-runtime setup route and its wrapper. Inputs:
# skills/agent-runtime/scripts/**, skills/agent-runtime/runtime/Cargo.toml,
# runtime/Cargo.lock, runtime/src/**, skills/agent-runtime/tests/setup/wrapper-timeout.py.
#
# The planted cargo beside this suite, first on PATH, records its argv and
# writes a small executable where a real build would, so no row compiles
# anything. The package under
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

ln -s "$SRC/tests/setup/cargo" "$TMP_ROOT/bin/cargo"
ln -s "$SRC/tests/setup/rustup" "$TMP_ROOT/bin/rustup"
ln -s "$SRC/tests/setup/rustup" "$TMP_ROOT/bin/rustc"
export FAKE_TOOLCHAINS=1.96.1
# A caller under `rustup run` would otherwise choose the planted toolchain.
unset RUSTUP_TOOLCHAIN
unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE
# Setup reads the home directory's skills after a build: a scratch home.
export HOME="$TMP_ROOT/home"
export XDG_CONFIG_HOME="$HOME/.config" XDG_DATA_HOME="$HOME/.local/share" XDG_STATE_HOME="$HOME/.local/state" XDG_CACHE_HOME="$HOME/.cache"
mkdir -p "$HOME"
# The planted kendex answers `project list --json` from FAKE_KENDEX_REGISTRY,
# or exits FAKE_KENDEX_EXIT.
cat >"$TMP_ROOT/bin/kendex" <<'SHIM'
#!/bin/sh
[ "$*" = 'project list --json' ] || exit 97
[ "${FAKE_KENDEX_EXIT:-0}" -eq 0 ] || exit "$FAKE_KENDEX_EXIT"
cat "$FAKE_KENDEX_REGISTRY"
SHIM
chmod 755 "$TMP_ROOT/bin/kendex"
export FAKE_KENDEX_REGISTRY="$TMP_ROOT/registry.json"
printf '[]\n' >"$FAKE_KENDEX_REGISTRY"

# chmod as BSD reads its arguments, first on PATH for every row, so a Linux
# run fails the placement a macOS one fails: getopt(3) stops at the first
# non-option, which is the mode, and a `--` after it is a file operand. BSD
# reports it, still changes the real operands and exits 1; so does the shim.
REAL_CHMOD="$(command -v chmod)"
cat >"$TMP_ROOT/bin/chmod" <<SHIM
#!/bin/sh
n=\$#; i=0; phase=opts; bad=0
while [ "\$i" -lt "\$n" ]; do
  arg=\$1; shift; i=\$((i + 1))
  case "\$phase" in
    opts) case "\$arg" in
      --) phase=mode; continue ;;
      -[RfhvHLP]*) set -- "\$@" "\$arg"; continue ;;
      *) phase=files; set -- "\$@" "\$arg"; continue ;;
    esac ;;
    mode) phase=files; set -- "\$@" "\$arg"; continue ;;
    files) if [ "\$arg" = "--" ]; then bad=1; echo "chmod: --: No such file or directory" >&2; continue; fi; set -- "\$@" "\$arg" ;;
  esac
done
"$REAL_CHMOD" "\$@"; rc=\$?
[ "\$bad" -eq 0 ] || exit 1
exit "\$rc"
SHIM
"$REAL_CHMOD" 755 "$TMP_ROOT/bin/chmod"
export PATH="$TMP_ROOT/bin:$PATH"
: >"$TMP_ROOT/probe-after"
: >"$TMP_ROOT/probe-before"
RC=0
chmod 755 -- "$TMP_ROOT/probe-after" 2>/dev/null || RC=$?
assert_eq "$RC" 1 'premise: the chmod shim fails a -- after the mode, as BSD chmod does'
RC=0
chmod -- 755 "$TMP_ROOT/probe-before" || RC=$?
assert_eq "$RC" 0 'premise: the chmod shim passes a -- before the mode to the real chmod'
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

RC=0
python3 -B "$SRC/tests/setup/wrapper-timeout.py" "$WRAPPER" "$PKG/scripts/lib/key.sh" "$TMP_ROOT" 2>"$TMP_ROOT/err" || RC=$?
assert_eq "$RC" 0 'wrapper timeout during a build leaves the keyed binary ready' "$TMP_ROOT/err"
if [ "${1:-}" = wrapper-timeout ]; then
  exit "$((FAIL != 0))"
fi
: >"$FAKE_CARGO_LOG"

CACHE="$TMP_ROOT/cache"

# --- first setup builds once and places the keyed binary ------------------
# Under the chmod shim above: a placement whose chmod puts `--` after the
# mode fails here with place-failed.
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

# --- the wrapper execs the keyed binary, and builds a missing one ----------
run "$CACHE" "$WRAPPER" inspect --record r.json
assert_eq "$RC" 0 'wrapper exits with the binary' "$TMP_ROOT/err"
assert_eq "$OUT" 'fake-binary argv=inspect --record r.json' 'wrapper hands every argument to the keyed binary'

# A PATH holding every tool the wrapper and the setup read but cargo.
NOCARGO="$TMP_ROOT/no-cargo-bin"
mkdir -p "$NOCARGO"
for tool in awk bash cat chmod cut date find ln mkdir mv readlink rm sh sha256sum shasum sort tr wc; do
  if found="$(command -v "$tool")"; then ln -s "$found" "$NOCARGO/$tool"; fi
done
before="$(calls)"
RC=0
OUT="$(PATH="$NOCARGO" AGENT_RUNTIME_CACHE="$TMP_ROOT/cache-empty" "$WRAPPER" version 2>"$TMP_ROOT/err")" || RC=$?
assert_eq "$RC|$(cat "$TMP_ROOT/err")|$OUT|$(calls)" "69|agent-runtime: setup-required key=$KEY run=$PKG/scripts/setup||$before" \
  'wrapper on a computer with no cargo exits 69, names the key and the setup to run, and prints no reply'
if [ ! -e "$TMP_ROOT/cache-empty" ]; then pass 'wrapper with no cargo writes no cache'; else fail 'wrapper with no cargo writes no cache'; fi

# The checkout moves to new runtime sources by a plain fast-forward, as a
# person's or an automation's pull moves it, and the next call answers.
MOVED="$TMP_ROOT/moved"
mkdir -p "$MOVED"
cp -R "$PKG/scripts" "$PKG/runtime" "$MOVED/"
git -C "$MOVED" init -q -b main
git -C "$MOVED" config gc.auto 0
git -C "$MOVED" config maintenance.auto false
git -C "$MOVED" add -A
git -C "$MOVED" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m base
git -C "$MOVED" checkout -q -b topic
printf '// moved\n' >>"$MOVED/runtime/src/lib.rs"
git -C "$MOVED" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -am moved
git -C "$MOVED" checkout -q main
MC="$TMP_ROOT/cache-moved"
run "$MC" "$MOVED/scripts/setup"
assert_eq "$RC|$(key_of "$OUT")" "0|$KEY" 'premise: the checkout before the move holds the program for its key' "$TMP_ROOT/err"
git -C "$MOVED" merge -q --ff-only topic
before="$(calls)"
run "$MC" "$MOVED/scripts/agent-runtime" version
MOVED_KEY="$(key_of "$(grep '^agent-runtime-setup: key=' "$TMP_ROOT/err")")"
assert_eq "$RC|$OUT|$(calls)" "0|fake-binary argv=version|$((before + 1))" \
  'after a fast-forward past a runtime change the next call builds once and answers' "$TMP_ROOT/err"
assert_eq "$(head -n 1 "$TMP_ROOT/err")" "agent-runtime: setup-building key=$MOVED_KEY run=$MOVED/scripts/setup" \
  'the call names the runtime and key it builds on its first stderr line'
if [ "$MOVED_KEY" != "$KEY" ] && [ -x "$MC/bin/agent-runtime-$MOVED_KEY" ]; then pass 'the build placed the moved sources'"'"' own key'; else fail 'the build placed the moved sources'"'"' own key' "$MOVED_KEY"; fi

# A build that fails ends the call with the setup's refusal, last on stderr.
printf '// failing\n' >>"$MOVED/runtime/src/lib.rs"
FAKE_CARGO_EXIT=1 run "$MC" "$MOVED/scripts/agent-runtime" version
assert_eq "$RC|$OUT" '69|' 'a call whose build fails exits 69 with no reply'
case "$(head -n 1 "$TMP_ROOT/err")" in
  "agent-runtime: setup-building key="*" run=$MOVED/scripts/setup") pass 'a call whose build fails names the build first' ;;
  *) fail 'a call whose build fails names the build first' "$ERR" ;;
esac
case "${ERR##*$'\n'}" in
  'agent-runtime-setup: build-failed status=1 key='*) pass "the setup's refusal is the call's last stderr line" ;;
  *) fail "the setup's refusal is the call's last stderr line" "$ERR" ;;
esac

# --- a failed build leaves bin/ empty --------------------------------------
FAKE_CARGO_EXIT=1 run "$TMP_ROOT/cache-failed" "$SETUP"
assert_eq "$RC" 1 'failed build exits 1'
assert_contains "$ERR" "agent-runtime-setup: build-failed status=1 key=$KEY" 'failed build refuses with its key'
assert_contains "$ERR" 'fake cargo: build failed' "cargo's stderr passes through"
assert_eq "$OUT" '' 'failed build prints no success line'
assert_eq "$(ls -A "$TMP_ROOT/cache-failed/bin")" '' 'bin/ holds nothing after a failed build'

# --- a caller's lower pin does not choose the build's toolchain -----------
PIN="$TMP_ROOT/pinned"
mkdir -p "$PIN"
printf '[toolchain]\nchannel = "1.94.0"\n' >"$PIN/rust-toolchain.toml"
cd "$PIN"
FAKE_TOOLCHAINS='1.94.0 1.98.1' run "$PIN" cargo build --manifest-path "$PKG/runtime/Cargo.toml"
assert_contains "$ERR" 'rustc 1.94.0 is not supported' "premise: cargo in the pinned directory refuses the caller's toolchain"
FAKE_TOOLCHAINS='1.94.0 1.98.1' run "$TMP_ROOT/cache-pinned" "$SETUP"
assert_eq "$RC" 0 'setup under a lower pin builds on a toolchain at the rust-version' "$TMP_ROOT/err"
before="$(calls)"
FAKE_TOOLCHAINS=1.94.0 run "$TMP_ROOT/cache-old" "$SETUP"
assert_eq "$RC|$ERR|$(calls)" "1|agent-runtime-setup: toolchain-missing rust-version=1.96 key=$KEY fix=rustup toolchain install 1.96|$before" 'setup without such a toolchain refuses, names the install and builds nothing'
FAKE_TOOLCHAINS='' run "$TMP_ROOT/cache-unlisted" "$SETUP"
assert_eq "$RC" 0 'a rustup that lists no toolchain, as under an isolated HOME, leaves the build to cargo' "$TMP_ROOT/err"
cd "$ROOT"

# --- a dependent crate is keyed on its inputs and its dependency's ----------
# A crate that declares this runtime by path, laid out as orch's runtime is
# beside agent-runtime's: dep/runtime beside runtime, the dependency two
# levels up. The dev-dependency path points nowhere: a key that read it
# would refuse inputs-missing.
DEP="$PKG/dep/runtime"
mkdir -p "$DEP/src"
cat >"$DEP/Cargo.toml" <<'TOML'
[package]
name = "dep-runtime"
version = "0.1.0"
edition = "2024"

[[bin]]
name = "dep-runtime"
path = "src/main.rs"

[dependencies]
agent-runtime = { path = "../../runtime" }
serde = "1"

[dev-dependencies]
fixture = { path = "../nowhere" }
TOML
printf 'fn main() {}\n' >"$DEP/src/main.rs"
printf '# fake lock\n' >"$DEP/Cargo.lock"
DEP_CACHE="$TMP_ROOT/cache-dep"
run "$DEP_CACHE" "$SETUP" --runtime "$DEP" --name dep-runtime
assert_eq "$RC" 0 'setup of a dependent crate exits 0' "$TMP_ROOT/err"
DEP_KEY="$(key_of "$OUT")"
assert_eq "${#DEP_KEY}" 64 'the dependent key is one sha256 hex'
if [ "$DEP_KEY" != "$KEY" ]; then pass 'the dependent crate has its own key'; else fail 'the dependent crate has its own key' "$DEP_KEY"; fi
assert_eq "$OUT" "dep-runtime-setup: key=$DEP_KEY binary=$DEP_CACHE/bin/dep-runtime-$DEP_KEY" 'the line and the binary carry the name'
assert_contains "$(tail -n 1 "$FAKE_CARGO_LOG")" "--manifest-path $DEP/Cargo.toml" 'cargo builds the named crate'
if [ -x "$DEP_CACHE/bin/dep-runtime-$DEP_KEY" ]; then pass 'the named binary is executable'; else fail 'the named binary is executable'; fi
if [ -d "$DEP_CACHE/build/dep-runtime/$DEP_KEY" ]; then pass 'the build lands under the name and the key'; else fail 'the build lands under the name and the key'; fi
before="$(calls)"
run "$DEP_CACHE" "$SETUP" --runtime "$DEP" --name dep-runtime
assert_eq "$(key_of "$OUT")|$(calls)" "$DEP_KEY|$before" 'the same inputs give the same key and no build'

printf '\n' >>"$PKG/runtime/src/lib.rs"
run "$TMP_ROOT/cache-dep-changed" "$SETUP" --runtime "$DEP" --name dep-runtime
assert_eq "$RC" 0 'setup after a dependency change exits 0' "$TMP_ROOT/err"
if [ "$(key_of "$OUT")" != "$DEP_KEY" ]; then pass 'a changed byte in the dependency changes the dependent key'; else fail 'a changed byte in the dependency changes the dependent key' "$DEP_KEY"; fi
cp -p "$SRC/runtime/src/lib.rs" "$PKG/runtime/src/lib.rs"

printf '\n' >>"$DEP/src/main.rs"
run "$TMP_ROOT/cache-dep-own" "$SETUP" --runtime "$DEP" --name dep-runtime
assert_eq "$RC" 0 'setup after an own-source change exits 0' "$TMP_ROOT/err"
if [ "$(key_of "$OUT")" != "$DEP_KEY" ]; then pass 'a changed byte in the dependent crate changes its key'; else fail 'a changed byte in the dependent crate changes its key' "$DEP_KEY"; fi
printf 'fn main() {}\n' >"$DEP/src/main.rs"

run "$DEP_CACHE" "$SETUP" --runtime "$DEP" --name dep-runtime
assert_eq "$(key_of "$OUT")" "$DEP_KEY" 'the restored inputs give the first key again'

# --- a runtime that is not there, and a manifest that cannot be read -------
before="$(calls)"
run "$TMP_ROOT/cache-missing" "$SETUP" --runtime "$PKG/nowhere" --name dep-runtime
assert_eq "$RC" 1 'a missing runtime exits 1'
assert_eq "$ERR" "dep-runtime-setup: runtime-missing runtime=$PKG/nowhere" 'a missing runtime refuses by name'
assert_eq "$OUT|$(calls)" "|$before" 'a missing runtime prints no line and builds nothing'
if [ "$(id -u)" -ne 0 ]; then
  chmod 000 "$DEP/Cargo.toml"
  run "$TMP_ROOT/cache-unreadable" "$SETUP" --runtime "$DEP" --name dep-runtime
  chmod 644 "$DEP/Cargo.toml"
  assert_eq "$RC" 1 'an unreadable manifest exits 1'
  assert_eq "$ERR" "dep-runtime-setup: manifest-unreadable path=$DEP/Cargo.toml" 'an unreadable manifest refuses by path'
  assert_eq "$OUT|$(calls)" "|$before" 'an unreadable manifest prints no line and builds nothing'
else
  echo 'note: running as root, so no file is unreadable; the manifest-unreadable rows did not run'
fi

# --- the default cache root is XDG --------------------------------------
RC=0
env -u AGENT_RUNTIME_CACHE XDG_CACHE_HOME="$TMP_ROOT/xdg" "$SETUP" >"$TMP_ROOT/out" 2>"$TMP_ROOT/err" || RC=$?
assert_eq "$RC" 0 'setup under XDG_CACHE_HOME exits 0' "$TMP_ROOT/err"
assert_eq "$(cat "$TMP_ROOT/out")" "agent-runtime-setup: key=$KEY binary=$TMP_ROOT/xdg/kendex/agent-runtime/bin/agent-runtime-$KEY" 'the default cache is kendex/agent-runtime under XDG_CACHE_HOME'

# --- after a build, setup removes the keys nothing uses ---------------------
# One cache holding a key of each kind setup tells apart, then a build of the
# package's key from a registered copy of the package, since a build from a
# checkout no record names removes nothing. The registered checkouts beside
# it: a repository and its linked
# worktree, a folder in no repository (a source catalog's skills/ layout),
# beside the home directory. The unregistered ones: a runtime a cargo is
# building now, and a hosted lane's clone for the row after. Each holds the
# package's runtime one comment off, so each resolves to a key of its own.
# Every finished build's dep-info names a checkout that is gone unless a row
# says otherwise.
PC="$TMP_ROOT/cache-prune"
PB="$PC/build/agent-runtime"
mkdir -p "$PB" "$PC/bin"
hex() { printf '%064d' 0 | tr 0 "$1"; }
placed() { printf '#!/bin/sh\n' >"$PC/bin/agent-runtime-$1" && chmod -- 755 "$PC/bin/agent-runtime-$1"; }
built_from() { # KEY RUNTIME — the dep-info cargo leaves, a space escaped as `\ `
  local escaped="${2// /\\ }"
  printf '%s: %s/src/main.rs %s/src/lib.rs %s/skills/other/runtime/src/lib.rs\n' \
    "$PB/$1/release/agent-runtime" "$escaped" "$escaped" "$TMP_ROOT/dependency" >"$PB/$1/release/agent-runtime.d"
}
built() { mkdir -p "$PB/$1/release" && : >"$PB/$1.log" && placed "$1" && built_from "$1" "$TMP_ROOT/gone/$1"; }
runtime_copy() { # DEST MARK
  mkdir -p "$1"
  cp -p "$PKG/runtime/Cargo.toml" "$PKG/runtime/Cargo.lock" "$1/"
  cp -R "$PKG/runtime/src" "$1/src"
  printf '// %s\n' "$2" >>"$1/src/lib.rs"
}
key_at() { bash -c 'refuse() { exit 1; }; . "$1"; agent_runtime_key "$2"' _ "$SRC/scripts/lib/key.sh" "$1"; }
until_args() { # PID PREFIX — until ps shows the process's arguments opening with PREFIX
  local n=0
  until [[ "$(ps -p "$1" -ww -o args= 2>/dev/null || :)" == "$2"* ]]; do
    n=$((n + 1))
    [ "$n" -lt 100 ] || return 1
    sleep 0.1
  done
}
REPO="$TMP_ROOT/checkouts/repo"
LANE="$TMP_ROOT/checkouts/lane"
PLAIN="$TMP_ROOT/checkouts/plain"
PACKAGE="$TMP_ROOT/checkouts/package/skills/agent-runtime/runtime"
CLONE="$TMP_ROOT/lane host/clone/.agents/skills/agent-runtime/runtime"
BUILDING="$TMP_ROOT/building/.agents/skills/agent-runtime/runtime"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config gc.auto 0
git -C "$REPO" config maintenance.auto false
runtime_copy "$REPO/.agents/skills/agent-runtime/runtime" repo
git -C "$REPO" add -A
git -C "$REPO" -c user.name=fixture -c user.email=fixture@example.invalid commit -q -m fixture
git -C "$REPO" worktree add -q -b lane "$LANE"
printf '// lane\n' >>"$LANE/.agents/skills/agent-runtime/runtime/src/lib.rs"
# A copy delivery: the tool's own directory holds a copy, not a link.
runtime_copy "$REPO/.claude/skills/agent-runtime/runtime" copy
runtime_copy "$PLAIN/skills/agent-runtime/runtime" plain
mkdir -p "$PACKAGE"
cp -p "$PKG/runtime/Cargo.toml" "$PKG/runtime/Cargo.lock" "$PACKAGE/"
cp -R "$PKG/runtime/src" "$PACKAGE/src"
runtime_copy "$HOME/.agents/skills/agent-runtime/runtime" home
runtime_copy "$HOME/.pi/agent/skills/agent-runtime/runtime" pi
runtime_copy "$CLONE" clone
runtime_copy "$BUILDING" building
printf '[{"folder":"%s","state":"ok","worktree":null},{"folder":"%s","state":"ok","worktree":null},{"folder":"%s","state":"ok","worktree":null},{"folder":"%s","state":"folder-not-found","worktree":null}]\n' \
  "$REPO" "$PLAIN" "$TMP_ROOT/checkouts/package" "$TMP_ROOT/gone" >"$FAKE_KENDEX_REGISTRY"
assert_eq "$(key_at "$PACKAGE")" "$KEY" 'premise: the registered copy of the package resolves to its key'
REPO_KEY="$(key_at "$REPO/.agents/skills/agent-runtime/runtime")"
LANE_KEY="$(key_at "$LANE/.agents/skills/agent-runtime/runtime")"
COPY_KEY="$(key_at "$REPO/.claude/skills/agent-runtime/runtime")"
PLAIN_KEY="$(key_at "$PLAIN/skills/agent-runtime/runtime")"
HOME_KEY="$(key_at "$HOME/.agents/skills/agent-runtime/runtime")"
PI_KEY="$(key_at "$HOME/.pi/agent/skills/agent-runtime/runtime")"
CLONE_KEY="$(key_at "$CLONE")"
BUILDING_KEY="$(key_at "$BUILDING")"
CHECKOUT_KEYS="$REPO_KEY $LANE_KEY $COPY_KEY $PLAIN_KEY $HOME_KEY $PI_KEY $BUILDING_KEY"
# shellcheck disable=SC2086 # the keys, one word each
assert_eq "$(printf '%s\n' "$KEY" $CHECKOUT_KEYS "$CLONE_KEY" | grep -c -E '^[0-9a-f]{64}$' | tr -d ' ')|$(printf '%s\n' "$KEY" $CHECKOUT_KEYS "$CLONE_KEY" | sort -u | wc -l | tr -d ' ')" '9|9' 'premise: each checkout resolves to a key of its own'
for checkout_key in $CHECKOUT_KEYS; do
  [ "$checkout_key" = "$BUILDING_KEY" ] || built "$checkout_key"
done
# A build of a key no checkout holds now, its dep-info naming a recorded
# checkout that has since moved to another key.
UNUSED="$(hex a)"
built "$UNUSED"
built_from "$UNUSED" "$PLAIN/skills/agent-runtime/runtime"
: >"$PB/$UNUSED.told-0-build-failed"
# A finished build whose dep-info names no source proves no builder.
UNRECORDED="$(hex 3)"
built "$UNRECORDED"
: >"$PB/$UNRECORDED/release/agent-runtime.d"
FAILED="$(hex 1)"
mkdir -p "$PB/$FAILED"
printf 'build-failed\n' >"$PB/$FAILED.failed"
: >"$PB/$FAILED.log"
# A failed detached build that a setup without --detach is building again:
# no claim, a .failed record, and a cargo naming the runtime's manifest.
mkdir -p "$PB/$BUILDING_KEY"
printf 'build-failed\n' >"$PB/$BUILDING_KEY.failed"
bash -c 'exec -a "cargo build --release --locked --manifest-path $1/Cargo.toml" sleep 30' _ "$BUILDING" &
cargo_pid=$!
until_args "$cargo_pid" "cargo build --release --locked --manifest-path $BUILDING/Cargo.toml" ||
  fail 'premise: the running cargo shows its manifest path'
STALE="$(hex 2)"
built "$STALE"
ln -s '1 1200' "$PB/$STALE.lock"
LOCKED="$(hex b)"
built "$LOCKED"
sleep 30 &
holder=$!
ln -s "$(date +%s) 1200 $holder" "$PB/$LOCKED.lock"
RUNNING="$(hex c)"
built "$RUNNING"
# A placed program runs with its path as argv[0], as the wrapper's exec
# leaves it.
bash -c 'exec -a "$1" sleep 30' _ "$PC/bin/agent-runtime-$RUNNING" &
runner=$!
until_args "$runner" "$PC/bin/agent-runtime-$RUNNING" || fail 'premise: the running program shows its path as argv[0]'
# Installed from elsewhere on a host with no cargo: a binary, and only the
# .log and .told-* its detached setup leaves under build/.
FLEET="$(hex d)"
placed "$FLEET"
printf 'agent-runtime-setup: cargo-missing key=%s\n' "$FLEET" >"$PB/$FLEET.log"
: >"$PB/$FLEET.told-0123-cargo-missing"
FLIGHT="$(hex e)"
mkdir -p "$PB/$FLIGHT/release"

# A narrow COLUMNS, as a terminal or harness exports it, ends a cut ps line
# well inside the running program's key.
COLUMNS=40 run "$PC" "$SETUP" --runtime "$PACKAGE"
assert_eq "$RC|$OUT|$ERR" "0|agent-runtime-setup: key=$KEY binary=$PC/bin/agent-runtime-$KEY|" 'prune: the build passes with its one line and no diagnostic'
expected_bin=""
for k in "$KEY" $CHECKOUT_KEYS "$UNRECORDED" "$LOCKED" "$RUNNING" "$FLEET"; do
  [ "$k" = "$BUILDING_KEY" ] || expected_bin="$expected_bin
agent-runtime-$k"
done
assert_eq "$(ls -A "$PC/bin" | sort)" "$(printf '%s\n' "$expected_bin" | sed '/^$/d' | sort)" 'prune: bin/ keeps the built, checkout, unrecorded, claimed, running and installed keys alone'
expected_build="$KEY
$BUILDING_KEY
$BUILDING_KEY.failed
$FLIGHT
$FLEET.log
$FLEET.told-0123-cargo-missing
$LOCKED
$LOCKED.log
$LOCKED.lock
$RUNNING
$RUNNING.log
$UNRECORDED
$UNRECORDED.log"
for k in $CHECKOUT_KEYS; do
  [ "$k" = "$BUILDING_KEY" ] || expected_build="$expected_build
$k
$k.log"
done
assert_eq "$(ls -A "$PB" | sort)" "$(printf '%s\n' "$expected_build" | sort)" 'prune: build/ loses the unused, failed and lost-claim keys whole, the builds in flight kept'
kill "$holder" "$runner" "$cargo_pid" 2>/dev/null || :
wait "$holder" "$runner" "$cargo_pid" 2>/dev/null || :

# A key built from a checkout that stands outside every recorded one, as a
# hosted lane's clone does, shows the host holds checkouts its record misses:
# another clone can share a key the dep-info names for this one alone, so
# nothing goes, not even a key no checkout holds.
PC="$TMP_ROOT/cache-prune-clone"
PB="$PC/build/agent-runtime"
mkdir -p "$PB" "$PC/bin"
built "$CLONE_KEY"
built_from "$CLONE_KEY" "$CLONE"
built "$UNUSED"
run "$PC" "$SETUP" --runtime "$PACKAGE"
assert_eq "$RC|$OUT|$ERR" "0|agent-runtime-setup: key=$KEY binary=$PC/bin/agent-runtime-$KEY|agent-runtime-setup: prune-skipped cause=checkout-unrecorded runtime=$CLONE" 'prune: a binary built in an unrecorded checkout passes the build and names the skip'
assert_eq "$(ls -A "$PC/bin" | sort | tr '\n' ' ')|$(ls -A "$PB" | sort | tr '\n' ' ')" "$(printf '%s\n' "agent-runtime-$KEY" "agent-runtime-$CLONE_KEY" "agent-runtime-$UNUSED" | sort | tr '\n' ' ')|$(printf '%s\n' "$KEY" "$CLONE_KEY" "$CLONE_KEY.log" "$UNUSED" "$UNUSED.log" | sort | tr '\n' ' ')" 'prune: a binary built in an unrecorded checkout removes nothing'

# A build from a checkout no record names, as a hosted lane's clone builds,
# shows the same: nothing goes.
PC="$TMP_ROOT/cache-prune-unrecorded"
PB="$PC/build/agent-runtime"
mkdir -p "$PB" "$PC/bin"
built "$UNUSED"
run "$PC" "$SETUP"
assert_eq "$RC|$OUT|$ERR" "0|agent-runtime-setup: key=$KEY binary=$PC/bin/agent-runtime-$KEY|agent-runtime-setup: prune-skipped cause=checkout-unrecorded runtime=$PKG/runtime" 'prune: a build from an unrecorded checkout passes and names the skip'
assert_eq "$(ls -A "$PC/bin" | sort | tr '\n' ' ')|$(ls -A "$PB" | sort | tr '\n' ' ')" "$(printf '%s\n' "agent-runtime-$KEY" "agent-runtime-$UNUSED" | sort | tr '\n' ' ')|$(printf '%s\n' "$KEY" "$UNUSED" "$UNUSED.log" | sort | tr '\n' ' ')" 'prune: a build from an unrecorded checkout removes nothing'

# A project list that does not read proves nothing unused: nothing goes.
PC="$TMP_ROOT/cache-prune-unread"
PB="$PC/build/agent-runtime"
mkdir -p "$PB" "$PC/bin"
built "$UNUSED"
FAKE_KENDEX_EXIT=1 run "$PC" "$SETUP"
assert_eq "$RC|$OUT|$ERR" "0|agent-runtime-setup: key=$KEY binary=$PC/bin/agent-runtime-$KEY|agent-runtime-setup: prune-skipped cause=projects-unread" 'prune: an unread project list passes the build and names the skip'
assert_eq "$(ls -A "$PC/bin" | sort | tr '\n' ' ')|$(ls -A "$PB" | sort | tr '\n' ' ')" "$(printf '%s\n' "agent-runtime-$KEY" "agent-runtime-$UNUSED" | sort | tr '\n' ' ')|$(printf '%s\n' "$KEY" "$UNUSED" "$UNUSED.log" | sort | tr '\n' ' ')" 'prune: an unread project list removes nothing'
printf '[]\n' >"$FAKE_KENDEX_REGISTRY"

# --- --detach: the build a caller that must answer starts beside itself ----
# A turn end on a computer whose runtime is unbuilt (a pull, a cleared
# cache, an edited runtime) starts the build here and answers at once. The
# rows hold a build in flight with the cargo hold, and wait on files with a
# bound, ten seconds each.
until_there() { # PATH
  local n=0
  while [ ! -e "$1" ]; do
    n=$((n + 1))
    [ "$n" -lt 100 ] || return 1
    sleep 0.1
  done
}
until_gone() { # PATH, a file or a symlink
  local n=0
  while [ -e "$1" ] || [ -L "$1" ]; do
    n=$((n + 1))
    [ "$n" -lt 100 ] || return 1
    sleep 0.1
  done
}
MAIL="$TMP_ROOT/mailbox"
mkdir -p "$MAIL"
HOLD="$TMP_ROOT/hold"
building_line() { printf 'agent-runtime-setup: runtime-building key=%s log=%s/build/agent-runtime/%s.log' "$KEY" "$1" "$KEY"; }
unbuilt_line() { printf 'agent-runtime-setup: runtime-unbuilt cause=%s key=%s log=%s/build/agent-runtime/%s.log' "$2" "$KEY" "$1" "$KEY"; }

# One build per key: the caller holding a mailbox is held while the build it
# started runs, returns while it runs (a harness reads its hook's output to
# its end), and a second caller starts nothing. The build is outside the
# caller's process group, so a signal to the hook's group misses it.
DC="$TMP_ROOT/cache-detach"
: >"$HOLD"
before="$(calls)"
RC=0
OUT="$(FAKE_CARGO_HOLD="$HOLD" AGENT_RUNTIME_CACHE="$DC" "$SETUP" --detach --hold "$MAIL" 2>"$TMP_ROOT/err")" || RC=$?
assert_eq "$RC|$OUT" "3|$(building_line "$DC")" 'detach: a caller holding a mailbox is held while the build it started runs' "$TMP_ROOT/err"
until_there "$HOLD.pid" || fail 'detach: the build reached cargo'
read -r cargo_pid cargo_group <"$HOLD.pid"
if kill -0 "$cargo_pid" 2>/dev/null; then pass 'detach: the caller returned while its build runs'; else fail 'detach: the caller returned while its build runs'; fi
own_group="$(ps -o pgid= -p "$$" | tr -d ' ')"
if [ "$cargo_group" != "$own_group" ]; then pass "detach: the build runs outside the caller's process group"; else fail "detach: the build runs outside the caller's process group" "$cargo_group"; fi
FAKE_CARGO_HOLD="$HOLD" run "$DC" "$SETUP" --detach --hold "$MAIL"
assert_eq "$RC|$OUT" "3|$(building_line "$DC")" 'detach: a second caller is held while the build runs'
# The first build stays held while a second, were one started, keys the
# sources and reaches cargo: three seconds, ten times what that takes.
n=0
while [ "$(calls)" -lt "$((before + 2))" ] && [ "$n" -lt 30 ]; do
  n=$((n + 1))
  sleep 0.1
done
assert_eq "$(calls)" "$((before + 1))" 'detach: a second caller while a build runs starts no second build'
rm -f "$HOLD"
until_gone "$DC/build/agent-runtime/$KEY.lock" || fail 'detach: the build released its claim'
run "$DC" "$SETUP" --detach --hold "$MAIL"
assert_eq "$RC|$OUT" "0|agent-runtime-setup: key=$KEY binary=$DC/bin/agent-runtime-$KEY" 'detach: a built key passes with the success line'
assert_eq "$(calls)" "$((before + 1))" 'detach: a built key starts nothing'

# A root with no mailbox passes silently, and a caller naming no hold (the
# row, usage and compact arms) passes with the line; both start the build.
DC="$TMP_ROOT/cache-quiet"
before="$(calls)"
run "$DC" "$SETUP" --detach --hold "$TMP_ROOT/no-mailbox"
assert_eq "$RC|$OUT|$(cat "$TMP_ROOT/err")" '0||' 'detach: a root with no mailbox passes silently'
until_gone "$DC/build/agent-runtime/$KEY.lock" || fail 'detach: the quiet build ended'
assert_eq "$(calls)" "$((before + 1))" 'detach: a root with no mailbox still starts the build'
DC="$TMP_ROOT/cache-record"
run "$DC" "$SETUP" --detach
assert_eq "$RC|$OUT" "0|$(building_line "$DC")" 'detach: a caller with no hold passes with the building line'
until_gone "$DC/build/agent-runtime/$KEY.lock" || fail 'detach: the record build ended'
if [ -x "$DC/bin/agent-runtime-$KEY" ]; then pass 'detach: a caller with no hold still builds'; else fail 'detach: a caller with no hold still builds'; fi

# A failed build holds a mailbox once per root and cause, then passes; it is
# never started again by --detach, and a setup without it clears the record.
DC="$TMP_ROOT/cache-failed-detach"
before="$(calls)"
FAKE_CARGO_EXIT=1 run "$DC" "$SETUP" --detach --hold "$MAIL"
assert_eq "$RC|$OUT" "3|$(building_line "$DC")" 'detach: the failing build is held while it runs'
until_gone "$DC/build/agent-runtime/$KEY.lock" || fail 'detach: the failed build released its claim'
FAKE_CARGO_EXIT=1 run "$DC" "$SETUP" --detach --hold "$MAIL"
assert_eq "$RC|$OUT" "3|$(unbuilt_line "$DC" build-failed)" 'detach: a failed build holds a mailbox once with its cause'
FAKE_CARGO_EXIT=1 run "$DC" "$SETUP" --detach --hold "$MAIL"
assert_eq "$RC|$OUT" "0|$(unbuilt_line "$DC" build-failed)" 'detach: the next caller of a failed build passes'
assert_eq "$(calls)" "$((before + 1))" 'detach: a failed build is not started again'
assert_contains "$(cat "$DC/build/agent-runtime/$KEY.log")" "agent-runtime-setup: build-failed status=1 key=$KEY" "detach: the log holds the build's own refusal"
mkdir -p "$TMP_ROOT/other-mailbox"
run "$DC" "$SETUP" --detach --hold "$TMP_ROOT/other-mailbox"
assert_eq "$RC" 3 'detach: another root is held once for the same failure'
run "$DC" "$SETUP"
assert_eq "$RC" 0 'detach: a setup without --detach builds the failed key' "$TMP_ROOT/err"
assert_eq "$(ls -A "$DC/build/agent-runtime" | grep -c -e '\.failed$' -e '\.told-' || :)" 0 'detach: the build clears the failure and its notices'

# A build past its cap is ended, its group with it, and read as unbuilt. The
# cap is four seconds: the clock is whole seconds, and the build keys the
# sources before it reaches cargo, which must be running when the cap ends it.
DC="$TMP_ROOT/cache-capped"
: >"$HOLD"
rm -f "$HOLD.pid"
FAKE_CARGO_HOLD="$HOLD" run "$DC" "$SETUP" --detach --cap 4 --hold "$MAIL"
assert_eq "$RC" 3 'detach: a capped build is held while it runs'
until_there "$HOLD.pid" || fail 'detach: the capped build reached cargo'
until_gone "$DC/build/agent-runtime/$KEY.lock" || fail 'detach: the capped build released its claim'
read -r cargo_pid cargo_group <"$HOLD.pid"
n=0
while kill -0 "$cargo_pid" 2>/dev/null && [ "$n" -lt 20 ]; do n=$((n + 1)); sleep 0.1; done
if kill -0 "$cargo_pid" 2>/dev/null; then fail 'detach: the cap ends the build with its group'; else pass 'detach: the cap ends the build with its group'; fi
rm -f "$HOLD"
run "$DC" "$SETUP" --detach --hold "$MAIL"
assert_eq "$RC|$OUT" "3|$(unbuilt_line "$DC" build-capped)" 'detach: a capped build holds a mailbox once'

# A claim past its cap is read as unbuilt while its process still lives, and
# a claim whose build is gone with no record was lost.
DC="$TMP_ROOT/cache-claims"
mkdir -p "$DC/build/agent-runtime"
sleep 30 &
live=$!
ln -s "1 5 $live" "$DC/build/agent-runtime/$KEY.lock"
before="$(calls)"
run "$DC" "$SETUP" --detach --hold "$MAIL"
assert_eq "$RC|$OUT" "3|$(unbuilt_line "$DC" build-capped)" 'detach: a claim past its cap reads unbuilt while its process lives'
kill "$live"
wait "$live" 2>/dev/null || :
run "$DC" "$SETUP" --detach --hold "$MAIL"
assert_eq "$RC|$OUT" "3|$(unbuilt_line "$DC" build-lost)" 'detach: a claim whose process is gone with no record is lost'
assert_eq "$(calls)|$(cat "$DC/build/agent-runtime/$KEY.failed")" "$before|build-lost" 'detach: a lost build is recorded and not started again'
if [ -L "$DC/build/agent-runtime/$KEY.lock" ]; then fail 'detach: the lost claim is removed'; else pass 'detach: the lost claim is removed'; fi
DC="$TMP_ROOT/cache-untaken"
mkdir -p "$DC/build/agent-runtime"
ln -s "1 1200" "$DC/build/agent-runtime/$KEY.lock"
run "$DC" "$SETUP" --detach --hold "$MAIL"
assert_eq "$RC|$OUT" "3|$(unbuilt_line "$DC" build-lost)" 'detach: a claim no build took within its grace is lost'

# No cargo: the caller is told once, nothing is recorded, and a later cargo
# builds, on the PATH without cargo the wrapper rows use.
DC="$TMP_ROOT/cache-no-cargo"
RC=0
OUT="$(PATH="$NOCARGO" AGENT_RUNTIME_CACHE="$DC" "$SETUP" --detach --hold "$MAIL" 2>"$TMP_ROOT/err")" || RC=$?
assert_eq "$RC|$OUT" "3|$(unbuilt_line "$DC" cargo-missing)" 'detach: a computer with no cargo holds a mailbox once' "$TMP_ROOT/err"
RC=0
OUT="$(PATH="$NOCARGO" AGENT_RUNTIME_CACHE="$DC" "$SETUP" --detach --hold "$MAIL" 2>"$TMP_ROOT/err")" || RC=$?
assert_eq "$RC" 0 'detach: the next caller with no cargo passes'
run "$DC" "$SETUP" --detach --hold "$MAIL"
assert_eq "$RC|$OUT" "3|$(building_line "$DC")" 'detach: once cargo is there the build starts'
until_gone "$DC/build/agent-runtime/$KEY.lock" || fail 'detach: the late build ended'

# --hold and --cap belong to --detach; a cap is a positive whole number.
run "$TMP_ROOT/cache-usage" "$SETUP" --hold "$MAIL"
assert_eq "$RC|$ERR" '1|agent-runtime-setup: usage argument=--hold|--cap wanted=--detach' '--hold without --detach is refused'
run "$TMP_ROOT/cache-usage" "$SETUP" --detach --cap 0
assert_eq "$RC|$ERR" '1|agent-runtime-setup: usage argument=--cap wanted=SECONDS got=0' 'a cap of zero is refused'

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[[ "$FAIL" -eq 0 ]]
