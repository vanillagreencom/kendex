//! Review-driven pins: strictest-provenance merge, the edited-copy
//! choice, licence evidence, cross-selection collisions, and the
//! origin-overlap refusal.

use std::fs;

use super::{entry, find, seeded, selection, skill, target};
use crate::author::import::{CandidateGroup, ImportSelection, apply, inventory};
use crate::error::CoreError;
use crate::model::{HarnessId, ItemKind, Scope};

/// One name offered by two provenances with identical bytes is one origin
/// under the *strictest* group — equal bytes can never dodge the licence
/// gate by also existing as "your own".
#[test]
#[allow(clippy::unwrap_used)]
fn identical_bytes_merge_under_the_strictest_provenance() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    // The same gh bytes, in the local source, installed for a second
    // harness from `local`.
    skill(
        &root.join(crate::source::LOCAL_SOURCE_DIR).join("skills"),
        "gh",
        "market bytes",
    );
    let lock_path = crate::lock::lock_path(&env, &scope);
    let mut lock = match crate::lock::load_file(&lock_path).unwrap() {
        crate::lock::LockFile::Current(lock) => lock,
        _ => unreachable!(),
    };
    let mut own = entry(ItemKind::Skill, "gh", "local", "local");
    own.harness = HarnessId::Codex;
    lock.entries.insert(
        crate::lock::entry_key(ItemKind::Skill, "gh", HarnessId::Codex),
        own,
    );
    crate::lock::save(&lock_path, &lock).unwrap();

    let scopes = [scope.clone()];
    let candidates = inventory(&env, &scopes).unwrap();
    let gh = find(&candidates, "gh");
    assert_eq!(gh.origins.len(), 1, "{:?}", gh.origins);
    assert!(
        matches!(gh.origins[0].group, CandidateGroup::Marketplace { .. }),
        "the marketplace provenance must govern the merged origin"
    );
    assert!(gh.origins[0].locations.len() >= 2, "{:?}", gh.origins);

    // And the gate still applies to the merged origin.
    let target = target(&env, &tmp, "mine-merge");
    let refused = apply(&env, &scopes, &target, &[selection(gh, false)]);
    assert!(refused.is_err());
}

/// An installed marketplace package whose bytes diverged shows both
/// copies: the original and "your edited copy", each selectable.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edited_install_shows_beside_the_marketplace_original() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    skill(&root.join(".claude/skills"), "gh", "my edited bytes");
    let scopes = [scope.clone()];
    let candidates = inventory(&env, &scopes).unwrap();
    let gh = find(&candidates, "gh");
    assert_eq!(gh.origins.len(), 2, "{:?}", gh.origins);
    let edited = gh
        .origins
        .iter()
        .find(|origin| matches!(origin.group, CandidateGroup::Edited { .. }))
        .unwrap();

    // The edited copy carries the same licence duty as the original.
    let target = target(&env, &tmp, "mine-edited");
    let chosen = ImportSelection {
        kind: ItemKind::Skill,
        name: "gh".to_owned(),
        destination: "gh".to_owned(),
        hash: edited.hash.clone(),
        license_confirmed: false,
        license_basis: None,
    };
    assert!(apply(&env, &scopes, &target, std::slice::from_ref(&chosen)).is_err());
    let confirmed = ImportSelection {
        license_confirmed: true,
        ..chosen
    };
    let outcome = apply(&env, &scopes, &target, &[confirmed]).unwrap();
    assert!(outcome.written.contains(&"skills/gh".to_owned()));
    let copied = fs::read_to_string(target.join("skills/gh/SKILL.md")).unwrap();
    assert!(copied.contains("my edited bytes"));
}

/// A licence kendex does not recognize as redistributable cannot be
/// checkbox-confirmed — it needs a stated basis, like no licence at all.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unrecognized_licence_cannot_be_confirmed_away() {
    let (tmp, env, scope) = seeded();
    fs::write(
        tmp.path().join("catalog/kendex.toml"),
        "[marketplace]\nname = \"cat\"\nlicense = \"All-Rights-Reserved\"\n",
    )
    .unwrap();
    let scopes = [scope];
    let target = target(&env, &tmp, "mine-prop");
    let candidates = inventory(&env, &scopes).unwrap();
    let gh = find(&candidates, "gh");

    let confirmed = selection(gh, true);
    let refused = apply(&env, &scopes, &target, std::slice::from_ref(&confirmed))
        .unwrap_err()
        .to_string();
    assert!(refused.contains("does not recognize"), "{refused}");

    let with_basis = ImportSelection {
        license_basis: Some("the author granted me permission in writing".to_owned()),
        ..confirmed
    };
    apply(&env, &scopes, &target, &[with_basis]).unwrap();
}

