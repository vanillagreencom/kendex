//! What a generated command-as-skill is called, and what happens to the tree
//! it used to occupy when that name changes. Two commands must never pick
//! one name, and a tree an earlier install wrote is ours to clear away.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::apply;
use kendex_core::engine::{DriftState, audit};
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    skills: PathBuf,
    project: PathBuf,
    source: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn put(path: &Path, text: &str) {
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

#[allow(clippy::unwrap_used)]
fn fixture() -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path().to_path_buf();
    let project = home.join("dev/app");
    Fixture {
        env: Env::fake(&home, FakeOs::Linux),
        scope: Scope::Project {
            root: project.clone(),
        },
        skills: project.join(".agents/skills"),
        source: home.join("catalog"),
        project,
        _tmp: tmp,
    }
}

fn declare(f: &Fixture, declarations: &str) {
    put(
        &f.project.join("kendex.toml"),
        &format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"codex\"]\nmethod = \"symlink\"\n\n{declarations}",
            source_path(&f.source)
        ),
    );
}

fn add_command(f: &Fixture, name: &str, body: &str) {
    // Commands install only from a catalog that declares kendex's layout — a
    // bare `commands/` folder in a discovered repo is repository tooling, not
    // installable content. The marker makes this source an explicit catalog.
    put(&f.source.join("kendex.toml"), "is_source_catalog = true\n");
    put(
        &f.source.join(format!("commands/{name}.md")),
        &format!("---\ndescription: {name}\n---\n\n{body}\n"),
    );
}

fn add_skill(f: &Fixture, name: &str, body: &str) {
    put(
        &f.source.join(format!("skills/{name}/SKILL.md")),
        &format!("---\nname: {name}\ndescription: {name}\n---\n\n{body}\n"),
    );
}

#[allow(clippy::unwrap_used)]
fn apply_now(f: &Fixture) {
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

/// Nothing left to do and nothing needing a human: an empty plan with no
/// conflict row. An orphan row is a report about a dropped declaration, not
/// unfinished work, so it is checked where it is expected.
#[allow(clippy::unwrap_used)]
fn settled(f: &Fixture) -> bool {
    let report = audit(&f.env, &f.scope).unwrap();
    report.plan.ops.is_empty()
        && !report
            .drift
            .iter()
            .any(|row| row.state == DriftState::Conflict)
}

#[allow(clippy::unwrap_used)]
fn body_of(dir: &Path) -> String {
    fs::read_to_string(dir.join("SKILL.md")).unwrap()
}

/// A skill holds its own name and each command takes the next free one, in a
/// fixed order. Without that, two commands claim one tree: one body wins,
/// silently, and every apply hands it to the other one.
#[test]
#[allow(clippy::unwrap_used)]
fn two_commands_never_fight_over_one_emitted_name() {
    let f = fixture();
    add_skill(&f, "ship", "The real skill.");
    add_command(&f, "ship", "Ship the branch.");
    add_command(&f, "ship__command", "Something else entirely.");
    declare(
        &f,
        "[skills.ship]\nsource = \"cat\"\n\n[commands.ship]\nsource = \"cat\"\n\n[commands.ship__command]\nsource = \"cat\"\n",
    );
    apply_now(&f);

    assert!(body_of(&f.skills.join("ship")).contains("The real skill."));
    assert!(body_of(&f.skills.join("ship__command")).contains("Ship the branch."));
    assert!(body_of(&f.skills.join("ship__command__command")).contains("Something else entirely."));
    // Two audits in a row: the names must not swap back and forth.
    assert!(settled(&f));
    assert!(settled(&f));
    assert!(audit(&f.env, &f.scope).unwrap().drift.is_empty());
}

/// A real skill declared later takes the name back. The command relocates,
/// and the tree it leaves behind is ours to hand over — not an unmanaged
/// directory the user has to delete before the skill can install.
#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_claiming_a_command_s_name_takes_the_tree_over() {
    let f = fixture();
    add_command(&f, "ship", "Ship the branch.");
    declare(&f, "[commands.ship]\nsource = \"cat\"\n");
    apply_now(&f);
    assert!(body_of(&f.skills.join("ship")).contains("Ship the branch."));

    add_skill(&f, "ship", "The real skill.");
    declare(
        &f,
        "[skills.ship]\nsource = \"cat\"\n\n[commands.ship]\nsource = \"cat\"\n",
    );
    apply_now(&f);

    assert!(body_of(&f.skills.join("ship")).contains("The real skill."));
    assert!(body_of(&f.skills.join("ship__command")).contains("Ship the branch."));
    assert!(settled(&f));
}

/// The clash clears and the command gets its plain name back. The tree it
/// used while renamed must go, or both tools list a skill nobody declared.
#[test]
#[allow(clippy::unwrap_used)]
fn a_command_getting_its_name_back_leaves_no_old_tree() {
    let f = fixture();
    add_command(&f, "ship", "Ship the branch.");
    add_skill(&f, "ship", "The real skill.");
    declare(
        &f,
        "[skills.ship]\nsource = \"cat\"\n\n[commands.ship]\nsource = \"cat\"\n",
    );
    apply_now(&f);
    assert!(f.skills.join("ship__command").is_dir());

    fs::remove_dir_all(f.source.join("skills/ship")).unwrap();
    declare(&f, "[commands.ship]\nsource = \"cat\"\n");
    apply_now(&f);

    assert!(body_of(&f.skills.join("ship")).contains("Ship the branch."));
    assert!(
        !f.skills.join("ship__command").exists(),
        "the renamed tree outlived the rename"
    );
    assert!(settled(&f));
}

/// A command from a marketplace catalog has to reserve the name it really
/// writes. The catalog's own skills are held back under the spelling they
/// would install as, or declaring one later moves a tree the user has
/// already learned to type.
#[test]
#[allow(clippy::unwrap_used)]
fn a_catalog_holds_back_the_names_its_skills_would_install_as() {
    let f = fixture();
    put(
        &f.source.join(".claude-plugin/marketplace.json"),
        r#"{"name": "cat", "owner": {"name": "o"},
            "plugins": [{"name": "p", "source": "./plugins/p"}]}"#,
    );
    put(
        &f.source.join("plugins/p/skills/thing/SKILL.md"),
        "---\nname: thing\ndescription: thing\n---\n\nThe real skill.\n",
    );
    put(
        &f.source.join("plugins/p/commands/thing.md"),
        "---\ndescription: thing\n---\n\nShip the branch.\n",
    );
    declare(&f, "[commands.\"p/thing\"]\nsource = \"cat\"\n");
    apply_now(&f);

    assert!(body_of(&f.skills.join("p__thing__command")).contains("Ship the branch."));
    assert!(
        !f.skills.join("p__thing").exists(),
        "the command took the tree the catalog's own skill installs into"
    );

    // Declaring that skill is a single edit away, and it must not move
    // anything the user is already using.
    declare(
        &f,
        "[skills.\"p/thing\"]\nsource = \"cat\"\n\n[commands.\"p/thing\"]\nsource = \"cat\"\n",
    );
    apply_now(&f);
    assert!(body_of(&f.skills.join("p__thing")).contains("The real skill."));
    assert!(body_of(&f.skills.join("p__thing__command")).contains("Ship the branch."));
    assert!(settled(&f));
}
