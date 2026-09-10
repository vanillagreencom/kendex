//! An agent whose bytes are not the markdown a catalog stores: not
//! offered, whichever door it arrives at, and the offer says why.
//!
//! Codex keeps its agents as TOML and an unmanaged scan finds them like
//! any other. A catalog keeps an agent at `agents/<name>.md`, the catalog
//! check's structural pass never validates one, and every consumer's
//! install refuses it — so a copy taken under the candidate's own name
//! would publish breakage in silence, and one taken under another name
//! would refuse only at apply, with no way to finish the rename.

use std::fs;

use super::{entry, file_item, find, seeded, target};
use crate::author::import::{ImportSelection, apply, inventory};
use crate::error::CoreError;
use crate::lock;
use crate::model::{HarnessId, ItemKind, Scope};

/// A selection the wizard would never hand over, spelled by hand: the
/// preview carries no hash for these bytes, so apply is asked with the
/// empty one a caller reaching past the inventory would have.
fn selection(name: &str, destination: &str) -> ImportSelection {
    ImportSelection {
        kind: ItemKind::Agent,
        name: name.to_owned(),
        destination: destination.to_owned(),
        hash: String::new(),
        license_confirmed: false,
        license_basis: None,
    }
}

/// One row per door bytes that are not the markdown a catalog stores can
/// arrive at: the unmanaged scan, which is the silent one (Codex keeps
/// its agents as TOML); a file parked at `.claude/agents/<name>.md`,
/// offered by its extension alone, whose bytes are not text — the reason
/// says which of the two it is; and a local catalog already holding TOML
/// at `agents/<name>.md`, judged by the same rule as any other origin
/// because every read goes through `offered`, so re-importing from it
/// cannot carry the breakage into another package.
///
/// The candidate is listed, so the person sees kendex found it, with no
/// hash to select and the reason where the hash would be, and the place
/// is a path and nothing else. Apply refuses under the candidate's own
/// name, where a copy would land the bytes in a `.md` slot the catalog
/// check calls clean, and under another one, where the rename would
/// otherwise refuse only at apply with no way to finish it — the same
/// words both times, and nothing written. The markdown agent in the same
/// scan is untouched: this excludes a format, not a kind.
#[test]
#[allow(clippy::unwrap_used)]
fn bytes_a_catalog_cannot_store_are_listed_without_a_hash_and_refused_under_either_name() {
    type Row<'a> = (&'a str, &'a str, &'a [u8], Option<&'a str>, &'a str);
    let local = format!("{}/agents", crate::source::LOCAL_SOURCE_DIR);
    let rows: [Row<'_>; 3] = [
        (
            ".codex/agents",
            "codexer.toml",
            b"name = \"codexer\"\ndescription = \"about codexer\"\n",
            None,
            "it has no frontmatter, and a catalog stores an agent as markdown",
        ),
        (
            ".claude/agents",
            "binary.md",
            &[0xff, 0xfe, b'\n'],
            None,
            "the file is not text, and a catalog stores an agent as markdown",
        ),
        (
            local.as_str(),
            "poisoned.md",
            b"name = \"poisoned\"\ndescription = \"about poisoned\"\n",
            Some("local"),
            "it has no frontmatter, and a catalog stores an agent as markdown",
        ),
    ];
    for (dir, file, bytes, locked, problem) in rows {
        let (tmp, env, scope) = seeded();
        let Scope::Project { root } = &scope else {
            unreachable!()
        };
        let name = file.split_once('.').unwrap().0;
        fs::create_dir_all(root.join(dir)).unwrap();
        fs::write(root.join(dir).join(file), bytes).unwrap();
        if let Some(source) = locked {
            let path = lock::lock_path(&env, &scope);
            let mut held = lock::load(&path).unwrap();
            held.entries.insert(
                lock::entry_key(ItemKind::Agent, name, HarnessId::Claude),
                entry(ItemKind::Agent, name, source, source),
            );
            lock::save(&path, &held).unwrap();
        }
        let scopes = [scope.clone()];
        let target = target(&env, &tmp, "mine-unstorable");
        let candidates = inventory(&env, &scopes).unwrap();

        let place = crate::paths::slashed(&root.join(dir).join(file));
        let listed: Vec<(Vec<&str>, &str, Option<&str>)> = find(&candidates, name)
            .origins
            .iter()
            .map(|origin| {
                (
                    origin.locations.iter().map(String::as_str).collect(),
                    origin.hash.as_str(),
                    origin.problem.as_deref(),
                )
            })
            .collect();
        assert_eq!(
            listed,
            [(vec![place.as_str()], "", Some(problem))],
            "{file}"
        );
        assert!(
            !find(&candidates, "drifter").origins[0].hash.is_empty(),
            "{file}: the markdown agent beside it is still offered"
        );

        for destination in [name, "elsewhere"] {
            let error = apply(&env, &scopes, &target, &[selection(name, destination)]).unwrap_err();
            let CoreError::Authoring { message } = &error else {
                panic!("{file} as {destination}: {error:?}");
            };
            assert_eq!(
                message,
                &format!("agent '{name}' has no bytes kendex can import: {place} — {problem}"),
                "{file} as {destination}"
            );
        }
        assert!(
            target.join("agents").symlink_metadata().is_err(),
            "{file}: a refused apply writes nothing at all"
        );
    }
}

