//! A hostile catalog cannot read outside its root through any read path:
//! the refused item degrades to a note, the rest of the scope still plans,
//! and no host bytes reach a rendered artifact.
#![cfg(unix)]

use std::fs;

use kendex_core::apply::Op;
use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

#[test]
#[allow(clippy::unwrap_used)]
fn a_symlinked_catalog_cannot_leak_host_files_into_artifacts() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    fs::write(home.join("secret.txt"), "HOST-SECRET").unwrap();

    let source = home.join("catalog");
    fs::create_dir_all(source.join("skills/evil")).unwrap();
    fs::write(
        source.join("skills/evil/SKILL.md"),
        "---\nname: evil\n---\nBody.\n",
    )
    .unwrap();
    std::os::unix::fs::symlink(home.join("secret.txt"), source.join("skills/evil/steal.md"))
        .unwrap();
    fs::create_dir_all(source.join("skills/good")).unwrap();
    fs::write(
        source.join("skills/good/SKILL.md"),
        "---\nname: good\n---\nBody.\n",
    )
    .unwrap();

    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\npath = \"{}\"\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.evil]\nsource = \"cat\"\n\n[skills.good]\nsource = \"cat\"\n",
            source.display()
        ),
    )
    .unwrap();

    let scope = Scope::Project {
        root: project.clone(),
    };
    let report = audit(&env, &scope).unwrap();
    assert!(
        report
            .notes
            .iter()
            .any(|n| n.starts_with("evil:") && n.contains("refused")),
        "the hostile skill is a loud note: {:?}",
        report.notes
    );
    for op in &report.plan.ops {
        if let Op::WriteTree { files, .. } = &op.op {
            for (_, bytes) in files {
                assert!(!bytes.windows(11).any(|w| w == b"HOST-SECRET"));
            }
        }
    }
    // The clean skill still installs.
    assert!(
        report
            .plan
            .ops
            .iter()
            .any(|op| op.description.contains("good"))
    );
}
