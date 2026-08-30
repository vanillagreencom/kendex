//! What kendex tells the user about a Copilot setup it cannot fully act on:
//! an event Copilot has no counterpart for, hooks switched off from another
//! tool's settings file, a skill a personal setting holds down that no
//! repository can lift, a model the repository will not run, and a machine
//! whose settings still live in the file Copilot moved away from.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::{EngineReport, audit};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;
use serde_json::Value;

const AGENT: &str = "---\nname: rust\ndescription: Rust engineer\nmodel: claude-sonnet-4.6\nrole: engineer\n---\nUse the Grep tool.\n";

const AUDIT_HOOK: &str = "#!/usr/bin/env bash\n# ---\n# name: audit\n# event: PreToolUse\n# matcher: Bash\n# description: log shell commands\n# ---\nexit 0\n";

/// Copilot has no event that means "the turn's work was accepted".
const DONE_HOOK: &str = "#!/usr/bin/env bash\n# ---\n# name: done\n# event: TaskCompleted\n# description: check the work\n# ---\nexit 0\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture(harnesses: &str, declarations: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".github")).unwrap();
    fs::create_dir_all(project.join(".claude")).unwrap();
    // Copilot is on this machine: what it reads is worth reporting.
    fs::create_dir_all(home.join(".copilot")).unwrap();

    let source = home.join("catalog");
    for dir in ["agents", "hooks", "skills/deploy"] {
        fs::create_dir_all(source.join(dir)).unwrap();
    }
    fs::write(
        source.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: Ship it\n---\n\nSteps.\n",
    )
    .unwrap();
    fs::write(source.join("agents/rust.md"), AGENT).unwrap();
    fs::write(source.join("hooks/audit.sh"), AUDIT_HOOK).unwrap();
    fs::write(source.join("hooks/done.sh"), DONE_HOOK).unwrap();
    // Hooks and commands install only from a catalog that declares kendex's
    // layout, never guessed from a discovered repo's folders.
    fs::write(source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();

    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [{harnesses}]\nmethod = \"symlink\"\n\n{declarations}",
            source_path(&source)
        ),
    )
    .unwrap();

    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) -> EngineReport {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    report
}

#[allow(clippy::unwrap_used)]
fn json(path: &std::path::Path) -> Value {
    serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap()
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_event_copilot_does_not_have_is_reported_never_faked() {
    let f = fixture("\"copilot\"", "[hooks.done]\nsource = \"cat\"\n");
    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("event TaskCompleted has no Copilot counterpart")),
        "{:?}",
        report.notes
    );
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(!f.project.join(".github/hooks").exists());
}

