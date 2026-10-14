use super::*;

use crate::source::plugin_registry::read;
use crate::test_util::rooted;

const REGISTRY: &str = r#"{
  "name": "workflows",
  "owner": {"name": "wshobson"},
  "metadata": {"description": "workflows", "version": "1.2.0"},
  "plugins": [
    {"name": "data-science", "source": "./plugins/data-science", "version": "0.4.0",
     "description": "analysis", "category": "analysis", "license": "MIT",
     "author": {"name": "wshobson"}, "homepage": "https://example.invalid"},
    {"name": "code-review", "source": "./plugins/code-review", "version": "1.0.0"}
  ]
}"#;

fn write(root: &std::path::Path, rel: &str, text: &str) {
    let path = root.join(rel);
    std::fs::create_dir_all(path.parent().expect("parent")).expect("mkdir");
    std::fs::write(path, text).expect("write");
}

/// A wshobson-shaped catalog: a registry, two plugins, three kinds.
fn fixture() -> (tempfile::TempDir, SealedSource) {
    let tmp = tempfile::tempdir().expect("tempdir");
    let root = tmp.path().join("catalog");
    write(&root, ".claude-plugin/marketplace.json", REGISTRY);
    write(
        &root,
        "plugins/data-science/.claude-plugin/plugin.json",
        r#"{"name": "data-science", "version": "0.4.0", "skills": "./skills"}"#,
    );
    write(
        &root,
        "plugins/data-science/agents/eda.md",
        "---\nname: eda\ndescription: explore\n---\nbody\n",
    );
    write(
        &root,
        "plugins/data-science/skills/eda/SKILL.md",
        "---\nname: eda\ndescription: explore\n---\nbody\n",
    );
    write(
        &root,
        "plugins/data-science/commands/report.md",
        "Write the report.\n",
    );
    write(
        &root,
        "plugins/code-review/agents/reviewer.md",
        "---\nname: reviewer\ndescription: review\n---\nbody\n",
    );
    let sealed = SealedSource::open(&root).expect("open");
    (tmp, sealed)
}

#[test]
fn items_are_named_for_the_plugin_they_came_from() {
    let (_tmp, sealed) = fixture();
    let registry = read(&sealed)
        .expect("read")
        .expect("plugin-registry-shaped");

    assert_eq!(
        items(&sealed, &registry, ItemKind::Agent),
        ["code-review/reviewer", "data-science/eda"]
    );
    assert_eq!(
        items(&sealed, &registry, ItemKind::Skill),
        ["data-science/eda"]
    );
    assert_eq!(
        items(&sealed, &registry, ItemKind::Command),
        ["data-science/report"]
    );
    // Kinds a plugin has no place for offer nothing rather than guessing.
    assert!(items(&sealed, &registry, ItemKind::Hook).is_empty());
}

#[test]
fn names_resolve_only_through_the_registry() {
    let (_tmp, sealed) = fixture();
    let registry = read(&sealed)
        .expect("read")
        .expect("plugin-registry-shaped");

    let skill = find(&sealed, &registry, ItemKind::Skill, "data-science/eda").expect("found");
    assert!(skill.ends_with("plugins/data-science/skills/eda"));
    let agent = find(&sealed, &registry, ItemKind::Agent, "data-science/eda").expect("found");
    assert!(agent.ends_with("plugins/data-science/agents/eda.md"));

    // A plugin the registry never validated is not a directory to read from,
    // whatever the repository happens to hold.
    assert_eq!(
        find(&sealed, &registry, ItemKind::Agent, "unlisted/x"),
        None
    );
    // Flat names mean nothing here, and neither does climbing out.
    assert_eq!(find(&sealed, &registry, ItemKind::Agent, "eda"), None);
    assert_eq!(
        find(
            &sealed,
            &registry,
            ItemKind::Agent,
            "data-science/../../secret"
        ),
        None
    );
}

#[test]
fn each_plugin_is_a_group_carrying_its_members_and_its_metadata() {
    let (_tmp, sealed) = fixture();
    let meta = metadata(&sealed)
        .expect("read")
        .expect("plugin-registry-shaped");

    assert_eq!(meta.name, "workflows");
    assert_eq!(meta.version.as_deref(), Some("1.2.0"));
    assert_eq!(meta.groups.len(), 2);
    let group = meta
        .groups
        .iter()
        .find(|g| g.name == "data-science")
        .expect("group");
    assert_eq!(group.version.as_deref(), Some("0.4.0"));
    assert_eq!(group.category.as_deref(), Some("analysis"));
    assert_eq!(group.license.as_deref(), Some("MIT"));
    assert_eq!(group.author.as_deref(), Some("wshobson"));
    let members: Vec<&str> = group.members.iter().map(|m| m.name.as_str()).collect();
    assert_eq!(
        members,
        [
            "data-science/eda",
            "data-science/report",
            "data-science/eda"
        ]
    );
    assert!(meta.findings.is_empty(), "{:?}", meta.findings);
}

