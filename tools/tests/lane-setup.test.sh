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

fixture() {
  R="$TMP/$1"
  mkdir -p "$R/tools" "$R/ui" "$R/fake-bin" "$R/home"
  cp "$REPO/.fleet-setup" "$R/"
  cp "$TOOLS/lane-setup" "$R/tools/"
  chmod +x "$R/.fleet-setup" "$R/tools/lane-setup"
  printf 'ui/node_modules/\n' >"$R/.gitignore"
  printf '{"scripts":{}}\n' >"$R/ui/package.json"
  printf '{}\n' >"$R/ui/package-lock.json"
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

run_setup() {
  RC=0
  OUT="$(cd "$R" && env -i HOME="$R/home" PATH="$R/fake-bin:/usr/bin:/bin" NPM_LOG="$NPM_LOG" RUSTUP_LOG="$RUSTUP_LOG" RUSTUP_STATE="$RUSTUP_STATE" NPM_FAIL="${NPM_FAIL:-0}" RUSTUP_FAIL="${RUSTUP_FAIL:-0}" "$1" 2>&1)" || RC=$?
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
fixture mutant
line='  npm ci --no-audit --no-fund --prefix ui'
[ "$(grep -cF "$line" "$R/tools/lane-setup")" -eq 1 ] || { bad "the mutant matches one npm command"; exit 1; }
sed 's/^  npm ci --no-audit --no-fund --prefix ui$/  npm ci --no-audit --no-fund --prefix ui || true/' "$R/tools/lane-setup" >"$R/tools/lane-setup.mutant"
cmp -s "$R/tools/lane-setup" "$R/tools/lane-setup.mutant" && { bad "the mutant changes the script"; exit 1; }
mv "$R/tools/lane-setup.mutant" "$R/tools/lane-setup"
chmod +x "$R/tools/lane-setup"
NPM_FAIL=23 run_setup ./tools/lane-setup
[ "$RC" -eq 0 ] && [ -s "$RUSTUP_LOG" ] \
  && ok "control: the swallowed npm status exits clean and reaches rustup" \
  || bad "control: the swallowed npm status should turn the failure row green" "rc=$RC out=$OUT"

echo "=== the script starts under a real Bash 3.2 when one is reachable ==="
RUNTIMES="$(sed -n 's/^RUNTIMES="\(.*\)"$/\1/p' "$TOOLS/bash32-parse")"
IMAGE="$(sed -n 's/^IMAGE="\(.*\)"$/\1/p' "$TOOLS/bash32-parse")"
ran32=no
causes=""
fixture bash32
run_bash32() {
  "$runtime_path" run --rm --init --network=none --volume "$R:/repo" --workdir /repo --env HOME=/tmp --env PATH=/repo/fake-bin:/usr/local/bin:/usr/bin:/bin --env NPM_LOG=/repo/npm.log --env RUSTUP_LOG=/repo/rustup.log --env RUSTUP_STATE=/repo/rustup.state "$IMAGE" bash "$@"
}
for runtime in $RUNTIMES; do
  runtime_path="$(command -v "$runtime" 2>/dev/null)" || continue
  probe="$(run_bash32 -c 'for command in bash git node npm rustc rustup grep cat; do command -v "$command" >/dev/null || exit 1; done; printf %s "$BASH_VERSION"' 2>&1)" || { causes="$causes $runtime:$probe"; continue; }
  case "$probe" in 3.2.*) ;; *) causes="$causes $runtime:$probe"; continue ;; esac
  RC=0
  OUT="$(run_bash32 ./tools/lane-setup 2>&1)" || RC=$?
  [ "$RC" -eq 0 ] && case "$OUT" in *"lane-setup: rust-targets=install"*) true ;; *) false ;; esac \
    && ok "the setup executes under Bash $probe" \
    || bad "the setup executes under Bash $probe" "rc=$RC out=$OUT"
  ran32=yes
  break
done
[ "$ran32" = yes ] || ok "Bash 3.2 execution unavailable:${causes:- no declared runtime is installed}"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
