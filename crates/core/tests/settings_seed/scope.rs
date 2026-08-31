//! The project a settings test runs against, and the passes it can take.
//!
//! Held apart from the tests because both halves need the same fixture: a
//! catalog, a manifest declaring what it installs, and either an arrival
//! or a refresh over the scope. Which of those two a test runs is the
//! subject on one side and the setup on the other.

use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

use super::test_util::{rooted, source_path};

/// One key the consumer has to decide and one that ships a working
/// default: what an install writes, and what it leaves in the template.
pub(crate) const TEMPLATE: &str = "[env]\n# Which reviewers run by default.\nREVIEWERS = \"arch,security\" # required\n\nDEPTH = \"2\"\n";

pub(crate) struct Fixture {
    _tmp: tempfile::TempDir,
    pub(crate) env: Env,
    pub(crate) scope: Scope,
    pub(crate) project: PathBuf,
}

#[allow(clippy::unwrap_used)]
pub(crate) fn fixture(enabled: bool) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let source = home.join("catalog");
    let skill = source.join("skills/review");
    fs::create_dir_all(&skill).unwrap();
    fs::write(
        skill.join("SKILL.md"),
        "---\nname: review\ndescription: review changes\n---\nBody.\n",
    )
    .unwrap();
    fs::write(skill.join("kendex.settings.toml.example"), TEMPLATE).unwrap();

    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.review]\nsource = \"cat\"\nenabled = {enabled}\n",
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

/// A pass over the scope that arrives nothing: every `kendex refresh`,
/// every audit, every apply that declares no new skill.
#[allow(clippy::unwrap_used)]
pub(crate) fn refresh_now(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

/// The pass a skill arrives on, as `ops::add` builds it: the names the
/// manifest gained. Held apart from the refresh above because which of the
/// two a test runs is the whole subject here. The report comes back
/// because what an arrival SAYS is as much its answer as what it writes.
#[allow(clippy::unwrap_used)]
pub(crate) fn arrive(f: &Fixture, skills: &[&str]) -> kendex_core::engine::EngineReport {
    let manifest = kendex_core::manifest::load_for_mutation(&kendex_core::manifest::manifest_path(
        &f.env, &f.scope,
    ))
    .unwrap()
    .unwrap();
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(&f.env, &f.scope)).unwrap();
    let options = kendex_core::engine::PlanOptions {
        arriving_skills: skills.iter().map(|name| (*name).to_owned()).collect(),
        ..kendex_core::engine::PlanOptions::default()
    };
    let report =
        kendex_core::engine::plan_scope(&f.env, &f.scope, &manifest, &lock, &options).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    report
}

/// The file with every line assigning this key taken out: what a consumer
/// leaves behind when they decide against a key an arrival wrote.
pub(crate) fn without_key(text: &str, key: &str) -> String {
    text.lines()
        .filter(|line| !line.starts_with(key))
        .map(|line| format!("{line}\n"))
        .collect()
}

/// Whether this pass named the key as one nobody has answered.
pub(crate) fn names_unanswered(report: &kendex_core::engine::EngineReport, key: &str) -> bool {
    report
        .notes
        .iter()
        .any(|note| note.contains(key) && note.contains("needs this key decided"))
}

/// A project installing several skills, each shipping the `[env]` lines it
/// is given. Skill names are the package-name order seeding resolves in.
#[allow(clippy::unwrap_used)]
pub(crate) fn many_owners(templates: &[(&str, &str)]) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let source = home.join("catalog");

    let mut declared = String::new();
    for (name, template) in templates {
        let skill = source.join(format!("skills/{name}"));
        fs::create_dir_all(&skill).unwrap();
        fs::write(
            skill.join("SKILL.md"),
            format!("---\nname: {name}\ndescription: does {name} things\n---\nBody.\n"),
        )
        .unwrap();
        fs::write(skill.join("kendex.settings.toml.example"), template).unwrap();
        declared.push_str(&format!("\n[skills.{name}]\nsource = \"cat\"\n"));
    }
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n{declared}",
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
