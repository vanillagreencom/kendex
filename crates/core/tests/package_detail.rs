//! The package page's queries: sealed, capped, and traversal-proof file
//! reads; a deterministic readme; provenance that names the version and
//! the fork.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::manifest;
use kendex_core::model::{ItemKind, Scope};
use kendex_core::package::detail;
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
fn install(w: &World) -> String {
    let dir = w.upstream.join("skills/gh");
    fs::create_dir_all(dir.join("references")).unwrap();
    fs::write(
        dir.join("SKILL.md"),
        "---\nname: gh\ndescription: github flows\n---\nBody.\n",
    )
    .unwrap();
    fs::write(dir.join("readme.md"), "lowercase readme").unwrap();
    fs::write(dir.join("README.md"), "# The readme\n").unwrap();
    fs::write(dir.join("references/deep.md"), "deep file").unwrap();
    let commit = commit(&w.upstream, "one");
    git(&w.upstream, &["tag", "v1"]);
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(
        &path,
        format!(
            "schema = 6\n\n[sources.cat]\nrepo = \"{REPO}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.gh]\nsource = \"cat\"\n"
        ),
    )
    .unwrap();
    let loaded = manifest::load_for_mutation(&path).unwrap().unwrap();
    remote::sync_sources(&w.env, &loaded).unwrap();
    let report = audit(&w.env, &w.scope).unwrap();
    apply::execute(&w.env, &report.plan).unwrap();
    commit
}

