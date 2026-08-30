#!/usr/bin/env bash
# Pins what tools/setup arms: the growth-guards installer writes both shims
# and nothing is spliced in beside them, a clone armed by the older setup has
# its call to the deleted tools/commit-msg taken back out, and then it commits
# through the armed hooks in both directions — the package's header, subject
# and changelog verdicts have to be reachable from a real commit, or the chain
# is wired to nothing. The refusing direction runs first in every pair.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TOOLS="$(cd "$TEST_DIR/.." && pwd)"
REPO="$(cd "$TOOLS/.." && pwd)"
# Enforcement in this repo rests on these keys, and an empty list is a
# documented rule-off — so a hardcoded copy here would stay green after a key
# stopped naming the trees this repo means.
REQUIRED_PATHS="$(sed -n 's/^GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS = "\(.*\)"$/\1/p' "$REPO/kendex.settings.toml")"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

PASS=0
FAIL=0
ok() { PASS=$((PASS + 1)); printf '  ok    %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL  %s\n        %s\n' "$1" "${2:-}"; }

[ -n "$REQUIRED_PATHS" ] \
  && ok "kendex.settings.toml names the paths that oblige a changelog entry" \
  || bad "kendex.settings.toml names the paths that oblige a changelog entry" "GROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS is empty"

new_fixture() { # NAME — a clone-shaped repo carrying the package and these tools
  R="$TMP/$1"
  mkdir -p "$R/.agents/skills/growth-guards" "$R/tools" "$R/crates"
  cp -R "$REPO/.agents/skills/growth-guards/scripts" "$R/.agents/skills/growth-guards/scripts"
  cp "$TOOLS/setup" "$R/tools/"
  printf '#!/usr/bin/env bash\necho "repo-local lane ran"\n' >"$R/tools/guard"
  chmod +x "$R/tools/guard"
  printf '[env]\nGROWTH_GUARDS_PRE_COMMIT_LOCAL = "tools/guard"\nGROWTH_GUARDS_CHANGELOG_REQUIRED_PATHS = "%s"\n' \
    "$REQUIRED_PATHS" >"$R/kendex.settings.toml"
  printf '# fixture\n' >"$R/README.md"
  git -C "$R" init -q
  git -C "$R" symbolic-ref HEAD refs/heads/main
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  HOOKS="$R/.git/hooks"
}

new_fixture repo
SENTINEL="# kendex-guards-hook"
# The line clones armed before the consolidation carry.
STALE_LANE='"$(git rev-parse --show-toplevel)/tools/commit-msg" "$@" || exit $?'

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
grep -qF "tools/commit-msg" "$HOOKS/commit-msg" \
  && bad "no repo-local lane is spliced in beside it" "$(cat "$HOOKS/commit-msg")" \
  || ok "no repo-local lane is spliced in beside it"

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

echo "=== the package judges the changelog this repo's paths oblige ==="
printf 'fn main() {}\n' >"$R/crates/a.rs"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "feat: a crate change" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"without a changelog entry"*) true ;; *) false ;; esac \
  && ok "a crates/ change with no changelog entry is refused by the package lane" \
  || bad "a crates/ change with no changelog entry is refused by the package lane" "rc=$RC out=$OUT"
mkdir -p "$R/changelog.d"
printf '# changelog.d\n' >"$R/changelog.d/README.md"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "feat: a crate change" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"without a changelog entry"*) true ;; *) false ;; esac \
  && ok "changelog.d's own README does not stand in for a fragment" \
  || bad "changelog.d's own README does not stand in for a fragment" "rc=$RC out=$OUT"
mkdir -p "$R/changelog.d/fixed"
printf -- '- A crate fix consumers see.\n' >"$R/changelog.d/fixed/ken-1.md"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "feat: a crate change" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "a changelog.d fragment satisfies the rule" \
  || bad "a changelog.d fragment satisfies the rule" "rc=$RC out=$OUT"
printf 'fn other() {}\n' >"$R/crates/b.rs"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "feat: a crate change [no-changelog]" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "[no-changelog] in the subject releases it" \
  || bad "[no-changelog] in the subject releases it" "rc=$RC out=$OUT"
printf 'fn third() {}\n' >"$R/crates/c.rs"
rm -f "$R/changelog.d/fixed/ken-1.md"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "feat: a crate change" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"without a changelog entry"*) true ;; *) false ;; esac \
  && ok "deleting a fragment is not writing one" \
  || bad "deleting a fragment is not writing one" "rc=$RC out=$OUT"
printf '# Changelog\n\n## [Unreleased]\n' >"$R/CHANGELOG.md"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "chore(release): the collated changelog" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"without a changelog entry"*) true ;; *) false ;; esac \
  && ok "the record alone is no entry while nothing declares a collation" \
  || bad "the record alone is no entry while nothing declares a collation" "rc=$RC out=$OUT"
