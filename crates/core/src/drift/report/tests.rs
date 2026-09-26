use std::path::Path;

use super::*;
use crate::drift::snapshot::{PackageSnapshot, SNAPSHOT_SCHEMA, ScopeSnapshot};
use crate::drift::stamps;
use crate::env::FakeOs;
use crate::model::Scope;

pub(super) fn env_in(dir: &Path) -> Env {
    Env::fake(dir, FakeOs::Linux)
}

/// The scope bound to the one spelling the report prints, which
/// `check` reaches through `Scope::canonical`: on Windows a raw
/// `canonicalize` answers in the verbatim `\\?\` form, and a path
/// built from it never matches a line.
pub(super) fn project_scope(dir: &Path) -> Scope {
    let root = dir.join("proj");
    std::fs::create_dir_all(&root).unwrap();
    Scope::Project {
        root: crate::paths::canonical(&root).unwrap(),
    }
}

pub(super) fn write_manifest(env: &Env, scope: &Scope, manifest: &crate::manifest::Manifest) {
    crate::manifest::save(&crate::manifest::manifest_path(env, scope), manifest).unwrap();
}

pub(super) fn manifest_with_remote() -> crate::manifest::Manifest {
    let mut manifest = crate::manifest::Manifest {
        schema: crate::manifest::MANIFEST_SCHEMA,
        ..Default::default()
    };
    manifest.sources.insert(
        "cat".into(),
        crate::manifest::SourceDecl {
            repo: Some("owner/repo".into()),
            path: None,
            rev: None,
            enabled: true,
        },
    );
    manifest
}

pub(super) fn package(name: &str) -> PackageSnapshot {
    PackageSnapshot {
        kind: crate::model::ItemKind::Skill,
        name: name.into(),
        source: "cat".into(),
        repo: "owner/repo".into(),
        refs_state: Some("same-refs".into()),
        update_available: false,
        removed_upstream: false,
        held: false,
        ignored: false,
        edited: false,
        mixed: false,
        forked: false,
    }
}

pub(super) fn snapshot_with(env: &Env, scope: &Scope, packages: Vec<PackageSnapshot>) {
    snapshot_aged(env, scope, packages, crate::clock::unix_now());
}

pub(super) fn snapshot_aged(
    env: &Env,
    scope: &Scope,
    packages: Vec<PackageSnapshot>,
    taken_at: u64,
) {
    if let Some(package) = packages.iter().find(|package| package.refs_state.is_some()) {
        record_refs(env, &package.repo, package.refs_state.as_deref());
    }
    crate::drift::snapshot::store(
        env,
        scope,
        &ScopeSnapshot {
            schema: SNAPSHOT_SCHEMA,
            taken_at,
            scope: scope.canonical().label(),
            packages,
            unreadable: Vec::new(),
        },
    )
    .unwrap();
}

pub(super) fn record_refs(env: &Env, repo: &str, refs: Option<&str>) {
    let key = crate::remote::cache_key(env, repo);
    stamps::record_success(env, &key, refs.map(str::to_owned), crate::clock::unix_now()).unwrap();
}

#[test]
fn a_clean_scope_is_silent_and_exit_zero() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    snapshot_with(&env, &scope, vec![package("gh")]);

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Clean);
    assert_eq!(report.status.exit_code(), 0);
    assert_eq!(render_plain(&report), "");
}