/// The other door: an agent installs as the file its harness reads, so the
/// edited copy of a marketplace agent under Codex is that TOML rendering.
/// The marketplace's own bytes are the catalog's markdown and stay
/// offerable; the copy beside them does not.
#[test]
#[allow(clippy::unwrap_used)]
fn the_edited_copy_of_a_marketplace_agent_is_judged_by_the_same_rule() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    file_item(
        &tmp.path().join("catalog/agents"),
        "agentic.md",
        "---\nname: agentic\ndescription: about agentic\n---\nAgent body.\n",
    );
    file_item(
        &root.join(".codex/agents"),
        "agentic.toml",
        "name = \"agentic\"\ndescription = \"about agentic\"\n",
    );
    let path = lock::lock_path(&env, &scope);
    let mut held = lock::load(&path).unwrap();
    held.entries.insert(
        // Recorded for the tool that holds the file: the copy beside the
        // marketplace's own bytes is this record's, and nothing but a
        // record says so.
        lock::entry_key(ItemKind::Agent, "agentic", HarnessId::Codex),
        crate::lock::LockEntry {
            harness: HarnessId::Codex,
            ..entry(ItemKind::Agent, "agentic", "cat", "cat")
        },
    );
    lock::save(&path, &held).unwrap();

    let scopes = [scope.clone()];
    let candidates = inventory(&env, &scopes).unwrap();
    let agentic = find(&candidates, "agentic");
    let (offered, refused): (Vec<_>, Vec<_>) = agentic
        .origins
        .iter()
        .partition(|origin| !origin.hash.is_empty());
    assert_eq!(offered.len(), 1, "{:?}", agentic.origins);
    assert_eq!(
        offered[0].locations,
        ["cat:agents/agentic.md"],
        "the catalog's own markdown is what stays offerable"
    );
    // The TOML is claimed twice — as the edited copy of the marketplace
    // agent, and by the unmanaged scan of an install the lock does not
    // cover — and the two claims are refused by the one rule and listed
    // once, under the strictest provenance of the claimants.
    assert_eq!(refused.len(), 1, "{:?}", agentic.origins);
    assert!(
        matches!(
            refused[0].group,
            crate::author::import::CandidateGroup::Edited { .. }
        ),
        "{:?}",
        agentic.origins
    );
    assert_eq!(
        refused[0].locations,
        [crate::paths::slashed(
            &root.join(".codex/agents/agentic.toml")
        )]
    );
    assert_eq!(
        refused[0].problem.as_deref(),
        Some("it has no frontmatter, and a catalog stores an agent as markdown")
    );

    // And the markdown half really does import, so the rule took away the
    // TOML rendering rather than the candidate.
    let target = target(&env, &tmp, "mine-edited-agent");
    let chosen = ImportSelection {
        hash: offered[0].hash.clone(),
        license_confirmed: true,
        ..selection("agentic", "agentic")
    };
    apply(&env, &scopes, &target, &[chosen]).unwrap();
    assert_eq!(
        fs::read_to_string(target.join("agents/agentic.md")).unwrap(),
        "---\nname: agentic\ndescription: about agentic\n---\nAgent body.\n"
    );

    // A hash matching nothing, on a candidate that still holds a usable
    // origin, is a preview gone stale — not this rule. The refusal says so
    // and names no file, because the refused origin was never what the
    // selection was about.
    let stale = ImportSelection {
        hash: "0".repeat(64),
        license_confirmed: true,
        ..selection("agentic", "agentic")
    };
    let error = apply(&env, &scopes, &target, &[stale]).unwrap_err();
    let CoreError::Authoring { message } = &error else {
        panic!("{error:?}");
    };
    assert_eq!(
        message,
        "the bytes of agent 'agentic' changed since the preview — re-open the import to re-preview"
    );
}
