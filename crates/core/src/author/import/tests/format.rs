//! An agent whose bytes are not the markdown a catalog stores: not
//! offered, whichever door it arrives at, and the offer says why.
//!
//! Codex keeps its agents as TOML and an unmanaged scan finds them like
//! any other. A catalog keeps an agent at `agents/<name>.md`, the catalog
//! check's structural pass never validates one, and every consumer's
//! install refuses it — so a copy taken under the candidate's own name
//! published breakage in silence, and one taken under a new name refused
//! only at apply, with no way to finish the rename.

use std::fs;

use super::{entry, file_item, find, seeded, target};
use crate::author::import::{ImportSelection, apply, inventory};
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

/// The unmanaged door, which is the silent one: both names refused before
/// a byte is written, and the markdown agent beside it still offered.
#[test]
#[allow(clippy::unwrap_used)]
fn an_agent_in_another_format_is_not_offered_under_either_name() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    file_item(
        &root.join(".codex/agents"),
        "codexer.toml",
        "name = \"codexer\"\ndescription = \"about codexer\"\n",
    );
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-codex");
    let candidates = inventory(&env, &scopes).unwrap();

    // Listed, so the person sees kendex found it, with no hash to select
    // and the reason where the hash would be.
    let codexer = find(&candidates, "codexer");
    assert!(
        codexer.origins.iter().all(|origin| origin.hash.is_empty()),
        "nothing selectable: {:?}",
        codexer.origins
    );
    let refused = &codexer.origins[0];
    assert!(
        refused.locations[0].contains("codexer.toml"),
        "the place is a path and nothing else: {:?}",
        refused.locations
    );
    let problem = refused.problem.as_deref().unwrap_or_default();
    assert!(problem.contains("it has no frontmatter"), "{problem}");
    assert!(
        problem.contains("a catalog stores an agent as markdown"),
        "{problem}"
    );

    // The markdown agent in the same scan is untouched by the rule: this
    // excludes a format, not a kind.
    assert!(
        !find(&candidates, "drifter").origins[0].hash.is_empty(),
        "{:?}",
        find(&candidates, "drifter").origins
    );

    // Both paths the issue names: under its own name, where the copy used
    // to land TOML in a `.md` slot the catalog check calls clean, and
    // under a new one, where the rename used to refuse at apply.
    for chosen in [
        selection("codexer", "codexer"),
        selection("codexer", "settled"),
    ] {
        let destination = chosen.destination.clone();
        let message = apply(&env, &scopes, &target, &[chosen])
            .unwrap_err()
            .to_string();
        assert!(
            message.contains("has no bytes kendex can import"),
            "{destination}: {message}"
        );
        assert!(message.contains("codexer.toml"), "{destination}: {message}");
        assert!(
            message.contains("it has no frontmatter"),
            "and why, rather than a change nobody made — {destination}: {message}"
        );
    }
    assert!(
        !target.join("agents").exists(),
        "a refused apply writes nothing at all"
    );
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
        lock::entry_key(ItemKind::Agent, "agentic", HarnessId::Claude),
        entry(ItemKind::Agent, "agentic", "cat", "cat"),
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
    assert!(
        offered[0].locations[0].contains("agents/agentic.md"),
        "the catalog's own markdown is what stays offerable: {:?}",
        offered[0].locations
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
    assert!(
        refused[0].locations[0].contains("agentic.toml"),
        "{:?}",
        refused[0].locations
    );
    assert!(
        refused[0]
            .problem
            .as_deref()
            .is_some_and(|problem| problem.contains("a catalog stores an agent as markdown")),
        "{:?}",
        refused[0].problem
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
    assert!(
        fs::read_to_string(target.join("agents/agentic.md"))
            .unwrap()
            .contains("name: agentic"),
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
    let message = apply(&env, &scopes, &target, &[stale])
        .unwrap_err()
        .to_string();
    assert!(message.contains("changed since the preview"), "{message}");
    assert!(!message.contains("agentic.toml"), "{message}");
    assert!(
        !message.contains("has no bytes kendex can import"),
        "{message}"
    );
}

/// Bytes that are not text carry no frontmatter either, and the reason
/// says which of the two it is. A file parked at `.claude/agents/<name>.md`
/// is offered by its extension alone, so this is the shape that would
/// otherwise land raw bytes in a catalog under a name the check calls
/// clean.
#[test]
#[allow(clippy::unwrap_used)]
fn an_agent_whose_bytes_are_not_text_is_not_offered() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    let dir = root.join(".claude/agents");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("binary.md"), [0xff, 0xfe, b'\n']).unwrap();
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-binary-agent");
    let candidates = inventory(&env, &scopes).unwrap();

    let binary = find(&candidates, "binary");
    assert!(
        binary.origins.iter().all(|origin| origin.hash.is_empty()),
        "nothing selectable: {:?}",
        binary.origins
    );
    assert!(
        binary.origins[0]
            .problem
            .as_deref()
            .is_some_and(|problem| problem.contains("the file is not text")),
        "{:?}",
        binary.origins[0].problem
    );

    let message = apply(&env, &scopes, &target, &[selection("binary", "binary")])
        .unwrap_err()
        .to_string();
    assert!(
        message.contains("has no bytes kendex can import"),
        "{message}"
    );
    assert!(message.contains("binary.md"), "{message}");
    assert!(message.contains("the file is not text"), "{message}");
    assert!(!target.join("agents").exists());
}

/// The Own door, which is the migration path: a catalog a pre-fix kendex
/// wrote already holds TOML at `agents/<name>.md`, and re-importing from
/// it is how the breakage would reach a second package. Judged by the same
/// rule as any other origin, because every read goes through `offered`.
#[test]
#[allow(clippy::unwrap_used)]
fn a_local_catalog_already_holding_toml_is_not_offered_on() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    let toml = "name = \"poisoned\"\ndescription = \"about poisoned\"\n";
    file_item(
        &root.join(crate::source::LOCAL_SOURCE_DIR).join("agents"),
        "poisoned.md",
        toml,
    );
    let path = lock::lock_path(&env, &scope);
    let mut held = lock::load(&path).unwrap();
    held.entries.insert(
        lock::entry_key(ItemKind::Agent, "poisoned", HarnessId::Claude),
        entry(ItemKind::Agent, "poisoned", "local", "local"),
    );
    lock::save(&path, &held).unwrap();

    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-poisoned");
    let candidates = inventory(&env, &scopes).unwrap();

    let poisoned = find(&candidates, "poisoned");
    assert!(
        poisoned
            .origins
            .iter()
            .any(|origin| matches!(origin.group, crate::author::import::CandidateGroup::Own)),
        "the local catalog is the origin under test: {:?}",
        poisoned.origins
    );
    assert!(
        poisoned.origins.iter().all(|origin| origin.hash.is_empty()),
        "nothing selectable: {:?}",
        poisoned.origins
    );
    assert!(
        poisoned.origins[0]
            .problem
            .as_deref()
            .is_some_and(|problem| problem.contains("it has no frontmatter")),
        "{:?}",
        poisoned.origins[0].problem
    );

    let message = apply(&env, &scopes, &target, &[selection("poisoned", "poisoned")])
        .unwrap_err()
        .to_string();
    assert!(
        message.contains("has no bytes kendex can import"),
        "{message}"
    );
    assert!(message.contains("poisoned.md"), "{message}");
    assert!(
        !target.join("agents").exists(),
        "a refused apply writes nothing at all"
    );
}
