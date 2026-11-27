//! `orch-runtime tier` through the built binary, over the catalog's own
//! change-scope launch arm in a planted install layout: the cycle each class
//! opens and the line a launch brief carries, the touched set the body and
//! the brief name, and each refusal with its exit.
#![allow(
    clippy::disallowed_methods,
    reason = "the process rows build fixture repositories and run the binary and its programs"
)]

mod support;

use std::fs;
use std::path::{Path, PathBuf};
use std::process::Output;

use support::{isolated, program, stderr};

fn change_scope() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../change-scope")
}

fn git(dir: &Path, args: &[&str]) -> String {
    let out = program("git")
        .arg("-C")
        .arg(dir)
        .args(args)
        .output()
        .unwrap();
    assert!(out.status.success(), "git {args:?}: {}", stderr(&out));
    String::from_utf8_lossy(&out.stdout).trim_end().to_owned()
}

/// A checkout with one commit, change-scope's scripts and references copied
/// beside it as an install lays them out, and the files a row writes.
struct World {
    _dir: tempfile::TempDir,
    root: PathBuf,
    repo: PathBuf,
    scripts: PathBuf,
}

impl World {
    fn new() -> World {
        let dir = tempfile::tempdir().unwrap();
        let root = fs::canonicalize(dir.path()).unwrap();
        let package = root.join("change-scope");
        for part in ["scripts", "references"] {
            copy_tree(&change_scope().join(part), &package.join(part));
        }
        let repo = root.join("repo");
        fs::create_dir_all(&repo).unwrap();
        git(&repo, &["init", "-q", "-b", "main"]);
        for (k, v) in [
            ("gc.auto", "0"),
            ("maintenance.auto", "false"),
            ("commit.gpgsign", "false"),
            ("user.email", "tier@example.invalid"),
            ("user.name", "tier"),
        ] {
            git(&repo, &["config", k, v]);
        }
        fs::write(repo.join("seed"), "seed\n").unwrap();
        // The classifier measures a range only over a base that holds the
        // generated-file inventory.
        fs::write(
            repo.join(".kendex-generated.json"),
            "[\".kendex-generated.json\"]\n",
        )
        .unwrap();
        git(&repo, &["add", "."]);
        git(&repo, &["commit", "-qm", "seed"]);
        World {
            _dir: dir,
            scripts: package.join("scripts"),
            root,
            repo,
        }
    }

    fn file(&self, name: &str, text: &str) -> PathBuf {
        let path = self.root.join(name);
        fs::write(&path, text).unwrap();
        path
    }

    fn tier(&self, args: &[&str]) -> Output {
        isolated()
            .env(
                "CHANGE_SCOPE_PATHS_CLI",
                self.scripts.join("harness-only").as_os_str(),
            )
            .arg("tier")
            .args(args)
            .arg("--repo")
            .arg(&self.repo)
            .output()
            .unwrap()
    }
}

fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let target = to.join(entry.file_name());
        if entry.file_type().unwrap().is_dir() {
            copy_tree(&entry.path(), &target);
        } else {
            support::copy_executable(&entry.path(), &target);
        }
    }
}

/// The exit, the stdout line and the first stderr line.
fn answer(out: &Output) -> (Option<i32>, String, String) {
    (
        out.status.code(),
        String::from_utf8_lossy(&out.stdout).trim_end().to_owned(),
        stderr(out).lines().next().unwrap_or_default().to_owned(),
    )
}

