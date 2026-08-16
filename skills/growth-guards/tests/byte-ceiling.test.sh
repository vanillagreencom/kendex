#!/usr/bin/env bash
# Pins for scripts/byte-ceiling: additions over the ceiling fail in every
# mode, diff-scoping really is addition-only (modifications and renames
# pass), lockfiles and excluded trees are exempt (each with a control
# proving the exemption is what passed it), configuration resolves, and a
# broken measurement is a collection error — never a pass.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
BC="$SKILL_DIR/scripts/byte-ceiling"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

unset GROWTH_GUARDS_BYTE_CEILING_KB GROWTH_GUARDS_BYTE_EXCLUDES GROWTH_GUARDS_SETTINGS_FILE 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

new_repo() { # NAME
  R="$TMP/$1"
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
}

mkbytes() { # PATH KB — file of KB*1024 bytes under $R
  mkdir -p "$R/$(dirname "$1")"
  dd if=/dev/zero of="$R/$1" bs=1024 count="$2" 2>/dev/null
}

run_bc() { # [args...] — run in $R at ceiling 1 KB; sets OUT and RC
  OUT=""
  RC=0
  OUT="$(cd "$R" && GROWTH_GUARDS_BYTE_CEILING_KB=1 "$BC" "$@" 2>&1)" || RC=$?
}

run_bc_default() { # [args...] — run in $R at the built-in default ceiling
  OUT=""
  RC=0
  OUT="$(cd "$R" && "$BC" "$@" 2>&1)" || RC=$?
}

echo "=== staged mode: additions over the ceiling fail; at-ceiling passes ==="
new_repo staged
mkbytes small.bin 1
git -C "$R" add -A
run_bc
[ "$RC" -eq 0 ] && case "$OUT" in *"1 staged addition(s) checked"*) true ;; *) false ;; esac \
  && ok "a 1 KB addition at ceiling 1 KB passes (at-ceiling is not over)" \
  || bad "at-ceiling addition passes" "rc=$RC out=$OUT"

mkbytes big.bin 2
git -C "$R" add -A
run_bc
[ "$RC" -eq 1 ] && case "$OUT" in *"oversized file: big.bin — 2048 bytes"*"> ceiling 1 KB"*) true ;; *) false ;; esac \
  && ok "a 2 KB addition at ceiling 1 KB fails, naming file/bytes/ceiling" \
  || bad "oversized addition fails with bytes and ceiling" "rc=$RC out=$OUT"
case "$OUT" in *"asset store, Git LFS, build-time generation"*) ok "diagnostic carries the remediation" ;; *) bad "diagnostic carries the remediation" "$OUT" ;; esac

echo "=== the built-in default 200 KB is real, not vacuous ==="
new_repo defreal
mkbytes big.bin 205
git -C "$R" add -A
run_bc_default
[ "$RC" -eq 1 ] && case "$OUT" in *"ceiling 200 KB"*) true ;; *) false ;; esac \
  && ok "a 205 KB addition fails under the built-in default 200" \
  || bad "default 200 can fail" "rc=$RC out=$OUT"
rm "$R/big.bin"
mkbytes ok.bin 100
git -C "$R" add -A
run_bc_default
[ "$RC" -eq 0 ] && ok "a 100 KB addition passes under the default (control)" \
  || bad "100 KB passes under the default" "rc=$RC out=$OUT"

echo "=== diff-scoping: modification and rename are not additions ==="
new_repo grown
mkbytes seed.bin 3
git -C "$R" add -A
git -C "$R" commit -qm "seed: legacy file over any future ceiling"
mkbytes seed.bin 5
git -C "$R" add -A
run_bc
[ "$RC" -eq 0 ] && case "$OUT" in *"0 staged addition(s)"*) true ;; *) false ;; esac \
  && ok "growing an existing tracked file is not an addition (staged mode)" \
  || bad "modification is not an addition" "rc=$RC out=$OUT"
git -C "$R" mv seed.bin moved.bin
run_bc
[ "$RC" -eq 0 ] && ok "renaming an existing large file is not an addition (rename detection pinned on)" \
  || bad "rename is not an addition" "rc=$RC out=$OUT"
