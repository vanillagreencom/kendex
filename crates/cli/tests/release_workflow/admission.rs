//! Inputs: .github/workflows/release.yml and .github/workflows/publish-aur.yml.
//! Shell fixtures prove source admission, create-only tags and main dispatch.
//! They do not prove GitHub environment policy or live token permissions.

#![cfg(unix)]

use std::collections::BTreeMap;
use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::{Path, PathBuf};
use std::process::{Command, Output};

use super::{job, run_script, step, workflow};
use crate::test_util::{fixture_env, rooted};

const REPOSITORY: &str = "vanillagreencom/kendex";

struct Fixture {
    _dir: tempfile::TempDir,
    root: PathBuf,
    source: String,
    squash: String,
    fragments: String,
    branch: String,
    main: String,
}

impl Fixture {
    #[allow(
        clippy::unwrap_used,
        reason = "fixture filesystem setup is a test precondition"
    )]
    fn new() -> Self {
        let dir = tempfile::tempdir().unwrap();
        let root = rooted(&dir);
        let mut fixture = Self {
            _dir: dir,
            root,
            source: String::new(),
            squash: String::new(),
            fragments: String::new(),
            branch: String::new(),
            main: String::new(),
        };
        fixture.git(&["init", "-b", "main"]);
        fixture.git(&["config", "user.name", "Fixture"]);
        fixture.git(&["config", "user.email", "fixture@example.test"]);
        fs::create_dir_all(fixture.root.join("changelog.d")).unwrap();
        fs::write(
            fixture.root.join("changelog.d/README.md"),
            "release notes\n",
        )
        .unwrap();
        fixture.source = fixture.commit("initial");
        fixture.git(&["checkout", "-b", "release-change"]);
        fs::write(fixture.root.join("release-change"), "release\n").unwrap();
        fixture.commit("release change");
        fixture.git(&["checkout", "main"]);
        fixture.git(&["merge", "--squash", "release-change"]);
        fixture.squash = fixture.commit("squashed release");
        fixture.git(&["checkout", "-b", "branch-only"]);
        fs::write(fixture.root.join("branch-only"), "branch\n").unwrap();
        fixture.branch = fixture.commit("branch only");
        fixture.git(&["checkout", "main"]);
        fs::create_dir_all(fixture.root.join("changelog.d/fixed")).unwrap();
        fs::write(
            fixture.root.join("changelog.d/fixed/pending.md"),
            "pending\n",
        )
        .unwrap();
        fixture.fragments = fixture.commit("pending fragments");
        fs::remove_dir_all(fixture.root.join("changelog.d/fixed")).unwrap();
        fixture.main = fixture.commit("later main");
        fixture.git(&["init", "--bare", "remote.git"]);
        fixture.git(&["remote", "add", "origin", "remote.git"]);
        fixture.git(&["push", "origin", "main"]);
        fs::create_dir_all(fixture.root.join("bin")).unwrap();
        fixture
    }

    fn command(&self, program: &str) -> Command {
        let mut command = Command::new(program);
        command
            .current_dir(&self.root)
            .env_clear()
            .envs(fixture_env(&self.root))
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("GIT_CONFIG_NOSYSTEM", "1")
            .env("GIT_CONFIG_GLOBAL", "/dev/null");
        command
    }

    #[allow(
        clippy::unwrap_used,
        reason = "fixture Git launch and UTF-8 output are test preconditions"
    )]
    fn git(&self, arguments: &[&str]) -> String {
        let output = self.command("git").args(arguments).output().unwrap();
        assert!(
            output.status.success(),
            "Git fixture operation: {arguments:?}"
        );
        String::from_utf8(output.stdout).unwrap().trim().to_owned()
    }

    fn commit(&self, message: &str) -> String {
        self.git(&["add", "."]);
        self.git(&["commit", "-m", message]);
        self.git(&["rev-parse", "HEAD"])
    }

    #[allow(
        clippy::unwrap_used,
        reason = "fixture executable creation is a test precondition"
    )]
    fn shim(&self, program: &str, body: &str) {
        let path = self.root.join("bin").join(program);
        fs::write(&path, format!("#!/bin/bash\nset -euo pipefail\n{body}\n")).unwrap();
        fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
    }

    #[allow(
        clippy::unwrap_used,
        reason = "the shell must launch before a workflow assertion can run"
    )]
    fn shell(&self, script: &str, environment: &[(&str, &str)]) -> Output {
        self.command("bash")
            .args(["--noprofile", "--norc", "-euo", "pipefail", "-c", script])
            .env(
                "PATH",
                format!(
                    "{}:{}",
                    self.root.join("bin").display(),
                    std::env::var("PATH").unwrap_or_default()
                ),
            )
            .env("GITHUB_REPOSITORY", REPOSITORY)
            .env("GITHUB_OUTPUT", self.root.join("github.output"))
            .env("GH_LOG", self.root.join("gh.log"))
            .env("GITHUB_SHA", &self.main)
            .envs(environment.iter().copied())
            .output()
            .unwrap()
    }

    #[allow(
        clippy::unwrap_used,
        reason = "the workflow output fixture contains machine-readable key-value lines"
    )]
    fn outputs(&self) -> BTreeMap<String, String> {
        fs::read_to_string(self.root.join("github.output"))
            .unwrap_or_default()
            .lines()
            .map(|line| {
                let (key, value) = line.split_once('=').unwrap();
                (key.to_owned(), value.to_owned())
            })
            .collect()
    }

    fn calls(&self) -> Vec<String> {
        fs::read_to_string(self.root.join("gh.log"))
            .unwrap_or_default()
            .split('\0')
            .filter(|field| !field.is_empty())
            .map(str::to_owned)
            .collect()
    }
}