/// Copilot reads Claude Code's settings for a handful of keys, and this is
/// the one that stops every hook it would otherwise run.
#[test]
#[allow(clippy::unwrap_used)]
fn hooks_switched_off_in_claudes_settings_are_reported_inert() {
    let f = fixture("\"copilot\"", "[hooks.audit]\nsource = \"cat\"\n");
    let claude = f.project.join(".claude/settings.json");
    fs::write(&claude, r#"{"disableAllHooks": true}"#).unwrap();

    let report = apply_now(&f);
    assert!(
        report
            .warnings
            .iter()
            .any(|w| w.message.contains("installs but stays inert")),
        "{:?}",
        report.warnings
    );
    // Said, not obeyed: the registration still lands where Copilot reads it.
    let registry = f.project.join(".github/hooks/audit.json");
    assert_eq!(json(&registry)["hooks"]["preToolUse"][0]["matcher"], "bash");

    fs::write(&claude, r#"{"disableAllHooks": false}"#).unwrap();
    let quiet = audit(&f.env, &f.scope).unwrap();
    assert!(
        !quiet
            .warnings
            .iter()
            .any(|w| w.message.contains("stays inert")),
        "{:?}",
        quiet.warnings
    );
}

/// A repository file may add a name to `disabledSkills` but never take one
/// off, so a project that declares the skill on is not the last word on it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_a_personal_setting_holds_down_cannot_be_switched_back_on_here() {
    let f = fixture("\"copilot\"", "[skills.deploy]\nsource = \"cat\"\n");
    fs::write(
        f.env.home.join(".copilot/settings.json"),
        r#"{"disabledSkills": ["deploy"]}"#,
    )
    .unwrap();

    let report = apply_now(&f);
    assert!(
        report
            .warnings
            .iter()
            .any(|w| w.message.contains("this project cannot switch it back on")),
        "{:?}",
        report.warnings
    );
    // The skill still installs — what is refused is the pretence that a
    // repository can lift a personal switch.
    assert!(f.project.join(".agents/skills/deploy/SKILL.md").is_file());
}

/// One tree, two readers. Copilot sees a skill installed for Claude Code,
/// and saying so must never turn one installation into two.
#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_installed_for_another_tool_is_noted_as_visible_to_copilot() {
    let f = fixture("\"claude\"", "[skills.deploy]\nsource = \"cat\"\n");
    let report = apply_now(&f);
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("GitHub Copilot")
                && note.contains("read `.agents/skills` too")
                && note.contains("one definition, counted once")),
        "{:?}",
        report.notes
    );
    // Nothing was installed into Copilot's own directory, and nothing in the
    // report claims Copilot has an installation of its own.
    assert!(!f.project.join(".github/skills").exists());
    assert!(
        !report
            .drift
            .iter()
            .any(|row| row.harness == kendex_core::model::HarnessId::Copilot)
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_model_the_repository_will_not_run_is_named() {
    let f = fixture("\"copilot\"", "[agents.rust]\nsource = \"cat\"\n");
    fs::write(
        f.project.join(".github/allowed_models.txt"),
        "gpt-5.4\nfallback: gpt-5.4\n",
    )
    .unwrap();

    let report = apply_now(&f);
    assert!(
        report.warnings.iter().any(|w| w
            .message
            .contains("allows gpt-5.4 and not claude-sonnet-4.6")),
        "{:?}",
        report.warnings
    );
    assert!(f.project.join(".github/agents/rust.agent.md").is_file());
}

/// Copilot's skills reference requires a lowercase-hyphen `name`, so a name
/// it will not load is refused with the spelling that would work — the same
/// treatment OpenCode's loader gets.
#[test]
#[allow(clippy::unwrap_used)]
fn a_name_copilots_loader_rejects_is_refused_with_the_one_that_works() {
    let f = fixture("\"copilot\"", "[skills.Deploy_Thing]\nsource = \"cat\"\n");
    let source = f.env.home.join("catalog/skills/Deploy_Thing");
    fs::create_dir_all(&source).unwrap();
    fs::write(
        source.join("SKILL.md"),
        "---\nname: Deploy_Thing\ndescription: Ship it\n---\n\nSteps.\n",
    )
    .unwrap();

    let report = apply_now(&f);
    assert!(
        report.drift.iter().any(|row| row.name == "Deploy_Thing"
            && row.detail.contains("will not load `Deploy_Thing`")
            && row.detail.contains("deploy-thing")),
        "{:?}",
        report.drift
    );
    assert!(!f.project.join(".github/skills/Deploy_Thing").exists());
}

/// Copilot has no slash commands of its own. A command declared only for
/// Copilot installs nowhere, and silence there reads as success.
#[test]
#[allow(clippy::unwrap_used)]
fn a_command_declared_only_for_copilot_says_it_installed_nowhere() {
    let f = fixture("\"copilot\"", "[commands.ship]\nsource = \"cat\"\n");
    let source = f.env.home.join("catalog/commands");
    fs::create_dir_all(&source).unwrap();
    fs::write(
        source.join("ship.md"),
        "---\ndescription: Ship the branch\n---\n\nRun the checklist.\n",
    )
    .unwrap();

    let report = apply_now(&f);
    assert!(
        report.notes.iter().any(|note| note
            .contains("command ship: GitHub Copilot cannot hold one at this scope")
            && note.contains("nothing was installed")),
        "{:?}",
        report.notes
    );
}