RC=0
OUT="$(cd "$R" && GROWTH_GUARDS_CHANGELOG_COLLATE=1 git commit -m "chore(release): the collated changelog" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "CHANGELOG.md counts under the declaration, the way the release commit needs" \
  || bad "CHANGELOG.md counts under the declaration" "rc=$RC out=$OUT"
printf 'fn fourth() {}\n' >"$R/crates/d.rs"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "Merge branch 'topic' into main" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"without a changelog entry"*) true ;; *) false ;; esac \
  && ok "a Merge subject is exempt from shape and length, never from the changelog" \
  || bad "a Merge subject is exempt from shape and length, never from the changelog" "rc=$RC out=$OUT"
mkdir -p "$R/changelog.d/fixed"
printf -- '- A merged fix consumers see.\n' >"$R/changelog.d/fixed/ken-2.md"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "Merge branch 'topic' into main" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "control: the same Merge with a fragment passes" \
  || bad "control: the same Merge with a fragment passes" "rc=$RC out=$OUT"

echo "=== the documented release commit passes the gate it has to pass ==="
# The flow in docs/RELEASING.md, .pi/prompts/gh-release.md and the app-deploy
# skill: collate the fragments into the record, delete them, bump the version
# under crates/, stage exactly those paths, commit. The bump obliges an entry
# and the fragments are gone, so the record has to count — and it counts only
# under the declaration all three of those documents now carry.
git -C "$R" reset -q --hard HEAD
mkdir -p "$R/changelog.d/fixed" "$R/crates/app"
printf -- '- A fix consumers see.\n' >"$R/changelog.d/fixed/ken-9.md"
printf '{ "version": "1.0.0" }\n' >"$R/crates/app/tauri.conf.json"
printf '# Changelog\n\n## [Unreleased]\n' >"$R/CHANGELOG.md"
git -C "$R" add -A
git -C "$R" commit -qm "chore: a release to cut [no-changelog]"
# The collation, as the flow runs it: the entry moves into the record and the
# fragment is deleted.
rm -f "$R/changelog.d/fixed/ken-9.md"
printf '# Changelog\n\n## [Unreleased]\n\n## [1.0.1] - 2026-01-01\n\n### Fixed\n\n- A fix consumers see.\n' >"$R/CHANGELOG.md"
printf '{ "version": "1.0.1" }\n' >"$R/crates/app/tauri.conf.json"
git -C "$R" add -A -- CHANGELOG.md changelog.d crates/app/tauri.conf.json
RC=0
OUT="$(git -C "$R" commit -m "chore(release): v1.0.1" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"without a changelog entry"*) true ;; *) false ;; esac \
  && ok "control: without the declaration the release commit is refused" \
  || bad "control: without the declaration the release commit is refused" "rc=$RC out=$OUT"
RC=0
OUT="$(cd "$R" && GROWTH_GUARDS_CHANGELOG_COLLATE=1 git commit -m "chore(release): v1.0.1" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "the documented release commit, declaration and all, is accepted" \
  || bad "the documented release commit, declaration and all, is accepted" "rc=$RC out=$OUT"

echo "=== the package caps the subject; git's own subjects are exempt ==="
LONG="docs: $(printf 'x%.0s' $(seq 1 70))" # 76 characters
printf 'y\n' >>"$R/README.md"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "$LONG" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"header is 76 characters"*) true ;; *) false ;; esac \
  && ok "a 76-character subject is refused, naming the count" \
  || bad "a 76-character subject is refused, naming the count" "rc=$RC out=$OUT"
printf 'w\n' >>"$R/README.md"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "docs: $(printf 'x%.0s' $(seq 1 67))" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"header is 73 characters"*) true ;; *) false ;; esac \
  && ok "73 characters is one too many" \
  || bad "73 characters is one too many" "rc=$RC out=$OUT"
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
# -F keeps comment lines (cleanup=whitespace), so the header is not line 1.
# Reading the first physical line would measure the comment and pass.
printf '# a comment git keeps\n\n%s\n' "$LONG" >"$TMP/msg-with-comment"
printf 'c\n' >>"$R/README.md"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -F "$TMP/msg-with-comment" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"header is 76 characters"*) true ;; *) false ;; esac \
  && ok "the header is the first non-blank non-comment line, not line 1" \
  || bad "the header is the first non-blank non-comment line, not line 1" "rc=$RC out=$OUT"
printf 'f\n' >>"$R/README.md"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "fixup! $(printf 'x%.0s' $(seq 1 70))" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "a long fixup! subject passes — the exemption is the package's whole list" \
  || bad "a long fixup! subject passes — the exemption is the package's whole list" "rc=$RC out=$OUT"