/// A plugin that ships hooks or MCP servers says so: kendex installs its
/// skills, agents and commands from a registry, not those, and the finding
/// keeps installing the plugin from being mistaken for installing all of it.
#[test]
fn a_plugin_carrying_hooks_or_servers_says_they_are_not_installed() {
    let (tmp, _) = fixture();
    let root = tmp.path().join("catalog");
    write(
        &root,
        "plugins/data-science/.claude-plugin/plugin.json",
        r#"{"name": "data-science", "version": "0.4.0", "skills": "./skills", "hooks": "./hooks/hooks.json", "mcpServers": "./.mcp.json"}"#,
    );
    let sealed = SealedSource::open(&root).expect("open");
    let meta = metadata(&sealed).expect("read").expect("registry");
    assert!(
        meta.findings.iter().any(|f| f
            .problem
            .contains("hooks and MCP servers that kendex does not install")),
        "{:?}",
        meta.findings
    );
    // The skills/agents/commands are still offered.
    let group = meta
        .groups
        .iter()
        .find(|g| g.name == "data-science")
        .expect("group");
    assert!(group.members.iter().any(|m| m.name == "data-science/eda"));
}

#[test]
fn a_catalog_whose_two_files_disagree_is_reported() {
    let (tmp, _) = fixture();
    let root = tmp.path().join("catalog");
    write(
        &root,
        "plugins/data-science/.claude-plugin/plugin.json",
        r#"{"name": "datascience", "version": "9.9.9", "skills": "../code-review/skills"}"#,
    );
    let sealed = SealedSource::open(&root).expect("open");
    let meta = metadata(&sealed)
        .expect("read")
        .expect("plugin-registry-shaped");
    let problems: Vec<&str> = meta.findings.iter().map(|f| f.problem.as_str()).collect();

    assert!(
        problems.iter().any(|p| p.contains("calls itself")),
        "{problems:?}"
    );
    assert!(problems.iter().any(|p| p.contains("9.9.9")), "{problems:?}");
    assert!(
        problems.iter().any(|p| p.contains("outside this plugin")),
        "{problems:?}"
    );
    for finding in &meta.findings {
        assert!(!finding.fix.is_empty(), "{finding} needs a fix");
    }
}

#[test]
fn item_names_a_filesystem_would_fold_together_are_reported_not_installed() {
    let (tmp, _) = fixture();
    let root = tmp.path().join("catalog");
    // A case-insensitive filesystem cannot even hold the colliding pair —
    // the second write lands on the first — so the finding this check
    // exists to raise for such consumers can only be staged where case is
    // preserved as distinct.
    let case_sensitive = {
        std::fs::write(tmp.path().join("CaseProbe"), "a").unwrap();
        !tmp.path().join("caseprobe").exists()
    };
    write(
        &root,
        "plugins/data-science/agents/EDA.md",
        "---\nname: EDA\n---\nbody\n",
    );
    write(&root, "plugins/data-science/agents/nul.md", "---\n---\n");
    let sealed = SealedSource::open(&root).expect("open");
    let registry = read(&sealed)
        .expect("read")
        .expect("plugin-registry-shaped");
    let meta = metadata(&sealed)
        .expect("read")
        .expect("plugin-registry-shaped");
    let problems: Vec<&str> = meta.findings.iter().map(|f| f.problem.as_str()).collect();

    if case_sensitive {
        assert!(
            problems.iter().any(|p| p.contains("folded case")),
            "{problems:?}"
        );
    }
    assert!(
        problems.iter().any(|p| p.contains("reserved device name")),
        "{problems:?}"
    );
    // The offered list holds one of the two folded names, never both.
    let agents = items(&sealed, &registry, ItemKind::Agent);
    assert!(!agents.iter().any(|name| name.contains("nul")));
    if case_sensitive {
        assert_eq!(
            agents
                .iter()
                .filter(|name| names::fold(name) == "data-science/eda")
                .count(),
            1
        );
        for name in ["data-science/EDA", "data-science/eda"] {
            assert_eq!(
                find(&sealed, &registry, ItemKind::Agent, name).is_some(),
                agents.iter().any(|item| item == name)
            );
        }
    }
}

