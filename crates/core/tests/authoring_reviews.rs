//! What a catalog's committed reviews buy in its own check — and every way
//! a record fails to hold up there, which is every way it fails to hold up
//! on the machines that install from it.

use std::fs;

use kendex_core::check_catalog::check;
use kendex_core::model::ItemKind;
use kendex_core::source_read::SealedSource;

/// An empty catalog directory to build one item in.
#[allow(clippy::unwrap_used)]
fn repo() -> (tempfile::TempDir, std::path::PathBuf) {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().join("repo");
    fs::create_dir_all(&root).unwrap();
    (tmp, root)
}

/// The check refuses what an install refuses. A hand-written record an
/// installer will not honour has to fail here, or a maintainer's own CI
/// goes green while everyone installing from them is held back over it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_record_an_install_refuses_fails_the_check() {
    let (_tmp, root) = repo();
    let dir = root.join("skills").join("risky");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        "---\nname: risky\ndescription: about risky\n---\nRun `git commit --no-verify` first.\n",
    )
    .unwrap();
    let sealed = SealedSource::open(&root).unwrap();
    let config = kendex_core::source::source_config(&sealed, "repo").unwrap();
    let hash = kendex_core::quality::author::content_hash(
        &sealed,
        &dir,
        &config.rendering_inputs(&sealed, kendex_core::model::ItemKind::Skill, "risky"),
    )
    .unwrap();
    let fingerprint = check(&sealed, "repo")
        .unwrap()
        .findings()
        .find(|finding| finding.rule.is_some())
        .and_then(|finding| finding.token.clone())
        .and_then(|token| {
            kendex_core::check_catalog::dismissals::parse_token(&token)
                .map(|(_, _, fingerprint)| fingerprint.to_owned())
        })
        .expect("the item has a finding to settle");
    // Hand-written: `dismiss --catalog` refuses this reason outright.
    fs::write(
        root.join("kendex-reviews.toml"),
        format!(
            "[reviews.\"skill:risky\"]\nreview-hash = \"{hash}\"\nruleset = {}\n\n[reviews.\"skill:risky\".dismissed.{fingerprint}]\nreason = \"trusted-source\"\ndismissed-at = \"2026-01-01T00:00:00Z\"\n",
            kendex_core::quality::RULESET_VERSION
        ),
    )
    .unwrap();

    let report = check(&SealedSource::open(&root).unwrap(), "repo").unwrap();
    assert!(
        report
            .findings()
            .any(|finding| finding.message.contains("not one an install will honour")),
        "{:?}",
        report.findings().collect::<Vec<_>>()
    );
    assert!(report.failing(false) > 0, "and the run fails");
}
/// A hook's review cannot travel to an install, so no path may honour one:
/// the authoring check, the preview and the install all read it through the
/// same reader and all refuse it. A check that passed while the install
/// blocked would be the disagreement this whole record exists to remove.
#[test]
#[allow(clippy::unwrap_used)]
fn a_hand_written_hook_record_is_refused_by_the_check_too() {
    let (_tmp, root) = repo();
    fs::create_dir_all(root.join("hooks")).unwrap();
    fs::write(root.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    let script = root.join("hooks/guard.sh");
    fs::write(
        &script,
        "#!/usr/bin/env bash\n# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: check\n# ---\nsudo rm -rf /tmp/x\n",
    )
    .unwrap();
    let sealed = SealedSource::open(&root).unwrap();
    let before = check(&sealed, "repo").unwrap();
    let open = before
        .findings()
        .find(|finding| finding.rule.is_some())
        .expect("the hook has a finding");
    assert!(open.token.is_none(), "and no token is offered for it");

    // Hand-written, since nothing kendex ships will write one.
    let config = kendex_core::source::source_config(&sealed, "repo").unwrap();
    let hash = kendex_core::quality::author::content_hash(
        &sealed,
        &script,
        &config.rendering_inputs(&sealed, kendex_core::model::ItemKind::Hook, "guard"),
    )
    .unwrap();
    fs::write(
        root.join("kendex-reviews.toml"),
        format!(
            "[reviews.\"hook:guard\"]\nreview-hash = \"{hash}\"\nruleset = {}\n\n[reviews.\"hook:guard\".dismissed.0123456789abcdef]\nreason = \"intended\"\ndismissed-at = \"2026-01-01T00:00:00Z\"\n",
            kendex_core::quality::RULESET_VERSION
        ),
    )
    .unwrap();

    let after = check(&SealedSource::open(&root).unwrap(), "repo").unwrap();
    assert!(
        after
            .findings()
            .any(|finding| finding.message.contains("not one an install will honour")),
        "{:?}",
        after.findings().collect::<Vec<_>>()
    );
    assert!(
        after
            .findings()
            .any(|finding| finding.rule.is_some() && !finding.dismissed),
        "and the hook's own finding still counts"
    );
}
/// A committed review record settles a finding: the item stops being held
/// back, the finding is still reported (marked dismissed), and editing the
/// item's content makes the record stale so the hold comes back.
#[test]
#[allow(clippy::unwrap_used)]
fn a_committed_dismissal_unblocks_until_the_content_moves() {
    use kendex_core::check_catalog::dismissals;
    use kendex_core::quality::Verdict;

    let (_tmp, root) = repo();
    let dir = root.join("skills/guardy");
    fs::create_dir_all(&dir).unwrap();
    let body = "---\nname: guardy\ndescription: a commit guard\n---\nIf the hook blocks a commit, `git commit --no-verify` is the deliberate bypass.\n";
    fs::write(dir.join("SKILL.md"), body).unwrap();
    fs::write(root.join("kendex.toml"), "[marketplace]\nname = \"demo\"\n").unwrap();

    let sealed = SealedSource::open(&root).unwrap();
    let report = check(&sealed, "repo").unwrap();
    let item = &report.items[0];
    assert_eq!(item.verdict, Verdict::Block);
    let token = item
        .findings
        .iter()
        .find_map(|finding| finding.token.clone())
        .unwrap();
    let (kind, name, fingerprint) = dismissals::parse_token(&token).unwrap();
    assert_eq!(kind, ItemKind::Skill);
    assert_eq!(name, "guardy");

    let config = kendex_core::source::source_config(&sealed, "repo").unwrap();
    let hash = kendex_core::quality::author::content_hash(
        &sealed,
        &dir,
        &config.rendering_inputs(&sealed, kendex_core::model::ItemKind::Skill, "risky"),
    )
    .unwrap();
    dismissals::record(
        &sealed,
        kind,
        name,
        &hash,
        &[(
            fingerprint.to_owned(),
            kendex_core::quality::reviews::DismissReason::Intended,
        )],
    )
    .unwrap();

    // Re-open so the reviews file is inside the sealed root's view.
    let sealed = SealedSource::open(&root).unwrap();
    let report = check(&sealed, "repo").unwrap();
    let item = &report.items[0];
    assert_ne!(
        item.verdict,
        Verdict::Block,
        "the reviewed finding no longer holds the item back"
    );
    let settled = item
        .findings
        .iter()
        .find(|finding| finding.token.as_deref() == Some(token.as_str()))
        .unwrap();
    assert!(
        settled.dismissed,
        "the finding is still reported, marked dismissed"
    );

    // The content moves: the snapshot is stale and the hold returns.
    fs::write(dir.join("SKILL.md"), format!("{body}\nOne more line.\n")).unwrap();
    let report = check(&sealed, "repo").unwrap();
    assert_eq!(report.items[0].verdict, Verdict::Block);
}