#[allow(
    clippy::unwrap_used,
    reason = "the tracked workflow is a required test input"
)]
fn aur_workflow() -> String {
    fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../.github/workflows/publish-aur.yml"),
    )
    .unwrap()
    .replace("\r\n", "\n")
}

fn selection_script() -> String {
    run_script(&step(&workflow(), "name: Select the release source"))
}

#[allow(
    clippy::unwrap_used,
    reason = "clearing the owned fixture output is a test precondition"
)]
fn select(
    fixture: &Fixture,
    script: &str,
    event: &str,
    run_ref: &str,
    tag: &str,
    commit: &str,
) -> Output {
    fs::write(fixture.root.join("github.output"), "").unwrap();
    fixture.shell(
        script,
        &[
            ("EVENT_NAME", event),
            ("RUN_REF", run_ref),
            ("REQUESTED_TAG", tag),
            ("REQUESTED_COMMIT", commit),
        ],
    )
}

#[test]
fn source_admission_selects_only_reviewed_main_commits() {
    let fixture = Fixture::new();
    let script = selection_script();
    for (event, tag, requested, selected, mode) in [
        ("push", "", "", fixture.main.as_str(), "main"),
        (
            "workflow_dispatch",
            "v5.1.0",
            fixture.source.as_str(),
            fixture.source.as_str(),
            "release",
        ),
        (
            "workflow_dispatch",
            "v5.1.0",
            fixture.squash.as_str(),
            fixture.squash.as_str(),
            "release",
        ),
    ] {
        let run = select(&fixture, &script, event, "refs/heads/main", tag, requested);
        assert!(
            run.status.success(),
            "{event}: {}",
            String::from_utf8_lossy(&run.stderr)
        );
        let values = fixture.outputs();
        assert_eq!(values.get("mode").map(String::as_str), Some(mode));
        assert_eq!(
            values.get("source-commit").map(String::as_str),
            Some(selected)
        );
        assert_eq!(values.get("release-tag").map(String::as_str), Some(tag));
    }
}

