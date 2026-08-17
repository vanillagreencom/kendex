//! The `--source` option: which source a run resolves to, how it is
//! labelled, and what `add` refuses rather than silently substituting.

use super::*;

/// A registry or lock written by an earlier vstack can still hold a
/// credential URL — exactly the strings the parser now refuses. The picker
/// row that renders it must not be where the token is printed.
#[test]
fn source_label_never_prints_a_credential() {
    // A GitHub remote resolves to its slug, which is charset-gated where it is
    // minted: no userinfo survives into the row at all.
    for source in [
        "https://user:token@github.com/owner/repo.git",
        "https://token@github.com/owner/repo.git",
        "https://user:to ken@github.com/owner/repo.git",
    ] {
        assert_eq!(source_label(source), "owner/repo", "{source}");
    }
    // Anything the slug parser does not claim falls back to the redacted
    // spelling, which is where the credential must not survive.
    for source in [
        "https://user:token@example.com/owner/repo.git",
        "https://token@gitlab.example/owner/repo",
        "https://user:token@github.com.evil.example/owner/repo",
    ] {
        let label = source_label(source);
        assert!(!label.contains("token"), "{source}: {label}");
        assert!(label.contains("<redacted>"), "{source}: {label}");
    }
    // A local path is echoed as recorded, minus anything a terminal would
    // act on rather than print.
    let root = std::env::temp_dir().join(format!(
        "vstack-source-label-\u{1b}[31m-{}",
        std::process::id()
    ));
    std::fs::create_dir_all(&root).unwrap();
    let label = source_label(&root.to_string_lossy());
    assert!(!label.contains('\u{1b}'), "{label}");
    assert!(label.starts_with("local: "), "{label}");
    let _ = std::fs::remove_dir_all(&root);

    // Every spelling of one GitHub repository gets ONE row. The prefix
    // trimming this replaced knew three of them and left the rest long, so the
    // same source appeared twice under two labels.
    for source in [
        "owner/repo",
        "owner/repo.git",
        "https://github.com/owner/repo.git",
        "https://github.com/owner/repo/",
        "git@github.com:owner/repo.git",
        "ssh://git@github.com/owner/repo.git",
    ] {
        assert_eq!(source_label(source), "owner/repo", "{source}");
    }
    // A remote that is not GitHub keeps its spelling, minus what names no part
    // of the repository.
    assert_eq!(
        source_label("https://gitlab.example/owner/repo.git"),
        "https://gitlab.example/owner/repo"
    );
}

fn tmpdir(label: &str) -> PathBuf {
    let nanos = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_nanos();
    std::env::temp_dir().join(format!("vstack-add-{label}-{}-{nanos}", std::process::id()))
}

fn init_git_origin(dir: &Path, origin: &str) {
    let status = std::process::Command::new("git")
        .args(["init", "-q"])
        .current_dir(dir)
        .status()
        .unwrap();
    assert!(status.success());
    let status = std::process::Command::new("git")
        .args(["remote", "add", "origin", origin])
        .current_dir(dir)
        .status()
        .unwrap();
    assert!(status.success());
}

fn write_demo_skill(source: &Path) {
    let skill_dir = source.join("skills").join("demo");
    std::fs::create_dir_all(&skill_dir).unwrap();
    std::fs::write(
        skill_dir.join("SKILL.md"),
        r#"---
name: demo
description: Demo skill
license: MIT
---

# Demo
"#,
    )
    .unwrap();
    std::fs::write(
        skill_dir.join("vstack.settings.toml.example"),
        r#"[env]
DEMO_TIMEOUT = "30"
"#,
    )
    .unwrap();
}

fn write_demo_agent_source(source: &Path) {
    std::fs::create_dir_all(source.join("agents")).unwrap();
    std::fs::write(
        source.join("agents/rust.md"),
        r#"---
name: rust
description: Rust agent
model: sonnet
role: engineer
---

# Rust
"#,
    )
    .unwrap();
    std::fs::write(
        source.join("vstack.toml"),
        "[agent-skills]\nrust = [\"demo\"]\n",
    )
    .unwrap();
}

