//! Catalog kind and declaration context survive the saved-template boundary.
use std::fs;

use super::super::*;
use super::{home, skill};
use crate::model::{HarnessId, Scope};
use crate::source::browse::Catalog;

#[allow(clippy::unwrap_used)]
fn selected(env: &Env, scope: &Scope, alias: &str, name: &str) -> Member {
    Member {
        kind: MemberKind::Skill,
        name: name.to_owned(),
        enabled: true,
        source: catalog_source(
            env,
            &Catalog::Subscription {
                scope: scope.clone(),
                source: alias.to_owned(),
            },
            None,
        )
        .unwrap(),
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn folder_catalogs_survive_save_admission_group_install_and_targeted_removal() {
    let (_tmp, env) = home();
    let manifest = env.global_manifest_file();
    let home = manifest.parent().unwrap();
    let first = home.join("catalog");
    let second = home.join("catalog.git");
    skill(&first.join("skills"), "first", "first catalog");
    skill(&second.join("skills"), "second", "second catalog");
    fs::write(
        &manifest,
        format!(
            "schema = 8\n[sources.first]\n{}\n[sources.second]\n{}\n",
            crate::test_util::source_path(&first),
            crate::test_util::source_path(&second)
        ),
    )
    .unwrap();
    let a = selected(&env, &Scope::Global, "first", "first");
    let b = selected(&env, &Scope::Global, "second", "second");
    // Same package name probes admission independently of install namespace refusal.
    let mut same_name = b.clone();
    same_name.name = a.name.clone();
    let admitted = create_from_selection(&env, "Admission", vec![a.clone(), same_name]).unwrap();
    assert_eq!(admitted.members.len(), 2);
    let template = create_from_selection(&env, "Folders", vec![a.clone(), b.clone()]).unwrap();
    let loaded = get(&env, "Folders").unwrap();
    assert_eq!(loaded.members, template.members);
    let resolution = resolve(&env, &loaded).unwrap();
    assert!(resolution.missing.is_empty());
    assert_eq!(resolution.groups.len(), 2);
    assert_ne!(
        resolution.groups[0].catalog.as_ref().unwrap().identity(),
        resolution.groups[1].catalog.as_ref().unwrap().identity()
    );
    let project = home.join("destination");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let result = install(
        &env,
        &loaded,
        &Scope::Project {
            root: project.clone(),
        },
        Some(vec![HarnessId::Claude]),
        None,
    )
    .unwrap();
    assert_eq!(result.stopped, None);
    assert_eq!(result.declared.len(), 2);
    let text = fs::read_to_string(project.join(".claude/skills/second/SKILL.md")).unwrap();
    assert!(text.contains("second catalog"));
    let MemberSource::Catalog { catalog, .. } = &a.source else {
        panic!("typed selection")
    };
    let remaining = remove_members(
        &env,
        "Folders",
        &[MemberRef {
            kind: a.kind,
            name: a.name.clone(),
            which: MemberWhich::Catalog {
                catalog: catalog.clone(),
            },
        }],
    )
    .unwrap();
    assert_eq!(remaining.members, vec![b]);
}

#[test]
#[allow(clippy::unwrap_used)]
fn repository_records_match_only_repositories_in_their_declaring_scope() {
    let (_tmp, env) = home();
    let global = env.global_manifest_file();
    fs::create_dir_all(global.parent().unwrap()).unwrap();
    let project = global.parent().unwrap().join("project");
    fs::create_dir_all(&project).unwrap();
    let scope = Scope::Project { root: project };
    // The same spelling is a real folder declaration and a remote declaration.
    fs::write(
        &global,
        "schema = 8\n[sources.folder]\npath = 'owner/repo'\n",
    )
    .unwrap();
    fs::write(crate::manifest::manifest_path(&env, &scope), "schema = 8\n[sources.folder]\npath = 'owner/repo'\n[sources.remote]\nrepo = 'owner/repo'\n").unwrap();
    let member = selected(&env, &scope, "remote", "gh");
    let template = create_from_selection(&env, "Remote", vec![member]).unwrap();
    let resolution = resolve(&env, &template).unwrap();
    assert_eq!(resolution.groups.len(), 1);
    assert_eq!(resolution.groups[0].source.as_deref(), Some("remote"));
    assert_eq!(resolution.groups[0].scope.as_ref(), Some(&scope));
    assert!(matches!(
        resolution.groups[0].catalog,
        Some(TemplateCatalog::Repository { .. })
    ));
}

#[test]
#[allow(clippy::unwrap_used)]
fn literal_legacy_records_keep_unique_readings_and_preserve_ambiguous_strings() {
    let (_tmp, env) = home();
    let manifest = env.global_manifest_file();
    let base = manifest.parent().unwrap();
    let absolute = base.join("absolute");
    let relative = crate::source::path_root(&env, &Scope::Global, "folder/repo");
    let ambiguous = base.join("ambiguous");
    let other = base.join("ambiguous.git");
    for path in [&absolute, &relative, &ambiguous, &other] {
        skill(&path.join("skills"), "gh", "bytes");
    }
    fs::write(&manifest, format!("schema = 8\n[sources.remote]\nrepo = 'owner/repo'\n[sources.absolute]\n{}\n[sources.relative]\npath = 'folder/repo'\n[sources.ambiguous]\n{}\n[sources.other]\n{}\n", crate::test_util::source_path(&absolute), crate::test_util::source_path(&ambiguous), crate::test_util::source_path(&other))).unwrap();
    // These are the exact old record fields, not new typed members serialized as old.
    let text = format!("[[templates]]\nname = 'Legacy'\nid = 'legacy'\n{}", ["owner/repo".to_owned(), crate::paths::slashed(&absolute), crate::paths::slashed(&relative), "folder/repo".to_owned(), crate::paths::slashed(&ambiguous)].into_iter().enumerate().map(|(i, repo)| format!("[[templates.members]]\nkind = 'skill'\nname = 'item{i}'\n[templates.members.source]\nheld = 'marketplace'\nrepo = {repo:?}\n")).collect::<String>());
    fs::write(env.templates_file(), text).unwrap();
    let before = get(&env, "Legacy").unwrap();
    // Evaluate each member separately: equal package names are immaterial to legacy policy.
    for (i, member) in before.members.iter().enumerate() {
        let mut one = before.clone();
        one.members = vec![member.clone()];
        let resolution = resolve(&env, &one).unwrap();
        let expected_alias = [
            Some("remote"),
            Some("absolute"),
            Some("relative"),
            Some("relative"),
            None,
        ][i];
        assert_eq!(
            resolution.groups.len(),
            usize::from(expected_alias.is_some())
        );
        if let Some(alias) = expected_alias {
            assert_eq!(resolution.groups[0].source.as_deref(), Some(alias));
            assert_eq!(resolution.groups[0].scope.as_ref(), Some(&Scope::Global));
        } else {
            assert_eq!(
                resolution.missing[0].which,
                MemberWhich::Marketplace {
                    repo: crate::paths::slashed(&ambiguous)
                }
            );
        }
    }
    create_from_selection(
        &env,
        "Another",
        vec![selected(&env, &Scope::Global, "absolute", "gh")],
    )
    .unwrap();
    assert_eq!(get(&env, "Legacy").unwrap(), before);
    // The raw relative spelling can also name a repository. Neither wins.
    let mut declared = crate::manifest::load_current(&manifest).unwrap().unwrap();
    declared.sources.insert(
        "competing".to_owned(),
        crate::manifest::SourceDecl {
            repo: Some("folder/repo".to_owned()),
            path: None,
            rev: None,
            enabled: true,
        },
    );
    crate::manifest::save(&manifest, &declared).unwrap();
    let mut relative_only = before.clone();
    relative_only.members = vec![before.members[3].clone()];
    let unresolved = resolve(&env, &relative_only).unwrap();
    assert!(unresolved.groups.is_empty());
    assert_eq!(unresolved.missing.len(), 1);
    create_from_selection(
        &env,
        "Mutation",
        vec![selected(&env, &Scope::Global, "absolute", "gh")],
    )
    .unwrap();
    assert_eq!(get(&env, "Legacy").unwrap(), before);
}

#[cfg(windows)]
#[test]
#[allow(clippy::unwrap_used)]
fn native_backslash_declarations_match_slashed_saved_roots() {
    let (_tmp, env) = home();
    let manifest = env.global_manifest_file();
    let root = manifest.parent().unwrap().join("catalog.git");
    skill(&root.join("skills"), "gh", "bytes");
    fs::write(
        &manifest,
        format!(
            "schema = 8\n[sources.folder]\npath = '{}'\n",
            root.display()
        ),
    )
    .unwrap();
    let typed = selected(&env, &Scope::Global, "folder", "gh");
    let mut template = create_from_selection(&env, "Native", vec![typed]).unwrap();
    let MemberSource::Catalog {
        catalog: TemplateCatalog::Folder {
            root: saved_root, ..
        },
        ..
    } = &template.members[0].source
    else {
        panic!("saved folder catalog")
    };
    assert_eq!(saved_root, &crate::paths::slashed(&root));
    let typed_resolution = resolve(&env, &template).unwrap();
    assert!(typed_resolution.missing.is_empty());
    assert_eq!(typed_resolution.groups.len(), 1);
    assert_eq!(typed_resolution.groups[0].source.as_deref(), Some("folder"));
    assert_eq!(
        typed_resolution.groups[0].scope.as_ref(),
        Some(&Scope::Global)
    );
    template.members[0].source = MemberSource::Marketplace {
        repo: crate::paths::slashed(&root),
        rev: None,
    };
    let legacy_resolution = resolve(&env, &template).unwrap();
    assert!(legacy_resolution.missing.is_empty());
    assert_eq!(legacy_resolution.groups.len(), 1);
    assert_eq!(
        legacy_resolution.groups[0].source.as_deref(),
        Some("folder")
    );
    assert_eq!(
        legacy_resolution.groups[0].scope.as_ref(),
        Some(&Scope::Global)
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn catalog_wire_records_preserve_kind_root_and_origin() {
    for catalog in [
        r#"{"kind":"folder","root":"/catalog.git","origin":{"scope":"global"}}"#,
        r#"{"kind":"repository","repo":"owner/repo","origin":{"origin":"direct"}}"#,
    ] {
        let input = format!(
            r#"{{"kind":"skill","name":"gh","source":{{"held":"catalog","catalog":{catalog}}}}}"#
        );
        let member: Member = serde_json::from_str(&input).unwrap();
        let saved = serde_json::to_value(&member).unwrap();
        assert_eq!(
            saved["source"]["catalog"],
            serde_json::from_str::<serde_json::Value>(catalog).unwrap()
        );
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn mixed_format_rows_keep_their_original_removal_reference() {
    let (_tmp, env) = home();
    let manifest = env.global_manifest_file();
    let root = manifest.parent().unwrap().join("catalog");
    skill(&root.join("skills"), "first", "first");
    skill(&root.join("skills"), "second", "second");
    fs::write(
        &manifest,
        format!(
            "schema = 8\n[sources.folder]\n{}\n",
            crate::test_util::source_path(&root)
        ),
    )
    .unwrap();
    let typed = selected(&env, &Scope::Global, "folder", "first");
    create_from_selection(&env, "Mixed", vec![typed.clone()]).unwrap();
    let legacy = Member {
        kind: MemberKind::Skill,
        name: "second".to_owned(),
        enabled: true,
        source: MemberSource::Marketplace {
            repo: crate::paths::slashed(&root),
            rev: None,
        },
    };
    let mixed = add_members(&env, "Mixed", vec![legacy]).unwrap();
    let resolved = resolve(&env, &mixed).unwrap();
    assert!(resolved.missing.is_empty());
    assert_eq!(resolved.groups.len(), 1);
    let group = &resolved.groups[0];
    let first = group
        .items
        .iter()
        .find(|item| item.name == "first")
        .unwrap();
    let second = group
        .items
        .iter()
        .find(|item| item.name == "second")
        .unwrap();
    assert!(matches!(first.which, MemberWhich::Catalog { .. }));
    assert!(matches!(second.which, MemberWhich::Marketplace { .. }));
    let remaining = remove_members(
        &env,
        "Mixed",
        &[MemberRef {
            kind: MemberKind::Skill,
            name: second.name.clone(),
            which: second.which.clone(),
        }],
    )
    .unwrap();
    assert_eq!(remaining.members, vec![typed]);
}

#[test]
#[allow(clippy::unwrap_used)]
fn targeted_removal_reads_legacy_catalogs_before_mutating() {
    // (declarations, literal legacy source, other claimant, target legacy)
    for (declarations, unsubscribed, other, target_legacy) in [
        (1, None, None, false),
        (2, None, None, false),
        (0, Some("someone/else"), Some("someone/other"), true),
        (0, Some("./unsubscribed"), Some("./unsubscribed.git"), true),
        (0, Some("./unsubscribed"), Some("./unsubscribed.git"), false),
    ] {
        let (_tmp, env) = home();
        let manifest = env.global_manifest_file();
        let first = manifest.parent().unwrap().join("catalog");
        let second = manifest.parent().unwrap().join("catalog.git");
        skill(&first.join("skills"), "gh", "first");
        skill(&second.join("skills"), "gh", "second");
        let declared = if declarations > 0 {
            format!(
                "[sources.first]\n{}\n",
                crate::test_util::source_path(&first)
            )
        } else {
            String::new()
        };
        fs::write(&manifest, format!("schema = 8\n{declared}")).unwrap();
        // The pre-change CLI saved its source text verbatim without subscribing.
        let legacy = Member {
            kind: MemberKind::Skill,
            name: "gh".to_owned(),
            enabled: true,
            source: MemberSource::Marketplace {
                repo: unsubscribed.map_or_else(|| crate::paths::slashed(&first), str::to_owned),
                rev: None,
            },
        };
        let other_reference = other.map_or_else(|| crate::paths::slashed(&second), str::to_owned);
        let selected_reference = if target_legacy {
            unsubscribed.unwrap().to_owned()
        } else {
            other_reference.clone()
        };
        let typed = Member {
            source: source_choice(&env, &other_reference).unwrap(),
            ..legacy.clone()
        };
        create_from_selection(&env, "Mixed", vec![legacy.clone(), typed.clone()]).unwrap();
        if declarations == 2 {
            fs::write(
                &manifest,
                format!(
                    "schema = 8\n{declared}[sources.second]\n{}\n",
                    crate::test_util::source_path(&second)
                ),
            )
            .unwrap();
        }
        let MemberSource::Catalog { catalog, .. } =
            source_choice(&env, &selected_reference).unwrap()
        else {
            unreachable!()
        };
        let before = fs::read(env.templates_file()).unwrap();
        let result = remove_members(
            &env,
            "Mixed",
            &[MemberRef {
                kind: legacy.kind,
                name: legacy.name.clone(),
                which: MemberWhich::CatalogSelection {
                    catalog,
                    reference: selected_reference,
                },
            }],
        );
        if declarations == 2 {
            assert!(matches!(
                result,
                Err(CoreError::TemplateMemberUnavailable { .. })
            ));
            assert_eq!(fs::read(env.templates_file()).unwrap(), before);
        } else {
            let expected = if target_legacy { typed } else { legacy };
            assert_eq!(result.unwrap().members, vec![expected]);
        }
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn cross_format_admission_keeps_the_first_record_and_reference() {
    for (folder, ambiguous) in [(false, false), (true, false), (true, true)] {
        for add in [false, true] {
            let (_tmp, env) = home();
            let manifest = env.global_manifest_file();
            let root = manifest.parent().unwrap().join("catalog");
            skill(&root.join("skills"), "gh", "bytes");
            let declaration = if folder {
                crate::test_util::source_path(&root)
            } else {
                "repo = 'owner/repo'".to_owned()
            };
            let competitor = if ambiguous {
                format!(
                    "[sources.second]\n{}\n",
                    crate::test_util::source_path(&root.with_extension("git"))
                )
            } else {
                String::new()
            };
            fs::write(
                &manifest,
                format!("schema = 8\n[sources.first]\n{declaration}\n{competitor}"),
            )
            .unwrap();
            let legacy = Member {
                kind: MemberKind::Skill,
                name: "gh".to_owned(),
                enabled: false,
                source: MemberSource::Marketplace {
                    repo: if folder {
                        crate::paths::slashed(&root)
                    } else {
                        "owner/repo".to_owned()
                    },
                    rev: Some("saved".to_owned()),
                },
            };
            let typed = selected(&env, &Scope::Global, "first", "gh");
            let template = if add {
                create_from_selection(&env, "Dedup", vec![legacy.clone()]).unwrap();
                add_members(&env, "Dedup", vec![typed]).unwrap()
            } else {
                create_from_selection(&env, "Dedup", vec![legacy.clone(), typed]).unwrap()
            };
            assert_eq!(template.members[0], legacy);
            if ambiguous {
                assert_eq!(template.members.len(), 2);
                continue;
            }
            assert_eq!(template.members, vec![legacy.clone()]);
            let resolution = resolve(&env, &template).unwrap();
            assert_eq!(resolution.groups.len(), 1);
            // An unfetched repository may be unavailable, but admission must not contest it.
            assert_eq!(resolution.groups[0].source.as_deref(), Some("first"));
            let MemberSource::Marketplace { repo, .. } = legacy.source else {
                unreachable!()
            };
            assert!(
                remove_members(
                    &env,
                    "Dedup",
                    &[MemberRef {
                        kind: legacy.kind,
                        name: legacy.name,
                        which: MemberWhich::Marketplace { repo }
                    }]
                )
                .unwrap()
                .members
                .is_empty()
            );
        }
    }
}
