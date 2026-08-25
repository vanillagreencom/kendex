//! Settings templates across the product rename: the old template name
//! still seeds, and a skill shipping both generations is said out loud.
#![cfg(unix)]

use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

const TEMPLATE: &str =
    "[env]\n# Which reviewers run by default.\nREVIEWERS = \"arch,security\"\n\nDEPTH = \"2\"\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture(enabled: bool) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
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
            "schema = 6\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.review]\nsource = \"cat\"\nenabled = {enabled}\n",
            source.display()
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

#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_shipping_the_old_template_name_still_seeds() {
    let f = fixture(true);
    let skill = f
        .project
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("catalog/skills/review");
    fs::remove_file(skill.join("kendex.settings.toml.example")).unwrap();
    fs::write(
        skill.join("vstack.settings.toml.example"),
        "[env]\nNEW_KEY = \"from-old-template\"\n",
    )
    .unwrap();
    let report = audit(&f.env, &f.scope).unwrap();
    assert!(
        !report
            .warnings
            .iter()
            .any(|w| w.message.contains("ships both")),
        "one template is the ordinary case, not a warning: {:?}",
        report.warnings
    );
    apply::execute(&f.env, &report.plan, None).unwrap();
    let seeded = fs::read_to_string(f.project.join("kendex.settings.toml")).unwrap();
    assert!(
        seeded.contains("NEW_KEY = \"from-old-template\""),
        "{seeded}"
    );
}

/// A skill shipping templates under both names seeds only the new one, and
/// the plan says so out loud: the ignored file may be the one somebody
/// reviewed, so silence here would hide which defaults actually land.
#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_shipping_both_template_names_warns_and_seeds_the_new_one() {
    let f = fixture(true);
    let skill = f
        .project
        .parent()
        .unwrap()
        .parent()
        .unwrap()
        .join("catalog/skills/review");
    fs::write(
        skill.join("vstack.settings.toml.example"),
        "[env]\nLEGACY_ONLY = \"unreviewed\"\n",
    )
    .unwrap();

    let report = audit(&f.env, &f.scope).unwrap();
    let warning = report
        .warnings
        .iter()
        .find(|w| w.name == "review" && w.message.contains("ships both"))
        .unwrap_or_else(|| panic!("both templates must be reported: {:?}", report.warnings));
    assert!(
        warning.message.contains("kendex.settings.toml.example")
            && warning.message.contains("vstack.settings.toml.example"),
        "the warning names both files: {}",
        warning.message
    );

    apply::execute(&f.env, &report.plan, None).unwrap();
    let seeded = fs::read_to_string(f.project.join("kendex.settings.toml")).unwrap();
    assert!(seeded.contains("REVIEWERS"), "{seeded}");
    assert!(
        !seeded.contains("LEGACY_ONLY"),
        "only the new template seeds: {seeded}"
    );
}