#[test]
fn each_input_opens_its_cycle_with_the_line_a_brief_carries() {
    let w = World::new();
    let small_body = w.file(
        "small-body",
        "**Location**: `src/a.rs`\n**Expected delta**: 40 lines\n",
    );
    let workflow_body = w.file(
        "workflow-body",
        "- **Location**: `.github/workflows/ci.yml`\n**Expected delta**: 4 lines\n",
    );
    let bare_body = w.file("bare-body", "**Location**: `src/a.rs:3-9`\nNo sizing.\n");
    // A Location path naming a folder in the checkout without its `/` is
    // classified as that folder, the spelling the launch's holders meet.
    fs::create_dir_all(w.repo.join(".github/workflows")).unwrap();
    let folder_body = w.file(
        "folder-body",
        "**Location**: `.github/workflows`\n**Expected delta**: 4 lines\n",
    );
    // Prose spans beside the path, one an option word, are not passed to
    // the arm, whose `--path` would read an option word as no value.
    let prose_body = w.file(
        "prose-body",
        "**Location**: `src/a.rs` (the `--overseer` branch of `classify`)\n**Expected delta**: 4 lines\n",
    );
    let rows: &[(&[&str], &str)] = &[
        (
            &["--production", "1"],
            "tier=micro brief=micro cause=estimate-within-micro production=1 estimate=1 delta=- paths=0",
        ),
        (
            &["--production", "40"],
            "tier=small brief=small cause=estimate-within-small production=40 estimate=40 delta=- paths=0",
        ),
        (
            &["--production", "151"],
            "tier=standard brief=start cause=estimate-past-small production=151 estimate=151 delta=- paths=0",
        ),
        (
            &["--production", "1", "--floor", "small"],
            "tier=small brief=small cause=floor class=small estimate=1 delta=- paths=0",
        ),
        (
            &["--production", "1", "--body", small_body.to_str().unwrap()],
            "tier=small brief=small cause=estimate-within-small production=40 estimate=1 delta=40 paths=1",
        ),
        (
            &["--body", workflow_body.to_str().unwrap()],
            "tier=standard brief=start cause=excluded-path path=.github/workflows/ci.yml glob=.github/workflows/* estimate=- delta=4 paths=1",
        ),
        (
            &["--body", folder_body.to_str().unwrap()],
            "tier=standard brief=start cause=excluded-path path=.github/workflows/ glob=.github/workflows/* estimate=- delta=4 paths=1",
        ),
        (
            &["--body", bare_body.to_str().unwrap()],
            "tier=standard brief=start cause=body-without-tier-inputs estimate=- delta=- paths=1",
        ),
        (
            &["--body", prose_body.to_str().unwrap()],
            "tier=micro brief=micro cause=estimate-within-micro production=4 estimate=- delta=4 paths=1",
        ),
    ];
    for (args, line) in rows {
        let out = w.tier(args);
        assert_eq!(answer(&out).0, Some(0), "{args:?}: {}", stderr(&out));
        assert_eq!(answer(&out).1, *line, "{args:?}");
    }
}

/// change-scope installed without its narrow-change ceilings cannot measure
/// an estimate: the verb answers the widest cycle with the arm's cause,
/// never a refusal and never a narrower cycle.
#[test]
fn an_unmeasured_classification_answers_standard_with_its_cause() {
    let w = World::new();
    fs::remove_file(w.scripts.join("../references/narrow-change.conf")).unwrap();
    let out = w.tier(&["--production", "1"]);
    assert_eq!(
        (out.status.code(), answer(&out).1),
        (
            Some(0),
            "tier=standard brief=start cause=narrow-change-unreadable estimate=1 delta=- paths=0"
                .to_owned()
        ),
        "{}",
        stderr(&out)
    );
}

/// `lines` lines appended to `path` in the checkout.
fn append(repo: &Path, path: &str, lines: usize) {
    let file = repo.join(path);
    fs::create_dir_all(file.parent().unwrap()).unwrap();
    let mut text = fs::read_to_string(&file).unwrap_or_default();
    for i in 0..lines {
        text.push_str(&format!("export const added_{i} = 1;\n"));
    }
    fs::write(file, text).unwrap();
}

