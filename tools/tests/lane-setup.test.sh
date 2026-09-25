#!/usr/bin/env bash
# Proves the fleet clone setup against the commands a lane image supplies.
set -euo pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$(cd "$TEST_DIR/.." && pwd)"
# Physical, because cargo names a crate's directory by its physical path and
# the warm rows compare that name with the lane path built from this one.
REPO="$(cd "$TOOLS/.." && pwd -P)"
mkdir -p "$REPO/tmp"
TMP="$(mktemp -d "$REPO/tmp/lane-setup.XXXXXX")"
trap 'rm -rf -- "${TMP:?}"' EXIT

REAL_GIT="$(command -v git)" || { printf 'the host provides git\n'; exit 1; }

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

# The setup runs on a PATH of its fakes and these utilities alone, so a
# linker or sccache installed on the host cannot answer for a row.
SYS_BIN="$TMP/sys-bin"
mkdir -p "$SYS_BIN"
for tool in bash cat grep mkdir mv; do
  tool_path="$(command -v "$tool")" || { bad "the host provides $tool"; exit 1; }
  ln -s "$tool_path" "$SYS_BIN/$tool"
done

# mutate FILE FROM TO: replaces the one line equal to FROM.
mutate() {
  local n=""
  n="$(FROM="$2" awk '$0 == ENVIRON["FROM"] { n++ } END { print n + 0 }' "$1")" || exit 1
  [ "$n" -eq 1 ] || { bad "the mutant matches one line: $2" "found $n"; exit 1; }
  FROM="$2" TO="$3" awk '$0 == ENVIRON["FROM"] { print ENVIRON["TO"]; next } { print }' "$1" >"$1.mutant" || exit 1
  mv "$1.mutant" "$1"
}

# fixture NAME [FROM TO]: a clone at $TMP/NAME, its lane-setup mutated when
# FROM and TO are given. Its worktree skill answers only `path --hosted`, with
# the hosted lane path a clone of that name has by default, LANE_PATH.
fixture() {
  R="$TMP/$1"
  EXTRA_BIN=""
  LANE_PATH="${R%/*}/.worktrees/${R##*/}/lane"
  mkdir -p "$R/tools" "$R/ui" "$R/fake-bin" "$R/home" "$R/src" "$R/.agents/skills/worktree/scripts"
  cat >"$R/.agents/skills/worktree/scripts/worktree" <<SH
#!/usr/bin/env bash
[ "\$*" = "path --hosted" ] || exit 64
printf '%s\\n' '$LANE_PATH'
SH
  cp "$REPO/.fleet-setup" "$R/"
  cp "$TOOLS/lane-setup" "$R/tools/"
  [ $# -eq 1 ] || mutate "$R/tools/lane-setup" "$2" "$3"
  chmod +x "$R/.fleet-setup" "$R/tools/lane-setup"
  printf 'ui/node_modules/\n' >"$R/.gitignore"
  printf '{"scripts":{}}\n' >"$R/ui/package.json"
  printf '{}\n' >"$R/ui/package-lock.json"
  printf '[package]\nname = "toy"\nversion = "0.1.0"\nedition = "2021"\n\n[workspace]\n' >"$R/Cargo.toml"
  printf 'pub fn toy() {}\n' >"$R/src/lib.rs"
  cat >"$R/fake-bin/node" <<'SH'
#!/usr/bin/env bash
printf 'v22.19.0\n'
SH
  # git answers the dependency-input read itself and hands `worktree`, which
  # the warm build takes, to the real git.
  cat >"$R/fake-bin/git" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1-}" = worktree ]; then exec "$REAL_GIT" "$@"; fi
[ "$*" = "rev-parse HEAD:ui/package.json HEAD:ui/package-lock.json" ]
printf 'package:'
cat ui/package.json
printf 'lock:'
cat ui/package-lock.json
SH
  cat >"$R/fake-bin/npm" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "${1-}" = --version ]; then printf '10.9.3\n'; exit 0; fi
printf '%s\n' "$*" >>"$NPM_LOG"
[ "$*" = "ci --no-audit --no-fund --prefix ui" ]
mkdir -p ui/node_modules
[ "${NPM_FAIL:-0}" -eq 0 ] || exit "$NPM_FAIL"
SH
  cat >"$R/fake-bin/rustc" <<'SH'
#!/usr/bin/env bash
printf 'rustc 1.96.1 (fixture)\n'
SH
  cat >"$R/fake-bin/rustup" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "$*" = "target list --installed" ]; then [ ! -f "$RUSTUP_STATE" ] || cat "$RUSTUP_STATE"; exit 0; fi
printf '%s\n' "$*" >>"$RUSTUP_LOG"
[ "$*" = "target add aarch64-apple-darwin x86_64-pc-windows-msvc" ]
[ "${RUSTUP_FAIL:-0}" -eq 0 ] || exit "$RUSTUP_FAIL"
printf '%s\n' aarch64-apple-darwin x86_64-pc-windows-msvc >"$RUSTUP_STATE"
SH
  chmod +x "$R/fake-bin/"* "$R/.agents/skills/worktree/scripts/worktree"
  git -C "$R" init -q
  git -C "$R" add -A
  git -C "$R" -c user.name=test -c user.email=test@example.com commit -qm fixture
  NPM_LOG="$R/npm.log"
  RUSTUP_LOG="$R/rustup.log"
  RUSTUP_STATE="$R/rustup.state"
}

