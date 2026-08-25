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

fn said(output: &Output) -> String {
    String::from_utf8_lossy(&output.stderr).into_owned()
}

/// [`git`] for a command whose output is the answer.
#[allow(clippy::unwrap_used)]
fn git_stdout(dir: &Path, args: &[&str]) -> String {
    let output = Command::new("git")
        .args(args)
        .current_dir(dir)
        .env_remove("GIT_DIR")
        .env_remove("GIT_WORK_TREE")
        .env_remove("GIT_INDEX_FILE")
        .env_remove("GIT_OBJECT_DIRECTORY")
        .env_remove("GIT_PREFIX")
        .output()
        .unwrap();
    assert!(output.status.success(), "git {args:?}");
    String::from_utf8_lossy(&output.stdout).trim().to_owned()
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

/// `kendex updates` names the place at the head of every line: the same
/// package out of date at user level and in a project must never read as
/// two copies of one line.
#[test]
#[allow(clippy::unwrap_used)]
fn updates_lines_lead_with_their_place() {
    let tmp = fixture();
    let home = tmp.path();
    let proj = home.join("proj");
    for args in [
        &["add", "--skill", "gh", "-y"][..],
        &["add", "--skill", "gh", "-y", "--global"][..],
    ] {
        let output = kendex(home, &proj, args);
        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
    }

    let upstream = home.join("git/vanillagreencom/kendex");
    fs::write(
        upstream.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: github flows\n---\nUpstream v2.\n",
    )
    .unwrap();
    git(&upstream, &["commit", "--quiet", "-am", "two"]);

    let output = kendex(home, &proj, &["updates", "--refresh"]);
    assert!(output.status.success());
    let said = String::from_utf8_lossy(&output.stderr);
    let line = said
        .lines()
        .find(|line| line.contains("skill gh"))
        .unwrap_or_else(|| panic!("no gh line in {said}"));
    let root = proj.canonicalize().unwrap();
    assert!(
        line.starts_with(&format!("{}  skill gh", root.display())),
        "{line}"
    );

    let output = kendex(home, &proj, &["updates", "--global"]);
    assert!(output.status.success());
    let said = String::from_utf8_lossy(&output.stderr);
    assert!(
        said.lines()
            .any(|line| line.starts_with("global  skill gh")),
        "{said}"
    );
}

/// `kendex pin` moves one hold and nothing else. Planned whole-scope, it
/// brings every other follower current as a side effect — an unasked-for
/// version bump landing on a package the person only wanted left alone.
#[test]
#[allow(clippy::unwrap_used)]
fn pinning_one_package_leaves_the_scopes_followers_where_they_are() {
    let tmp = fixture();
    let home = tmp.path();
    let proj = home.join("proj");
    let upstream = home.join("git/vanillagreencom/kendex");

    fs::create_dir_all(upstream.join("skills/sib")).unwrap();
    fs::write(
        upstream.join("skills/sib/SKILL.md"),
        "---\nname: sib\ndescription: the neighbour\n---\nSibling v1.\n",
    )
    .unwrap();
    git(&upstream, &["add", "."]);
    git(&upstream, &["commit", "--quiet", "-m", "two"]);

    let output = kendex(
        home,
        &proj,
        &["add", "--skill", "gh", "--skill", "sib", "-y"],
    );
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );

    // Both packages move upstream; only `gh` is asked to.
    fs::write(
        upstream.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: github flows\n---\nUpstream v2.\n",
    )
    .unwrap();
    fs::write(
        upstream.join("skills/sib/SKILL.md"),
        "---\nname: sib\ndescription: the neighbour\n---\nSibling v2.\n",
    )
    .unwrap();
    git(&upstream, &["commit", "--quiet", "-am", "three"]);
    let tip = git_stdout(&upstream, &["rev-parse", "HEAD"]);

    let output = kendex(home, &proj, &["pin", "skill", "gh", &tip, "-y"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );

    let gh = fs::read_to_string(proj.join(".agents/skills/gh/SKILL.md")).unwrap();
    assert!(gh.contains("Upstream v2"), "the hold moved: {gh}");
    let sib = fs::read_to_string(proj.join(".agents/skills/sib/SKILL.md")).unwrap();
    assert!(
        sib.contains("Sibling v1"),
        "holding one package must not bring the scope's other followers current: {sib}"
    );
    let manifest = fs::read_to_string(proj.join("kendex.toml")).unwrap();
    assert!(manifest.contains(&tip), "the hold is recorded: {manifest}");
}

/// `kendex updates apply <kind> <name>` says what it did, and a copy the
/// person changed by hand is said about rather than written over — the one
/// verdict that must never read as "applied" when nothing moved.
#[test]
#[allow(clippy::unwrap_used)]
fn updates_apply_names_what_moved_and_what_was_held_back() {
    let tmp = fixture();
    let home = tmp.path();
    let proj = home.join("proj");
    let upstream = home.join("git/vanillagreencom/kendex");

    let output = kendex(home, &proj, &["add", "--skill", "gh", "-y"]);
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );

    fs::write(
        upstream.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: github flows\n---\nUpstream v2.\n",
    )
    .unwrap();
    git(&upstream, &["commit", "--quiet", "-am", "two"]);
    assert!(
        kendex(home, &proj, &["updates", "--refresh"])
            .status
            .success()
    );

    let applied = said(&kendex(home, &proj, &["updates", "apply", "skill", "gh"]));
    assert!(
        applied.contains("applied — skill gh is current here"),
        "{applied}"
    );
    let rendered = proj.join(".agents/skills/gh/SKILL.md");
    assert!(
        fs::read_to_string(&rendered)
            .unwrap()
            .contains("Upstream v2")
    );

    // Now the person edits their copy and upstream moves again: the plan
    // holds the edited rendering back, and the run has to say so.
    fs::write(
        &rendered,
        "---\nname: gh\ndescription: mine\n---\nMy own words.\n",
    )
    .unwrap();
    fs::write(
        upstream.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: github flows\n---\nUpstream v3.\n",
    )
    .unwrap();
    git(&upstream, &["commit", "--quiet", "-am", "three"]);
    assert!(
        kendex(home, &proj, &["updates", "--refresh"])
            .status
            .success()
    );

    let held = said(&kendex(home, &proj, &["updates", "apply", "skill", "gh"]));
    assert!(
        held.contains("skill gh is held back by the conflict above — nothing moved for it"),
        "{held}"
    );
    assert!(
        !held.contains("applied —"),
        "a held-back package must never read as applied: {held}"
    );
    assert_eq!(
        fs::read_to_string(&rendered).unwrap(),
        "---\nname: gh\ndescription: mine\n---\nMy own words.\n",
        "the edited copy survives the run that refused to write over it"
    );
}

