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

/// A skill whose SKILL.md is whatever the caller says, for the shapes the
/// `skill` helper cannot spell.
#[allow(clippy::unwrap_used)]
fn raw_skill(dir: &Path, name: &str, skill_md: &str) {
    let skill = dir.join(name);
    fs::create_dir_all(&skill).unwrap();
    fs::write(skill.join("SKILL.md"), skill_md).unwrap();
}

/// One item that is a file rather than a tree, at the extension its kind
/// is stored under.
#[allow(clippy::unwrap_used)]
fn file_item(dir: &Path, file: &str, text: &str) {
    fs::create_dir_all(dir).unwrap();
    fs::write(dir.join(file), text).unwrap();
}

/// A project with all three origins: a marketplace skill (path source with
/// a licence), the person's own local-source content, and unmanaged
/// content of three kinds.
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
    // A body file beside the declaration, because a skill is a tree and
    // only the file that declares the name may be rewritten. It carries no
    // frontmatter, so a rewrite reaching it refuses the whole import
    // rather than landing something subtly wrong.
    file_item(
        &project.join(".claude/skills/stray/references"),
        "notes.md",
        "Body file. No frontmatter here.\n",
    );
    // A tree no name can be written into, and two other kinds.
    raw_skill(
        &project.join(".claude/skills"),
        "bare",
        "No frontmatter at all.\n",
    );
    file_item(
        &project.join(".claude/agents"),
        "drifter.md",
        "---\nname: drifter\ndescription: about drifter\n---\nAgent body.\n",
    );
    file_item(
        &project.join(".claude/commands"),
        "note.md",
        "---\ndescription: a note\n---\nCommand body.\n",
    );
    let local = project.join(crate::source::LOCAL_SOURCE_DIR);
    skill(&local.join("skills"), "mine", "my own bytes");
    // A hook and an MCP server reach the wizard through a lock entry
    // pointing at the local source, which is an import candidate like any
    // other.
    file_item(
        &local.join("hooks"),
        "watcher.sh",
        "#!/bin/sh\n# ---\n# name: watcher\n# event: SessionStart\n# ---\necho watching\n",
    );
    file_item(
        &local.join("mcp"),
        "server.toml",
        "command = \"serve\"\nargs = []\n",
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
    for (kind, name, source, repo) in [
        (ItemKind::Skill, "gh", "cat", "cat"),
        (ItemKind::Skill, "mine", "local", "local"),
        (ItemKind::Hook, "watcher", "local", "local"),
        (ItemKind::McpServer, "server", "local", "local"),
    ] {
        lock.entries.insert(
            crate::lock::entry_key(kind, name, HarnessId::Claude),
            entry(kind, name, source, repo),
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

/// What the catalog check makes of what one import wrote, read as the
/// person's own marketplace: the items it found, and every breakage over
/// them. The count is half the answer — a check that read nothing reports
/// no breakage either.
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

/// A copy taken under a new name has to declare that name: a skill copied
/// verbatim under a renamed destination lands a SKILL.md calling it
/// something else, which the catalog check reports as breakage — run here
/// over what the import wrote, so this holds only as long as it does.
///
/// Both shapes: the flat rename, and the nested destination it was
/// reported against.
#[test]
#[allow(clippy::unwrap_used)]
fn a_renamed_skill_declares_its_destination_and_leaves_the_catalog_whole() {
    let (tmp, env, scope) = seeded();
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-renamed");
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

    let flat_md = fs::read_to_string(target.join("skills/renamed/SKILL.md")).unwrap();
    assert!(flat_md.contains("name: renamed"), "{flat_md}");
    assert!(
        flat_md.contains("unmanaged bytes") && flat_md.contains("description: about stray"),
        "only the name line changes: {flat_md}"
    );
    // The rest of the tree is a copy. A rewrite reaching a body file would
    // refuse the whole import — no frontmatter, no line to carry a name —
    // so a skill with a references/ directory could not be renamed at all.
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    assert_eq!(
        fs::read(target.join("skills/renamed/references/notes.md")).unwrap(),
        fs::read(root.join(".claude/skills/stray/references/notes.md")).unwrap(),
        "the tree's body files are copied, not declared",
    );
    let nested_md = fs::read_to_string(target.join("skills/group/deep/SKILL.md")).unwrap();
    assert!(nested_md.contains("name: deep"), "{nested_md}");

    let (items, breakage) = checked(&target);
    assert_eq!(items, 2, "the check read both imported trees");
    assert_eq!(breakage, Vec::<String>::new());

    // The bytes on disk are what the same selection would write again, so
    // a repeated import is already present rather than someone else's.
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

/// The rename is decided with every other refusal, before the first byte:
/// bytes no name can be written into refuse the whole apply rather than
/// land a copy that still answers to the old name.
#[test]
#[allow(clippy::unwrap_used)]
fn a_rename_no_declaration_can_carry_refuses_and_writes_nothing() {
    let (tmp, env, scope) = seeded();
    let scopes = [scope];
    let target = target(&env, &tmp, "mine-uncarried");
    let candidates = inventory(&env, &scopes).unwrap();
    let mut renamed = selection(find(&candidates, "bare"), false);
    renamed.destination = "clothed".to_owned();
    let selections = [selection(find(&candidates, "mine"), false), renamed];

    let message = apply(&env, &scopes, &target, &selections)
        .unwrap_err()
        .to_string();
    assert!(message.contains("it has no frontmatter"), "{message}");
    assert!(message.contains("'clothed'"), "{message}");
    assert!(
        message.contains("still call itself 'bare'"),
        "and what the copy would have answered to: {message}"
    );
    assert!(
        !target.join("skills").exists(),
        "a refused apply writes nothing at all"
    );
}

/// The refusal spells the names it quotes rather than replaying them. A
/// candidate name is read off a directory on disk, and the inventory keeps
/// illegal spellings so the wizard can offer them under a legal
/// destination — which is the path into this refusal. The name carries
/// U+202E, the right-to-left override that would let one package read as
/// another: the threat `names::shown` exists for, and, unlike a control
/// character, a filename every platform this runs on will create.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refusal_escapes_the_candidate_name_it_quotes() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    raw_skill(
        &root.join(".claude/skills"),
        "ba\u{202e}re",
        "No frontmatter at all.\n",
    );
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-escaped");
    let candidates = inventory(&env, &scopes).unwrap();
    let mut renamed = selection(find(&candidates, "ba\u{202e}re"), false);
    renamed.destination = "clothed".to_owned();

    let message = apply(&env, &scopes, &target, &[renamed])
        .unwrap_err()
        .to_string();
    assert!(message.contains("ba\\u{202e}re"), "{message}");
    assert!(!message.contains('\u{202e}'), "{message:?}");
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

/// Bytes that are not text carry no declaration either, and the refusal
/// says so rather than landing a copy whose name line is a replacement
/// character. A skill's tree is read as bytes, so nothing upstream has
/// asked whether its declaration is text.
#[test]
#[allow(clippy::unwrap_used)]
fn a_rename_of_bytes_that_are_not_text_refuses() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    let dir = root.join(".claude/skills/binary");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("SKILL.md"), [0xff, 0xfe, b'\n']).unwrap();
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-binary");
    let candidates = inventory(&env, &scopes).unwrap();
    let mut renamed = selection(find(&candidates, "binary"), false);
    renamed.destination = "textual".to_owned();
    // A selection that would have been written first, so the folder
    // staying empty is the refusal beating the copy rather than there
    // being nothing to copy.
    let selections = [selection(find(&candidates, "mine"), false), renamed];

    let message = apply(&env, &scopes, &target, &selections)
        .unwrap_err()
        .to_string();
    assert!(message.contains("the file is not text"), "{message}");
    assert!(
        !target.join("skills").exists(),
        "a refused apply writes nothing at all"
    );
}

/// What every other kind does under a rename, as a fixture rather than a
/// claim in a comment.
///
/// An agent's own file carries the name its tool answers to, so a renamed
/// agent declares its destination. The other three carry no name anything
/// keys on and are copied byte for byte.
///
/// All three are real candidates: a hook and an MCP server reach the
/// wizard through a lock entry pointing at the local source, which is how
/// they are seeded here.
#[test]
#[allow(clippy::unwrap_used)]
fn a_renamed_agent_declares_its_destination_and_the_name_less_kinds_are_copied_verbatim() {
    let (tmp, env, scope) = seeded();
    let scopes = [scope.clone()];
    let target = target(&env, &tmp, "mine-kinds");
    let candidates = inventory(&env, &scopes).unwrap();
    let renamed_to = |name: &str, destination: &str| {
        let mut chosen = selection(find(&candidates, name), false);
        chosen.destination = destination.to_owned();
        chosen
    };
    let selections = [
        renamed_to("drifter", "settled"),
        renamed_to("note", "memo"),
        renamed_to("watcher", "sentry"),
        renamed_to("server", "relay"),
    ];

    apply(&env, &scopes, &target, &selections).unwrap();

    let written = fs::read_to_string(target.join("agents/settled.md")).unwrap();
    assert!(written.contains("name: settled"), "{written}");
    assert!(
        written.contains("description: about drifter") && written.contains("Agent body."),
        "only the name line changes: {written}"
    );
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    let local = root.join(crate::source::LOCAL_SOURCE_DIR);
    for (landed, origin) in [
        ("commands/memo.md", root.join(".claude/commands/note.md")),
        ("hooks/sentry.sh", local.join("hooks/watcher.sh")),
        ("mcp/relay.toml", local.join("mcp/server.toml")),
    ] {
        assert_eq!(
            fs::read(target.join(landed)).unwrap(),
            fs::read(&origin).unwrap(),
            "{landed} is a copy, not a declaration",
        );
    }
}
