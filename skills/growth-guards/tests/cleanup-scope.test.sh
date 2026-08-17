#!/usr/bin/env bash
# Pins for the family's EXIT cleanup: it removes only what THIS process
# created. An inherited GG_TMP or ownership flag must never decide what a
# guard deletes, and a check a hook lane runs must not remove the settings
# cache its parent is still reading. Every hostile-environment pin is paired
# with the clean-environment control.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TB="$SKILL_DIR/scripts/todo-ban"
PC="$SKILL_DIR/scripts/pre-commit"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gg-cleanup-scope.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

unset GROWTH_GUARDS_CHECKS GROWTH_GUARDS_SETTINGS_FILE GG_TMP \
  GG_SETTINGS_INDEX_OWNED GG_SETTINGS_INDEX_DIR GG_SETTINGS_FROM_INDEX 2>/dev/null || true

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

new_repo() { # NAME -> repo path on stdout
  local r="$TMP/$1"
  mkdir -p "$r"
  git -C "$r" -c init.defaultBranch=main init -q
  git -C "$r" config user.email test@example.com
  git -C "$r" config user.name test
  printf 'fn main() {}\n' >"$r/ok.rs"
  # A TRACKED settings source, so the hook lane materializes an index copy
  # into the cache the children inherit.
  printf '[env]\nGROWTH_GUARDS_BYTE_CEILING_KB = "200"\n' >"$r/vstack.settings.toml"
  git -C "$r" add -A
  printf '%s' "$r"
}

# A sentinel a correct cleanup never touches: an inherited GG_TMP naming it
# would be rm -rf'd by the guard's own EXIT trap.
new_sentinel() { # NAME -> path on stdout
  local d="$TMP/$1"
  mkdir -p "$d"
  printf 'precious\n' >"$d/keep.txt"
  printf '%s' "$d"
}

echo "=== a standalone check never deletes an inherited GG_TMP ==="
R="$(new_repo standalone)"
S="$(new_sentinel sentinel-standalone)"
RC=0
OUT="$(cd "$R" && GG_TMP="$S" "$TB" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "control: the check itself still passes with GG_TMP inherited" \
  || bad "check passes with GG_TMP inherited" "rc=$RC out=$OUT"
[ -f "$S/keep.txt" ] && ok "the inherited directory survives the check's exit" \
  || bad "inherited GG_TMP survives todo-ban" "$S/keep.txt is gone"

echo "=== a hook lane never deletes an inherited GG_TMP ==="
R2="$(new_repo hooklane)"
S2="$(new_sentinel sentinel-hooklane)"
RC=0
OUT="$(cd "$R2" && GG_TMP="$S2" "$PC" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "control: the pre-commit chain still passes with GG_TMP inherited" \
  || bad "pre-commit passes with GG_TMP inherited" "rc=$RC out=$OUT"
# pre-commit arms the cleanup trap through gg_settings_index_mode, which
# creates no scratch directory of its own — so an inherited name is the only
# thing the trap could act on.
[ -f "$S2/keep.txt" ] && ok "the inherited directory survives the hook lane's exit" \
  || bad "inherited GG_TMP survives pre-commit" "$S2/keep.txt is gone"

R2B="$(new_repo hooklane-msg)"
S2B="$(new_sentinel sentinel-hooklane-msg)"
printf 'feat: a message\n' >"$TMP/msg.txt"
RC=0
OUT="$(cd "$R2B" && GG_TMP="$S2B" "$SKILL_DIR/scripts/commit-msg" "$TMP/msg.txt" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "control: the commit-msg gate still passes with GG_TMP inherited" \
  || bad "commit-msg passes with GG_TMP inherited" "rc=$RC out=$OUT"
[ -f "$S2B/keep.txt" ] && ok "the inherited directory survives the commit-msg lane's exit" \
  || bad "inherited GG_TMP survives commit-msg" "$S2B/keep.txt is gone"

echo "=== an inherited ownership flag cannot make a child delete the settings cache ==="
R3="$(new_repo ownership)"
RC=0
OUT="$(cd "$R3" && GG_SETTINGS_INDEX_OWNED=1 "$PC" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "the chain completes with the ownership flag inherited" \
  || bad "chain completes with GG_SETTINGS_INDEX_OWNED inherited" "rc=$RC out=$OUT"
case "$OUT" in
  *"could not read the staged copy while resolving a setting"* | *"did not complete"*)
    bad "no check lost the settings cache" "out=$OUT" ;;
  *) ok "no check lost the settings cache mid-run" ;;
esac
RC=0
OUT="$(cd "$R3" && "$PC" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "control: the same chain passes with a clean environment" \
  || bad "control: clean-environment chain passes" "rc=$RC out=$OUT"

echo "=== the scratch directory a check DOES create is still removed ==="
R4="$(new_repo owncleanup)"
BEFORE="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'gg-todo-ban.*' 2>/dev/null | wc -l)"
RC=0
OUT="$(cd "$R4" && "$TB" 2>&1)" || RC=$?
AFTER="$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'gg-todo-ban.*' 2>/dev/null | wc -l)"
[ "$RC" -eq 0 ] && [ "$AFTER" -eq "$BEFORE" ] \
  && ok "a check leaves no scratch directory behind" \
  || bad "check cleans up its own scratch directory" "rc=$RC before=$BEFORE after=$AFTER"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