/// A stale session hook names the supported reinstall command and a safe
/// backup command before the reinstall can replace local changes.
#[test]
fn an_old_drift_hook_names_reinstall_and_backup_commands() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    let mut manifest = manifest_with_remote();
    manifest.hooks.insert(
        crate::drift::hook::HOOK_NAME.to_owned(),
        crate::manifest::ItemDecl::from_source(crate::manifest::LOCAL_SOURCE_NAME),
    );
    write_manifest(&env, &scope, &manifest);
    let script = crate::drift::hook::script_path(&env, &scope);
    std::fs::create_dir_all(script.parent().unwrap()).unwrap();
    std::fs::write(&script, "old hook\n").unwrap();

    let report = check(&env, std::slice::from_ref(&scope));
    let stale = report
        .sections
        .iter()
        .find(|section| section.title == "stale")
        .and_then(|section| section.lines.first())
        .unwrap();
    assert_eq!(stale.remedy, Some(Remedy::DriftHook { global: false }));
    // The backup is a command, so a rendering that wraps never breaks it.
    let backup = format!(
        "cp -i {} {}",
        crate::names::quoted(&script.display().to_string()),
        crate::names::quoted(&format!("{}.backup", script.display()))
    );
    assert!(
        stale.text.spans().contains(&Span::Command(&backup)),
        "{:?}",
        stale.text.spans()
    );
    let text = item_lines(&report);
    assert!(
        text.contains(&format!(
            "backup first if needed: cp -i {} {}",
            crate::names::quoted(&script.display().to_string()),
            crate::names::quoted(&format!("{}.backup", script.display()))
        )),
        "{text}"
    );
    assert!(
        text.contains("fix: kendex drift-hook --yes --scope project"),
        "{text}"
    );
}

#[test]
fn held_only_and_ignored_only_drift_stays_silent() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    let held = PackageSnapshot {
        update_available: true,
        held: true,
        ..package("held-one")
    };
    let ignored = PackageSnapshot {
        update_available: true,
        removed_upstream: false,
        ignored: true,
        ..package("muted-one")
    };
    // Even an edited or removed-upstream package stays quiet while held:
    // a hold is a decision already made.
    let held_edited = PackageSnapshot {
        edited: true,
        held: true,
        ..package("held-two")
    };
    snapshot_with(&env, &scope, vec![held, ignored, held_edited]);
    record_refs(&env, "owner/repo", Some("new-refs"));

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Clean, "{report:?}");
    assert_eq!(render_plain(&report), "");
}

/// Every section as its title and lines, each line as its class and
/// typed remedy. The line's sentence is a diagnostic whose wording is
/// authoring guidance, not a pin; what it must carry is the package
/// name, asserted apart.
type Sectioned<'a> = Vec<(&'a str, Vec<(Class, Option<&'a Remedy>)>)>;

fn sections(report: &CheckReport) -> Sectioned<'_> {
    report
        .sections
        .iter()
        .map(|section| {
            (
                section.title.as_str(),
                section
                    .lines
                    .iter()
                    .map(|line| (line.class, line.remedy.as_ref()))
                    .collect(),
            )
        })
        .collect()
}

/// One package per classification, each landing in its own section with
/// its own typed remedy, drift sections in their fixed order, every line
/// naming its package.
#[test]
fn each_classification_lands_in_its_section_with_its_remedy() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    snapshot_with(
        &env,
        &scope,
        vec![
            PackageSnapshot {
                update_available: true,
                ..package("stale-one")
            },
            PackageSnapshot {
                edited: true,
                ..package("edited-one")
            },
            PackageSnapshot {
                removed_upstream: true,
                ..package("gone-one")
            },
            PackageSnapshot {
                mixed: true,
                ..package("mixed-one")
            },
        ],
    );

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Drift);
    assert_eq!(report.status.exit_code(), 1);
    let refresh = Remedy::Refresh { global: false };
    let fork = Remedy::Fork {
        kind: ItemKind::Skill,
        name: "edited-one".to_owned(),
        global: false,
    };
    let remove = Remedy::Remove {
        name: "gone-one".to_owned(),
        global: false,
    };
    assert_eq!(
        sections(&report),
        [
            ("stale", vec![(Class::Drift, Some(&refresh))]),
            ("edited by hand", vec![(Class::Drift, Some(&fork))]),
            (
                "gone from their source",
                vec![(Class::Drift, Some(&remove))]
            ),
            ("mixed installs", vec![(Class::Drift, Some(&refresh))]),
        ]
    );
    let lines = report.sections.iter().flat_map(|section| &section.lines);
    for (line, name) in lines.zip(["stale-one", "edited-one", "gone-one", "mixed-one"]) {
        assert!(line.text.contains(&format!("'{name}'")), "{}", line.text);
    }
    // Drift before suggestions: the stale section renders before the age
    // line.
    let text = render_plain(&report);
    let stale_at = text.find("stale:").unwrap();
    let age_at = text.find("(package evaluation:").unwrap();
    assert!(stale_at < age_at, "{text}");
}

