//! End to end: a fresh consuming repo installs from the DEFAULT
//! remote catalog, customizes it, and refreshes clean — the GitHub host
//! swapped for a local file:// git fixture via KENDEX_GIT_BASE.
#![cfg(unix)]

use crate::test_util;

use std::fs;
use std::io::{Read, Seek};
use std::path::{Path, PathBuf};
use std::process::{Command, Output, Stdio};
use std::time::{Duration, Instant};

use kendex_core::attest::{Document, State};

fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    run(launch(home, cwd, args))
}

/// [`kendex`] with one more variable in the binary's environment.
fn kendex_with(home: &Path, cwd: &Path, args: &[&str], var: (&str, &str)) -> Output {
    let mut command = launch(home, cwd, args);
    command.env(var.0, var.1);
    run(command)
}

/// The binary against the fixture home, before it runs.
fn launch(home: &Path, cwd: &Path, args: &[&str]) -> Command {
    let mut command = Command::new(env!("CARGO_BIN_EXE_kendex"));
    command
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .env("KENDEX_GIT_BASE", format!("file://{}/git", home.display()));
    command
}

/// How long one run may take before the suite fails it: a fetch that
/// never returns would otherwise hang the suite instead of failing it.
const RUN_LIMIT: Duration = Duration::from_secs(120);

