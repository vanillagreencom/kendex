//! A rendering the target tool's own loader would reject never reaches
//! disk: the plan shows it as a conflict carrying the fix, and the tools
//! whose loaders do accept it install as usual.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;

use kendex_core::apply;
use kendex_core::engine::{DriftState, audit};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{HarnessId, Scope};

#[test]
#[allow(clippy::unwrap_used)]
fn a_name_opencode_cannot_load_blocks_there_while_claude_still_installs() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();

    let source = home.join("catalog");
    fs::create_dir_all(source.join("skills/My_Skill")).unwrap();
    fs::write(
        source.join("skills/My_Skill/SKILL.md"),
        "---\nname: My_Skill\ndescription: files issues\n---\nBody.\n",
    )
    .unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\", \"opencode\"]\nmethod = \"symlink\"\n\n[skills.My_Skill]\nsource = \"cat\"\n",
            source_path(&source)
        ),
    )
    .unwrap();

    let scope = Scope::Project {
        root: project.clone(),
    };
    let report = audit(&env, &scope).unwrap();
    let row = report
        .drift
        .iter()
        .find(|row| row.harness == HarnessId::Opencode)
        .unwrap_or_else(|| panic!("opencode row missing: {:?}", report.drift));
    assert_eq!(row.state, DriftState::Conflict);
    assert!(
        row.detail.contains("My_Skill") && row.detail.contains("my-skill"),
        "the conflict names the fix: {}",
        row.detail
    );
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.harness == HarnessId::Claude && row.state == DriftState::Missing),
        "claude still installs: {:?}",
        report.drift
    );

    apply::execute(&env, &report.plan).unwrap();
    // OpenCode reads the shared tree, so a name it cannot load keeps the
    // shared tree empty — writing it there would put the rejected file
    // exactly where OpenCode looks. Claude Code, whose loader accepts the
    // name, gets a real directory of its own instead of a link.
    assert!(!project.join(".agents/skills/My_Skill").exists());
    let claude = project.join(".claude/skills/My_Skill");
    assert!(claude.is_dir() && !claude.is_symlink());
    assert!(
        fs::read_to_string(claude.join("SKILL.md"))
            .unwrap()
            .contains("Body.")
    );
    assert!(!project.join(".opencode/skills/My_Skill").exists());
}
