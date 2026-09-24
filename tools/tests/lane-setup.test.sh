#!/usr/bin/env bash
# Proves the fleet clone setup against the commands a lane image supplies.
set -euo pipefail

unset GIT_DIR GIT_COMMON_DIR GIT_WORK_TREE GIT_INDEX_FILE

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$(cd "$TEST_DIR/.." && pwd)"
REPO="$(cd "$TOOLS/.." && pwd)"
mkdir -p "$REPO/tmp"
TMP="$(mktemp -d "$REPO/tmp/lane-setup.XXXXXX")"
trap 'rm -rf -- "${TMP:?}"' EXIT

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
# FROM and TO are given.
fixture() {
  R="$TMP/$1"
  EXTRA_BIN=""
  mkdir -p "$R/tools" "$R/ui" "$R/fake-bin" "$R/home" "$R/src"
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
  cat >"$R/fake-bin/git" <<'SH'
#!/usr/bin/env bash
set -eu
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
  chmod +x "$R/fake-bin/"*
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
  OUT="$(cd "$R" && env -i HOME="$R/home" PATH="${EXTRA_BIN:+$EXTRA_BIN:}$R/fake-bin:$SYS_BIN" NPM_LOG="$NPM_LOG" RUSTUP_LOG="$RUSTUP_LOG" RUSTUP_STATE="$RUSTUP_STATE" NPM_FAIL="${NPM_FAIL:-0}" RUSTUP_FAIL="${RUSTUP_FAIL:-0}" "$@" "$command" 2>&1)" || RC=$?
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

cargo_in() { # DIR ARGS...
  local dir=$1
  shift
  (cd "$dir" && env -i HOME="$R/home" PATH="$CARGO_DIR:/usr/bin:/bin" CARGO_HOME="$R/home/.cargo" CARGO_NET_OFFLINE=true "$CARGO_BIN" "$@" 2>&1)
}

target_of() { # DIR
  local meta=""
  meta="$(cargo_in "$1" metadata --format-version 1 --no-deps)" || { printf 'metadata-failed:%s' "$meta"; return 0; }
  sed -n 's/.*"target_directory":"\([^"]*\)".*/\1/p' <<<"$meta"
}

count() { # TEXT NEEDLE
  local text=$1 n=0
  while case "$text" in *"$2"*) true ;; *) false ;; esac; do
    text="${text#*"$2"}"
    n=$((n + 1))
  done
  printf '%s' "$n"
}

lanes_of() { (cd "$R/.." && pwd -P); }

# lane_fixture [FROM TO]: a clone alone in its own lanes directory, which is
# where the setup writes the cargo config.
LANES=0
lane_fixture() {
  LANES=$((LANES + 1))
  fixture "lanes-$LANES/clone" "$@"
}

# Every proof takes the fixture's optional mutation, so its control reruns
# the same proof against a mutant and expects it to fail.
proof_shared_target() {
  local lanes="" wt="" clone_target="" wt_target="" incremental=""
  lane_fixture "$@"
  lanes="$(lanes_of)" || return 1
  run_setup ./.fleet-setup DAYTONA_SANDBOX_ID=test
  [ "$RC" -eq 0 ] || { WHY="rc=$RC out=$OUT"; return 1; }
  wt="$lanes/.worktrees/clone/wt"
  git -C "$R" worktree add -q "$wt" || return 1
  clone_target="$(target_of "$R")"
  wt_target="$(target_of "$wt")"
  cargo_in "$R" check -q >/dev/null || return 1
  cargo_in "$wt" check -q >/dev/null || return 1
  # Cargo lays out debug/incremental whatever the setting; a session writes
  # a directory inside it.
  incremental="$(ls -A "$clone_target/debug/incremental" 2>&1)" || incremental="unreadable: $incremental"
  WHY="clone=$clone_target worktree=$wt_target incremental=$incremental"
  [ "$clone_target" = "$lanes/.cargo/target" ] && [ "$wt_target" = "$clone_target" ] && [ -z "$incremental" ]
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
  lane_fixture "$@"
  run_setup ./.fleet-setup
  WHY="rc=$RC out=$OUT"
  [ "$RC" -eq 0 ] && [ ! -e "$R/../.cargo" ] && [ "$(target_of "$R")" = "$(lanes_of)/clone/target" ] \
    && case "$OUT" in *"lane-setup: cargo-config=not-sandbox"*) true ;; *) false ;; esac
}

