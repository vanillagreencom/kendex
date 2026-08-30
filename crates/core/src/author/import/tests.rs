use std::collections::BTreeMap;
use std::collections::BTreeSet;
use std::fs;
use std::path::Path;

use super::*;
use crate::env::FakeOs;

#[path = "../../../../test_util.rs"]
mod test_util;
use crate::lock::{Lock, LockEntry};
use crate::manifest::Method;
use crate::model::HarnessId;
use test_util::source_path;

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
        &project.join(crate::source::LOCAL_SOURCE_DIR).join("skills"),
        "mine",
        "my own bytes",
    );
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n[sources.cat]\n{}\n[skills.gh]\nsource = \"cat\"\n",
            source_path(&catalog)
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

/// A write that stops part-way leaves bytes behind, and the copy is not
/// a transaction. The error has to name them: the next attempt reads
/// them as somebody else's and tells the person to remove a file they
/// never put there.
#[test]
#[allow(clippy::unwrap_used)]
fn a_write_that_stops_part_way_names_what_reached_the_folder() {
    let (tmp, env, scope) = seeded();
    let scopes = [scope];
    let target = target(&env, &tmp, "mine-interrupted");
    // A regular file where the second selection's tree needs a
    // directory. Nothing sits at the destination itself, so this is not a
    // refusal pass one can make; the write is what meets it.
    fs::create_dir_all(target.join("skills")).unwrap();
    fs::write(target.join("skills/blocked"), "not a directory").unwrap();

    let candidates = inventory(&env, &scopes).unwrap();
    let mut second = selection(find(&candidates, "stray"), false);
    second.destination = "blocked/here".to_owned();
    let selections = [selection(find(&candidates, "mine"), false), second];

    let message = apply(&env, &scopes, &target, &selections)
        .unwrap_err()
        .to_string();
    assert!(
        message.contains("skills/blocked/here"),
        "the error names the destination that failed: {message}"
    );
    assert!(
        message.contains("skills/mine"),
        "and what landed before it: {message}"
    );
    assert!(
        message.contains("Remove them before importing again"),
        "{message}"
    );
    // What the copy leaves, pinned rather than assumed: the selections
    // before the failure are on disk, the one that failed is not, and
    // nothing was rolled back. Restoring per-package atomicity would need
    // the staging directory this issue removes.
    assert!(
        target.join("skills/mine/SKILL.md").is_file(),
        "the earlier selection really is on disk"
    );
    assert!(
        !target.join("skills/blocked/here").exists(),
        "the selection that failed wrote nothing"
    );
    assert_eq!(
        fs::read_to_string(target.join("skills/blocked")).unwrap(),
        "not a directory",
        "and what was in the way is untouched"
    );
}

/// Two candidates with nothing to do with each other, one of them given
/// a destination spelled under the other's. A nested destination name is
/// ordinary and says nothing by itself about where the bytes land: these
/// two trees never meet, so both are copied whole.
///
/// (A pair `source::layout::nested_names` itself offers is the other
/// case. It lists `p` only where `p/SKILL.md` sits and `p/sub` only where
/// `p/sub/SKILL.md` does, and a skill's tree is read whole, so `p` really
/// does write into `p/sub` and this rule refuses it.)
#[test]
#[allow(clippy::unwrap_used)]
fn a_nested_pair_whose_trees_do_not_meet_is_copied_whole() {
    let (tmp, env, scope) = seeded();
    let scopes = [scope];
    let target = target(&env, &tmp, "mine-nested");
    let candidates = inventory(&env, &scopes).unwrap();
    let mut under = selection(find(&candidates, "stray"), false);
    under.destination = "mine/nested".to_owned();
    let selections = [selection(find(&candidates, "mine"), false), under];

    let outcome = apply(&env, &scopes, &target, &selections).unwrap();
    assert_eq!(outcome.written, ["skills/mine", "skills/mine/nested"]);
    assert!(
        fs::read_to_string(target.join("skills/mine/SKILL.md"))
            .unwrap()
            .contains("my own bytes")
    );
    assert!(
        fs::read_to_string(target.join("skills/mine/nested/SKILL.md"))
            .unwrap()
            .contains("unmanaged bytes")
    );
}