/// A range is classified by its changed paths and by its production lines,
/// as review depth reads it, and its changed paths are counted. The MEM-460
/// range changes 7 files, 3 of them new, with 506 production lines added.
#[test]
fn a_range_is_classified_by_its_paths_and_its_production_lines() {
    let w = World::new();
    let modified = ["auth", "session", "store", "net"].map(|n| format!("apps/sidecar/src/{n}.ts"));
    for path in &modified {
        append(&w.repo, path, 60);
    }
    git(&w.repo, &["add", "."]);
    git(&w.repo, &["commit", "-qm", "sidecar"]);
    let base = git(&w.repo, &["rev-parse", "HEAD"]);
    let body = w.file(
        "body",
        "**Location**: `src/b.rs`\n**Expected delta**: 4 lines\n",
    );
    let body = body.to_str().unwrap();
    let ranges: &[(&str, &[(&str, usize)])] = &[
        ("micro", &[("src/a.rs", 20)]),
        ("small", &[("src/a.rs", 150)]),
        (
            "mem-460",
            &[
                ("apps/sidecar/src/auth.ts", 90),
                ("apps/sidecar/src/session.ts", 70),
                ("apps/sidecar/src/store.ts", 40),
                ("apps/sidecar/src/net.ts", 26),
                ("apps/sidecar/src/stall.ts", 120),
                ("apps/sidecar/src/retry.ts", 100),
                ("apps/sidecar/src/signal.ts", 60),
            ],
        ),
        ("markdown", &[("AGENTS.md", 1)]),
    ];
    for (branch, files) in ranges {
        git(&w.repo, &["checkout", "-q", "-B", branch, &base]);
        for (path, lines) in *files {
            append(&w.repo, path, *lines);
        }
        git(&w.repo, &["add", "."]);
        git(&w.repo, &["commit", "-qm", branch]);
    }
    let mem_460 = "tier=standard brief=start cause=branch-class class=standard rule=production-past-small production=506 estimate=- delta=- paths=7";
    let rows: &[(&str, &[&str], &str)] = &[
        (
            "micro",
            &[],
            "tier=micro brief=micro cause=branch-class class=micro rule=production-within-micro production=20 estimate=- delta=- paths=1",
        ),
        (
            "small",
            &[],
            "tier=small brief=small cause=branch-class class=small rule=production-within-small subsystem=src estimate=- delta=- paths=1",
        ),
        ("mem-460", &[], mem_460),
        ("mem-460", &["--floor", "small"], mem_460),
        (
            "markdown",
            &[],
            "tier=micro brief=micro cause=branch-class class=trivial rule=documentation-paths lines=1 estimate=- delta=- paths=1",
        ),
        (
            "micro",
            &["--body", body],
            "tier=micro brief=micro cause=estimate-within-micro production=4 estimate=- delta=4 paths=2",
        ),
    ];
    for (head, args, line) in rows {
        let mut argv = vec!["--base", base.as_str(), "--head", head];
        argv.extend_from_slice(args);
        let out = w.tier(&argv);
        assert_eq!(
            (out.status.code(), answer(&out).1.as_str()),
            (Some(0), *line),
            "{argv:?}: {}",
            stderr(&out)
        );
    }
}

/// The brief the launch will be given names a path outside the Location:
/// the touched set holds it, so the cycle widens, as the launch's own
/// admission would judge it.
#[test]
fn a_brief_naming_a_path_past_the_location_widens_the_cycle() {
    let w = World::new();
    let body = w.file(
        "body",
        "**Location**: `src/a.rs`\n**Expected delta**: 4 lines\n",
    );
    let brief = w.file(
        "brief",
        "Change `src/a.rs` and gate it in `.github/workflows/ci.yml`; see `changelog.d/x.md`.\n",
    );
    let alone = w.tier(&["--body", body.to_str().unwrap()]);
    assert_eq!(
        answer(&alone).1,
        "tier=micro brief=micro cause=estimate-within-micro production=4 estimate=- delta=4 paths=1"
    );
    let briefed = w.tier(&[
        "--body",
        body.to_str().unwrap(),
        "--brief",
        brief.to_str().unwrap(),
    ]);
    assert_eq!(
        answer(&briefed).1,
        "tier=standard brief=start cause=excluded-path path=.github/workflows/ci.yml glob=.github/workflows/* estimate=- delta=4 paths=2",
        "{}",
        stderr(&briefed)
    );
}