proof_fleet_target_kept() {
  local fleet_target=""
  lane_fixture "$@"
  fleet_target="$(lanes_of)/fleet-target" || return 1
  run_setup ./.fleet-setup DAYTONA_SANDBOX_ID=test CARGO_TARGET_DIR="$fleet_target"
  WHY="rc=$RC target=$(target_of "$R") out=$OUT"
  [ "$RC" -eq 0 ] && [ "$(target_of "$R")" = "$fleet_target" ]
}

proof_foreign_refused() {
  local foreign='[build]
jobs = 1'
  lane_fixture "$@"
  mkdir -p "$R/../.cargo"
  printf '%s\n' "$foreign" >"$R/../.cargo/config.toml"
  run_setup ./.fleet-setup DAYTONA_SANDBOX_ID=test
  WHY="rc=$RC out=$OUT"
  [ "$RC" -eq 1 ] && [ "$(cat "$R/../.cargo/config.toml")" = "$foreign" ] \
    && case "$OUT" in *"lane-setup: cargo-config=foreign path=$(lanes_of)/.cargo/config.toml"*) true ;; *) false ;; esac
}

# The rustc line of a fresh `cargo check -v` carries the resolved rustflags;
# a host whose own config adds a linker flag shows it in the baseline too.
LINK_DELTA=0
[ "$(uname -s)" != Linux ] || LINK_DELTA=1
fixture baseline/clone
BASE="$(cargo_in "$R" check -v)" || { bad "the baseline check runs" "$BASE"; exit 1; }
case "$BASE" in *"--crate-name toy"*) ;; *) bad "the baseline check compiles the toy crate" "$BASE"; exit 1 ;; esac
BASE_MOLD="$(count "$BASE" -fuse-ld=mold)"
BASE_LLD="$(count "$BASE" -fuse-ld=lld)"

proof_linker() { # BINS EXPECT [FROM TO]
  local bins=$1 expect=$2 bin="" out="" mold=0 lld=0
  shift 2
  lane_fixture "$@"
  EXTRA_BIN="$R/row-bin"
  mkdir -p "$EXTRA_BIN"
  for bin in $bins; do
    printf '#!/bin/sh\nexit 0\n' >"$EXTRA_BIN/$bin"
    chmod +x "$EXTRA_BIN/$bin"
  done
  run_setup ./.fleet-setup DAYTONA_SANDBOX_ID=test
  [ "$RC" -eq 0 ] || { WHY="rc=$RC out=$OUT"; return 1; }
  out="$(cargo_in "$R" check -v)" || { WHY="$out"; return 1; }
  case "$expect" in
    mold) mold=$LINK_DELTA ;;
    lld) lld=$LINK_DELTA ;;
    none) ;;
    *) WHY="unknown expectation $expect"; return 1 ;;
  esac
  WHY="bins=$bins setup=$OUT check=$out"
  case "$out" in *"--crate-name toy"*) ;; *) return 1 ;; esac
  case "$OUT" in *"lane-setup: linker=$expect"*) ;; *) return 1 ;; esac
  [ "$(count "$out" -fuse-ld=mold)" -eq $((BASE_MOLD + mold)) ] && [ "$(count "$out" -fuse-ld=lld)" -eq $((BASE_LLD + lld)) ]
}

proof_wrapper() { # ENDPOINT-ASSIGNMENT SCCACHE EXPECT [FROM TO]
  local assignment=$1 sccache=$2 expect=$3 out="" conf=""
  shift 3
  lane_fixture "$@"
  EXTRA_BIN="$R/row-bin"
  mkdir -p "$EXTRA_BIN"
  if [ "$sccache" = present ]; then
    printf '#!/usr/bin/env bash\nprintf "%%s\\n" "$*" >>"${0%%/*}/sccache.log"\nexec "$@"\n' >"$EXTRA_BIN/sccache"
    chmod +x "$EXTRA_BIN/sccache"
  fi
  if [ -n "$assignment" ]; then
    run_setup ./.fleet-setup DAYTONA_SANDBOX_ID=test "$assignment"
  else
    run_setup ./.fleet-setup DAYTONA_SANDBOX_ID=test
  fi
  [ "$RC" -eq 0 ] || { WHY="rc=$RC out=$OUT"; return 1; }
  out="$(cargo_in "$R" check -v)" || { WHY="$out"; return 1; }
  conf="$R/home/.config/sccache/config"
  WHY="setup=$OUT check=$out"
  case "$expect" in
    used)
      [ -s "$EXTRA_BIN/sccache.log" ] && grep -qxF "endpoint = \"${assignment#*=}\"" "$conf" ;;
    unused)
      [ ! -e "$EXTRA_BIN/sccache.log" ] && [ ! -e "$conf" ] ;;
    *) WHY="unknown expectation $expect"; return 1 ;;
  esac
}

