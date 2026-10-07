//! Adding a package within a scope: what the request declares comes
//! current, and every follower already installed stays at the commit its
//! record names, the way a single-package update leaves its siblings.

use kendex_core::apply;
use kendex_core::engine::ops::{self, AddRequest};

use super::{
    World, commit, declare, fetch_mirrors, installed_body, locked_commit, messages, notes,
    sync_and_apply, world, write_skill,
};

/// `add` from the scope's catalog subscription, of these skills.
#[allow(clippy::unwrap_used)]
fn add_skills(w: &World, skills: &[&str]) -> kendex_core::engine::EngineReport {
    let request = AddRequest {
        source: Some("cat".into()),
        skills: skills.iter().map(|name| (*name).to_owned()).collect(),
        ..AddRequest::default()
    };
    ops::add(&w.env, &w.scope, &request).unwrap()
}

/// The source moves while `a` is installed; adding `b` installs `b` at the
/// new commit and leaves `a`'s files and record where they were.
#[test]
#[allow(clippy::unwrap_used)]
fn an_add_leaves_the_scopes_followers_at_their_commits() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    let first = commit(&w.upstream, "one");
    declare(&w, "[skills.a]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    write_skill(&w.upstream, "a", "", "a version two.");
    write_skill(&w.upstream, "b", "", "b version two.");
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let report = add_skills(&w, &["b"]);
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(installed_body(&w, "b").contains("b version two."));
    assert_eq!(locked_commit(&w, "b"), second);
    assert!(
        installed_body(&w, "a").contains("a version one."),
        "an installed follower must not come current with an add"
    );
    assert_eq!(locked_commit(&w, "a"), first);
}

