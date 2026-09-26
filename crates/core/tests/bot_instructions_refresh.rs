//! The installed bot-instructions package driven through kendex's own
//! render and removal routes. Every case here runs the package's shell
//! script, which kendex launches through `sh`.
#![cfg(unix)]

use crate::test_util;

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use crate::test_util::rooted;
use kendex_core::bot_instructions;
use kendex_core::commit_offer::{self, Carried, Staleness};
use kendex_core::engine::GeneratedPaths;
use kendex_core::env::{Env, FakeOs};
use kendex_core::lock::{EmittedArtifact, Lock, LockEntry, Reason};
use kendex_core::manifest::Method;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::process::Hardened;

const CODEX_PACKAGE: &str = ".agents/skills/bot-instructions";
const CLAUDE_PACKAGE: &str = ".claude/skills/bot-instructions";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    root: PathBuf,
    scope: Scope,
}

#[allow(clippy::unwrap_used)]
fn copy_tree(from: &Path, to: &Path) {
    fs::create_dir_all(to).unwrap();
    for entry in fs::read_dir(from).unwrap() {
        let entry = entry.unwrap();
        let source = entry.path();
        let destination = to.join(entry.file_name());
        if source.is_dir() {
            copy_tree(&source, &destination);
        } else {
            fs::copy(&source, &destination).unwrap();
        }
    }
}

