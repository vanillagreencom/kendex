//! Phase 5 end to end: a fresh consuming repo installs from the DEFAULT
//! remote catalog, customizes it, and refreshes clean — the GitHub host
//! swapped for a local file:// git fixture via KENDEX_GIT_BASE.
#![cfg(unix)]

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("KENDEX_GIT_BASE", format!("file://{}/git", home.display()))
        .output()
        .expect("kendex binary runs")
}

#[allow(clippy::unwrap_used)]
fn git(dir: &Path, args: &[&str]) {
    // The caller's git environment is dropped: run from a commit hook,
    // GIT_DIR and friends point at the repository being committed to and
    // every command here would act on that one instead of this fixture.
    let output = Command::new("git")
        .args(["-c", "user.email=t@t", "-c", "user.name=t"])
        .args(args)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_OBJECT_DIRECTORY")
        .env_remove("GIT_PREFIX")
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "git {args:?} failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[allow(clippy::unwrap_used)]
fn children(dir: &Path) -> Vec<std::path::PathBuf> {
    let mut entries: Vec<std::path::PathBuf> = fs::read_dir(dir)
        .unwrap()
        .flatten()
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
        .collect();
    entries.sort();
    entries
}

/// The one directory `dir` holds, asserting that it holds exactly one.
#[allow(clippy::unwrap_used)]
fn only_child(dir: &Path) -> std::path::PathBuf {
    let mut entries = children(dir);
    assert_eq!(
        entries.len(),
        1,
        "{dir:?} should hold exactly one directory"
    );
    entries.pop().unwrap()
}

/// The default catalog, served as a real git repo under the rebased host
/// path `git/vanillagreencom/kendex`.
#[allow(clippy::unwrap_used)]
fn fixture() -> tempfile::TempDir {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let upstream = home.join("git/vanillagreencom/kendex");
    fs::create_dir_all(upstream.join("skills/gh")).unwrap();
    fs::write(
        upstream.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: github flows\n---\nUpstream v1.\n",
    )
    .unwrap();
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    git(&upstream, &["add", "."]);
    git(&upstream, &["commit", "--quiet", "-m", "one"]);

    // Claude is detected globally and marks the project.
    fs::create_dir_all(home.join(".claude")).unwrap();
    fs::create_dir_all(home.join("proj/.claude")).unwrap();
    tmp
}

#[test]
#[allow(clippy::unwrap_used)]
fn consuming_repo_installs_customizes_and_refreshes_from_the_default_catalog() {
    let tmp = fixture();
    let home = tmp.path();
    let proj = home.join("proj");

    // Install with NO source argument: the seeded default source resolves
    // remotely, is fetched into the cache, and the skill lands.
    let output = kendex(home, &proj, &["add", "--skill", "gh", "-y"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    let manifest = fs::read_to_string(proj.join("kendex.toml")).unwrap();
    assert!(manifest.contains("[sources.kendex]"), "{manifest}");
    assert!(manifest.contains("vanillagreencom/kendex"), "{manifest}");
    let rendered = proj.join(".agents/skills/gh/SKILL.md");
    assert!(
        fs::read_to_string(&rendered)
            .unwrap()
            .contains("Upstream v1"),
    );
    assert!(proj.join(".claude/skills/gh").is_symlink());
    // The platform cache root the binary itself resolves: macOS caches
    // under Library/Caches and ignores XDG variables.
    #[cfg(target_os = "macos")]
    let sources = home.join("Library/Caches/kendex/sources");
    #[cfg(not(target_os = "macos"))]
    let sources = home.join(".cache/kendex/sources");
    let installed = only_child(&only_child(&sources.join("commits")));
    assert!(installed.join("skills/gh/SKILL.md").is_file());
    assert!(only_child(&sources.join("mirrors")).join("HEAD").is_file());
    assert!(kendex(home, &proj, &["verify"]).status.success());

    // Customize: a project skill instruction re-renders into the skill.
    let manifest = format!("{manifest}\n[skill-instructions]\ngh = \"Team note.\"\n");
    fs::write(proj.join("kendex.toml"), manifest).unwrap();
    let output = kendex(home, &proj, &["refresh"]);
    assert!(output.status.success());
    assert!(
        fs::read_to_string(&rendered)
            .unwrap()
            .contains("Team note."),
    );
    assert!(kendex(home, &proj, &["verify"]).status.success());

    // Upstream moves; refresh re-syncs the cache and regenerates.
    let upstream = home.join("git/vanillagreencom/kendex");
    fs::write(
        upstream.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: github flows\n---\nUpstream v2.\n",
    )
    .unwrap();
    git(&upstream, &["commit", "--quiet", "-am", "two"]);
    let output = kendex(home, &proj, &["refresh"]);
    assert!(output.status.success());
    let text = fs::read_to_string(&rendered).unwrap();
    assert!(text.contains("Upstream v2"), "{text}");
    assert!(text.contains("Team note."), "{text}");
    assert!(kendex(home, &proj, &["verify"]).status.success());

    // The refresh published the new commit beside the old one instead of
    // resetting a shared checkout: the first commit's bytes are still there.
    assert_eq!(children(&only_child(&sources.join("commits"))).len(), 2);
    assert!(
        fs::read_to_string(installed.join("skills/gh/SKILL.md"))
            .unwrap()
            .contains("Upstream v1")
    );
}
