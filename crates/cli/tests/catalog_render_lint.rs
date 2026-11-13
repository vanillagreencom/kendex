//! The trusted repository catalog must install files its shipped lanes accept.
//!
//! Its own target rather than a module of `catalog_check`: installing every
//! package on every harness and linting the result takes minutes on a macOS
//! runner, so it answers to a step bound of its own in
//! `.github/workflows/skill-tests.yml`.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use std::fs;
use std::path::Path;
use std::process::{Command, Output};

#[allow(clippy::expect_used)]
fn kendex(home: &Path, cwd: &Path, args: &[&str]) -> Output {
    Command::new(env!("CARGO_BIN_EXE_kendex"))
        .args(args)
        .current_dir(cwd)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("PATH", std::env::var("PATH").unwrap_or_default())
        .output()
        .expect("kendex binary runs")
}

#[allow(clippy::unwrap_used)]
fn command(home: &Path, project: &Path, program: &Path, args: &[&str]) -> Output {
    scoped_command(home, project, program, args, "*")
}

/// One lane run, with the paths it considers set to `scope`. The lane takes no
/// pathspec, so its own path setting is how a run is narrowed, and `*` is the
/// whole tree.
#[allow(clippy::unwrap_used)]
fn scoped_command(
    home: &Path,
    project: &Path,
    program: &Path,
    args: &[&str],
    scope: &str,
) -> Output {
    Command::new(program)
        .args(args)
        .current_dir(project)
        .env_clear()
        .envs(test_util::fixture_env(home))
        .env("PATH", std::env::var("PATH").unwrap())
        // A glob scope's Markdown is its `.md` files. A source-only control
        // must not parse shell code as Markdown.
        .env(
            "COMMIT_GUARDS_MD_REFS_PATHS",
            match scope.strip_suffix('*') {
                Some(prefix) => format!("{prefix}*.md"),
                None if scope.ends_with(".md") => scope.to_owned(),
                None => "__no_markdown__".to_owned(),
            },
        )
        .env("COMMIT_GUARDS_MD_REFS_SOURCE_PATHS", scope)
        .env("COMMIT_GUARDS_SETTINGS_FILE", "/dev/null")
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

/// The scopes a staged path set partitions into: one glob per top-level
/// directory, and each top-level file under its own name. Read out of the
/// staged paths, so a harness directory the renderer gains later takes a scope
/// with no edit here, and every staged path falls in exactly one.
fn lane_scopes(staged: &[String]) -> Vec<String> {
    let mut scopes: Vec<String> = staged
        .iter()
        .map(|path| match path.split_once('/') {
            Some((top, _)) => format!("{top}/*"),
            None => path.clone(),
        })
        .collect();
    scopes.sort_unstable();
    scopes.dedup();
    scopes
}

#[allow(clippy::unwrap_used)]
fn staged_paths(project: &Path) -> Vec<String> {
    // core.quotePath=false, or git wraps a path holding an unusual byte in
    // quotes and its first field reads as a quote instead of a directory.
    let output = Command::new("git")
        .args([
            "-c",
            "core.quotePath=false",
            "diff",
            "--cached",
            "--name-only",
        ])
        .current_dir(project)
        .env_clear()
        .env("PATH", std::env::var("PATH").unwrap())
        .output()
        .unwrap();
    assert!(output.status.success(), "{output:?}");
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(str::to_owned)
        .collect()
}

/// Every package of this repository's catalog, on every harness, copied into
/// a fresh project under `home`.
#[allow(clippy::unwrap_used)]
fn install_whole_catalog(home: &Path, project: &Path) {
    let catalog = Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("../..")
        .canonicalize()
        .unwrap();
    // Project discovery uses a harness marker. The manifest alone does not
    // stop its ancestor walk at this fixture.
    fs::create_dir_all(project.join(".agents")).unwrap();
    success(command(home, project, Path::new("git"), &["init", "-q"]));
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 8\n[sources.catalog]\n{}\n",
            test_util::source_path(&catalog)
        ),
    )
    .unwrap();
    // The CLI's catalog discovery selects every package. Copy delivery makes
    // every harness output available to the index-based scanners.
    success(kendex(
        home,
        project,
        &["add", "catalog", "--all", "--all-harnesses", "--copy", "-y"],
    ));
}

/// One run of a lane per scope, all at once, in scope order.
#[allow(clippy::expect_used)]
fn each_scope(
    home: &Path,
    project: &Path,
    program: &Path,
    args: &[&str],
    scopes: &[String],
) -> Vec<Output> {
    std::thread::scope(|threads| {
        let handles: Vec<_> = scopes
            .iter()
            .map(|scope| threads.spawn(|| scoped_command(home, project, program, args, scope)))
            .collect();
        handles
            .into_iter()
            .map(|handle| handle.join().expect("a lane thread finishes"))
            .collect()
    })
}