#[test]
fn edited_outranks_stale_for_one_package() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    snapshot_with(
        &env,
        &scope,
        vec![PackageSnapshot {
            update_available: true,
            edited: true,
            ..package("both")
        }],
    );

    let report = check(&env, std::slice::from_ref(&scope));
    let titles: Vec<&str> = report
        .sections
        .iter()
        .map(|section| section.title.as_str())
        .collect();
    assert_eq!(titles, ["edited by hand"], "one package, one line");
    assert_eq!(report.sections[0].lines.len(), 1);
}

#[test]
fn a_mirror_that_moved_since_evaluation_reads_as_unevaluated() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = Scope::Global;
    write_manifest(&env, &scope, &manifest_with_remote());
    snapshot_with(
        &env,
        &scope,
        ["moved", "also-moved"]
            .map(|name| PackageSnapshot {
                update_available: name == "moved",
                refs_state: Some("old-refs".into()),
                ..package(name)
            })
            .to_vec(),
    );
    record_refs(&env, "owner/repo", Some("new-refs"));

    let report = check(&env, std::slice::from_ref(&scope));
    // The honest "maybe": never a guessed verdict, and never a failure to
    // check — the check ran and this is its answer.
    assert_eq!(report.status, CheckStatus::Drift);
    assert_eq!(report.status.exit_code(), 1);
    assert_eq!(
        render_plain(&report),
        "source comparison needed:\n  skill 'moved': source changed since evaluation; not yet re-evaluated — fix: kendex refresh --global\n  skill 'also-moved': source changed since evaluation; not yet re-evaluated — fix: kendex refresh --global\n(package evaluation: moments ago)\nNext: kendex check --global to list global packages; kendex refresh --global --yes to refresh them.\n"
    );
}

#[test]
fn an_unreadable_snapshot_is_could_not_check_not_unevaluated() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    // A directory where the file goes: exists, and no read succeeds.
    std::fs::create_dir_all(crate::drift::snapshot::snapshot_path(&env, &scope)).unwrap();

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Unknown);
    assert_eq!(report.status.exit_code(), 2);
    let text = render_plain(&report);
    assert!(text.contains("could not check:"), "{text}");
    assert!(text.contains("drift snapshot unreadable:"), "{text}");
    assert!(!text.contains("source comparison needed"), "{text}");
}

#[test]
fn could_not_check_outranks_unevaluated() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    std::fs::write(crate::lock::lock_path(&env, &scope), "{definitely not json").unwrap();

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Unknown);
    assert_eq!(report.status.exit_code(), 2);
    let text = render_plain(&report);
    assert!(text.contains("source comparison needed:"), "{text}");
    assert!(text.contains("could not check:"), "{text}");
}

#[test]
fn a_scope_with_remotes_and_no_snapshot_is_unevaluated() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Drift);
    assert_eq!(report.status.exit_code(), 1);
    assert_eq!(
        render_plain(&report),
        "source comparison needed:\n  packages have not been compared with their sources — fix: kendex updates\n"
    );
}

#[test]
fn snapshot_age_is_rendered() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_manifest(&env, &scope, &manifest_with_remote());
    snapshot_aged(
        &env,
        &scope,
        vec![PackageSnapshot {
            update_available: true,
            ..package("stale-one")
        }],
        crate::clock::unix_now() - 3 * 3600,
    );

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.snapshot_age_secs.map(|age| age / 3600), Some(3));
    let text = render_plain(&report);
    assert!(text.contains("(package evaluation: 3h ago)"));
    assert!(text.ends_with(
        "Next: kendex refresh --scope project --yes in this checkout to refresh project packages.\n"
    ));
}

