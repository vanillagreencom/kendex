use super::*;
use crate::lock::{BundleRef, InstallRef, LockEntry};
use crate::manifest::{ItemDecl, SourceDecl};
use crate::model::HarnessId;

fn manifest_with(items: &[(&str, Option<&str>)], bundles: &[&str]) -> Manifest {
    let mut manifest = Manifest::default();
    manifest.sources.insert(
        "cat".to_owned(),
        SourceDecl {
            repo: Some("owner/catalog".to_owned()),
            enabled: true,
            ..SourceDecl::default()
        },
    );
    for (name, rev) in items {
        let mut decl = ItemDecl::from_source("cat");
        decl.rev = rev.map(str::to_owned);
        manifest
            .declared_mut(ItemKind::Skill)
            .insert((*name).to_owned(), decl);
    }
    for name in bundles {
        manifest
            .bundles
            .insert((*name).to_owned(), ItemDecl::from_source("cat"));
    }
    manifest
}

/// [`held_manifest`] for one target, which is what every case below
/// names. A set of them is covered end to end in `package_pins`.
fn held_for(manifest: &Manifest, lock: &Lock, kind: ItemKind, name: &str) -> (Manifest, HeldPins) {
    held_manifest(manifest, lock, &BTreeSet::from([(kind, name.to_owned())]))
}

fn entry_from(
    name: &str,
    commit: Option<&str>,
    reasons: &[Reason],
    source: &str,
    source_repo: &str,
) -> LockEntry {
    LockEntry {
        source: source.to_owned(),
        source_repo: source_repo.to_owned(),
        ..entry(name, commit, reasons)
    }
}

fn entry(name: &str, commit: Option<&str>, reasons: &[Reason]) -> LockEntry {
    LockEntry {
        name: name.to_owned(),
        kind: ItemKind::Skill,
        harness: HarnessId::Claude,
        source: "cat".to_owned(),
        source_repo: "owner/catalog".to_owned(),
        method: crate::manifest::Method::Copy,
        installed_at: "2026-01-01T00:00:00Z".to_owned(),
        source_hash: "x".to_owned(),
        source_commit: commit.map(str::to_owned),
        rendered_hash: None,
        enabled: true,
        upstream_skills: None,
        emitted: None,
        registration: None,
        reasons: reasons.iter().cloned().collect(),
    }
}

fn lock_with(entries: &[(&str, LockEntry)]) -> Lock {
    let mut lock = Lock::default();
    for (key, entry) in entries {
        lock.entries.insert((*key).to_owned(), entry.clone());
    }
    lock
}

/// A set's record: where it came out as, in the catalog the fixtures
/// declare. The only account of where a set sits — its members carry
/// their own commits and say nothing about the set's, so both sets below
/// carry one and the assertions turn on which of them holds, never on
/// which of them has a record at all.
fn recorded_set(lock: &mut Lock, name: &str, commit: &str) {
    lock.bundles.insert(
        name.to_owned(),
        crate::lock::BundleRev {
            source: "cat".to_owned(),
            source_repo: "owner/catalog".to_owned(),
            commit: commit.to_owned(),
        },
    );
}

#[test]
fn siblings_pin_at_their_commit_and_the_target_stays_free() {
    let manifest = manifest_with(&[("a", None), ("b", None), ("held", Some("fff"))], &[]);
    let lock = lock_with(&[
        (
            "skill:a:claude",
            entry("a", Some("aaa"), &[Reason::Requested]),
        ),
        (
            "skill:b:claude",
            entry("b", Some("bbb"), &[Reason::Requested]),
        ),
    ]);

    let (held, pins) = held_for(&manifest, &lock, ItemKind::Skill, "a");
    let rev = |name: &str| held.declared(ItemKind::Skill)[name].rev.clone();
    assert_eq!(rev("a"), None, "the target resolves fresh");
    assert_eq!(rev("b"), Some("bbb".to_owned()), "the sibling holds");
    assert_eq!(rev("held"), Some("fff".to_owned()), "a user pin is kept");

    let mut written = held.clone();
    pins.unpin(&mut written);
    assert_eq!(
        written, manifest,
        "unpinning restores the manifest exactly — a written manifest never carries a synthetic hold"
    );
}