/// A package the request names that is already installed at another
/// commit moves with it, and the plan says so in one line before the
/// write.
#[test]
#[allow(clippy::unwrap_used)]
fn a_named_package_installed_at_another_commit_is_said_to_move() {
    let w = world();
    write_skill(&w.upstream, "a", "", "a version one.");
    let first = commit(&w.upstream, "one");
    declare(&w, "[skills.a]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    write_skill(&w.upstream, "a", "", "a version two.");
    write_skill(&w.upstream, "b", "", "b version two.");
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let report = add_skills(&w, &["b", "a"]);
    let said = notes(&report);
    let line = format!(
        "skill a moves from {} to {} with this add",
        &first[..7],
        &second[..7]
    );
    assert_eq!(
        said.iter().filter(|note| **note == line).count(),
        1,
        "{said:?}"
    );
    assert!(
        !said.iter().any(|note| note.starts_with("skill b ")),
        "a package new to the scope moves from nowhere: {said:?}"
    );
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(installed_body(&w, "a").contains("a version two."));
}

/// Two packages requiring one skill, the second added while the source has
/// not moved: the shared skill is wanted at one commit, so the add lands
/// whole with no revision conflict.
#[test]
#[allow(clippy::unwrap_used)]
fn a_dependency_shared_with_a_held_package_is_wanted_at_one_commit() {
    let w = world();
    let requires_z = "dependencies:\n  required: [z]\n";
    write_skill(&w.upstream, "a", requires_z, "a.");
    write_skill(&w.upstream, "b", requires_z, "b.");
    write_skill(&w.upstream, "z", "", "z.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.a]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    assert!(installed_body(&w, "z").contains("z."));

    let report = add_skills(&w, &["b"]);
    assert_eq!(messages(&report), Vec::<String>::new());
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(installed_body(&w, "b").contains("b."));
    assert!(installed_body(&w, "z").contains("z."));
}

/// The same shared skill after the source moved: the held package wants it
/// where it is and the added one where the source is now. The plan names
/// it before the write and leaves it where it is installed, and the added
/// package still lands.
#[test]
#[allow(clippy::unwrap_used)]
fn a_dependency_shared_with_a_held_package_at_another_commit_is_named_and_stays() {
    let w = world();
    let requires_z = "dependencies:\n  required: [z]\n";
    write_skill(&w.upstream, "a", requires_z, "a.");
    write_skill(&w.upstream, "z", "", "z version one.");
    let first = commit(&w.upstream, "one");
    declare(&w, "[skills.a]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    write_skill(&w.upstream, "b", requires_z, "b.");
    write_skill(&w.upstream, "z", "", "z version two.");
    commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let report = add_skills(&w, &["b"]);
    let named: Vec<&str> = report
        .warnings
        .iter()
        .filter(|warning| warning.message.contains(&first[..7]))
        .map(|warning| warning.name.as_str())
        .collect();
    assert_eq!(named, ["z"], "{:?}", messages(&report));
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(installed_body(&w, "b").contains("b."));
    assert!(installed_body(&w, "z").contains("z version one."));
    assert_eq!(locked_commit(&w, "z"), first);
}

/// A skill installed only as what another requires is added in its own
/// right after the source moved. The add declares it and nothing else: the
/// package that required it is not what the person named and stays at the
/// commit its record names, its files with it. That package still wants
/// the skill where it is, so the plan names the skill and leaves it there,
/// as it does for a dependency an added package shares.
#[test]
#[allow(clippy::unwrap_used)]
fn adding_a_required_skill_leaves_the_package_that_required_it_held() {
    let w = world();
    let requires_z = "dependencies:\n  required: [z]\n";
    write_skill(&w.upstream, "a", requires_z, "a version one.");
    write_skill(&w.upstream, "z", "", "z version one.");
    let first = commit(&w.upstream, "one");
    declare(&w, "[skills.a]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    assert_eq!(locked_commit(&w, "z"), first);

    write_skill(&w.upstream, "a", requires_z, "a version two.");
    write_skill(&w.upstream, "z", "", "z version two.");
    commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let report = add_skills(&w, &["z"]);
    let named: Vec<&str> = report
        .warnings
        .iter()
        .filter(|warning| warning.message.contains(&first[..7]))
        .map(|warning| warning.name.as_str())
        .collect();
    assert_eq!(named, ["z"], "{:?}", messages(&report));
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(installed_body(&w, "a").contains("a version one."));
    assert_eq!(locked_commit(&w, "a"), first);
    assert_eq!(locked_commit(&w, "z"), first);
}

/// A set already installed is added again after its source moved: the set
/// the request names comes current, its new member with it, and a package
/// outside it stays at the commit its record names.
#[test]
#[allow(clippy::unwrap_used)]
fn adding_an_installed_set_again_brings_it_current_and_no_one_else() {
    let w = world();
    write_skill(&w.upstream, "m1", "", "m1 version one.");
    write_skill(&w.upstream, "solo", "", "solo version one.");
    std::fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"m1\"]\n",
    )
    .unwrap();
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.solo]\nsource = \"cat\"\n\n[bundles.kit]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    write_skill(&w.upstream, "m2", "", "m2 version two.");
    write_skill(&w.upstream, "solo", "", "solo version two.");
    std::fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"m1\", \"m2\"]\n",
    )
    .unwrap();
    let second = commit(&w.upstream, "two");
    fetch_mirrors(&w);

    let request = AddRequest {
        source: Some("cat".into()),
        bundles: vec!["kit".into()],
        ..AddRequest::default()
    };
    let report = ops::add(&w.env, &w.scope, &request).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    assert!(installed_body(&w, "m2").contains("m2 version two."));
    assert_eq!(locked_commit(&w, "m1"), second);
    assert!(installed_body(&w, "solo").contains("solo version one."));
    assert_eq!(locked_commit(&w, "solo"), first);
}

/// Two sets from one catalog sharing a member, added one after the other to
/// different tools with the source standing still: the installed set holds
/// at the commit its record names, which is the commit the new one follows,
/// so the shared member is wanted at one commit and lands on both tools.
#[test]
#[allow(clippy::unwrap_used)]
fn overlapping_sets_added_to_different_tools_share_their_member() {
    use kendex_core::lock::{entry_key, load as load_lock, lock_path};
    use kendex_core::model::{HarnessId, ItemKind};
    let w = world();
    for name in ["shared", "first", "second"] {
        write_skill(&w.upstream, name, "", &format!("{name}."));
    }
    std::fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.one]\ndescription = \"a set\"\nskills = [\"shared\", \"first\"]\n\n[bundles.two]\ndescription = \"another\"\nskills = [\"shared\", \"second\"]\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    declare(&w, "");
    sync_and_apply(&w);
    let add = |bundle: &str, harness: HarnessId| {
        let request = AddRequest {
            source: Some("cat".into()),
            bundles: vec![bundle.into()],
            harnesses: Some(vec![harness]),
            ..AddRequest::default()
        };
        let report = ops::add(&w.env, &w.scope, &request).unwrap();
        assert_eq!(messages(&report), Vec::<String>::new(), "{bundle}");
        apply::execute(&w.env, &report.plan).unwrap();
    };
    add("one", HarnessId::Claude);
    add("two", HarnessId::Gemini);

    let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    for harness in [HarnessId::Claude, HarnessId::Gemini] {
        let key = entry_key(ItemKind::Skill, "shared", harness);
        assert!(lock.entries.contains_key(&key), "{key} is not installed");
    }
}