echo "=== a clone armed by the older setup loses its call to the deleted lane ==="
new_fixture stale
(cd "$R" && ./tools/setup >/dev/null 2>&1)
# Put the retired line back where the older setup spliced it, plus a body of
# the consumer's own below it, written with no final newline.
awk -v sentinel="$SENTINEL" -v lane="$STALE_LANE" \
  '{ print } index($0, sentinel) && !placed { print lane; placed = 1 }' \
  "$HOOKS/commit-msg" >"$HOOKS/commit-msg.new"
printf 'echo "consumer hook ran"' >>"$HOOKS/commit-msg.new"
cat "$HOOKS/commit-msg.new" >"$HOOKS/commit-msg"
rm -f "$HOOKS/commit-msg.new"
grep -qxF "$STALE_LANE" "$HOOKS/commit-msg" \
  && ok "control: the fixture really carries the retired lane" \
  || bad "control: the fixture really carries the retired lane" "$(cat "$HOOKS/commit-msg")"
RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"dropped the retired tools/commit-msg lane"*) true ;; *) false ;; esac \
  && ok "setup says it dropped the retired lane" \
  || bad "setup says it dropped the retired lane" "rc=$RC out=$OUT"
grep -qF "tools/commit-msg" "$HOOKS/commit-msg" \
  && bad "the retired lane is gone" "$(cat "$HOOKS/commit-msg")" \
  || ok "the retired lane is gone"
[ "$(tail -1 "$HOOKS/commit-msg")" = 'echo "consumer hook ran"' ] \
  && ok "the consumer's own body is left alone" \
  || bad "the consumer's own body is left alone" "$(cat "$HOOKS/commit-msg")"
[ -n "$(tail -c 1 "$HOOKS/commit-msg")" ] \
  && ok "the missing final newline is preserved" \
  || bad "the missing final newline is preserved" "the rewrite added one"
git -C "$R" add -A
RC=0
OUT="$(git -C "$R" commit -m "chore: fixture" 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"consumer hook ran"*) true ;; *) false ;; esac \
  && ok "the repaired hook commits, and still hands back to the consumer's body" \
  || bad "the repaired hook commits, and still hands back to the consumer's body" "rc=$RC out=$OUT"
RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"dropped the retired"*) false ;; *) true ;; esac \
  && ok "a hook that never had the lane is not rewritten" \
  || bad "a hook that never had the lane is not rewritten" "rc=$RC out=$OUT"

[ -x "$HOOKS/commit-msg" ] \
  && ok "the repaired hook keeps the execute bit git needs" \
  || bad "the repaired hook keeps the execute bit git needs" "$(ls -l "$HOOKS/commit-msg")"
# A probe the repair cannot complete must stop the run, not report the clone
# armed while the hook still calls a script that is gone. grep spends 1 on
# "not found" and 2 on "could not read it"; a shim ahead of PATH is what
# separates the two branches, since the installer that runs first would refuse
# a hook the filesystem really had made unreadable.
awk -v sentinel="$SENTINEL" -v lane="$STALE_LANE" \
  '{ print } index($0, sentinel) && !placed { print lane; placed = 1 }' \
  "$HOOKS/commit-msg" >"$HOOKS/commit-msg.new"
cat "$HOOKS/commit-msg.new" >"$HOOKS/commit-msg"
rm -f "$HOOKS/commit-msg.new"
GREP_SHIM="$TMP/grep-shim"
mkdir -p "$GREP_SHIM"
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "${1:-}" = "-Fxq" ]; then\n'
  printf '  echo "grep: simulated read failure" >&2\n'
  printf '  exit 2\n'
  printf 'fi\n'
  printf 'exec %s "$@"\n' "$(command -v grep)"
} >"$GREP_SHIM/grep"
chmod +x "$GREP_SHIM/grep"
RC=0
OUT="$(cd "$R" && PATH="$GREP_SHIM:$PATH" ./tools/setup 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"hooks armed"*) false ;; *"grep exit 2"*) true ;; *) false ;; esac \
  && ok "a probe that could not run stops setup instead of reporting the clone armed" \
  || bad "a probe that could not run stops setup" "rc=$RC out=$OUT"
grep -qxF "$STALE_LANE" "$HOOKS/commit-msg" \
  && ok "control: that hook really did still carry the retired lane" \
  || bad "control: that hook really did still carry the retired lane" "$(cat "$HOOKS/commit-msg")"
