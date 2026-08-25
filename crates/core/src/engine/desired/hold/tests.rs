use super::*;
use crate::lock::{BundleRef, LockEntry};
use crate::manifest::{ItemDecl, SourceDecl};
use crate::model::{HarnessId, Scope};

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
        left_pi_reserved_name: false,
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

    let (held, pins) = held_manifest(&manifest, &lock, &(ItemKind::Skill, "a".to_owned()));
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
            scope: Scope::Global,
        },
    };
    let lock = lock_with(&[
        ("skill:m1:claude", entry("m1", Some("aaa"), &[of("kit")])),
        ("skill:o1:claude", entry("o1", Some("bbb"), &[of("other")])),
    ]);

    let (held, _) = held_manifest(&manifest, &lock, &(ItemKind::Skill, "m1".to_owned()));
    assert_eq!(
        held.bundles["kit"].rev, None,
        "the bundle carrying the target owns its revision, so it resolves fresh"
    );
    assert_eq!(
        held.bundles["other"].rev,
        Some("bbb".to_owned()),
        "a bundle the target has nothing to do with holds at its members' commit"
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

    let (held, _) = held_manifest(&manifest, &lock, &(ItemKind::Skill, "a".to_owned()));
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

    let (held, _) = held_manifest(&manifest, &lock, &(ItemKind::Skill, "a".to_owned()));
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

    let (held, pins) = held_manifest(&manifest, &lock, &(ItemKind::Skill, "a".to_owned()));
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

    let (held, _) = held_manifest(&manifest, &lock, &(ItemKind::Skill, "a".to_owned()));
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
