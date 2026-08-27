#!/usr/bin/env bash
# Pins what tools/setup arms: the growth-guards installer writes both shims,
# and this repo's own commit-msg rule is spliced in below the line the
# installer writes, once, above whatever else the hook runs. Then it commits
# through the armed hooks in both directions — the package's
# conventional-header verdict and this repo's changelog verdict have to be
# reachable from a real commit, or the chain is wired to nothing. The
# refusing direction runs first in every pair.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$(cd "$TEST_DIR/.." && pwd)"
REPO="$(cd "$TOOLS/.." && pwd)"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

new_fixture() { # NAME — a clone-shaped repo carrying the package and these tools
  R="$TMP/$1"
  mkdir -p "$R/.agents/skills/growth-guards" "$R/tools" "$R/crates"
  cp -R "$REPO/.agents/skills/growth-guards/scripts" "$R/.agents/skills/growth-guards/scripts"
  cp "$TOOLS/setup" "$TOOLS/commit-msg" "$R/tools/"
  printf '#!/usr/bin/env bash\necho "repo-local lane ran"\n' >"$R/tools/guard"
  chmod +x "$R/tools/guard"
  printf '[env]\nGROWTH_GUARDS_PRE_COMMIT_LOCAL = "tools/guard"\n' >"$R/kendex.settings.toml"
  printf '# fixture\n' >"$R/README.md"
  git -C "$R" init -q
  git -C "$R" symbolic-ref HEAD refs/heads/main
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  HOOKS="$R/.git/hooks"
}

new_fixture repo
SENTINEL="# kendex-guards-hook"
LANE='exec "$(git rev-parse --show-toplevel)/tools/commit-msg" "$@"'

echo "=== a fresh clone is not armed until setup runs ==="
{ [ ! -e "$HOOKS/pre-commit" ] && [ ! -e "$HOOKS/commit-msg" ]; } \
  && ok "neither shim exists before setup" \
  || bad "neither shim exists before setup" "$(ls -1 "$HOOKS" 2>&1)"

RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "setup exits clean" || bad "setup exits clean" "rc=$RC out=$OUT"
{ [ -x "$HOOKS/pre-commit" ] && grep -qF "$SENTINEL" "$HOOKS/pre-commit"; } \
  && ok "pre-commit carries the installer's line and is executable" \
  || bad "pre-commit carries the installer's line and is executable" "$(cat "$HOOKS/pre-commit" 2>&1)"
{ [ -x "$HOOKS/commit-msg" ] && grep -qF "$SENTINEL" "$HOOKS/commit-msg"; } \
  && ok "commit-msg carries the installer's line and is executable" \
  || bad "commit-msg carries the installer's line and is executable" "$(cat "$HOOKS/commit-msg" 2>&1)"
grep -qxF "$LANE" "$HOOKS/commit-msg" \
  && ok "the repo's commit-msg lane is wired below it" \
  || bad "the repo's commit-msg lane is wired below it" "$(cat "$HOOKS/commit-msg" 2>&1)"

echo "=== re-running setup repairs, it does not stack ==="
(cd "$R" && ./tools/setup >/dev/null 2>&1)
(cd "$R" && ./tools/setup >/dev/null 2>&1)
LANES="$(grep -cxF "$LANE" "$HOOKS/commit-msg" || true)"
[ "$LANES" = "1" ] && ok "three runs leave one repo lane" \
  || bad "three runs leave one repo lane" "count=$LANES"

echo "=== the chain runs at commit time, local lane last ==="
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "chore: fixture" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"repo-local lane ran"*) true ;; *) false ;; esac \
  && ok "the first commit passes and reaches tools/guard last" \
  || bad "the first commit passes and reaches tools/guard last" "rc=$RC out=$OUT"

echo "=== the package judges the header ==="
printf 'x\n' >>"$R/README.md"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "not conventional at all" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"non-conventional header"*) true ;; *) false ;; esac \
  && ok "a non-conventional subject is refused by the package's check" \
  || bad "a non-conventional subject is refused by the package's check" "rc=$RC out=$OUT"
RC=0
OUT="$(git -C "$R" commit -m "docs: a conventional subject" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "a conventional subject passes" \
  || bad "a conventional subject passes" "rc=$RC out=$OUT"

echo "=== this repo judges the changelog ==="
printf 'fn main() {}\n' >"$R/crates/a.rs"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "feat: a crate change" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"without a CHANGELOG.md entry"*) true ;; *) false ;; esac \
  && ok "a crates/ change with no changelog entry is refused by the repo lane" \
  || bad "a crates/ change with no changelog entry is refused by the repo lane" "rc=$RC out=$OUT"
RC=0
OUT="$(git -C "$R" commit -m "feat: a crate change [no-changelog]" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "[no-changelog] in the subject releases it" \
  || bad "[no-changelog] in the subject releases it" "rc=$RC out=$OUT"

echo "=== this repo caps the subject; git's own subjects are exempt ==="
LONG="docs: $(printf 'x%.0s' $(seq 1 70))" # 76 characters
printf 'y\n' >>"$R/README.md"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "$LONG" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"subject is 76 characters"*) true ;; *) false ;; esac \
  && ok "a 76-character subject is refused, naming the count" \
  || bad "a 76-character subject is refused, naming the count" "rc=$RC out=$OUT"
