//! What the package page and the install picker read before an install:
//! the declared required and optional lists, with each name's state here.

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

/// The row and the page read the same lists, and an installed dependency
/// reads as installed rather than as one more thing about to arrive.
#[test]
fn a_package_carries_its_declared_dependencies() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let catalog = root.join("catalog");
    needing(&catalog, "dev", &["code-quality"], &["linear"]);
    skill(&catalog, "skills", "code-quality", "body");
    skill(&catalog, "skills", "linear", "body");
    let (env, scope) = project(&root, &sources_decl(&catalog));
    save_lock(&env, &scope, &[(ItemKind::Skill, "code-quality")]);

    let rows = packages(&env, &cat(&scope)).unwrap();
    let dev = rows.iter().find(|row| row.name == "dev").unwrap();
    assert_eq!(
        named(&dev.dependencies.required),
        vec![("code-quality", InstallState::Installed)]
    );
    assert_eq!(
        named(&dev.dependencies.optional),
        vec![("linear", InstallState::Available)]
    );

    let preview = package_preview(&env, &cat(&scope), ItemKind::Skill, "dev").unwrap();
    assert_eq!(preview.dependencies, dev.dependencies);
}

/// The must-fail control on the read above: a skill that declares nothing
/// carries nothing, so the lists on `dev` are its own declaration and not
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

/// A dependency the catalog does not carry is still a row, saying so: the
/// reader owns the catalog line that put it there, and a silently dropped
/// name would have the page promise less than the install takes.
#[test]
fn a_dependency_the_catalog_lost_reads_as_not_offered() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let catalog = root.join("catalog");
    needing(&catalog, "dev", &["gone"], &[]);
    let (env, scope) = project(&root, &sources_decl(&catalog));

    let preview = package_preview(&env, &cat(&scope), ItemKind::Skill, "dev").unwrap();
    assert_eq!(
        named(&preview.dependencies.required),
        vec![("gone", InstallState::NotOffered)]
    );
}

/// The name a row carries is the one its parent declared — the spelling an
/// install's optional choice is matched against — even where the catalog
/// offers it under a plugin's qualified name.
#[test]
fn a_dependency_row_carries_the_declared_name() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let catalog = root.join("catalog");
    fs::create_dir_all(catalog.join(".claude-plugin")).unwrap();
    fs::write(
        catalog.join(".claude-plugin/marketplace.json"),
        r#"{"name":"reg","owner":{"name":"o"},"plugins":[{"name":"tools","source":"./plugins/tools"}]}"#,
    )
    .unwrap();
    let home = catalog.join("plugins/tools/skills/dev");
    fs::create_dir_all(&home).unwrap();
    fs::write(
        home.join("SKILL.md"),
        "---\nname: dev\ndescription: does dev things\ndependencies:\n  required: [\"eda\"]\n---\nbody\n",
    )
    .unwrap();
    skill(&catalog, "plugins/tools/skills", "eda", "body");
    let (env, scope) = project(&root, &sources_decl(&catalog));

    let preview = package_preview(&env, &cat(&scope), ItemKind::Skill, "tools/dev").unwrap();
    assert_eq!(
        named(&preview.dependencies.required),
        vec![("eda", InstallState::Available)]
    );
}

/// Only skills declare dependencies; every other kind reads as none rather
/// than as an unread question.
#[test]
fn a_kind_that_declares_no_dependencies_reads_as_none() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let catalog = root.join("catalog");
    fs::create_dir_all(catalog.join("agents")).unwrap();
    fs::write(
        catalog.join("agents/helper.md"),
        "---\nname: helper\ndescription: helps out\ndependencies:\n  required: [\"gh\"]\n---\nbody\n",
    )
    .unwrap();
    skill(&catalog, "skills", "gh", "body");
    let (env, scope) = project(&root, &sources_decl(&catalog));

    let preview = package_preview(&env, &cat(&scope), ItemKind::Agent, "helper").unwrap();
    assert!(
        preview.dependencies.is_empty(),
        "{:?}",
        preview.dependencies
    );
}