# run_setup COMMAND [NAME=VALUE...]: the extra assignments join the clean
# environment, so an unset variable stays unset.
run_setup() {
  local command=$1
  shift
  RC=0
  OUT="$(cd "$R" && env -i HOME="$R/home" PATH="${EXTRA_BIN:+$EXTRA_BIN:}$R/fake-bin:$SYS_BIN" REAL_GIT="$REAL_GIT" NPM_LOG="$NPM_LOG" RUSTUP_LOG="$RUSTUP_LOG" RUSTUP_STATE="$RUSTUP_STATE" NPM_FAIL="${NPM_FAIL:-0}" RUSTUP_FAIL="${RUSTUP_FAIL:-0}" "$@" "$command" 2>&1)" || RC=$?
}

echo "=== a fresh clone installs both dependency sets ==="
fixture fresh
run_setup ./.fleet-setup
[ "$RC" -eq 0 ] && [ "$(cat "$NPM_LOG")" = "ci --no-audit --no-fund --prefix ui" ] && [ "$(cat "$RUSTUP_LOG")" = "target add aarch64-apple-darwin x86_64-pc-windows-msvc" ] && case "$OUT" in *"lane-setup: versions=node:v22.19.0 npm:10.9.3"*"lane-setup: ui=install"*"lane-setup: rust-targets=install"*"rustc 1.96.1 (fixture)"*) true ;; *) false ;; esac \
  && ok "the root entry point installs the locked UI tree and both pinned targets" \
  || bad "the root entry point installs both dependency sets" "rc=$RC out=$OUT"
[ -z "$(git -C "$R" status --porcelain --untracked-files=no)" ] \
  && ok "a successful setup leaves every tracked file unchanged" \
  || bad "a successful setup leaves every tracked file unchanged" "$(git -C "$R" status --porcelain --untracked-files=no)"

echo "=== a second run skips satisfied steps ==="
run_setup ./tools/lane-setup
[ "$RC" -eq 0 ] && [ "$(wc -l <"$NPM_LOG")" -eq 1 ] && [ "$(wc -l <"$RUSTUP_LOG")" -eq 1 ] && case "$OUT" in *"lane-setup: ui=skip"*"lane-setup: rust-targets=skip"*) true ;; *) false ;; esac \
  && ok "a second run skips npm and rustup" \
  || bad "a second run skips npm and rustup" "rc=$RC out=$OUT"

echo "=== npm failure stops before rustup ==="
fixture npm-fail
NPM_FAIL=23 run_setup ./tools/lane-setup
[ "$RC" -eq 23 ] && [ -d "$R/ui/node_modules" ] && [ ! -e "$R/ui/node_modules/.kendex-lane-setup" ] && [ ! -e "$RUSTUP_LOG" ] && case "$OUT" in *"lane-setup: ui=install"*) true ;; *) false ;; esac \
  && ok "a failing npm ci names its step and stops before rustup" \
  || bad "a failing npm ci stops before rustup" "rc=$RC out=$OUT"
run_setup ./tools/lane-setup
[ "$RC" -eq 0 ] && [ "$(wc -l <"$NPM_LOG")" -eq 2 ] && [ -f "$R/ui/node_modules/.kendex-lane-setup" ] && case "$OUT" in *"lane-setup: ui=install"*) true ;; *) false ;; esac \
  && ok "a relaunch reinstalls after npm left a partial directory" \
  || bad "a relaunch reinstalls after npm left a partial directory" "rc=$RC out=$OUT"

echo "=== a changed dependency input invalidates the installed tree ==="
fixture changed-lock
run_setup ./tools/lane-setup
printf '{"lockfileVersion":3}\n' >"$R/ui/package-lock.json"
git -C "$R" add ui/package-lock.json
git -C "$R" -c user.name=test -c user.email=test@example.com commit -qm "changed lock"
run_setup ./tools/lane-setup
[ "$RC" -eq 0 ] && [ "$(wc -l <"$NPM_LOG")" -eq 2 ] && case "$OUT" in *"lane-setup: ui=install"*) true ;; *) false ;; esac \
  && ok "a relaunch reinstalls for the dependency inputs at its new HEAD" \
  || bad "a relaunch reinstalls for changed dependency inputs" "rc=$RC out=$OUT"

echo "=== rustup failure is returned ==="
fixture rustup-fail
mkdir -p "$R/ui/node_modules"
RUSTUP_FAIL=24 run_setup ./tools/lane-setup
[ "$RC" -eq 24 ] && case "$OUT" in *"lane-setup: rust-targets=install"*"rustc 1.96.1 (fixture)"*) true ;; *) false ;; esac \
  && ok "a failing target add names its step and returns its status" \
  || bad "a failing target add returns its status" "rc=$RC out=$OUT"

echo "=== must-fail control: swallowing npm failure turns the row green ==="
fixture mutant '  npm ci --no-audit --no-fund --prefix ui' '  npm ci --no-audit --no-fund --prefix ui || true'
NPM_FAIL=23 run_setup ./tools/lane-setup
[ "$RC" -eq 0 ] && [ -s "$RUSTUP_LOG" ] \
  && ok "control: the swallowed npm status exits clean and reaches rustup" \
  || bad "control: the swallowed npm status should turn the failure row green" "rc=$RC out=$OUT"

# The cargo rows read what a real cargo resolves from the written config, on
# the host's default toolchain rather than the repository's pinned one.
CARGO_BIN="$(cd / && rustup which cargo 2>/dev/null)" || CARGO_BIN="$(command -v cargo)" || CARGO_BIN=""
[ -n "$CARGO_BIN" ] || { bad "a cargo toolchain is reachable" "neither rustup nor cargo answered"; exit 1; }
CARGO_DIR="${CARGO_BIN%/*}"
SYSROOT="$(env -i PATH="$CARGO_DIR:/usr/bin:/bin" rustc --print sysroot 2>&1)" || { bad "the toolchain names its sysroot" "$SYSROOT"; exit 1; }

