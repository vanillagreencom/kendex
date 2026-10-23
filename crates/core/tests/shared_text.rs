//! `[shared-text]` through the real plan and transactional apply: each
//! skill that places a paragraph renders it where its token sits, and the
//! manifest the plan writes back keeps the token.

use std::fs;
use std::path::PathBuf;

use crate::test_util::{rooted, source_path};
use kendex_core::apply;
use kendex_core::engine::{DeclarationStatus, audit};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

const PARAGRAPH: &str = "Push the item branch.";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture(instructions: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("project");
    let source = home.join("catalog");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::create_dir_all(source.join("agents")).unwrap();
    fs::write(
        source.join("kendex.toml"),
        "is_source_catalog = true\n[agent-skills]\nmaintainer = []\n",
    )
    .unwrap();
    fs::write(
        source.join("agents/maintainer.md"),
        "---\nname: maintainer\ndescription: Keep things tidy\n---\nBody.\n",
    )
    .unwrap();
    for skill in ["dev", "orch", "github"] {
        fs::create_dir_all(source.join("skills").join(skill)).unwrap();
        fs::write(
            source.join("skills").join(skill).join("SKILL.md"),
            format!("---\nname: {skill}\ndescription: The {skill} skill\n---\nBody.\n"),
        )
        .unwrap();
    }
    // `generalist` is the catalog's old name for `maintainer`, so the plan
    // writes its normalized copy of this manifest back.
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 7\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\
             [agents.generalist]\nsource = \"cat\"\n\
             [skills.dev]\nsource = \"cat\"\n[skills.orch]\nsource = \"cat\"\n[skills.github]\nsource = \"cat\"\n\
             {instructions}\n[sources.cat]\n{}\n",
            source_path(&source)
        ),
    )
    .unwrap();
    Fixture {
        _tmp: tmp,
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
    }
}

#[allow(clippy::unwrap_used)]
fn applied(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    assert_eq!(report.declaration_status, DeclarationStatus::Complete);
    assert!(report.refused.is_empty(), "{:?}", report.refused);
    apply::execute(&f.env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
fn skill_md(f: &Fixture, skill: &str) -> String {
    fs::read_to_string(
        f.project
            .join(".claude/skills")
            .join(skill)
            .join("SKILL.md"),
    )
    .unwrap()
}

#[test]
#[allow(clippy::unwrap_used)]
fn each_placing_skill_renders_the_paragraph_where_its_token_sits() {
    let _diagnostic = crate::diagnostic::Span::begin(concat!(
        module_path!(),
        "::each_placing_skill_renders_the_paragraph_where_its_token_sits"
    ));
    let f = fixture(&format!(
        "[shared-text]\ndelivery = \"{PARAGRAPH}\\n\\n\"\n\
         [skill-instructions]\n\
         dev = \"{{{{shared-text:delivery}}}}\"\n\
         orch = \"Own orch text.\\n\\n{{{{shared-text:delivery}}}}\\n\\nAfter.\"\n\
         github = \"Own github text.\"\n"
    ));
    applied(&f);
    let dev = skill_md(&f, "dev");
    assert!(!dev.contains("{{shared-text:"), "{dev}");
    assert_eq!(dev.matches(PARAGRAPH).count(), 1, "{dev}");
    assert!(
        dev.contains(&format!("## Project Instructions\n\n{PARAGRAPH}\n")),
        "{dev}"
    );
    let orch = skill_md(&f, "orch");
    assert!(!orch.contains("{{shared-text:"), "{orch}");
    assert_eq!(orch.matches(PARAGRAPH).count(), 1, "{orch}");
    assert!(
        orch.contains(&format!("Own orch text.\n\n{PARAGRAPH}\n\nAfter.")),
        "{orch}"
    );

    // The plan wrote its normalized copy back, and that copy places the
    // paragraph by token: the text is declared once, in its table.
    let written = fs::read_to_string(f.project.join("kendex.toml")).unwrap();
    let manifest = kendex_core::manifest::load_for_mutation(&f.project.join("kendex.toml"))
        .unwrap()
        .unwrap();
    assert!(manifest.agents.contains_key("maintainer"), "{written}");
    assert_eq!(
        written.matches("{{shared-text:delivery}}").count(),
        2,
        "{written}"
    );
    assert_eq!(written.matches(PARAGRAPH).count(), 1, "{written}");

    // A skill that places nothing renders the bytes a manifest without the
    // table renders.
    let plain = fixture("[skill-instructions]\ngithub = \"Own github text.\"\n");
    applied(&plain);
    assert_eq!(skill_md(&f, "github"), skill_md(&plain, "github"));
}
