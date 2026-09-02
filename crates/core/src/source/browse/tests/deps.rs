//! What the package page and the install picker read before an install:
//! the declared required and optional lists, each name with its state in
//! the scope the install would land in.

use std::fs;
use std::path::Path;

use super::test_util::rooted;
use super::*;

/// A skill whose frontmatter declares what it needs.
fn needing(catalog: &Path, name: &str, required: &[&str], optional: &[&str]) {
    let home = catalog.join("skills").join(name);
    fs::create_dir_all(&home).unwrap();
    let list = |names: &[&str]| {
        names
            .iter()
            .map(|name| format!("\"{name}\""))
            .collect::<Vec<_>>()
            .join(", ")
    };
    fs::write(
        home.join("SKILL.md"),
        format!(
            "---\nname: {name}\ndescription: does {name} things\ndependencies:\n  required: [{}]\n  optional: [{}]\n---\nbody\n",
            list(required),
            list(optional),
        ),
    )
    .unwrap();
}

fn named(rows: &[PackageDependency]) -> Vec<(&str, InstallState)> {
    rows.iter()
        .map(|dep| (dep.name.as_str(), dep.state))
        .collect()
}

/// The declared lists, each name with the state it has where the install
/// would land — which is the destination when one is chosen, not the scope
/// being browsed. Every state the surfaces draw is here at once: already
/// installed, on offer, kept removed by the person, and a leaf name the
/// catalog carries under two plugins, which the engine refuses to guess
/// between and so is not "not offered" either.
#[test]
fn declared_dependencies_carry_their_state_where_the_install_lands() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let catalog = root.join("catalog");
    fs::create_dir_all(catalog.join(".claude-plugin")).unwrap();
    fs::write(
        catalog.join(".claude-plugin/marketplace.json"),
        r#"{"name":"reg","owner":{"name":"o"},"plugins":[{"name":"tools","source":"./plugins/tools"},{"name":"more","source":"./plugins/more"}]}"#,
    )
    .unwrap();
    needing(
        &catalog.join("plugins/tools"),
        "dev",
        &["code-quality", "dup"],
        &["linear", "removed"],
    );
    for name in ["code-quality", "linear", "removed", "dup"] {
        skill(&catalog, "plugins/tools/skills", name, "body");
    }
    skill(&catalog, "plugins/more/skills", "dup", "body");

    // Browsed here, installed there: the destination's records are the ones
    // the states have to come from.
    let (env, browsing) = project(&root, &sources_decl(&catalog));
    let landing = Scope::Project {
        root: root.join("elsewhere"),
    };
    let Scope::Project { root: elsewhere } = &landing else {
        unreachable!()
    };
    fs::create_dir_all(elsewhere).unwrap();
    fs::write(
        elsewhere.join("kendex.toml"),
        format!(
            "{}\n[suppressed]\nskill = [\"tools/removed\"]\n",
            sources_decl(&catalog)
        ),
    )
    .unwrap();
    save_lock(&env, &landing, &[(ItemKind::Skill, "tools/code-quality")]);

    let preview = package_preview(
        &env,
        &cat(&browsing),
        ItemKind::Skill,
        "tools/dev",
        Some(&landing),
    )
    .unwrap();
    assert_eq!(
        named(&preview.dependencies.required),
        vec![
            ("code-quality", InstallState::Installed),
            ("dup", InstallState::OfferedMoreThanOnce),
        ]
    );
    assert_eq!(
        named(&preview.dependencies.optional),
        vec![
            ("linear", InstallState::Available),
            ("removed", InstallState::RemovedByYou),
        ]
    );
}

/// The must-fail control beside it: a skill that declares nothing carries
/// nothing, so the lists above are that package's own declaration and not
/// something every package would show.
#[test]
fn a_package_that_declares_nothing_carries_no_dependencies() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let catalog = root.join("catalog");
    skill(&catalog, "skills", "gh", "body");
    let (env, scope) = project(&root, &sources_decl(&catalog));

    let rows = packages(&env, &cat(&scope)).unwrap();
    let gh = rows.iter().find(|row| row.name == "gh").unwrap();
    assert!(gh.dependencies.is_empty(), "{:?}", gh.dependencies);
}