# Cargo reads the config of every ancestor of its working directory, and on a
# fleet sandbox this tree sits under a lanes dir the setup configured.
# $TMP/.cargo/config.toml sits between that ancestor and every fixture and
# turns incremental back on, so only a fixture's own lanes config can turn it
# off. Each run
# names its own target dir for the same reason.
mkdir -p "$TMP/.cargo"
printf '[build]\nincremental = true\n' >"$TMP/.cargo/config.toml"

cargo_in() { # DIR ARGS...
  local dir=$1
  shift
  (cd "$dir" && env -i HOME="$R/home" PATH="$CARGO_DIR:/usr/bin:/bin" CARGO_HOME="$R/home/.cargo" CARGO_TARGET_DIR="$dir/target" CARGO_NET_OFFLINE=true "$CARGO_BIN" "$@" 2>&1)
}

count() { # TEXT NEEDLE
  local text=$1 n=0
  while case "$text" in *"$2"*) true ;; *) false ;; esac; do
    text="${text#*"$2"}"
    n=$((n + 1))
  done
  printf '%s' "$n"
}

# toy_line OUTPUT CLONE: the toy crate's rustc line from `cargo check -v`,
# with the clone's path, the incremental session dir and the unit hashes the
# profile's incremental setting feeds taken out, so two fixtures' lines
# compare equal exactly when their other flags do.
toy_line() {
  local line=""
  line="$(sed -n 's/ -C incremental=[^ ]*//; s/ -C metadata=[^ ]*//; s/ -C extra-filename=[^ ]*//; /--crate-name toy/p' <<<"$1")"
  printf '%s' "${line//"$2"/<clone>}"
}

lanes_of() { (cd "$R/.." && pwd -P); }

# lane_fixture [FROM TO]: a clone alone in its own lanes directory, which is
# where the setup writes the cargo config.
LANES=0
lane_fixture() {
  LANES=$((LANES + 1))
  fixture "lanes-$LANES/clone" "$@"
}

# The non-Linux target a row checks against: the host itself when it is not
# Linux, else a pinned cross target the toolchain has installed.
FOREIGN_TARGET=""
FOREIGN_ARGS=""
if [ "$(uname -s)" != Linux ]; then
  FOREIGN_TARGET=host
else
  for target in aarch64-apple-darwin x86_64-pc-windows-msvc; do
    if [ -d "$SYSROOT/lib/rustlib/$target" ]; then
      FOREIGN_TARGET=$target
      FOREIGN_ARGS="--target $target"
      break
    fi
  done
fi

LINK_DELTA=0
[ "$(uname -s)" != Linux ] || LINK_DELTA=1
fixture baseline/clone
BASE="$(cargo_in "$R" check -v)" || { bad "the baseline check runs" "$BASE"; exit 1; }
case "$BASE" in *"--crate-name toy"*) ;; *) bad "the baseline check compiles the toy crate" "$BASE"; exit 1 ;; esac
BASE_LINE="$(toy_line "$BASE" "$R")"
BASE_MOLD="$(count "$BASE" -fuse-ld=mold)"
BASE_LLD="$(count "$BASE" -fuse-ld=lld)"
BASE_FOREIGN=""
if [ -n "$FOREIGN_TARGET" ]; then
  # shellcheck disable=SC2086 # FOREIGN_ARGS is empty or one flag and its value
  BASE_FOREIGN="$(cargo_in "$R" check -v $FOREIGN_ARGS)" || { bad "the baseline check runs for $FOREIGN_TARGET" "$BASE_FOREIGN"; exit 1; }
fi

# Every proof takes the fixture's optional mutation, so its control reruns
# the same proof against a mutant and expects it to fail.
# Every run sets its own CARGO_TARGET_DIR, which outranks the config, so the
# config's lack of a target-dir key is read from the file itself.
proof_incremental_off() {
  local wt="" clone_cache="" wt_cache="" config="" target_key=absent
  lane_fixture "$@"
  run_setup ./.fleet-setup DAYTONA_SANDBOX_ID=test
  [ "$RC" -eq 0 ] || { WHY="rc=$RC out=$OUT"; return 1; }
  wt="$(lanes_of)/.worktrees/clone/wt" || return 1
  git -C "$R" worktree add -q "$wt" || return 1
  cargo_in "$R" check -q >/dev/null || return 1
  cargo_in "$wt" check -q >/dev/null || return 1
  # Cargo lays out debug/incremental whatever the setting; a session writes
  # a directory inside it.
  clone_cache="$(ls -A "$R/target/debug/incremental" 2>&1)" || clone_cache="unreadable: $clone_cache"
  wt_cache="$(ls -A "$wt/target/debug/incremental" 2>&1)" || wt_cache="unreadable: $wt_cache"
  if [ -e "$R/../.cargo/config.toml" ]; then
    config="$(cat "$R/../.cargo/config.toml")" || return 1
  fi
  case $'\n'"$config" in *$'\n'target-dir*) target_key=present ;; esac
  WHY="clone incremental=[$clone_cache] worktree incremental=[$wt_cache] target-dir=$target_key"
  [ -z "$clone_cache" ] && [ -z "$wt_cache" ] && [ "$target_key" = absent ]
}