#[test]
fn missing_skill_reference_stays_a_failure() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    let mut manifest = manifest_with_remote();
    manifest
        .agent_skills
        .insert("orch".into(), vec!["ghost".into()]);
    write_manifest(&env, &scope, &manifest);
    snapshot_with(&env, &scope, vec![]);

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Drift);
    let text = render_plain(&report);
    assert!(
        text.contains("references skill 'ghost'") && text.contains("kendex add --skill ghost"),
        "{text}"
    );
}

#[test]
fn corrupt_manifest_and_lock_are_could_not_check() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    let manifest_path = crate::manifest::manifest_path(&env, &scope);
    std::fs::create_dir_all(manifest_path.parent().unwrap()).unwrap();
    std::fs::write(&manifest_path, "not = [valid").unwrap();
    std::fs::write(crate::lock::lock_path(&env, &scope), "{definitely not json").unwrap();

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Unknown);
    let text = render_plain(&report);
    assert!(text.contains("could not check:"), "{text}");
    assert!(text.contains("manifest:"), "{text}");
    assert!(text.contains("lock:"), "{text}");
}

fn selection_manifest() -> crate::manifest::Manifest {
    let mut manifest = crate::manifest::Manifest {
        schema: crate::manifest::MANIFEST_SCHEMA,
        ..Default::default()
    };
    manifest.install.harnesses = vec![crate::model::HarnessId::Claude];
    manifest.sources.insert(
        "cat".into(),
        crate::manifest::SourceDecl {
            repo: None,
            path: Some("catalog".into()),
            rev: None,
            enabled: true,
        },
    );
    manifest
}

fn recorded_entry(
    kind: ItemKind,
    name: &str,
    reasons: std::collections::BTreeSet<crate::lock::Reason>,
) -> crate::lock::LockEntry {
    crate::lock::LockEntry {
        name: name.into(),
        kind,
        harness: crate::model::HarnessId::Claude,
        source: "cat".into(),
        source_repo: "local".into(),
        machine: None,
        source_hash: "source".into(),
        source_commit: None,
        rendered_hash: None,
        enabled: true,
        upstream_skills: None,
        emitted: None,
        registration: None,
        reasons,
    }
}

fn plant_recorded_skill_files(scope: &Scope, entries: &mut [crate::lock::LockEntry]) {
    let Scope::Project { root } = scope else {
        unreachable!("selection tests use project scopes");
    };
    for entry in entries
        .iter_mut()
        .filter(|entry| entry.kind == ItemKind::Skill)
    {
        let path = root.join(".claude/skills").join(&entry.name);
        std::fs::create_dir_all(&path).unwrap();
        std::fs::write(path.join("SKILL.md"), "Recorded.\n").unwrap();
        entry.machine = Some(crate::lock::MachineRecord {
            method: crate::manifest::Method::Copy,
            installed_at: crate::clock::timestamp(),
        });
        entry.emitted = Some(crate::lock::EmittedArtifact {
            kind: ItemKind::Skill,
            name: entry.name.clone(),
            paths: vec![path],
        });
    }
}

fn write_record(env: &Env, scope: &Scope, entries: Vec<crate::lock::LockEntry>) {
    let mut lock = crate::lock::Lock {
        version: crate::lock::LOCK_VERSION,
        ..Default::default()
    };
    for entry in entries {
        let key = crate::lock::entry_key(entry.kind, &entry.name, entry.harness);
        lock.entries.insert(key, entry);
    }
    crate::lock::save(&crate::lock::lock_path(env, scope), &lock).unwrap();
}

fn cleanup_names(report: &CheckReport) -> Vec<&str> {
    report
        .sections
        .iter()
        .find(|section| section.title == "record cleanup needed")
        .into_iter()
        .flat_map(|section| section.lines.iter().map(|line| line.text.as_str()))
        .collect()
}

