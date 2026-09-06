#!/usr/bin/env bash
# The changelog scripts/commit-msg says a commit owes: a commit touching the
# configured required paths writes an entry or says [no-changelog] in its
# HEADER, over a git-generated header as much as a hand-written one. What is
# TOUCHED is every path the commit's record names, both sides of a rename
# and a chmod included; what is WRITTEN is a path that gained content — a
# new or changed blob, a link that became a document, a rename's destination
# — never a deletion, a chmod or a document that became a link; and the
# collated record counts only under the release declaration. One table: a
# row builds its own repository around one staged change, runs the gate,
# and reads back the exit status and every line printed. The amend base is
# commit-msg-amend.test.sh; what a fragment must SAY is changelog-entries'.
set -euo pipefail

TEST_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SKILL_DIR="$(cd "$TEST_DIR/.." && pwd)"
CM="$SKILL_DIR/scripts/commit-msg"
# shellcheck source=lib/harness.bash
. "$TEST_DIR/lib/harness.bash"
ROOT="$TMP"

unset COMMIT_GUARDS_COMMIT_TYPES COMMIT_GUARDS_SUBJECT_MAX \
  COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS COMMIT_GUARDS_CHANGELOG_PATHS \
  COMMIT_GUARDS_CHANGELOG_RECORD COMMIT_GUARDS_CHANGELOG_COLLATE \
  COMMIT_GUARDS_SETTINGS_FILE 2>/dev/null || true

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

# One line for a run of the gate inside $R over a message on stdin: the exit
# status, then every printed line in order joined by ';'. ENVS is a
# comma-separated list of assignments; the settings otherwise come from the
# committed kendex.settings.toml, read the way the hook lane reads it.
judge() { # ENVS MSG
  local envs=() rc=0 out
  [ -z "$1" ] || IFS=',' read -ra envs <<<"$1"
  out="$(cd "$R" && printf '%b\n' "$2" | env ${envs[@]+"${envs[@]}"} "$CM" 2>&1)" || rc=$?
  printf 'rc=%s%s' "$rc" "${out:+ $(printf '%s\n' "$out" | LC_ALL=C paste -sd ';' -)}"
}

OK="commit-msg: OK — conventional header:"
GEN="commit-msg: git-generated header — shape and length not judged:"
owed() { # PATH — the whole violation: the path named, the remedies, the record's standing
  printf '%s' "commit-msg FAIL $1 changed without a changelog entry;  write one of: changelog.d/*/*.md;  or put [no-changelog] in the header when the commit changes nothing a consumer sees;  CHANGELOG.md counts only under COMMIT_GUARDS_CHANGELOG_COLLATE=1, which is the release commit collating the fragments"
}
waived() { # PATH
  printf '%s' "commit-msg: OK — [no-changelog] in the header waives the entry for $1"
}

# The seeded world every row builds on: crates/* and ui/* required, a record
# with an empty [Unreleased] section, one crate file, all committed.
base() { # NAME
  R="$ROOT/$1"
  mkdir -p "$R/crates/core" "$R/docs"
  git -C "$R" -c init.defaultBranch=main init -q
  git -C "$R" config user.email test@example.com
  git -C "$R" config user.name test
  printf '[env]\nCOMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS = "crates/* ui/*"\n' >"$R/kendex.settings.toml"
  printf '# Changelog\n\n## [Unreleased]\n' >"$R/CHANGELOG.md"
  printf 'fn main() {}\n' >"$R/crates/core/lib.rs"
  commit "chore: base"
}
commit() { # MESSAGE — stage everything and commit it
  git -C "$R" add -A
  git -C "$R" commit -qm "$1"
}
touch_crate() { printf 'fn %s() {}\n' "$1" >>"$R/crates/core/lib.rs"; }
fragment() { # PATH [TEXT]
  mkdir -p "$R/$(dirname "$1")"
  printf -- '- %s\n' "${2:-A fix consumers see.}" >"$R/$1"
}