#[test]
fn a_derived_targets_bundle_is_exempt_and_a_stranger_bundle_holds() {
    let manifest = manifest_with(&[], &["kit", "other"]);
    let of = |bundle: &str| Reason::MemberOf {
        bundle: BundleRef {
            source: "cat".to_owned(),
            name: bundle.to_owned(),
        },
    };
    let mut lock = lock_with(&[
        ("skill:m1:claude", entry("m1", Some("aaa"), &[of("kit")])),
        ("skill:o1:claude", entry("o1", Some("bbb"), &[of("other")])),
    ]);
    recorded_set(&mut lock, "kit", "aaa");
    recorded_set(&mut lock, "other", "bbb");

    let (held, _) = held_for(&manifest, &lock, ItemKind::Skill, "m1");
    assert_eq!(
        held.bundles["kit"].rev, None,
        "the bundle carrying the target owns its revision, so it resolves fresh"
    );
    assert_eq!(
        held.bundles["other"].rev,
        Some("bbb".to_owned()),
        "a bundle the target has nothing to do with holds at its recorded commit"
    );
}

#[test]
fn a_lock_that_cannot_place_a_package_pins_nothing_for_it() {
    let manifest = manifest_with(&[("a", None), ("fresh", None), ("mixed", None)], &[]);
    let lock = lock_with(&[
        (
            "skill:a:claude",
            entry("a", Some("aaa"), &[Reason::Requested]),
        ),
        (
            "skill:mixed:claude",
            entry("mixed", Some("aaa"), &[Reason::Requested]),
        ),
        (
            "skill:mixed:codex",
            entry("mixed", Some("bbb"), &[Reason::Requested]),
        ),
    ]);

    let (held, _) = held_for(&manifest, &lock, ItemKind::Skill, "a");
    let rev = |name: &str| held.declared(ItemKind::Skill)[name].rev.clone();
    assert_eq!(rev("fresh"), None, "nothing installed, nothing to hold at");
    assert_eq!(rev("mixed"), None, "disagreeing installs invent no pin");
}

#[test]
fn installations_from_somewhere_else_pin_nothing() {
    let mut manifest = manifest_with(&[("a", None), ("rebound", None), ("regrouped", None)], &[]);
    manifest.sources.insert(
        "other".to_owned(),
        SourceDecl {
            repo: Some("owner/other".to_owned()),
            enabled: true,
            ..SourceDecl::default()
        },
    );
    // `regrouped` reads from a second catalog now; `rebound`'s own
    // catalog is the one that moved repositories under it.
    manifest
        .declared_mut(ItemKind::Skill)
        .get_mut("regrouped")
        .unwrap()
        .source = "other".to_owned();
    let lock = lock_with(&[
        (
            "skill:a:claude",
            entry("a", Some("aaa"), &[Reason::Requested]),
        ),
        (
            "skill:rebound:claude",
            entry_from(
                "rebound",
                Some("bbb"),
                &[Reason::Requested],
                "cat",
                "owner/was-here",
            ),
        ),
        (
            "skill:regrouped:claude",
            entry_from(
                "regrouped",
                Some("ccc"),
                &[Reason::Requested],
                "cat",
                "owner/catalog",
            ),
        ),
    ]);

    let (held, _) = held_for(&manifest, &lock, ItemKind::Skill, "a");
    let rev = |name: &str| held.declared(ItemKind::Skill)[name].rev.clone();
    assert_eq!(
        rev("rebound"),
        None,
        "a commit recorded against another repository is not this source's history"
    );
    assert_eq!(
        rev("regrouped"),
        None,
        "a declaration rebound to another source is not held at the old one's commit"
    );
}