#[derive(Clone, Copy)]
enum SelectionCase {
    Plugin,
    CustomHook,
    BundleMember,
    RequiredDependency,
}

impl SelectionCase {
    fn label(self) -> &'static str {
        match self {
            Self::Plugin => "plugin",
            Self::CustomHook => "custom hook",
            Self::BundleMember => "bundle member",
            Self::RequiredDependency => "required dependency",
        }
    }

    fn target(self) -> (ItemKind, &'static str) {
        match self {
            Self::Plugin => (ItemKind::Plugin, "plugin@market"),
            Self::CustomHook => (ItemKind::Hook, "custom-hook"),
            Self::BundleMember => (ItemKind::Skill, "bundle-member"),
            Self::RequiredDependency => (ItemKind::Skill, "dependency"),
        }
    }

    fn fixture(self) -> (crate::manifest::Manifest, Vec<crate::lock::LockEntry>) {
        use crate::lock::{BundleRef, InstallRef, Reason};

        let mut manifest = selection_manifest();
        let (kind, name) = self.target();
        let reasons = match self {
            Self::Plugin => {
                manifest.plugins.insert(
                    name.into(),
                    crate::manifest::PluginDecl {
                        enabled: true,
                        harness: crate::model::HarnessId::Claude,
                    },
                );
                std::collections::BTreeSet::from([Reason::Requested])
            }
            Self::CustomHook => {
                manifest.custom_hooks.push(crate::manifest::CustomHook {
                    name: Some(name.into()),
                    event: "SessionStart".into(),
                    matcher: None,
                    command: "true".into(),
                    description: None,
                    timeout: None,
                    harnesses: Some(vec!["claude".into()]),
                    enabled: true,
                    agents: crate::manifest::HookAgents::One("all".into()),
                });
                std::collections::BTreeSet::from([Reason::Requested])
            }
            Self::BundleMember => {
                manifest.bundles.insert(
                    "starter".into(),
                    crate::manifest::ItemDecl::from_source("cat"),
                );
                std::collections::BTreeSet::from([Reason::MemberOf {
                    bundle: BundleRef {
                        source: "cat".into(),
                        name: "starter".into(),
                    },
                }])
            }
            Self::RequiredDependency => {
                manifest.skills.insert(
                    "parent".into(),
                    crate::manifest::ItemDecl::from_source("cat"),
                );
                std::collections::BTreeSet::from([Reason::RequiredBy {
                    by: InstallRef {
                        source: "cat".into(),
                        kind: ItemKind::Skill,
                        name: "parent".into(),
                        harness: crate::model::HarnessId::Claude,
                    },
                }])
            }
        };
        let mut entries = vec![recorded_entry(kind, name, reasons)];
        if matches!(self, Self::RequiredDependency) {
            entries.push(recorded_entry(
                ItemKind::Skill,
                "parent",
                std::collections::BTreeSet::from([Reason::Requested]),
            ));
        }
        (manifest, entries)
    }

    fn remove_owner(self, manifest: &mut crate::manifest::Manifest) {
        match self {
            Self::Plugin => manifest.plugins.clear(),
            Self::CustomHook => manifest.custom_hooks.clear(),
            Self::BundleMember => manifest.bundles.clear(),
            Self::RequiredDependency => manifest.skills.clear(),
        }
    }
}

#[test]
fn record_selection_tracks_each_manifest_owner() {
    for case in [
        SelectionCase::Plugin,
        SelectionCase::CustomHook,
        SelectionCase::BundleMember,
        SelectionCase::RequiredDependency,
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let scope = project_scope(tmp.path());
        let (mut manifest, mut entries) = case.fixture();
        plant_recorded_skill_files(&scope, &mut entries);
        write_manifest(&env, &scope, &manifest);
        write_record(&env, &scope, entries);

        let report = check(&env, std::slice::from_ref(&scope));
        let (kind, name) = case.target();
        assert!(
            !cleanup_names(&report)
                .iter()
                .any(|line| line.contains(name)),
            "selected {} was called stale: {report:?}",
            case.label()
        );

        case.remove_owner(&mut manifest);
        write_manifest(&env, &scope, &manifest);
        let report = check(&env, std::slice::from_ref(&scope));
        assert!(
            cleanup_names(&report)
                .iter()
                .any(|line| line.contains(&format!("{} '{name}'", kind.name()))),
            "unselected {} was not called stale: {report:?}",
            case.label()
        );
    }
}