fx_docs_only() { base "$1"; printf 'notes\n' >"$R/docs/notes.md"; git -C "$R" add -A; }
fx_crate() { base "$1"; touch_crate added; git -C "$R" add -A; }
fx_crate_fragment() { base "$1"; touch_crate added; fragment changelog.d/fixed/ken-1.md; git -C "$R" add -A; }
fx_fragment_deleted() { base "$1"; fragment changelog.d/fixed/ken-1.md; commit "fix(KEN-1): a change [no-changelog]"; touch_crate more; rm -f "$R/changelog.d/fixed/ken-1.md"; git -C "$R" add -A; }
fx_record_edited() { base "$1"; touch_crate more; printf '# Changelog\n\n## [Unreleased]\n\n- A fix consumers see.\n\n## [1.0.0] - 2026-01-01\n\n- A released entry.\n' >"$R/CHANGELOG.md"; git -C "$R" add -A; }
fx_ui() { base "$1"; mkdir -p "$R/ui/src"; printf 'export const x = 1;\n' >"$R/ui/src/a.ts"; git -C "$R" add -A; }
# A name git quotes in its text output: it has to reach the globs as the
# bytes git recorded, since a quoted name matches no glob.
fx_quoted() { base "$1"; printf 'fn quoted() {}\n' >"$R/$(printf 'crates/core/na\303\257ve.rs')"; git -C "$R" add -A; }
fx_rename_out() { base "$1"; git -C "$R" mv crates/core/lib.rs other-lib.rs; }
fx_rename_docs() { base "$1"; printf 'notes\n' >"$R/docs/a.md"; commit "docs: a note"; git -C "$R" mv docs/a.md docs/b.md; }
fx_rename_in() { base "$1"; fragment pending-entry.md; commit "chore: park an entry"; touch_crate moved; mkdir -p "$R/changelog.d/fixed"; git -C "$R" mv pending-entry.md changelog.d/fixed/ken-7.md; git -C "$R" add -A; }
fx_rename_away() { base "$1"; fragment changelog.d/fixed/ken-8.md; commit "chore: park a fragment [no-changelog]"; touch_crate moved_again; git -C "$R" mv changelog.d/fixed/ken-8.md parked.md; git -C "$R" add -A; }
# diff.renames=copies makes git pair a duplicated file as C, a record whose
# SOURCE the commit leaves in place; the scan pins its own detection, so the
# committer's setting never puts that record on the stream. Git offers a
# file as a copy source only when the copy is its PREIMAGE and the commit
# modifies it, so the copy is taken before the crate is touched.
fx_copies() { base "$1"; git -C "$R" config diff.renames copies; cp "$R/crates/core/lib.rs" "$R/docs/copy.rs"; touch_crate copied; git -C "$R" add -A; }
fx_copies_entry() { fx_copies "$1"; fragment changelog.d/fixed/ken-9.md; git -C "$R" add -A; }
fx_chmod_fragment() { base "$1"; fragment changelog.d/fixed/old.md "An old entry nobody is rewriting."; commit "chore: park an entry [no-changelog]"; touch_crate chmodded; chmod +x "$R/changelog.d/fixed/old.md"; git -C "$R" add -A; }
fx_rewrite_fragment() { base "$1"; fragment changelog.d/fixed/old.md "An old entry nobody is rewriting."; commit "chore: park an entry [no-changelog]"; touch_crate edited; fragment changelog.d/fixed/old.md "An old entry, now rewritten."; git -C "$R" add -A; }
fx_chmod_required() { base "$1"; chmod +x "$R/crates/core/lib.rs"; git -C "$R" add -A; }
# A link replaced by a regular file: git reports T. Two shapes, the second
# holding the link target's own bytes so BOTH SIDES CARRY ONE BLOB and a sha
# comparison alone would call a real entry no entry at all.
fx_link_to_file() { base "$1"; fragment real-entry.md "The real entry."; mkdir -p "$R/changelog.d/fixed"; ln -s ../../real-entry.md "$R/changelog.d/fixed/ken-t.md"; commit "chore: a fragment that is a link [no-changelog]"; rm -f "$R/changelog.d/fixed/ken-t.md"; fragment changelog.d/fixed/ken-t.md "The real entry."; touch_crate typed; git -C "$R" add -A; }
fx_link_to_file_same_blob() { base "$1"; mkdir -p "$R/changelog.d/fixed"; ln -s -- '- A fix consumers see.' "$R/changelog.d/fixed/old.md"; commit "chore: park a symlink fragment [no-changelog]"; rm -f "$R/changelog.d/fixed/old.md"; printf -- '- A fix consumers see.' >"$R/changelog.d/fixed/old.md"; touch_crate typed; git -C "$R" add -A; }
fx_file_to_link() { base "$1"; mkdir -p "$R/changelog.d/fixed"; printf -- '- A fix consumers see.' >"$R/changelog.d/fixed/old.md"; commit "chore: park an entry [no-changelog]"; rm -f "$R/changelog.d/fixed/old.md"; ln -s -- '- A fix consumers see.' "$R/changelog.d/fixed/old.md"; touch_crate untyped; git -C "$R" add -A; }
fx_link_to_file_outside() { base "$1"; printf 'notes\n' >"$R/docs/target.md"; ln -s target.md "$R/docs/link.md"; commit "docs: a link"; rm -f "$R/docs/link.md"; printf 'notes\n' >"$R/docs/link.md"; touch_crate typed_only; git -C "$R" add -A; }
fx_spaced_record() { base "$1"; touch_crate spaced; printf '# Changelog\n\n## [Unreleased]\n' >"$R/docs/My Changelog.md"; git -C "$R" add -A; }

