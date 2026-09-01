use super::*;

fn entry(name: &str, kind: ItemKind, source_repo: &str) -> LockEntry {
    LockEntry {
        name: name.to_owned(),
        kind,
        harness: crate::model::HarnessId::Claude,
        source: "kendex".to_owned(),
        source_repo: source_repo.to_owned(),
        method: crate::manifest::Method::Copy,
        installed_at: "2026-01-01T00:00:00Z".to_owned(),
        source_hash: "x".to_owned(),
        source_commit: None,
        rendered_hash: None,
        enabled: true,
        upstream_skills: None,
        emitted: None,
        registration: None,
        reasons: std::collections::BTreeSet::from([crate::lock::Reason::Requested]),
    }
}

fn lock_of(entries: &[(&str, ItemKind, &str)]) -> Lock {
    let mut lock = Lock::default();
    for (name, kind, source_repo) in entries {
        lock.entries.insert(
            format!("{}:{name}:{source_repo}", kind.name()),
            entry(name, *kind, source_repo),
        );
    }
    lock
}

/// The lock records provenance for every kind of asset alike, so a skill
/// recorded from the default repo routes upstream like an agent or hook.
#[test]
fn a_default_repo_entry_routes_upstream() {
    for (kind, label) in [
        (ItemKind::Hook, "harness"),
        (ItemKind::Skill, "skills"),
        (ItemKind::Agent, "skills"),
    ] {
        let lock = lock_of(&[("guard", kind, DEFAULT_UPSTREAM)]);
        let route = route(&lock, "guard", Some(kind), DEFAULT_UPSTREAM);
        assert!(route.kendex_owned, "{kind:?} from the default repo");
        assert_eq!(route.repo.as_deref(), Some(DEFAULT_UPSTREAM));
        assert_eq!(route.label.as_deref(), Some(label));
    }
}

/// Nothing in the lock says nothing about ownership, and the safe answer
/// is the user's own repo.
#[test]
fn an_unlocked_name_stays_project_local() {
    let route = route(&Lock::default(), "mystery", None, DEFAULT_UPSTREAM);
    assert!(!route.kendex_owned);
    assert_eq!(route.repo, None);
    assert_eq!(route.label, None);
}

/// A dated entry, the way the marker needs it: a commit and a
/// rendering the lock recorded.
fn dated(source_repo: &str, commit: &str, rendered: Option<&str>) -> LockEntry {
    let mut entry = entry("guard", ItemKind::Skill, source_repo);
    entry.source_commit = Some(commit.to_owned());
    entry.rendered_hash = rendered.map(str::to_owned);
    entry
}

/// The provenance a lock of these entries yields for `guard` the skill.
fn provenance_of(entries: &[(&str, LockEntry)]) -> Option<Provenance> {
    let mut lock = Lock::default();
    for (key, entry) in entries {
        lock.entries.insert((*key).to_owned(), entry.clone());
    }
    route(&lock, "guard", Some(ItemKind::Skill), DEFAULT_UPSTREAM).provenance
}

/// A report has to be datable against the fix that already landed, so
/// the route carries what the lock recorded: the repo and commit the
/// bytes came from, and what the apply wrote, both cut short. A lock
/// entry keeps the manifest's spelling of the repo, and the marker
/// carries the one a lookup takes.
#[test]
fn a_dated_entry_carries_its_recorded_provenance() {
    for spelling in [
        DEFAULT_UPSTREAM,
        "git@github.com:VanillaGreenCom/kendex.git",
        "https://github.com/vanillagreencom/kendex",
    ] {
        assert_eq!(
            provenance_of(&[(
                "skill",
                dated(spelling, "abc1234def5678", Some("9f8e7d6c5b4a"))
            )]),
            Some(Provenance {
                source: format!("{DEFAULT_UPSTREAM}@abc1234"),
                rendered: Some("9f8e7d6".to_owned()),
            }),
            "{spelling}"
        );
    }
}

/// A commit without a rendering still dates the report, and the
/// rendering it does not claim is the one on its own entry — an
/// undated sibling's rendering describes an install this report did
/// not come from.
#[test]
fn a_dated_entry_claims_only_its_own_rendering() {
    let mut undated = entry("guard", ItemKind::Skill, DEFAULT_UPSTREAM);
    undated.rendered_hash = Some("deadbee".to_owned());
    assert_eq!(
        provenance_of(&[
            ("a-undated", undated),
            ("b-dated", dated(DEFAULT_UPSTREAM, "abc1234def5678", None)),
        ]),
        Some(Provenance {
            source: format!("{DEFAULT_UPSTREAM}@abc1234"),
            rendered: None,
        })
    );
}