#[test]
fn release_fragments_are_read_from_the_selected_commit() {
    let fixture = Fixture::new();
    let script = selection_script();
    let run = fixture.shell(
        &script,
        &[
            ("EVENT_NAME", "workflow_dispatch"),
            ("RUN_REF", "refs/heads/main"),
            ("REQUESTED_TAG", "v5.1.0"),
            ("REQUESTED_COMMIT", &fixture.source),
            ("GITHUB_SHA", &fixture.fragments),
        ],
    );
    assert!(run.status.success());
    assert_eq!(
        fixture.outputs().get("source-commit"),
        Some(&fixture.source)
    );
}

#[test]
fn source_admission_refuses_dispatch_inputs_before_emitting_a_source() {
    let fixture = Fixture::new();
    let script = selection_script();
    // GitHub dispatch supplies these fields. The owner selects the merged
    // commit; a writer can instead supply any branch, tag, or fragment state.
    for (rule, event, run_ref, tag, commit) in [
        (
            "branch run",
            "workflow_dispatch",
            "refs/heads/branch-only",
            "v5.1.0",
            fixture.source.as_str(),
        ),
        (
            "tag run",
            "workflow_dispatch",
            "refs/tags/v5.1.0",
            "v5.1.0",
            fixture.source.as_str(),
        ),
        (
            "event",
            "release",
            "refs/heads/main",
            "v5.1.0",
            fixture.source.as_str(),
        ),
        (
            "branch-only source",
            "workflow_dispatch",
            "refs/heads/main",
            "v5.1.0",
            fixture.branch.as_str(),
        ),
        (
            "unknown source",
            "workflow_dispatch",
            "refs/heads/main",
            "v5.1.0",
            "ffffffffffffffffffffffffffffffffffffffff",
        ),
        (
            "short source",
            "workflow_dispatch",
            "refs/heads/main",
            "v5.1.0",
            &fixture.source[..12],
        ),
        (
            "revision expression",
            "workflow_dispatch",
            "refs/heads/main",
            "v5.1.0",
            "HEAD~1",
        ),
        (
            "missing source",
            "workflow_dispatch",
            "refs/heads/main",
            "v5.1.0",
            "",
        ),
        (
            "fragments",
            "workflow_dispatch",
            "refs/heads/main",
            "v5.1.0",
            fixture.fragments.as_str(),
        ),
        (
            "tag prefix",
            "workflow_dispatch",
            "refs/heads/main",
            "5.1.0",
            fixture.source.as_str(),
        ),
        (
            "invalid tag ref",
            "workflow_dispatch",
            "refs/heads/main",
            "v5..1.0",
            fixture.source.as_str(),
        ),
        (
            "tag injection",
            "workflow_dispatch",
            "refs/heads/main",
            "v5.1.0\nsource-commit=other",
            fixture.source.as_str(),
        ),
    ] {
        let run = select(&fixture, &script, event, run_ref, tag, commit);
        assert!(!run.status.success(), "{rule}");
        assert!(
            fixture.outputs().is_empty(),
            "{rule} emitted source outputs"
        );
    }
}

fn tag_script() -> String {
    run_script(&step(
        &workflow(),
        "name: Create and verify the version tag",
    ))
}