#[test]
fn a_source_with_no_repository_is_never_pinned() {
    let mut manifest = manifest_with(&[("a", None), ("mine", None), ("part", None)], &[]);
    manifest.sources.insert(
        "here".to_owned(),
        SourceDecl {
            path: Some("/srv/catalog".to_owned()),
            enabled: true,
            ..SourceDecl::default()
        },
    );
    for name in ["mine", "part"] {
        manifest
            .declared_mut(ItemKind::Skill)
            .get_mut(name)
            .unwrap()
            .source = "here".to_owned();
    }
    let lock = lock_with(&[
        (
            "skill:a:claude",
            entry("a", Some("aaa"), &[Reason::Requested]),
        ),
        (
            "skill:mine:claude",
            entry_from(
                "mine",
                Some("bbb"),
                &[Reason::Requested],
                "here",
                "/srv/catalog",
            ),
        ),
        // Installed from the same path source, with no commit recorded
        // at all — the arm that has nothing to agree on.
        (
            "skill:part:claude",
            entry_from("part", None, &[Reason::Requested], "here", "/srv/catalog"),
        ),
    ]);

    let (held, pins) = held_for(&manifest, &lock, ItemKind::Skill, "a");
    let rev = |name: &str| held.declared(ItemKind::Skill)[name].rev.clone();
    assert_eq!(
        rev("mine"),
        None,
        "a path source has no revisions — pinning one refuses the whole plan"
    );
    assert_eq!(rev("part"), None, "an entry with no commit holds nothing");
    assert!(
        pins.items.is_empty(),
        "and nothing was recorded as a synthetic pin to take back out"
    );
}

/// A package installed from two places at once — one copy still recorded
/// against the source it was installed from, another already re-applied
/// from the one it reads now — has no one commit this source can hold it
/// at. Deciding over the entries that match and ignoring the rest reads
/// the survivor as agreement and pins the package there, which moves the
/// other copy to a commit out of a history it was never installed from.
#[test]
fn a_package_installed_from_two_places_pins_nothing() {
    let mut manifest = manifest_with(&[("a", None), ("mixed", None), ("moved", None)], &[]);
    manifest.sources.insert(
        "other".to_owned(),
        SourceDecl {
            repo: Some("owner/other".to_owned()),
            enabled: true,
            ..SourceDecl::default()
        },
    );
    let lock = lock_with(&[
        (
            "skill:a:claude",
            entry("a", Some("aaa"), &[Reason::Requested]),
        ),
        // One copy from the source this declaration reads now, one still
        // recorded against the alias it was installed under.
        (
            "skill:mixed:claude",
            entry("mixed", Some("bbb"), &[Reason::Requested]),
        ),
        (
            "skill:mixed:codex",
            entry_from(
                "mixed",
                Some("bbb"),
                &[Reason::Requested],
                "other",
                "owner/other",
            ),
        ),
        // The same shape through the repository behind one alias.
        (
            "skill:moved:claude",
            entry("moved", Some("ccc"), &[Reason::Requested]),
        ),
        (
            "skill:moved:codex",
            entry_from(
                "moved",
                Some("ccc"),
                &[Reason::Requested],
                "cat",
                "owner/was-here",
            ),
        ),
    ]);

    let (held, _) = held_for(&manifest, &lock, ItemKind::Skill, "a");
    let rev = |name: &str| held.declared(ItemKind::Skill)[name].rev.clone();
    assert_eq!(
        rev("mixed"),
        None,
        "an installation under another source alias is not this source's to hold"
    );
    assert_eq!(
        rev("moved"),
        None,
        "nor one recorded against another repository behind the same alias"
    );
    assert_eq!(rev("a"), None, "the target resolves fresh either way");
}