/// The lock keys an installation per harness, so one name is several
/// entries. Entries at two commits date nothing — a marker naming one
/// of them would close a live report against an install it did not
/// come from — while entries at one commit whose renderings differ
/// still date it, because a rendering is per harness.
#[test]
fn entries_that_disagree_date_nothing() {
    assert_eq!(
        provenance_of(&[
            (
                "claude",
                dated(DEFAULT_UPSTREAM, "abc1234def", Some("9f8e7d6"))
            ),
            (
                "codex",
                dated(DEFAULT_UPSTREAM, "fed4321cba", Some("9f8e7d6"))
            ),
        ]),
        None
    );
    assert_eq!(
        provenance_of(&[
            (
                "claude",
                dated(DEFAULT_UPSTREAM, "abc1234def", Some("9f8e7d6"))
            ),
            (
                "codex",
                dated(DEFAULT_UPSTREAM, "abc1234def", Some("1122334"))
            ),
        ]),
        Some(Provenance {
            source: format!("{DEFAULT_UPSTREAM}@abc1234"),
            rendered: None,
        })
    );
}

/// `--asset` names no kind, so entries of every kind match it. A name
/// whose entries disagree about their kind resolves to no kind, and
/// one kind's commit is not the other's date.
#[test]
fn a_kindless_ambiguous_name_dates_nothing() {
    let mut lock = Lock::default();
    lock.entries.insert(
        "skill".to_owned(),
        dated(DEFAULT_UPSTREAM, "abc1234def", None),
    );
    let mut hook = dated(DEFAULT_UPSTREAM, "abc1234def", None);
    hook.kind = ItemKind::Hook;
    lock.entries.insert("hook".to_owned(), hook);
    assert_eq!(route(&lock, "guard", None, DEFAULT_UPSTREAM).kind, None);
    assert_eq!(
        route(&lock, "guard", None, DEFAULT_UPSTREAM).provenance,
        None
    );
}

/// The lock is a file anyone can edit and the marker lands in a public
/// issue body, so only a value shaped like a hash reaches it: an empty
/// commit claims a date it does not carry, and one holding `-->` ends
/// the comment early. A rendering that fails the same check is absent
/// rather than fatal.
#[test]
fn a_value_that_is_no_hash_never_reaches_the_marker() {
    for commit in ["", "a--> hi", "abc1234\u{1b}[0m", "abc1234def56789 "] {
        assert_eq!(
            provenance_of(&[("skill", dated(DEFAULT_UPSTREAM, commit, Some("9f8e7d6")))]),
            None,
            "{commit:?}"
        );
    }
    assert_eq!(
        provenance_of(&[(
            "skill",
            dated(DEFAULT_UPSTREAM, "abc1234def", Some("--> hi"))
        )]),
        Some(Provenance {
            source: format!("{DEFAULT_UPSTREAM}@abc1234"),
            rendered: None,
        })
    );
}

/// A repo the marker cannot spell without breaking out of its own
/// comment is no source, and it does not leave a sibling standing as
/// the only date either.
#[test]
fn a_repo_that_is_no_reference_never_reaches_the_marker() {
    let unspellable = "gitlab.com/team/catalog -->";
    for spelling in [unspellable, ""] {
        assert_eq!(
            provenance_of(&[("skill", dated(spelling, "abc1234def", None))]),
            None,
            "{spelling:?}"
        );
    }
    assert_eq!(
        provenance_of(&[
            ("a-bad", dated(unspellable, "abc1234def", None)),
            ("b-good", dated(DEFAULT_UPSTREAM, "abc1234def", None)),
        ]),
        None
    );
}

/// An installation the lock never dated cannot be dated afterwards, and
/// a name it never recorded even less so: the route says nothing rather
/// than inventing a commit.
#[test]
fn an_undated_entry_has_no_provenance() {
    let lock = lock_of(&[("guard", ItemKind::Skill, DEFAULT_UPSTREAM)]);
    let recorded = route(&lock, "guard", Some(ItemKind::Skill), DEFAULT_UPSTREAM);
    assert_eq!(recorded.provenance, None);
    assert_eq!(
        route(&Lock::default(), "guard", None, DEFAULT_UPSTREAM).provenance,
        None
    );
}

/// A skill installed from another marketplace keeps filing against the
/// consumer's own repo.
#[test]
fn a_third_party_entry_stays_project_local() {
    let lock = lock_of(&[("guard", ItemKind::Skill, "someone/else")]);
    assert!(!route(&lock, "guard", Some(ItemKind::Skill), DEFAULT_UPSTREAM).kendex_owned);
}