fx_link_to_file link-fixture
assert_eq "fixture: HEAD carries the fragment as a symlink and the index as a type change" "120000 T" \
  "$(git -C "$R" ls-tree HEAD changelog.d/fixed/ken-t.md | cut -d' ' -f1 | tr -d '\n'; git -C "$R" diff --cached --name-status -- changelog.d/fixed/ken-t.md | cut -c1 | sed 's/^/ /')"
fx_link_to_file_same_blob same-blob-fixture
assert_eq "fixture: the link and the file are one blob, so a sha says nothing" \
  "$(git -C "$R" rev-parse "HEAD:changelog.d/fixed/old.md")" "$(git -C "$R" rev-parse ":changelog.d/fixed/old.md")"
fx_copies copies-fixture
assert_eq "fixture: under the committer's setting a bare diff really reports the copy" "C100" \
  "$(git -C "$R" diff --cached --raw | awk '$5 ~ /^C/ { print $5 }')"
fx_quoted quoted-fixture
assert_eq "fixture: git's text output really quotes the name" '"crates/core/na\303\257ve.rs"' "$(git -C "$R" diff --cached --name-only)"

CRATE="fix(KEN-1): change a crate"
echo "=== what a commit touching the required paths owes ==="
# label | fixture | env | message | expect
rows=(
  "a commit touching none of the required paths owes nothing|fx_docs_only docs-only||docs: a note|rc=0 $OK docs: a note"
  "a staged crates/ change with no entry fails, naming the path, the fragment globs unescaped, the waiver and the record's standing|fx_crate crate-1||$CRATE|rc=1 $OK $CRATE;$(owed crates/core/lib.rs)"
  "[no-changelog] in the header waives it, naming the path waived|fx_crate crate-2||$CRATE [no-changelog]|rc=0 $OK $CRATE [no-changelog];$(waived crates/core/lib.rs)"
  "control: [no-changelog] in the body alone waives nothing|fx_crate crate-3||$CRATE\n\nThe rule here is [no-changelog] for pure refactors.|rc=1 $OK $CRATE;$(owed crates/core/lib.rs)"
  "MUST: the rule runs over a git-generated header too|fx_crate crate-4||Merge branch 'topic' into main|rc=1 $GEN Merge branch 'topic' into main;$(owed crates/core/lib.rs)"
  "control: [no-changelog] escapes it on a generated header as well|fx_crate crate-5||Merge branch 'topic' into main [no-changelog]|rc=0 $GEN Merge branch 'topic' into main [no-changelog];$(waived crates/core/lib.rs)"
  "a path matching the SECOND required glob owes an entry too, and is the one named|fx_ui ui||fix(KEN-6): change the UI|rc=1 $OK fix(KEN-6): change the UI;$(owed ui/src/a.ts)"
  "a required path git would quote is still matched, and named as bash spells it|fx_quoted quoted|LC_ALL=C|fix(KEN-4): change a crate under a quoted name|rc=1 $OK fix(KEN-4): change a crate under a quoted name;$(owed "\$'crates/core/na\\303\\257ve.rs'")"
  "a chmod under a required path is a touch|fx_chmod_required chmod-required||fix(KEN-10): make a crate file executable|rc=1 $OK fix(KEN-10): make a crate file executable;$(owed crates/core/lib.rs)"
  "a rename OUT of a required path is refused, naming the path it left|fx_rename_out rename-out-1||refactor(KEN-7): move a crate file out|rc=1 $OK refactor(KEN-7): move a crate file out;$(owed crates/core/lib.rs)"
  "control: the same rename with [no-changelog] passes|fx_rename_out rename-out-2||refactor(KEN-7): move a crate file out [no-changelog]|rc=0 $OK refactor(KEN-7): move a crate file out [no-changelog];$(waived crates/core/lib.rs)"
  "a rename within unrequired paths owes nothing|fx_rename_docs rename-docs||docs(KEN-7): rename a note|rc=0 $OK docs(KEN-7): rename a note"
)
for row in "${rows[@]}"; do
  IFS='|' read -r label fixture env msg expect <<<"$row"
  $fixture
  assert_eq "$label" "$expect" "$(judge "$env" "$msg")"