#[cfg(unix)]
#[test]
fn a_symlinked_plugin_component_is_never_read_through() {
    let (tmp, _) = fixture();
    let root = tmp.path().join("catalog");
    std::fs::write(tmp.path().join("secret.md"), "host secret").expect("write");
    std::os::unix::fs::symlink(
        tmp.path().join("secret.md"),
        root.join("plugins/code-review/agents/leak.md"),
    )
    .expect("symlink");
    let sealed = SealedSource::open(&root).expect("open");
    let registry = read(&sealed)
        .expect("read")
        .expect("plugin-registry-shaped");

    assert_eq!(
        find(&sealed, &registry, ItemKind::Agent, "code-review/leak"),
        None
    );
    assert!(
        !items(&sealed, &registry, ItemKind::Agent)
            .iter()
            .any(|name| name.ends_with("leak"))
    );
    let reviewer = root.join("plugins/code-review/agents/reviewer.md");
    std::fs::remove_file(&reviewer).expect("remove marker");
    std::os::unix::fs::symlink(tmp.path().join("secret.md"), &reviewer).expect("symlink");
    assert_eq!(
        find(&sealed, &registry, ItemKind::Agent, "code-review/reviewer"),
        None
    );
}

#[test]
fn a_registry_read_owns_its_offered_items_until_the_next_read() {
    let (_tmp, sealed) = fixture();
    let registry = read(&sealed).expect("read").expect("registry");
    let entry = registry.entry("data-science").expect("entry");
    for (kind, path) in [
        (ItemKind::Agent, "agents/late.md"),
        (ItemKind::Command, "commands/late.md"),
        (ItemKind::Skill, "skills/late/SKILL.md"),
    ] {
        write(
            sealed.root(),
            &format!("plugins/data-science/{path}"),
            "---\nname: late\ndescription: fixture\n---\nbody\n",
        );
        assert!(
            !items(&sealed, &registry, kind)
                .iter()
                .any(|name| name == "data-science/late")
        );
        assert!(find(&sealed, &registry, kind, "data-science/late").is_none());
        let group = group(&sealed, entry, &mut Vec::new()).expect("group");
        assert!(
            !group
                .members
                .iter()
                .any(|item| item.kind == kind && item.name == "data-science/late")
        );
        let fresh = read(&sealed).expect("read").expect("registry");
        assert!(
            items(&sealed, &fresh, kind)
                .iter()
                .any(|name| name == "data-science/late")
        );
        assert!(find(&sealed, &fresh, kind, "data-science/late").is_some());
    }
}

fn declared_fixture(source: &str, skills: Option<Value>) -> (tempfile::TempDir, SealedSource) {
    let tmp = tempfile::tempdir().expect("tempdir");
    let home = rooted(&tmp);
    let root = home.join("catalog");
    let mut plugin = serde_json::json!({"name": "heygen", "source": source});
    if let Some(skills) = skills {
        plugin["skills"] = skills;
    }
    write(
        &root,
        ".claude-plugin/marketplace.json",
        &serde_json::json!({
            "name": "heygen", "owner": {"name": "HeyGen"}, "plugins": [plugin]
        })
        .to_string(),
    );
    for leaf in ["heygen-avatar", "heygen-video", "skills/unlisted"] {
        write(
            &root,
            &format!("{source}/{leaf}/SKILL.md"),
            &format!(
                "---\nname: {}\ndescription: create media\n---\nmedia body\n",
                leaf.rsplit('/').next().expect("leaf")
            ),
        );
    }
    let sealed = SealedSource::open(&root).expect("open");
    (tmp, sealed)
}