#[test]
fn a_body_to_refile_and_each_environment_failure_refuse_with_their_exit() {
    let w = World::new();
    let unlocated = w.file(
        "unlocated",
        "Every test suite\n**Expected delta**: 4 lines\n",
    );
    let pathless = w.file("pathless", "**Location**: the whole runtime\n");
    let missing = w.root.join("missing");
    let rows: Vec<(Vec<&str>, Option<i32>, String)> = vec![
        (
            vec!["--body", unlocated.to_str().unwrap()],
            Some(1),
            "orch-runtime: tier cause=no-location route=per-subsystem-split".to_owned(),
        ),
        (
            vec!["--production", "1", "--body", pathless.to_str().unwrap()],
            Some(1),
            "orch-runtime: tier cause=location-unread route=per-subsystem-split".to_owned(),
        ),
        (
            vec!["--production", "1", "--body", missing.to_str().unwrap()],
            Some(2),
            format!(
                "orch-runtime: tier cause=body-unreadable path={} error=entity-not-found",
                missing.display()
            ),
        ),
        (
            vec!["--floor", "tiny"],
            Some(2),
            "orch-runtime: tier cause=invalid-floor floor=tiny".to_owned(),
        ),
    ];
    for (args, exit, first) in rows {
        let out = w.tier(&args);
        assert_eq!(answer(&out), (exit, String::new(), first), "{args:?}");
    }
    for args in [
        &[][..],
        &["--production", "1x"][..],
        &["--base", "b"][..],
        &["--path", "src/a.rs"][..],
    ] {
        let out = w.tier(args);
        assert_eq!(
            (out.status.code(), out.stdout.is_empty()),
            (Some(2), true),
            "{args:?} is a usage error: {}",
            stderr(&out)
        );
    }
}

/// A range whose changed paths the path reader cannot read refuses: its
/// count is unknown, never zero.
#[test]
fn a_range_the_path_reader_cannot_read_refuses() {
    let w = World::new();
    let seed = git(&w.repo, &["rev-parse", "HEAD"]);
    fs::remove_file(w.scripts.join("harness-only")).unwrap();
    let out = w.tier(&["--base", &seed, "--head", "HEAD"]);
    assert_eq!(
        (out.status.code(), out.stdout.is_empty()),
        (Some(2), true),
        "{}",
        stderr(&out)
    );
    assert!(
        answer(&out)
            .2
            .starts_with("orch-runtime: tier cause=range-paths-unreadable detail="),
        "{}",
        stderr(&out)
    );
}

#[test]
fn a_malformed_delta_warning_reaches_the_caller() {
    let w = World::new();
    let body = w.file(
        "body",
        "**Location**: `src/a.rs`\n**Expected delta**: about 4 lines\n",
    );
    let out = w.tier(&["--production", "1", "--body", body.to_str().unwrap()]);
    assert_eq!(out.status.code(), Some(0));
    assert!(
        stderr(&out)
            .lines()
            .any(|l| l.starts_with("launch-warning: cause=invalid-delta line=[about 4 lines]")),
        "{}",
        stderr(&out)
    );
}

#[test]
fn a_change_scope_without_the_arm_or_none_at_all_is_refused_by_key() {
    let w = World::new();
    let arm = w.scripts.join("change-scope");
    let text = fs::read_to_string(&arm).unwrap();
    let dispatch = "if [ \"${1:-}\" = launch ]; then";
    assert_eq!(text.matches(dispatch).count(), 1);
    fs::write(&arm, text.replace(dispatch, "if false; then")).unwrap();
    let out = w.tier(&["--production", "1"]);
    assert_eq!(
        answer(&out),
        (
            Some(2),
            String::new(),
            format!(
                "orch-runtime: tier cause=launch-arm-absent path={}",
                arm.display()
            )
        )
    );
    fs::remove_file(&arm).unwrap();
    let out = w.tier(&["--production", "1"]);
    assert_eq!(
        answer(&out),
        (
            Some(2),
            String::new(),
            format!(
                "orch-runtime: tier cause=dependency-absent skill=change-scope path={}",
                arm.display()
            )
        )
    );
}