/// The verb takes a kind the engine never derives only to refuse it: a Pi
/// extension installs through its own path, so planning one here comes
/// back empty and "nothing to change" would be a success-shaped answer for
/// work that cannot happen.
#[test]
#[allow(clippy::unwrap_used)]
fn updates_apply_refuses_a_kind_with_no_per_package_update() {
    let tmp = fixture();
    let home = tmp.path();
    let proj = home.join("proj");
    assert!(
        kendex(home, &proj, &["add", "--skill", "gh", "-y"])
            .status
            .success()
    );

    let refused = kendex(home, &proj, &["updates", "apply", "pi-extension", "gh"]);
    let printed = said(&refused);
    assert!(!refused.status.success(), "{printed}");
    assert!(
        printed.contains("has no per-package update"),
        "the refusal says what it will not do: {printed}"
    );
    assert!(
        printed.contains("kendex update-pi"),
        "and names the path that does move a Pi extension: {printed}"
    );
    assert!(
        !printed.contains("nothing to change"),
        "never the already-current answer: {printed}"
    );

    // The help stops advertising a kind this verb refuses.
    let help = said(&kendex(home, &proj, &["updates", "apply", "--help"]))
        + &String::from_utf8_lossy(&kendex(home, &proj, &["updates", "apply", "--help"]).stdout);
    assert!(help.contains("mcp-server"), "{help}");
    assert!(
        !help.contains("| pi-extension"),
        "pi-extension is no longer offered as a kind: {help}"
    );
}
