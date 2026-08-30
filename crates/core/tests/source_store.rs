//! The source store as the product promises it: two scopes reading two
//! revisions of one repository at the same time, and an upstream tag that
//! moves being shown before it is followed.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::{DriftState, audit};
use kendex_core::env::{Env, FakeOs};
use kendex_core::lock::{load as load_lock, lock_path};
use kendex_core::manifest;
use kendex_core::model::Scope;
use kendex_core::process::Hardened;
use kendex_core::remote;
use kendex_core::source::{self, SourceState};

struct World {
    _tmp: tempfile::TempDir,
    env: Env,
    home: PathBuf,
    upstream: PathBuf,
}

const REPO: &str = "owner/catalog";
const OTHER: &str = "owner/elsewhere";

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
fn write_skill(dir: &Path, body: &str) {
    fs::create_dir_all(dir.join("skills/gh")).unwrap();
    fs::write(
        dir.join("skills/gh/SKILL.md"),
        format!("---\nname: gh\ndescription: github flows\n---\n{body}\n"),
    )
    .unwrap();
}

/// A home with Claude present and a remote catalog carrying skill `gh`,
/// tagged `release` at its first commit.
#[allow(clippy::unwrap_used)]
fn world() -> World {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let upstream = home.join("git").join(REPO);
    write_skill(&upstream, "Upstream v1.");
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    commit(&upstream, "one");
    git(&upstream, &["tag", "release"]);
    fs::create_dir_all(home.join(".claude")).unwrap();
    fs::create_dir_all(home.join("app/.claude")).unwrap();
    let base = format!("file://{}", home.join("git").display());
    World {
        env: Env::fake(&home, FakeOs::Linux).with_var("KENDEX_GIT_BASE", &base),
        home,
        upstream,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn declare(w: &World, scope: &Scope, rev: &str) {
    declare_repo(w, scope, REPO, rev);
}

#[allow(clippy::unwrap_used)]
fn declare_repo(w: &World, scope: &Scope, repo: &str, rev: &str) {
    let path = manifest::manifest_path(&w.env, scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{repo}\"\nrev = \"{rev}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"\n"
        ),
    )
    .unwrap();
}

#[allow(clippy::unwrap_used)]
fn loaded(w: &World, scope: &Scope) -> manifest::Manifest {
    manifest::load_for_mutation(&manifest::manifest_path(&w.env, scope))
        .unwrap()
        .unwrap()
}

/// Fetch what this scope declares, then apply its plan.
#[allow(clippy::unwrap_used)]
fn install(w: &World, scope: &Scope) {
    let loaded = loaded(w, scope);
    remote::sync_sources(&w.env, &loaded).unwrap();
    let report = audit(&w.env, scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
fn rendered(w: &World, scope: &Scope) -> String {
    let path = match scope {
        Scope::Global => w.env.rendered_skills_dir().join("gh/SKILL.md"),
        Scope::Project { root } => root.join(".agents/skills/gh/SKILL.md"),
    };
    fs::read_to_string(path).unwrap()
}

/// One repository, two revisions, two scopes — each reads its own commit
/// and neither can disturb the other, which the single mutable checkout of
/// v0.1 could not do.
#[test]
#[allow(clippy::unwrap_used)]
fn two_scopes_pin_different_revisions_of_one_repo() {
    let w = world();
    let first = {
        let output = Hardened::git(&["rev-parse", "HEAD"], Some(&w.upstream))
            .run()
            .unwrap();
        String::from_utf8_lossy(&output.stdout).trim().to_owned()
    };
    write_skill(&w.upstream, "Upstream v2.");
    let second = commit(&w.upstream, "two");

    let project = Scope::Project {
        root: w.home.join("app"),
    };
    declare(&w, &Scope::Global, &first);
    declare(&w, &project, &second);
    install(&w, &Scope::Global);
    install(&w, &project);

    assert!(rendered(&w, &Scope::Global).contains("Upstream v1."));
    assert!(rendered(&w, &project).contains("Upstream v2."));

    // Each scope recorded the commit it read, and re-planning either one
    // leaves the other alone.
    let recorded = |scope: &Scope| {
        load_lock(&lock_path(&w.env, scope))
            .unwrap()
            .sources
            .get("cat")
            .unwrap()
            .commit
            .clone()
    };
    assert_eq!(recorded(&Scope::Global), first);
    assert_eq!(recorded(&project), second);
    assert!(audit(&w.env, &Scope::Global).unwrap().plan.is_empty());
    assert!(audit(&w.env, &project).unwrap().plan.is_empty());
    assert!(rendered(&w, &Scope::Global).contains("Upstream v1."));
}

/// Pointing a source at another repository is a change of identity, not of
/// revision: until the new repository is fetched, the old one's content is
/// nobody's answer — least of all under the new one's name.
#[test]
#[allow(clippy::unwrap_used)]
fn repointing_a_source_never_serves_the_old_repository() {
    let w = world();
    let scope = Scope::Project {
        root: w.home.join("app"),
    };
    declare(&w, &scope, "main");
    install(&w, &scope);
    assert!(rendered(&w, &scope).contains("Upstream v1."));

    // A second repository, never fetched, carrying its own `gh`.
    let elsewhere = w.home.join("git").join(OTHER);
    write_skill(&elsewhere, "Elsewhere v1.");
    git(&elsewhere, &["init", "--quiet", "-b", "main"]);
    commit(&elsewhere, "one");

    declare_repo(&w, &scope, OTHER, "main");
    let state = source::resolve(&w.env, &scope, "cat", &loaded(&w, &scope)).unwrap();
    assert!(
        matches!(&state, SourceState::Pending { repo, .. } if repo == OTHER),
        "a repointed source must not resolve to the old repository: {state:?}"
    );
    let report = audit(&w.env, &scope).unwrap();
    assert!(
        report.notes.iter().any(|note| note.contains("not fetched")),
        "the audit should say the new repository is not here yet: {:?}",
        report.notes
    );

    // Fetching the new repository makes it readable, and the installed copy
    // is then a rebind the user has to settle — never a silent swap.
    remote::sync_sources(&w.env, &loaded(&w, &scope)).unwrap();
    let report = audit(&w.env, &scope).unwrap();
    assert!(
        report.drift.iter().any(|row| row.name == "gh"
            && row.state == DriftState::Conflict
            && row.detail.contains(REPO)
            && row.detail.contains(OTHER)),
        "the rebind should name both repositories: {:?}",
        report.drift
    );
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(rendered(&w, &scope).contains("Upstream v1."));
}

/// A download running in another window holds one repository's cache. That
/// must cost the scope only that source: everything else still plans.
#[test]
#[allow(clippy::unwrap_used)]
fn a_busy_cache_costs_only_its_own_source() {
    let w = world();
    let scope = Scope::Project {
        root: w.home.join("app"),
    };
    let plain = w.home.join("plain");
    fs::create_dir_all(plain.join("skills/local-gh")).unwrap();
    fs::write(
        plain.join("skills/local-gh/SKILL.md"),
        "---\nname: local-gh\ndescription: local\n---\nLocal.\n",
    )
    .unwrap();
    let path = manifest::manifest_path(&w.env, &scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\nrev = \"main\"\n\n[sources.plain]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"\n\n[skills.local-gh]\nsource = \"plain\"\n",
            source_path(&plain)
        ),
    )
    .unwrap();
    install(&w, &scope);

    // The checkout has to be rebuilt, and the repository's cache is held by
    // a neighbour for as long as its own download takes.
    let key = remote::store::repo_key(&remote::clone_url(&w.env, REPO));
    let commit = load_lock(&lock_path(&w.env, &scope))
        .unwrap()
        .sources
        .get("cat")
        .unwrap()
        .commit
        .clone();
    fs::remove_dir_all(remote::store::checkout_dir(&w.env, &key, &commit)).unwrap();
    fs::remove_dir_all(w.home.join("app").join(".agents/skills/local-gh")).unwrap();
    let guard = remote::store::lock_repo(&w.env, &key).unwrap();

    let report = audit(&w.env, &scope).unwrap();
    assert!(
        report.notes.iter().any(|note| note.starts_with("gh:")),
        "the busy source should be noted, not fatal: {:?}",
        report.notes
    );
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.name == "local-gh" && row.state == DriftState::Missing),
        "the healthy source must still plan: {:?}",
        report.drift
    );
    apply::execute(&w.env, &report.plan).unwrap();
    assert!(w.home.join("app").join(".agents/skills/local-gh").is_dir());

    // The neighbour finishes, and the busy source resolves again.
    drop(guard);
    assert!(audit(&w.env, &scope).unwrap().plan.is_empty());
}

