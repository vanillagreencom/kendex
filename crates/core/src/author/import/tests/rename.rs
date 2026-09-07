//! What a copy taken under another name declares: the rename itself and
//! the kinds carrying no name anything keys on. The refusals that decide
//! before the first byte is written are rows of the parent's table.

use std::fs;
use std::path::Path;

use super::{file_item, find, seeded, selection, target};
use crate::author::import::{apply, inventory};
use crate::model::Scope;

/// What the catalog check makes of what one import wrote, read as the
/// person's own marketplace: how many items it found, and every breakage
/// over them. The count is half the answer — a check that read nothing
/// reports no breakage either.
#[allow(clippy::unwrap_used)]
fn checked(target: &Path) -> (usize, Vec<String>) {
    let sealed = crate::source_read::SealedSource::open(target).unwrap();
    let check = crate::check_catalog::check(&sealed, "mine").unwrap();
    let breakage = check
        .findings()
        .filter(|finding| finding.is_breakage() && !finding.is_note())
        .map(|finding| format!("{}: {}", finding.file, finding.message))
        .collect();
    (check.tally().items, breakage)
}

/// What a copy taken under another name lands, one row per file form. A
/// copy has to declare the name it lands under: a skill copied verbatim
/// under a renamed destination would land a SKILL.md calling it something
/// else, which the catalog check reports as breakage. So the file that
/// declares the name is rewritten on its name line and nothing else
/// changes — the flat rename and the nested destination it was reported
/// against; an agent's own file, which carries the name its tool answers
/// to; a parked agent, whose content sits at `<name>.md.disabled`, a
/// suffix that is not a format at all, so the bytes are asked rather
/// than the filename; a Cursor rule, `.mdc` with frontmatter, which
/// lands in the catalog's markdown slot declaring the destination
/// because what decides is the format, not the extension it wears. The
/// rest of a skill's tree is a copy: a rewrite reaching a body file would
/// refuse the whole import, since a file with no frontmatter has no line
/// to carry a name, and a skill with a references/ directory could not be
/// imported under another name at all. A command, a hook and an MCP
/// server carry no name anything keys on and are copied byte for byte —
/// real candidates, the last two reaching the wizard through a lock entry
/// pointing at the local source.
#[test]
#[allow(clippy::unwrap_used)]
#[allow(clippy::too_many_lines, reason = "one row per file form")]
fn a_renamed_copy_declares_its_destination_and_a_name_less_kind_is_copied_verbatim() {
    type Row = (
        Option<(&'static str, &'static str, &'static str)>,
        &'static str,
        &'static str,
        &'static str,
        &'static [(&'static str, &'static str)],
    );
    let rows: [Row; 8] = [
        (
            None,
            "stray",
            "renamed",
            "skills/renamed",
            &[
                (
                    "skills/renamed/SKILL.md",
                    "---\nname: renamed\ndescription: about stray\n---\nunmanaged bytes\n",
                ),
                (
                    "skills/renamed/references/notes.md",
                    "Body file. No frontmatter here.\n",
                ),
            ],
        ),
        (
            None,
            "mine",
            "group/deep",
            "skills/group/deep",
            &[(
                "skills/group/deep/SKILL.md",
                "---\nname: deep\ndescription: about mine\n---\nmy own bytes\n",
            )],
        ),
        (
            None,
            "drifter",
            "settled",
            "agents/settled.md",
            &[(
                "agents/settled.md",
                "---\nname: settled\ndescription: about drifter\n---\nAgent body.\n",
            )],
        ),
        (
            Some((
                ".claude/agents",
                "parked.md.disabled",
                "---\nname: parked\ndescription: about parked\n---\nAgent body.\n",
            )),
            "parked",
            "roused",
            "agents/roused.md",
            &[(
                "agents/roused.md",
                "---\nname: roused\ndescription: about parked\n---\nAgent body.\n",
            )],
        ),
        (
            Some((
                ".cursor/rules",
                "ruler.mdc",
                "---\ndescription: about ruler\nalwaysApply: false\n---\nRule body.\n",
            )),
            "ruler",
            "measured",
            "agents/measured.md",
            &[(
                "agents/measured.md",
                "---\nname: measured\ndescription: about ruler\nalwaysApply: false\n---\nRule body.\n",
            )],
        ),
        (
            None,
            "note",
            "memo",
            "commands/memo.md",
            &[(
                "commands/memo.md",
                "---\ndescription: a note\n---\nCommand body.\n",
            )],
        ),
        (
            None,
            "watcher",
            "sentry",
            "hooks/sentry.sh",
            &[(
                "hooks/sentry.sh",
                "#!/bin/sh\n# ---\n# name: watcher\n# event: SessionStart\n# ---\necho watching\n",
            )],
        ),
        (
            None,
            "server",
            "relay",
            "mcp/relay.toml",
            &[("mcp/relay.toml", "command = \"serve\"\nargs = []\n")],
        ),
    ];
    for (planted, name, destination, written, landed) in rows {
        let (tmp, env, scope) = seeded();
        let Scope::Project { root } = &scope else {
            unreachable!()
        };
        if let Some((dir, file, bytes)) = planted {
            file_item(&root.join(dir), file, bytes);
        }
        let scopes = [scope.clone()];
        let target = target(&env, &tmp, "mine-renamed");
        let candidates = inventory(&env, &scopes).unwrap();
        let mut chosen = selection(find(&candidates, name), false);
        chosen.destination = destination.to_owned();

        let outcome = apply(&env, &scopes, &target, &[chosen]).unwrap();
        assert_eq!(outcome.written, [written], "{name}");
        for (rel, bytes) in landed {
            assert_eq!(
                fs::read_to_string(target.join(rel)).unwrap(),
                *bytes,
                "{name} as {destination}: {rel}"
            );
        }
    }
}

/// The catalog check reads what a rename wrote as whole: run here over
/// the import, so this holds only as long as it does. And the bytes on
/// disk are what the same selection would write again, so a repeated
/// import is already present rather than someone else's.
#[test]
#[allow(clippy::unwrap_used)]
fn a_renamed_import_passes_the_catalog_check_and_repeats_as_already_present() {
    let (tmp, env, scope) = seeded();
    let scopes = [scope];
    let target = target(&env, &tmp, "mine-checked");
    fs::write(
        target.join("kendex.toml"),
        "[marketplace]\nname = \"mine\"\n",
    )
    .unwrap();
    let candidates = inventory(&env, &scopes).unwrap();
    let mut flat = selection(find(&candidates, "stray"), false);
    flat.destination = "renamed".to_owned();
    let mut nested = selection(find(&candidates, "mine"), false);
    nested.destination = "group/deep".to_owned();
    let selections = [flat, nested];

    let outcome = apply(&env, &scopes, &target, &selections).unwrap();
    assert_eq!(outcome.written, ["skills/renamed", "skills/group/deep"]);
    let (items, breakage) = checked(&target);
    assert_eq!(items, 2, "the check read both imported trees");
    assert_eq!(breakage, Vec::<String>::new());

    let again = apply(&env, &scopes, &target, &selections).unwrap();
    assert_eq!(
        again.already_present,
        ["skills/renamed", "skills/group/deep"]
    );
    assert!(again.written.is_empty());
}

/// An import that keeps the candidate's name copies its bytes verbatim,
/// nested destination included: the leaf is the name a declaration
/// carries, so moving a skill into a directory renames nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn an_import_that_keeps_the_leaf_copies_the_bytes_untouched() {
    let (tmp, env, scope) = seeded();
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-kept");
    let candidates = inventory(&env, &scopes).unwrap();
    let mut moved = selection(find(&candidates, "stray"), false);
    moved.destination = "group/stray".to_owned();
    // A tree carrying no frontmatter is copied as it is, rather than
    // refused for a name nobody asked to change.
    let bare = selection(find(&candidates, "bare"), false);

    apply(&env, &scopes, &target, &[moved, bare]).unwrap();

    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    assert_eq!(
        fs::read(target.join("skills/group/stray/SKILL.md")).unwrap(),
        fs::read(root.join(".claude/skills/stray/SKILL.md")).unwrap(),
    );
    assert_eq!(
        fs::read_to_string(target.join("skills/bare/SKILL.md")).unwrap(),
        "No frontmatter at all.\n",
    );
}

