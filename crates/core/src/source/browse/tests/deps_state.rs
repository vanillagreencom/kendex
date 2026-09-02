//! What state a dependency row reads, and which declared names produce a
//! row at all. The page and the install picker act on these, so each case
//! sits beside the one that must answer differently.

use std::fs;
use std::path::Path;

use super::test_util::rooted;
use super::*;

/// A skill declaring one required dependency.
fn requiring(catalog: &Path, name: &str, required: &str) {
    let home = catalog.join("skills").join(name);
    fs::create_dir_all(&home).unwrap();
    fs::write(
        home.join("SKILL.md"),
        format!(
            "---\nname: {name}\ndescription: does {name} things\ndependencies:\n  required: [\"{required}\"]\n---\nbody\n"
        ),
    )
    .unwrap();
}

fn required_of(env: &Env, scope: &Scope, name: &str) -> Vec<(String, InstallState)> {
    package_preview(env, &cat(scope), ItemKind::Skill, name)
        .unwrap()
        .dependencies
        .required
        .into_iter()
        .map(|dep| (dep.name, dep.state))
        .collect()
}

/// A removal the person recorded keeps the dependency out of every plan
/// (`engine::deps::wanted_by` refuses on the same predicate), so the row
/// says it was their choice rather than offering to install it.
#[test]
fn a_dependency_the_person_removed_reads_as_removed_by_you() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let catalog = root.join("catalog");
    requiring(&catalog, "dev", "gh");
    skill(&catalog, "skills", "gh", "body");
    let (env, scope) = project(
        &root,
        &format!(
            "{}\n[suppressed]\nskill = [\"gh\"]\n",
            sources_decl(&catalog)
        ),
    );

    assert_eq!(
        required_of(&env, &scope, "dev"),
        vec![("gh".to_owned(), InstallState::RemovedByYou)]
    );
}

/// The must-fail control beside it: the same catalog with nothing recorded
/// as removed reads Available, so the state above is the record speaking
/// and not something every row says.
#[test]
fn the_same_dependency_with_no_removal_recorded_reads_available() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let catalog = root.join("catalog");
    requiring(&catalog, "dev", "gh");
    skill(&catalog, "skills", "gh", "body");
    let (env, scope) = project(&root, &sources_decl(&catalog));

    assert_eq!(
        required_of(&env, &scope, "dev"),
        vec![("gh".to_owned(), InstallState::Available)]
    );
}

/// A removal a declaration outranks is no removal: `Manifest::is_held_back`
/// lets a declared name through, and the row has to agree or it would
/// report a package the install does bring as kept out.
#[test]
fn a_removal_the_declaration_outranks_reads_installed() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let catalog = root.join("catalog");
    requiring(&catalog, "dev", "gh");
    skill(&catalog, "skills", "gh", "body");
    let (env, scope) = project(
        &root,
        &format!(
            "{}\n[skills.gh]\nsource = \"cat\"\n\n[suppressed]\nskill = [\"gh\"]\n",
            sources_decl(&catalog)
        ),
    );
    save_lock(&env, &scope, &[(ItemKind::Skill, "gh")]);

    assert_eq!(
        required_of(&env, &scope, "dev"),
        vec![("gh".to_owned(), InstallState::Installed)]
    );
}

/// A leaf name two plugins both offer is one the engine refuses to guess
/// between, so nothing here is on offer either — showing an arbitrary
/// plugin's state would name a package the install would never take.
#[test]
fn a_name_two_plugins_both_offer_reads_as_not_offered() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let catalog = root.join("catalog");
    fs::create_dir_all(catalog.join(".claude-plugin")).unwrap();
    fs::write(
        catalog.join(".claude-plugin/marketplace.json"),
        r#"{"name":"reg","owner":{"name":"o"},"plugins":[{"name":"tools","source":"./plugins/tools"},{"name":"more","source":"./plugins/more"}]}"#,
    )
    .unwrap();
    requiring(&catalog.join("plugins/tools"), "dev", "eda");
    skill(&catalog, "plugins/tools/skills", "eda", "body");
    skill(&catalog, "plugins/more/skills", "eda", "body");
    let (env, scope) = project(&root, &sources_decl(&catalog));

    assert_eq!(
        required_of(&env, &scope, "tools/dev"),
        vec![("eda".to_owned(), InstallState::NotOffered)]
    );
}

/// The must-fail control beside it: with only one plugin offering the leaf
/// name it resolves, so the refusal above is the second candidate speaking.
#[test]
fn a_name_one_plugin_offers_resolves() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let catalog = root.join("catalog");
    fs::create_dir_all(catalog.join(".claude-plugin")).unwrap();
    fs::write(
        catalog.join(".claude-plugin/marketplace.json"),
        r#"{"name":"reg","owner":{"name":"o"},"plugins":[{"name":"tools","source":"./plugins/tools"},{"name":"more","source":"./plugins/more"}]}"#,
    )
    .unwrap();
    requiring(&catalog.join("plugins/tools"), "dev", "eda");
    skill(&catalog, "plugins/tools/skills", "eda", "body");
    skill(&catalog, "plugins/more/skills", "other", "body");
    let (env, scope) = project(&root, &sources_decl(&catalog));

    assert_eq!(
        required_of(&env, &scope, "tools/dev"),
        vec![("eda".to_owned(), InstallState::Available)]
    );
}

/// A skill that lists its own name: the engine treats that line as
/// installing nothing, so the panel shows no row for it either.
#[test]
fn a_skill_that_lists_itself_produces_no_dependency_row() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let catalog = root.join("catalog");
    requiring(&catalog, "dev", "dev");
    let (env, scope) = project(&root, &sources_decl(&catalog));

    assert!(required_of(&env, &scope, "dev").is_empty());
}

/// The declared spelling is what an install's optional choice is matched
/// with, so it travels raw; the escaped spelling travels beside it for
/// display. A name carrying a control character would otherwise be ticked
/// in its escaped form and refused by the add.
#[test]
fn a_dependency_row_carries_the_raw_name_and_an_escaped_one_to_show() {
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let catalog = root.join("catalog");
    requiring(&catalog, "dev", "gh\u{202e}x");
    let (env, scope) = project(&root, &sources_decl(&catalog));

    let preview = package_preview(&env, &cat(&scope), ItemKind::Skill, "dev").unwrap();
    let dep = &preview.dependencies.required[0];
    assert_eq!(dep.name, "gh\u{202e}x", "the raw name the install matches");
    assert_ne!(dep.shown, dep.name, "the shown name escapes it");
    assert!(!dep.shown.contains('\u{202e}'), "{}", dep.shown);
}
