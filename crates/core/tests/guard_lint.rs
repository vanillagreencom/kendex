//! The lint lanes red and green: rust-fmt on real rustfmt, rust-clippy
//! scoped to the staged file's owning manifest on real clippy, biome
//! against a fake project-pinned binary, and the pre-commit chain
//! carrying all three.
#![cfg(unix)]

use std::path::{Path, PathBuf};

use kendex_core::guard::{self, GuardCtx, lint};
use kendex_core::process::Hardened;

struct Repo {
    _tmp: tempfile::TempDir,
    root: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn git(root: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(root)).run().unwrap();
    assert!(
        output.status.success(),
        "git {args:?}: {}",
        String::from_utf8_lossy(&output.stderr)
    );
}

#[allow(clippy::unwrap_used)]
fn repo() -> Repo {
    let tmp = tempfile::tempdir().unwrap();
    let root = tmp.path().canonicalize().unwrap();
    git(&root, &["init", "--quiet", "-b", "main"]);
    git(&root, &["config", "user.email", "t@t"]);
    git(&root, &["config", "user.name", "t"]);
    Repo { _tmp: tmp, root }
}

#[allow(clippy::unwrap_used)]
fn stage(repo: &Repo, path: &str, content: &str) {
    let target = repo.root.join(path);
    std::fs::create_dir_all(target.parent().unwrap()).unwrap();
    std::fs::write(&target, content).unwrap();
    git(&repo.root, &["add", "--", path]);
}

fn ctx(repo: &Repo) -> GuardCtx {
    GuardCtx {
        root: repo.root.clone(),
        index_file: None,
    }
}

fn package_manifest(name: &str) -> String {
    format!("[package]\nname = \"{name}\"\nversion = \"0.0.0\"\nedition = \"2021\"\n")
}

#[test]
#[allow(clippy::unwrap_used)]
fn rust_fmt_flags_unformatted_staged_rust_then_passes_formatted() {
    let r = repo();
    stage(&r, "Cargo.toml", &package_manifest("fixture"));
    stage(&r, "src/lib.rs", "pub fn f( ) ->  u8 {  7 }\n");
    let out = lint::run_fmt(&ctx(&r)).unwrap();
    assert!(out.violations > 0, "unformatted staged rust must fail");
    assert!(out.lines.iter().any(|l| l.contains("rust-fmt FAIL")));

    stage(&r, "src/lib.rs", "pub fn f() -> u8 {\n    7\n}\n");
    let out = lint::run_fmt(&ctx(&r)).unwrap();
    assert_eq!(out.violations, 0, "{:?}", out.lines);
}

#[test]
#[allow(clippy::unwrap_used)]
fn rust_clippy_answers_for_the_owning_manifest_only() {
    let r = repo();
    // Two sibling crates, no root manifest: the staged file's crate is
    // linted against its own manifest, the unstaged sibling's warning
    // must not block.
    stage(&r, "warned/Cargo.toml", &package_manifest("warned"));
    stage(
        &r,
        "warned/src/lib.rs",
        "pub fn f() -> u8 {\n    let unused = 1;\n    7\n}\n",
    );
    stage(&r, "clean/Cargo.toml", &package_manifest("clean"));
    stage(&r, "clean/src/lib.rs", "pub fn g() -> u8 {\n    9\n}\n");

    let out = lint::run_clippy(&ctx(&r)).unwrap();
    assert!(out.violations > 0, "denied warning must fail");
    assert!(
        out.lines
            .iter()
            .any(|l| l.contains("rust-clippy FAIL") && l.contains("warned")),
        "{:?}",
        out.lines
    );

    // Only the clean crate staged: the sibling's warning stays its own.
    git(&r.root, &["commit", "-qm", "fixture"]);
    stage(&r, "clean/src/lib.rs", "pub fn g() -> u8 {\n    8\n}\n");
    let out = lint::run_clippy(&ctx(&r)).unwrap();
    assert_eq!(out.violations, 0, "{:?}", out.lines);
}

#[test]
#[allow(clippy::unwrap_used)]
fn rust_lanes_skip_visibly_when_no_manifest_owns_the_files() {
    let r = repo();
    stage(&r, "fixtures/sample.rs", "fn  ugly( ){}\n");
    let out = lint::run_fmt(&ctx(&r)).unwrap();
    assert_eq!(out.violations, 0);
    assert!(
        out.lines
            .iter()
            .any(|l| l.contains("no Cargo.toml owns the staged .rs files")),
        "{:?}",
        out.lines
    );
}

/// A fake pinned biome recording its invocation; exit code and output come
/// from the fixture files beside it.
#[allow(clippy::unwrap_used)]
fn install_fake_biome(repo: &Repo, exit: i32) {
    let bin = repo.root.join("node_modules/.bin");
    std::fs::create_dir_all(&bin).unwrap();
    let script = format!(
        "#!/bin/sh\nprintf '%s\\n' \"$@\" > args.log\n[ {exit} -ne 0 ] && echo 'lint error: noUnusedVariables at src/x.js:1:1'\nexit {exit}\n"
    );
    let path = bin.join("biome");
    std::fs::write(&path, script).unwrap();
    use std::os::unix::fs::PermissionsExt;
    std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o755)).unwrap();
}

