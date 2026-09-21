//! Holding one item at one version while its source moves on: the pin is a
//! full commit id, it survives refresh, it flows through to dependencies,
//! and everything about setting it is checked before the manifest changes.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::{DriftState, PlanOptions, audit, plan_apply};
use kendex_core::env::{Env, FakeOs};
use kendex_core::lock::{entry_key, load as load_lock, lock_path};
use kendex_core::manifest;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::process::Hardened;
use kendex_core::remote;
use kendex_core::remote::store::DEFAULT_KEEP;
use kendex_core::{error::CoreError, package};

const REPO: &str = "owner/catalog";

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
    upstream: PathBuf,
    scope: Scope,
}

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(dir)).run().unwrap();
    assert!(output.status.success(), "git {args:?}");
}

#[allow(clippy::unwrap_used)]
fn commit(dir: &Path, message: &str) -> String {
    git(dir, &["add", "-A"]);
    git(
        dir,
        &[
            "-c",
            "user.email=t@t",
            "-c",
            "user.name=t",
            "commit",
            "--quiet",
            "-m",
            message,
        ],
    );
    let output = Hardened::git(&["rev-parse", "HEAD"], Some(dir))
        .run()
        .unwrap();
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
}

#[allow(clippy::unwrap_used)]
fn write_skill(dir: &Path, name: &str, frontmatter_extra: &str, body: &str) {
    let skill = dir.join("skills").join(name);
    fs::create_dir_all(&skill).unwrap();
    fs::write(
        skill.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: about {name}\n{frontmatter_extra}---\n{body}\n"),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn write_agent(dir: &Path, name: &str, body: &str) {
    let agents = dir.join("agents");
    fs::create_dir_all(&agents).unwrap();
    fs::write(
        agents.join(format!("{name}.md")),
        format!("---\nname: {name}\ndescription: about {name}\nmodel: opus\n---\n{body}\n"),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn world() -> World {
    world_at(REPO)
}

/// A world whose catalog is served under a named repository path — what a
/// scope that still names the repository kendex moved from needs.
#[allow(clippy::unwrap_used)]
fn world_at(repo: &str) -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let upstream = home.join("git").join(repo);
    fs::create_dir_all(&upstream).unwrap();
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    fs::create_dir_all(home.join(".claude")).unwrap();
    fs::create_dir_all(home.join("app/.claude")).unwrap();
    let base = format!("file://{}", home.join("git").display());
    World {
        env: Env::fake(&home, FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base),
        scope: Scope::Project {
            root: home.join("app"),
        },
        home,
        upstream,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn declare(w: &World, body: &str) {
    declare_from(w, REPO, body);
}

/// [`declare`] naming an explicit repository, for the scopes whose source
/// points somewhere other than this file's default catalog.
#[allow(clippy::unwrap_used)]
fn declare_from(w: &World, repo: &str, body: &str) {
    write_manifest(
        w,
        &format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{repo}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{body}"
        ),
    );
}

#[allow(clippy::unwrap_used)]
fn write_manifest(w: &World, text: &str) {
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, text).unwrap();
}

#[allow(clippy::unwrap_used)]
fn sync_and_apply(w: &World) {
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
fn installed_body(w: &World, name: &str) -> String {
    fs::read_to_string(
        w.home
            .join("app/.agents/skills")
            .join(name)
            .join("SKILL.md"),
    )
    .unwrap()
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_pinned_item_holds_while_the_source_moves() {
    let w = world();
    write_skill(&w.upstream, "gh", "", "Version one.");
    let first = commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    assert!(installed_body(&w, "gh").contains("Version one."));

    // Pin at the installed commit, then move upstream and refresh.
    declare(
        &w,
        &format!("[skills.gh]\nsource = \"cat\"\nrev = \"{first}\"\n"),
    );
    write_skill(&w.upstream, "gh", "", "Version two.");
    commit(&w.upstream, "two");
    sync_and_apply(&w);

    assert!(
        installed_body(&w, "gh").contains("Version one."),
        "a held item must not move with its source"
    );
    let report = audit(&w.env, &w.scope).unwrap();
    assert_eq!(report.drift, vec![], "a held item is clean, never stale");
    let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    let entry = &lock.entries[&entry_key(ItemKind::Skill, "gh", HarnessId::Claude)];
    assert_eq!(entry.source_commit.as_deref(), Some(first.as_str()));
    assert!(entry.rendered_hash.is_some());

    // Unpinned control: the same refresh moves it.
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    assert!(installed_body(&w, "gh").contains("Version two."));
}

/// One pass resolves more distinct pins of one repository than the cache
/// keeps by count, and every pinned item still installs: a snapshot the
/// pass was handed is not removed by the snapshots it publishes after it.
#[test]
#[allow(clippy::unwrap_used)]
fn more_pins_than_the_cache_keeps_all_install_in_one_pass() {
    let w = world();
    let mut pinned = Vec::new();
    for n in 0..=DEFAULT_KEEP {
        let name = format!("tool{n}");
        write_skill(&w.upstream, &name, "", &format!("Tool {n}."));
        pinned.push((name.clone(), commit(&w.upstream, &name)));
    }
    let declarations: String = pinned
        .iter()
        .map(|(name, rev)| format!("[skills.{name}]\nsource = \"cat\"\nrev = \"{rev}\"\n\n"))
        .collect();
    declare(&w, &declarations);
    sync_and_apply(&w);

    for (n, (name, _)) in pinned.iter().enumerate() {
        assert!(
            installed_body(&w, name).contains(&format!("Tool {n}.")),
            "{name} did not install"
        );
    }
    let report = audit(&w.env, &w.scope).unwrap();
    assert_eq!(report.notes, Vec::<String>::new());
}

#[test]
#[allow(clippy::unwrap_used)]
fn set_rev_normalizes_a_tag_to_its_commit() {
    let w = world();
    write_skill(&w.upstream, "gh", "", "Tagged.");
    let first = commit(&w.upstream, "one");
    git(&w.upstream, &["tag", "v1"]);
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    let report = package::set_rev(&w.env, &w.scope, ItemKind::Skill, "gh", Some("v1")).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    let text = fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap();
    assert!(
        text.contains(&format!("rev = \"{first}\"")),
        "the tag must be recorded as the commit it named: {text}"
    );
    assert!(!text.contains("\"v1\""), "a movable name is never recorded");
}

#[test]
#[allow(clippy::unwrap_used)]
fn pin_to_unknown_version_is_refused_before_any_write() {
    let w = world();
    write_skill(&w.upstream, "gh", "", "One.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    let before = fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap();
    let error =
        package::set_rev(&w.env, &w.scope, ItemKind::Skill, "gh", Some("no-such-tag")).unwrap_err();
    assert!(matches!(error, CoreError::PinUnavailable { .. }), "{error}");
    let after = fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap();
    assert_eq!(before, after, "a refused pin must not touch the manifest");
}

#[test]
#[allow(clippy::unwrap_used)]
fn set_rev_refuses_a_commit_where_the_item_is_missing() {
    let w = world();
    write_skill(&w.upstream, "other", "", "Only other.");
    let without = commit(&w.upstream, "one");
    write_skill(&w.upstream, "gh", "", "Now with gh.");
    commit(&w.upstream, "two");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    let before = fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap();
    let error =
        package::set_rev(&w.env, &w.scope, ItemKind::Skill, "gh", Some(&without)).unwrap_err();
    assert!(
        matches!(error, CoreError::ItemMissingAtRev { .. }),
        "{error}"
    );
    let after = fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap();
    assert_eq!(before, after);
}

#[test]
#[allow(clippy::unwrap_used)]
fn set_rev_refuses_an_undeclared_item() {
    let w = world();
    write_skill(&w.upstream, "gh", "", "One.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    let error =
        package::set_rev(&w.env, &w.scope, ItemKind::Skill, "stranger", Some("main")).unwrap_err();
    assert!(matches!(error, CoreError::NotDeclared { .. }), "{error}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn hold_at_install_writes_the_resolved_commit_as_rev() {
    let w = world();
    write_skill(&w.upstream, "gh", "", "One.");
    let first = commit(&w.upstream, "one");
    declare(&w, "");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    let request = kendex_core::engine::ops::AddRequest {
        source: Some("cat".to_owned()),
        skills: vec!["gh".to_owned()],
        hold: true,
        ..Default::default()
    };
    let report = kendex_core::engine::ops::add(&w.env, &w.scope, &request).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    let text = fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap();
    assert!(
        text.contains(&format!("rev = \"{first}\"")),
        "--hold must record the commit the install resolved: {text}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_pinned_items_dependencies_resolve_at_the_pinned_commit() {
    let w = world();
    write_skill(
        &w.upstream,
        "gh",
        "dependencies:\n  required: [helper]\n",
        "Parent one.",
    );
    write_skill(&w.upstream, "helper", "", "Helper one.");
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        &format!("[skills.gh]\nsource = \"cat\"\nrev = \"{first}\"\n"),
    );
    sync_and_apply(&w);
    assert!(installed_body(&w, "helper").contains("Helper one."));

    write_skill(&w.upstream, "helper", "", "Helper two.");
    commit(&w.upstream, "two");
    sync_and_apply(&w);

    assert!(
        installed_body(&w, "helper").contains("Helper one."),
        "a pinned parent's dependency must read the pinned catalog"
    );
    let report = audit(&w.env, &w.scope).unwrap();
    assert_eq!(report.drift, vec![]);
}

/// Two skills that require each other are a knot the plan tells the reader
/// about: taking one takes the other. Where the other is wanted at two
/// revisions it is written nowhere, so the sentence would be false, and the
/// plan says nothing rather than promising a package it holds back.
#[test]
#[allow(clippy::unwrap_used)]
fn a_knot_whose_member_is_wanted_at_two_revisions_claims_no_co_install() {
    let w = world();
    write_skill(
        &w.upstream,
        "wrap",
        "dependencies:\n  required: [judge]\n",
        "Wrap one.",
    );
    write_skill(
        &w.upstream,
        "judge",
        "dependencies:\n  required: [wrap]\n",
        "Judge one.",
    );
    write_skill(
        &w.upstream,
        "stop",
        "dependencies:\n  required: [judge]\n",
        "Stop one.",
    );
    let first = commit(&w.upstream, "one");
    write_skill(
        &w.upstream,
        "judge",
        "dependencies:\n  required: [wrap]\n",
        "Judge two.",
    );
    let second = commit(&w.upstream, "two");
    declare(
        &w,
        &format!(
            "[skills.wrap]\nsource = \"cat\"\nrev = \"{first}\"\n\n[skills.stop]\nsource = \"cat\"\nrev = \"{second}\"\n"
        ),
    );
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    let report = audit(&w.env, &w.scope).unwrap();
    assert!(
        report
            .warnings
            .iter()
            .any(|row| row.name == "judge" && row.message.contains("wanted at")),
        "{:?}",
        report
            .warnings
            .iter()
            .map(|row| row.message.clone())
            .collect::<Vec<_>>()
    );
    assert!(
        !report
            .notes
            .iter()
            .any(|note| note.contains("also installs")),
        "a co-install note claims a skill written nowhere: {:?}",
        report.notes
    );
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(
        !w.home.join("app/.agents/skills/judge").exists(),
        "a skill wanted at two revisions was written"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn two_parents_pinning_different_revs_of_one_dependency_change_nothing() {
    let w = world();
    write_skill(
        &w.upstream,
        "gh",
        "dependencies:\n  required: [helper]\n",
        "Parent gh.",
    );
    write_skill(
        &w.upstream,
        "top",
        "dependencies:\n  required: [helper]\n",
        "Parent top.",
    );
    write_skill(&w.upstream, "helper", "", "Helper one.");
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.helper]\nsource = \"cat\"\nharnesses = [\"opencode\"]\n",
    );
    sync_and_apply(&w);
    let before = installed_body(&w, "helper");
    write_skill(&w.upstream, "helper", "", "Helper two.");
    let second = commit(&w.upstream, "two");

    declare(
        &w,
        &format!(
            "[skills.gh]\nsource = \"cat\"\nrev = \"{first}\"\n\n[skills.top]\nsource = \"cat\"\nrev = \"{second}\"\n"
        ),
    );
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();
    let options = PlanOptions {
        remove_orphans: true,
        ..PlanOptions::default()
    };
    let report = plan_apply(&w.env, &w.scope, &options).unwrap();

    let conflicted: Vec<_> = report
        .drift
        .iter()
        .filter(|row| row.name == "helper" && row.state == DriftState::Conflict)
        .collect();
    assert!(
        !conflicted.is_empty(),
        "two revisions of one dependency must conflict: {:?}",
        report.drift
    );
    assert!(
        report
            .warnings
            .iter()
            .any(|w| w.name == "helper" && w.message.contains("wanted at")),
        "{:?}",
        report.warnings
    );
    assert!(
        !report.plan.ops.iter().any(|op| {
            format!("{:?}", op.op).contains("helper") && op.line().contains("helper")
        }),
        "nothing is written for a conflicted item: {:?}",
        report.plan.ops
    );
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(installed_body(&w, "helper") == before);

    // Agreeing pins settle it.
    declare(
        &w,
        &format!(
            "[skills.gh]\nsource = \"cat\"\nrev = \"{first}\"\n\n[skills.top]\nsource = \"cat\"\nrev = \"{first}\"\n"
        ),
    );
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(installed_body(&w, "helper").contains("Helper one."));
}

#[allow(clippy::unwrap_used)]
fn fetch_mirrors(w: &World) {
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();
}

#[allow(clippy::unwrap_used)]
fn locked_commit(w: &World, name: &str) -> String {
    let lock = load_lock(&lock_path(&w.env, &w.scope)).unwrap();
    lock.entries[&entry_key(ItemKind::Skill, name, HarnessId::Claude)]
        .source_commit
        .clone()
        .unwrap()
}

/// The manifest text as it sits on disk, and the revision a package is
/// declared with there. A synthetic hold that reaches the file is a hold
/// nobody chose: that package stops updating, forever and silently.
#[allow(clippy::unwrap_used)]
fn declared_rev(w: &World, name: &str) -> Option<String> {
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    loaded.declared(ItemKind::Skill)[name].rev.clone()
}

mod batched_update;
mod hook_requires;
mod sets;
mod single_update;
mod validate;

#[test]
#[allow(clippy::unwrap_used)]
fn removing_a_plugin_by_kind_does_not_panic() {
    let w = world();
    write_skill(&w.upstream, "gh", "", "One.");
    commit(&w.upstream, "one");
    declare(&w, "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    // A kind-scoped plugin removal must route to the plugins table, never
    // through declared_mut (which panics on Plugin).
    let report = kendex_core::engine::ops::remove(
        &w.env,
        &w.scope,
        &["anything".to_owned()],
        Some(ItemKind::Plugin),
        false,
    );
    assert!(report.is_ok(), "{report:?}");
}