# The next probe down the same repair, and the same rule: tail spends its
# status on whether it could READ the hook, and a discarded status would make
# an unreadable hook look like one ending in a newline. The lane is still in
# the hook here, so the run reaches tail at all.
TAIL_SHIM="$TMP/tail-shim"
mkdir -p "$TAIL_SHIM"
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "${1:-}" = "-c" ]; then\n'
  printf '  echo "tail: simulated read failure" >&2\n'
  printf '  exit 1\n'
  printf 'fi\n'
  printf 'exec %s "$@"\n' "$(command -v tail)"
} >"$TAIL_SHIM/tail"
chmod +x "$TAIL_SHIM/tail"
RC=0
OUT="$(cd "$R" && PATH="$TAIL_SHIM:$PATH" ./tools/setup 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"hooks armed"*) false ;; *"tail exit 1"*) true ;; *) false ;; esac \
  && ok "a final-byte probe that could not run stops setup too" \
  || bad "a final-byte probe that could not run stops setup too" "rc=$RC out=$OUT"
grep -qxF "$STALE_LANE" "$HOOKS/commit-msg" \
  && ok "control: that hook is unchanged, retired lane and all" \
  || bad "control: that hook is unchanged, retired lane and all" "$(cat "$HOOKS/commit-msg")"

# The hooks path itself is a probe. Failed, it hands back an empty string,
# `/hooks/commit-msg` is a file no clone has, and the repair would find
# nothing to do and report the clone armed. The shim fails only the bare
# `rev-parse --git-common-dir` this script runs: every call the installer
# makes carries -C, so the verdict it gives first is its own.
GIT_SHIM="$TMP/git-shim"
mkdir -p "$GIT_SHIM"
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [ "${1:-}" = "rev-parse" ] && [ "${2:-}" = "--git-common-dir" ]; then\n'
  printf '  echo "git: simulated failure" >&2\n'
  printf '  exit 128\n'
  printf 'fi\n'
  printf 'exec %s "$@"\n' "$(command -v git)"
} >"$GIT_SHIM/git"
chmod +x "$GIT_SHIM/git"
RC=0
OUT="$(cd "$R" && PATH="$GIT_SHIM:$PATH" ./tools/setup 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"hooks armed"*) false ;; *"could not locate the shared .git directory"*) true ;; *) false ;; esac \
  && ok "a hooks path that could not be resolved stops setup" \
  || bad "a hooks path that could not be resolved stops setup" "rc=$RC out=$OUT"
grep -qxF "$STALE_LANE" "$HOOKS/commit-msg" \
  && ok "control: that hook is unchanged there too" \
  || bad "control: that hook is unchanged there too" "$(cat "$HOOKS/commit-msg")"

RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && ok "with a working probe the same hook is repaired" \
  || bad "with a working probe the same hook is repaired" "rc=$RC out=$OUT"

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
[ "$RC" -eq 0 ] && grep -qF "$SENTINEL" "$HOOKS/commit-msg" \
  && ok "deleting both arms the clone" \
  || bad "deleting both arms the clone" "rc=$RC out=$OUT"

echo "=== setup never claims armed where git reads hooks elsewhere ==="
E="$TMP/elsewhere"
mkdir -p "$E/tools" "$E/other-hooks" "$E/.agents/skills"
cp -R "$R/.agents/skills/growth-guards" "$E/.agents/skills/growth-guards"
cp "$TOOLS/setup" "$E/tools/"
git -C "$E" init -q
git -C "$E" config core.hooksPath "$E/other-hooks"
# A leftover file at the path the installer writes, which git no longer reads,
# carrying the retired lane.
mkdir -p "$E/.git/hooks"
printf '#!/bin/sh\n%s\n' "$STALE_LANE" >"$E/.git/hooks/commit-msg"
RC=0
OUT="$(cd "$E" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"not armed"*) true ;; *) false ;; esac \
  && ok "a configured hooks path stops setup instead of wiring a hook git ignores" \
  || bad "a configured hooks path stops setup instead of wiring a hook git ignores" "rc=$RC out=$OUT"
grep -qxF "$STALE_LANE" "$E/.git/hooks/commit-msg" \
  && ok "the stale hook is left alone — the repair runs only past the installer's verdict" \
  || bad "the stale hook is left alone" "$(cat "$E/.git/hooks/commit-msg")"

echo "=== setup outside a work tree says so, rather than working somewhere else ==="
# The first probe of all. Unread, its empty answer is a change of directory
# that stays put, and the run would go on to blame the installer for a
# verdict it never reached.
NOREPO="$TMP/no-repo"
mkdir -p "$NOREPO"
RC=0
OUT="$(cd "$NOREPO" && "$R/tools/setup" 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"hooks armed"*) false ;; *"not inside a git work tree"*) true ;; *) false ;; esac \
  && ok "setup run outside a work tree names that, not the installer" \
  || bad "setup run outside a work tree names that, not the installer" "rc=$RC out=$OUT"

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
