#!/usr/bin/env bash
# Pins for the pre-commit chain's lane resolution and announcements: sibling
# gates resolve from the COMMITTING work tree before the install the shim
# execs (linked worktrees share one hooks directory, so that install can live
# in another checkout whose branch state says nothing about this commit), a
# genuine double absence is a stated skip naming both probed sides, and the
# repo-local lane announces itself even when nothing is configured. Every
# firing pin is paired with the control that proves the fixture, not the
# chain, would otherwise pass.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
TMP="$(mktemp -d "${TMPDIR:-/tmp}/gg-pre-commit-chain.XXXXXX")"
trap 'rm -rf -- "$TMP"' EXIT

unset GROWTH_GUARDS_CHECKS GROWTH_GUARDS_PRE_COMMIT_LOCAL \
  GROWTH_GUARDS_SETTINGS_FILE GG_TMP GG_SETTINGS_INDEX_OWNED \
  GG_SETTINGS_INDEX_DIR GG_SETTINGS_FROM_INDEX 2>/dev/null || true
# Neutralize the caller's git configuration: global hooks, templates or
# signing would decide these results instead of the chain.
export HOME="$TMP/home" XDG_CONFIG_HOME="$TMP/xdg" GIT_CONFIG_NOSYSTEM=1
mkdir -p "$HOME" "$XDG_CONFIG_HOME"

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

# The chain as a linked worktree runs it: the shim execs a growth-guards
# install in ANOTHER checkout, so SCRIPT_DIR sits outside the committing work
# tree and install-relative siblings are that checkout's, not this one's.
# This install carries NO siblings at all.
BARE_INSTALL="$TMP/other-checkout/skills"
mkdir -p "$BARE_INSTALL"
cp -R "$SKILL_DIR" "$BARE_INSTALL/growth-guards"
PC="$BARE_INSTALL/growth-guards/scripts/pre-commit"

# A second shared install that DOES carry both siblings, for the fallback and
# precedence pins.
FULL_INSTALL="$TMP/other-checkout-full/skills"
mkdir -p "$FULL_INSTALL"
cp -R "$SKILL_DIR" "$FULL_INSTALL/growth-guards"
PC_FULL="$FULL_INSTALL/growth-guards/scripts/pre-commit"

fake_skill() { # ROOT NAME MARKER RC — a gate that proves which copy ran
  local d="$1/$2"
  mkdir -p "$d/scripts"
  printf '#!/bin/sh\necho "%s"\nexit %s\n' "$3" "$4" >"$d/scripts/$2"
  chmod +x "$d/scripts/$2"
}
fake_skill "$FULL_INSTALL" size-ratchet "install size-ratchet ran" 0
fake_skill "$FULL_INSTALL" preflight "install preflight ran" 0

new_repo() { # NAME -> repo path on stdout; seeded, with one file staged
  local r="$TMP/$1"
  mkdir -p "$r"
  git -C "$r" -c init.defaultBranch=main init -q
  git -C "$r" config user.email test@example.com
  git -C "$r" config user.name test
  printf 'hello\n' >"$r/a.txt"
  git -C "$r" add a.txt
  git -C "$r" commit -qm 'feat: seed'
  printf 'more\n' >"$r/b.txt"
  git -C "$r" add b.txt
  printf '%s' "$r"
}

echo "=== the committing work tree's sibling gates outrank an install that has none ==="
R1="$(new_repo tree-wins)"
fake_skill "$R1/.agents/skills" size-ratchet "worktree size-ratchet ran" 0
fake_skill "$R1/.agents/skills" preflight "worktree preflight ran" 0
RC=0
OUT="$(cd "$R1" && "$PC" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "control: the chain passes on the tree's own gates" \
  || bad "chain passes on tree-carried gates" "rc=$RC out=$OUT"
case "$OUT" in
  *"worktree size-ratchet ran"*) ok "the tree's size-ratchet is the one that ran" ;;
  *) bad "tree size-ratchet ran" "out=$OUT" ;;
esac
case "$OUT" in
  *"worktree preflight ran"*) ok "the tree's preflight is the one that ran" ;;
  *) bad "tree preflight ran" "out=$OUT" ;;
esac
case "$OUT" in
  *"size-ratchet not installed"* | *"preflight not installed"*)
    bad "no lane reports the gates as absent" "out=$OUT" ;;
  *) ok "no lane reports the gates as absent" ;;
esac

echo "=== a failing tree-carried gate blocks even when the install has no sibling ==="
R2="$(new_repo tree-gates)"
fake_skill "$R2/.agents/skills" size-ratchet "size-ratchet: staged violation" 1
RC=0
OUT="$(cd "$R2" && "$PC" 2>&1)" || RC=$?
[ "$RC" -eq 1 ] && ok "the tree's size-ratchet verdict blocks (exit 1)" \
  || bad "tree size-ratchet verdict blocks" "rc=$RC out=$OUT"
case "$OUT" in
  *"size-ratchet: staged violation"*) ok "the gate's own output reaches the committer" ;;
  *) bad "gate output reaches the committer" "out=$OUT" ;;
esac

