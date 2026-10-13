//! Inputs: .github/workflows/release.yml, .github/workflows/publish-aur.yml,
//! .github/workflows/skill-tests.yml,
//! and skills/commit-guards/scripts/changelog-entries with its libraries.
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
        fixture.git(&["config", "gc.auto", "0"]);
        fixture.git(&["config", "maintenance.auto", "false"]);
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
            "- Pending change.\n",
        )
        .unwrap();
        fixture.fragments = fixture.commit("pending fragments");
        fs::remove_dir_all(fixture.root.join("changelog.d/fixed")).unwrap();
        fixture.main = fixture.commit("later main");
        fixture.git(&["init", "--bare", "remote.git"]);
        fixture.git(&["--git-dir=remote.git", "config", "gc.auto", "0"]);
        fixture.git(&[
            "--git-dir=remote.git",
            "config",
            "maintenance.auto",
            "false",
        ]);
        fixture.git(&["remote", "add", "origin", "remote.git"]);
        fixture.git(&["push", "origin", "main"]);
        fixture.git(&[
            "push",
            "origin",
            &format!("{}:refs/pull/1/head", fixture.source),
        ]);
        fixture.source_dependencies();
        fixture
    }

    #[allow(
        clippy::unwrap_used,
        reason = "workflow dependencies and GitHub responses are fixture inputs"
    )]
    fn source_dependencies(&self) {
        fs::create_dir_all(self.root.join("bin")).unwrap();
        fs::create_dir_all(self.root.join("skills/commit-guards")).unwrap();
        std::os::unix::fs::symlink(
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../skills/commit-guards/scripts"),
            self.root.join("skills/commit-guards/scripts"),
        )
        .unwrap();
        self.source_api();
    }

    fn source_api(&self) {
        self.shim(
            "gh",
            r#"[ "$1:$2:$3" = "api:repos/vanillagreencom/kendex/pulls/$REQUESTED_PR:--jq" ]
jq -nr --arg commit "$REQUESTED_COMMIT" --arg head "${PR_HEAD:-$REQUESTED_COMMIT}" \
  --arg base "${PR_BASE:-main}" --arg merged "${PR_MERGED:-true}" --arg merge "${PR_MERGE:-$REQUESTED_COMMIT}" \
  '{merged: ($merged == "true"), base: {ref: $base}, merge_commit_sha: $merge, head: {sha: $head}} | '"$4""#,
        );
    }

    #[allow(
        clippy::unwrap_used,
        reason = "release file edits are fixture preconditions"
    )]
    fn prepare_collation(
        &self,
        version: &str,
        section: &str,
        entry: &str,
        recollate: bool,
    ) -> String {
        fs::write(
            self.root.join("CHANGELOG.md"),
            "# Changelog\n\n## [Unreleased]\n",
        )
        .unwrap();
        fs::create_dir_all(self.root.join(format!("changelog.d/{section}"))).unwrap();
        fs::write(
            self.root.join(format!("changelog.d/{section}/cut.md")),
            format!("{entry}\n"),
        )
        .unwrap();
        fs::create_dir_all(self.root.join("crates/app")).unwrap();
        fs::write(
            self.root.join("crates/app/tauri.conf.json"),
            "{\"version\":\"1.9.0\"}\n",
        )
        .unwrap();
        fs::write(
            self.root.join("kendex.settings.toml"),
            "[env]\nCOMMIT_GUARDS_CHANGELOG_VERSION_PATHS = \"crates/app/tauri.conf.json pi-extensions/*/package.json\"\n",
        )
        .unwrap();
        self.commit("release input");
        self.package_releases();
        if recollate {
            fs::write(
                self.root.join("crates/app/tauri.conf.json"),
                format!("{{\"version\":\"{version}\"}}\n"),
            )
            .unwrap();
            self.commit("unpublished version awaiting manual re-collation");
        }
        self.git(&["checkout", "-b", "collation-pr"]);
        let collate = self
            .command("/bin/bash")
            .args([
                "skills/commit-guards/scripts/changelog-entries",
                "--collate",
            ])
            .env("COMMIT_GUARDS_CHANGELOG_COLLATE", "1")
            .output()
            .unwrap();
        assert!(
            collate.status.success(),
            "{}",
            String::from_utf8_lossy(&collate.stdout)
        );
        fs::write(
            self.root.join("crates/app/tauri.conf.json"),
            format!("{{\"version\":\"{version}\"}}\n"),
        )
        .unwrap();
        let path = self.root.join("CHANGELOG.md");
        let record = fs::read_to_string(&path).unwrap();
        let heading = "## [Unreleased]\n";
        assert_eq!(record.matches(heading).count(), 1);
        fs::write(
            path,
            record.replacen(
                heading,
                &format!("## [Unreleased]\n\n## [{version}] - 2026-10-13\n"),
                1,
            ),
        )
        .unwrap();
        self.commit("collate release")
    }

    #[allow(
        clippy::unwrap_used,
        reason = "independent package release history is a fixture input"
    )]
    fn package_releases(&self) {
        let dir = self.root.join("pi-extensions/pi-session-bridge");
        fs::create_dir_all(&dir).unwrap();
        let mut record = String::new();
        for (version, entry) in [
            ("2.3.0", "- Add a session tool."),
            ("3.0.0", "- **Breaking**: Rename the session tool."),
            ("3.0.1", "- Fix the session tool."),
        ] {
            fs::write(
                dir.join("package.json"),
                format!("{{\"version\":\"{version}\"}}\n"),
            )
            .unwrap();
            record = format!("### {version}\n\n{entry}\n\n{record}");
            fs::write(dir.join("CHANGELOG.md"), &record).unwrap();
            self.commit("independent package release");
        }
    }

    #[allow(
        clippy::unwrap_used,
        reason = "queue fixture writes are test preconditions"
    )]
    fn queued_release(
        method: &str,
        version: &str,
        section: &str,
        entry: &str,
        pending_section: &str,
        pending_entry: &str,
        recollate: bool,
    ) -> (Self, String, String) {
        let mut fixture = Self::new();
        fs::write(
            fixture.root.join(".git/info/exclude"),
            "bin/\nskills/\nremote.git/\ngithub.output\ngh.log\n",
        )
        .unwrap();
        let collation_head = fixture.prepare_collation(version, section, entry, recollate);

        fixture.git(&["checkout", "main"]);
        fixture.git(&["checkout", "-b", "fragment-pr"]);
        fs::create_dir_all(fixture.root.join(format!("changelog.d/{pending_section}"))).unwrap();
        fs::write(
            fixture
                .root
                .join(format!("changelog.d/{pending_section}/next.md")),
            format!("{pending_entry}\n"),
        )
        .unwrap();
        fixture.commit("later fragment");
        fixture.git(&["checkout", "main"]);
        fixture.git(&["merge", "--squash", "fragment-pr"]);
        fixture.commit("fragment PR merges ahead in queue");
        let queue_base = fixture.git(&["rev-parse", "HEAD"]);
        if method == "squash" {
            fixture.git(&["merge", "--squash", "collation-pr"]);
            fixture.source = fixture.commit("first release collation merge");
        } else {
            fixture.git(&[
                "merge",
                "--no-ff",
                "-m",
                "first release collation merge",
                "collation-pr",
            ]);
            fixture.source = fixture.git(&["rev-parse", "HEAD"]);
        }
        fs::write(fixture.root.join("after-release"), "later main change\n").unwrap();
        fixture.main = fixture.commit("main advances after release merge");
        fixture.git(&["push", "origin", "main"]);
        fixture.git(&[
            "push",
            "--force",
            "origin",
            &format!("{collation_head}:refs/pull/1/head"),
        ]);
        (fixture, collation_head, queue_base)
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

    fn attempt_release(&self, collation_head: &str, version: &str, script: &str) -> Output {
        let tag = format!("v{version}");
        let environment = [
            ("EVENT_NAME", "workflow_dispatch"),
            ("RUN_REF", "refs/heads/main"),
            ("REQUESTED_TAG", tag.as_str()),
            ("REQUESTED_COMMIT", self.source.as_str()),
            ("PR_HEAD", collation_head),
        ];
        let selected = self.shell(script, &environment);
        if selected.status.success() {
            let old_flow = mutant(
                script,
                "git ls-tree -r --name-only \"$collation_commit\" -- changelog.d",
                "git ls-tree -r --name-only \"$source_commit\" -- changelog.d",
            );
            assert!(!self.shell(&old_flow, &environment).status.success());
            api_shim(
                self,
                "git --git-dir=remote.git update-ref \"$ref\" \"$sha\" ''",
            );
            assert!(
                self.shell(
                    &tag_script(),
                    &[("RELEASE_TAG", &tag), ("SOURCE_COMMIT", &self.source)]
                )
                .status
                .success()
            );
        }
        selected
    }

    #[allow(
        clippy::unwrap_used,
        reason = "the control owns this fixture's script directory"
    )]
    fn mutate_changelog_command(&self, guard: &str, replacement: &str) {
        let scripts = self.root.join("skills/commit-guards/scripts");
        assert!(
            fs::symlink_metadata(&scripts)
                .unwrap()
                .file_type()
                .is_symlink()
        );
        fs::remove_file(&scripts).unwrap();
        let source =
            Path::new(env!("CARGO_MANIFEST_DIR")).join("../../skills/commit-guards/scripts");
        assert!(
            self.command("/bin/cp")
                .arg("-R")
                .arg(source)
                .arg(&scripts)
                .status()
                .unwrap()
                .success()
        );
        let command = scripts.join("changelog-entries");
        let original = fs::read_to_string(&command).unwrap();
        assert_eq!(original.matches(guard).count(), 1);
        let changed = original.replacen(guard, replacement, 1);
        assert_ne!(changed, original);
        fs::write(command, changed).unwrap();
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
        self.command("/bin/bash")
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
            .env("REQUESTED_PR", "1")
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
    reason = "the required CI command is a tracked test input"
)]
fn queue_validation_script() -> String {
    let workflow = fs::read_to_string(
        Path::new(env!("CARGO_MANIFEST_DIR")).join("../../.github/workflows/skill-tests.yml"),
    )
    .unwrap()
    .replace("\r\n", "\n");
    run_script(&step(&workflow, "id: changelog-entries"))
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
    let resolved = fixture
        .command("git")
        .args(["rev-parse", "--verify", &format!("{commit}^{{commit}}")])
        .output()
        .unwrap();
    let identity = if resolved.status.success() {
        String::from_utf8(resolved.stdout)
            .unwrap()
            .trim()
            .to_owned()
    } else {
        fixture.main.clone()
    };
    fixture.shell(
        script,
        &[
            ("EVENT_NAME", event),
            ("RUN_REF", run_ref),
            ("REQUESTED_TAG", tag),
            ("REQUESTED_COMMIT", commit),
            ("PR_MERGE", &identity),
            ("PR_HEAD", &identity),
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
fn the_collation_head_check_admits_later_main_fragments() {
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

type QueueRelease = (
    &'static str,
    &'static str,
    &'static str,
    &'static str,
    &'static str,
    Option<&'static str>,
);

const QUEUE_RELEASES: &[QueueRelease] = &[
    (
        "1.9.1",
        "fixed",
        "- Fix a typo.",
        "fixed",
        "- Fix another typo.",
        None,
    ),
    (
        "1.9.1",
        "fixed",
        "- Fix a typo.",
        "changed",
        "- Change a default.",
        None,
    ),
    (
        "1.9.1",
        "fixed",
        "- Fix a typo.",
        "added",
        "- Add a profile.",
        Some("minor"),
    ),
    (
        "1.9.1",
        "fixed",
        "- Fix a typo.",
        "changed",
        "- **Breaking:** Rename the profile.",
        Some("major"),
    ),
    (
        "1.10.0",
        "added",
        "- Add a profile.",
        "added",
        "- Add another profile.",
        None,
    ),
    (
        "1.10.0",
        "added",
        "- Add a profile.",
        "changed",
        "- **Breaking:** Rename the profile.",
        Some("major"),
    ),
    (
        "2.0.0",
        "changed",
        "- **Breaking:** Rename the profile.",
        "added",
        "- Add a profile.",
        None,
    ),
    (
        "2.0.0",
        "changed",
        "- **Breaking:** Rename the profile.",
        "changed",
        "- **Breaking:** Rename another profile.",
        None,
    ),
];

fn refused_release(
    fixture: &Fixture,
    selected: &Output,
    version: &str,
    section: &str,
    level: &str,
) -> bool {
    let diagnostic =
        format!("changelog-entries: required-level=changelog.d/{section}/next.md:{level}");
    !selected.status.success()
        && String::from_utf8_lossy(&selected.stdout)
            .lines()
            .any(|line| line == diagnostic)
        && fixture
            .git(&["ls-remote", "origin", &format!("refs/tags/v{version}")])
            .is_empty()
}

#[test]
fn the_first_collation_merge_tags_with_later_fragments_reserved() {
    let mut failures = Vec::new();
    for method in ["squash", "merge"] {
        for recollate in [false, true] {
            for &(version, section, entry, pending_section, pending_entry, required) in
                QUEUE_RELEASES
            {
                let (fixture, collation_head, queue_base) = Fixture::queued_release(
                    method,
                    version,
                    section,
                    entry,
                    pending_section,
                    pending_entry,
                    recollate,
                );
                let queue_check =
                    fixture.shell(&queue_validation_script(), &[("BASE", &queue_base)]);
                let selected =
                    fixture.attempt_release(&collation_head, version, &selection_script());
                if let Some(level) = required {
                    if (!recollate && queue_check.status.success())
                        || !refused_release(&fixture, &selected, version, pending_section, level)
                    {
                        failures.push(format!("{method}/{version}/{pending_section}/{level}/recollate={recollate}: incompatible merge was admitted"));
                    }
                } else {
                    assert!(
                        queue_check.status.success(),
                        "{}",
                        String::from_utf8_lossy(&queue_check.stdout)
                    );
                    assert!(
                        selected.status.success(),
                        "{}",
                        String::from_utf8_lossy(&selected.stderr)
                    );
                    assert_eq!(
                        fixture.outputs().get("source-commit"),
                        Some(&fixture.source)
                    );
                    assert_eq!(
                        fixture.git(&[
                            "--git-dir=remote.git",
                            "rev-parse",
                            &format!("refs/tags/v{version}^{{commit}}")
                        ]),
                        fixture.source
                    );
                }
                assert!(
                    fixture
                        .root
                        .join(format!("changelog.d/{pending_section}/next.md"))
                        .is_file()
                );
                assert!(
                    !fixture
                        .root
                        .join(format!("changelog.d/{section}/cut.md"))
                        .exists()
                );
                assert_ne!(fixture.source, collation_head);
                assert_ne!(fixture.source, fixture.main);
            }
        }
    }
    assert!(failures.is_empty(), "{failures:?}");
}

#[test]
fn ignoring_pending_release_levels_reddens_the_release_route_contract() {
    for &(version, section, entry, pending_section, pending_entry, required) in QUEUE_RELEASES {
        let Some(level) = required else { continue };
        let (fixture, head, _) = Fixture::queued_release(
            "squash",
            version,
            section,
            entry,
            pending_section,
            pending_entry,
            false,
        );
        let script = selection_script();
        let selected = fixture.attempt_release(&head, version, &script);
        assert!(refused_release(
            &fixture,
            &selected,
            version,
            pending_section,
            level
        ));
        let kind = if pending_section == "added" {
            "added"
        } else {
            "breaking"
        };
        let guard = "  if ! entry=\"$(first_entry \"$1\")\"; then";
        fixture.mutate_changelog_command(
            guard,
            &format!("  [ \"$1\" != {kind} ] || return 0\n{guard}"),
        );
        let admitted = fixture.attempt_release(&head, version, &script);
        assert!(
            admitted.status.success(),
            "{}",
            String::from_utf8_lossy(&admitted.stderr)
        );
        assert!(!refused_release(
            &fixture,
            &admitted,
            version,
            pending_section,
            level
        ));
    }
}

#[test]
#[allow(
    clippy::unwrap_used,
    reason = "later dispatch policy is a fixture input"
)]
fn later_main_policy_cannot_change_the_selected_release_verdict() {
    let (mut fixture, head, _) = Fixture::queued_release(
        "squash",
        "1.9.1",
        "fixed",
        "- Fix a typo.",
        "added",
        "- Add a profile.",
        false,
    );
    let script = selection_script();
    let selected = fixture.attempt_release(&head, "1.9.1", &script);
    assert!(refused_release(
        &fixture, &selected, "1.9.1", "added", "minor"
    ));
    fs::write(
        fixture.root.join("kendex.settings.toml"),
        "[env]\nCOMMIT_GUARDS_CHANGELOG_VERSION_PATHS = \"pi-extensions/*/package.json\"\n",
    )
    .unwrap();
    fixture.main = fixture.commit("later main changes version policy");
    fs::write(fixture.root.join("caller-staging"), "Caller staging.\n").unwrap();
    fixture.git(&["add", "caller-staging"]);
    let before = fixture.git(&["status", "--porcelain"]);
    let selected = fixture.attempt_release(&head, "1.9.1", &script);
    assert!(refused_release(
        &fixture, &selected, "1.9.1", "added", "minor"
    ));
    assert_eq!(fixture.git(&["status", "--porcelain"]), before);
    fixture.mutate_changelog_command("  gg_settings_index_mode", "  : gg_settings_index_mode");
    let admitted = fixture.attempt_release(&head, "1.9.1", &script);
    assert!(
        admitted.status.success(),
        "{}",
        String::from_utf8_lossy(&admitted.stderr)
    );
    assert!(!refused_release(
        &fixture, &admitted, "1.9.1", "added", "minor"
    ));
}

#[test]
fn independent_package_versions_do_not_set_the_app_release_level() {
    let (fixture, head, _) = Fixture::queued_release(
        "squash",
        "1.10.0",
        "added",
        "- Add a profile.",
        "added",
        "- Add another profile.",
        false,
    );
    let script = selection_script();
    let selected = fixture.attempt_release(&head, "1.10.0", &script);
    assert!(
        selected.status.success(),
        "{}",
        String::from_utf8_lossy(&selected.stderr)
    );
    let tag = "refs/tags/v1.10.0";
    fixture.git(&["--git-dir=remote.git", "update-ref", "-d", tag]);
    fixture.source_api();
    fixture.mutate_changelog_command(
        "    package_record_of \"$f\" >/dev/null && continue",
        "    : package_record_of \"$f\" >/dev/null",
    );
    let refused = fixture.attempt_release(&head, "1.10.0", &script);
    assert!(!refused.status.success());
    assert!(String::from_utf8_lossy(&refused.stdout).lines().any(|line|
        line == "changelog-entries: patch-added=pi-extensions/pi-session-bridge/package.json:3.0.1"
    ));
    assert!(fixture.git(&["ls-remote", "origin", tag]).is_empty());
}

#[test]
fn the_release_pr_must_bind_the_collation_head_to_the_selected_main_merge() {
    let fixture = Fixture::new();
    fixture.git(&[
        "--git-dir=remote.git",
        "update-ref",
        "refs/pull/0/head",
        &fixture.source,
    ]);
    let script = selection_script();
    for (field, value, disabled) in [
        (
            "REQUESTED_PR",
            "0",
            Some((
                "if [[ ! \"$REQUESTED_PR\" =~ ^[1-9][0-9]*$ ]]; then",
                "if false; then",
            )),
        ),
        (
            "PR_MERGED",
            "false",
            Some((
                "if [ \"$merged:$base:$merge_commit\" != \"true:main:$source_commit\" ]; then",
                "if false; then",
            )),
        ),
        ("PR_BASE", "other", None),
        ("PR_MERGE", fixture.main.as_str(), None),
        ("PR_HEAD", "ffffffffffffffffffffffffffffffffffffffff", None),
    ] {
        let environment = [
            ("EVENT_NAME", "workflow_dispatch"),
            ("RUN_REF", "refs/heads/main"),
            ("REQUESTED_TAG", "v5.1.0"),
            ("REQUESTED_COMMIT", fixture.source.as_str()),
            (field, value),
        ];
        assert!(
            !fixture.shell(&script, &environment).status.success(),
            "{field}"
        );
        if let Some((original, replacement)) = disabled {
            let changed = mutant(&script, original, replacement);
            assert!(
                fixture.shell(&changed, &environment).status.success(),
                "{field} control"
            );
        }
    }
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
        if rule == "fragment state" {
            let diagnostic = format!("::error::release-source: fragments={commit}");
            assert!(
                String::from_utf8_lossy(&good.stdout)
                    .lines()
                    .any(|line| line == diagnostic)
            );
        }
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
        .command("/bin/bash")
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
        .command("/bin/bash")
        .args(["-c", "command -v git"])
        .output()
        .unwrap();
    let real_git = String::from_utf8(real_git.stdout).unwrap();
    fixture.shim(
        "git",
        &format!(
            "[ \"$1:${{2:-}}\" != ls-tree:-r ] || exit 1\nexec '{}' \"$@\"",
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
        "fragments=$(git ls-tree -r --name-only \"$collation_commit\" -- changelog.d)",
        "fragments=changelog.d/README.md # git ls-tree -r --name-only \"$collation_commit\" -- changelog.d",
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