fn demo_skill_value() -> Skill {
    Skill {
        name: "demo".into(),
        description: "Demo skill".into(),
        license: None,
        user_invocable: None,
        dependencies: None,
        body: String::new(),
        source_dir: PathBuf::new(),
        resolved_deps: Vec::new(),
    }
}

fn skill_lock(name: &str, method: InstallMethod) -> LockFile {
    let mut lock = LockFile::default();
    lock.add(config::LockEntry {
        name: name.into(),
        kind: config::ItemKind::Skill,
        source: "source".into(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock
}

fn write_project_skill_lock(project: &Path, source: &Path, method: InstallMethod) {
    let mut lock = LockFile::default();
    lock.add(config::LockEntry {
        name: "demo".into(),
        kind: config::ItemKind::Skill,
        source: source.to_string_lossy().into_owned(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.save(&project.join(".vstack-lock.json")).unwrap();
}

#[test]
fn add_preflight_accounts_for_auto_included_skill_effective_symlink_methods() {
    let skills = vec![demo_skill_value()];
    let auto = ["demo".to_string()].into_iter().collect();
    let copy_lock = skill_lock("demo", InstallMethod::Copy);
    let symlink_lock = skill_lock("demo", InstallMethod::Symlink);
    let no_auto = std::collections::HashSet::new();

    assert!(add_writes_project_skill_root(
        false,
        &skills,
        &[Harness::ClaudeCode],
        InstallMethod::Copy,
        &auto,
        &symlink_lock,
        false,
    ));
    assert!(
        !add_writes_project_skill_root(
            false,
            &skills,
            &[Harness::ClaudeCode],
            InstallMethod::Copy,
            &auto,
            &copy_lock,
            false,
        ),
        "copy-mode auto-included skills with copy lock entries do not write .agents/skills"
    );
    assert!(
        !add_writes_project_skill_root(
            false,
            &skills,
            &[Harness::ClaudeCode],
            InstallMethod::Copy,
            &no_auto,
            &LockFile::default(),
            false,
        ),
        "manual copy-mode Claude skill installs do not write .agents/skills"
    );
}

#[test]
fn source_options_include_default_repo_for_fresh_installs() {
    let registry = config::SourceRegistry::default();
    let project_root = std::env::temp_dir().join("vstack_source_options_default_removed");
    let resolved = ResolvedSource {
        source: "/repo/local-vstack".into(),
        source_repo: None,
        label: "local: /repo/local-vstack".into(),
        dir: PathBuf::from("/repo/local-vstack"),
        persist: false,
        lease: config::CacheLease::none(),
    };

    let options = build_source_options(&registry, &resolved, &project_root);

    assert_eq!(
        options
            .iter()
            .map(|o| o.source.as_str())
            .collect::<Vec<_>>(),
        vec![crate::REPO, "/repo/local-vstack"]
    );
}

#[test]
fn source_options_do_not_re_add_removed_default_repo() {
    let mut registry = config::SourceRegistry::default();
    registry.forget(crate::REPO);
    let project_root = std::env::temp_dir().join("vstack_source_options_default_removed");
    let resolved = ResolvedSource {
        source: "/repo/local-vstack".into(),
        source_repo: None,
        label: "local: /repo/local-vstack".into(),
        dir: PathBuf::from("/repo/local-vstack"),
        persist: false,
        lease: config::CacheLease::none(),
    };

    let options = build_source_options(&registry, &resolved, &project_root);

    assert_eq!(options.len(), 1);
    assert_eq!(options[0].source, "/repo/local-vstack");
}

#[test]
fn source_options_preserve_registered_sources_only() {
    let mut registry = config::SourceRegistry::default();
    registry.remember("owner/custom");
    let project_root = std::env::temp_dir().join("vstack_source_options_registered_only");
    let resolved = ResolvedSource {
        source: "owner/custom".into(),
        source_repo: Some("owner/custom".into()),
        label: "owner/custom".into(),
        dir: PathBuf::from("/cache/owner_custom"),
        persist: true,
        lease: config::CacheLease::none(),
    };

    let options = build_source_options(&registry, &resolved, &project_root);

    assert_eq!(
        options
            .iter()
            .map(|o| o.source.as_str())
            .collect::<Vec<_>>(),
        vec![crate::REPO, "owner/custom"]
    );
}

/// The lock must record the source the install actually read from, even
/// when that directory does not look like a canonical vstack repo (here a
/// dot-named dir carrying only `skills/`). Recording the registry's current
/// source instead points every later refresh at the wrong repo.
#[test]
fn resolve_source_for_app_prefers_the_passed_source_over_the_registry_current() {
    let root = std::env::temp_dir().join(format!(
        "vstack-add-passed-source-{}-{:?}",
        std::process::id(),
        std::time::SystemTime::now()
    ));
    let alternate = root.join(".agents");
    std::fs::create_dir_all(alternate.join("skills/demo")).unwrap();
    let project_root = root.join("project");
    std::fs::create_dir_all(&project_root).unwrap();

    let mut registry = config::SourceRegistry::default();
    registry.remember_for_project(&project_root, "/repo/current-vstack");

    let resolved = resolve_source_for_app(
        Some(&alternate.to_string_lossy()),
        &registry,
        &project_root,
        SourceFetch::Now,
    )
    .expect("passed source should resolve");

    let canonical = std::fs::canonicalize(&alternate).unwrap();
    assert_eq!(resolved.source, canonical.display().to_string());
    assert_eq!(resolved.dir, canonical);
    assert!(
        !crate::resolve::is_vstack_source(&alternate),
        "fixture must exercise the non-canonical-layout case"
    );

    let _ = std::fs::remove_dir_all(root);
}

/// A refused source is not an absent one here either: walking past it
/// installs items from a different source over the ones already installed.
#[test]
fn resolve_source_for_app_fails_rather_than_replacing_a_refused_project_source() {
    let root = tmpdir("refused-project-source");
    let project_root = root.join("project");
    std::fs::create_dir_all(&project_root).unwrap();
    // A fallback that WOULD resolve: the walk from CWD finds this
    // checkout's own vstack source, so the chain has somewhere to go.
    assert!(
        std::env::current_dir()
            .unwrap()
            .ancestors()
            .any(crate::resolve::is_vstack_source),
        "control: the fallback chain must have a source to reach"
    );

    let mut registry = config::SourceRegistry::default();
    registry.remember_for_project(
        &project_root,
        "https://user:ghp_TESTTOKEN@github.com/owner/repo.git",
    );

    let Err(err) = resolve_source_for_app(None, &registry, &project_root, SourceFetch::Now) else {
        panic!("a refused project source must not fall through");
    };
    let err = format!("{err:#}");
    assert!(err.contains("credential-bearing"), "{err}");
    assert!(!err.contains("ghp_TESTTOKEN"), "{err}");
    assert!(err.contains("<redacted>"), "{err}");

    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn resolve_source_for_app_records_local_source_git_identity() {
    let root = tmpdir("source-repo-local");
    let project_root = root.join("project");
    let source = root.join("source");
    std::fs::create_dir_all(&project_root).unwrap();
    std::fs::create_dir_all(source.join("agents")).unwrap();
    std::fs::create_dir_all(source.join("skills")).unwrap();
    init_git_origin(&source, "https://github.com/vanillagreencom/vstack.git");

    let registry = config::SourceRegistry::default();
    let resolved = resolve_source_for_app(
        Some(&source.to_string_lossy()),
        &registry,
        &project_root,
        SourceFetch::Now,
    )
    .expect("local source should resolve");

    assert_eq!(
        resolved.source_repo.as_deref(),
        Some("vanillagreencom/vstack")
    );
    let _ = std::fs::remove_dir_all(root);
}

mod project_install_tests;

fn write_project_skills_dir_config(project: &Path) {
    std::fs::create_dir_all(project.join("project-skills")).unwrap();
    std::fs::write(
        project.join("vstack.toml"),
        "project-skills-dir = \"project-skills\"\n",
    )
    .unwrap();
}

fn write_canonical_source(dir: &Path) {
    std::fs::create_dir_all(dir.join("agents")).unwrap();
    std::fs::create_dir_all(dir.join("skills")).unwrap();
}

fn self_pointing_registry(project: &Path) -> config::SourceRegistry {
    let key = project.canonicalize().unwrap().display().to_string();
    let mut registry = config::SourceRegistry::default();
    registry.project_current.insert(key.clone(), key);
    registry
}

/// vstack#1024: a project that is not itself a vstack source must never
/// become its own default add source. Installing a project-local item with
/// an explicit self path records the project in the registry
/// (project-skills-dir repos do exactly that); the no-SOURCE path must
/// skip that self-reference and fall through to the lock-recorded source.
#[test]
fn default_source_skips_project_self_reference_in_registry() {
    let root = tmpdir("self-source-registry");
    let project = root.join("project");
    let canonical = root.join("canonical");
    std::fs::create_dir_all(&project).unwrap();
    write_canonical_source(&canonical);
    write_project_skills_dir_config(&project);
    let registry = self_pointing_registry(&project);
    write_project_skill_lock(&project, &canonical, InstallMethod::Copy);

    let resolved = resolve_source_for_app(None, &registry, &project, SourceFetch::Now)
        .expect("default source resolves");

    assert_eq!(
        resolved.dir,
        canonical.canonicalize().unwrap(),
        "no-SOURCE add must not resolve the project itself as the source"
    );
    let _ = std::fs::remove_dir_all(root);
}

/// vstack#1024: project-local lock entries (source = the project) must not
/// outvote the canonical source when deriving the default source from the
/// project lock.
#[test]
fn default_source_ignores_self_sourced_lock_entries() {
    let root = tmpdir("self-source-lock");
    let project = root.join("project");
    let canonical = root.join("canonical");
    std::fs::create_dir_all(&project).unwrap();
    write_canonical_source(&canonical);
    write_project_skills_dir_config(&project);

    let mut lock = LockFile::default();
    for name in ["local-a", "local-b"] {
        lock.add(config::LockEntry {
            name: name.into(),
            kind: config::ItemKind::Skill,
            source: project.to_string_lossy().into_owned(),
            source_repo: None,
            harnesses: vec!["claude-code".into()],
            method: InstallMethod::Copy,
            installed_at: "2026-07-03T00:00:00Z".into(),
            source_hash: String::new(),
        });
    }
    lock.add(config::LockEntry {
        name: "demo".into(),
        kind: config::ItemKind::Skill,
        source: canonical.to_string_lossy().into_owned(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });
    lock.save(&project.join(".vstack-lock.json")).unwrap();

    let registry = config::SourceRegistry::default();
    let resolved = resolve_source_for_app(None, &registry, &project, SourceFetch::Now)
        .expect("default source resolves");

    assert_eq!(resolved.dir, canonical.canonicalize().unwrap());
    let _ = std::fs::remove_dir_all(root);
}

/// The self-source guard must not break the legitimate case where the
/// project root really is a vstack source (e.g. running add inside the
/// vstack checkout itself).
#[test]
fn default_source_keeps_project_that_is_a_real_vstack_source() {
    let root = tmpdir("self-source-genuine");
    let project = root.join("project");
    write_canonical_source(&project);
    let registry = self_pointing_registry(&project);

    let resolved = resolve_source_for_app(None, &registry, &project, SourceFetch::Now)
        .expect("default source resolves");

    assert_eq!(resolved.dir, project.canonicalize().unwrap());
    let _ = std::fs::remove_dir_all(root);
}

/// vstack#1024: a requested-by-name item that is not in the source must be
/// a hard error, never "nothing found" + exit 0 — scripted adopters chain
/// on the exit code.
#[test]
fn add_named_missing_skill_fails_nonzero() {
    let root = tmpdir("missing-skill");
    let source = root.join("source");
    let project = root.join("project");
    let home = root.join("home");
    let config_home = root.join("config");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&config_home).unwrap();
    write_demo_skill(&source);

    let err = crate::test_util::with_home_and_config(&home, &config_home, || {
        crate::test_util::with_project_root(&project, || {
            run(
                Some(source.to_string_lossy().into_owned()),
                false,
                Some(vec!["codex".into()]),
                None,
                Some(vec!["review-gate".into()]),
                None,
                None,
                false,
                true,
                false,
                false,
                false,
            )
            .unwrap_err()
        })
    });

    let msg = err.to_string();
    assert!(
        msg.contains("skill 'review-gate'"),
        "error must name the missing item: {msg}"
    );
    let _ = std::fs::remove_dir_all(root);
}

/// A partial match must also fail: naming one existing skill plus a
/// missing agent and hook installs nothing and errors listing every
/// missing item.
#[test]
fn add_partial_named_match_fails_and_installs_nothing() {
    let root = tmpdir("missing-partial");
    let source = root.join("source");
    let project = root.join("project");
    let home = root.join("home");
    let config_home = root.join("config");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&config_home).unwrap();
    write_demo_skill(&source);

    let err = crate::test_util::with_home_and_config(&home, &config_home, || {
        crate::test_util::with_project_root(&project, || {
            run(
                Some(source.to_string_lossy().into_owned()),
                false,
                Some(vec!["codex".into()]),
                Some(vec!["ghost".into()]),
                Some(vec!["demo".into()]),
                Some(vec!["nohook".into()]),
                None,
                false,
                true,
                false,
                false,
                false,
            )
            .unwrap_err()
        })
    });

    let msg = err.to_string();
    assert!(msg.contains("agent 'ghost'"), "missing agent named: {msg}");
    assert!(msg.contains("hook 'nohook'"), "missing hook named: {msg}");
    assert!(
        !project.join(".agents/skills/demo/SKILL.md").exists(),
        "a failed add must not partially install the matched items"
    );
    assert!(!project.join(".vstack-lock.json").exists());
    let _ = std::fs::remove_dir_all(root);
}

/// vstack#1038: a non-interactive add that ends up with zero harnesses
/// installs nothing — that must be a nonzero exit naming the real flag
/// (`--harness`), never exit 0 with a wrong-flag hint.
#[test]
fn add_with_no_matching_harness_fails_nonzero_and_names_harness_flag() {
    let root = tmpdir("no-harness");
    let source = root.join("source");
    let project = root.join("project");
    let home = root.join("home");
    let config_home = root.join("config");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&config_home).unwrap();
    write_demo_skill(&source);

    let err = crate::test_util::with_home_and_config(&home, &config_home, || {
        crate::test_util::with_project_root(&project, || {
            let err = run(
                Some(source.to_string_lossy().into_owned()),
                false,
                Some(vec!["not-a-harness".into()]),
                None,
                Some(vec!["demo".into()]),
                None,
                None,
                false,
                true,
                false,
                false,
                false,
            )
            .unwrap_err();

            // #1047 round 4: a failing add must not touch registry state —
            // no sources.json had existed, so none may appear.
            assert!(
                !config::source_registry_path().exists(),
                "a failed add must not create sources.json"
            );
            err
        })
    });

    let msg = err.to_string();
    assert!(
        msg.contains("--harness"),
        "hint must name the real flag: {msg}"
    );
    let _ = std::fs::remove_dir_all(root);
}

/// vstack#1038 (review round 3): a non-interactive add against a source
/// with nothing installable must exit nonzero — same defect shape as the
/// zero-harness path: exit 0 with nothing installed reads as success to
/// scripted adopters. Interactive runs never hit this bail; without
/// -y/--all/--harness they fall through to the source picker instead.
#[test]
fn add_empty_source_noninteractive_fails_nonzero() {
    let root = tmpdir("empty-source");
    let source = root.join("source");
    let project = root.join("project");
    let home = root.join("home");
    let config_home = root.join("config");
    std::fs::create_dir_all(&source).unwrap();
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&config_home).unwrap();

    let err = crate::test_util::with_home_and_config(&home, &config_home, || {
        crate::test_util::with_project_root(&project, || {
            // #1047 round 4: a failing add must not mutate sources.json.
            // Seed a registry carrying a stale project-self entry that the
            // persist-path prune WOULD rewrite, and pin the exact bytes.
            let reg_path = config::source_registry_path();
            let registry = config::SourceRegistry {
                entries: vec![
                    "vanillagreencom/vstack".to_string(),
                    project.display().to_string(),
                ],
                ..Default::default()
            };
            registry.save(&reg_path).unwrap();
            let before = std::fs::read(&reg_path).unwrap();

            let err = run(
                Some(source.to_string_lossy().into_owned()),
                false,
                None,
                None,
                None,
                None,
                None,
                false,
                true,
                false,
                false,
                false,
            )
            .unwrap_err();

            assert_eq!(
                std::fs::read(&reg_path).unwrap(),
                before,
                "a failed add must leave sources.json byte-identical"
            );
            err
        })
    });

    let msg = err.to_string();
    assert!(
        msg.contains("No agents, skills, hooks, pi-packages, or extras found"),
        "empty source must fail loud: {msg}"
    );
    let _ = std::fs::remove_dir_all(root);
}

#[test]
fn noninteractive_harnesses_rejects_all_unknown_ids_naming_the_flag() {
    let err = noninteractive_harnesses(Some(&["nope".to_string()])).unwrap_err();
    let msg = err.to_string();
    assert!(
        msg.contains("--harness"),
        "hint must name the real flag: {msg}"
    );
    let ids: Vec<&str> = Harness::ALL.iter().map(Harness::id).collect();
    assert!(
        msg.contains(&ids.join(",")),
        "hint must carry the canonical id list, derived so it cannot drift: {msg}"
    );
}

#[test]
fn noninteractive_harnesses_accepts_known_ids() {
    let harnesses = noninteractive_harnesses(Some(&["codex".to_string()])).unwrap();
    assert_eq!(harnesses, vec![Harness::Codex]);
}

/// vstack#1038, rescoped in the #1047 review: the picker filters ONLY the
/// current project's own self entry, and only when the project lacks
/// vstack source content (a consumer project recorded as its own source,
/// vstack#1024). Other local entries are never judged — a registered
/// skills-only source is legitimate (explicit-path adds accept it), and a
/// missing path proves nothing about its content.
#[test]
fn source_options_exclude_only_the_current_project_self_entry() {
    let root = tmpdir("picker-self-only");
    let project = root.join("consumer-project");
    let other_project = root.join("other-consumer-project");
    let skills_only = root.join("skills-only-source");
    let genuine = root.join("genuine-source");
    let missing = root.join("unmounted");
    std::fs::create_dir_all(&project).unwrap();
    std::fs::create_dir_all(&other_project).unwrap();
    std::fs::create_dir_all(skills_only.join("skills/demo")).unwrap();
    write_canonical_source(&genuine);

    let registry = config::SourceRegistry {
        entries: vec![
            project.display().to_string(),
            other_project.display().to_string(),
            skills_only.display().to_string(),
            genuine.display().to_string(),
            missing.display().to_string(),
            "owner/custom".to_string(),
        ],
        ..Default::default()
    };
    let resolved = ResolvedSource {
        source: genuine.display().to_string(),
        source_repo: None,
        label: "local".into(),
        dir: genuine.clone(),
        persist: false,
        lease: config::CacheLease::none(),
    };

    let options = build_source_options(&registry, &resolved, &project);
    let sources: Vec<String> = options.iter().map(|o| o.source.clone()).collect();

    assert!(
        !sources.contains(&project.display().to_string()),
        "the current project's non-source self entry must be filtered: {sources:?}"
    );
    assert!(
        sources.contains(&other_project.display().to_string()),
        "local entries that are not the current project must be kept: {sources:?}"
    );
    assert!(
        sources.contains(&skills_only.display().to_string()),
        "a registered skills-only source must be kept: {sources:?}"
    );
    assert!(sources.contains(&genuine.display().to_string()));
    assert!(
        sources.contains(&missing.display().to_string()),
        "missing-path entries must be kept: {sources:?}"
    );
    assert!(sources.contains(&"owner/custom".to_string()));
    let _ = std::fs::remove_dir_all(root);
}

/// An unreadable registry is a failed read, not an empty one: defaulting
/// past it and saving would overwrite the file with an empty registry,
/// destroying every remembered source and tombstone it still holds.
#[test]
fn persist_confirmed_source_refuses_to_overwrite_an_unreadable_registry() {
    let root = tmpdir("persist-corrupt");
    let home = root.join("home");
    let config_home = root.join("config");
    let project = root.join("project");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&config_home).unwrap();
    std::fs::create_dir_all(&project).unwrap();

    crate::test_util::with_home_and_config(&home, &config_home, || {
        let reg_path = config::source_registry_path();
        std::fs::create_dir_all(reg_path.parent().unwrap()).unwrap();
        std::fs::write(&reg_path, "{ this is not json").unwrap();

        let resolved = ResolvedSource {
            source: "owner/confirmed".into(),
            source_repo: None,
            label: "owner/confirmed".into(),
            dir: PathBuf::from("/cache/owner_confirmed"),
            persist: true,
            lease: config::CacheLease::none(),
        };
        let err = persist_confirmed_source(&resolved, false, &project)
            .expect_err("an unreadable registry must fail, not default to empty");
        assert!(
            format!("{err:#}").contains("source registry"),
            "the error must name the registry it could not read: {err:#}"
        );
        assert_eq!(
            std::fs::read_to_string(&reg_path).unwrap(),
            "{ this is not json",
            "the unreadable registry must be left exactly as it was"
        );
    });
    let _ = std::fs::remove_dir_all(root);
}

/// The interactive repo dialog removes sources by writing sources.json
/// directly mid-run (install_flow::forget_source).
/// The post-confirmation persist must work from the on-disk registry, not
/// this run's pre-TUI snapshot — saving the snapshot resurrects the entry
/// and drops its removed-source tombstone.
#[test]
fn persist_confirmed_source_keeps_registry_mutations_made_during_the_tui() {
    let root = tmpdir("persist-reload");
    let home = root.join("home");
    let config_home = root.join("config");
    let project = root.join("project");
    std::fs::create_dir_all(&home).unwrap();
    std::fs::create_dir_all(&config_home).unwrap();
    std::fs::create_dir_all(&project).unwrap();

    crate::test_util::with_home_and_config(&home, &config_home, || {
        let reg_path = config::source_registry_path();
        let mut pre_tui = config::SourceRegistry::default();
        pre_tui.remember("owner/keep");
        pre_tui.remember("owner/removed-in-tui");
        pre_tui.save(&reg_path).unwrap();

        // Mid-TUI: the repo dialog forgets one source on disk.
        let mut on_disk = config::SourceRegistry::load(&reg_path).unwrap();
        on_disk.forget("owner/removed-in-tui");
        on_disk.save(&reg_path).unwrap();

        let resolved = ResolvedSource {
            source: "owner/confirmed".into(),
            source_repo: None,
            label: "owner/confirmed".into(),
            dir: PathBuf::from("/cache/owner_confirmed"),
            persist: true,
            lease: config::CacheLease::none(),
        };
        persist_confirmed_source(&resolved, false, &project).unwrap();

        let after = config::SourceRegistry::load(&reg_path).unwrap();
        assert!(
            !after.entries.iter().any(|e| e == "owner/removed-in-tui"),
            "persist must not resurrect a source removed during the TUI: {:?}",
            after.entries
        );
        assert!(
            after.was_removed("owner/removed-in-tui"),
            "the removed-source tombstone must survive the persist"
        );
        assert!(after.entries.iter().any(|e| e == "owner/keep"));
        assert!(after.entries.iter().any(|e| e == "owner/confirmed"));
        assert_eq!(after.current_for_project(&project), Some("owner/confirmed"));
    });
    let _ = std::fs::remove_dir_all(root);
}

/// The source resolved for THIS run always stays listed, even when it is
/// the current project's own non-source root — the user explicitly chose
/// it (e.g. a project-skills-dir self-add, vstack#1024).
#[test]
fn source_options_keep_the_resolved_source_even_if_non_source() {
    let root = tmpdir("picker-resolved-non-source");
    let consumer = root.join("consumer-project");
    std::fs::create_dir_all(&consumer).unwrap();

    let registry = config::SourceRegistry {
        entries: vec![consumer.display().to_string()],
        ..Default::default()
    };
    let resolved = ResolvedSource {
        source: consumer.display().to_string(),
        source_repo: None,
        label: "local".into(),
        dir: consumer.clone(),
        persist: false,
        lease: config::CacheLease::none(),
    };

    let options = build_source_options(&registry, &resolved, &consumer);
    assert!(
        options
            .iter()
            .any(|o| o.source == consumer.display().to_string()),
        "the currently resolved source must stay selectable"
    );
    let _ = std::fs::remove_dir_all(root);
}