/// The manifest's explicit source edits apply when an add names a package:
/// a new revision supplies both followers, and a new repository supplies
/// the added package without overwriting an installation it does not offer.
#[test]
#[allow(clippy::unwrap_used)]
fn an_add_reads_an_explicitly_redeclared_source() {
    for replacement_repo in [false, true] {
        let w = world();
        write_skill(&w.upstream, "a", "", "a version one.");
        let first = commit(&w.upstream, "installed");
        declare(&w, "[skills.a]\nsource = \"cat\"\n");
        sync_and_apply(&w);

        let (repo, revision) = if replacement_repo {
            let repo = "owner/replacement";
            let upstream = w.home.join("git").join(repo);
            std::fs::create_dir_all(&upstream).unwrap();
            super::git(&upstream, &["init", "--quiet", "-b", "main"]);
            write_skill(&upstream, "b", "", "b version two.");
            (repo, commit(&upstream, "replacement"))
        } else {
            write_skill(&w.upstream, "a", "", "a version two.");
            write_skill(&w.upstream, "b", "", "b version two.");
            (super::REPO, commit(&w.upstream, "later"))
        };
        let source_rev = if replacement_repo {
            String::new()
        } else {
            format!("rev = \"{revision}\"\n")
        };
        super::write_manifest(
            &w,
            &format!(
                "schema = 6\n[sources.cat]\nrepo = \"{repo}\"\n{source_rev}\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n[skills.a]\nsource = \"cat\"\n",
            ),
        );
        fetch_mirrors(&w);
        let report = add_skills(&w, &["b"]);
        apply::execute(&w.env, &report.plan).unwrap();

        assert!(installed_body(&w, "b").contains("b version two."));
        assert_eq!(
            locked_commit(&w, "b"),
            revision,
            "replacement_repo={replacement_repo}"
        );
        let lock = super::load_lock(&super::lock_path(&w.env, &w.scope)).unwrap();
        assert_eq!(lock.sources["cat"].repo, repo);
        assert_eq!(lock.sources["cat"].commit, revision);
        if replacement_repo {
            assert!(installed_body(&w, "a").contains("a version one."));
            assert_eq!(locked_commit(&w, "a"), first);
        } else {
            assert!(
                installed_body(&w, "a").contains("a version two."),
                "replacement_repo={replacement_repo}"
            );
            assert_eq!(locked_commit(&w, "a"), revision);
        }
    }
}