/// Two selections folding to one destination refuse before any write.
#[test]
#[allow(clippy::unwrap_used)]
fn two_selections_on_one_destination_refuse_up_front() {
    let (tmp, env, scope) = seeded();
    let scopes = [scope];
    let target = target(&env, &tmp, "mine-dup");
    let candidates = inventory(&env, &scopes).unwrap();
    let mut first = selection(find(&candidates, "mine"), false);
    let mut second = selection(find(&candidates, "stray"), false);
    first.destination = "Same-Name".to_owned();
    second.destination = "same-name".to_owned();
    let refused = apply(&env, &scopes, &target, &[first, second])
        .unwrap_err()
        .to_string();
    assert!(refused.contains("both land at"), "{refused}");
    assert!(!target.join("skills/Same-Name").exists());
}

/// Marketplace-origin copies carry the catalog's licence evidence with
/// them, under NOTICES/<source>/.
#[test]
#[allow(clippy::unwrap_used)]
fn licence_evidence_files_travel_with_the_copy() {
    let (tmp, env, scope) = seeded();
    fs::write(tmp.path().join("catalog/LICENSE"), "MIT text here\n").unwrap();
    let scopes = [scope];
    let target = target(&env, &tmp, "mine-notice");
    let candidates = inventory(&env, &scopes).unwrap();
    let gh = find(&candidates, "gh");
    let outcome = apply(&env, &scopes, &target, &[selection(gh, true)]).unwrap();
    assert!(
        outcome
            .written
            .iter()
            .any(|written| written.contains("NOTICES")),
        "{outcome:?}"
    );
    let notice = fs::read_to_string(target.join("NOTICES/cat/LICENSE")).unwrap();
    assert_eq!(notice, "MIT text here\n");
}

/// A catalog whose root will not be listed carries no evidence this can
/// see, and a copy made anyway would take somebody's bytes and leave their
/// licence behind. Every other listing answers an unreadable directory by
/// drawing no rows; this one refuses, because there is no surface for the
/// person to notice the omission on.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_catalog_that_will_not_be_listed_refuses_rather_than_copying_bare() {
    use std::os::unix::fs::PermissionsExt;
    let (tmp, env, scope) = seeded();
    let catalog = tmp.path().join("catalog");
    fs::write(catalog.join("LICENSE"), "MIT text here\n").unwrap();
    let scopes = [scope];
    let target = target(&env, &tmp, "mine-unreadable");
    let candidates = inventory(&env, &scopes).unwrap();
    let gh = find(&candidates, "gh");
    let chosen = selection(gh, true);

    fs::set_permissions(&catalog, fs::Permissions::from_mode(0o311)).unwrap();
    // Root lists any directory whatever its mode, so there the denial under
    // test does not exist and the evidence simply travels.
    let denied = !rustix::process::geteuid().is_root();
    let asked = apply(&env, &scopes, &target, &[chosen]);
    fs::set_permissions(&catalog, fs::Permissions::from_mode(0o755)).unwrap();

    match denied {
        true => assert!(matches!(asked, Err(CoreError::Io { .. })), "{asked:?}"),
        false => assert!(asked.is_ok(), "{asked:?}"),
    }
}

/// A symlinked LICENSE is the same loss with no permissions in it. The
/// sealed reader refuses to look through a link inside a source, and read
/// as a boolean that refusal says "no file here" — so the entry is passed
/// over and the package is copied with its notice left behind.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_symlinked_licence_refuses_rather_than_copying_bare() {
    let (tmp, env, scope) = seeded();
    let elsewhere = tmp.path().join("LICENSE-real");
    fs::write(&elsewhere, "MIT text here\n").unwrap();
    std::os::unix::fs::symlink(&elsewhere, tmp.path().join("catalog/LICENSE")).unwrap();
    let scopes = [scope];
    let target = target(&env, &tmp, "mine-linked-licence");
    let candidates = inventory(&env, &scopes).unwrap();
    let gh = find(&candidates, "gh");

    let asked = apply(&env, &scopes, &target, &[selection(gh, true)]);
    assert!(
        matches!(asked, Err(CoreError::SourceEscape { .. })),
        "{asked:?}"
    );
    // The refusal is what stopped the copy, not something after it: read
    // as a boolean the same probe lets this through, and the package lands
    // with no NOTICES beside it.
    assert!(
        !target.join("skills/gh").exists(),
        "the bytes were copied before the evidence was found missing"
    );
}