/// Two legal destination names whose trees meet in a directory without
/// sharing a single filename. `mine` carries `nested/notes.md` and the
/// second selection is destined for `mine/nested`, so neither writes a
/// path the other writes and one skill's file would still end up sitting
/// in the other skill's directory, with the outcome reporting both as
/// copied cleanly.
#[test]
#[allow(clippy::unwrap_used)]
fn two_selections_whose_trees_meet_refuse_and_write_nothing() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    let nested = root
        .join(crate::source::LOCAL_SOURCE_DIR)
        .join("skills/mine/nested");
    fs::create_dir_all(&nested).unwrap();
    fs::write(nested.join("notes.md"), "the parent tree's own file").unwrap();
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-overlap");
    let candidates = inventory(&env, &scopes).unwrap();
    let mut under = selection(find(&candidates, "stray"), false);
    under.destination = "mine/nested".to_owned();
    let selections = [selection(find(&candidates, "mine"), false), under];

    let message = apply(&env, &scopes, &target, &selections)
        .unwrap_err()
        .to_string();
    assert!(message.contains("both land at"), "{message}");
    assert!(message.contains("mine/nested"), "it names both: {message}");
    assert!(
        !target.join("skills").exists(),
        "a refused apply writes nothing at all"
    );
}

/// Every refusal is decided before the first byte is written, so a
/// second selection that cannot land takes the first one with it. Without
/// that the import is half-done and there is nothing to say which half.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refusal_on_a_later_selection_writes_nothing_for_the_earlier_one() {
    let (tmp, env, scope) = seeded();
    let scopes = [scope];
    let target = target(&env, &tmp, "mine-partial");
    // The second selection's destination is occupied by other bytes.
    skill(
        &target.join("skills"),
        "stray",
        "different bytes already here",
    );
    let candidates = inventory(&env, &scopes).unwrap();
    let selections = [
        selection(find(&candidates, "mine"), false),
        selection(find(&candidates, "stray"), false),
    ];

    let refused = apply(&env, &scopes, &target, &selections);
    let message = refused.unwrap_err().to_string();
    assert!(message.contains("different bytes"), "{message}");
    assert!(
        !target.join("skills/mine").exists(),
        "the selection before the refusal must not have been written"
    );
    assert!(
        fs::read_to_string(target.join("skills/stray/SKILL.md"))
            .unwrap()
            .contains("different bytes already here"),
        "the occupied destination is untouched"
    );
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
        root.join(crate::source::LOCAL_SOURCE_DIR)
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

/// A skill adopted in place: its bytes live under the project's shared
/// `.agents` tree, and the owned row reads from there — before KEN-700 the
/// read went to the local source, found nothing, and the only claim left
/// was whatever an unlocked harness happened to observe.
#[test]
#[allow(clippy::unwrap_used)]
fn an_in_place_skill_is_an_own_candidate_read_from_its_tree() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let project = tmp.path().join("app");
    skill(&project.join(".agents/skills"), "here", "in place bytes");
    fs::write(
        project.join("kendex.toml"),
        "schema = 6\n[skills.here]\nsource = \"in-place\"\n",
    )
    .unwrap();
    let project = project.canonicalize().unwrap();
    let scope = Scope::Project { root: project };
    let mut lock = Lock {
        version: crate::lock::LOCK_VERSION,
        ..Lock::default()
    };
    lock.entries.insert(
        crate::lock::entry_key(ItemKind::Skill, "here", HarnessId::Claude),
        entry(ItemKind::Skill, "here", "in-place", ""),
    );
    crate::lock::save(&crate::lock::lock_path(&env, &scope), &lock).unwrap();

    let rows = crate::library::provenance(&env, std::slice::from_ref(&scope)).unwrap();
    let own_row = rows
        .iter()
        .find(|r| r.name == "here" && matches!(r.origin, crate::library::Origin::Own { .. }))
        .unwrap_or_else(|| panic!("no own row: {rows:?}"));
    let reads = origins_of(&env, own_row, &BTreeMap::new());
    let [(group, bytes, location, _)] = reads.as_slice() else {
        panic!("one owned read expected, got {}", reads.len());
    };
    assert!(matches!(group, CandidateGroup::Own));
    assert!(bytes.is_some());
    assert!(location.contains(".agents/skills/here"), "{location}");

    // The candidate the wizard lists carries those bytes, so the skill is
    // importable; identical observed claims may still govern its group.
    let candidates = inventory(&env, &[scope]).unwrap();
    let here = find(&candidates, "here");
    assert!(here.origins.iter().any(|o| !o.hash.is_empty()));
}