/// The whole staged tree through the reference lane. It costs a fork or more
/// per file it reads and is this crate's slowest work on macOS, so it runs
/// once per scope, concurrently, rather than once over the tree. The scopes
/// partition the staged set and the lane's own reached counts must add back up
/// to it: that, not the exit statuses alone, is what says no scope quietly
/// dropped a path. A scope narrows only which files the lane reads for
/// citations; it resolves each citation against the whole index, so a
/// citation into another scope is still judged.
fn every_staged_path_passes_the_reference_lane(home: &Path, project: &Path, scripts: &Path) {
    // Git discovers the complete installed tree. No catalog or harness path
    // allowlist can hide a newly shipped file from the lane.
    success(command(home, project, Path::new("git"), &["add", "-A"]));

    let staged = staged_paths(project);
    assert!(!staged.is_empty(), "the installed tree staged no path");
    let scopes = lane_scopes(&staged);
    let references = each_scope(
        home,
        project,
        &scripts.join("md-refs"),
        &["--all", "--strict"],
        &scopes,
    );
    assert_reference_coverage(&references, &staged);
    for (scope, output) in scopes.iter().zip(&references) {
        assert!(
            output.status.success(),
            "scope {scope}: {}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn installed_catalog_passes_reference_lane() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("consumer");
    install_whole_catalog(&home, &project);
    let scripts = project.join(".claude/skills/commit-guards/scripts");
    every_staged_path_passes_the_reference_lane(&home, &project, &scripts);
    install_reference_controls(&home, &project, &scripts);
}

/// These callers select every staged Markdown file for the document pass.
/// Markdown, source, and skipped counts, summed over the runs that partition
/// the staged set, must cover the selected paths. Counts plus the hook and
/// extensionless controls reject a scan that admits too few files.
fn assert_reference_coverage(outputs: &[Output], staged: &[String]) {
    let mut markdown = 0;
    let mut reached = 0;
    for output in outputs {
        let said = String::from_utf8_lossy(&output.stdout);
        let summary = said
            .lines()
            .find_map(|line| line.strip_prefix("md-refs: summary="))
            .unwrap_or_else(|| panic!("reference scan has no summary: {output:?}"));
        let count = |name: &str| {
            summary
                .split_whitespace()
                .find_map(|field| {
                    field
                        .strip_prefix(name)
                        .and_then(|value| value.parse::<usize>().ok())
                })
                .unwrap_or_else(|| panic!("reference scan has no {name} count: {summary}"))
        };
        markdown += count("markdown=");
        reached += count("markdown=") + count("sources=") + count("skipped=");
    }
    assert!(!staged.is_empty(), "installed catalog staged no files");
    assert_eq!(
        reached,
        staged.len(),
        "{} reference scans reached {reached} of {} staged paths",
        outputs.len(),
        staged.len()
    );
    assert_eq!(
        markdown,
        staged.iter().filter(|path| path.ends_with(".md")).count(),
        "{} reference scans selected {markdown} Markdown files",
        outputs.len()
    );
}

/// A source-layout citation can resolve before installation and be dead in
/// a consumer. The complete tree is scanned once above. Controls use that
/// scanner on one citing file, with a coverage count for each run.
#[allow(clippy::unwrap_used)]
fn install_reference_controls(home: &Path, project: &Path, scripts: &Path) {
    let callers = [
        (".claude/hooks/lane-mail-check.sh", "# "),
        (
            ".claude/skills/commit-guards/scripts/install-git-hooks",
            "# ",
        ),
        (".claude/skills/orch/SKILL.md", ""),
    ];
    let target = "skills/orch/references/oversee-events.md";
    assert!(
        !project.join("skills").exists(),
        "consumer has a source tree"
    );
    for (relative, prefix) in callers {
        let path = project.join(relative);
        let original = fs::read_to_string(&path).unwrap();
        let citation = format!("{prefix}`{target} § Judgement rules`\n");
        fs::write(&path, format!("{original}\n{citation}")).unwrap();
        fs::create_dir_all(project.join("skills/orch/references")).unwrap();
        fs::write(project.join(target), "# Events\n\n## Judgement rules\n").unwrap();
        success(command(home, project, Path::new("git"), &["add", "-A"]));
        let expected_paths = [relative.to_owned()];
        let output = scoped_command(
            home,
            project,
            &scripts.join("md-refs"),
            &["--all", "--strict"],
            relative,
        );
        assert_reference_coverage(std::slice::from_ref(&output), &expected_paths);
        success(output);

        success(command(
            home,
            project,
            Path::new("git"),
            &["rm", "-f", "--", target],
        ));
        let output = scoped_command(
            home,
            project,
            &scripts.join("md-refs"),
            &["--all", "--strict"],
            relative,
        );
        assert_reference_coverage(std::slice::from_ref(&output), &expected_paths);
        assert_eq!(output.status.code(), Some(1), "{output:?}");
        let expected = format!("md-refs: citation-target={relative}:");
        assert!(
            String::from_utf8_lossy(&output.stdout).contains(&expected),
            "{output:?}"
        );

        // The installed hook names the skill section in prose rather than
        // pretending the consumer carries the catalog's source path.
        fs::write(
            &path,
            format!("{original}\n{prefix}Orch skill, Oversee events, Judgement rules.\n"),
        )
        .unwrap();
        success(command(
            home,
            project,
            Path::new("git"),
            &["add", "--", relative],
        ));
        let output = scoped_command(
            home,
            project,
            &scripts.join("md-refs"),
            &["--all", "--strict"],
            relative,
        );
        assert_reference_coverage(std::slice::from_ref(&output), &expected_paths);
        success(output);
        fs::write(path, original).unwrap();
        success(command(
            home,
            project,
            Path::new("git"),
            &["add", "--", relative],
        ));
    }
}

#[test]
fn the_scope_partition_accounts_for_every_staged_path() {
    let staged: Vec<String> = [
        ".claude/skills/a/SKILL.md",
        ".claude/hooks/b.sh",
        ".opencode/command/c.md",
        "kendex.toml",
    ]
    .iter()
    .map(|path| (*path).to_owned())
    .collect();

    let scopes = lane_scopes(&staged);
    assert_eq!(scopes, vec![".claude/*", ".opencode/*", "kendex.toml"]);
}