proof_rerun_skips() {
  local before=""
  lane_fixture "$@"
  run_setup ./tools/lane-setup DAYTONA_SANDBOX_ID=test
  before="$(cat "$R/../.cargo/config.toml")" || return 1
  run_setup ./tools/lane-setup DAYTONA_SANDBOX_ID=test
  WHY="rc=$RC out=$OUT"
  [ "$RC" -eq 0 ] && [ "$(cat "$R/../.cargo/config.toml")" = "$before" ] \
    && case "$OUT" in *"lane-setup: cargo-config=skip"*) true ;; *) false ;; esac
}

proof_developer_untouched() {
  local lanes_config=absent
  lane_fixture "$@"
  run_setup ./.fleet-setup
  [ ! -e "$R/../.cargo" ] || lanes_config=present
  WHY="rc=$RC lanes-config=$lanes_config out=$OUT"
  [ "$RC" -eq 0 ] && [ "$lanes_config" = absent ] \
    && case "$OUT" in *"lane-setup: cargo-config=not-sandbox"*) true ;; *) false ;; esac
}

proof_foreign_refused() {
  local foreign='[build]
jobs = 1' after=""
  lane_fixture "$@"
  mkdir -p "$R/../.cargo"
  printf '%s\n' "$foreign" >"$R/../.cargo/config.toml"
  run_setup ./.fleet-setup DAYTONA_SANDBOX_ID=test
  after="$(cat "$R/../.cargo/config.toml")" || return 1
  WHY="rc=$RC config=[$after] out=$OUT"
  [ "$RC" -eq 1 ] && [ "$after" = "$foreign" ] \
    && case "$OUT" in *"lane-setup: cargo-config=foreign path=$(lanes_of)/.cargo/config.toml"*) true ;; *) false ;; esac
}

# linker_fixture IMAGE BINS [FROM TO]: a sandbox setup whose PATH holds BINS
# and whose image cargo config passes -fuse-ld=IMAGE when IMAGE is set.
linker_fixture() {
  local image=$1 bins=$2 bin=""
  shift 2
  lane_fixture "$@"
  EXTRA_BIN="$R/row-bin"
  mkdir -p "$EXTRA_BIN"
  for bin in $bins; do
    printf '#!/bin/sh\nexit 0\n' >"$EXTRA_BIN/$bin"
    chmod +x "$EXTRA_BIN/$bin"
  done
  if [ -n "$image" ]; then
    mkdir -p "$R/home/.cargo"
    printf '[target.%s]\nrustflags = ["-C", "link-arg=-fuse-ld=%s"]\n' "'cfg(target_os = \"linux\")'" "$image" >"$R/home/.cargo/config.toml"
  fi
  run_setup ./.fleet-setup DAYTONA_SANDBOX_ID=test
}

# A linker the setup writes adds one -fuse-ld flag on a Linux host and none
# elsewhere. `none` leaves the toy crate's rustc line equal to the baseline's
# and, since a Linux-only entry never reaches a non-Linux host's rustc line,
# the written config without a rustflags key.
proof_linker() { # IMAGE BINS EXPECT [FROM TO]
  local image=$1 bins=$2 expect=$3 out="" line="" config="" mold=0 lld=0
  shift 3
  linker_fixture "$image" "$bins" "$@"
  [ "$RC" -eq 0 ] || { WHY="rc=$RC out=$OUT"; return 1; }
  out="$(cargo_in "$R" check -v)" || { WHY="$out"; return 1; }
  line="$(toy_line "$out" "$R")"
  config="$(cat "$R/../.cargo/config.toml")" || return 1
  WHY="setup=$OUT line=$line baseline=$BASE_LINE config=$config"
  case "$OUT" in *"lane-setup: linker=$expect"*) ;; *) return 1 ;; esac
  [ -n "$line" ] || return 1
  case "$expect" in
    mold | image) mold=$LINK_DELTA ;;
    lld) lld=$LINK_DELTA ;;
    none)
      [ "$line" = "$BASE_LINE" ] && case "$config" in *rustflags*) false ;; *) true ;; esac
      return
      ;;
    *) WHY="unknown expectation $expect"; return 1 ;;
  esac
  [ "$(count "$out" -fuse-ld=mold)" -eq $((BASE_MOLD + mold)) ] && [ "$(count "$out" -fuse-ld=lld)" -eq $((BASE_LLD + lld)) ]
}

proof_linux_only() { # [FROM TO]
  local out=""
  linker_fixture "" mold "$@"
  [ "$RC" -eq 0 ] || { WHY="rc=$RC out=$OUT"; return 1; }
  # shellcheck disable=SC2086 # FOREIGN_ARGS is empty or one flag and its value
  out="$(cargo_in "$R" check -v $FOREIGN_ARGS)" || { WHY="$out"; return 1; }
  WHY="target=$FOREIGN_TARGET check=$out"
  case "$OUT" in *"lane-setup: linker=mold"*) ;; *) return 1 ;; esac
  case "$out" in *"--crate-name toy"*) ;; *) return 1 ;; esac
  [ "$(count "$out" -fuse-ld=)" -eq "$(count "$BASE_FOREIGN" -fuse-ld=)" ]
}

# The first line of every file the setup owns, read from the script itself.
OWNED_HEADER="$(sed -n "s/^owned_header='\(.*\)'\$/\1/p" "$TOOLS/lane-setup")"
[ -n "$OWNED_HEADER" ] || { bad "the owned_header extractor reads the header from lane-setup" "no owned_header= line matched"; exit 1; }