/// A tag that moves upstream is a change like any other: the refresh shows
/// it as stale and writes nothing until the plan is applied.
#[test]
#[allow(clippy::unwrap_used)]
fn a_moved_tag_is_previewed_before_it_is_followed() {
    let w = world();
    let scope = Scope::Project {
        root: w.home.join("app"),
    };
    declare(&w, &scope, "release");
    install(&w, &scope);
    assert!(rendered(&w, &scope).contains("Upstream v1."));

    write_skill(&w.upstream, "Upstream v2.");
    commit(&w.upstream, "two");
    git(&w.upstream, &["tag", "-f", "release"]);

    // Refresh fetches; re-resolution alone changes nothing on disk.
    let loaded = manifest::load_for_mutation(&manifest::manifest_path(&w.env, &scope))
        .unwrap()
        .unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();
    assert!(rendered(&w, &scope).contains("Upstream v1."));

    let report = audit(&w.env, &scope).unwrap();
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.name == "gh" && row.state == DriftState::Stale),
        "the moved tag should be previewed as stale: {:?}",
        report.drift
    );
    assert!(rendered(&w, &scope).contains("Upstream v1."));

    apply::execute(&w.env, &report.plan).unwrap();
    assert!(rendered(&w, &scope).contains("Upstream v2."));
    assert!(audit(&w.env, &scope).unwrap().plan.is_empty());
}
