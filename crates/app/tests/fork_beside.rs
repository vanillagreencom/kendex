//! Installing an edited copy beside its original: what the answer says
//! once the fork has landed, settled or not.
#![cfg(unix)]

use crate::test_util;
use test_util::{rooted, source_path};

use std::fs;

use kendex_app::packages::{LandingStopped, fork_beside};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::{HarnessId, ItemKind, Scope};

/// A fork that landed keeps its own report when the settle behind it
/// fails: the link its capture kept rides on `Recorded` as typed
/// warnings, so the window shows it without reading the message.
#[test]
#[allow(clippy::unwrap_used)]
fn a_recorded_fork_carries_the_links_it_kept() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    let catalog = home.join("catalog");
    fs::create_dir_all(catalog.join("skills/deploy")).unwrap();
    fs::write(
        catalog.join("skills/deploy/SKILL.md"),
        "---\nname: deploy\ndescription: does deploy\n---\nUpstream.\n",
    )
    .unwrap();
    fs::create_dir_all(catalog.join("agents")).unwrap();
    fs::write(
        catalog.join("agents/extra.md"),
        "---\nname: extra\ndescription: does extra\n---\nUpstream.\n",
    )
    .unwrap();
    fs::create_dir_all(project.join(".claude")).unwrap();
    let manifest = format!(
        "schema = 8\n[sources.cat]\n{}\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n[skills.deploy]\nsource = \"cat\"\n",
        source_path(&catalog)
    );
    fs::write(project.join("kendex.toml"), &manifest).unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };
    let report = kendex_core::engine::audit(&env, &scope).unwrap();
    kendex_core::apply::execute(&env, &report.plan).unwrap();
    // The edit adds a link out of the project, which no spelling from the
    // fork's store reaches inside it.
    let copy = project.join(".claude/skills/deploy/SKILL.md");
    let edited = format!(
        "{}[o](../../../../../outside.md)\n",
        fs::read_to_string(&copy).unwrap()
    );
    fs::write(&copy, edited).unwrap();
    // A declared agent the settle has to write, into a folder that refuses
    // the write.
    fs::write(
        project.join("kendex.toml"),
        format!("{manifest}[agents.extra]\nsource = \"cat\"\n"),
    )
    .unwrap();
    let agents = project.join(".claude/agents");
    fs::create_dir_all(&agents).unwrap();
    let Some(unwritable) = test_util::unwritable_dir(&agents) else {
        return;
    };

    let answer = fork_beside(
        &env,
        &scope,
        ItemKind::Skill,
        "deploy",
        HarnessId::Claude,
        "deploy-mine",
        None,
    );
    drop(unwritable);
    let written = match answer {
        Err(LandingStopped::Recorded { written, .. }) => written,
        Err(LandingStopped::Refused { message }) => panic!("the fork was refused: {message}"),
        Ok(_) => panic!("the settle went through, so this fixture proves nothing"),
    };
    let written: Vec<Option<&str>> = written
        .iter()
        .map(|warning| warning.detail.as_deref())
        .collect();
    assert_eq!(
        written,
        [Some("skill-link-kept: SKILL.md: ../../../../../outside.md")]
    );
}