# proof_wrapper PRIOR ASSIGNMENT SCCACHE EXPECT CONFIG [FROM TO]: the sandbox
# setup with the endpoint ASSIGNMENT, after a first run with PRIOR when that
# is set. sccache wraps rustc and its config names the endpoint (redis),
# wraps rustc and its config is the owned header alone (local), or neither
# (unused). CONFIG is the sccache-config key the second run prints, write or
# skip, or none when it prints none.
proof_wrapper() {
  local prior=$1 assignment=$2 sccache=$3 expect=$4 config=$5 out="" conf="" conf_text=""
  shift 5
  lane_fixture "$@"
  EXTRA_BIN="$R/row-bin"
  mkdir -p "$EXTRA_BIN"
  if [ "$sccache" = present ]; then
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"${0%%/*}/sccache.log"\nexec "$@"\n' >"$EXTRA_BIN/sccache"
    chmod +x "$EXTRA_BIN/sccache"
  fi
  if [ -n "$prior" ]; then
    run_setup ./.fleet-setup DAYTONA_SANDBOX_ID=test "$prior"
    [ "$RC" -eq 0 ] || { WHY="prior rc=$RC out=$OUT"; return 1; }
  fi
  run_setup ./.fleet-setup DAYTONA_SANDBOX_ID=test ${assignment:+"$assignment"}
  [ "$RC" -eq 0 ] || { WHY="rc=$RC out=$OUT"; return 1; }
  out="$(cargo_in "$R" check -v)" || { WHY="$out"; return 1; }
  conf="$R/home/.config/sccache/config"
  if [ -e "$conf" ]; then
    conf_text="$(cat "$conf")" || return 1
  fi
  WHY="setup=$OUT conf=[$conf_text] check=$out"
  case "$config" in
    write | skip) case "$OUT" in *"lane-setup: sccache-config=$config"*) ;; *) return 1 ;; esac ;;
    none) case "$OUT" in *"lane-setup: sccache-config="*) return 1 ;; esac ;;
    *) WHY="unknown config key $config"; return 1 ;;
  esac
  case "$expect" in
    redis)
      [ -s "$EXTRA_BIN/sccache.log" ] && grep -qxF "endpoint = \"${assignment#*=}\"" "$conf" \
        && case "$OUT" in *"lane-setup: sccache-cache=redis"*) true ;; *) false ;; esac ;;
    local)
      [ -s "$EXTRA_BIN/sccache.log" ] && [ -e "$conf" ] && [ "$conf_text" = "$OWNED_HEADER" ] \
        && case "$OUT" in *"lane-setup: sccache-cache=local:endpoint-unset"*) true ;; *) false ;; esac ;;
    unused)
      [ ! -e "$EXTRA_BIN/sccache.log" ] && [ ! -e "$conf" ] \
        && case "$OUT" in *"lane-setup: sccache-cache="*) false ;; *) true ;; esac ;;
    *) WHY="unknown expectation $expect"; return 1 ;;
  esac
}

# A warm build links, so its PATH also holds the host's C linker driver and
# the linkers it or a host cargo config can name.
LINK_TOOLS=""
for tool in cc ld ld.mold mold ld.lld; do
  tool_path="$(command -v "$tool")" || continue
  LINK_TOOLS="$LINK_TOOLS $tool_path"
done
case "$LINK_TOOLS" in */cc\ * | */cc) ;; *) bad "the host provides cc for the warm build rows" "found:$LINK_TOOLS"; exit 1 ;; esac