/// A subscription spells its repo however it likes and the lock keeps
/// that spelling, so ownership compares folded identities: the scp-style
/// and `.git`-suffixed entries are the same repository as the shorthand,
/// and a `--upstream` spelled either way matches too. Another host with
/// the same path is another repository.
#[test]
fn a_differently_spelled_upstream_is_the_same_repository() {
    for spelling in [
        "git@github.com:vanillagreencom/kendex.git",
        "https://github.com/VanillaGreenCom/kendex",
        "vanillagreencom/kendex.git",
    ] {
        let lock = lock_of(&[("guard", ItemKind::Skill, spelling)]);
        let recorded = route(&lock, "guard", Some(ItemKind::Skill), DEFAULT_UPSTREAM);
        assert!(recorded.kendex_owned, "{spelling}");
        assert_eq!(recorded.label.as_deref(), Some("skills"), "{spelling}");

        // However the caller spells it, what comes back is what `gh
        // --repo` and an issue URL take.
        let named = route(&lock, "guard", Some(ItemKind::Skill), spelling);
        assert!(named.kendex_owned, "{spelling}");
        assert_eq!(named.repo.as_deref(), Some(DEFAULT_UPSTREAM), "{spelling}");
        assert_eq!(named.label.as_deref(), Some("skills"), "{spelling}");
    }

    let elsewhere = lock_of(&[(
        "guard",
        ItemKind::Skill,
        "https://gitlab.com/vanillagreencom/kendex",
    )]);
    assert!(!route(&elsewhere, "guard", Some(ItemKind::Skill), DEFAULT_UPSTREAM).kendex_owned);
}

/// Only a GitHub reference folds to `owner/repo`; another host has no
/// shorthand, so the report files against the reference as spelled.
#[test]
fn another_hosts_upstream_is_the_target_as_spelled() {
    let lock = lock_of(&[(
        "guard",
        ItemKind::Skill,
        "https://gitlab.com/team/catalog.git",
    )]);
    let route = route(
        &lock,
        "guard",
        Some(ItemKind::Skill),
        "https://gitlab.com/team/catalog",
    );
    assert!(route.kendex_owned);
    assert_eq!(
        route.repo.as_deref(),
        Some("https://gitlab.com/team/catalog")
    );
    assert_eq!(route.label, None);
}

/// A named upstream routes there only when the lock recorded the asset
/// from it; naming a repo is not by itself proof of ownership.
#[test]
fn a_named_upstream_must_match_recorded_provenance() {
    let lock = lock_of(&[("guard", ItemKind::Skill, "someone/else")]);
    let matched = route(&lock, "guard", Some(ItemKind::Skill), "someone/else");
    assert!(matched.kendex_owned);
    assert_eq!(matched.repo.as_deref(), Some("someone/else"));
    // Labels exist only on the canonical repo.
    assert_eq!(matched.label, None);
    assert!(!route(&Lock::default(), "guard", None, "someone/else").kendex_owned);
}

/// `--asset <name>` names no kind, so entries of every kind match it. A
/// name shared with something from elsewhere is ambiguous and stays
/// local; naming the kind resolves it.
#[test]
fn a_name_shared_with_another_origin_is_ambiguous() {
    let lock = lock_of(&[
        ("dev", ItemKind::Skill, DEFAULT_UPSTREAM),
        ("dev", ItemKind::Hook, "someone/else"),
    ]);
    assert!(!route(&lock, "dev", None, DEFAULT_UPSTREAM).kendex_owned);
    assert!(route(&lock, "dev", Some(ItemKind::Skill), DEFAULT_UPSTREAM).kendex_owned);
}

/// A kind-less report takes the kind its entries agree on, so it carries
/// the same label a named kind would; disagreement leaves it unresolved.
#[test]
fn a_kindless_report_takes_the_kind_its_entries_agree_on() {
    let one_kind = lock_of(&[("dev", ItemKind::Skill, DEFAULT_UPSTREAM)]);
    let resolved = route(&one_kind, "dev", None, DEFAULT_UPSTREAM);
    assert_eq!(resolved.kind, Some(ItemKind::Skill));
    assert_eq!(resolved.label.as_deref(), Some("skills"));

    let mut two_kinds = one_kind;
    two_kinds.entries.insert(
        "hook:dev:claude".to_owned(),
        entry("dev", ItemKind::Hook, DEFAULT_UPSTREAM),
    );
    let unresolved = route(&two_kinds, "dev", None, DEFAULT_UPSTREAM);
    assert_eq!(unresolved.kind, None);
    assert_eq!(unresolved.label.as_deref(), Some("cli"));
}