fn api_shim(fixture: &Fixture, behavior: &str) {
    fixture.shim(
        "gh",
        &format!(
            r#"
printf '%s\0' "$@" >> "$GH_LOG"
[ "$1" = api ]
ref=''; sha=''
for argument in "$@"; do
  case "$argument" in ref=*) ref=${{argument#ref=}} ;; sha=*) sha=${{argument#sha=}} ;; esac
done
[ -n "$ref" ] && [ -n "$sha" ]
{behavior}
"#
        ),
    );
}

fn run_tag(fixture: &Fixture, script: &str) -> Output {
    fixture.shell(
        script,
        &[
            ("RELEASE_TAG", "v5.1.0"),
            ("SOURCE_COMMIT", &fixture.source),
        ],
    )
}

#[test]
fn version_tags_are_created_once_and_verified_against_the_built_commit() {
    let script = tag_script();
    for kind in ["absent", "lightweight", "annotated"] {
        let fixture = Fixture::new();
        if kind == "lightweight" {
            fixture.git(&["tag", "v5.1.0", &fixture.source]);
            fixture.git(&["push", "origin", "refs/tags/v5.1.0"]);
        } else if kind == "annotated" {
            fixture.git(&["tag", "-a", "v5.1.0", &fixture.source, "-m", "release"]);
            fixture.git(&["push", "origin", "refs/tags/v5.1.0"]);
        }
        api_shim(
            &fixture,
            "git --git-dir=remote.git update-ref \"$ref\" \"$sha\" ''",
        );
        let run = run_tag(&fixture, &script);
        assert!(
            run.status.success(),
            "{kind}: {}",
            String::from_utf8_lossy(&run.stderr)
        );
        let target = fixture.git(&[
            "--git-dir=remote.git",
            "rev-parse",
            "refs/tags/v5.1.0^{commit}",
        ]);
        assert_eq!(target, fixture.source, "{kind}");
        let calls = fixture.calls();
        if kind == "absent" {
            assert!(calls.windows(2).any(|args| args == ["--method", "POST"]));
            assert!(calls.contains(&format!("repos/{REPOSITORY}/git/refs")));
            assert!(calls.contains(&"ref=refs/tags/v5.1.0".to_owned()));
            assert!(calls.contains(&format!("sha={}", fixture.source)));
        } else {
            assert!(calls.is_empty(), "{kind} attempted to recreate a tag");
        }
    }
}

#[test]
fn conflicting_or_unreadable_tags_stop_publication() {
    let script = tag_script();
    for kind in [
        "wrong lightweight",
        "wrong annotated",
        "read failure",
        "create failure",
        "create conflict",
        "wrong readback",
        "missing readback",
    ] {
        let fixture = Fixture::new();
        let behavior = match kind {
            "create failure" => "exit 1".to_owned(),
            "create conflict" => format!(
                "git --git-dir=remote.git update-ref \"$ref\" {}; exit 1",
                fixture.main
            ),
            "wrong readback" => format!(
                "git --git-dir=remote.git update-ref \"$ref\" {} ''",
                fixture.main
            ),
            "missing readback" => "exit 0".to_owned(),
            _ => "git --git-dir=remote.git update-ref \"$ref\" \"$sha\" ''".to_owned(),
        };
        api_shim(&fixture, &behavior);
        match kind {
            "wrong lightweight" => {
                fixture.git(&["tag", "v5.1.0", &fixture.main]);
                fixture.git(&["push", "origin", "refs/tags/v5.1.0"]);
            }
            "wrong annotated" => {
                fixture.git(&["tag", "-a", "v5.1.0", &fixture.main, "-m", "wrong target"]);
                fixture.git(&["push", "origin", "refs/tags/v5.1.0"]);
            }
            "read failure" => {
                fixture.git(&["remote", "set-url", "origin", "missing-remote.git"]);
            }
            _ => {}
        }
        let run = run_tag(&fixture, &script);
        assert!(!run.status.success(), "{kind}");
        if matches!(
            kind,
            "wrong lightweight" | "wrong annotated" | "read failure"
        ) {
            assert!(fixture.calls().is_empty(), "{kind} attempted a write");
        }
    }
}

#[test]
fn aur_dispatches_use_main_and_propagate_api_failure() {
    for (owner, source, marker) in [
        (
            "release bridge",
            aur_workflow(),
            "name: Dispatch AUR publication on main",
        ),
        (
            "candidate",
            workflow(),
            "name: Dispatch candidate AUR publication on main",
        ),
    ] {
        let script = run_script(&step(&source, marker));
        for failure in [false, true] {
            let fixture = Fixture::new();
            fixture.shim(
                "gh",
                &format!(
                    "printf '%s\\0' \"$@\" >> \"$GH_LOG\"\nexit {}",
                    if failure { 1 } else { 0 }
                ),
            );
            let run = fixture.shell(&script, &[]);
            assert_eq!(run.status.success(), !failure, "{owner}");
            assert_eq!(
                fixture.calls(),
                [
                    "workflow",
                    "run",
                    "publish-aur.yml",
                    "--repo",
                    REPOSITORY,
                    "--ref",
                    "main"
                ],
                "{owner}"
            );
        }
    }
}

fn mutant(script: &str, original: &str, replacement: &str) -> String {
    assert_eq!(script.matches(original).count(), 1);
    let changed = script.replacen(original, replacement, 1);
    assert_ne!(changed, script);
    // Keep the guarded text so a comment or text scan cannot prove behavior.
    format!(": <<'DISABLED_RULE'\n{original}\nDISABLED_RULE\n{changed}")
}

#[test]
fn source_admission_controls_reach_each_independent_rule() {
    let fixture = Fixture::new();
    let script = selection_script();
    for (rule, original, replacement, event, run_ref, tag, commit) in [
        (
            "run ref",
            "if [ \"$RUN_REF\" != refs/heads/main ]; then",
            "if false; then",
            "workflow_dispatch",
            "refs/heads/branch-only",
            "v5.1.0",
            fixture.source.as_str(),
        ),
        (
            "event",
            "case \"$EVENT_NAME\" in",
            "case push in",
            "release",
            "refs/heads/main",
            "v5.1.0",
            fixture.source.as_str(),
        ),
        (
            "full commit",
            "${#REQUESTED_COMMIT} -ne 40",
            "1 -eq 0",
            "workflow_dispatch",
            "refs/heads/main",
            "v5.1.0",
            &fixture.source[..12],
        ),
        (
            "commit resolution",
            "source_commit=$(git rev-parse --verify \"${REQUESTED_COMMIT}^{commit}\")",
            "source_commit=$GITHUB_SHA",
            "workflow_dispatch",
            "refs/heads/main",
            "v5.1.0",
            "ffffffffffffffffffffffffffffffffffffffff",
        ),
        (
            "ancestry",
            "if ! git merge-base --is-ancestor \"$source_commit\" \"$GITHUB_SHA\"; then",
            "if false; then",
            "workflow_dispatch",
            "refs/heads/main",
            "v5.1.0",
            fixture.branch.as_str(),
        ),
        (
            "tag prefix",
            "case \"$REQUESTED_TAG\" in",
            "case v5.1.0 in",
            "workflow_dispatch",
            "refs/heads/main",
            "5.1.0",
            fixture.source.as_str(),
        ),
        (
            "tag syntax",
            "git check-ref-format \"refs/tags/$REQUESTED_TAG\"",
            ": \"refs/tags/$REQUESTED_TAG\"",
            "workflow_dispatch",
            "refs/heads/main",
            "v5..1.0",
            fixture.source.as_str(),
        ),
        (
            "fragment state",
            "if [ \"$fragments\" != changelog.d/README.md ]; then",
            "if false; then",
            "workflow_dispatch",
            "refs/heads/main",
            "v5.1.0",
            fixture.fragments.as_str(),
        ),
    ] {
        let good = select(&fixture, &script, event, run_ref, tag, commit);
        assert!(
            !good.status.success(),
            "{rule} failed to refuse the planted input"
        );
        let changed = mutant(&script, original, replacement);
        let bad = select(&fixture, &changed, event, run_ref, tag, commit);
        assert!(
            bad.status.success(),
            "{rule} mutation did not reach the failed assertion: {}",
            String::from_utf8_lossy(&bad.stderr)
        );
        assert!(fixture.outputs().contains_key("source-commit"), "{rule}");
    }
}

#[test]
#[allow(
    clippy::unwrap_used,
    reason = "locating the real Git executable is a recorder fixture precondition"
)]
fn malformed_commit_characters_are_refused_before_git_resolution() {
    let fixture = Fixture::new();
    let real_git = fixture
        .command("bash")
        .args(["-c", "command -v git"])
        .output()
        .unwrap();
    let real_git = String::from_utf8(real_git.stdout).unwrap();
    fixture.shim(
        "git",
        &format!(
            "printf '%s\\0' \"$@\" >> \"$GH_LOG\"\nexec '{}' \"$@\"",
            real_git.trim()
        ),
    );
    let script = selection_script();
    let commit = "gggggggggggggggggggggggggggggggggggggggg";
    let run = select(
        &fixture,
        &script,
        "workflow_dispatch",
        "refs/heads/main",
        "v5.1.0",
        commit,
    );
    assert!(!run.status.success());
    assert!(fixture.calls().is_empty());
    let changed = mutant(&script, "\"$REQUESTED_COMMIT\" == *[!0-9a-f]*", "1 -eq 0");
    let run = select(
        &fixture,
        &changed,
        "workflow_dispatch",
        "refs/heads/main",
        "v5.1.0",
        commit,
    );
    assert!(!run.status.success());
    assert!(fixture.calls().contains(&"rev-parse".to_owned()));
}