echo "=== the lane cargo configuration ==="
WHY=""
proof_shared_target && ok "a sandbox clone and its worktree resolve one target dir and write no incremental cache" || bad "a sandbox clone and its worktree share one target dir, incremental off" "$WHY"
proof_rerun_skips && ok "a rerun leaves the written config as it was and says skip" || bad "a rerun skips an unchanged config" "$WHY"
proof_developer_untouched && ok "a developer checkout gets no lane config and keeps its own target dir" || bad "a developer checkout gets no lane config" "$WHY"
proof_fleet_target_kept && ok "the fleet's CARGO_TARGET_DIR is the target dir the config names" || bad "the fleet's CARGO_TARGET_DIR is kept" "$WHY"
proof_foreign_refused && ok "a config the script did not write is refused by name and left intact" || bad "a foreign config is refused and left intact" "$WHY"
while IFS='|' read -r bins expect; do
  proof_linker "$bins" "$expect" && ok "linker: bins [$bins] resolve $expect" || bad "linker: bins [$bins] resolve $expect" "$WHY"
done <<'ROWS'
mold ld.lld|mold
ld.lld|lld
|none
ROWS
while IFS='|' read -r assignment sccache expect; do
  proof_wrapper "$assignment" "$sccache" "$expect" && ok "wrapper: [$assignment] with sccache $sccache is $expect" || bad "wrapper: [$assignment] with sccache $sccache is $expect" "$WHY"
done <<'ROWS'
FLEET_SCCACHE_REDIS_ENDPOINT=tcp://cache.test:6379|present|used
FLEET_SCCACHE_REDIS_ENDPOINT=|present|unused
|present|unused
FLEET_SCCACHE_REDIS_ENDPOINT=tcp://cache.test:6379|absent|unused
ROWS

echo "=== must-fail controls: each cargo proof fails against its mutant ==="
proof_shared_target '  write_lane_cargo_config' '  :' \
  && bad "control: the unpatched script leaves two target dirs and incremental caches" "$WHY" \
  || ok "control: the unpatched script leaves two target dirs and incremental caches"
proof_rerun_skips '  if [ "$current" = "$content" ]; then' '  if false; then' \
  && bad "control: a rewrite of an unchanged config fails the rerun proof" "$WHY" \
  || ok "control: a rewrite of an unchanged config fails the rerun proof"
proof_developer_untouched 'if [ -z "${DAYTONA_SANDBOX_ID:-}" ]; then' 'if false; then' \
  && bad "control: writing on a developer checkout fails its proof" "$WHY" \
  || ok "control: writing on a developer checkout fails its proof"
proof_fleet_target_kept '  target_dir="${CARGO_TARGET_DIR:-$lanes_dir/.cargo/target}"' '  target_dir="$lanes_dir/.cargo/target"' \
  && bad "control: ignoring the fleet's CARGO_TARGET_DIR fails its proof" "$WHY" \
  || ok "control: ignoring the fleet's CARGO_TARGET_DIR fails its proof"
proof_foreign_refused '      exit 1' '      true' \
  && bad "control: overwriting a foreign config fails the refusal proof" "$WHY" \
  || ok "control: overwriting a foreign config fails the refusal proof"
proof_linker 'mold ld.lld' mold '  if command -v mold >/dev/null; then' '  if false; then' \
  && bad "control: skipping mold fails the mold row" "$WHY" \
  || ok "control: skipping mold fails the mold row"
proof_wrapper FLEET_SCCACHE_REDIS_ENDPOINT= present unused '  if [ -z "${FLEET_SCCACHE_REDIS_ENDPOINT:-}" ]; then' '  if false; then' \
  && bad "control: a wrapper on an empty endpoint fails the empty-endpoint row" "$WHY" \
  || ok "control: a wrapper on an empty endpoint fails the empty-endpoint row"

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