printf 'm\n' >>"$R/README.md"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "Merge $(printf 'x%.0s' $(seq 1 70))" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "a long Merge subject passes — git wrote it, nobody sized it" \
  || bad "a long Merge subject passes — git wrote it, nobody sized it" "rc=$RC out=$OUT"
printf 'z\n' >>"$R/README.md"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "docs: $(printf 'x%.0s' $(seq 1 66))" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "a 72-character subject passes" \
  || bad "a 72-character subject passes" "rc=$RC out=$OUT"

echo "=== the lane goes above the hook's own body, not after it ==="
new_fixture own-hook
# A consumer hook that returns early. Appended below it, the repo lane would
# never run. Written with no final newline, which the splice must preserve.
printf '#!/bin/sh\necho "consumer hook ran"\nexit 0' >"$HOOKS/commit-msg"
chmod +x "$HOOKS/commit-msg"
RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "setup arms a repo that already had its own commit-msg hook" \
  || bad "setup arms a repo that already had its own commit-msg hook" "rc=$RC out=$OUT"
SENT_AT="$(grep -n -F -- "$SENTINEL" "$HOOKS/commit-msg" | head -1 | cut -d: -f1)"
[ -n "$SENT_AT" ] && [ "$(sed -n "$((SENT_AT + 1))p" "$HOOKS/commit-msg")" = "$LANE" ] \
  && ok "the repo lane is the line right after the delegate" \
  || bad "the repo lane is the line right after the delegate" "$(cat "$HOOKS/commit-msg")"
[ "$(tail -1 "$HOOKS/commit-msg")" = "exit 0" ] \
  && ok "the consumer's body is still last" \
  || bad "the consumer's body is still last" "$(cat "$HOOKS/commit-msg")"
[ -n "$(tail -c 1 "$HOOKS/commit-msg")" ] \
  && ok "the missing final newline is preserved" \
  || bad "the missing final newline is preserved" "the splice added one"
printf 'fn main() {}\n' >"$R/crates/a.rs"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "feat: a crate change" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"without a CHANGELOG.md entry"*) true ;; *) false ;; esac \
  && ok "the changelog rule still runs, though the hook body exits before the end" \
  || bad "the changelog rule still runs, though the hook body exits before the end" "rc=$RC out=$OUT"

echo "=== a clone armed by the old setup names both hooks to delete ==="
new_fixture legacy
for pair in pre-commit:guard commit-msg:commit-msg; do
  printf '#!/usr/bin/env bash\nexec "$(git rev-parse --show-toplevel)/tools/%s" "$@"\n' \
    "${pair##*:}" >"$HOOKS/${pair%%:*}"
  chmod +x "$HOOKS/${pair%%:*}"
done
RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -ne 0 ] \
  && case "$OUT" in *".git/hooks/pre-commit AND .git/hooks/commit-msg"*) true ;; *) false ;; esac \
  && ok "setup stops and names both legacy hooks, not just pre-commit" \
  || bad "setup stops and names both legacy hooks, not just pre-commit" "rc=$RC out=$OUT"
rm -f "$HOOKS/pre-commit"
RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && ok "deleting pre-commit alone is not enough" \
  || bad "deleting pre-commit alone is not enough" "rc=$RC out=$OUT"
rm -f "$HOOKS/commit-msg"
RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && grep -qxF "$LANE" "$HOOKS/commit-msg" \
  && ok "deleting both arms the clone" \
  || bad "deleting both arms the clone" "rc=$RC out=$OUT"

echo "=== setup never claims armed where git reads hooks elsewhere ==="
E="$TMP/elsewhere"
mkdir -p "$E/tools" "$E/other-hooks" "$E/.agents/skills"
cp -R "$R/.agents/skills/growth-guards" "$E/.agents/skills/growth-guards"
cp "$TOOLS/setup" "$TOOLS/commit-msg" "$E/tools/"
git -C "$E" init -q
git -C "$E" config core.hooksPath "$E/other-hooks"
# A leftover file at the path the installer writes, which git no longer reads.
mkdir -p "$E/.git/hooks"
printf '#!/bin/sh\n' >"$E/.git/hooks/commit-msg"
RC=0
OUT="$(cd "$E" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"not armed"*) true ;; *) false ;; esac \
  && ok "a configured hooks path stops setup instead of wiring a hook git ignores" \
  || bad "a configured hooks path stops setup instead of wiring a hook git ignores" "rc=$RC out=$OUT"
grep -qxF "$LANE" "$E/.git/hooks/commit-msg" \
  && bad "the stale hook is left alone" "$(cat "$E/.git/hooks/commit-msg")" \
  || ok "the stale hook is left alone"

echo "=== the repo lane fails closed when it cannot read the message ==="
RC=0
OUT="$(cd "$R" && ./tools/commit-msg 2>&1)" || RC=$?
[ "$RC" -eq 2 ] && case "$OUT" in *"no readable message file"*) true ;; *) false ;; esac \
  && ok "no message file is exit 2, not a pass" \
  || bad "no message file is exit 2, not a pass" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
