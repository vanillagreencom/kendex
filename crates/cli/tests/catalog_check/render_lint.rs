//! The trusted repository catalog must install files its shipped lanes accept.

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

use super::{kendex, rooted};

#[allow(clippy::unwrap_used)]
fn command(home: &Path, project: &Path, program: &Path, args: &[&str]) -> Output {
    Command::new(program)
        .args(args)
        .current_dir(project)
        .env_clear()
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", std::env::var("PATH").unwrap())
        // Include extensionless scripts and hooks. The shipped extractor
        // decides which installed files have a comment grammar.
        .env("COMMIT_GUARDS_COMMENT_PATHS", "*")
        .output()
        .unwrap()
}

fn success(output: Output) {
    assert!(
        output.status.success(),
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn installed_catalog_passes_comment_and_prose_lanes() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("consumer");
    let catalog = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap();
    // Project discovery uses a harness marker. The manifest alone does not
    // stop its ancestor walk at this fixture.
    fs::create_dir_all(project.join(".agents")).unwrap();
    success(command(&home, &project, Path::new("git"), &["init", "-q"]));
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n[sources.catalog]\n{}\n",
            crate::test_util::source_path(&catalog)
        ),
    )
    .unwrap();
    // The CLI's catalog discovery selects every package. Copy delivery makes
    // every harness output available to the index-based scanners.
    success(kendex(
        &home,
        &project,
        &["add", "catalog", "--all", "--all-harnesses", "--copy", "-y"],
    ));
    let scripts = project.join(".claude/skills/commit-guards/scripts");
    let controls = [
        (
            "comments",
            ".claude/skills/review-gate/templates/review-gate-writer.yml",
            "# Regression history: #2107\n",
        ),
        (
            "comments",
            ".claude/hooks/command-safety.sh",
            "# Regression history: #2107\n",
        ),
        (
            "comments",
            ".claude/skills/commit-guards/scripts/install-git-hooks",
            "# Regression history: #2107\n",
        ),
        (
            "prose",
            ".claude/skills/review-gate/SKILL.md",
            "Regression history: #2107\n",
        ),
    ];
    // Stage only each planted output for its control. A failure must name
    // that output, so an unrelated catalog finding cannot pass the control.
    for (lane, relative, defect) in controls {
        let path = project.join(relative);
        let original = fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("installed control {relative}: {error}"));
        fs::write(&path, format!("{original}\n{defect}")).unwrap();
        success(command(
            &home,
            &project,
            Path::new("git"),
            &["add", "--", relative],
        ));
        let output = command(&home, &project, &scripts.join(lane), &[]);
        assert_eq!(output.status.code(), Some(1), "{output:?}");
        let said = String::from_utf8_lossy(&output.stdout);
        assert!(said.contains(relative), "{said}");
        assert!(said.contains("history reference"), "{said}");
        fs::write(path, original).unwrap();
        success(command(
            &home,
            &project,
            Path::new("git"),
            &["rm", "--cached", "-f", "--", relative],
        ));
    }
    // Git discovers the complete installed tree. No catalog or harness path
    // allowlist can hide a newly shipped file from an applicable lane.
    success(command(&home, &project, Path::new("git"), &["add", "-A"]));
    for lane in ["prose", "comments"] {
        success(command(&home, &project, &scripts.join(lane), &[]));
    }
}
