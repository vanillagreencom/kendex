//! A package's version timeline and the updates projection: only commits
//! that touched the package's files count, tags decorate rather than
//! replace the timeline, holds and ignores are flagged rather than
//! filtered, and a pinned source can still hear about newer versions.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::manifest;
use kendex_core::model::{ItemKind, Scope};
use kendex_core::package::{self, updates};
use kendex_core::process::Hardened;
use kendex_core::remote;

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
fn write_skill(dir: &Path, name: &str, body: &str) {
    let skill = dir.join("skills").join(name);
    fs::create_dir_all(&skill).unwrap();
    fs::write(
        skill.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: about {name}\n---\n{body}\n"),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    // Canonical up front: macOS reaches its temp dirs through a symlink,
    // and the engine hands back canonical paths.
    let home = tmp.path().canonicalize().unwrap();
    let upstream = home.join("git").join(REPO);
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
fn declare(w: &World, source_extra: &str, body: &str) {
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n{source_extra}\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{body}"
        ),
    )
    .unwrap();
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

#[test]
#[allow(clippy::unwrap_used)]
fn versions_list_the_subtree_timeline_with_tags_and_markers() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    let first = commit(&w.upstream, "gh one");
    fs::write(w.upstream.join("README.md"), "unrelated").unwrap();
    commit(&w.upstream, "readme only");
    write_skill(&w.upstream, "gh", "Three.");
    let third = commit(&w.upstream, "gh three\x1b[31m");
    git(&w.upstream, &["tag", "v2"]);

    declare(&w, "", "[skills.gh]\nsource = \"cat\"\n");
    // Install while pinned at the first commit — the timeline must still
    // reach past the hold.
    declare(
        &w,
        "",
        &format!("[skills.gh]\nsource = \"cat\"\nrev = \"{first}\"\n"),
    );
    sync_and_apply(&w);

    let rows = package::versions(&w.env, &w.scope, ItemKind::Skill, "gh").unwrap();
    let ids: Vec<&str> = rows.iter().map(|row| row.id.as_str()).collect();
    assert_eq!(
        ids,
        vec![third.as_str(), first.as_str()],
        "only commits that touched the package are versions"
    );
    assert_eq!(rows[0].label.as_deref(), Some("v2"));
    assert!(rows[0].newer_than_installed);
    assert!(!rows[0].installed);
    assert!(rows[1].installed);
    assert!(
        !rows[0].summary.contains('\x1b'),
        "control characters never reach display: {}",
        rows[0].summary
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_installed_commit_off_the_timeline_maps_to_its_content_commit() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    let first = commit(&w.upstream, "gh one");
    fs::write(w.upstream.join("README.md"), "unrelated").unwrap();
    commit(&w.upstream, "readme only");

    declare(&w, "", "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    // Installed at the readme commit, which never touched the package.
    let rows = package::versions(&w.env, &w.scope, ItemKind::Skill, "gh").unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].id, first);
    assert!(
        rows[0].installed,
        "the marker lands on the content revision the install holds"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn updates_report_only_packages_whose_files_moved() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    write_skill(&w.upstream, "other", "One.");
    commit(&w.upstream, "one");
    declare(
        &w,
        "",
        "[skills.gh]\nsource = \"cat\"\n\n[skills.other]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    write_skill(&w.upstream, "other", "Two.");
    commit(&w.upstream, "two");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    let rows = updates::updates(&w.env, &w.scope).unwrap().rows;
    let gh = rows.iter().find(|row| row.name == "gh").unwrap();
    let other = rows.iter().find(|row| row.name == "other").unwrap();
    assert!(
        !gh.update_available,
        "a repository that moved without touching the package is not an update"
    );
    assert!(other.update_available);
    assert!(!other.pinned);
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_held_package_still_reports_its_update_and_holds_on_disk() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "",
        &format!("[skills.gh]\nsource = \"cat\"\nrev = \"{first}\"\n"),
    );
    sync_and_apply(&w);

    write_skill(&w.upstream, "gh", "Two.");
    commit(&w.upstream, "two");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();

    let rows = updates::updates(&w.env, &w.scope).unwrap().rows;
    let gh = rows.iter().find(|row| row.name == "gh").unwrap();
    assert!(gh.update_available, "a hold never hides what it holds back");
    assert!(gh.pinned);
    let body = fs::read_to_string(w.home.join("app/.agents/skills/gh/SKILL.md")).unwrap();
    assert!(body.contains("One."), "held content stays held");
}

#[test]
#[allow(clippy::unwrap_used)]
fn ignoring_updates_is_a_settings_write_and_rows_stay_visible() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    declare(&w, "", "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    write_skill(&w.upstream, "gh", "Two.");
    commit(&w.upstream, "two");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    let manifest_before = fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap();
    updates::set_ignored(&w.env, &w.scope, ItemKind::Skill, "gh", REPO, true).unwrap();
    let manifest_after = fs::read_to_string(manifest::manifest_path(&w.env, &w.scope)).unwrap();
    assert_eq!(
        manifest_before, manifest_after,
        "a notification preference never touches shared intent"
    );

    let rows = updates::updates(&w.env, &w.scope).unwrap().rows;
    let gh = rows.iter().find(|row| row.name == "gh").unwrap();
    assert!(gh.ignored, "ignored rows come back flagged, never filtered");
    assert!(gh.update_available);

    updates::set_ignored(&w.env, &w.scope, ItemKind::Skill, "gh", REPO, false).unwrap();
    let rows = updates::updates(&w.env, &w.scope).unwrap().rows;
    assert!(!rows.iter().find(|row| row.name == "gh").unwrap().ignored);
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_hostile_source_commit_never_reaches_git_as_an_option() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    declare(&w, "", "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    // A lock is a project file: a hostile repo can ship one whose
    // source_commit is a git option, not a commit. It must never be
    // handed to git as a positional — `--output=<path>` would clobber
    // that path. The updates/versions projections must simply not answer
    // for that entry, and write nothing outside the scope.
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    let mut lock = kendex_core::lock::load(&lock_path).unwrap();
    let marker = w.home.join("PWNED");
    for entry in lock.entries.values_mut() {
        entry.source_commit = Some(format!("--output={}", marker.display()));
    }
    kendex_core::lock::save(&lock_path, &lock).unwrap();

    let _ = package::versions(&w.env, &w.scope, ItemKind::Skill, "gh");
    let _ = updates::updates(&w.env, &w.scope);
    assert!(!marker.exists(), "a lock value reached git as an option");
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_pinned_source_discovers_new_versions_after_fetch_all() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        &format!("rev = \"{first}\"\n"),
        "[skills.gh]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    write_skill(&w.upstream, "gh", "Two.");
    let second = commit(&w.upstream, "two");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    // A pinned source's sync skips the network on purpose; the updates
    // check must not inherit that blindness.
    remote::sync_sources(&w.env, &loaded).unwrap();
    let rows = updates::updates(&w.env, &w.scope).unwrap().rows;
    assert!(!rows[0].update_available, "nothing fetched yet");

    let warnings = remote::fetch_all(&w.env, &loaded);
    assert_eq!(warnings, Vec::<String>::new());
    let rows = updates::updates(&w.env, &w.scope).unwrap().rows;
    let gh = rows.iter().find(|row| row.name == "gh").unwrap();
    assert!(gh.update_available);
    assert_eq!(gh.latest.as_ref().unwrap().commit, second);
}

#[allow(clippy::unwrap_used)]
fn write_pi_extension(dir: &Path, name: &str, version: &str) {
    let ext = dir.join("pi-extensions").join(name);
    fs::create_dir_all(&ext).unwrap();
    fs::write(
        ext.join("package.json"),
        format!("{{\"name\": \"{name}\", \"version\": \"{version}\"}}\n"),
    )
    .unwrap();
}

/// A Pi extension whose source tip stopped carrying it still says why it
/// is never updated one package at a time. This is the row that actually
/// reaches a reader: a Pi extension has no lock entry, so it never has an
/// installed commit to compare and never reports an update — the tip
/// dropping it is the one standing that puts its row on a surface. The
/// refusal has to survive that path, not only the evaluated one.
#[test]
#[allow(clippy::unwrap_used)]
fn a_pi_extension_gone_from_its_source_still_carries_the_refusal() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    write_pi_extension(&w.upstream, "pi-hooks", "1.0.0");
    commit(&w.upstream, "one");
    declare(
        &w,
        "",
        "[skills.gh]\nsource = \"cat\"\n\n[pi-extensions.pi-hooks]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    fs::remove_dir_all(w.upstream.join("pi-extensions/pi-hooks")).unwrap();
    commit(&w.upstream, "the extension is gone");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();
    remote::fetch_all(&w.env, &loaded);

    let report = updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::PiExtension)
        .unwrap_or_else(|| panic!("no pi-extension row in {:?}", report.rows));
    assert!(row.removed_upstream, "{row:?}");
    assert_eq!(
        row.no_per_package_update.as_deref(),
        Some(kendex_core::engine::NO_PER_PACKAGE_UPDATE),
        "{row:?}"
    );
}

/// A fork row carries the refusal too. kendex's own fork refuses every
/// kind but skills and agents, so it never writes this — but the manifest
/// is the reader's file, `[forks]` is keyed by kind, and core reads what
/// the file holds rather than only what it wrote. Losing the refusal here
/// fails open: the row reaches the Library and the app would offer an
/// Update the planner has no plan for.
#[test]
#[allow(clippy::unwrap_used)]
fn a_forked_row_of_a_refused_kind_still_carries_the_refusal() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    // A path source has no repository coordinates to bind, which is the
    // one error that reaches the fork row at all.
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[sources.here]\npath = \"cat\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"\n\n[pi-extensions.pi-hooks]\nsource = \"here\"\n\n[forks.pi-extension.pi-hooks]\nsource = \"cat\"\nforked-at = \"2026-01-01\"\n"
        ),
    )
    .unwrap();
    let loaded = manifest::load_for_mutation(&path).unwrap().unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    let report = updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::PiExtension)
        .unwrap_or_else(|| panic!("no fork row in {:?}", report.rows));
    assert!(row.forked, "{row:?}");
    assert_eq!(
        row.no_per_package_update.as_deref(),
        Some(kendex_core::engine::NO_PER_PACKAGE_UPDATE),
        "{row:?}"
    );
    // The control: the skill beside it is a kind the planner does derive.
    let gh = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Skill)
        .unwrap_or_else(|| panic!("no skill row in {:?}", report.rows));
    assert_eq!(gh.no_per_package_update, None, "{gh:?}");
}