#[test]
#[allow(
    clippy::unwrap_used,
    reason = "locating the real Git executable is a failure fixture precondition"
)]
fn an_unreadable_fragment_tree_refuses_the_release_source() {
    let fixture = Fixture::new();
    let real_git = fixture
        .command("bash")
        .args(["-c", "command -v git"])
        .output()
        .unwrap();
    let real_git = String::from_utf8(real_git.stdout).unwrap();
    fixture.shim(
        "git",
        &format!(
            "[ \"$1\" != ls-tree ] || exit 1\nexec '{}' \"$@\"",
            real_git.trim()
        ),
    );
    let script = selection_script();
    let run = select(
        &fixture,
        &script,
        "workflow_dispatch",
        "refs/heads/main",
        "v5.1.0",
        &fixture.source,
    );
    assert!(!run.status.success());
    assert!(fixture.outputs().is_empty());
    let changed = mutant(
        &script,
        "fragments=$(git ls-tree -r --name-only \"$source_commit\" -- changelog.d)",
        "fragments=changelog.d/README.md",
    );
    assert!(
        select(
            &fixture,
            &changed,
            "workflow_dispatch",
            "refs/heads/main",
            "v5.1.0",
            &fixture.source
        )
        .status
        .success()
    );
}

#[test]
fn tag_target_and_dispatch_controls_make_the_contract_fail() {
    let fixture = Fixture::new();
    fixture.git(&["tag", "v5.1.0", &fixture.main]);
    fixture.git(&["push", "origin", "refs/tags/v5.1.0"]);
    api_shim(&fixture, "exit 1");
    let script = tag_script();
    assert!(!run_tag(&fixture, &script).status.success());
    let changed = mutant(
        &script,
        "if [ \"$tag_target\" != \"$SOURCE_COMMIT\" ]; then",
        "if false; then",
    );
    assert!(run_tag(&fixture, &changed).status.success());

    for source in [workflow(), aur_workflow()] {
        let marker = if source.contains("name: Dispatch candidate AUR publication on main") {
            "name: Dispatch candidate AUR publication on main"
        } else {
            "name: Dispatch AUR publication on main"
        };
        let script = run_script(&step(&source, marker));
        let fixture = Fixture::new();
        fixture.shim("gh", "printf '%s\\0' \"$@\" >> \"$GH_LOG\"");
        let changed = mutant(&script, "--ref main", "--ref branch-only");
        assert!(fixture.shell(&changed, &[]).status.success());
        assert!(fixture.calls().contains(&"branch-only".to_owned()));
        assert!(!fixture.calls().contains(&"main".to_owned()));
    }
}

