use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use super::*;
use crate::env::FakeOs;
use crate::lock::{Lock, LockEntry};
use crate::manifest::Method;
use crate::model::HarnessId;

#[allow(clippy::unwrap_used)]
fn entry(kind: ItemKind, name: &str, source: &str, repo: &str) -> LockEntry {
    LockEntry {
        name: name.to_owned(),
        kind,
        harness: HarnessId::Claude,
        source: source.to_owned(),
        source_repo: repo.to_owned(),
        method: Method::Symlink,
        installed_at: "2026-01-01T00:00:00Z".to_owned(),
        source_hash: "hash".to_owned(),
        source_commit: None,
        rendered_hash: None,
        enabled: true,
        upstream_skills: None,
        emitted: None,
        registration: None,
        reasons: BTreeSet::from([crate::lock::Reason::Requested]),
        author_review: None,
    }
}

#[allow(clippy::unwrap_used)]
fn skill(dir: &Path, name: &str, body: &str) {
    let skill = dir.join(name);
    fs::create_dir_all(&skill).unwrap();
    fs::write(
        skill.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: about {name}\n---\n{body}\n"),
    )
    .unwrap();
}

/// A project with all three origins: a marketplace skill (path source with
/// a licence), the person's own local-source skill, and an unmanaged one.
#[allow(clippy::unwrap_used)]
fn seeded() -> (tempfile::TempDir, Env, Scope) {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let catalog = tmp.path().join("catalog");
    skill(&catalog.join("skills"), "gh", "market bytes");
    fs::write(
        catalog.join("kendex.toml"),
        "[marketplace]\nname = \"cat\"\nlicense = \"MIT\"\n",
    )
    .unwrap();
    let project = tmp.path().join("app");
    skill(&project.join(".claude/skills"), "stray", "unmanaged bytes");
    skill(
        &project.join(crate::rename::LOCAL_SOURCE_DIR).join("skills"),
        "mine",
        "my own bytes",
    );
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 5\n[sources.cat]\npath = \"{}\"\n[skills.gh]\nsource = \"cat\"\n",
            catalog.display()
        ),
    )
    .unwrap();
    let project = project.canonicalize().unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };
    let mut lock = Lock {
        version: crate::lock::LOCK_VERSION,
        ..Lock::default()
    };
    for (name, source, repo) in [("gh", "cat", "cat"), ("mine", "local", "local")] {
        lock.entries.insert(
            crate::lock::entry_key(ItemKind::Skill, name, HarnessId::Claude),
            entry(ItemKind::Skill, name, source, repo),
        );
    }
    crate::lock::save(&crate::lock::lock_path(&env, &scope), &lock).unwrap();
    (tmp, env, scope)
}

/// Apply refuses unregistered targets, so every test target is created and
/// registered under Mine first.
#[allow(clippy::unwrap_used)]
fn target(env: &Env, tmp: &tempfile::TempDir, name: &str) -> std::path::PathBuf {
    let dir = tmp.path().join(name);
    fs::create_dir_all(&dir).unwrap();
    crate::author::registry::register(env, &dir).unwrap();
    dir.canonicalize().unwrap()
}

#[allow(clippy::unwrap_used)]
fn find<'a>(candidates: &'a [ImportCandidate], name: &str) -> &'a ImportCandidate {
    candidates
        .iter()
        .find(|candidate| candidate.name == name)
        .unwrap_or_else(|| panic!("no candidate {name}"))
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_inventory_lists_all_three_origins_with_their_groups() {
    let (_tmp, env, scope) = seeded();
    let scopes = [scope];
    let candidates = inventory(&env, &scopes).unwrap();

    let own = find(&candidates, "mine");
    assert!(matches!(own.origins[0].group, CandidateGroup::Own));
    assert!(!own.origins[0].hash.is_empty());

    let market = find(&candidates, "gh");
    let CandidateGroup::Marketplace { license, .. } = &market.origins[0].group else {
        panic!("gh should be marketplace-origin: {:?}", market.origins);
    };
    assert_eq!(license.as_deref(), Some("MIT"));

    let stray = find(&candidates, "stray");
    assert!(matches!(stray.origins[0].group, CandidateGroup::Unmanaged));
}