# proof_warm WARM SOURCE WRAPPER STALE EXPECT [FROM TO]: the setup with
# FLEET_WARM=WARM on a toy crate, committed, that compiles with a current
# Cargo.lock (good), does not compile (broken), or has no Cargo.lock for
# --locked to accept (unlocked), with the real cargo on its PATH and the build
# kept in the clone's own target dir. WRAPPER sccache gives the lane config a
# pass-through sccache and an endpoint; none gives it no wrapper. STALE tree
# leaves a cut-off build's worktree, with an untracked file, at LANE_PATH;
# registration leaves its registration with the directory gone; foreign
# leaves a plain directory holding a file, which git does not know as a
# worktree; none leaves nothing. A build that ran compiled the crate at
# LANE_PATH and left no tree there; a refused run left the foreign directory
# as it was.
proof_warm() {
  local warm=$1 source=$2 wrapper=$3 stale=$4 expect=$5 lock="" exe="" built=no trees="" at_lane=no
  local -a endpoint=()
  shift 5
  lane_fixture "$@"
  case "$source" in
    good) ;;
    broken) printf 'pub fn toy( {}\n' >"$R/src/lib.rs" ;;
    unlocked) ;;
    *) WHY="unknown source $source"; return 1 ;;
  esac
  if [ "$source" != unlocked ]; then
    lock="$(cargo_in "$R" generate-lockfile)" || { WHY="generate-lockfile: $lock"; return 1; }
  fi
  git -C "$R" add -A || return 1
  git -C "$R" -c user.name=test -c user.email=test@example.com commit -q --allow-empty -m "$source crate" || return 1
  case "$stale" in
    none) ;;
    tree)
      git -C "$R" worktree add -q --detach "$LANE_PATH" HEAD || return 1
      printf 'partial\n' >"$LANE_PATH/leftover" || return 1
      ;;
    registration)
      git -C "$R" worktree add -q --detach "$LANE_PATH" HEAD || return 1
      rm -rf -- "$LANE_PATH" || return 1
      ;;
    foreign)
      mkdir -p "$LANE_PATH" || return 1
      printf 'keep\n' >"$LANE_PATH/keep" || return 1
      ;;
    *) WHY="unknown stale state $stale"; return 1 ;;
  esac
  EXTRA_BIN="$R/row-bin"
  mkdir -p "$EXTRA_BIN"
  ln -s "$CARGO_BIN" "$EXTRA_BIN/cargo"
  ln -s "$CARGO_DIR/rustc" "$EXTRA_BIN/rustc"
  for tool in $LINK_TOOLS; do
    ln -s "$tool" "$EXTRA_BIN/${tool##*/}"
  done
  case "$wrapper" in
    sccache)
      printf '#!/usr/bin/env bash\nexec "$@"\n' >"$EXTRA_BIN/sccache"
      chmod +x "$EXTRA_BIN/sccache"
      endpoint=(FLEET_SCCACHE_REDIS_ENDPOINT=tcp://cache.test:6379)
      ;;
    none) ;;
    *) WHY="unknown wrapper $wrapper"; return 1 ;;
  esac
  run_setup ./.fleet-setup DAYTONA_SANDBOX_ID=test CARGO_TARGET_DIR="$R/target" ${endpoint[@]+"${endpoint[@]}"} ${warm:+FLEET_WARM="$warm"}
  for exe in "$R"/target/debug/deps/toy-*; do
    case "${exe##*/}" in *.*) ;; *) [ ! -f "$exe" ] || [ ! -x "$exe" ] || built=yes ;; esac
  done
  trees="$(git -C "$R" worktree list --porcelain | grep -c '^worktree ')" || return 1
  case "$OUT" in *"Compiling toy v0.1.0 ($LANE_PATH)"*) at_lane=yes ;; esac
  WHY="rc=$RC built=$built at-lane=$at_lane trees=$trees out=$OUT"
  [ "$trees" -eq 1 ] || return 1
  [ "$expect" = refused ] || [ ! -e "$LANE_PATH" ] || return 1
  case "$expect" in
    refused) [ "$RC" -ne 0 ] && [ -f "$LANE_PATH/keep" ] && [ "$at_lane" = no ] && case "$OUT" in *"lane-setup: warm-tree=remove-stale path=$LANE_PATH"*) true ;; *) false ;; esac ;;
    built) [ "$RC" -eq 0 ] && [ "$built" = yes ] && [ "$at_lane" = yes ] && case "$OUT" in *"lane-setup: warm-build=run path=$LANE_PATH"*) true ;; *) false ;; esac ;;
    skipped) [ "$RC" -eq 0 ] && [ ! -e "$R/target" ] && case "$OUT" in *"lane-setup: warm-build=skip"*) true ;; *) false ;; esac ;;
    fetched) [ "$RC" -eq 0 ] && [ "$built" = no ] && [ "$at_lane" = no ] && case "$OUT" in *"lane-setup: warm-build=fetch-only:no-wrapper"*) true ;; *) false ;; esac ;;
    fetch-failed) [ "$RC" -ne 0 ] && [ "$built" = no ] && case "$OUT" in *"lane-setup: warm-build=fetch-only:no-wrapper"*) true ;; *) false ;; esac ;;
    failed) [ "$RC" -ne 0 ] && case "$OUT" in *"lane-setup: warm-build=run path=$LANE_PATH"*) true ;; *) false ;; esac ;;
    *) WHY="unknown expectation $expect"; return 1 ;;
  esac
}

echo "=== the lane cargo configuration ==="
WHY=""
proof_incremental_off && ok "a sandbox clone and its worktree write no incremental cache, and the config names no target dir" || bad "a sandbox clone and its worktree write no incremental cache, and the config names no target dir" "$WHY"
proof_rerun_skips && ok "a rerun leaves the written config as it was and says skip" || bad "a rerun skips an unchanged config" "$WHY"
proof_developer_untouched && ok "a developer checkout gets no lane config" || bad "a developer checkout gets no lane config" "$WHY"
proof_foreign_refused && ok "a config the script did not write is refused by name and left intact" || bad "a foreign config is refused and left intact" "$WHY"
while IFS='|' read -r image bins expect; do
  proof_linker "$image" "$bins" "$expect" && ok "linker: image [$image] bins [$bins] resolve $expect" || bad "linker: image [$image] bins [$bins] resolve $expect" "$WHY"
done <<'ROWS'
|mold ld.lld|mold
|ld.lld|lld
||none
mold|mold ld.lld|image
ROWS
if [ -n "$FOREIGN_TARGET" ]; then
  proof_linux_only && ok "linker: a non-Linux target ($FOREIGN_TARGET) gets no -fuse-ld flag" || bad "linker: a non-Linux target ($FOREIGN_TARGET) gets no -fuse-ld flag" "$WHY"
else
  ok "linker: non-Linux target row skipped, no aarch64-apple-darwin or x86_64-pc-windows-msvc in $SYSROOT"
fi
while IFS='|' read -r prior assignment sccache expect config; do
  proof_wrapper "$prior" "$assignment" "$sccache" "$expect" "$config" && ok "wrapper: [$assignment] after [$prior] with sccache $sccache is $expect, config $config" || bad "wrapper: [$assignment] after [$prior] with sccache $sccache is $expect, config $config" "$WHY"
done <<'ROWS'
|FLEET_SCCACHE_REDIS_ENDPOINT=tcp://cache.test:6379|present|redis|write
|FLEET_SCCACHE_REDIS_ENDPOINT=|present|local|write
||present|local|write
FLEET_SCCACHE_REDIS_ENDPOINT=tcp://cache.test:6379||present|local|write
FLEET_SCCACHE_REDIS_ENDPOINT=||present|local|skip
|FLEET_SCCACHE_REDIS_ENDPOINT=tcp://cache.test:6379|absent|unused|none
ROWS