/// A licence file whose name is bytes no UTF-8 spells. On Linux that is
/// an ordinary filename, and both halves of the read meet it: the stem is
/// matched on the lossy spelling, so `LICENSE.<invalid>` is seen as the
/// evidence it is rather than passed over, and the name cannot be written
/// at the destination, so the copy refuses rather than going out without
/// it. Read either way round it is the same harm — a package published
/// with somebody's licence left behind.
///
/// What this needs is a filesystem that will hold such a name, which is
/// narrower than a platform: macOS enforces UTF-8 at the filesystem layer
/// and refuses to create one at all, so the case cannot build its own
/// precondition there. Compiled out where it cannot run rather than
/// skipped inside a passing run, because a skip reported as a pass is how
/// a case stops covering anything without saying so.
#[cfg(target_os = "linux")]
#[test]
#[allow(clippy::unwrap_used)]
fn a_licence_name_no_utf8_spells_refuses_rather_than_copying_bare() {
    use std::os::unix::ffi::OsStrExt;
    let (tmp, env, scope) = seeded();
    let odd = std::ffi::OsStr::from_bytes(b"LICENSE.\xff");
    // The precondition, said rather than unwrapped: a filesystem that
    // will not hold the name is the one thing that makes this case
    // meaningless, so it names itself rather than panicking on a line
    // that reads like setup.
    fs::write(tmp.path().join("catalog").join(odd), "MIT text here\n").unwrap_or_else(|error| {
        panic!("this filesystem will not hold a non-UTF-8 name, which the case needs: {error}")
    });
    let scopes = [scope];
    let target = target(&env, &tmp, "mine-odd-licence");
    let candidates = inventory(&env, &scopes).unwrap();
    let gh = find(&candidates, "gh");

    let asked = apply(&env, &scopes, &target, &[selection(gh, true)]);
    assert!(
        matches!(asked, Err(CoreError::SourceEscape { .. })),
        "{asked:?}"
    );
    assert!(
        !target.join("skills/gh").exists(),
        "the bytes were copied before the evidence was found unreadable"
    );
}

/// And the same for one evidence file the catalog will not hand over. The
/// directory lists, so the licence is known to be there and known not to
/// have travelled — copying the bytes anyway is the harm this refusal
/// exists to stop, said about one file rather than the whole root.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_licence_file_that_cannot_be_read_refuses_rather_than_copying_bare() {
    use std::os::unix::fs::PermissionsExt;
    let (tmp, env, scope) = seeded();
    let licence = tmp.path().join("catalog/LICENSE");
    fs::write(&licence, "MIT text here\n").unwrap();
    let scopes = [scope];
    let target = target(&env, &tmp, "mine-unreadable-licence");
    let candidates = inventory(&env, &scopes).unwrap();
    let gh = find(&candidates, "gh");
    let chosen = selection(gh, true);

    fs::set_permissions(&licence, fs::Permissions::from_mode(0o000)).unwrap();
    // Root reads any file whatever its mode, so there the denial under
    // test does not exist and the evidence simply travels.
    let denied = !rustix::process::geteuid().is_root();
    let asked = apply(&env, &scopes, &target, &[chosen]);
    fs::set_permissions(&licence, fs::Permissions::from_mode(0o644)).unwrap();

    match denied {
        true => assert!(matches!(asked, Err(CoreError::Io { .. })), "{asked:?}"),
        false => assert!(asked.is_ok(), "{asked:?}"),
    }
}

/// The target must not sit inside a tree the bytes come from.
#[test]
#[allow(clippy::unwrap_used)]
fn a_target_inside_an_origin_tree_is_refused() {
    let (tmp, env, scope) = seeded();
    let Scope::Project { root } = &scope else {
        unreachable!()
    };
    // Register the observed skill's own directory as the "marketplace".
    let inside = root.join(".claude/skills/stray");
    crate::author::registry::register(&env, &inside).unwrap();
    let _ = tmp;
    let scopes = [scope.clone()];
    let candidates = inventory(&env, &scopes).unwrap();
    let stray = find(&candidates, "stray");
    let refused = apply(
        &env,
        &scopes,
        &inside.canonicalize().unwrap(),
        &[selection(stray, false)],
    )
    .unwrap_err()
    .to_string();
    assert!(refused.contains("own origin"), "{refused}");
}
