#!/usr/bin/env bash
# Pins what tools/setup arms: the growth-guards installer writes both shims,
# nothing is spliced in beside them, and the clone then commits through the
# armed hooks in both directions — the package's header, subject and changelog
# verdicts have to be reachable from a real commit, or the chain is wired to
# nothing. The refusing direction runs first in every pair.
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

echo "=== hooks the installer will not vouch for are each named ==="
# It refuses an interpreter it cannot verify rather than rewriting somebody
# else's hook. setup's remedy points back at that report rather than naming a
# cause of its own, so the report has to name every hook in the way and why —
# the first one it tripped over is not the whole answer.
new_fixture foreign
for hook in pre-commit commit-msg; do
  printf '#!/usr/bin/env bash\necho "%s ran"\n' "$hook" >"$HOOKS/$hook"
  chmod +x "$HOOKS/$hook"
done
RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && ok "setup stops instead of reporting the clone armed" \
  || bad "setup stops instead of reporting the clone armed" "rc=$RC out=$OUT"
# Cause and remedy are asserted apart: the remedy prints for every refusal, so
# matching it alone would pass on a message naming the wrong cause.
for hook in pre-commit commit-msg; do
  case "$OUT" in
    *"hooks/$hook runs under an interpreter that cannot be verified"*)
      ok "the report names $hook and why it was refused" ;;
    *) bad "the report names $hook and why it was refused" "out=$OUT" ;;
  esac
done

echo "=== following the printed remedy through arms the clone ==="
# The remedy is keyed on what a hook still HOLDS, not on who wrote it, and
# only walking it end to end proves that: --uninstall reports success over a
# hook this installer created that carries a lane of the consumer's, and
# leaves the file exactly where it was. A message keyed on authorship stops
# there and sends the operator round the same refusal with nothing to try.
new_fixture remedy
(cd "$R" && ./tools/setup >/dev/null 2>&1)
# The shipped case: a hook this installer wrote, its shebang swapped for one
# the installer will not vouch for, with a lane of the consumer's below it.
{
  printf '#!/usr/bin/env bash\n'
  tail -n +2 "$HOOKS/commit-msg"
  printf 'echo "my own lane"\n'
} >"$HOOKS/commit-msg.new"
mv "$HOOKS/commit-msg.new" "$HOOKS/commit-msg"
chmod +x "$HOOKS/commit-msg"
RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"--uninstall"*) true ;; *) false ;; esac \
  && ok "control: setup refuses that clone and prints the remedy" \
  || bad "control: setup refuses that clone and prints the remedy" "rc=$RC out=$OUT"
# Step one, exactly as the message spells it.
(cd "$R" && ./.agents/skills/growth-guards/scripts/install-git-hooks --uninstall >/dev/null 2>&1) || true
[ -e "$HOOKS/commit-msg" ] && grep -qF 'my own lane' "$HOOKS/commit-msg" \
  && ok "--uninstall leaves a hook still holding the consumer's lane" \
  || bad "--uninstall leaves that hook" "$(cat "$HOOKS/commit-msg" 2>&1)"
RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -ne 0 ] \
  && ok "must-fail: step one alone does not clear the refusal" \
  || bad "must-fail: step one alone does not clear the refusal" "rc=$RC out=$OUT"
# Step two, which the message keys on that hook still being there.
rm -f "$HOOKS/commit-msg"
RC=0
OUT="$(cd "$R" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -eq 0 ] && case "$OUT" in *"hooks armed"*) true ;; *) false ;; esac \
  && ok "and the remedy walked through leaves the clone armed" \
  || bad "the remedy walked through arms the clone" "rc=$RC out=$OUT"
{ grep -qF "$SENTINEL" "$HOOKS/commit-msg" && grep -qF "$SENTINEL" "$HOOKS/pre-commit"; } \
  && ok "with both shims back in place" \
  || bad "both shims back in place" "$(ls -1 "$HOOKS" 2>&1)"

echo "=== the refused clone, hook by hook, resolves one at a time ==="
new_fixture foreign2
for hook in pre-commit commit-msg; do
  printf '#!/usr/bin/env bash\necho "%s ran"\n' "$hook" >"$HOOKS/$hook"
  chmod +x "$HOOKS/$hook"
done
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
RC=0
OUT="$(cd "$E" && ./tools/setup 2>&1)" || RC=$?
[ "$RC" -ne 0 ] && case "$OUT" in *"not armed"*) true ;; *) false ;; esac \
  && ok "a configured hooks path stops setup instead of wiring a hook git ignores" \
  || bad "a configured hooks path stops setup instead of wiring a hook git ignores" "rc=$RC out=$OUT"
[ ! -e "$E/.git/hooks/pre-commit" ] && [ ! -e "$E/.git/hooks/commit-msg" ] \
  && ok "and writes no shim at the path git has stopped reading" \
  || bad "setup wrote a shim git ignores" "$(ls -1 "$E/.git/hooks" 2>&1)"

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