#[allow(clippy::unwrap_used)]
fn selection(candidate: &ImportCandidate, confirmed: bool) -> ImportSelection {
    ImportSelection {
        kind: candidate.kind,
        name: candidate.name.clone(),
        destination: candidate.name.clone(),
        hash: candidate.origins[0].hash.clone(),
        license_confirmed: confirmed,
        license_basis: None,
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn marketplace_origin_copies_only_past_licence_confirmation() {
    let (tmp, env, scope) = seeded();
    let scopes = [scope];
    let target = target(&env, &tmp, "mine-market");
    let candidates = inventory(&env, &scopes).unwrap();
    let gh = find(&candidates, "gh");

    let refused = apply(&env, &scopes, &target, &[selection(gh, false)]);
    assert!(refused.is_err(), "unconfirmed licence must refuse");
    assert!(
        !target.join("skills/gh").exists(),
        "a refused apply must write nothing"
    );

    let outcome = apply(&env, &scopes, &target, &[selection(gh, true)]).unwrap();
    assert_eq!(outcome.written, ["skills/gh"]);
    assert!(target.join("skills/gh/SKILL.md").exists());

    // The same bytes again are already present, not a collision.
    let again = apply(&env, &scopes, &target, &[selection(gh, true)]).unwrap();
    assert_eq!(again.already_present, ["skills/gh"]);
    assert!(again.written.is_empty());
}

#[test]
#[allow(clippy::unwrap_used)]
fn own_and_unmanaged_content_import_without_a_licence_question() {
    let (tmp, env, scope) = seeded();
    let scopes = [scope];
    let target = target(&env, &tmp, "mine-own");
    let candidates = inventory(&env, &scopes).unwrap();
    let selections = [
        selection(find(&candidates, "mine"), false),
        selection(find(&candidates, "stray"), false),
    ];
    let outcome = apply(&env, &scopes, &target, &selections).unwrap();
    assert_eq!(outcome.written.len(), 2);
    assert!(target.join("skills/mine/SKILL.md").exists());
    assert!(target.join("skills/stray/SKILL.md").exists());
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_destination_holding_different_bytes_is_a_refusal_naming_it() {
    let (tmp, env, scope) = seeded();
    let scopes = [scope];
    let target = target(&env, &tmp, "mine-clash");
    skill(
        &target.join("skills"),
        "mine",
        "different bytes already here",
    );
    let candidates = inventory(&env, &scopes).unwrap();
    let refused = apply(
        &env,
        &scopes,
        &target,
        &[selection(find(&candidates, "mine"), false)],
    );
    let message = refused.unwrap_err().to_string();
    assert!(message.contains("different bytes"), "{message}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_case_folding_sibling_refuses_before_the_copy() {
    let (tmp, env, scope) = seeded();
    let scopes = [scope];
    let target = target(&env, &tmp, "mine-fold");
    skill(&target.join("skills"), "MINE", "upper-case sibling");
    let candidates = inventory(&env, &scopes).unwrap();
    let refused = apply(
        &env,
        &scopes,
        &target,
        &[selection(find(&candidates, "mine"), false)],
    );
    let message = refused.unwrap_err().to_string();
    assert!(message.contains("case-insensitive"), "{message}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_stale_hash_refuses_instead_of_copying_moved_bytes() {
    let (tmp, env, scope) = seeded();
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-stale");
    let candidates = inventory(&env, &scopes).unwrap();
    let mut chosen = selection(find(&candidates, "mine"), false);
    // The preview goes stale: the local source's bytes change under it.
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    fs::write(
        root.join(crate::rename::LOCAL_SOURCE_DIR)
            .join("skills/mine/SKILL.md"),
        "---\nname: mine\ndescription: about mine\n---\nedited since preview\n",
    )
    .unwrap();
    let refused = apply(&env, &scopes, &target, std::slice::from_ref(&chosen));
    let message = refused.unwrap_err().to_string();
    assert!(message.contains("changed since the preview"), "{message}");
    // Re-previewing picks up the new hash and the copy proceeds.
    let fresh = inventory(&env, &scopes).unwrap();
    chosen.hash = find(&fresh, "mine").origins[0].hash.clone();
    apply(&env, &scopes, &target, &[chosen]).unwrap();
}

mod review;
