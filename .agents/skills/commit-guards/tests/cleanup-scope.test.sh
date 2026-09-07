#!/usr/bin/env bash
# Pins for the family's EXIT cleanup: it removes only what THIS process
# created. An inherited GG_TMP or ownership flag must never decide what a
# guard deletes, and a check a hook lane runs must not remove the settings
# cache its parent is still reading. One table: a lane runs in a fresh
# repository under ENVS, and the row pins the exit status, the lane's last
# line (a chain that lost its cache mid-run ends otherwise), whether the
# sentinel directory an inherited GG_TMP names survived, and how many
# scratch directories the run left in the root this suite owns.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"

# The chain runs from an install that carries no sibling skills: this suite
# pins cleanup state, and a sibling resolved from the source tree beside
# this package would judge the fixture repositories on its own terms.
BARE_INSTALL="$TMP/install/skills"
mkdir -p "$BARE_INSTALL"
cp -R "$SKILL_DIR" "$BARE_INSTALL/commit-guards"
SCRIPTS="$BARE_INSTALL/commit-guards/scripts"
unset COMMIT_GUARDS_CHECKS COMMIT_GUARDS_SETTINGS_FILE GG_TMP \
  GG_SETTINGS_INDEX_OWNED GG_SETTINGS_INDEX_DIR GG_SETTINGS_FROM_INDEX 2>/dev/null || true

PASS=0
FAIL=0
assert_eq() { # LABEL EXPECT ACTUAL
  if [ "$2" = "$3" ]; then
    PASS=$((PASS + 1))
    printf '  ok    %s\n' "$1"
  else
    FAIL=$((FAIL + 1))
    printf '  FAIL  %s\n        want: %s\n        got:  %s\n' "$1" "$2" "$3"
  fi
}

# A repository with a TRACKED settings source, so the hook lane materializes
# an index copy into the cache the children inherit.
R=""
repo() { # NAME
  R="$TMP/$1"
  [ ! -e "$R" ] || { echo "harness: fixture $1 already exists" >&2; exit 2; }
  mkdir -p "$R"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  printf '[]\n' >"$R/.kendex-generated.json"
  printf 'fn main() {}\n' >"$R/ok.rs"
  printf '[env]\nCOMMIT_GUARDS_BYTE_CEILING_KB = "200"\n' >"$R/kendex.settings.toml"
  git -C "$R" add -A
}
# The sentinel a correct cleanup never touches: an inherited GG_TMP naming it
# would be rm -rf'd by a guard's own EXIT trap. One per row.
S=""
sentinel() { # NAME
  S="$TMP/$1"
  mkdir -p "$S"
  printf 'precious\n' >"$S/keep.txt"
}
kept() { if [ -f "$S/keep.txt" ]; then echo kept; else echo gone; fi; }
# Counted inside the scratch root the harness owns and points TMPDIR at, so
# the number answers for this run alone and no concurrent run moves it.
scratch() { # — the gg-*.* scratch directories left in the owned root
  local n=0 d
  for d in "$TMPDIR"/gg-*.*; do
    if [ -d "$d" ]; then n=$((n + 1)); fi
  done
  printf '%s' "$n"
}
printf 'feat: a message\n' >"$TMP/msg.txt"
# One line for a run: the lane's exit status and last line, the sentinel's
# fate, the scratch directories the run added to the owned root. ENVS is a
# comma-separated list of assignments; a value `S` names the row's sentinel
# directory and `F` the file inside it.
run() { # LANE ENVS
  local envs=() rc=0 out="" e before
  if [ -n "$2" ]; then
    IFS=',' read -ra envs <<<"$2"
    for e in "${!envs[@]}"; do
      case "${envs[$e]}" in
        *=S) envs[$e]="${envs[$e]%=S}=$S" ;;
        *=F) envs[$e]="${envs[$e]%=F}=$S/keep.txt" ;;
      esac
    done
  fi
  before="$(scratch)"
  case "$1" in
    commit-msg) out="$(cd "$R" && env ${envs[@]+"${envs[@]}"} "$SCRIPTS/commit-msg" "$TMP/msg.txt" 2>&1)" || rc=$? ;;
    *) out="$(cd "$R" && env ${envs[@]+"${envs[@]}"} "$SCRIPTS/$1" 2>&1)" || rc=$? ;;
  esac
  printf 'rc=%s last=%s sentinel=%s scratch=%s' "$rc" "$(printf '%s\n' "$out" | tail -n 1)" "$(kept)" "$(( $(scratch) - before ))"
}
ROW=0
run_rows() { # label | lane | envs | expect
  local row label lane envs expect
  for row in "$@"; do
    IFS='|' read -r label lane envs expect <<<"$row"
    ROW=$((ROW + 1))
    repo "repo-$ROW"
    sentinel "sentinel-$ROW"
    assert_eq "$label" "$expect" "$(run "$lane" "$envs")"
  done
}

echo "=== premise: the scratch count sees a directory in the owned root ==="
mkdir -p "$TMPDIR/gg-todo-ban.decoy"
assert_eq "control: a decoy scratch directory is counted" "1" "$(scratch)"
rmdir "$TMPDIR/gg-todo-ban.decoy"
assert_eq "control: the root is empty before any row" "0" "$(scratch)"

echo "=== a check or a lane never deletes an inherited GG_TMP, an inherited ownership flag never deletes the settings cache, and a check's own scratch is removed ==="
CHAIN="pre-commit: OK — staged guard chain clean"
run_rows \
  "standalone: a check with GG_TMP inherited passes, leaves the inherited directory and its own scratch removed|todo-ban|GG_TMP=S|rc=0 last=todo-ban: OK — no work markers in tracked files sentinel=kept scratch=0" \
  "install: a check with GG_INSTALL_TMP inherited leaves the inherited file|todo-ban|GG_INSTALL_TMP=F|rc=0 last=todo-ban: OK — no work markers in tracked files sentinel=kept scratch=0" \
  "hooklane: the pre-commit chain with GG_TMP inherited passes and leaves it|pre-commit|GG_TMP=S|rc=0 last=$CHAIN sentinel=kept scratch=0" \
  "msglane: the commit-msg gate with GG_TMP inherited passes and leaves it|commit-msg|GG_TMP=S|rc=0 last=commit-msg: OK — conventional header: feat: a message sentinel=kept scratch=0" \
  "ownership: the chain completes with the ownership flag inherited, no check losing the cache mid-run|pre-commit|GG_SETTINGS_INDEX_OWNED=1|rc=0 last=$CHAIN sentinel=kept scratch=0" \
  "cachedir: the chain with GG_SETTINGS_INDEX_DIR inherited makes its own cache and leaves the inherited one|pre-commit|GG_SETTINGS_INDEX_DIR=S|rc=0 last=$CHAIN sentinel=kept scratch=0" \
  "control: the same chain in a clean environment|pre-commit||rc=0 last=$CHAIN sentinel=kept scratch=0"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
