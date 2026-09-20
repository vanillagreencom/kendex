#[path = "../../test_util.rs"]
mod test_util;

use std::collections::BTreeSet;
use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::bot_instructions;
use kendex_core::engine::GeneratedPaths;
use kendex_core::env::{Env, FakeOs};
use kendex_core::lock::{EmittedArtifact, Lock, LockEntry, Reason};
use kendex_core::manifest::Method;
use kendex_core::model::{HarnessId, ItemKind, Scope};
use kendex_core::process::Hardened;
use test_util::rooted;

const CODEX_PACKAGE: &str = ".agents/skills/bot-instructions";

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
        &kendex_core::lock::lock_path(&env, &Scope::Project { root: root.clone() }),
        &lock,
    )
    .unwrap();
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

fn enabled_fixture() -> Fixture {
    enabled_fixture_with_arming(true)
}

#[allow(clippy::unwrap_used)]
fn enabled_fixture_with_arming(armed: bool) -> Fixture {
    let checkout = test_util::checkout_root();
    let canonical =
        fs::read_to_string(checkout.join("skills/bot-instructions/tests/fixtures/canonical.toml"))
            .unwrap();
    let fixture = fixture_with_arming(&canonical, armed);
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
    git(&fixture.root, &["add", "-A"]);
    run_package(&fixture.root, "adopt");
    run_package(&fixture.root, "render");
    git(&fixture.root, &["add", "-A"]);
    fixture
}

#[allow(clippy::unwrap_used)]
fn run_package(root: &Path, verb: &str) {
    let script = root.join(CODEX_PACKAGE).join("scripts/bot-instructions");
    let output = Hardened::package_script(
        &script,
        vec![verb.into(), "--repo".into(), root.as_os_str().to_owned()],
        root,
    )
    .run()
    .unwrap();
    assert!(
        output.status.success(),
        "bot-instructions {verb} failed:\n{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

#[test]
fn a_doctrine_update_rerenders_enabled_surfaces_and_adds_them_to_the_change_set() {
    let fixture = enabled_fixture();
    let copilot = fixture.root.join(".github/copilot-instructions.md");
    let agents = fixture.root.join("AGENTS.md");
    let before_copilot = fs::read_to_string(&copilot).expect("the first render exists");
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
        ".github/instructions/docs.instructions.md",
        ".github/instructions/tests.instructions.md",
        ".macroscope/correctness/docs.md",
        ".macroscope/correctness/doctrine.md",
        ".macroscope/correctness/tests.md",
        ".macroscope/ignore.md",
        ".pr_agent.toml",
        "AGENTS.md",
        "REVIEW.md",
        "best_practices.md",
    ]
    .into_iter()
    .map(|path| fixture.root.join(path))
    .collect();
    assert_eq!(generated.whole, expected);
    let mut discovered = GeneratedPaths::default();
    bot_instructions::add_to_generated(&fixture.env, &fixture.scope, &mut discovered)
        .expect("the commit offer discovers the rendered surfaces");
    assert_eq!(discovered.whole, expected);
    assert_ne!(
        fs::read_to_string(&copilot).expect("the refreshed Copilot surface reads"),
        before_copilot
    );
    assert_ne!(
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
        rendered.skipped(),
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