while IFS='|' read -r warm source wrapper stale expect; do
  proof_warm "$warm" "$source" "$wrapper" "$stale" "$expect" && ok "warm: FLEET_WARM=[$warm] on a $source crate with wrapper $wrapper and stale $stale is $expect" || bad "warm: FLEET_WARM=[$warm] on a $source crate with wrapper $wrapper and stale $stale is $expect" "$WHY"
done <<'ROWS'
1|good|sccache|none|built
1|good|sccache|tree|built
1|good|sccache|registration|built
1|good|sccache|foreign|refused
|good|sccache|none|skipped
0|good|sccache|none|skipped
1|broken|sccache|none|failed
1|unlocked|sccache|none|failed
1|good|none|none|fetched
1|unlocked|none|none|fetch-failed
ROWS

echo "=== must-fail controls: each cargo proof fails against its mutant ==="
proof_incremental_off '  write_lane_cargo_config' '  :' \
  && bad "control: the unpatched script leaves incremental caches" "$WHY" \
  || ok "control: the unpatched script leaves incremental caches"
proof_incremental_off 'incremental = false"' $'incremental = false\ntarget-dir = $(toml_string "$lanes_dir/.cargo/target")"' \
  && bad "control: a target-dir entry in the lane config fails the incremental row" "$WHY" \
  || ok "control: a target-dir entry in the lane config fails the incremental row"
proof_rerun_skips '  if [ "$current" = "$content" ]; then' '  if false; then' \
  && bad "control: a rewrite of an unchanged config fails the rerun proof" "$WHY" \
  || ok "control: a rewrite of an unchanged config fails the rerun proof"
proof_developer_untouched 'if [ -z "${DAYTONA_SANDBOX_ID:-}" ]; then' 'if false; then' \
  && bad "control: writing on a developer checkout fails its proof" "$WHY" \
  || ok "control: writing on a developer checkout fails its proof"
proof_foreign_refused '      exit 1' '      true' \
  && bad "control: overwriting a foreign config fails the refusal proof" "$WHY" \
  || ok "control: overwriting a foreign config fails the refusal proof"
proof_linker '' 'mold ld.lld' mold '    if command -v mold >/dev/null; then' '    if false; then' \
  && bad "control: skipping mold fails the mold row" "$WHY" \
  || ok "control: skipping mold fails the mold row"
proof_linker '' '' none '    mold | lld)' '    mold | lld | none)' \
  && bad "control: a linker entry written anyway fails the none row" "$WHY" \
  || ok "control: a linker entry written anyway fails the none row"
proof_linker mold 'mold ld.lld' image '      0) linker=image ;;' '      0) ;;' \
  && bad "control: a second mold entry beside the image's fails the image row" "$WHY" \
  || ok "control: a second mold entry beside the image's fails the image row"
if [ -n "$FOREIGN_TARGET" ]; then
  proof_linux_only "[target.'cfg(target_os = \\\"linux\\\")']" "[target.'cfg(all())']" \
    && bad "control: a linker entry for every target fails the non-Linux row" "$WHY" \
    || ok "control: a linker entry for every target fails the non-Linux row"
fi
proof_wrapper '' FLEET_SCCACHE_REDIS_ENDPOINT= present local write '  if ! sccache_path="$(command -v sccache)"; then' '  if [ -z "${FLEET_SCCACHE_REDIS_ENDPOINT:-}" ] || ! sccache_path="$(command -v sccache)"; then' \
  && bad "control: a wrapper tied to the endpoint fails the empty-endpoint row" "$WHY" \
  || ok "control: a wrapper tied to the endpoint fails the empty-endpoint row"
proof_wrapper '' '' present local write '    if [ -n "${FLEET_SCCACHE_REDIS_ENDPOINT:-}" ]; then' '    if true; then' \
  && bad "control: a redis section written with no endpoint fails the unset-endpoint row" "$WHY" \
  || ok "control: a redis section written with no endpoint fails the unset-endpoint row"
proof_wrapper FLEET_SCCACHE_REDIS_ENDPOINT=tcp://cache.test:6379 '' present local write '    write_owned sccache-config "${XDG_CONFIG_HOME:-$HOME/.config}/sccache/config" "$sccache_config"' '    [ -z "$sccache_config" ] || write_owned sccache-config "${XDG_CONFIG_HOME:-$HOME/.config}/sccache/config" "$sccache_config"' \
  && bad "control: an earlier run's redis section left in place fails the rerun row" "$WHY" \
  || ok "control: an earlier run's redis section left in place fails the rerun row"
proof_wrapper FLEET_SCCACHE_REDIS_ENDPOINT= '' present local skip '  if [ -n "$3" ]; then' '  if true; then' \
  && bad "control: a blank line after the header of an empty config fails the no-endpoint rerun row" "$WHY" \
  || ok "control: a blank line after the header of an empty config fails the no-endpoint rerun row"

proof_warm 1 good sccache none built '  (cd -- "$lane_path" && cargo test --workspace --no-run --locked) || build_status=$?' '  :' \
  && bad "control: a warm run that builds nothing fails the built row" "$WHY" \
  || ok "control: a warm run that builds nothing fails the built row"
proof_warm 1 good sccache none built '  (cd -- "$lane_path" && cargo test --workspace --no-run --locked) || build_status=$?' '  (cargo test --workspace --no-run --locked) || build_status=$?' \
  && bad "control: a warm build in the clone rather than at the lane path fails the built row" "$WHY" \
  || ok "control: a warm build in the clone rather than at the lane path fails the built row"
