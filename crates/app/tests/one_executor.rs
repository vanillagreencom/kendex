//! One executor for a report, held by a fixture rather than by a comment.
//!
//! `repo_effects::execute` is where a report's plan gets written, because
//! that is where a leaving package's uninstaller runs while its scripts
//! are still on disk. A command that reaches past it into
//! `apply::execute(env, &report.plan)` compiles, previews the same, and
//! leaves the repository armed against files it just deleted — which is
//! how every desktop path came to do it. So the rule is read off the
//! source: nothing here executes a plan it took off a report.

use std::path::{Path, PathBuf};

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

fn src() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("src")
}

#[allow(clippy::unwrap_used)]
fn rust_files(dir: &Path, found: &mut Vec<PathBuf>) {
    for entry in std::fs::read_dir(dir).unwrap() {
        let path = entry.unwrap().path();
        if path.is_dir() {
            rust_files(&path, found);
        } else if path.extension().is_some_and(|ext| ext == "rs") {
            found.push(path);
        }
    }
}

/// The executor itself writes the plan — that is what it is for. A file of
/// tests reaching for core's apply is exercising core, not writing a
/// command's report.
fn exempt(path: &Path) -> bool {
    let stem = path.file_stem().and_then(|stem| stem.to_str());
    matches!(stem, Some("repo_effects" | "tests"))
}

/// Every line in `dir` that writes a plan it took off a report.
fn offenders(dir: &Path) -> Vec<String> {
    let mut files = Vec::new();
    rust_files(dir, &mut files);
    assert!(!files.is_empty(), "no sources found under {dir:?}");
    let mut found = Vec::new();
    for path in files.iter().filter(|path| !exempt(path)) {
        let text = std::fs::read_to_string(path).unwrap_or_default();
        for (n, line) in text.lines().enumerate() {
            if line.contains("apply::execute(") && line.contains(".plan") {
                found.push(format!("{}:{}: {}", path.display(), n + 1, line.trim()));
            }
        }
    }
    found
}

#[test]
fn no_command_executes_a_report_s_plan_itself() {
    let found = offenders(&src());
    assert!(
        found.is_empty(),
        "these write a report's plan without running the leaving packages' \
         uninstallers — call repo_effects::execute instead:\n{}",
        found.join("\n")
    );
}

/// The scan run red once, over the shape the bug had — and left alone by
/// the bare plan a command is allowed to execute on its own.
#[test]
#[allow(clippy::unwrap_used)]
fn the_scan_names_a_report_s_plan_and_spares_a_bare_one() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let nested = root.join("marketplaces");
    std::fs::create_dir_all(&nested).unwrap();
    std::fs::write(
        nested.join("install.rs"),
        "fn write(env: &Env, report: &EngineReport) {\n\
         \x20   apply::execute(env, &report.plan).unwrap();\n}\n",
    )
    .unwrap();
    std::fs::write(
        root.join("packages.rs"),
        "fn write(env: &Env, plan: &Plan) {\n\
         \x20   apply::execute(env, plan).unwrap();\n}\n",
    )
    .unwrap();

    let found = offenders(&root);
    assert_eq!(found.len(), 1, "{found:?}");
    assert!(found[0].contains("install.rs:2"), "{found:?}");
}