cp "$R/moved.bin" "$R/second-copy.bin" 2>/dev/null || true
printf 'x' >>"$R/second-copy.bin"
git -C "$R" add -A
run_bc
[ "$RC" -eq 1 ] && case "$OUT" in *"second-copy.bin"*) true ;; *) false ;; esac \
  && ok "control: a genuinely new large file beside the rename still fails" \
  || bad "control: new large file fails beside the rename" "rc=$RC out=$OUT"
new_repo copy
mkbytes big.bin 3
git -C "$R" add -A
git -C "$R" commit -qm "seed: an oversized tracked file"
cp "$R/big.bin" "$R/twin.bin"
git -C "$R" add -A
run_bc
[ "$RC" -eq 1 ] && case "$OUT" in *"twin.bin"*) true ;; *) false ;; esac \
  && ok "an exact copy of an oversized tracked file IS an addition (it duplicates the bytes; only renames are followed)" \
  || bad "an exact copy is an addition" "rc=$RC out=$OUT"

echo "=== --all: the full sweep gates legacy files the staged mode skips ==="
new_repo legacy
mkbytes old.bin 4
git -C "$R" add -A
git -C "$R" commit -qm "seed: legacy oversized file"
run_bc
[ "$RC" -eq 0 ] && ok "staged mode passes with nothing staged (legacy untouched)" \
  || bad "staged mode passes on the legacy repo" "rc=$RC out=$OUT"
run_bc --all
[ "$RC" -eq 1 ] && case "$OUT" in *"old.bin"*"full sweep"*) true ;; *) false ;; esac \
  && ok "--all fails on the legacy oversized file" || bad "--all fails on legacy" "rc=$RC out=$OUT"

echo "=== --base REF: additions since the merge-base ==="
git -C "$R" checkout -qb feature
mkbytes feat.bin 2
git -C "$R" add -A
git -C "$R" commit -qm "feature adds an oversized file"
run_bc --base main
[ "$RC" -eq 1 ] && case "$OUT" in *"feat.bin"*"added since main"*) true ;; *) false ;; esac \
  && ok "--base main fails on the branch's added file" || bad "--base fails on the added file" "rc=$RC out=$OUT"
git -C "$R" checkout -q main
run_bc --base main
[ "$RC" -eq 0 ] && ok "control: --base main on main itself has no additions" \
  || bad "control: --base with no additions passes" "rc=$RC out=$OUT"
run_bc --base no-such-ref
[ "$RC" -eq 2 ] && ok "an unknown --base ref is exit 2" || bad "unknown --base ref is exit 2" "rc=$RC out=$OUT"

echo "=== lockfiles are exempt by basename; same bytes elsewhere are not ==="
new_repo lock
mkbytes package-lock.json 2
git -C "$R" add -A
run_bc
[ "$RC" -eq 0 ] && ok "an oversized package-lock.json passes (built-in lockfile exemption)" \
  || bad "lockfile exemption" "rc=$RC out=$OUT"
cp "$R/package-lock.json" "$R/data.json"
git -C "$R" add -A
run_bc
[ "$RC" -eq 1 ] && case "$OUT" in *"data.json"*) true ;; *) false ;; esac \
  && ok "control: the same bytes as data.json fail — the exemption is the basename, not the size" \
  || bad "control: non-lockfile with same bytes fails" "rc=$RC out=$OUT"

echo "=== excludes: declared asset trees, reason mandatory ==="
new_repo assets
mkdir -p "$R/tools"
mkbytes assets/demo.gif 2
git -C "$R" add -A
run_bc
[ "$RC" -eq 1 ] && ok "control: the asset fails without an excludes row" \
  || bad "control: asset fails without excludes" "rc=$RC out=$OUT"
printf 'assets/*\tdemo media\n' >"$R/tools/byte-ceiling-excludes"
git -C "$R" add -A
run_bc
[ "$RC" -eq 0 ] && ok "the excludes row exempts the declared asset tree" \
  || bad "excludes row exempts the asset tree" "rc=$RC out=$OUT"
printf 'assets/*\n' >"$R/tools/byte-ceiling-excludes"
git -C "$R" add -A
run_bc
[ "$RC" -eq 2 ] && ok "a pattern without a reason is exit 2" || bad "pattern without a reason is exit 2" "rc=$RC out=$OUT"

