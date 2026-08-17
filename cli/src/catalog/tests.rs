//! Catalog discovery: root expansion, per-kind inventory, and the source
//! problems that must never read as an item removed upstream.

use super::*;
use std::fs;
use std::time::{SystemTime, UNIX_EPOCH};

fn sandbox(label: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_nanos();
    let dir = std::env::temp_dir().join(format!(
        "vstack-catalog-{label}-{}-{nanos}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn custom_catalog_roots_discover_each_item_kind() {
    let root = sandbox("custom-roots");
    fs::write(
        root.join("vstack.toml"),
        r#"[catalog]
agents = ["pkgs/agent-defs"]
skills = ["pkgs/skill-*", "single/custom-skill"]
hooks = ["pkgs/hook-defs"]
pi_extensions = ["apps/pi-*"]
extras = ["theme-packs"]
"#,
    )
    .unwrap();

    fs::create_dir_all(root.join("pkgs/agent-defs")).unwrap();
    fs::write(
        root.join("pkgs/agent-defs/rust.md"),
        "---\nname: rust\ndescription: Rust\nrole: engineer\n---\n# Rust\n",
    )
    .unwrap();

    fs::create_dir_all(root.join("pkgs/skill-demo")).unwrap();
    fs::write(
        root.join("pkgs/skill-demo/SKILL.md"),
        "---\nname: demo\ndescription: Demo\n---\n# Demo\n",
    )
    .unwrap();
    fs::create_dir_all(root.join("single/custom-skill")).unwrap();
    fs::write(
        root.join("single/custom-skill/SKILL.md"),
        "---\nname: custom\ndescription: Custom\n---\n# Custom\n",
    )
    .unwrap();

    fs::create_dir_all(root.join("pkgs/hook-defs")).unwrap();
    fs::write(
        root.join("pkgs/hook-defs/guard.sh"),
        "# ---\n# name: guard\n# event: PreToolUse\n# matcher: Bash\n# description: Guard\n# ---\n",
    )
    .unwrap();

    fs::create_dir_all(root.join("apps/pi-demo")).unwrap();
    fs::write(
        root.join("apps/pi-demo/package.json"),
        "{\"name\":\"@example/pi-demo\",\"version\":\"1.0.0\",\"pi\":{\"extensions\":[]}}\n",
    )
    .unwrap();

    fs::create_dir_all(root.join("theme-packs/method")).unwrap();
    fs::write(
        root.join("theme-packs/method/extra.toml"),
        "name = \"method\"\nkind = \"theme-pack\"\ndescription = \"Theme\"\ndefault-theme = \"dark\"\n",
    )
    .unwrap();

    assert_eq!(discover_agents(&root).unwrap()[0].name, "rust");
    let skills: Vec<String> = discover_skills(&root)
        .unwrap()
        .into_iter()
        .map(|skill| skill.name)
        .collect();
    assert_eq!(skills, vec!["custom".to_string(), "demo".to_string()]);
    assert_eq!(discover_hooks(&root).unwrap()[0].name, "guard");
    assert_eq!(
        discover_pi_extensions(&root).unwrap()[0].name,
        "@example/pi-demo"
    );
    assert_eq!(discover_extras(&root).unwrap()[0].name(), "method");

    let _ = fs::remove_dir_all(root);
}

fn skill_at(root: &Path, rel: &str, name: &str) {
    fs::create_dir_all(root.join(rel)).unwrap();
    fs::write(
        root.join(rel).join("SKILL.md"),
        format!("---\nname: {name}\ndescription: {name}\n---\nbody\n"),
    )
    .unwrap();
}

fn inv(root: &Path, catalog: &crate::mapping::CatalogConfig) -> KindInventory {
    inventory(root, crate::config::ItemKind::Skill, catalog)
}

#[test]
fn kind_states_separate_readable_empty_from_missing_root_and_error() {
    let root = sandbox("kind-states");
    let default_catalog = crate::mapping::CatalogConfig::default();

    // No `skills/` at all: the layout moved, nothing can be concluded.
    assert!(matches!(
        inv(&root, &default_catalog),
        KindInventory::MissingRoot
    ));

    // The root exists but is empty: that is POSITIVE evidence the source
    // ships no skills — the last one really was removed.
    fs::create_dir_all(root.join("skills")).unwrap();
    let empty = inv(&root, &default_catalog);
    assert!(matches!(&empty, KindInventory::Readable(inv) if inv.names.is_empty()));
    assert!(
        empty.readable().unwrap().names_are_complete(),
        "an empty readable root proves absence"
    );

    // A zero-match glob whose PARENT exists is the same story: readable,
    // currently shipping nothing.
    let globbed = crate::mapping::CatalogConfig {
        skills: Some(vec!["pkgs/skill-*".into()]),
        ..Default::default()
    };
    fs::create_dir_all(root.join("pkgs")).unwrap();
    assert!(matches!(
        inv(&root, &globbed),
        KindInventory::Readable(inv) if inv.names.is_empty()
    ));
    // Control: the same glob with no parent directory is a missing root.
    let elsewhere = crate::mapping::CatalogConfig {
        skills: Some(vec!["nowhere/skill-*".into()]),
        ..Default::default()
    };
    assert!(matches!(inv(&root, &elsewhere), KindInventory::MissingRoot));

    // A configuration that cannot be expanded at all is an error, never a
    // silent empty inventory.
    let bad = crate::mapping::CatalogConfig {
        skills: Some(vec!["../escape".into()]),
        ..Default::default()
    };
    assert!(matches!(inv(&root, &bad), KindInventory::Error(_)));
    assert!(
        inv(&root, &bad)
            .unverifiable(crate::config::ItemKind::Skill)
            .is_some()
    );
    assert!(
        inv(&root, &globbed)
            .unverifiable(crate::config::ItemKind::Skill)
            .is_none(),
        "a readable kind is verifiable"
    );

    let _ = fs::remove_dir_all(root);
}

#[test]
fn a_directory_that_parsed_under_a_new_name_does_not_shelter_the_old_one() {
    // A skill renamed in its own SKILL.md while the directory keeps the
    // old basename. The old name is GONE — refresh is keyed on the
    // declared name and could never find it again — so a directory that
    // parsed cleanly must not answer for a name it does not declare.
    let root = sandbox("renamed-in-manifest");
    skill_at(&root, "skills/alpha", "renamed-alpha");
    let catalog = crate::mapping::CatalogConfig::default();
    let inventory = inv(&root, &catalog);
    let readable = inventory.readable().unwrap();
    assert_eq!(readable.names, vec!["renamed-alpha".to_string()]);
    assert!(
        readable.names_are_complete(),
        "a clean parse leaves nothing unaccounted for, so `alpha` is removed"
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn an_unparseable_candidate_shelters_every_name_of_its_kind() {
    // A directory need not be named after the item it declares, so an
    // unparseable manifest could be ANY locked item's — including one
    // whose directory name matches nothing.
    let root = sandbox("unparseable-candidate");
    let catalog = crate::mapping::CatalogConfig::default();
    skill_at(&root, "skills/keeper", "keeper");
    fs::create_dir_all(root.join("skills").join("mystery")).unwrap();
    fs::write(root.join("skills/mystery/SKILL.md"), "no frontmatter\n").unwrap();
    let inventory = inv(&root, &catalog);
    let readable = inventory.readable().unwrap();
    assert!(
        !readable.names_are_complete(),
        "an unparseable candidate makes the name list incomplete"
    );

    // A candidate named after the locked item behaves the same way — it is
    // the parse failure, not the name, that carries the evidence.
    fs::remove_dir_all(root.join("skills").join("mystery")).unwrap();
    fs::create_dir_all(root.join("skills").join("gone")).unwrap();
    fs::write(root.join("skills/gone/SKILL.md"), "no frontmatter\n").unwrap();
    assert!(
        !inv(&root, &catalog)
            .readable()
            .unwrap()
            .names_are_complete()
    );

    // Control: once discovery is clean, absence is provable again.
    fs::remove_dir_all(root.join("skills").join("gone")).unwrap();
    assert!(
        inv(&root, &catalog)
            .readable()
            .unwrap()
            .names_are_complete()
    );

    let _ = fs::remove_dir_all(root);
}

#[test]
fn one_missing_configured_root_makes_the_whole_kind_unverifiable() {
    // Two configured roots, one gone: the readable one cannot vouch for
    // the items the missing one used to supply, so the kind is a layout
    // problem to inspect — never a list of removals to run.
    let root = sandbox("partial-roots");
    let two_roots = crate::mapping::CatalogConfig {
        skills: Some(vec!["skills".into(), "packages/skills".into()]),
        ..Default::default()
    };
    skill_at(&root, "skills/keeper", "keeper");
    assert!(matches!(inv(&root, &two_roots), KindInventory::MissingRoot));

    // Control: with both roots present the kind is readable as before.
    skill_at(&root, "packages/skills/extra", "extra");
    assert!(matches!(
        inv(&root, &two_roots),
        KindInventory::Readable(inv) if inv.names == ["extra".to_string(), "keeper".to_string()]
    ));

    // Control: a single configured root that is missing is unchanged.
    let one_missing = crate::mapping::CatalogConfig {
        skills: Some(vec!["nowhere".into()]),
        ..Default::default()
    };
    assert!(matches!(
        inv(&root, &one_missing),
        KindInventory::MissingRoot
    ));

    let _ = fs::remove_dir_all(root);
}

#[test]
fn an_explicitly_empty_catalog_list_is_a_readable_empty_kind() {
    // `skills = []` is positive evidence the source ships no skills, so a
    // lock entry against it is removed upstream — unlike an ABSENT key,
    // which expands to `skills/` and is a missing root when that is gone.
    let root = sandbox("empty-catalog-list");
    let declared_empty = crate::mapping::CatalogConfig {
        skills: Some(Vec::new()),
        ..Default::default()
    };
    assert!(matches!(
        inv(&root, &declared_empty),
        KindInventory::Readable(inv) if inv.names.is_empty()
    ));
    assert!(
        inv(&root, &declared_empty)
            .readable()
            .unwrap()
            .names_are_complete(),
        "an explicitly empty list proves absence"
    );

    // Control: the absent key is still a missing root.
    assert!(matches!(
        inv(&root, &crate::mapping::CatalogConfig::default()),
        KindInventory::MissingRoot
    ));

    let _ = fs::remove_dir_all(root);
}

#[cfg(unix)]
#[test]
fn an_unreadable_item_directory_is_a_discovery_failure_not_a_removal() {
    use std::os::unix::fs::PermissionsExt;
    // SAFETY: `geteuid` reads the calling process's effective uid; it
    // takes no arguments and cannot fail.
    if unsafe { libc::geteuid() } == 0 {
        return; // root ignores the permission bits this test relies on
    }
    let root = sandbox("unreadable-dir");
    skill_at(&root, "skills/keeper", "keeper");
    let locked_dir = root.join("skills").join("secret");
    fs::create_dir_all(&locked_dir).unwrap();
    fs::write(locked_dir.join("SKILL.md"), "---\nname: secret\n---\n").unwrap();
    fs::set_permissions(&locked_dir, fs::Permissions::from_mode(0o000)).unwrap();

    let catalog = crate::mapping::CatalogConfig::default();
    let inventory = inv(&root, &catalog);
    let readable = inventory.readable().expect("the ROOT is readable");
    fs::set_permissions(&locked_dir, fs::Permissions::from_mode(0o700)).unwrap();

    assert!(
        !readable.names_are_complete(),
        "files behind a permission bit are still files: {readable:?}"
    );
    let _ = fs::remove_dir_all(root);
}

/// A configured path may name the ITEM directory itself, and discovery stops
/// at that root's own manifest. Its internal directories are the package's own
/// content, never candidates — so an unreadable `references/private/` inside a
/// perfectly valid skill is not a discovery failure, and `check` must not exit
/// 1 over it forever.
#[cfg(unix)]
#[test]
fn an_unreadable_directory_inside_a_direct_item_root_is_not_a_discovery_failure() {
    use std::os::unix::fs::PermissionsExt;
    // SAFETY: `geteuid` reads the calling process's effective uid; it
    // takes no arguments and cannot fail.
    if unsafe { libc::geteuid() } == 0 {
        return; // root ignores the permission bits this test relies on
    }
    let root = sandbox("unreadable-inside-item-root");
    let catalog = crate::mapping::CatalogConfig {
        skills: Some(vec!["one-offs/specific-skill".into()]),
        ..Default::default()
    };
    skill_at(&root, "one-offs/specific-skill", "specific");

    // Control: readable and complete before anything is locked down.
    let readable = inv(&root, &catalog);
    let readable = readable.readable().expect("the item root is readable");
    assert_eq!(readable.names, vec!["specific".to_string()]);
    assert!(readable.names_are_complete(), "control: {readable:?}");

    let private = root
        .join("one-offs")
        .join("specific-skill")
        .join("references")
        .join("private");
    fs::create_dir_all(&private).unwrap();
    fs::set_permissions(&private, fs::Permissions::from_mode(0o000)).unwrap();
    let inventory = inv(&root, &catalog);
    let readable = inventory.readable().expect("the item root is readable");
    fs::set_permissions(&private, fs::Permissions::from_mode(0o700)).unwrap();

    assert_eq!(readable.names, vec!["specific".to_string()]);
    assert!(
        readable.names_are_complete(),
        "the item's own content is not a candidate: {readable:?}"
    );

    // Control: the same directory under a COLLECTION root still is a
    // discovery failure — that is where an unreadable directory hides an item.
    let collection = crate::mapping::CatalogConfig {
        skills: Some(vec!["one-offs".into()]),
        ..Default::default()
    };
    fs::set_permissions(&private, fs::Permissions::from_mode(0o000)).unwrap();
    let unreadable_item = root.join("one-offs").join("hidden-skill");
    fs::create_dir_all(&unreadable_item).unwrap();
    fs::set_permissions(&unreadable_item, fs::Permissions::from_mode(0o000)).unwrap();
    let inventory = inv(&root, &collection);
    let readable = inventory
        .readable()
        .expect("the collection root is readable");
    fs::set_permissions(&unreadable_item, fs::Permissions::from_mode(0o700)).unwrap();
    fs::set_permissions(&private, fs::Permissions::from_mode(0o700)).unwrap();
    assert!(
        !readable.names_are_complete(),
        "an unreadable candidate under a collection root is still a failure: {readable:?}"
    );

    // Control: the item root's OWN manifest failing to parse is still
    // reported, whatever its internal directories look like.
    fs::write(
        root.join("one-offs")
            .join("specific-skill")
            .join("SKILL.md"),
        "no frontmatter here\n",
    )
    .unwrap();
    let inventory = inv(&root, &catalog);
    let readable = inventory.readable().expect("the item root is readable");
    assert!(
        !readable.names_are_complete(),
        "a broken manifest on the item root is still a failure: {readable:?}"
    );

    let _ = fs::remove_dir_all(root);
}

/// Hooks and agents are files read from the root itself, so no subdirectory
/// of theirs can hide one. An unrelated protected directory beside them is
/// somebody else's business, not an incomplete inventory.
#[cfg(unix)]
#[test]
fn an_unreadable_directory_beside_hook_files_is_not_a_discovery_failure() {
    use std::os::unix::fs::PermissionsExt;
    // SAFETY: `geteuid` reads the calling process's effective uid; it
    // takes no arguments and cannot fail.
    if unsafe { libc::geteuid() } == 0 {
        return; // root ignores the permission bits this test relies on
    }
    let root = sandbox("unreadable-beside-hooks");
    let catalog = crate::mapping::CatalogConfig::default();
    fs::create_dir_all(root.join("hooks")).unwrap();
    fs::write(
        root.join("hooks").join("guard.sh"),
        "# ---\n# name: guard\n# event: PreToolUse\n# description: guard\n# ---\nexit 0\n",
    )
    .unwrap();
    skill_at(&root, "skills/keeper", "keeper");

    let hook_inventory = |root: &Path| inventory(root, crate::config::ItemKind::Hook, &catalog);
    // Control: both kinds are complete while everything is readable.
    assert!(
        hook_inventory(&root)
            .readable()
            .expect("hooks root is readable")
            .names_are_complete(),
        "control: a readable source is complete"
    );
    assert!(
        inv(&root, &catalog)
            .readable()
            .expect("skills root is readable")
            .names_are_complete(),
        "control: a readable source is complete"
    );

    for kind_root in ["hooks", "skills"] {
        let locked_dir = root.join(kind_root).join("private");
        fs::create_dir_all(&locked_dir).unwrap();
        fs::set_permissions(&locked_dir, fs::Permissions::from_mode(0o000)).unwrap();
    }

    let hooks = hook_inventory(&root);
    let hooks = hooks.readable().expect("hooks root is readable");
    // The same directory under the skills root IS a failure: that is where
    // an unreadable directory could be hiding an item.
    let skills = inv(&root, &catalog);
    let skills = skills.readable().expect("skills root is readable");
    for kind_root in ["hooks", "skills"] {
        fs::set_permissions(
            root.join(kind_root).join("private"),
            fs::Permissions::from_mode(0o700),
        )
        .unwrap();
    }

    assert_eq!(hooks.names, vec!["guard".to_string()]);
    assert!(
        hooks.names_are_complete(),
        "a directory cannot hide a hook file: {hooks:?}"
    );
    assert!(
        !skills.names_are_complete(),
        "an unreadable skill directory is still a discovery failure: {skills:?}"
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn a_package_renamed_in_its_manifest_is_removed_under_its_old_name() {
    // The lock names `@vg/pi-hooks` and the directory is still
    // `pi-hooks`, but its manifest declares a different package. The
    // directory name is not evidence: `vstack refresh` resolves the locked
    // name against declared names and would never find this package again.
    let root = sandbox("renamed-package");
    let dir = root.join("pi-extensions").join("pi-hooks");
    fs::create_dir_all(&dir).unwrap();
    fs::write(
        dir.join("package.json"),
        "{\"name\":\"@vg/pi-hooks-renamed\",\"version\":\"1.0.0\",\"keywords\":[\"pi-package\"],\"pi\":{\"extensions\":[]}}",
    )
    .unwrap();
    let catalog = crate::mapping::CatalogConfig::default();
    let inventory = inventory(&root, crate::config::ItemKind::PiExtension, &catalog);
    let readable = inventory.readable().expect("root exists and was read");
    assert_eq!(readable.names, vec!["@vg/pi-hooks-renamed".to_string()]);
    assert!(
        readable.names_are_complete(),
        "the manifest parsed, so the declared name is the whole truth"
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn glob_is_restricted_to_last_segment() {
    let root = sandbox("bad-glob");
    let err = expand_catalog_entry(&root, "*/skills").unwrap_err();
    assert!(
        err.to_string()
            .contains("only supported on the last path segment")
    );
    let _ = fs::remove_dir_all(root);
}

#[test]
fn wildcard_match_backtracks_to_later_suffix() {
    assert!(wildcard_match("*a", "aa"));
    assert!(wildcard_match("a*a", "ababa"));
    assert!(wildcard_match("pi-*-hooks", "pi-hooks-hooks"));
    assert!(!wildcard_match("a*b", "a"));
}
