//! The drift report agents wake up to, end to end: held-ness derives from
//! the effective installation graph, evaluation failures surface instead of
//! reading as current, the snapshot carries the deep pass's verdicts, and
//! the session-start hook script honors its contract.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::drift;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::manifest;
use kendex_core::model::Scope;
use kendex_core::package::updates;
use kendex_core::process::Hardened;
use kendex_core::remote;

const REPO: &str = "owner/catalog";

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
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
    write_skill_with(dir, name, body, "");
}

#[allow(clippy::unwrap_used)]
fn write_skill_with(dir: &Path, name: &str, body: &str, extra_frontmatter: &str) {
    let skill = dir.join("skills").join(name);
    fs::create_dir_all(&skill).unwrap();
    fs::write(
        skill.join("SKILL.md"),
        format!("---\nname: {name}\ndescription: about {name}\n{extra_frontmatter}---\n{body}\n"),
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
            "schema = 5\n\n[sources.cat]\nrepo = \"{REPO}\"\n{source_extra}\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n{body}"
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
    apply::execute(&w.env, &report.plan, None).unwrap();
}

#[allow(clippy::unwrap_used)]
fn row<'a>(rows: &'a [updates::UpdateRow], name: &str) -> &'a updates::UpdateRow {
    rows.iter()
        .find(|row| row.name == name)
        .unwrap_or_else(|| panic!("no row for {name}: {rows:?}"))
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_package_from_a_commit_pinned_source_reports_held() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        &format!("rev = \"{first}\"\n"),
        "[skills.gh]\nsource = \"cat\"\n",
    );
    sync_and_apply(&w);

    let report = updates::updates(&w.env, &w.scope).unwrap();
    assert!(
        row(&report.rows, "gh").pinned,
        "a source-level pin is a hold on everything it carries"
    );

    // A tracking selector is not a pin: the same declaration on a branch
    // name follows, and must not read as held.
    declare(&w, "rev = \"main\"\n", "[skills.gh]\nsource = \"cat\"\n");
    let report = updates::updates(&w.env, &w.scope).unwrap();
    assert!(!row(&report.rows, "gh").pinned);
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_pin_reaching_a_member_through_a_bundle_reports_held() {
    let w = world();
    write_skill(&w.upstream, "member", "One.");
    fs::write(
        w.upstream.join("kendex.toml"),
        "[bundles.kit]\ndescription = \"a set\"\nskills = [\"member\"]\n",
    )
    .unwrap();
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "",
        &format!("[bundles.kit]\nsource = \"cat\"\nrev = \"{first}\"\n"),
    );
    sync_and_apply(&w);

    let report = updates::updates(&w.env, &w.scope).unwrap();
    assert!(
        row(&report.rows, "member").pinned,
        "a pinned bundle holds its members: {report:?}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_pin_reaching_a_dependency_through_its_parent_reports_held() {
    let w = world();
    write_skill(&w.upstream, "dep", "Dep.");
    write_skill_with(
        &w.upstream,
        "parent",
        "Parent.",
        "dependencies:\n  required: [dep]\n",
    );
    let first = commit(&w.upstream, "one");
    declare(
        &w,
        "",
        &format!("[skills.parent]\nsource = \"cat\"\nrev = \"{first}\"\n"),
    );
    sync_and_apply(&w);

    let report = updates::updates(&w.env, &w.scope).unwrap();
    assert!(
        row(&report.rows, "dep").pinned,
        "a pinned parent holds its dependencies: {report:?}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_package_gone_from_its_source_is_a_fact_not_a_silent_skip() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    declare(&w, "", "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    fs::remove_dir_all(w.upstream.join("skills/gh")).unwrap();
    commit(&w.upstream, "gone");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    let report = updates::updates(&w.env, &w.scope).unwrap();
    assert!(row(&report.rows, "gh").removed_upstream, "{report:?}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_history_is_a_warning_never_current() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    declare(&w, "", "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    // A recorded commit the mirror does not hold — a force-pushed source,
    // or a hand-edited lock — makes the installed version unreadable.
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    let mut lock = kendex_core::lock::load(&lock_path).unwrap();
    for entry in lock.entries.values_mut() {
        entry.source_commit = Some("f".repeat(40));
    }
    kendex_core::lock::save(&lock_path, &lock).unwrap();

    let report = updates::updates(&w.env, &w.scope).unwrap();
    let gh = row(&report.rows, "gh");
    assert_eq!(
        (gh.current.as_ref(), gh.update_available),
        (None, false),
        "an unevaluable installed version keeps its row and claims no verdict: {report:?}"
    );
    assert!(
        gh.latest.is_some(),
        "the mirror's own history still renders"
    );
    assert!(
        report.warnings.iter().any(|warning| warning.name == "gh"),
        "the failure surfaces as a warning: {report:?}"
    );

    // And the snapshot carries it into the session check as could-not-check.
    drift::snapshot::record(&w.env, &w.scope).unwrap();
    let checked = drift::report::check(&w.env, std::slice::from_ref(&w.scope));
    assert_eq!(
        checked.status,
        drift::report::CheckStatus::Unknown,
        "{checked:?}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_snapshot_carries_stale_and_holding_silences_it() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    let first = commit(&w.upstream, "one");
    declare(&w, "", "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);

    write_skill(&w.upstream, "gh", "Two.");
    commit(&w.upstream, "two");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    drift::snapshot::record(&w.env, &w.scope).unwrap();
    let checked = drift::report::check(&w.env, std::slice::from_ref(&w.scope));
    assert_eq!(checked.status, drift::report::CheckStatus::Drift);
    let text = drift::report::render_plain(&checked);
    assert!(text.contains("'gh' has a newer version"), "{text}");
    assert!(text.contains("fix: kendex refresh"), "{text}");

    // Hold it: the same drift goes quiet, because a hold is a decision.
    declare(
        &w,
        "",
        &format!("[skills.gh]\nsource = \"cat\"\nrev = \"{first}\"\n"),
    );
    drift::snapshot::record(&w.env, &w.scope).unwrap();
    let checked = drift::report::check(&w.env, std::slice::from_ref(&w.scope));
    assert_eq!(
        checked.status,
        drift::report::CheckStatus::Clean,
        "{checked:?}"
    );
    assert_eq!(drift::report::render_plain(&checked), "");
}

#[test]
#[allow(clippy::unwrap_used)]
fn installations_disagreeing_on_their_commit_read_as_mixed() {
    let w = world();
    write_skill(&w.upstream, "gh", "One.");
    commit(&w.upstream, "one");
    declare(&w, "", "[skills.gh]\nsource = \"cat\"\n");
    sync_and_apply(&w);
    write_skill(&w.upstream, "gh", "Two.");
    let second = commit(&w.upstream, "two");
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &w.scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();

    // Two installations of one package recorded at different commits —
    // mid-apply state, or a partial refresh.
    let lock_path = kendex_core::lock::lock_path(&w.env, &w.scope);
    let mut lock = kendex_core::lock::load(&lock_path).unwrap();
    let mut cloned = None;
    for (key, entry) in lock.entries.iter() {
        if entry.name == "gh" {
            let mut other = entry.clone();
            other.harness = kendex_core::model::HarnessId::Codex;
            other.source_commit = Some(second.clone());
            cloned = Some((key.replace("claude", "codex"), other));
        }
    }
    let (key, entry) = cloned.unwrap();
    lock.entries.insert(key, entry);
    kendex_core::lock::save(&lock_path, &lock).unwrap();

    let report = updates::updates(&w.env, &w.scope).unwrap();
    assert!(row(&report.rows, "gh").mixed, "{report:?}");
}