#[test]
fn dependency_selection_keeps_the_owners_source_identity() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    let (mut manifest, mut entries) = SelectionCase::RequiredDependency.fixture();
    plant_recorded_skill_files(&scope, &mut entries);
    manifest.sources.insert(
        "other".into(),
        crate::manifest::SourceDecl {
            repo: None,
            path: Some("other-catalog".into()),
            rev: None,
            enabled: true,
        },
    );
    manifest.skills.get_mut("parent").unwrap().source = "other".into();
    write_manifest(&env, &scope, &manifest);
    write_record(&env, &scope, entries);

    let report = check(&env, std::slice::from_ref(&scope));
    assert!(
        cleanup_names(&report)
            .iter()
            .any(|line| line.contains("skill 'dependency'")),
        "a dependency owned by the old source stayed selected: {report:?}"
    );
}

#[test]
fn a_custom_hook_moved_into_agent_files_leaves_its_registry_record_for_cleanup() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    let (mut manifest, entries) = SelectionCase::CustomHook.fixture();
    write_manifest(&env, &scope, &manifest);
    write_record(&env, &scope, entries);

    let registered = check(&env, std::slice::from_ref(&scope));
    assert!(
        !cleanup_names(&registered)
            .iter()
            .any(|line| line.contains("custom-hook")),
        "the registered hook is still selected: {registered:?}"
    );

    manifest.custom_hooks[0].agents = crate::manifest::HookAgents::One("reviewer".into());
    write_manifest(&env, &scope, &manifest);
    let in_agent_file = check(&env, std::slice::from_ref(&scope));
    assert!(
        cleanup_names(&in_agent_file)
            .iter()
            .any(|line| line.contains("hook 'custom-hook'")),
        "the old registry record was still selected: {in_agent_file:?}"
    );
}

#[test]
fn suppression_excludes_derived_records_but_not_direct_declarations() {
    for case in [
        SelectionCase::BundleMember,
        SelectionCase::RequiredDependency,
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let env = env_in(tmp.path());
        let scope = project_scope(tmp.path());
        let (mut manifest, mut entries) = case.fixture();
        plant_recorded_skill_files(&scope, &mut entries);
        let (kind, name) = case.target();
        manifest.suppressed.insert(kind, vec![name.into()]);
        write_manifest(&env, &scope, &manifest);
        write_record(&env, &scope, entries);

        let report = check(&env, std::slice::from_ref(&scope));
        assert!(
            cleanup_names(&report)
                .iter()
                .any(|line| line.contains(name)),
            "suppressed {} stayed selected: {report:?}",
            case.label()
        );

        manifest
            .declared_mut(kind)
            .insert(name.into(), crate::manifest::ItemDecl::from_source("cat"));
        write_manifest(&env, &scope, &manifest);
        let report = check(&env, std::slice::from_ref(&scope));
        assert!(
            !cleanup_names(&report)
                .iter()
                .any(|line| line.contains(name)),
            "direct {} did not override suppression: {report:?}",
            case.label()
        );
    }
}

