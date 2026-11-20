#!/usr/bin/env bash
# Surface: the agent-runtime setup route and its wrapper. Inputs:
# skills/agent-runtime/scripts/**, skills/agent-runtime/runtime/Cargo.toml,
# runtime/Cargo.lock, runtime/src/**.
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
# builds. The PATH holds every tool the setup reads but cargo.
NOCARGO="$TMP_ROOT/no-cargo-bin"
mkdir -p "$NOCARGO"
for tool in awk bash cat chmod cut date find ln mkdir mv readlink rm sh sha256sum shasum sort tr wc; do
  if found="$(command -v "$tool")"; then ln -s "$found" "$NOCARGO/$tool"; fi
done
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