/// A place held by its owner — a derived dependency under a pinned source —
/// never reaches the package page, because the page's timeline read refuses
/// a package the manifest does not declare. The updates table shows and
/// explains those rows; the package page cannot be opened on one with a
/// version to move to, so its own withheld note has no such case to render.
/// Settled here rather than argued: if `versions` ever answers for a
/// derived package, this goes red and that note becomes reachable.
#[test]
#[allow(clippy::unwrap_used)]
fn a_derived_place_has_an_updates_row_and_no_version_timeline() {
    let w = world();
    let dir = w.upstream.join("skills/gh");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        "---\nname: gh\ndescription: about gh\ndependencies:\n  required: [helper]\n---\nOne.\n",
    )
    .unwrap();
    write_skill(&w.upstream, "helper", "One.");
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        &format!("rev = \"{first}\"\n"),
        "[skills.gh]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    let rows = updates::updates(&w.env, &w.scope).unwrap().rows;
    let helper = rows
        .iter()
        .find(|row| row.name == "helper")
        .unwrap_or_else(|| panic!("no derived row in {rows:?}"));
    assert!(helper.derived, "{helper:?}");
    assert!(helper.pinned, "the source's hold reaches it: {helper:?}");

    // The page reads its versions from here, and takes an error as an
    // empty timeline — so it has no newer version to offer and nothing
    // withheld to explain.
    let refused = package::versions(&w.env, &w.scope, ItemKind::Skill, "helper").unwrap_err();
    assert!(
        matches!(refused, kendex_core::error::CoreError::NotDeclared { .. }),
        "{refused:?}"
    );
    // The control: the declaration the dependency came in under does read.
    assert!(
        !package::versions(&w.env, &w.scope, ItemKind::Skill, "gh")
            .unwrap()
            .is_empty()
    );
}