#[test]
fn unreadable_manifest_does_not_guess_that_recorded_packages_need_cleanup() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    write_record(
        &env,
        &scope,
        vec![recorded_entry(
            ItemKind::Skill,
            "recorded",
            std::collections::BTreeSet::from([crate::lock::Reason::Requested]),
        )],
    );

    let absent = check(&env, std::slice::from_ref(&scope));
    assert!(
        cleanup_names(&absent)
            .iter()
            .any(|line| line.contains("recorded")),
        "an absent manifest is a known empty selection: {absent:?}"
    );

    std::fs::write(crate::manifest::manifest_path(&env, &scope), "not = [valid").unwrap();
    let unreadable = check(&env, std::slice::from_ref(&scope));
    let text = render_plain(&unreadable);
    assert!(text.contains("manifest:"), "{text}");
    assert!(!text.contains("record cleanup needed"), "{text}");
    assert!(!text.contains("kendex apply"), "{text}");
}

/// A declared Pi package with a second copy under the scope's
/// `extensions/` is one line in its own section, opening on the stable
/// key and naming both copies; with only the managed copy the section is
/// absent and the check is clean.
#[test]
fn a_second_copy_under_extensions_is_reported_and_the_managed_copy_alone_is_not() {
    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let scope = project_scope(tmp.path());
    let Scope::Project { root } = &scope else {
        unreachable!("project_scope builds a project scope");
    };
    let mut manifest = crate::manifest::Manifest {
        schema: crate::manifest::MANIFEST_SCHEMA,
        ..Default::default()
    };
    manifest.sources.insert(
        "cat".into(),
        crate::manifest::SourceDecl {
            repo: None,
            path: Some("catalog".into()),
            rev: None,
            enabled: true,
        },
    );
    manifest.pi_extensions.insert(
        "pi-widgets".into(),
        crate::manifest::ItemDecl::from_source("cat"),
    );
    write_manifest(&env, &scope, &manifest);
    let package = |version: &str| {
        format!(
            r#"{{"name":"pi-widgets","version":"{version}","pi":{{"extensions":["./widgets.js"]}}}}"#
        )
    };
    // One component per join: the report prints the platform separator,
    // and a slash inside a joined string stays a slash on Windows.
    let managed = root.join(".pi").join("packages").join("pi-widgets");
    std::fs::create_dir_all(&managed).unwrap();
    std::fs::write(managed.join("package.json"), package("2.0.0")).unwrap();
    // The managed copy has no completed install record here, which is its
    // own line in another section; this test reads only the shadow's.
    let shadowed = |report: &CheckReport| {
        report
            .sections
            .iter()
            .find(|section| section.title == "loaded twice by pi")
            .map(|section| section.lines.clone())
    };

    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(shadowed(&report), None, "{report:?}");

    // The copy's manifest is foreign text: a control character in its
    // version reaches the line as the report's scrub leaves it, a space
    // trimmed off the fragment, never as an escape or the byte itself.
    let shadow = root.join(".pi").join("extensions").join("pi-widgets");
    std::fs::create_dir_all(&shadow).unwrap();
    std::fs::write(shadow.join("package.json"), package("1.0.0\\u0007")).unwrap();
    let report = check(&env, std::slice::from_ref(&scope));
    assert_eq!(report.status, CheckStatus::Drift);
    let lines = shadowed(&report).unwrap_or_default();
    assert_eq!(lines.len(), 1, "{report:?}");
    let line = &lines[0];
    assert_eq!(line.class, Class::Drift);
    assert_eq!(
        line.remedy,
        Some(Remedy::MoveAside {
            from: shadow.clone(),
            to: root.join(".pi"),
            windows: false,
        })
    );
    assert!(
        line.text.starts_with("pi-shadow-package=pi-widgets: "),
        "{}",
        line.text
    );
    assert!(
        line.text
            .contains(&format!("{} (version 2.0.0)", managed.display())),
        "{}",
        line.text
    );
    assert!(
        line.text
            .contains(&format!("{} (version 1.0.0)", shadow.display())),
        "{}",
        line.text
    );
    assert!(
        line.text.contains(&format!(
            "move pi-widgets out of {}",
            root.join(".pi").join("extensions").display()
        )),
        "{}",
        line.text
    );
    let text = item_lines(&report);
    assert!(
        text.contains(&format!(
            "fix: mv -i {} {}",
            crate::names::quoted(&shadow.display().to_string()),
            crate::names::quoted(&root.join(".pi").display().to_string())
        )),
        "{text}"
    );
}