proof_warm 1 good sccache none built '  git worktree remove --force -- "$lane_path"' '  :' \
  && bad "control: a warm tree left at the lane path fails the built row" "$WHY" \
  || ok "control: a warm tree left at the lane path fails the built row"
proof_warm '' good sccache none skipped 'elif [ "${FLEET_WARM:-}" = 1 ]; then' 'elif true; then' \
  && bad "control: a build without FLEET_WARM fails the skipped row" "$WHY" \
  || ok "control: a build without FLEET_WARM fails the skipped row"
proof_warm 0 good sccache none skipped 'elif [ "${FLEET_WARM:-}" = 1 ]; then' 'elif [ -n "${FLEET_WARM:-}" ]; then' \
  && bad "control: building on any non-empty FLEET_WARM fails the FLEET_WARM=0 row" "$WHY" \
  || ok "control: building on any non-empty FLEET_WARM fails the FLEET_WARM=0 row"
proof_warm 1 unlocked sccache none failed '  (cd -- "$lane_path" && cargo test --workspace --no-run --locked) || build_status=$?' '  (cd -- "$lane_path" && cargo test --workspace --no-run) || build_status=$?' \
  && bad "control: a warm build without --locked fails the unlocked row" "$WHY" \
  || ok "control: a warm build without --locked fails the unlocked row"
proof_warm 1 broken sccache none failed '  (cd -- "$lane_path" && cargo test --workspace --no-run --locked) || build_status=$?' '  (cd -- "$lane_path" && cargo test --workspace --no-run --locked) || true' \
  && bad "control: a swallowed build failure fails the failed row" "$WHY" \
  || ok "control: a swallowed build failure fails the failed row"
proof_warm 1 good none none fetched 'if [ "${FLEET_WARM:-}" = 1 ] && [ -z "$lane_wrapper" ]; then' 'if false; then' \
  && bad "control: a warm build with no wrapper fails the fetched row" "$WHY" \
  || ok "control: a warm build with no wrapper fails the fetched row"
proof_warm 1 unlocked none none fetch-failed '  cargo fetch --locked' '  :' \
  && bad "control: a skipped fetch fails the fetch-failed row" "$WHY" \
  || ok "control: a skipped fetch fails the fetch-failed row"
proof_warm 1 unlocked none none fetch-failed '  cargo fetch --locked' '  cargo fetch' \
  && bad "control: a fetch without --locked fails the fetch-failed row" "$WHY" \
  || ok "control: a fetch without --locked fails the fetch-failed row"
proof_warm 1 good sccache tree built '  if [ -e "$lane_path" ]; then' '  if false; then' \
  && bad "control: a stale tree left at the lane path fails the stale-tree row" "$WHY" \
  || ok "control: a stale tree left at the lane path fails the stale-tree row"
proof_warm 1 good sccache registration built '  git worktree add --force --quiet --detach -- "$lane_path" HEAD' '  git worktree add --quiet --detach -- "$lane_path" HEAD' \
  && bad "control: an add without --force fails the stale-registration row" "$WHY" \
  || ok "control: an add without --force fails the stale-registration row"
proof_warm 1 good sccache foreign refused '    git worktree remove --force -- "$lane_path"' '    git worktree remove --force -- "$lane_path" || mv -- "$lane_path" "$lane_path.gone"' \
  && bad "control: moving a foreign directory aside fails the foreign row" "$WHY" \
  || ok "control: moving a foreign directory aside fails the foreign row"

echo "=== the script starts under a real Bash 3.2 when one is reachable ==="
RUNTIMES="$(sed -n 's/^RUNTIMES="\(.*\)"$/\1/p' "$TOOLS/bash32-parse")"
IMAGE="$(sed -n 's/^IMAGE="\(.*\)"$/\1/p' "$TOOLS/bash32-parse")"
ran32=no
causes=""
fixture bash32; mkdir -p "$R/ui/node_modules"
run_bash32() {
  "$runtime_path" run --rm --init --network=none --volume "$R:/repo:ro" --tmpfs /repo/ui/node_modules --workdir /repo --env HOME=/tmp --env DAYTONA_SANDBOX_ID=test --env PATH=/repo/fake-bin:/usr/local/bin:/usr/bin:/bin --env NPM_LOG=/tmp/npm.log --env RUSTUP_LOG=/tmp/rustup.log --env RUSTUP_STATE=/tmp/rustup.state "$IMAGE" bash "$@"
}
for runtime in $RUNTIMES; do
  runtime_path="$(command -v "$runtime" 2>/dev/null)" || continue
  probe="$(run_bash32 -c 'for command in bash git node npm rustc rustup grep cat mkdir mv; do command -v "$command" >/dev/null || exit 1; done; printf %s "$BASH_VERSION"' 2>&1)" || { causes="$causes $runtime:$probe"; continue; }
  case "$probe" in 3.2.*) ;; *) causes="$causes $runtime:$probe"; continue ;; esac
  RC=0
  OUT="$(run_bash32 ./tools/lane-setup 2>&1)" || RC=$?
  [ "$RC" -eq 0 ] && [ ! -e "$R/ui/node_modules/.kendex-lane-setup" ] && case "$OUT" in *"lane-setup: rust-targets=install"*"lane-setup: cargo-config=write"*) true ;; *) false ;; esac \
    && ok "the setup executes under Bash $probe, writes the lane cargo config and cleans its runtime-owned tree" \
    || bad "the setup executes under Bash $probe" "rc=$RC out=$OUT"
  ran32=yes
  break
done
[ "$ran32" = yes ] || ok "Bash 3.2 execution unavailable:${causes:- no declared runtime is installed}"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
