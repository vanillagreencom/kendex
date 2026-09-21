//! The trusted repository catalog must install files its shipped lanes accept.
//!
//! Its own target rather than a module of `catalog_check`: installing every
//! package on every harness and linting the result costs more than the rest of
//! this crate's tests together, so it answers to a step bound of its own in
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
        .env("HOME", home)
        .env("KENDEX_REAL_HOME", "1")
        .env("PATH", std::env::var("PATH").unwrap())
        // Include extensionless scripts and hooks. The shipped extractor
        // decides which installed files have a comment grammar.
        .env("COMMIT_GUARDS_COMMENT_PATHS", scope)
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
fn comment_scopes(staged: &[String]) -> Vec<String> {
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

/// How many staged paths one `comments` run's globs admitted, read off the
/// one terminal line it ends on. Index mode ends on one of four keyed lines
/// and the three that carry an admitted count are all accounted for here: a
/// run that admitted nothing would otherwise read as a scope with no paths
/// and hide them.
///
/// - `summary=… files=M … skipped=K` — M scanned plus K with no grammar
/// - `unmeasured-count=N` — N admitted, none of them with a grammar
/// - `no-match=<globs>` — the globs admitted nothing
///
/// The fourth, `incomplete=`, is the lane's extraction failure and exits 2.
/// It carries no admitted count, and it never reaches here: the caller
/// asserts the run succeeded before parsing, so a scope that could not be
/// scanned fails the test rather than contributing a count to it.
///
/// `None` when the run ended on none of the three, which is a protocol the
/// lane changed rather than a scope that reached zero.
fn reached(stdout: &str) -> Option<usize> {
    for line in stdout.lines() {
        let Some((_, keyed)) = line.split_once("comments: ") else {
            continue;
        };
        if let Some(rest) = keyed.strip_prefix("summary=") {
            let mut files = None;
            let mut skipped = None;
            for field in rest.split_whitespace() {
                if let Some(value) = field.strip_prefix("files=") {
                    files = value.parse::<usize>().ok();
                }
                if let Some(value) = field.strip_prefix("skipped=") {
                    skipped = value.parse::<usize>().ok();
                }
            }
            return Some(files? + skipped?);
        }
        if let Some(value) = keyed.strip_prefix("unmeasured-count=") {
            return value.trim().parse::<usize>().ok();
        }
        if keyed.starts_with("no-match=") {
            return Some(0);
        }
    }
    None
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
            "schema = 6\n[sources.catalog]\n{}\n",
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

/// One planted defect per lane, each staged alone, so a failure names that
/// output and an unrelated catalog finding cannot pass the control.
#[allow(clippy::unwrap_used)]
fn each_lane_names_its_own_planted_defect(home: &Path, project: &Path, scripts: &Path) {
    let controls = [
        (
            "comments",
            "comments: issue-number=",
            ".claude/skills/review-gate/templates/review-gate-writer.yml",
            "# Regression history: #2107\n",
        ),
        (
            "comments",
            "comments: issue-number=",
            ".claude/hooks/command-safety.sh",
            "# Regression history: #2107\n",
        ),
        (
            "comments",
            "comments: issue-number=",
            ".claude/skills/commit-guards/scripts/install-git-hooks",
            "# Regression history: #2107\n",
        ),
        (
            "prose",
            "prose: match=history reference:",
            ".claude/skills/review-gate/SKILL.md",
            "Regression history: #2107\n",
        ),
    ];
    for (lane, record, relative, defect) in controls {
        let path = project.join(relative);
        let original = fs::read_to_string(&path)
            .unwrap_or_else(|error| panic!("installed control {relative}: {error}"));
        let planted = format!("{original}\n{defect}");
        fs::write(&path, &planted).unwrap();
        success(command(
            home,
            project,
            Path::new("git"),
            &["add", "--", relative],
        ));
        let output = command(home, project, &scripts.join(lane), &[]);
        assert_eq!(output.status.code(), Some(1), "{output:?}");
        let said = String::from_utf8_lossy(&output.stdout);
        let line = planted.lines().count();
        let source = defect.strip_prefix('#').unwrap_or(defect).trim_end();
        let expected = format!("{record}{relative}:{line}:{source}");
        assert_eq!(said.lines().next(), Some(expected.as_str()), "{said}");
        fs::write(path, original).unwrap();
        success(command(
            home,
            project,
            Path::new("git"),
            &["rm", "--cached", "-f", "--", relative],
        ));
    }
}

/// The whole staged tree through both lanes. The comments lane costs a fork
/// per installed file and is this crate's slowest work on macOS, so it runs
/// once per scope, concurrently, rather than once over the tree. The scopes
/// partition the staged set and the lanes' own reached counts must add back
/// up to it: that, not the exit statuses alone, is what says no scope quietly
/// dropped a path.
#[allow(clippy::expect_used)]
fn every_staged_path_passes_both_lanes(home: &Path, project: &Path, scripts: &Path) {
    // Git discovers the complete installed tree. No catalog or harness path
    // allowlist can hide a newly shipped file from an applicable lane.
    success(command(home, project, Path::new("git"), &["add", "-A"]));
    success(command(home, project, &scripts.join("prose"), &[]));

    let staged = staged_paths(project);
    assert!(!staged.is_empty(), "the installed tree staged no path");
    let scopes = comment_scopes(&staged);
    let comments = scripts.join("comments");
    let outputs = std::thread::scope(|threads| {
        let handles: Vec<_> = scopes
            .iter()
            .map(|scope| threads.spawn(|| scoped_command(home, project, &comments, &[], scope)))
            .collect();
        handles
            .into_iter()
            .map(|handle| handle.join().expect("a comments lane thread finishes"))
            .collect::<Vec<_>>()
    });

    let mut total = 0;
    for (scope, output) in scopes.iter().zip(&outputs) {
        let said = String::from_utf8_lossy(&output.stdout);
        assert!(
            output.status.success(),
            "scope {scope}: {said}\n{}",
            String::from_utf8_lossy(&output.stderr)
        );
        total += reached(&said)
            .unwrap_or_else(|| panic!("scope {scope} ended on no keyed line: {said}"));
    }
    assert_eq!(
        total,
        staged.len(),
        "the {} comment scopes reached {total} of {} staged paths",
        scopes.len(),
        staged.len()
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn installed_catalog_passes_comment_and_prose_lanes() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let project = home.join("consumer");
    install_whole_catalog(&home, &project);
    let scripts = project.join(".claude/skills/commit-guards/scripts");
    each_lane_names_its_own_planted_defect(&home, &project, &scripts);
    every_staged_path_passes_both_lanes(&home, &project, &scripts);
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

    let scopes = comment_scopes(&staged);
    assert_eq!(scopes, vec![".claude/*", ".opencode/*", "kendex.toml"]);

    // Each row is one scope set and what its runs reported. The whole set
    // accounts for all four staged paths. A dropped scope falls short, each
    // of the lane's three counting lines is read, and a run ending on neither
    // those nor any keyed line at all is no count rather than a silent zero.
    // The lane's fourth line, `incomplete=`, carries no admitted count and
    // must not be read as one; the caller refuses its exit 2 before parsing.
    let rows: [(&str, &[&str], Option<usize>); 6] = [
        (
            "every scope reports a summary",
            &[
                "comments: summary=violations=0 files=1 scope=index skipped=1",
                "comments: summary=violations=0 files=1 scope=index skipped=0",
                "comments: summary=violations=0 files=1 scope=index skipped=0",
            ],
            Some(4),
        ),
        (
            "a scope dropped",
            &[
                "comments: summary=violations=0 files=1 scope=index skipped=1",
                "comments: summary=violations=0 files=1 scope=index skipped=0",
            ],
            Some(3),
        ),
        (
            "a scope whose paths carry no comment grammar",
            &[
                "comments: summary=violations=0 files=2 scope=index skipped=0",
                "comments: unmeasured=.gitignore:grammar\n\
                 comments: unmeasured-count=2",
            ],
            Some(4),
        ),
        (
            "a scope whose globs admitted nothing",
            &[
                "comments: summary=violations=0 files=4 scope=index skipped=0",
                "comments: no-match=range:*",
            ],
            Some(4),
        ),
        (
            "an extraction failure carries no count to add",
            &[
                "comments: summary=violations=0 files=4 scope=index skipped=0",
                "comments: incomplete=files=2 violations=0 scanned=3 skipped=1",
            ],
            None,
        ),
        (
            "a run ending on no terminal line at all",
            &[
                "comments: summary=violations=0 files=4 scope=index skipped=0",
                "nothing keyed",
            ],
            None,
        ),
    ];
    for (name, stdouts, want) in rows {
        let got = stdouts
            .iter()
            .try_fold(0, |sum, stdout| reached(stdout).map(|n| sum + n));
        assert_eq!(got, want, "{name}");
    }
    assert_eq!(staged.len(), 4);
}