#[cfg(unix)]
#[test]
fn a_non_utf8_shadow_path_keeps_the_row_and_omits_the_move_command() {
    use std::os::unix::ffi::OsStringExt;

    let tmp = tempfile::tempdir().unwrap();
    let env = env_in(tmp.path());
    let root = tmp.path().join(".pi");
    let extensions = root.join("extensions");
    let shadow = extensions.join(std::ffi::OsString::from_vec(b"pi-widgets-\xff".to_vec()));
    let scan = crate::pi_ext::ShadowScan {
        found: vec![crate::pi_ext::ShadowPackage {
            name: "pi-widgets".into(),
            managed: root.join("packages/pi-widgets"),
            managed_version: Some("2.0.0".into()),
            extensions,
            shadow: shadow.clone(),
            shadow_version: Some("1.0.0".into()),
        }],
        errors: Vec::new(),
    };
    let mut sections = Sections::new();
    scope::shadow_lines(&env, "", scan, &mut sections);
    let report = sections.into_report(None, None);
    let line = &report.sections[0].lines[0];

    assert!(line.text.starts_with("pi-shadow-package=pi-widgets: "));
    assert_eq!(line.remedy, None, "the lossy move command was retained");
    let json = serde_json::to_string(&report).expect("the full report remains serializable");
    assert!(json.contains("pi-shadow-package=pi-widgets"), "{json}");
    assert!(!json.contains("move-aside"), "{json}");
}

/// A package declared at both scopes with one copy under the global
/// root, which both scopes read: the report names the copy once, under
/// the scope checked first.
#[test]
fn a_copy_of_a_package_declared_at_both_scopes_is_named_once() {
    let tmp = tempfile::tempdir().unwrap();
    let scope = project_scope(tmp.path());
    let Scope::Project { root } = &scope else {
        unreachable!("project_scope builds a project scope");
    };
    // The global scope pairs with the project the check runs in, which
    // is this fixture's, never the test process's own directory.
    let env = env_in(tmp.path()).with_cwd(root);
    let mut manifest = crate::manifest::Manifest {
        schema: crate::manifest::MANIFEST_SCHEMA,
        ..Default::default()
    };
    manifest.sources.insert(
        "cat".into(),
        crate::manifest::SourceDecl {
            repo: None,
            path: Some("catalog".into()),
            rev: None,
            enabled: true,
        },
    );
    manifest.pi_extensions.insert(
        "pi-widgets".into(),
        crate::manifest::ItemDecl::from_source("cat"),
    );
    write_manifest(&env, &scope, &manifest);
    write_manifest(&env, &Scope::Global, &manifest);
    let shadow = crate::pi_ext::scope_root(&env, &Scope::Global)
        .unwrap()
        .join("extensions/pi-widgets");
    std::fs::create_dir_all(&shadow).unwrap();
    std::fs::write(
        shadow.join("package.json"),
        r#"{"name":"pi-widgets","version":"1.0.0","pi":{"extensions":["./widgets.js"]}}"#,
    )
    .unwrap();

    let report = check(&env, &[scope.clone(), Scope::Global]);

    let lines: Vec<&Line> = report
        .sections
        .iter()
        .filter(|section| section.title == "loaded twice by pi")
        .flat_map(|section| section.lines.iter())
        .collect();
    assert_eq!(lines.len(), 1, "{report:?}");
    assert!(
        lines[0].text.starts_with(&format!(
            "{}: pi-shadow-package=pi-widgets: ",
            scope_word(&scope)
        )),
        "{}",
        lines[0].text
    );
}

/// Every item line of the complete report, as the explicit check's plain
/// rendering shows each one.
fn item_lines(report: &CheckReport) -> String {
    page(report)
        .sections
        .iter()
        .flat_map(|section| &section.items)
        .map(PageItem::line)
        .collect::<Vec<_>>()
        .join("\n")
}