/// The run to its end, or a failure at [`RUN_LIMIT`]. Its output goes to
/// files rather than pipes, so a child that fills a pipe cannot stall
/// while nothing reads it.
#[allow(clippy::expect_used)]
fn run(mut command: Command) -> Output {
    let mut stdout = tempfile::tempfile().expect("stdout file");
    let mut stderr = tempfile::tempfile().expect("stderr file");
    let mut child = command
        .stdin(Stdio::null())
        .stdout(stdout.try_clone().expect("stdout handle"))
        .stderr(stderr.try_clone().expect("stderr handle"))
        .spawn()
        .expect("kendex binary runs");
    let deadline = Instant::now() + RUN_LIMIT;
    let status = loop {
        if let Some(status) = child.try_wait().expect("the run reports its state") {
            break status;
        }
        if Instant::now() >= deadline {
            let _ = child.kill();
            let _ = child.wait();
            panic!("kendex {:?} ran past {RUN_LIMIT:?}", command.get_args());
        }
        std::thread::sleep(Duration::from_millis(20));
    };
    let drain = |file: &mut fs::File| {
        let mut bytes = Vec::new();
        file.rewind().expect("output rewinds");
        file.read_to_end(&mut bytes).expect("output reads");
        bytes
    };
    Output {
        status,
        stdout: drain(&mut stdout),
        stderr: drain(&mut stderr),
    }
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
        .env_remove("GIT_COMMON_DIR")
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
        .env_remove("GIT_COMMON_DIR")
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
fn refresh_uses_the_catalog_tag_without_changing_the_declared_revision() {
    for (case, revision, expected_body) in [
        ("tag", Some("vN"), "Upstream v1."),
        ("unset control", None, "Upstream HEAD."),
    ] {
        let tmp = fixture();
        let home = test_util::rooted(&tmp);
        let project = home.join("proj");
        let upstream = home.join("git/vanillagreencom/kendex");
        let tag_commit = git_stdout(&upstream, &["rev-parse", "HEAD"]);
        git(&upstream, &["tag", "vN"]);
        fs::write(
            upstream.join("skills/gh/SKILL.md"),
            "---\nname: gh\ndescription: github flows\n---\nUpstream HEAD.\n",
        )
        .unwrap();
        git(&upstream, &["commit", "--quiet", "-am", "head"]);
        let head_commit = git_stdout(&upstream, &["rev-parse", "HEAD"]);
        assert_ne!(tag_commit, head_commit, "{case}: fixture history");
        let manifest_path = project.join("kendex.toml");
        let manifest = b"schema = 8\n\n[sources.kendex]\nrepo = \"vanillagreencom/kendex\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.gh]\nsource = \"kendex\"\n";
        fs::write(&manifest_path, manifest).unwrap();
        let args = ["refresh", "--scope", "project", "--yes", "--leave"];
        let output = match revision {
            Some(rev) => kendex_with(&home, &project, &args, ("KENDEX_CATALOG_REV", rev)),
            None => kendex(&home, &project, &args),
        };
        assert!(output.status.success(), "{case}: {}", said(&output));
        let rendered_path = project.join(".claude/skills/gh/SKILL.md");
        let rendered = fs::read(&rendered_path).unwrap();
        assert_eq!(
            rendered,
            format!("---\nname: gh\ndescription: github flows\n---\n{expected_body}\n").as_bytes(),
            "{case}: rendered bytes"
        );
        assert_eq!(
            fs::read(&manifest_path).unwrap(),
            manifest,
            "{case}: manifest"
        );
        let lock_path = project.join(".kendex-lock.json");
        let lock_bytes = fs::read(&lock_path).unwrap();
        let lock: serde_json::Value = serde_json::from_slice(&lock_bytes).unwrap();
        let source = &lock["sources"]["kendex"];
        assert!(source.get("rev").is_none(), "{case}: lock selector");
        assert_eq!(
            source["commit"].as_str(),
            Some(if revision.is_some() {
                tag_commit.as_str()
            } else {
                head_commit.as_str()
            }),
            "{case}: lock commit"
        );
        // Apply has no override; its recorded commit must retain the tag's bytes.
        let before_apply = test_util::lane::snapshot(&project);
        let applied = kendex(
            &home,
            &project,
            &["apply", "--scope", "project", "--yes", "--leave"],
        );
        assert!(applied.status.success(), "{case}: {}", said(&applied));
        assert_eq!(
            test_util::lane::snapshot(&project),
            before_apply,
            "{case}: apply tree"
        );
    }
}

/// A check can start the download that a foreground refresh meets. The
/// refresh waits for that same kendex work, then installs from its result.
/// Holding the lock past the old short wait is the control for the change.
#[test]
#[allow(clippy::unwrap_used)]
fn refresh_waits_for_the_download_another_process_is_finishing() {
    let tmp = fixture();
    let home = test_util::rooted(&tmp);
    let project = home.join("proj");
    fs::write(
        project.join("kendex.toml"),
        "schema = 8\n\n[sources.kendex]\nrepo = \"vanillagreencom/kendex\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.gh]\nsource = \"kendex\"\n",
    )
    .unwrap();
    let env = kendex_core::env::Env::host_rooted(&home)
        .with_var("KENDEX_GIT_BASE", &format!("file://{}/git", home.display()));
    let key = kendex_core::remote::cache_key(&env, "vanillagreencom/kendex");
    let guard =
        kendex_core::remote::store::lock_repo(&env, &key, "vanillagreencom/kendex").unwrap();
    let child_home = home.clone();
    let child_project = project.clone();
    let refreshing = std::thread::spawn(move || {
        kendex(
            &child_home,
            &child_project,
            &["refresh", "--scope", "project", "--yes", "--leave"],
        )
    });

    std::thread::sleep(Duration::from_secs(1));
    drop(guard);
    let output = refreshing.join().unwrap();
    let printed = said(&output);

    assert!(output.status.success(), "{printed}");
    assert_eq!(
        printed.matches("another kendex process").count(),
        1,
        "{printed}"
    );
    assert!(!printed.contains("not fetched yet"), "{printed}");
    assert!(project.join(".claude/skills/gh/SKILL.md").is_file());
}

/// Preparing the sources a project's packages come from fetches those and
/// leaves an unreachable subscription nothing installs from alone, while
/// the all-source form still fails on it. Either way the project's manifest,
/// lock and installed files stay as they were, though upstream has moved.
#[test]
#[allow(clippy::unwrap_used)]
fn source_refresh_in_use_skips_an_unused_unreachable_source_and_writes_no_project_file() {
    let tmp = fixture();
    let home = test_util::rooted(&tmp);
    let project = home.join("proj");
    fs::write(
        project.join("kendex.toml"),
        "schema = 8\n\n[sources.kendex]\nrepo = \"vanillagreencom/kendex\"\n\n[sources.gone]\nrepo = \"owner/gone\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.gh]\nsource = \"kendex\"\n",
    )
    .unwrap();
    let installed = kendex(
        &home,
        &project,
        &["refresh", "--scope", "project", "--yes", "--leave"],
    );
    assert!(installed.status.success(), "{}", said(&installed));
    let upstream = home.join("git/vanillagreencom/kendex");
    fs::write(
        upstream.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: github flows\n---\nUpstream v2.\n",
    )
    .unwrap();
    git(&upstream, &["commit", "--quiet", "-am", "two"]);
    let moved = git_stdout(&upstream, &["rev-parse", "HEAD"]);
    let before = test_util::lane::snapshot(&project);

    let in_use = kendex(
        &home,
        &project,
        &["source", "refresh", "--scope", "project", "--in-use"],
    );
    assert!(in_use.status.success(), "{}", said(&in_use));
    let env = kendex_core::env::Env::host_rooted(&home)
        .with_var("KENDEX_GIT_BASE", &format!("file://{}/git", home.display()));
    assert_eq!(
        kendex_core::remote::mirror_commit(&env, "vanillagreencom/kendex", None),
        Some(moved)
    );
    let all = kendex(
        &home,
        &project,
        &["source", "refresh", "--scope", "project"],
    );
    assert!(!all.status.success(), "control: {}", said(&all));
    let conflicting = kendex(
        &home,
        &project,
        &["source", "refresh", "--in-use", "--stale"],
    );
    assert_eq!(conflicting.status.code(), Some(2), "{}", said(&conflicting));

    assert_eq!(test_util::lane::snapshot(&project), before);
}

/// A catalog served as `owner/<name>` under the rebased host, one skill
/// named after it; its commit.
#[allow(clippy::unwrap_used)]
fn named_catalog(home: &Path, name: &str) -> String {
    let upstream = home.join("git/owner").join(name);
    fs::create_dir_all(upstream.join("skills").join(name)).unwrap();
    fs::write(
        upstream.join("skills").join(name).join("SKILL.md"),
        format!("---\nname: {name}\ndescription: {name} flows\n---\nBody.\n"),
    )
    .unwrap();
    git(&upstream, &["init", "--quiet", "-b", "main"]);
    git(&upstream, &["add", "."]);
    git(&upstream, &["commit", "--quiet", "-m", name]);
    git_stdout(&upstream, &["rev-parse", "HEAD"])
}

/// The project's install record, as committed.
#[allow(clippy::unwrap_used)]
fn record_of(project: &Path) -> serde_json::Value {
    serde_json::from_slice(&fs::read(project.join(".kendex-lock.json")).unwrap()).unwrap()
}

/// What a project's install record says on a worker that never fetched
/// anything. A warm machine wrote it while `spare`, a subscription no
/// package uses, sat in its cache, so the record names `spare`. `extra`,
/// reachable and subscribed since, the record never named. The project is
/// committed, then this machine's source cache goes. Returns the project
/// and `spare`'s commit.
#[allow(clippy::unwrap_used)]
fn recorded_on_a_warm_machine(home: &Path) -> (PathBuf, String) {
    let project = home.join("proj");
    let spare = named_catalog(home, "spare");
    named_catalog(home, "extra");
    git(&project, &["init", "--quiet", "-b", "main"]);
    fs::write(
        project.join("kendex.toml"),
        "schema = 8\n\n[sources.kendex]\nrepo = \"vanillagreencom/kendex\"\n\n[sources.spare]\nrepo = \"owner/spare\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.gh]\nsource = \"kendex\"\n",
    )
    .unwrap();
    for args in [
        &["source", "refresh", "--scope", "project"][..],
        &["refresh", "--scope", "project", "--yes", "--leave"],
    ] {
        let output = kendex(home, &project, args);
        assert!(output.status.success(), "warm {args:?}: {}", said(&output));
    }
    assert_eq!(
        record_of(&project)["sources"]["spare"]["commit"].as_str(),
        Some(spare.as_str()),
        "the warm record names spare"
    );
    let mut manifest = fs::read_to_string(project.join("kendex.toml")).unwrap();
    manifest.push_str("\n[sources.extra]\nrepo = \"owner/extra\"\n");
    fs::write(project.join("kendex.toml"), manifest).unwrap();
    git(&project, &["add", "-A"]);
    git(&project, &["commit", "--quiet", "-m", "warm record"]);
    let env = kendex_core::env::Env::host_rooted(home);
    fs::remove_dir_all(env.source_cache_dir()).unwrap();
    if env.drift_dir().exists() {
        fs::remove_dir_all(env.drift_dir()).unwrap();
    }
    (project, spare)
}

/// Whether `owner/<name>`'s mirror answers on this machine.
fn fetched(home: &Path, name: &str) -> bool {
    let env = kendex_core::env::Env::host_rooted(home)
        .with_var("KENDEX_GIT_BASE", &format!("file://{}/git", home.display()));
    kendex_core::remote::mirror_commit(&env, &format!("owner/{name}"), None).is_some()
}

/// One `verify --json` run and the document it printed.
#[allow(clippy::unwrap_used)]
fn verified(home: &Path, project: &Path, args: &[&str]) -> (Output, Document) {
    let output = kendex(home, project, args);
    let document = serde_json::from_slice(&output.stdout)
        .unwrap_or_else(|error| panic!("the document does not parse: {error}\n{}", said(&output)));
    (output, document)
}

/// The record row of a verify document.
#[allow(clippy::unwrap_used)]
fn record_row(document: &Document) -> &kendex_core::attest::Row {
    document
        .rows
        .iter()
        .find(|row| row.kind == "record" && row.name == ".kendex-lock.json")
        .unwrap()
}

/// The shipped full route on a cold worker: refresh, apply and verify. The
/// record pass reads `spare` from its mirror, so the refresh fetches it, and
/// the record row passes with `spare` recorded at its commit. `extra`, which
/// the record never named, stays unfetched and unrecorded.
#[test]
#[allow(clippy::unwrap_used)]
fn a_cold_refresh_fetches_the_unused_subscription_the_record_names() {
    let tmp = fixture();
    let home = test_util::rooted(&tmp);
    let (project, spare) = recorded_on_a_warm_machine(&home);

    for args in [
        ["refresh", "--scope", "project", "--yes", "--leave"],
        ["apply", "--scope", "project", "--yes", "--leave"],
    ] {
        let output = kendex(&home, &project, &args);
        assert!(output.status.success(), "{args:?}: {}", said(&output));
    }
    let (output, document) = verified(&home, &project, &["verify", "--scope", "project", "--json"]);

    let record = record_row(&document);
    assert_eq!(record.state, State::Ok, "{record:?}");
    assert!(output.status.success(), "{}", said(&output));
    let written = record_of(&project);
    assert_eq!(
        written["sources"]["spare"]["commit"].as_str(),
        Some(spare.as_str())
    );
    assert!(written["sources"].get("extra").is_none(), "{written}");
    assert!(!fetched(&home, "extra"));
}

/// The review preparation on a cold worker: `source refresh --in-use`
/// fetches `spare`, which the record names, and not `extra`, so verifying
/// at the record against the committed base passes. The all-source refresh
/// is the control: it fetches `extra` too, and the same verify fails the
/// record row on it.
#[test]
#[allow(clippy::unwrap_used)]
fn the_review_preparation_fetches_what_verifying_at_the_record_reads() {
    let tmp = fixture();
    let home = test_util::rooted(&tmp);
    let (project, _) = recorded_on_a_warm_machine(&home);
    let at_record = [
        "verify",
        "--scope",
        "project",
        "--json",
        "--at-record",
        "--base",
        "HEAD",
    ];

    let prepared = kendex(
        &home,
        &project,
        &["source", "refresh", "--scope", "project", "--in-use"],
    );
    assert!(prepared.status.success(), "{}", said(&prepared));
    let (output, document) = verified(&home, &project, &at_record);
    let record = record_row(&document);
    assert_eq!(record.state, State::Ok, "{record:?}");
    assert!(output.status.success(), "{}", said(&output));
    assert!(!fetched(&home, "extra"));

    let all = kendex(
        &home,
        &project,
        &["source", "refresh", "--scope", "project"],
    );
    assert!(all.status.success(), "{}", said(&all));
    let (output, document) = verified(&home, &project, &at_record);
    let record = record_row(&document);
    assert_eq!(record.state, State::Failed, "control: {record:?}");
    // verify --json is the document harness-ci's change-class reads; a
    // record problem names its subject first.
    let detail = record.detail.as_deref().unwrap_or_default();
    assert!(
        detail.contains("source extra:") && !detail.contains("source spare:"),
        "control: {detail}"
    );
    assert!(!output.status.success(), "control: {}", said(&output));
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

    // The refresh publishes the second commit beside the first instead of
    // resetting a shared checkout: the first commit's bytes are still there.
    assert_eq!(children(&only_child(&sources.join("commits"))).len(), 2);
    assert!(
        fs::read_to_string(installed.join("skills/gh/SKILL.md"))
            .unwrap()
            .contains("Upstream v1")
    );
}

/// A refresh that removes older snapshots from the source cache says how
/// many: with nothing kept past what the lock names, the third commit's
/// arrival takes the first one, which nothing names any more.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refresh_says_how_many_snapshots_it_removed() {
    let tmp = fixture();
    let home = tmp.path();
    let proj = home.join("proj");
    let upstream = home.join("git/vanillagreencom/kendex");
    let keep = ("KENDEX_SOURCE_CACHE_KEEP", "0");
    assert!(
        kendex(home, &proj, &["add", "--skill", "gh", "-y"])
            .status
            .success()
    );
    #[cfg(target_os = "macos")]
    let sources = home.join("Library/Caches/kendex/sources");
    #[cfg(not(target_os = "macos"))]
    let sources = home.join(".cache/kendex/sources");
    let commits = only_child(&sources.join("commits"));

    for (body, removed) in [("Upstream v2.", None), ("Upstream v3.", Some("1"))] {
        fs::write(
            upstream.join("skills/gh/SKILL.md"),
            format!("---\nname: gh\ndescription: github flows\n---\n{body}\n"),
        )
        .unwrap();
        git(&upstream, &["commit", "--quiet", "-am", body]);
        let output = kendex_with(home, &proj, &["refresh", "-y"], keep);
        assert!(output.status.success(), "{}", said(&output));
        let printed = said(&output);
        match removed {
            Some(count) => assert!(
                printed.contains(&format!(
                    "cache: removed {count} older marketplace snapshot\n"
                )),
                "{printed}"
            ),
            None => assert!(!printed.contains("older marketplace snapshot"), "{printed}"),
        }
        assert_eq!(children(&commits).len(), 2, "{printed}");
    }
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
        line.starts_with(&format!("{}  skill gh", kendex_core::paths::slashed(&root))),
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

/// `--refresh` is a fetch the person asked for before anything reads a
/// catalog, and the listing reads one. Skipped, the run answers from the
/// mirror as it already stands rather than from an explicit ask for fresh.
#[test]
#[allow(clippy::unwrap_used)]
fn updates_refresh_fetches_before_the_listing() {
    let tmp = fixture();
    let home = tmp.path();
    let proj = home.join("proj");
    let upstream = home.join("git/vanillagreencom/kendex");
    assert!(
        kendex(home, &proj, &["add", "--skill", "gh", "-y"])
            .status
            .success()
    );

    fs::write(
        upstream.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: github flows\n---\nUpstream v2.\n",
    )
    .unwrap();
    git(&upstream, &["commit", "--quiet", "-am", "two"]);

    // Without the flag the mirror is never asked, so the run has nothing
    // newer to report.
    let stale = said(&kendex(home, &proj, &["updates"]));
    assert!(
        stale.contains("everything is on its latest version"),
        "no fetch was asked for, so nothing newer was found: {stale}"
    );

    // With it, the fetch happens first and the listing sees the later commit.
    let printed = said(&kendex(home, &proj, &["updates", "--refresh"]));
    assert!(
        printed.lines().any(|line| line.contains("skill gh")),
        "{printed}"
    );
    assert!(
        !printed.contains("everything is on its latest version"),
        "{printed}"
    );
}

/// Muting reads no catalog, so `--refresh` beside it has nothing to be
/// ahead of and must not spend the network on every source.
#[test]
#[allow(clippy::unwrap_used)]
fn updates_refresh_does_not_fetch_for_a_settings_only_verb() {
    let tmp = fixture();
    let home = tmp.path();
    let proj = home.join("proj");
    assert!(
        kendex(home, &proj, &["add", "--skill", "gh", "-y"])
            .status
            .success()
    );

    // The source's own directory is gone: a fetch could only fail, and a
    // failed fetch says so.
    fs::rename(
        home.join("git/vanillagreencom/kendex"),
        home.join("git/moved-away"),
    )
    .unwrap();

    let muted = kendex(
        home,
        &proj,
        &["updates", "--refresh", "ignore", "skill", "gh"],
    );
    let printed = said(&muted);
    assert!(muted.status.success(), "{printed}");
    assert!(
        !printed.contains("warning:"),
        "no source was fetched, so none could complain: {printed}"
    );
}

/// Bringing the whole place current and changing one package's setting
/// are different asks; a run that carries both silently does one of them.
#[test]
#[allow(clippy::unwrap_used)]
fn updates_refuses_a_whole_place_apply_beside_a_named_package() {
    let tmp = fixture();
    let home = tmp.path();
    let proj = home.join("proj");
    assert!(
        kendex(home, &proj, &["add", "--skill", "gh", "-y"])
            .status
            .success()
    );

    let refused = kendex(
        home,
        &proj,
        &["updates", "--apply", "ignore", "skill", "gh"],
    );
    let printed = said(&refused);
    assert!(!refused.status.success(), "{printed}");
    // Neither ask ran: the package is not muted, and nothing was applied.
    let listed = kendex(home, &proj, &["updates"]);
    let rows = said(&listed);
    assert!(listed.status.success(), "{rows}");
    assert!(
        !rows.contains("ignored"),
        "the refused run muted the package: {rows}"
    );
    assert!(
        !printed.contains("updated"),
        "the refused run applied something: {printed}"
    );
}

/// An install edited on disk is a standing fact the listing says, with or
/// without a newer version behind it: Home counts every edited package,
/// and a listing that stayed silent about one with nothing newer would
/// disagree with it about the same scope.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edited_install_is_listed_even_with_nothing_newer() {
    let tmp = fixture();
    let home = tmp.path();
    let proj = home.join("proj");
    fs::create_dir_all(&proj).unwrap();
    let output = kendex(home, &proj, &["add", "--skill", "gh", "-y"]);
    assert!(output.status.success(), "{}", said(&output));

    let clean = said(&kendex(home, &proj, &["updates"]));
    assert!(
        clean.contains("everything is on its latest version"),
        "{clean}"
    );

    fs::write(
        proj.join(".agents/skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: github flows\n---\nMy edit.\n",
    )
    .unwrap();
    let edited = said(&kendex(home, &proj, &["updates"]));
    let line = edited
        .lines()
        .find(|line| line.contains("skill gh"))
        .unwrap_or_else(|| panic!("no gh line in {edited}"));
    assert!(line.contains("[edited on disk"), "{line}");
    assert!(
        !edited.contains("everything is on its latest version"),
        "{edited}"
    );
}

/// A pending positional repository is never mistaken for the personal
/// scope's default. The personal fetch a bare add into a fresh project
/// makes reads the pending alias off the personal manifest; a request that
/// names its repository derives the same alias a personal subscription may
/// happen to use, and that unrelated repository must stay unfetched. Drop
/// the bare-add gate and this case is what goes red.
#[test]
#[allow(clippy::unwrap_used)]
fn a_pending_positional_repository_never_fetches_a_personal_alias_twin() {
    let tmp = fixture();
    let home = tmp.path();
    let proj = home.join("proj");
    // The personal scope subscribes to other/tools as "tools", the alias a
    // positional acme/tools derives; only other/tools has an upstream.
    let other = home.join("git/other/tools");
    fs::create_dir_all(other.join("skills/gh")).unwrap();
    fs::write(
        other.join("skills/gh/SKILL.md"),
        "---\nname: gh\ndescription: github flows\n---\nOther.\n",
    )
    .unwrap();
    git(&other, &["init", "--quiet", "-b", "main"]);
    git(&other, &["add", "."]);
    git(&other, &["commit", "--quiet", "-m", "one"]);
    let env = kendex_core::env::Env::host_rooted(home)
        .with_var("KENDEX_GIT_BASE", &format!("file://{}/git", home.display()));
    let personal = env.global_manifest_file();
    fs::create_dir_all(personal.parent().unwrap()).unwrap();
    fs::write(
        &personal,
        "schema = 8\n\n[sources.tools]\nrepo = \"other/tools\"\n",
    )
    .unwrap();

    let output = kendex(home, &proj, &["add", "acme/tools", "--skill", "gh", "-y"]);

    assert!(!output.status.success(), "{}", said(&output));
    assert_eq!(
        kendex_core::remote::cache_head(&env, "other/tools", None),
        None,
        "the personal twin was fetched for a positional repository"
    );
    assert!(!proj.join("kendex.toml").exists());
}

/// The upstream at `upstream` offering its one skill `skill` as the
/// `starter` bundle.
#[allow(clippy::unwrap_used)]
fn offer_bundle(upstream: &Path, skill: &str) {
    fs::write(
        upstream.join("kendex.toml"),
        format!("[bundles.starter]\ndescription = \"the starter set\"\nskills = [\"{skill}\"]\n"),
    )
    .unwrap();
    git(upstream, &["add", "."]);
    git(upstream, &["commit", "--quiet", "-m", "bundle"]);
}

/// A first add on a home that never downloaded the repository it names
/// downloads it: nothing on disk declares that repository until the add
/// lands, and the personal scope holds no package and no manifest. The
/// `owner/tools` row names a repository the personal scope does not
/// subscribe to, so a retry that downloads the personal default instead
/// installs nothing; the default catalog's row is the reported spelling,
/// whose alias the personal seed also declares.
#[test]
#[allow(clippy::unwrap_used)]
fn a_first_add_of_a_bundle_downloads_the_repository_it_names() {
    // Whether the row serves its own catalog beside the default one, which
    // the add must then leave undownloaded.
    for (repo, skill, own_catalog) in [
        ("owner/tools", "tools", true),
        ("vanillagreencom/kendex", "gh", false),
    ] {
        let tmp = fixture();
        let home = test_util::rooted(&tmp);
        let proj = home.join("proj");
        if own_catalog {
            named_catalog(&home, skill);
        }
        offer_bundle(&home.join("git").join(repo), skill);
        let env = kendex_core::env::Env::host_rooted(&home)
            .with_var("KENDEX_GIT_BASE", &format!("file://{}/git", home.display()));
        assert!(!env.global_manifest_file().exists());

        let output = kendex(
            &home,
            &proj,
            &[
                "add",
                repo,
                "--bundle",
                "starter",
                "--harness",
                "claude",
                "-y",
            ],
        );

        assert!(output.status.success(), "{repo}: {}", said(&output));
        assert!(
            proj.join(".claude/skills")
                .join(skill)
                .join("SKILL.md")
                .exists(),
            "{repo}: {}",
            said(&output)
        );
        let manifest = fs::read_to_string(proj.join("kendex.toml")).unwrap();
        assert!(manifest.contains("[bundles.starter]"), "{repo}: {manifest}");
        if own_catalog {
            assert_eq!(
                kendex_core::remote::mirror_commit(&env, "vanillagreencom/kendex", None),
                None,
                "{repo}: the add downloaded the default catalog, which it never names"
            );
        }
    }
}

/// The personal scope reads as subscribed to the default catalog before
/// it writes a manifest, so refreshing it downloads that catalog, and
/// subscribes the scope to nothing on disk.
#[test]
#[allow(clippy::unwrap_used)]
fn a_personal_refresh_with_no_manifest_downloads_the_default_catalog() {
    let tmp = fixture();
    let home = test_util::rooted(&tmp);
    let env = kendex_core::env::Env::host_rooted(&home)
        .with_var("KENDEX_GIT_BASE", &format!("file://{}/git", home.display()));
    assert!(!env.global_manifest_file().exists());

    let output = kendex(&home, &home, &["source", "refresh", "--global"]);

    assert!(output.status.success(), "{}", said(&output));
    assert!(
        kendex_core::remote::mirror_commit(&env, "vanillagreencom/kendex", None).is_some(),
        "{}",
        said(&output)
    );
    assert!(!env.global_manifest_file().exists());
}