done

echo "=== what counts as a written entry: a path that gained content ==="
rows=(
  "a staged fragment satisfies it|fx_crate_fragment fragment||$CRATE|rc=0 $OK $CRATE"
  "deleting a fragment is not writing one|fx_fragment_deleted fragment-deleted||fix(KEN-2): change a crate again|rc=1 $OK fix(KEN-2): change a crate again;$(owed crates/core/lib.rs)"
  "the record edited is no entry — nothing declares this a collation|fx_record_edited record-1||chore(release): collate the changelog|rc=1 $OK chore(release): collate the changelog;$(owed crates/core/lib.rs)"
  "COMMIT_GUARDS_CHANGELOG_COLLATE=1 makes the collated record the entry|fx_record_edited record-2|COMMIT_GUARDS_CHANGELOG_COLLATE=1|chore(release): collate the changelog|rc=0 $OK chore(release): collate the changelog"
  "a rename INTO the fragment tree is the entry|fx_rename_in rename-in||fix(KEN-7): change a crate|rc=0 $OK fix(KEN-7): change a crate"
  "control: moving a fragment away is not writing one|fx_rename_away rename-away||fix(KEN-8): change a crate|rc=1 $OK fix(KEN-8): change a crate;$(owed crates/core/lib.rs)"
  "a copy-configured repository is judged on the same record vocabulary|fx_copies copies-1||fix(KEN-9): change a crate|rc=1 $OK fix(KEN-9): change a crate;$(owed crates/core/lib.rs)"
  "the entry written beside a copy is still the entry|fx_copies_entry copies-2||fix(KEN-9): change a crate|rc=0 $OK fix(KEN-9): change a crate"
  "a chmod on an existing fragment is not the entry|fx_chmod_fragment chmod-fragment||fix(KEN-10): change a crate|rc=1 $OK fix(KEN-10): change a crate;$(owed crates/core/lib.rs)"
  "control: rewriting the same fragment is|fx_rewrite_fragment rewrite-fragment||fix(KEN-10): change a crate|rc=0 $OK fix(KEN-10): change a crate"
  "a fragment that changed type from a link to a file is a written entry|fx_link_to_file link-to-file||fix(KEN-T): replace a link with a real fragment|rc=0 $OK fix(KEN-T): replace a link with a real fragment"
  "a link becoming a file holding the link target's own bytes is the entry, one blob or not|fx_link_to_file_same_blob same-blob||fix(KEN-11): change a crate|rc=0 $OK fix(KEN-11): change a crate"
  "control: a document becoming a link holding the same bytes is not the entry|fx_file_to_link file-to-link||fix(KEN-11): change a crate|rc=1 $OK fix(KEN-11): change a crate;$(owed crates/core/lib.rs)"
  "control: a type change outside the fragment globs is no entry|fx_link_to_file_outside link-outside||fix(KEN-T): change a crate|rc=1 $OK fix(KEN-T): change a crate;$(owed crates/core/lib.rs)"
)
for row in "${rows[@]}"; do
  IFS='|' read -r label fixture env msg expect <<<"$row"
  $fixture
  assert_eq "$label" "$expect" "$(judge "$env" "$msg")"