echo "=== configuration errors ==="
new_repo cfg
printf 'x\n' >"$R/f.txt"
git -C "$R" add -A
OUT="$(cd "$R" && GROWTH_GUARDS_BYTE_CEILING_KB=abc "$BC" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && ok "non-numeric ceiling is exit 2" || bad "non-numeric ceiling is exit 2" "rc=$RC out=$OUT"
OUT="$(cd "$R" && GROWTH_GUARDS_BYTE_CEILING_KB=0 "$BC" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && ok "zero ceiling is exit 2" || bad "zero ceiling is exit 2" "rc=$RC out=$OUT"
run_bc --no-such-flag
[ "$RC" -eq 2 ] && ok "unknown flag is exit 2" || bad "unknown flag is exit 2" "rc=$RC out=$OUT"

echo "=== settings file resolution ==="
printf '[env]\nGROWTH_GUARDS_BYTE_CEILING_KB = "3"\n' >"$R/vstack.settings.toml"
mkbytes big.bin 4
git -C "$R" add -A
run_bc_default
[ "$RC" -eq 1 ] && case "$OUT" in *"ceiling 3 KB"*) true ;; *) false ;; esac \
  && ok "vstack.settings.toml overrides the default (4 KB > 3 fails; 200 would have passed)" \
  || bad "settings file overrides the default" "rc=$RC out=$OUT"
OUT="$(cd "$R" && GROWTH_GUARDS_BYTE_CEILING_KB=5 "$BC" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 0 ] && ok "environment overrides the settings file (5 passes where 3 failed)" \
  || bad "environment overrides the settings file" "rc=$RC out=$OUT"

echo "=== settings: an unreadable source fails loud, never falls through ==="
if [ "$(id -u)" -eq 0 ]; then
  printf '  skip  unreadable-source pins need a non-root reader (chmod 000 cannot deny root)\n'
else
  printf 'GROWTH_GUARDS_BYTE_CEILING_KB=5\n' >"$R/.env.local"
  chmod 000 "$R/.env.local"
  run_bc_default
  [ "$RC" -eq 2 ] && case "$OUT" in *"unreadable while resolving a setting"*) true ;; *) false ;; esac \
    && ok "an unreadable .env.local is exit 2 (falling through would have read 3 from the settings file and exited 1)" \
    || bad "unreadable .env.local is exit 2" "rc=$RC out=$OUT"
  chmod 600 "$R/.env.local"
  run_bc_default
  [ "$RC" -eq 0 ] && ok "control: the same .env.local, readable, supplies 5 and the 4 KB file passes" \
    || bad "control: readable .env.local supplies the value" "rc=$RC out=$OUT"
  rm "$R/.env.local"
fi

echo "=== fail-closed: a broken blob measurement terminates, never passes ==="
new_repo measure
mkbytes big.bin 2
git -C "$R" add -A
run_bc
[ "$RC" -eq 1 ] && ok "shim-free control: the oversized staged file really fails" \
  || bad "shim-free control fails on the oversized file" "rc=$RC out=$OUT"
REAL_GIT="$(command -v git)"
GIT_SHIM="$TMP/git-shim"
mkdir -p "$GIT_SHIM"
cat >"$GIT_SHIM/git" <<EOF
#!/usr/bin/env bash
if [ "\${1:-}" = "cat-file" ] && [ "\${2:-}" = "-s" ]; then
  echo "fatal: simulated object read failure" >&2
  exit 128
fi
exec "$REAL_GIT" "\$@"
EOF
chmod +x "$GIT_SHIM/git"
OUT="$(cd "$R" && PATH="$GIT_SHIM:$PATH" GROWTH_GUARDS_BYTE_CEILING_KB=1 "$BC" 2>&1)" && RC=0 || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"cannot read blob"*"big.bin"*) true ;; *) false ;; esac \
  && ok "an unmeasurable blob is a collection error: exit 2, diagnostic names the file" \
  || bad "an unmeasurable blob is a collection error naming the file" "rc=$RC out=$OUT"
case "$OUT" in *"byte-ceiling: OK"*) bad "no OK verdict may accompany a broken measurement" "$OUT" ;; *) ok "no OK verdict accompanies the broken measurement" ;; esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