#[test]
#[allow(clippy::unwrap_used)]
fn biome_runs_the_pinned_binary_over_staged_paths() {
    let r = repo();
    stage(&r, "biome.json", "{}\n");
    stage(&r, "src/x.js", "let x = 1\n");
    install_fake_biome(&r, 1);
    let out = lint::run_biome(&ctx(&r)).unwrap();
    assert_eq!(out.violations, 1, "{:?}", out.lines);
    assert!(out.lines.iter().any(|l| l.contains("biome FAIL")));
    assert!(out.lines.iter().any(|l| l.contains("noUnusedVariables")));
    let args = std::fs::read_to_string(r.root.join("args.log")).unwrap();
    assert!(args.contains("--no-errors-on-unmatched"));
    assert!(args.contains("src/x.js"));
    assert!(
        args.contains("biome.json"),
        "staged json rides along: {args}"
    );

    install_fake_biome(&r, 0);
    let out = lint::run_biome(&ctx(&r)).unwrap();
    assert_eq!(out.violations, 0, "{:?}", out.lines);
}

#[test]
#[allow(clippy::unwrap_used)]
fn biome_stays_out_of_non_biome_projects_and_says_so_without_a_binary() {
    let r = repo();
    stage(&r, "src/x.js", "let x = 1\n");
    let out = lint::run_biome(&ctx(&r)).unwrap();
    assert_eq!(out.violations, 0);
    assert!(out.lines.iter().any(|l| l.contains("not a Biome project")));

    // A Biome project with no binary anywhere skips out loud. The PATH
    // fallback is hidden from the child so a machine with a real biome
    // still exercises the no-binary answer.
    stage(&r, "biome.json", "{}\n");
    let out = lint::run_biome(&ctx(&r)).unwrap();
    if !path_has_biome() {
        assert!(
            out.lines.iter().any(|l| l.contains("no biome binary")),
            "{:?}",
            out.lines
        );
    }
    assert_eq!(out.violations, 0, "{:?}", out.lines);
}

fn path_has_biome() -> bool {
    std::env::var_os("PATH")
        .is_some_and(|paths| std::env::split_paths(&paths).any(|dir| dir.join("biome").is_file()))
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_pre_commit_chain_carries_the_lint_lanes() {
    let r = repo();
    stage(&r, "README.md", "hello\n");
    let report = guard::run_pre_commit(&ctx(&r));
    for lane in ["=== rust-fmt", "=== rust-clippy", "=== biome"] {
        assert!(
            report.lines.iter().any(|l| l.starts_with(lane)),
            "missing {lane}: {:?}",
            report.lines
        );
    }
    assert_eq!(report.exit_code(), 0, "{:?}", report.lines);
}

#[test]
#[allow(clippy::unwrap_used)]
fn biome_keeps_a_dash_named_staged_path_a_path_operand() {
    let r = repo();
    stage(&r, "biome.json", "{}\n");
    stage(&r, "--config-path=x.json", "{}\n");
    install_fake_biome(&r, 0);
    lint::run_biome(&ctx(&r)).unwrap();
    let args = std::fs::read_to_string(r.root.join("args.log")).unwrap();
    let words: Vec<&str> = args.lines().collect();
    assert!(words.contains(&"./--config-path=x.json"), "{args}");
    assert!(
        !words.contains(&"--config-path=x.json"),
        "a staged path reached biome's option position: {args}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn biome_blocks_when_the_pinned_launcher_cannot_run() {
    use std::os::unix::fs::PermissionsExt;
    let r = repo();
    stage(&r, "biome.json", "{}\n");
    stage(&r, "src/x.js", "let x = 1\n");
    let bin = r.root.join("node_modules/.bin");
    std::fs::create_dir_all(&bin).unwrap();
    let launcher = bin.join("biome");
    // The real launcher is `#!/usr/bin/env node`; an absent interpreter
    // is ENOENT from execve — the errno a missing binary gives — and must
    // still block, not skip.
    std::fs::write(&launcher, "#!/nonexistent/interpreter\nexit 0\n").unwrap();
    std::fs::set_permissions(&launcher, std::fs::Permissions::from_mode(0o755)).unwrap();
    let error = lint::run_biome(&ctx(&r)).unwrap_err().to_string();
    assert!(
        error.contains("could not run") && error.contains("node_modules/.bin/biome"),
        "{error}"
    );

    // A launcher that starts but cannot find its command exits 127 with
    // env's complaint: a tool that could not run, not a lint finding.
    std::fs::write(
        &launcher,
        "#!/bin/sh\necho 'env: node: No such file or directory' >&2\nexit 127\n",
    )
    .unwrap();
    let error = lint::run_biome(&ctx(&r)).unwrap_err().to_string();
    assert!(
        error.contains("could not run") && error.contains("env: node"),
        "{error}"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_chain_skips_clippy_once_fmt_has_blocked_the_commit() {
    let r = repo();
    stage(&r, "Cargo.toml", &package_manifest("fixture"));
    stage(&r, "src/lib.rs", "pub fn f( ) ->  u8 {  7 }\n");
    let report = guard::run_pre_commit(&ctx(&r));
    assert_eq!(report.exit_code(), 1, "{:?}", report.lines);
    assert!(
        report
            .lines
            .contains(&"=== rust-clippy: skipped — rust-fmt already blocked the commit".to_owned()),
        "{:?}",
        report.lines
    );
    assert!(
        !report.lines.iter().any(|l| l.starts_with("rust-clippy")),
        "clippy ran after fmt failed: {:?}",
        report.lines
    );
}