/// A rebind leaves the lock holding entries from the source a package was
/// installed from and from the one it reads now. Following those edges by
/// name alone reaches the wrong parent — a declaration this scope still
/// reads, exempted from holding on the strength of an installation that
/// has nothing to do with it, and moved along with everything it carries.
#[test]
fn an_edge_recorded_against_another_source_exempts_nothing() {
    let mut manifest = manifest_with(&[("parent", None), ("dep", None)], &["kit"]);
    manifest.sources.insert(
        "old".to_owned(),
        SourceDecl {
            repo: Some("owner/old".to_owned()),
            enabled: true,
            ..SourceDecl::default()
        },
    );
    // The dependency reads from the catalog it was moved to; the parent
    // and the set are still the ones this scope declares.
    manifest
        .declared_mut(ItemKind::Skill)
        .get_mut("dep")
        .unwrap()
        .source = "old".to_owned();

    let by_old_parent = Reason::RequiredBy {
        by: InstallRef {
            source: "old".to_owned(),
            kind: ItemKind::Skill,
            name: "parent".to_owned(),
            harness: HarnessId::Claude,
        },
    };
    let of_old_kit = Reason::MemberOf {
        bundle: BundleRef {
            source: "old".to_owned(),
            name: "kit".to_owned(),
        },
    };
    let mut lock = lock_with(&[
        (
            "skill:parent:claude",
            entry("parent", Some("ppp"), &[Reason::Requested]),
        ),
        (
            "skill:member:claude",
            entry(
                "member",
                Some("mmm"),
                &[Reason::MemberOf {
                    bundle: BundleRef {
                        source: "cat".to_owned(),
                        name: "kit".to_owned(),
                    },
                }],
            ),
        ),
        // The target, still recorded under the source it came from, with
        // edges naming that source's parent and that source's set.
        (
            "skill:dep:claude",
            entry_from(
                "dep",
                Some("ddd"),
                &[by_old_parent, of_old_kit],
                "old",
                "owner/old",
            ),
        ),
    ]);
    recorded_set(&mut lock, "kit", "mmm");

    let (held, _) = held_for(&manifest, &lock, ItemKind::Skill, "dep");
    assert_eq!(
        held.declared(ItemKind::Skill)["parent"].rev,
        Some("ppp".to_owned()),
        "a parent this scope reads is not exempted by an edge recorded against another source"
    );
    assert_eq!(
        held.bundles["kit"].rev,
        Some("mmm".to_owned()),
        "nor is a set of the same name in another catalog"
    );
    assert_eq!(
        held.declared(ItemKind::Skill)["dep"].rev,
        None,
        "and the package asked for still resolves fresh"
    );
}

/// The same class from the other end: an installation a rebind left behind
/// is an installation of a package the declaration no longer is, so the
/// edges it records are not this update's to follow. Seeding the exemption
/// off every entry that shares the name walks them anyway and unpins
/// whatever they lead to.
#[test]
fn a_left_behind_installation_of_the_target_exempts_nothing() {
    let mut manifest = manifest_with(&[("parent", None), ("dep", None)], &[]);
    manifest.sources.insert(
        "old".to_owned(),
        SourceDecl {
            repo: Some("owner/old".to_owned()),
            enabled: true,
            ..SourceDecl::default()
        },
    );
    manifest
        .declared_mut(ItemKind::Skill)
        .get_mut("dep")
        .unwrap()
        .source = "old".to_owned();

    let by_cat_parent = Reason::RequiredBy {
        by: InstallRef {
            source: "cat".to_owned(),
            kind: ItemKind::Skill,
            name: "parent".to_owned(),
            harness: HarnessId::Claude,
        },
    };
    let lock = lock_with(&[
        (
            "skill:parent:claude",
            entry("parent", Some("ppp"), &[Reason::Requested]),
        ),
        // What the declaration reads now.
        (
            "skill:dep:claude",
            entry_from("dep", Some("ddd"), &[Reason::Requested], "old", "owner/old"),
        ),
        // And the copy the rebind left, still under the old catalog's
        // parent.
        (
            "skill:dep:codex",
            entry("dep", Some("ccc"), &[by_cat_parent]),
        ),
    ]);

    let (held, _) = held_for(&manifest, &lock, ItemKind::Skill, "dep");
    assert_eq!(
        held.declared(ItemKind::Skill)["parent"].rev,
        Some("ppp".to_owned()),
        "the parent of an installation this declaration no longer has stays held"
    );
    assert_eq!(
        held.declared(ItemKind::Skill)["dep"].rev,
        None,
        "and the package asked for still resolves fresh"
    );
}
