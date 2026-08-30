//! The package diff: line counts and hunks between two versions, the
//! installed-vs-version view a fork decision reads, and the budgets that
//! keep hostile or huge content a label instead of a hang.
#![cfg(unix)]

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::manifest;
use kendex_core::model::{ItemKind, Scope};
use kendex_core::package::diff::{FileStatus, LineKind, VersionSel, package_diff};
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
    let home = tmp.path().to_path_buf();
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
fn install_gh(w: &World) {
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
}

#[allow(clippy::unwrap_used)]
fn write_gh(w: &World, files: &[(&str, &[u8])]) {
    let dir = w.upstream.join("skills/gh");
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    for (name, bytes) in files {
        let path = dir.join(name);
        fs::create_dir_all(path.parent().unwrap()).unwrap();
        fs::write(path, bytes).unwrap();
    }
}

const V1: &str = "---\nname: gh\ndescription: github flows\n---\nline one\nline two\nline three\n";
const V2: &str = "---\nname: gh\ndescription: github flows\n---\nline one\nline 2 changed\nline three\nline four\n";

#[test]
#[allow(clippy::unwrap_used)]
fn a_version_diff_counts_lines_and_shapes_hunks() {
    let w = world();
    write_gh(
        &w,
        &[("SKILL.md", V1.as_bytes()), ("gone.md", b"old file\n")],
    );
    let first = commit(&w.upstream, "one");
    write_gh(
        &w,
        &[("SKILL.md", V2.as_bytes()), ("extra.md", b"new file\n")],
    );
    let second = commit(&w.upstream, "two");
    install_gh(&w);

    let diff = package_diff(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        &VersionSel::Commit(first),
        &VersionSel::Commit(second),
        None,
    )
    .unwrap();

    let paths: Vec<&str> = diff.files.iter().map(|f| f.path.as_str()).collect();
    assert_eq!(paths, vec!["SKILL.md", "extra.md", "gone.md"]);
    let skill = &diff.files[0];
    assert_eq!(skill.status, FileStatus::Modified);
    assert_eq!((skill.additions, skill.deletions), (2, 1));
    assert_eq!(diff.files[1].status, FileStatus::Added);
    assert_eq!(diff.files[2].status, FileStatus::Removed);
    assert_eq!(diff.total_additions, 2 + 1);
    assert_eq!(diff.total_deletions, 1 + 1);
    assert!(!diff.truncated);

    let hunk = &skill.hunks[0];
    assert!(hunk.header.starts_with("@@ -"), "{}", hunk.header);
    let added: Vec<&str> = hunk
        .lines
        .iter()
        .filter(|line| line.kind == LineKind::Add)
        .map(|line| line.text.as_str())
        .collect();
    assert_eq!(added, vec!["line 2 changed", "line four"]);
    let removed: Vec<&Option<u32>> = hunk
        .lines
        .iter()
        .filter(|line| line.kind == LineKind::Remove)
        .map(|line| &line.new_no)
        .collect();
    assert_eq!(removed, vec![&None], "a removed line has no new number");
}

#[test]
#[allow(clippy::unwrap_used)]
fn installed_vs_version_shows_the_local_edit() {
    let w = world();
    write_gh(&w, &[("SKILL.md", V1.as_bytes())]);
    let first = commit(&w.upstream, "one");
    install_gh(&w);
    let installed = w.home.join("app/.agents/skills/gh/SKILL.md");
    let text = fs::read_to_string(&installed).unwrap();
    fs::write(&installed, text.replace("line two", "my edited line")).unwrap();

    let diff = package_diff(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        &VersionSel::Commit(first),
        &VersionSel::Installed,
        None,
    )
    .unwrap();
    let skill = diff
        .files
        .iter()
        .find(|file| file.path == "SKILL.md")
        .unwrap();
    let added: Vec<&str> = skill
        .hunks
        .iter()
        .flat_map(|hunk| hunk.lines.iter())
        .filter(|line| line.kind == LineKind::Add)
        .map(|line| line.text.as_str())
        .collect();
    assert!(added.contains(&"my edited line"), "{added:?}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn binary_and_oversize_files_are_labeled_not_diffed() {
    let w = world();
    let big = "x\n".repeat(20_000);
    write_gh(
        &w,
        &[
            ("SKILL.md", V1.as_bytes()),
            ("blob.bin", &[0u8, 1, 2, 3][..]),
            ("huge.md", big.as_bytes()),
        ],
    );
    let first = commit(&w.upstream, "one");
    write_gh(
        &w,
        &[
            ("SKILL.md", V1.as_bytes()),
            ("blob.bin", &[9u8, 9, 9][..]),
            ("huge.md", format!("{big}tail\n").as_bytes()),
        ],
    );
    let second = commit(&w.upstream, "two");
    install_gh(&w);

    let diff = package_diff(
        &w.env,
        &w.scope,
        ItemKind::Skill,
        "gh",
        &VersionSel::Commit(first),
        &VersionSel::Commit(second),
        None,
    )
    .unwrap();
    let by_path = |path: &str| diff.files.iter().find(|f| f.path == path).unwrap();
    assert_eq!(by_path("blob.bin").status, FileStatus::Binary);
    assert!(by_path("blob.bin").hunks.is_empty());
    assert_eq!(by_path("huge.md").status, FileStatus::TooLarge);
    assert!(by_path("huge.md").hunks.is_empty());
}