/// A namespaced candidate landing under its own name is no rename. What a
/// file inside an item declares is the leaf — it knows nothing of the
/// namespace it is installed under — so `kit/gadget` copied to
/// `kit/gadget` changes nothing, a declaration that was already wrong at
/// the origin included: this is a copy, not a repair.
#[test]
#[allow(clippy::unwrap_used)]
fn a_namespaced_candidate_kept_under_its_own_name_is_no_rename() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    // A namespaced candidate comes off the scan as the directory it sits
    // in plus its own stem, and the name its frontmatter gives is neither.
    let declared = "---\nname: misdeclared\ndescription: about gadget\n---\nAgent body.\n";
    file_item(&root.join(".claude/agents/kit"), "gadget.md", declared);
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-namespaced");
    let candidates = inventory(&env, &scopes).unwrap();

    apply(
        &env,
        &scopes,
        &target,
        &[selection(find(&candidates, "kit/gadget"), false)],
    )
    .unwrap();

    assert_eq!(
        fs::read_to_string(target.join("agents/kit/gadget.md")).unwrap(),
        declared,
    );
}

/// An illegal namespace is not a rename. The inventory keeps illegal names
/// on purpose so the wizard can offer them under a legal destination, and
/// that is the path here: `-bad/tuned` landing at `tuned` changes no leaf,
/// because a file inside an item only ever declares its leaf.
///
/// The agent that would be rewritten is the case that made it matter: its
/// frontmatter names it something else again, so a rewrite nobody asked
/// for is visible in the bytes rather than being wasted work. Asking the
/// legality question here would land `name: tuned` in the copy.
#[test]
#[allow(clippy::unwrap_used)]
fn an_illegal_namespace_over_the_same_leaf_is_no_rename() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    let misdeclared = "---\nname: misdeclared\ndescription: about tuned\n---\nAgent body.\n";
    file_item(&root.join(".claude/agents/-bad"), "tuned.md", misdeclared);
    let declared = "---\nname: kept\ndescription: about kept\n---\nAgent body.\n";
    file_item(&root.join(".claude/agents/-bad"), "kept.md", declared);
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-illegal");
    let candidates = inventory(&env, &scopes).unwrap();
    let landing = |name: &str, destination: &str| {
        let mut chosen = selection(find(&candidates, name), false);
        chosen.destination = destination.to_owned();
        chosen
    };

    // A plain leaf and a legal namespace, the two repairs the wizard offers.
    let selections = [
        landing("-bad/tuned", "tuned"),
        landing("-bad/kept", "good/kept"),
    ];
    apply(&env, &scopes, &target, &selections).unwrap();

    assert_eq!(
        fs::read_to_string(target.join("agents/tuned.md")).unwrap(),
        misdeclared,
    );
    assert_eq!(
        fs::read_to_string(target.join("agents/good/kept.md")).unwrap(),
        declared,
    );
}