done

echo "=== the paths are configuration, validated like every other ==="
SPACED="COMMIT_GUARDS_CHANGELOG_COLLATE=1,COMMIT_GUARDS_CHANGELOG_RECORD=docs/My Changelog.md"
rows=(
  "an explicitly empty required list switches the rule off|fx_crate config-1|COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS=|fix(KEN-3): change a crate|rc=0 $OK fix(KEN-3): change a crate"
  "an absolute required path is a config error|fx_crate config-2|COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS=/etc/crates|fix(KEN-3): change a crate|rc=2 ::error::commit-msg: changelog-required path must be repo-root-relative, got absolute: /etc/crates"
  "every entry is validated: a list whose second entry is absolute is the same error|fx_crate config-3|COMMIT_GUARDS_CHANGELOG_REQUIRED_PATHS=crates/* /etc/crates|fix(KEN-3): change a crate|rc=2 ::error::commit-msg: changelog-required path must be repo-root-relative, got absolute: /etc/crates"
  "a record path carrying a space is one value: writing that file satisfies the rule|fx_spaced_record spaced-1|$SPACED|fix(KEN-5): change a crate|rc=0 $OK fix(KEN-5): change a crate"
  "control: without that file the same commit owes an entry, the record named as it must be typed|fx_crate spaced-2|$SPACED|fix(KEN-5): change a crate|rc=1 $OK fix(KEN-5): change a crate;commit-msg FAIL crates/core/lib.rs changed without a changelog entry;  write one of: changelog.d/*/*.md;  or put [no-changelog] in the header when the commit changes nothing a consumer sees;  docs/My\\ Changelog.md counts only under COMMIT_GUARDS_CHANGELOG_COLLATE=1, which is the release commit collating the fragments"
  "an empty fragment glob list is the config error both lanes give, after the header verdict|fx_crate config-4|COMMIT_GUARDS_CHANGELOG_PATHS=|fix(KEN-3): change a crate|rc=2 $OK fix(KEN-3): change a crate;::error::commit-msg: COMMIT_GUARDS_CHANGELOG_PATHS names no path — name at least one, or drop this check from COMMIT_GUARDS_CHECKS"
  "the overlap between the two scopes is one judgement, made in the shared resolution|fx_crate config-5|COMMIT_GUARDS_CHANGELOG_RECORD=changelog.d/fixed/x.md|fix(KEN-3): change a crate|rc=2 $OK fix(KEN-3): change a crate;::error::commit-msg: COMMIT_GUARDS_CHANGELOG_RECORD (changelog.d/fixed/x.md) is also matched by COMMIT_GUARDS_CHANGELOG_PATHS — the collated record is not a fragment"
)
for row in "${rows[@]}"; do
  IFS='|' read -r label fixture env msg expect <<<"$row"
  $fixture
  assert_eq "$label" "$expect" "$(judge "$env" "$msg")"
done

printf '\n%s passed, %s failed\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ]