fn declaration(lines: &[&str], key: &str) -> Option<String> {
    let prefix = format!("    {key}: ");
    lines
        .iter()
        .find_map(|line| line.strip_prefix(&prefix).map(str::to_owned))
}

#[allow(
    clippy::unwrap_used,
    reason = "the workflow permissions section delimits the declared trigger contract"
)]
fn check_admission_declarations(release: &str, aur: &str) {
    let triggers = release.split_once("\npermissions:").unwrap().0;
    assert!(triggers.lines().any(|line| line == "    branches: [main]"));
    assert!(triggers.lines().any(|line| line == "  workflow_dispatch:"));
    assert!(
        !triggers
            .lines()
            .any(|line| line.trim_start().starts_with("tags:"))
    );
    assert_eq!(declaration(&job(release, "prepare"), "environment"), None);
    for name in ["build", "publish", "channel"] {
        assert_eq!(
            declaration(&job(release, name), "environment").as_deref(),
            Some("kendex")
        );
    }
    assert_eq!(
        declaration(&job(release, "build"), "needs").as_deref(),
        Some("prepare")
    );
    assert_eq!(
        declaration(&job(release, "publish"), "needs").as_deref(),
        Some("[prepare, build]")
    );
    for (name, expected) in [
        ("build", "${{ needs.prepare.outputs.source-commit }}"),
        ("channel", "${{ github.sha }}"),
    ] {
        let owner = job(release, name).join("\n");
        let checkout = step(&owner, "uses: actions/checkout@v4");
        let active_ref = checkout
            .iter()
            .find_map(|line| line.strip_prefix("          ref: "));
        assert_eq!(active_ref, Some(expected), "{name}");
    }
    let publish = step(release, "uses: softprops/action-gh-release@v2");
    assert!(
        publish
            .iter()
            .any(|line| line.trim() == "target_commitish: ${{ steps.tag.outputs.source-commit }}")
    );
    let candidate = step(release, "name: Dispatch candidate AUR publication on main");
    assert!(candidate.iter().any(|line| line.trim() == "if: needs.prepare.outputs.mode == 'release' && steps.tag.outputs.channel == 'prerelease'"));
    let bridge = job(aur, "dispatch");
    assert_eq!(declaration(&bridge, "environment"), None);
    assert_eq!(
        declaration(&bridge, "if").as_deref(),
        Some("github.event_name == 'release'")
    );
    assert_eq!(
        declaration(&job(aur, "publish"), "if").as_deref(),
        Some("github.event_name != 'schedule' && github.event_name != 'release'")
    );
}