#[test]
#[allow(clippy::unwrap_used)]
fn files_list_sorted_with_the_readme_marked() {
    let w = world();
    install(&w);
    let files = detail::package_files(&w.env, &w.scope, ItemKind::Skill, "gh").unwrap();
    let paths: Vec<(&str, bool)> = files
        .iter()
        .map(|f| (f.path.as_str(), f.is_readme))
        .collect();
    // A case-insensitive filesystem folds the two readme spellings into
    // one file — under whichever spelling landed first — so only a
    // case-sensitive layout lists both.
    let case_sensitive = paths
        .iter()
        .filter(|(p, _)| p.eq_ignore_ascii_case("readme.md"))
        .count()
        == 2;
    if case_sensitive {
        assert_eq!(
            paths,
            vec![
                ("README.md", true),
                ("SKILL.md", false),
                ("readme.md", true),
                ("references/deep.md", false),
            ]
        );
    } else {
        let folded: Vec<(bool, bool)> = files
            .iter()
            .map(|f| (f.path.eq_ignore_ascii_case("readme.md"), f.is_readme))
            .collect();
        assert_eq!(folded.iter().filter(|(is, _)| *is).count(), 1);
        assert!(folded.iter().all(|(is, marked)| is == marked));
        assert_eq!(files.len(), 3);
    }
    assert!(files.iter().all(|f| f.size > 0));
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_file_reads_capped_and_traversal_is_refused() {
    let w = world();
    install(&w);
    let file = detail::package_file(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        "references/deep.md",
    )
    .unwrap();
    assert_eq!(file.content, "deep file");
    assert!(!file.truncated);

    for bad in ["../../../etc/passwd", "/etc/passwd", ""] {
        let error = detail::package_file(&w.env, &w.scope, ItemKind::Skill, "gh", bad).unwrap_err();
        assert!(
            matches!(error, CoreError::SourceEscape { .. }),
            "{bad}: {error}"
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_exact_readme_wins_over_case_variants() {
    let w = world();
    install(&w);
    let readme = detail::package_readme(&w.env, &w.scope, ItemKind::Skill, "gh")
        .unwrap()
        .unwrap();
    assert_eq!(readme.content, "# The readme\n");
}

/// A skill kendex never declared — dropped straight onto disk the way a
/// harness's own installer, or a hand-edit, would leave it — still has to
/// preview: the manifest has nothing to say about it, but the files are
/// real.
#[test]
#[allow(clippy::unwrap_used)]
fn an_undeclared_item_still_reads_from_disk() {
    let w = world();
    let dir = w.home.join("app/.claude/skills/loose");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("SKILL.md"), "---\nname: loose\n---\nBody.\n").unwrap();
    fs::write(dir.join("README.md"), "# Loose\n").unwrap();

    let files = detail::package_files(&w.env, &w.scope, ItemKind::Skill, "loose").unwrap();
    let paths: Vec<&str> = files.iter().map(|f| f.path.as_str()).collect();
    assert_eq!(paths, vec!["README.md", "SKILL.md"]);

    let file =
        detail::package_file(&w.env, &w.scope, ItemKind::Skill, "loose", "SKILL.md").unwrap();
    assert_eq!(file.content, "---\nname: loose\n---\nBody.\n");

    let readme = detail::package_readme(&w.env, &w.scope, ItemKind::Skill, "loose")
        .unwrap()
        .unwrap();
    assert_eq!(readme.content, "# Loose\n");
}

/// A project whose manifest is still v1 cannot be parsed for declarations
/// at all — that must not stop the preview for what is actually on disk,
/// any more than a declared-but-absent-from-the-manifest item does.
#[test]
#[allow(clippy::unwrap_used)]
fn a_v1_manifest_still_lets_disk_items_preview() {
    let w = world();
    let path = manifest::manifest_path(&w.env, &w.scope);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(&path, "[skills.gh]\nsource = \"cat\"\n").unwrap();

    let dir = w.home.join("app/.claude/skills/loose");
    fs::create_dir_all(&dir).unwrap();
    fs::write(dir.join("SKILL.md"), "---\nname: loose\n---\nBody.\n").unwrap();

    let files = detail::package_files(&w.env, &w.scope, ItemKind::Skill, "loose").unwrap();
    assert_eq!(files.len(), 1);
    assert_eq!(files[0].path, "SKILL.md");
}

/// Neither declared nor on disk: the error is about the missing item, not
/// about version holds — `NotDeclared`'s wording stays reserved for the
/// version-hold call sites that mean it.
#[test]
#[allow(clippy::unwrap_used)]
fn neither_declared_nor_on_disk_is_a_plain_not_found() {
    let w = world();
    let error = detail::package_files(&w.env, &w.scope, ItemKind::Skill, "ghost").unwrap_err();
    assert!(
        matches!(error, CoreError::PackageNotFound { .. }),
        "{error}"
    );
    assert!(error.to_string().contains("ghost"), "{error}");
    assert!(!error.to_string().contains("held at a version"), "{error}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn meta_names_the_version_the_link_and_the_fork() {
    let w = world();
    let commit = install(&w);
    let meta = detail::package_meta(&w.env, &w.scope, ItemKind::Skill, "gh").unwrap();
    assert_eq!(meta.source, "cat");
    assert_eq!(meta.repo.as_deref(), Some(REPO));
    assert_eq!(
        meta.repo_url.as_deref(),
        Some("https://github.com/owner/catalog")
    );
    let current = meta.current.unwrap();
    assert_eq!(current.commit, commit);
    assert_eq!(current.label.as_deref(), Some("v1"));
    assert!(meta.installed_at.is_some());
    assert!(meta.fork.is_none());
    assert!(meta.enabled);

    // Fork it: meta says so, and the source flips to local.
    fs::write(
        w.home.join("app/.agents/skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: mine\n---\nMine.\n",
    )
    .unwrap();
    let plan = kendex_core::engine::fork::fork(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        kendex_core::model::HarnessId::Claude,
    )
    .unwrap();
    apply::execute(&w.env, &plan).unwrap();
    let meta = detail::package_meta(&w.env, &w.scope, ItemKind::Skill, "gh").unwrap();
    assert_eq!(meta.source, "local");
    let fork = meta.fork.unwrap();
    assert_eq!(fork.source, "cat");
    assert_eq!(fork.repo.as_deref(), Some(REPO));
    assert_eq!(fork.commit.as_deref(), Some(commit.as_str()));
}

/// Two tools sharing one folder reach it through a symlink, and the seal
/// resolves its own root — so an unresolved item path sits outside it and
/// every read is refused. This is the shape most shared skills install in.
#[test]
#[allow(clippy::unwrap_used)]
fn a_shared_install_reached_through_a_symlink_still_reads() {
    let w = world();
    let real = w.home.join(".agents/skills/shared");
    fs::create_dir_all(&real).unwrap();
    fs::write(real.join("SKILL.md"), "---\nname: shared\n---\nBody.\n").unwrap();

    let link = w.home.join("app/.claude/skills/shared");
    fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink(&real, &link).unwrap();

    let file =
        detail::package_file(&w.env, &w.scope, ItemKind::Skill, "shared", "SKILL.md").unwrap();
    assert_eq!(file.content, "---\nname: shared\n---\nBody.\n");
}