echo "=== the tree's copy outranks the install's copy (re-vendor gating) ==="
R3="$(new_repo tree-over-install)"
fake_skill "$R3/.agents/skills" size-ratchet "worktree size-ratchet ran" 0
RC=0
OUT="$(cd "$R3" && "$PC_FULL" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "control: the chain passes" || bad "precedence chain passes" "rc=$RC out=$OUT"
case "$OUT" in
  *"worktree size-ratchet ran"*) ok "the tree's size-ratchet wins" ;;
  *) bad "tree size-ratchet wins" "out=$OUT" ;;
esac
case "$OUT" in
  *"install size-ratchet ran"*) bad "the install's size-ratchet must not also run" "out=$OUT" ;;
  *) ok "the install's size-ratchet did not run" ;;
esac
case "$OUT" in
  *"install preflight ran"*) ok "a sibling the tree lacks still comes from the install" ;;
  *) bad "install preflight fallback" "out=$OUT" ;;
esac

echo "=== a tree carrying no siblings still gets the install's gates ==="
R4="$(new_repo install-fallback)"
RC=0
OUT="$(cd "$R4" && "$PC_FULL" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "control: the chain passes on the install's gates" \
  || bad "chain passes on install gates" "rc=$RC out=$OUT"
case "$OUT" in
  *"install size-ratchet ran"*) ok "the install's size-ratchet ran" ;;
  *) bad "install size-ratchet ran" "out=$OUT" ;;
esac
case "$OUT" in
  *"install preflight ran"*) ok "the install's preflight ran" ;;
  *) bad "install preflight ran" "out=$OUT" ;;
esac

echo "=== genuine absence on both sides is a stated skip naming both probes ==="
R5="$(new_repo double-absence)"
RC=0
OUT="$(cd "$R5" && "$PC" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "an absent gate skill stays a pass (exit 0)" \
  || bad "absent gates stay exit 0" "rc=$RC out=$OUT"
case "$OUT" in
  *"size-ratchet not installed — skipped (no size-ratchet skill under "*)
    ok "the size-ratchet skip names the work-tree probe" ;;
  *) bad "size-ratchet skip names the tree probe" "out=$OUT" ;;
esac
case "$OUT" in
  *"(.agents/skills .claude/skills .cursor/rules .opencode/skills skills)"*)
    ok "the skip names every probed skills root" ;;
  *) bad "skip names the probed roots" "out=$OUT" ;;
esac
case "$OUT" in
  *"nor at $BARE_INSTALL/growth-guards/scripts/../../size-ratchet)"*)
    ok "the size-ratchet skip names the install probe" ;;
  *) bad "size-ratchet skip names the install probe" "out=$OUT" ;;
esac
case "$OUT" in
  *"preflight not installed — skipped (no preflight skill under "*)
    ok "the preflight skip names the work-tree probe" ;;
  *) bad "preflight skip names the tree probe" "out=$OUT" ;;
esac
case "$OUT" in
  *"nor at $BARE_INSTALL/growth-guards/scripts/../../preflight)"*)
    ok "the preflight skip names the install probe" ;;
  *) bad "preflight skip names the install probe" "out=$OUT" ;;
esac

echo "=== a tree-carried skill without a runnable script blocks, never skips ==="
R6="$(new_repo broken-tree-sibling)"
mkdir -p "$R6/.agents/skills/size-ratchet/scripts"
RC=0
OUT="$(cd "$R6" && "$PC" 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && ok "a present-but-broken tree sibling exits 2 (could not complete)" \
  || bad "broken tree sibling exits 2" "rc=$RC out=$OUT"
case "$OUT" in
  *"size-ratchet skill is installed at"*) ok "the broken install is named" ;;
  *) bad "broken install is named" "out=$OUT" ;;
esac

echo "=== the repo-local lane announces itself even with nothing configured ==="
R7="$(new_repo local-unconfigured)"
RC=0
OUT="$(cd "$R7" && "$PC" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "an unconfigured repo-local lane stays a pass (exit 0)" \
  || bad "unconfigured local lane exits 0" "rc=$RC out=$OUT"
case "$OUT" in
  *"=== pre-commit: repo-local entry: none configured"*)
    ok "the lane states that none is configured" ;;
  *) bad "none-configured line printed" "out=$OUT" ;;
esac

echo "=== a configured repo-local entry still runs, announces, and suppresses the none line ==="
R8="$(new_repo local-configured)"
mkdir -p "$R8/tools"
printf '#!/bin/sh\necho "repo-local check ran"\nexit 0\n' >"$R8/tools/local-check"
chmod +x "$R8/tools/local-check"
RC=0
OUT="$(cd "$R8" && GROWTH_GUARDS_PRE_COMMIT_LOCAL=tools/local-check "$PC" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "control: a passing entry keeps the chain green" \
  || bad "configured local entry passes" "rc=$RC out=$OUT"
case "$OUT" in
  *"=== pre-commit: repo-local: tools/local-check"*) ok "the configured lane announces its entry" ;;
  *) bad "configured lane announces" "out=$OUT" ;;
esac
case "$OUT" in
  *"repo-local check ran"*) ok "the entry actually ran" ;;
  *) bad "configured entry ran" "out=$OUT" ;;
esac
case "$OUT" in
  *"repo-local entry: none configured"*)
    bad "the none-configured line must not appear beside a configured entry" "out=$OUT" ;;
  *) ok "the none-configured line stays out of the configured lane" ;;
esac

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