#[test]
fn workflow_declarations_bind_signing_and_publication_to_prepared_main_runs() {
    let release = workflow();
    let aur = aur_workflow();
    check_admission_declarations(&release, &aur);
    for name in ["build", "publish", "channel"] {
        let original = job(&release, name).join("\n");
        assert_eq!(original.matches("    environment: kendex").count(), 1);
        let changed = original.replace(
            "    environment: kendex",
            "    environment: unreviewed\n    # environment: kendex",
        );
        assert_eq!(release.matches(&original).count(), 1);
        let mutant = release.replacen(&original, &changed, 1);
        assert_ne!(mutant, release);
        assert!(
            std::panic::catch_unwind(|| check_admission_declarations(&mutant, &aur)).is_err(),
            "{name}"
        );
    }
    for (name, expected, wrong) in [
        (
            "build",
            "${{ needs.prepare.outputs.source-commit }}",
            "${{ github.sha }}",
        ),
        (
            "channel",
            "${{ github.sha }}",
            "${{ needs.prepare.outputs.source-commit }}",
        ),
    ] {
        let original = job(&release, name).join("\n");
        let original_ref = format!("          ref: {expected}");
        assert_eq!(original.matches(&original_ref).count(), 1);
        let changed = original.replacen(
            &original_ref,
            &format!("          ref: {wrong}\n          # ref: {expected}"),
            1,
        );
        assert_ne!(original, changed);
        assert_eq!(release.matches(&original).count(), 1);
        let mutant = release.replacen(&original, &changed, 1);
        assert_ne!(mutant, release);
        assert!(mutant.contains(&format!("# ref: {expected}")));
        assert!(
            std::panic::catch_unwind(|| check_admission_declarations(&mutant, &aur)).is_err(),
            "{name} accepted a wrong checkout ref"
        );
    }
}