#[allow(clippy::unwrap_used)]
fn git(root: &Path, args: &[&str]) {
    let output = Hardened::git(args, Some(root)).run().unwrap();
    assert!(
        output.status.success(),
        "git {} failed: {}",
        args.join(" "),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn fixture(manifest: &str) -> Fixture {
    fixture_with_arming(manifest, true)
}

#[allow(clippy::unwrap_used)]
fn fixture_with_arming(manifest: &str, armed: bool) -> Fixture {
    fixture_at(manifest, armed, HarnessId::Codex, CODEX_PACKAGE)
}

#[allow(clippy::unwrap_used)]
fn fixture_at(manifest: &str, armed: bool, harness: HarnessId, package_rel: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let base = rooted(&tmp);
    let root = base.join("consumer");
    let env = Env::fake(base.join("home"), FakeOs::Linux);
    let package = root.join(package_rel);
    copy_tree(
        &test_util::checkout_root().join("skills/bot-instructions"),
        &package,
    );
    fs::write(root.join("kendex.toml"), manifest).unwrap();
    git(&root, &["init", "--quiet"]);
    git(&root, &["add", "-A"]);
    record_install(&env, &root, harness, package);
    if armed {
        let repo = kendex_core::guard::Repo::at(&root).unwrap();
        kendex_core::repo_effects::armed::arm(
            kendex_core::repo_effects::armed::record_dir(&repo, false),
            "bot-instructions",
        )
        .unwrap();
    }
    Fixture {
        scope: Scope::Project { root: root.clone() },
        env,
        root,
        _tmp: tmp,
    }
}

/// The install record naming `package` as this project's copy of the
/// package, the record `installed_declaration` reads.
#[allow(clippy::unwrap_used)]
fn record_install(env: &Env, root: &Path, harness: HarnessId, package: PathBuf) {
    let mut lock = Lock {
        version: kendex_core::lock::LOCK_VERSION,
        ..Lock::default()
    };
    lock.entries.insert(
        kendex_core::lock::entry_key(ItemKind::Skill, "bot-instructions", harness),
        LockEntry {
            name: "bot-instructions".to_owned(),
            kind: ItemKind::Skill,
            harness,
            source: "local".to_owned(),
            source_repo: "local".to_owned(),
            machine: Some(kendex_core::lock::MachineRecord {
                method: Method::Copy,
                installed_at: "2026-09-20T00:00:00Z".to_owned(),
            }),
            source_hash: "fixture".to_owned(),
            source_commit: None,
            rendered_hash: Some("fixture".to_owned()),
            enabled: true,
            upstream_skills: None,
            emitted: Some(EmittedArtifact {
                kind: ItemKind::Skill,
                name: "bot-instructions".to_owned(),
                paths: vec![package],
            }),
            registration: None,
            reasons: BTreeSet::from([Reason::Requested]),
        },
    );
    kendex_core::lock::save(
        &kendex_core::lock::lock_path(
            env,
            &Scope::Project {
                root: root.to_owned(),
            },
        ),
        &lock,
    )
    .unwrap();
}

fn enabled_fixture() -> Fixture {
    enabled_fixture_with_arming(true)
}

#[allow(clippy::unwrap_used)]
fn enabled_fixture_with_arming(armed: bool) -> Fixture {
    enabled_fixture_at(armed, HarnessId::Codex, CODEX_PACKAGE)
}

#[allow(clippy::unwrap_used)]
fn enabled_fixture_at(armed: bool, harness: HarnessId, package_rel: &str) -> Fixture {
    let checkout = test_util::checkout_root();
    let canonical =
        fs::read_to_string(checkout.join("skills/bot-instructions/tests/fixtures/canonical.toml"))
            .unwrap();
    let fixture = fixture_at(&canonical, armed, harness, package_rel);
    for directory in [
        ".bot-instructions",
        ".agents/skills/dev",
        ".claude/agents",
        "src/tests",
        "docs/generated",
    ] {
        fs::create_dir_all(fixture.root.join(directory)).unwrap();
    }
    fs::copy(
        checkout.join("skills/bot-instructions/tests/fixtures/coderabbit-schema.json"),
        fixture
            .root
            .join(".bot-instructions/coderabbit-schema.json"),
    )
    .unwrap();
    for (path, text) in [
        (".agents/skills/dev/SKILL.md", "x\n"),
        (".claude/agents/a.md", "x\n"),
        (".claude/settings.json", "{}\n"),
        ("src/main.rs", "fn main() {}\n"),
        ("docs/guide.md", "prose\n"),
        ("docs/generated/api.md", "prose\n"),
        ("README.md", "# fixture\n"),
        ("src/tests/t.rs", "x\n"),
        (
            ".kendex-generated.json",
            "[\".agents/skills/bot-instructions/SKILL.md\",\".agents/skills/dev/SKILL.md\",\".claude/agents/a.md\",\".claude/settings.json\",\".kendex-generated.json\"]\n",
        ),
        (
            "AGENTS.md",
            "# fixture\n\n## Code Review Rules\n\nHand-written today.\n\n## Something else\n\nText.\n",
        ),
    ] {
        fs::write(fixture.root.join(path), text).unwrap();
    }
    if package_rel != CODEX_PACKAGE {
        let inventory = fixture.root.join(".kendex-generated.json");
        let text = fs::read_to_string(&inventory).unwrap();
        fs::write(inventory, text.replace(CODEX_PACKAGE, package_rel)).unwrap();
    }
    git(&fixture.root, &["add", "-A"]);
    adopt_at(&fixture.root, package_rel);
    run_package_at(&fixture.root, package_rel, "render");
    git(&fixture.root, &["add", "-A"]);
    fixture
}

/// Adopt the fixture's hand-written surfaces.
///
/// The package reports the hand-written `## Code Review Rules` region under
/// `agents-region` and exits 1 while still taking it over, because the managed
/// region is one directive line. The `render` that follows is the migration.
///
/// Exit 1 is the findings status of every clause the adopt path can raise, so
/// the finding is named rather than the status accepted bare: a fixture whose
/// manifest failed `toml-schema` would otherwise pass this setup silently.
#[allow(clippy::unwrap_used)]
fn adopt_at(root: &Path, package_rel: &str) {
    let output = package_output(root, package_rel, "adopt");
    let code = output.status.code();
    let stderr = String::from_utf8_lossy(&output.stderr);
    let reported_region = code == Some(1) && stderr.contains("agents-region:");
    assert!(
        code == Some(0) || reported_region,
        "bot-instructions adopt exited {code:?} without agents-region:\n{}\n{stderr}",
        String::from_utf8_lossy(&output.stdout)
    );
}

#[allow(clippy::unwrap_used)]
fn run_package(root: &Path, verb: &str) {
    run_package_at(root, CODEX_PACKAGE, verb);
}

#[allow(clippy::unwrap_used)]
fn run_package_at(root: &Path, package_rel: &str, verb: &str) {
    let output = package_output(root, package_rel, verb);
    assert!(
        output.status.success(),
        "bot-instructions {verb} failed:\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[allow(clippy::unwrap_used)]
fn package_output(root: &Path, package_rel: &str, verb: &str) -> std::process::Output {
    package_run(root, package_rel, &[verb])
}

#[allow(clippy::unwrap_used)]
fn package_run(root: &Path, package_rel: &str, args: &[&str]) -> std::process::Output {
    let script = root.join(package_rel).join("scripts/bot-instructions");
    let mut argv: Vec<std::ffi::OsString> = args.iter().map(Into::into).collect();
    argv.extend(["--repo".into(), root.as_os_str().to_owned()]);
    Hardened::package_script(&script, argv, root).run().unwrap()
}

/// Commit what the fixture staged, so a later change reads as one.
fn commit_fixture(root: &Path) {
    git(
        root,
        &[
            "-c",
            "user.name=t",
            "-c",
            "user.email=t@t",
            "-c",
            "commit.gpgsign=false",
            "commit",
            "--quiet",
            "-m",
            "fixture",
        ],
    );
}

/// Change the installed doctrine, the way a refresh of the package does.
#[allow(clippy::unwrap_used)]
fn change_doctrine(root: &Path) -> PathBuf {
    let doctrine = root.join(CODEX_PACKAGE).join("SKILL.md");
    let current = fs::read_to_string(&doctrine).unwrap();
    let changed = current.replacen(
        "Raise a defect only in changed lines",
        "Raise a defect only in lines changed by this pull request",
        1,
    );
    assert_ne!(
        changed, current,
        "the doctrine mutation found no source text"
    );
    fs::write(&doctrine, changed).unwrap();
    doctrine
}

/// The offer's view of the project, with `generated` as the files kendex
/// wrote.
#[allow(clippy::expect_used)]
fn offer_scan(fixture: &Fixture, generated: &GeneratedPaths) -> commit_offer::Scan {
    commit_offer::scan(&fixture.scope, generated)
        .expect("the offer reads the project")
        .expect("the project has changes kendex owns")
}

/// Whether `bot-instructions check --staged`, the commit-guards pre-commit
/// lane, passes over these paths staged. The index is put back after.
fn staged_check_passes(root: &Path, owned: &[commit_offer::Owned]) -> bool {
    let mut add = vec!["add", "--"];
    add.extend(owned.iter().map(|owned| owned.path.as_str()));
    git(root, &add);
    let output = package_run(root, CODEX_PACKAGE, &["check", "--staged"]);
    git(root, &["reset", "--quiet"]);
    match output.status.code() {
        Some(0) => true,
        Some(1) => false,
        other => panic!(
            "check --staged could not answer ({other:?}):\n{}\n{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        ),
    }
}

#[test]
fn a_doctrine_update_rerenders_enabled_surfaces_and_adds_them_to_the_change_set() {
    let fixture = enabled_fixture();
    let copilot = fixture.root.join(".github/copilot-instructions.md");
    let doctrine_file = fixture.root.join(".github/instructions/code-review.md");
    let agents = fixture.root.join("AGENTS.md");
    let before_copilot = fs::read_to_string(&copilot).expect("the first render exists");
    let before_doctrine = fs::read_to_string(&doctrine_file).expect("the first doctrine exists");
    let before_agents = fs::read_to_string(&agents).expect("the first region exists");

    let doctrine = fixture
        .root
        .join(".agents/skills/bot-instructions/SKILL.md");
    let current = fs::read_to_string(&doctrine).expect("the installed doctrine reads");
    let changed = current.replacen(
        "Raise a defect only in changed lines",
        "Raise a defect only in lines changed by this pull request",
        1,
    );
    assert_ne!(
        changed, current,
        "the doctrine mutation found no source text"
    );
    fs::write(&doctrine, changed).expect("the refreshed doctrine is written");

    let rendered =
        bot_instructions::render(&fixture.env, &fixture.scope).expect("the refresh re-renders");
    let mut generated = GeneratedPaths::default();
    rendered.add_to(&mut generated);
    let expected: BTreeSet<PathBuf> = [
        ".coderabbit.yaml",
        ".github/copilot-instructions.md",
        ".github/instructions/code-review.md",
        ".github/instructions/docs.instructions.md",
        ".github/instructions/tests.instructions.md",
        ".macroscope/correctness/docs.md",
        ".macroscope/correctness/doctrine.md",
        ".macroscope/correctness/tests.md",
        ".macroscope/ignore.md",
        ".pr_agent.toml",
        "REVIEW.md",
        "best_practices.md",
    ]
    .into_iter()
    .map(|path| fixture.root.join(path))
    .collect();
    assert_eq!(generated.whole, expected);
    let expected_region = kendex_core::commit_offer::OwnedRegion::new(
        agents.clone(),
        "## Code Review Rules".to_owned(),
        fixture.root.join(CODEX_PACKAGE),
        "scripts/bot-instructions render".to_owned(),
    )
    .expect("the package reports a valid region");
    assert_eq!(generated.regions, BTreeSet::from([expected_region.clone()]));
    let mut discovered = GeneratedPaths::default();
    bot_instructions::add_to_generated(&fixture.env, &fixture.scope, &mut discovered)
        .expect("the commit offer discovers the rendered surfaces");
    assert_eq!(discovered.whole, expected);
    assert_eq!(discovered.regions, BTreeSet::from([expected_region]));
    assert_ne!(
        fs::read_to_string(&doctrine_file).expect("the refreshed doctrine surface reads"),
        before_doctrine,
        "a doctrine edit has to reach the file every bot is pointed at"
    );
    // The two pointer surfaces carry no doctrine, so a doctrine edit leaves
    // them byte for byte as they were. Asserting that is what keeps a silent
    // return to restating the blocks from passing this test.
    assert_eq!(
        fs::read_to_string(&copilot).expect("the refreshed Copilot surface reads"),
        before_copilot
    );
    assert_eq!(
        fs::read_to_string(&agents).expect("the refreshed AGENTS region reads"),
        before_agents
    );
    run_package(&fixture.root, "check");
}

#[test]
fn a_project_with_every_bot_surface_disabled_is_untouched() {
    let fixture = fixture(
        "schema = 6\n\n[bot-instructions]\nschema = 1\n\n[bot-instructions.repo]\nname = \"fixture\"\nsummary = \"A fixture with no review bot enabled.\"\n",
    );
    let rendered = bot_instructions::render(&fixture.env, &fixture.scope)
        .expect("the disabled render is a no-op");
    let mut generated = GeneratedPaths::default();
    rendered.add_to(&mut generated);
    assert!(generated.whole.is_empty());
    assert!(
        !fixture
            .root
            .join(".github/copilot-instructions.md")
            .exists()
    );
    assert!(!fixture.root.join("AGENTS.md").exists());
}

#[test]
fn an_invalid_manifest_names_the_input_and_the_render_repair() {
    let fixture = fixture(
        "schema = 6\n\n[bot-instructions]\nschema = 1\n\n[bot-instructions.bots]\ncopilot = true\n",
    );
    let error = bot_instructions::render(&fixture.env, &fixture.scope)
        .expect_err("the incomplete bot manifest must refuse")
        .to_string();
    assert!(
        error.contains("kendex.toml"),
        "the refusal did not name the manifest:\n{error}"
    );
    assert!(
        error.contains("'.agents/skills/bot-instructions/scripts/bot-instructions' 'render'"),
        "the refusal did not name the render repair:\n{error}"
    );
    assert!(
        error.contains("repair the reported cause, then run"),
        "the refusal did not put the cause before the rerun:\n{error}"
    );
}

#[test]
fn a_claude_only_copy_runs_and_names_its_installed_repair_command() {
    let fixture = fixture_at(
        "schema = 6\n\n[bot-instructions]\nschema = 1\n\n[bot-instructions.bots]\ncopilot = true\n",
        true,
        HarnessId::Claude,
        ".claude/skills/bot-instructions",
    );

    let error = bot_instructions::render(&fixture.env, &fixture.scope)
        .expect_err("the incomplete bot manifest must refuse")
        .to_string();

    assert!(
        error.contains("'.claude/skills/bot-instructions/scripts/bot-instructions' 'render'"),
        "the refusal did not name the installed Claude copy:\n{error}"
    );
    assert!(
        !error.contains(".agents/skills/bot-instructions/scripts"),
        "the refusal derived an uninstalled shared copy:\n{error}"
    );
}

#[test]
fn a_claude_only_copy_names_its_running_launcher_in_drift_repairs() {
    let fixture = enabled_fixture_at(true, HarnessId::Claude, CLAUDE_PACKAGE);
    let doctrine = fixture.root.join(CLAUDE_PACKAGE).join("SKILL.md");
    let current = fs::read_to_string(&doctrine).expect("the installed doctrine reads");
    let changed = current.replacen(
        "Raise a defect only in changed lines",
        "Raise a defect only in lines changed by this pull request",
        1,
    );
    assert_ne!(
        changed, current,
        "the doctrine mutation found no source text"
    );
    fs::write(doctrine, changed).expect("the installed doctrine changes");

    let output = package_output(&fixture.root, CLAUDE_PACKAGE, "check");
    assert_eq!(output.status.code(), Some(1));
    let error = String::from_utf8_lossy(&output.stderr);
    assert!(
        error.contains("run `.claude/skills/bot-instructions/scripts/bot-instructions render`"),
        "the drift repair did not name the running Claude copy:\n{error}"
    );
    assert!(
        !error.contains(".agents/skills/bot-instructions/scripts"),
        "the drift repair named an uninstalled shared copy:\n{error}"
    );
}

#[test]
fn an_unarmed_install_runs_no_package_code_and_names_the_setup_step() {
    let fixture = enabled_fixture_with_arming(false);
    let copilot = fixture.root.join(".github/copilot-instructions.md");
    let before = fs::read_to_string(&copilot).expect("the adopted fixture was rendered");
    let doctrine = fixture
        .root
        .join(".agents/skills/bot-instructions/SKILL.md");
    let current = fs::read_to_string(&doctrine).expect("the installed doctrine reads");
    let changed = current.replacen(
        "Raise a defect only in changed lines",
        "Raise a defect only in lines changed by this pull request",
        1,
    );
    assert_ne!(
        changed, current,
        "the doctrine mutation found no source text"
    );
    fs::write(doctrine, changed).expect("the installed doctrine changes");

    let rendered = bot_instructions::render(&fixture.env, &fixture.scope)
        .expect("an unarmed package is skipped");
    assert_eq!(
        rendered
            .skipped()
            .map(bot_instructions::Skipped::line)
            .as_deref(),
        Some(
            "bot-instructions: render skipped; use Set up on the bot-instructions package page, or remove and add it with --allow-repo-effects, then apply again"
        )
    );
    assert_eq!(
        fs::read_to_string(copilot).expect("the existing surface remains"),
        before,
        "the unarmed package code ran"
    );
}

#[test]
fn removal_revokes_automatic_rendering_before_a_declined_reinstall() {
    let fixture = enabled_fixture();
    let lock_path = kendex_core::lock::lock_path(&fixture.env, &fixture.scope);
    let installed = kendex_core::lock::load(&lock_path).expect("the installed lock reads");
    let declared = kendex_core::engine::installed_declaration(
        &fixture.env,
        &fixture.scope,
        "bot-instructions",
    )
    .expect("the declaration reads")
    .expect("the package declares its effect");
    let mut said = Vec::new();

    kendex_core::repo_effects::undo(
        &fixture.scope,
        std::slice::from_ref(&declared),
        &mut |line| said.push(line.into_line()),
    )
    .expect("removal retires the effect");
    assert!(
        said.iter().any(|line| line.contains("rendering retired")),
        "the uninstaller did not report retirement: {said:?}"
    );
    assert!(
        !kendex_core::repo_effects::armed_here(&fixture.scope, &declared)
            .expect("the permission record reads"),
        "removal left automatic execution armed"
    );

    let empty = Lock {
        version: kendex_core::lock::LOCK_VERSION,
        ..Lock::default()
    };
    kendex_core::lock::save(&lock_path, &empty).expect("the removal writes its lock");
    kendex_core::lock::save(&lock_path, &installed).expect("the reinstall writes its lock");
    let copilot = fixture.root.join(".github/copilot-instructions.md");
    let before = fs::read_to_string(&copilot).expect("the earlier render reads");
    let doctrine = declared.root.join("SKILL.md");
    let changed = fs::read_to_string(&doctrine)
        .expect("the reinstalled doctrine reads")
        .replacen(
            "Raise a defect only in changed lines",
            "Raise a defect only in lines changed by this pull request",
            1,
        );
    fs::write(doctrine, changed).expect("the reinstalled doctrine changes");

    let rendered = bot_instructions::render(&fixture.env, &fixture.scope)
        .expect("declining setup lets the update continue");
    assert!(
        rendered.skipped().is_some(),
        "the declined setup was not named"
    );
    assert_eq!(
        fs::read_to_string(copilot).expect("the old output remains"),
        before,
        "the declined reinstall executed the renderer"
    );
}

/// What one row of the stale table expects `commit_offer::stale` to say.
enum Holds {
    NotSetUp,
    OutOfDate,
    Unchecked(&'static str),
    Nothing,
}

/// One standing a package can have when the offer touches it.
struct StaleRow {
    what: &'static str,
    armed: bool,
    doctrine_changed: bool,
    rendered: bool,
    declares: fn(&Path, String) -> String,
    holds: Holds,
}

/// The declaration edits a row applies to the installed copy before the
/// fixture is committed.
fn as_shipped(_: &Path, text: String) -> String {
    text
}

fn no_installer(_: &Path, text: String) -> String {
    without(text, "  installer: \"scripts/bot-instructions render\"\n")
}

fn no_checker(_: &Path, text: String) -> String {
    without(text, "  checker: \"scripts/bot-instructions check\"\n")
}

fn writes_into_git(_: &Path, text: String) -> String {
    replaced(
        text,
        "  writes:\n",
        "  writes:\n    - \".git/hooks/pre-commit\"\n",
    )
}

#[allow(clippy::unwrap_used)]
fn check_cannot_answer(package: &Path, text: String) -> String {
    use std::os::unix::fs::PermissionsExt;
    let script = package.join("scripts/fail-check");
    fs::write(
        &script,
        "#!/bin/sh\necho 'fail-check: the manifest would not read' >&2\nexit 2\n",
    )
    .unwrap();
    fs::set_permissions(&script, fs::Permissions::from_mode(0o755)).unwrap();
    replaced(
        text,
        "  checker: \"scripts/bot-instructions check\"\n",
        "  checker: \"scripts/fail-check\"\n",
    )
}

fn without(text: String, line: &str) -> String {
    replaced(text, line, "")
}

fn replaced(text: String, from: &str, to: &str) -> String {
    assert_eq!(
        text.matches(from).count(),
        1,
        "the declaration edit found {from:?}"
    );
    text.replacen(from, to, 1)
}

const STALE_ROWS: [StaleRow; 8] = [
    StaleRow {
        what: "not set up here",
        armed: false,
        doctrine_changed: true,
        rendered: false,
        declares: as_shipped,
        holds: Holds::NotSetUp,
    },
    StaleRow {
        what: "set up, its files not rendered",
        armed: true,
        doctrine_changed: true,
        rendered: false,
        declares: as_shipped,
        holds: Holds::OutOfDate,
    },
    StaleRow {
        what: "set up and rendered",
        armed: true,
        doctrine_changed: true,
        rendered: true,
        declares: as_shipped,
        holds: Holds::Nothing,
    },
    StaleRow {
        what: "set up, its check cannot answer",
        armed: true,
        doctrine_changed: true,
        rendered: false,
        declares: check_cannot_answer,
        holds: Holds::Unchecked("fail-check: the manifest would not read"),
    },
    StaleRow {
        what: "not touched by the offer",
        armed: false,
        doctrine_changed: false,
        rendered: false,
        declares: as_shipped,
        holds: Holds::Nothing,
    },
    StaleRow {
        what: "no installer to set it up with",
        armed: false,
        doctrine_changed: true,
        rendered: false,
        declares: no_installer,
        holds: Holds::Nothing,
    },
    StaleRow {
        what: "an effect inside .git",
        armed: false,
        doctrine_changed: true,
        rendered: false,
        declares: writes_into_git,
        holds: Holds::Nothing,
    },
    StaleRow {
        what: "set up, no check to ask",
        armed: true,
        doctrine_changed: true,
        rendered: false,
        declares: no_checker,
        holds: Holds::Nothing,
    },
];

/// Each package the offer touches is asked before the commit is offered,
/// and one kendex cannot vouch for holds it. One row per standing: not set
/// up, set up with its files not rendered, set up and rendered, set up
/// with a check that cannot answer, and the four that hold nothing: not
/// touched by the offer, no installer to set it up with, an effect inside
/// `.git`, and set up with no check to ask.
#[test]
#[allow(clippy::unwrap_used)]
fn a_package_whose_files_the_offer_would_carry_stale_holds_the_commit() {
    for row in STALE_ROWS {
        let what = row.what;
        let fixture = enabled_fixture_with_arming(row.armed);
        let package = fixture.root.join(CODEX_PACKAGE);
        let skill = package.join("SKILL.md");
        let declared = (row.declares)(&package, fs::read_to_string(&skill).unwrap());
        fs::write(&skill, declared).unwrap();
        git(&fixture.root, &["add", "-A"]);
        commit_fixture(&fixture.root);
        let mut generated = GeneratedPaths::default();
        let readme = fixture.root.join("README.md");
        fs::write(&readme, "# fixture, changed\n").unwrap();
        generated.whole.insert(readme);
        if row.doctrine_changed {
            generated.whole.insert(change_doctrine(&fixture.root));
        }
        if row.rendered {
            bot_instructions::render(&fixture.env, &fixture.scope)
                .expect("the armed package renders")
                .add_to(&mut generated);
        }

        let stale = commit_offer::stale(
            &fixture.env,
            &fixture.scope,
            &offer_scan(&fixture, &generated),
            Carried::Everything,
        )
        .expect("the packages are asked");

        match row.holds {
            Holds::Nothing => assert!(stale.is_empty(), "{what}: {stale:?}"),
            Holds::NotSetUp => {
                assert_eq!(stale.len(), 1, "{what}: {stale:?}");
                assert_eq!(stale[0].disclosure.name, "bot-instructions", "{what}");
                assert_eq!(stale[0].why, Staleness::NotSetUp, "{what}");
            }
            Holds::OutOfDate => {
                assert_eq!(stale.len(), 1, "{what}: {stale:?}");
                let Staleness::OutOfDate(said) = &stale[0].why else {
                    panic!("{what}: {:?}", stale[0].why);
                };
                assert!(
                    said.iter()
                        .any(|line| line.starts_with("bot-instructions: findings=")),
                    "{what}: the check's own words did not travel: {said:?}"
                );
            }
            Holds::Unchecked(words) => {
                assert_eq!(stale.len(), 1, "{what}: {stale:?}");
                assert_eq!(
                    stale[0].why,
                    Staleness::Unchecked(vec![words.to_owned()]),
                    "{what}"
                );
            }
        }
    }
}

/// The offer after a refresh that changed an unarmed package's doctrine.
/// The commit it used to offer is one `bot-instructions check --staged`,
/// the pre-commit lane, refuses; the offer now holds it. The setup the
/// hold offers renders the files, and the commit it then offers passes
/// that check.
///
/// Must-fail control: `commit_offer::stale` answering empty for a package
/// not set up here restores the old offer, and the first assertion fails.
#[test]
fn an_unarmed_doctrine_change_never_offers_the_commit_the_staged_check_refuses() {
    let fixture = enabled_fixture_with_arming(false);
    commit_fixture(&fixture.root);
    let mut generated = GeneratedPaths::default();
    generated.whole.insert(change_doctrine(&fixture.root));
    let rendered = bot_instructions::render(&fixture.env, &fixture.scope)
        .expect("an unarmed package is skipped");
    assert!(rendered.skipped().is_some(), "the unarmed render ran");
    rendered.add_to(&mut generated);

    let scan = offer_scan(&fixture, &generated);
    let stale = commit_offer::stale(&fixture.env, &fixture.scope, &scan, Carried::Everything)
        .expect("the packages are asked");
    assert_eq!(
        stale.iter().map(|held| &held.why).collect::<Vec<_>>(),
        [&Staleness::NotSetUp],
        "the commit was offered over a package not set up here"
    );
    assert!(
        !staged_check_passes(&fixture.root, &scan.owned),
        "the premise failed: the old offer's commit passes the staged check"
    );

    kendex_core::repo_effects::arm(&fixture.scope, &stale[0].disclosure.declared)
        .expect("the setup the hold offers runs");
    bot_instructions::add_to_generated(&fixture.env, &fixture.scope, &mut generated)
        .expect("the setup's files join the offer");
    let scan = offer_scan(&fixture, &generated);
    let stale = commit_offer::stale(&fixture.env, &fixture.scope, &scan, Carried::Everything)
        .expect("the packages are asked again");
    assert!(stale.is_empty(), "still held after the setup: {stale:?}");
    assert!(
        staged_check_passes(&fixture.root, &scan.owned),
        "the commit offered after the setup fails the staged check"
    );
}

/// A linked work tree of a repository whose main checkout set the package
/// up is not set up itself, and its skip line names the main checkout
/// rather than leaving the state unexplained.
#[test]
#[allow(clippy::unwrap_used)]
fn a_linked_work_tree_names_the_main_checkout_in_its_skip_line() {
    let fixture = enabled_fixture();
    commit_fixture(&fixture.root);
    let linked = fixture.root.parent().unwrap().join("linked");
    git(
        &fixture.root,
        &[
            "worktree",
            "add",
            "--quiet",
            "-b",
            "second",
            linked.to_str().unwrap(),
        ],
    );
    let linked = linked.canonicalize().unwrap();
    record_install(
        &fixture.env,
        &linked,
        HarnessId::Codex,
        linked.join(CODEX_PACKAGE),
    );

    let rendered = bot_instructions::render(
        &fixture.env,
        &Scope::Project {
            root: linked.clone(),
        },
    )
    .expect("a package set up elsewhere is skipped here");

    assert_eq!(
        rendered.skipped().map(bot_instructions::Skipped::line),
        Some(format!(
            "bot-instructions: render skipped in this work tree; it is set up in the main checkout at {}, and each work tree is set up on its own: use Set up on the bot-instructions package page, then apply again",
            kendex_core::paths::slashed(&fixture.root)
        ))
    );
}

/// A commit never splits a package's changed paths. One row per way a
/// package's input can be left behind while its re-rendered files are
/// carried: a pending doctrine change outside the action's own commit, and
/// a changed `[bot-instructions]` table in the manifest, which no commit
/// kendex makes carries. A manifest change outside that table leaves the
/// commit whole.
#[test]
#[allow(clippy::unwrap_used)]
fn a_commit_that_splits_a_packages_changed_paths_is_held() {
    enum Carries {
        Rendered,
        Everything,
    }
    let rows = [
        (
            "the doctrine left out of the action's commit",
            None,
            Carries::Rendered,
            Some(vec![format!("{CODEX_PACKAGE}/SKILL.md")]),
        ),
        (
            "every pending change, the doctrine included",
            None,
            Carries::Everything,
            None,
        ),
        (
            "the package's manifest table changed",
            Some(("name = \"fixture\"\n", "name = \"renamed\"\n")),
            Carries::Everything,
            Some(vec!["kendex.toml".to_owned()]),
        ),
        (
            "the manifest changed outside the package's table",
            Some((
                "harnesses = [\"claude\"]\n",
                "harnesses = [\"claude\", \"codex\"]\n",
            )),
            Carries::Everything,
            None,
        ),
    ];
    for (what, manifest_edit, carries, split) in rows {
        let fixture = enabled_fixture();
        commit_fixture(&fixture.root);
        let manifest = fixture.root.join("kendex.toml");
        if let Some((from, to)) = manifest_edit {
            let text = fs::read_to_string(&manifest).unwrap();
            assert_eq!(
                text.matches(from).count(),
                1,
                "{what}: the manifest edit found {from:?}"
            );
            let text = text.replacen(from, to, 1);
            fs::write(&manifest, text).unwrap();
        }
        let mut generated = GeneratedPaths::default();
        generated.whole.insert(change_doctrine(&fixture.root));
        let mut rendered = GeneratedPaths::default();
        bot_instructions::render(&fixture.env, &fixture.scope)
            .expect("the armed package renders")
            .add_to(&mut rendered);
        let scan = offer_scan(&fixture, &{
            let mut all = generated.clone();
            all.whole.extend(rendered.whole.iter().cloned());
            all.regions.extend(rendered.regions.iter().cloned());
            all
        });
        let rendered_paths: BTreeSet<String> = scan
            .owned
            .iter()
            .map(|owned| owned.path.clone())
            .filter(|path| !path.ends_with("SKILL.md"))
            .collect();
        assert!(
            !rendered_paths.is_empty(),
            "{what}: the render changed nothing"
        );
        let carried = match carries {
            Carries::Rendered => Carried::Only(&rendered_paths),
            Carries::Everything => Carried::Everything,
        };

        let stale = commit_offer::stale(&fixture.env, &fixture.scope, &scan, carried)
            .expect("the packages are asked");

        let got: Vec<&Staleness> = stale.iter().map(|held| &held.why).collect();
        match split {
            Some(left) => assert_eq!(got, [&Staleness::Split(left)], "{what}"),
            None => assert!(got.is_empty(), "{what}: {got:?}"),
        }
    }
}