/// A declared Pi extension gets an updates row: `planned_declarations`
/// appends it after the closure walk precisely so its news is heard. The
/// row is a fact, not an offer — nothing here plans a Pi extension, so the
/// surfaces that act on a row have to say where its update lives.
#[test]
#[allow(clippy::unwrap_used)]
fn a_pi_extension_reaches_the_updates_report() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    write_pi_extension(&w.upstream, "pi-hooks", "1.0.0");
    commit(&w.upstream, "one");
    declare(
        &w,
        "",
        "[skills.gh]\nsource = \"cat\"\n\n[pi-extensions.pi-hooks]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    write_pi_extension(&w.upstream, "pi-hooks", "2.0.0");
    commit(&w.upstream, "two");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    let report = updates::updates(&w.env, &w.scope).unwrap();
    let row = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::PiExtension)
        .unwrap_or_else(|| panic!("no pi-extension row in {:?}", report.rows));
    assert_eq!(row.name, "pi-hooks");

    // The row says why it can never be updated one package at a time, in
    // the same words core refuses with, so no surface has to work the rule
    // out for itself. A kind that does plan carries nothing.
    assert_eq!(
        row.no_per_package_update.as_deref(),
        Some(kendex_core::engine::NO_PER_PACKAGE_UPDATE),
        "{row:?}"
    );
    let gh = report
        .rows
        .iter()
        .find(|row| row.kind == ItemKind::Skill)
        .unwrap_or_else(|| panic!("no skill row in {:?}", report.rows));
    assert_eq!(gh.no_per_package_update, None, "{gh:?}");

    // And it can never be acted on. Nothing records a Pi extension in the
    // lock — update-pi installs them and writes none — so there is no
    // installed commit to move from, and every surface that offers Update
    // asks for one. If a Pi extension ever gains a lock entry this goes
    // red, and the Update those surfaces would start offering is a plan
    // that refuses.
    assert_eq!(row.current, None, "{row:?}");
    assert!(!row.update_available, "{row:?}");
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(&w.env, &w.scope)).unwrap();
    assert!(
        !lock
            .entries
            .values()
            .any(|entry| entry.kind == ItemKind::PiExtension),
        "the lock records no Pi extension"
    );
    // The same absence on the package page: no version reads as installed,
    // so the page has nothing to offer an update from.
    let versions = package::versions(&w.env, &w.scope, ItemKind::PiExtension, "pi-hooks").unwrap();
    assert!(!versions.is_empty(), "the timeline still reads");
    assert!(versions.iter().all(|row| !row.installed), "{versions:?}");
}