#[test]
fn declared_skill_paths_agree_across_index_lookup_and_metadata() {
    for (source, skills, expected) in [
        (
            "./",
            Some(serde_json::json!([
                {"name": "avatar", "path": "heygen-avatar", "invoke": "/heygen:avatar"},
                {"name": "video", "path": "heygen-video"}
            ])),
            vec!["heygen/heygen-avatar", "heygen/heygen-video"],
        ),
        (
            ".",
            Some(serde_json::json!(["heygen-avatar", "./heygen-video"])),
            vec!["heygen/heygen-avatar", "heygen/heygen-video"],
        ),
        (
            "plugins/media",
            Some(serde_json::json!("heygen-avatar")),
            vec!["heygen/heygen-avatar"],
        ),
        ("plugins/media", None, vec!["heygen/unlisted"]),
        ("./", Some(serde_json::json!([])), vec![]),
    ] {
        let (_tmp, sealed) = declared_fixture(source, skills);
        let registry = read(&sealed).expect("read").expect("registry");
        assert!(registry.findings.is_empty(), "{source}");
        assert_eq!(
            items(&sealed, &registry, ItemKind::Skill),
            expected,
            "{source}"
        );
        let index = crate::source::index::index(&sealed, "heygen").expect("index");
        assert_eq!(
            index
                .packages
                .iter()
                .map(|item| item.name.as_str())
                .collect::<Vec<_>>(),
            expected,
            "{source}"
        );
        let meta = metadata(&sealed).expect("metadata").expect("registry");
        assert_eq!(
            meta.groups[0]
                .members
                .iter()
                .map(|item| item.name.as_str())
                .collect::<Vec<_>>(),
            expected,
            "{source}"
        );
        for name in [
            "heygen/heygen-avatar",
            "heygen/heygen-video",
            "heygen/unlisted",
            "heygen/avatar",
        ] {
            let path = find(&sealed, &registry, ItemKind::Skill, name);
            assert_eq!(path.is_some(), expected.contains(&name), "{source}: {name}");
            if let Some(path) = path {
                let leaf = name.split('/').nth(1).expect("leaf");
                let folder = if leaf == "unlisted" {
                    "skills/unlisted"
                } else {
                    leaf
                };
                assert_eq!(path, sealed.root().join(source).join(folder));
                assert!(
                    sealed
                        .read_to_string(&path.join("SKILL.md"))
                        .expect("marker")
                        .contains("media body")
                );
            }
        }
    }
}

#[test]
fn declared_unsafe_or_missing_skill_paths_are_named_and_do_not_hide_siblings() {
    for path in ["../outside", "/outside", "./../outside", "missing"] {
        let (_tmp, sealed) =
            declared_fixture("./", Some(serde_json::json!([path, "heygen-avatar"])));
        let registry = read(&sealed).expect("read").expect("registry");
        assert_eq!(
            items(&sealed, &registry, ItemKind::Skill),
            ["heygen/heygen-avatar"]
        );
        assert_eq!(
            registry
                .findings
                .iter()
                .map(|f| f.location.as_str())
                .collect::<Vec<_>>(),
            [format!(
                ".claude-plugin/marketplace.json: heygen: skills[{path}]"
            )]
        );
        assert!(find(&sealed, &registry, ItemKind::Skill, "heygen/outside").is_none());
    }
}

#[test]
fn an_empty_plugin_source_is_refused() {
    let (_tmp, sealed) = declared_fixture(".", None);
    write(
        sealed.root(),
        ".claude-plugin/marketplace.json",
        r#"{"name":"heygen","owner":{"name":"HeyGen"},"plugins":[{"name":"heygen","source":""}]}"#,
    );
    let registry = read(&sealed).expect("read").expect("registry");
    assert!(registry.plugins.is_empty());
    assert_eq!(
        registry
            .findings
            .iter()
            .map(|f| f.location.as_str())
            .collect::<Vec<_>>(),
        [".claude-plugin/marketplace.json: heygen"]
    );
}

#[cfg(unix)]
#[test]
fn declared_skills_keep_the_sealed_reader_for_links() {
    use std::os::unix::fs::symlink;
    for linked in ["directory", "marker", "content"] {
        let (_tmp, sealed) =
            declared_fixture("./", Some(serde_json::json!(["linked", "heygen-avatar"])));
        let root = sealed.root();
        match linked {
            "directory" => symlink(root.join("heygen-video"), root.join("linked")).expect("link"),
            "marker" => {
                std::fs::create_dir(root.join("linked")).expect("mkdir");
                symlink(
                    root.join("heygen-video/SKILL.md"),
                    root.join("linked/SKILL.md"),
                )
                .expect("link");
            }
            "content" => {
                write(
                    root,
                    "linked/SKILL.md",
                    "---\nname: linked\ndescription: media\n---\n",
                );
                symlink(
                    root.join("heygen-video/SKILL.md"),
                    root.join("linked/data.md"),
                )
                .expect("link");
            }
            _ => unreachable!(),
        }
        let registry = read(&sealed).expect("read").expect("registry");
        let path = find(&sealed, &registry, ItemKind::Skill, "heygen/linked");
        if linked == "content" {
            assert!(matches!(
                sealed.collect_skill_tree(&path.expect("skill")),
                Err(crate::error::CoreError::SourceEscape { .. })
            ));
        } else {
            assert!(path.is_none());
            let index = crate::source::index::index(&sealed, "heygen").expect("index");
            assert_eq!(
                index
                    .packages
                    .iter()
                    .map(|item| item.name.as_str())
                    .collect::<Vec<_>>(),
                ["heygen/heygen-avatar"]
            );
            assert!(
                registry
                    .findings
                    .iter()
                    .any(|f| f.location.ends_with("skills[linked]"))
            );
        }
    }
}
