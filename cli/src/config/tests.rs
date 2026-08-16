use super::*;
use std::fs;

fn sandbox(label: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "vstack_source_registry_{label}_{}",
        std::process::id()
    ));
    let _ = fs::remove_dir_all(&dir);
    fs::create_dir_all(&dir).unwrap();
    dir
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

#[test]
fn lock_file_save_terminates_with_exactly_one_newline() {
    let dir = sandbox("lock_newline");
    let path = dir.join(".vstack-lock.json");

    let mut lock = LockFile {
        version: 1,
        ..Default::default()
    };
    lock.add(LockEntry {
        name: "guard".to_string(),
        kind: ItemKind::Hook,
        source: "vanillagreencom/vstack".to_string(),
        source_repo: Some("vanillagreencom/vstack".to_string()),
        harnesses: vec!["codex".to_string()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-24T00:00:00Z".to_string(),
        source_hash: String::new(),
    });

    lock.save(&path).unwrap();
    let first = fs::read_to_string(&path).unwrap();
    assert!(
        first.ends_with("}\n"),
        "lock file must end with one newline"
    );
    assert!(
        !first.ends_with("\n\n"),
        "lock file must not end with a blank line"
    );

    // Load/save round-trips must not accumulate terminators, otherwise
    // every refresh would grow the file by a blank line.
    LockFile::load(&path).unwrap().save(&path).unwrap();
    assert_eq!(fs::read_to_string(&path).unwrap(), first);

    let _ = fs::remove_dir_all(dir);
}

#[test]
fn source_registry_save_terminates_with_exactly_one_newline() {
    let dir = sandbox("registry_newline");
    let path = dir.join("sources.json");

    let mut registry = SourceRegistry::default();
    registry.remember("vanillagreencom/vstack");

    registry.save(&path).unwrap();
    let first = fs::read_to_string(&path).unwrap();
    assert!(first.ends_with("}\n"), "registry must end with one newline");
    assert!(
        !first.ends_with("\n\n"),
        "registry must not end with a blank line"
    );

    SourceRegistry::load(&path).unwrap().save(&path).unwrap();
    assert_eq!(fs::read_to_string(&path).unwrap(), first);

    let _ = fs::remove_dir_all(dir);
}

#[test]
fn lock_entry_deserializes_legacy_without_source_repo() {
    let raw = r#"{
      "name": "guard",
      "kind": "hook",
      "source": "/missing/source",
      "harnesses": ["codex"],
      "method": "copy",
      "installed_at": "2026-07-21T00:00:00Z"
    }"#;
    let entry: LockEntry = serde_json::from_str(raw).unwrap();
    assert_eq!(entry.name, "guard");
    assert_eq!(entry.kind, ItemKind::Hook);
    assert!(entry.source_repo.is_none());
    assert!(entry.source_hash.is_empty());
}

#[test]
fn source_repo_for_source_prefers_git_origin_over_layout() {
    let dir = sandbox("source_repo_git");
    fs::create_dir_all(dir.join("agents")).unwrap();
    fs::create_dir_all(dir.join("hooks")).unwrap();
    init_git_origin(&dir, "https://github.com/vanillagreencom/vstack.git");

    assert_eq!(
        source_repo_for_source(Some(&dir), &dir.to_string_lossy()).as_deref(),
        Some("vanillagreencom/vstack")
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn source_repo_for_source_does_not_infer_from_local_layout_only() {
    let dir = sandbox("source_repo_layout");
    fs::create_dir_all(dir.join("agents")).unwrap();
    fs::create_dir_all(dir.join("hooks")).unwrap();

    assert_eq!(
        source_repo_for_source(Some(&dir), &dir.to_string_lossy()),
        None
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn parse_github_slug_normalizes_supported_remote_shapes() {
    assert_eq!(
        parse_github_slug("git@github.com:VanillaGreenCom/VStack.git").as_deref(),
        Some("vanillagreencom/vstack")
    );
    assert_eq!(
        parse_github_slug("https://github.com/owner/repo/").as_deref(),
        Some("owner/repo")
    );
    assert_eq!(
        parse_github_slug("https://credential@github.com/Owner/Repo.git").as_deref(),
        Some("owner/repo")
    );
    assert_eq!(
        parse_github_slug("https://user:token@github.com/owner/repo").as_deref(),
        Some("owner/repo")
    );
    assert_eq!(parse_github_slug("a/b/c"), None);
    assert_eq!(parse_github_slug("./source"), None);
    assert_eq!(parse_github_slug("../source"), None);
    assert_eq!(parse_github_slug("C:/source"), None);
    assert_eq!(parse_github_slug(".\\source"), None);
    assert_eq!(parse_github_slug("/home/me/dev/vstack"), None);
}

#[test]
fn prune_drops_dead_absolute_paths_keeps_shorthand_and_live_paths() {
    let dir = sandbox("prune_drops_dead");
    let live = dir.join("live");
    fs::create_dir_all(&live).unwrap();
    let dead = dir.join("dead");
    // dead is intentionally not created.

    let mut reg = SourceRegistry {
        current: Some("vanillagreencom/vstack".to_string()),
        entries: vec![
            "vanillagreencom/vstack".to_string(),
            live.display().to_string(),
            dead.display().to_string(),
            "https://example.com/repo".to_string(),
        ],
        ..Default::default()
    };
    let pruned = reg.prune_dead_paths();
    assert_eq!(pruned, 1);
    assert_eq!(
        reg.entries,
        vec![
            "vanillagreencom/vstack".to_string(),
            live.display().to_string(),
            "https://example.com/repo".to_string(),
        ]
    );
    assert_eq!(reg.current.as_deref(), Some("vanillagreencom/vstack"));
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn prune_clears_current_if_current_is_dead() {
    let dir = sandbox("prune_clears_current");
    let dead = dir.join("dead");
    let mut reg = SourceRegistry {
        current: Some(dead.display().to_string()),
        entries: vec![dead.display().to_string()],
        ..Default::default()
    };
    let pruned = reg.prune_dead_paths();
    assert_eq!(pruned, 1);
    assert!(reg.current.is_none());
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn load_persists_pruned_view_to_disk() {
    let dir = sandbox("load_persists");
    let path = dir.join("sources.json");
    let dead = dir.join("dead-source").display().to_string();
    let raw = serde_json::json!({
        "current": "vanillagreencom/vstack",
        "entries": ["vanillagreencom/vstack", dead],
    });
    fs::write(&path, raw.to_string()).unwrap();

    let loaded = SourceRegistry::load(&path).unwrap();
    assert_eq!(loaded.entries, vec!["vanillagreencom/vstack".to_string()]);

    let on_disk: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    assert_eq!(on_disk["entries"].as_array().unwrap().len(), 1);
    let _ = fs::remove_dir_all(&dir);
}

/// vstack#1038, rescoped in the #1047 review: the write-path prune drops
/// ONLY the current project's own self entry, and only when that project
/// provably lacks vstack source content (a consumer project recorded as
/// its own source, vstack#1024). Other local paths — another project, a
/// registered skills-only source, a missing path — are never judged.
#[test]
fn prune_project_self_drops_only_the_non_source_self_entry() {
    let dir = sandbox("prune_project_self");
    let project = dir.join("consumer-project");
    let other_project = dir.join("other-consumer-project");
    let skills_only = dir.join("skills-only-source");
    let genuine = dir.join("genuine");
    let missing = dir.join("missing");
    fs::create_dir_all(&project).unwrap();
    fs::create_dir_all(&other_project).unwrap();
    fs::create_dir_all(skills_only.join("skills/demo")).unwrap();
    fs::create_dir_all(genuine.join("agents")).unwrap();
    fs::create_dir_all(genuine.join("skills")).unwrap();

    let mut reg = SourceRegistry {
        current: Some(project.display().to_string()),
        entries: vec![
            "vanillagreencom/vstack".to_string(),
            project.display().to_string(),
            other_project.display().to_string(),
            skills_only.display().to_string(),
            genuine.display().to_string(),
            missing.display().to_string(),
        ],
        ..Default::default()
    };
    let pruned = reg.prune_project_self_non_source(&project);

    assert_eq!(pruned, 1);
    assert_eq!(
        reg.entries,
        vec![
            "vanillagreencom/vstack".to_string(),
            other_project.display().to_string(),
            skills_only.display().to_string(),
            genuine.display().to_string(),
            missing.display().to_string(),
        ]
    );
    // `current`/`project_current` are left alone: the #1024 read-side
    // guards already neutralize a stale self-pointer there, and dropping a
    // user's sticky per-project choice is riskier than cleaning the
    // picker-facing entries list.
    assert_eq!(
        reg.current.as_deref(),
        Some(project.display().to_string()).as_deref()
    );
    let _ = fs::remove_dir_all(&dir);
}

/// The self prune must keep a project that genuinely is a vstack source
/// (running add inside a source checkout).
#[test]
fn prune_project_self_keeps_a_project_with_source_content() {
    let dir = sandbox("prune_project_self_genuine");
    let project = dir.join("source-checkout");
    fs::create_dir_all(project.join("agents")).unwrap();
    fs::create_dir_all(project.join("skills")).unwrap();

    let mut reg = SourceRegistry {
        entries: vec![project.display().to_string()],
        ..Default::default()
    };
    assert_eq!(reg.prune_project_self_non_source(&project), 0);
    assert_eq!(reg.entries, vec![project.display().to_string()]);
    let _ = fs::remove_dir_all(&dir);
}

/// Round-trip policy (#1047 review): `save` never judges entries — every
/// in-memory entry is written, including missing paths and non-source
/// dirs. Dead local paths are dropped at LOAD by `prune_dead_paths`,
/// which exists for deleted/moved worktrees (b14d593f) — so a missing
/// path deliberately does NOT survive a save/load round trip.
#[test]
fn save_writes_all_entries_and_load_drops_dead_local_paths() {
    let dir = sandbox("save_load_round_trip");
    let path = dir.join("sources.json");
    let plain = dir.join("plain-non-source-dir");
    fs::create_dir_all(&plain).unwrap();
    let missing = dir.join("missing");

    let reg = SourceRegistry {
        entries: vec![
            "vanillagreencom/vstack".to_string(),
            plain.display().to_string(),
            missing.display().to_string(),
        ],
        ..Default::default()
    };
    reg.save(&path).unwrap();

    let on_disk: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&path).unwrap()).unwrap();
    let written: Vec<&str> = on_disk["entries"]
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap())
        .collect();
    assert_eq!(
        written,
        vec![
            "vanillagreencom/vstack",
            plain.display().to_string().as_str(),
            missing.display().to_string().as_str(),
        ],
        "save must write every entry verbatim"
    );

    let loaded = SourceRegistry::load(&path).unwrap();
    assert_eq!(
        loaded.entries,
        vec![
            "vanillagreencom/vstack".to_string(),
            plain.display().to_string()
        ],
        "load drops dead local paths (worktree hygiene), keeps live ones"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn remember_ignores_temp_sources() {
    let dir = sandbox("remember_temp");
    let mut reg = SourceRegistry::default();

    reg.remember("vanillagreencom/vstack");
    reg.remember(&dir.display().to_string());

    assert_eq!(reg.current.as_deref(), Some("vanillagreencom/vstack"));
    assert_eq!(reg.entries, vec!["vanillagreencom/vstack".to_string()]);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn remember_for_project_does_not_change_global_current() {
    let project_a = sandbox("project_a");
    let project_b = sandbox("project_b");
    let mut reg = SourceRegistry::default();

    reg.remember("vanillagreencom/vstack");
    reg.remember_for_project(&project_a, "owner/a");
    reg.remember_for_project(&project_b, "owner/b");

    assert_eq!(reg.current.as_deref(), Some("vanillagreencom/vstack"));
    assert_eq!(reg.current_for_project(&project_a), Some("owner/a"));
    assert_eq!(reg.current_for_project(&project_b), Some("owner/b"));
    assert!(reg.entries.contains(&"owner/a".to_string()));
    assert!(reg.entries.contains(&"owner/b".to_string()));
    let _ = fs::remove_dir_all(&project_a);
    let _ = fs::remove_dir_all(&project_b);
}

/// A per-project source choice outlives its project (deleted worktree,
/// vanished temp checkout): the KEY is a dead path even when the value is
/// a remote shorthand that never dies. Both sides are checked; a live
/// project keeps its remote choice untouched.
#[test]
fn prune_drops_project_current_keys_for_vanished_projects() {
    let dir = sandbox("prune_project_current_keys");
    let live_project = dir.join("live-project");
    fs::create_dir_all(&live_project).unwrap();
    let dead_project = dir.join("dead-project");
    // dead_project is intentionally not created.

    let mut reg = SourceRegistry::default();
    reg.remember_for_project(&live_project, "vanillagreencom/vstack");
    reg.project_current.insert(
        dead_project.display().to_string(),
        "vanillagreencom/vstack".to_string(),
    );

    let pruned = reg.prune_dead_paths();

    assert_eq!(pruned, 1);
    assert_eq!(
        reg.current_for_project(&live_project),
        Some("vanillagreencom/vstack")
    );
    assert!(
        !reg.project_current
            .contains_key(&dead_project.display().to_string()),
        "vanished project key must be dropped: {:?}",
        reg.project_current
    );
    assert_eq!(reg.entries, vec!["vanillagreencom/vstack".to_string()]);
    let _ = fs::remove_dir_all(&dir);
}

/// Path-likeness follows the running platform's notion of an absolute
/// path, so a dead Windows drive-letter or UNC key/source is pruned like a
/// dead `/…` one. Remote shorthand and URLs are never paths on any platform.
#[test]
fn prune_recognizes_platform_absolute_paths_and_never_prunes_remotes() {
    #[cfg(windows)]
    {
        let mut reg = SourceRegistry::default();
        reg.entries.push(r"C:\vanished-source".to_string());
        reg.project_current.insert(
            r"C:\vanished-project".to_string(),
            "vanillagreencom/vstack".to_string(),
        );
        reg.project_current.insert(
            r"\\server\share\vanished-project".to_string(),
            "vanillagreencom/vstack".to_string(),
        );
        assert_eq!(reg.prune_dead_paths(), 3);
        assert!(reg.entries.is_empty(), "{:?}", reg.entries);
        assert!(reg.project_current.is_empty(), "{:?}", reg.project_current);
    }
    #[cfg(unix)]
    {
        assert!(expanded_local_path("/vanished").is_some());
        assert!(is_dead_local_path("/vanished/never/existed"));
    }
    for remote in [
        "vanillagreencom/vstack",
        "https://example.com/repo",
        "git@github.com:owner/repo.git",
    ] {
        assert!(
            expanded_local_path(remote).is_none(),
            "{remote:?} is not a path"
        );
    }

    let dir = sandbox("prune_remotes_untouched");
    let mut reg = SourceRegistry {
        current: Some("vanillagreencom/vstack".to_string()),
        entries: vec![
            "vanillagreencom/vstack".to_string(),
            "https://example.com/repo".to_string(),
            "git@github.com:owner/repo.git".to_string(),
        ],
        ..Default::default()
    };
    reg.remember_for_project(&dir, "https://example.com/repo");
    let before = reg.clone();

    assert_eq!(reg.prune_dead_paths(), 0);
    assert_eq!(reg.entries, before.entries);
    assert_eq!(reg.current, before.current);
    assert_eq!(reg.project_current, before.project_current);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn forget_clears_matching_project_current() {
    let project = sandbox("forget_project");
    let mut reg = SourceRegistry::default();
    reg.remember_for_project(&project, "owner/repo");

    reg.forget("owner/repo");

    assert_eq!(reg.current_for_project(&project), None);
    assert!(!reg.entries.contains(&"owner/repo".to_string()));
    let _ = fs::remove_dir_all(&project);
}

#[test]
fn forget_records_removed_source_tombstone() {
    let mut reg = SourceRegistry::default();

    reg.forget("vanillagreencom/vstack");

    assert!(reg.was_removed("vanillagreencom/vstack"));
}

#[test]
fn pi_extension_hash_tracks_scoped_package_content() {
    let dir = sandbox("pi_hash_scoped");
    let pkg_dir = dir.join("pi-extensions").join("pi-questions");
    fs::create_dir_all(&pkg_dir).unwrap();
    fs::write(
        pkg_dir.join("package.json"),
        r#"{"name":"@vanillagreen/pi-questions","version":"0.0.1"}"#,
    )
    .unwrap();
    let ext_dir = pkg_dir.join("extensions");
    fs::create_dir_all(&ext_dir).unwrap();
    fs::write(ext_dir.join("questions.ts"), b"// before").unwrap();

    let entry = LockEntry {
        name: "@vanillagreen/pi-questions".to_string(),
        kind: ItemKind::PiExtension,
        source: dir.display().to_string(),
        source_repo: None,
        harnesses: vec!["pi".to_string()],
        method: InstallMethod::Symlink,
        installed_at: "2026-05-06T00:00:00Z".to_string(),
        source_hash: String::new(),
    };

    let h1 = compute_source_hash(&entry);
    fs::write(ext_dir.join("questions.ts"), b"// after a real edit").unwrap();
    let h2 = compute_source_hash(&entry);

    assert_ne!(
        h1, h2,
        "hash must change when source content changes for scoped Pi packages"
    );
    // Must not collapse to the bare FNV offset constant.
    assert_ne!(h1, format!("{:016x}", FNV_OFFSET));
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn source_hash_uses_custom_catalog_skill_path() {
    let dir = sandbox("catalog_hash_skill");
    let skill_dir = dir.join("pkgs").join("skills").join("demo");
    fs::create_dir_all(&skill_dir).unwrap();
    fs::write(
        dir.join("vstack.toml"),
        "[catalog]\nskills = [\"pkgs/skills/*\"]\n",
    )
    .unwrap();
    fs::write(
        skill_dir.join("SKILL.md"),
        "---\nname: demo\ndescription: Demo\n---\n# Before\n",
    )
    .unwrap();

    let entry = LockEntry {
        name: "demo".to_string(),
        kind: ItemKind::Skill,
        source: dir.display().to_string(),
        source_repo: None,
        harnesses: vec!["codex".to_string()],
        method: InstallMethod::Symlink,
        installed_at: "2026-07-29T00:00:00Z".to_string(),
        source_hash: String::new(),
    };

    let h1 = compute_source_hash(&entry);
    fs::write(
        skill_dir.join("SKILL.md"),
        "---\nname: demo\ndescription: Demo\n---\n# After\n",
    )
    .unwrap();
    let h2 = compute_source_hash(&entry);

    assert!(!h1.is_empty());
    assert_ne!(h1, h2);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn agent_source_hash_tracks_shared_instruction_key() {
    let dir = sandbox("shared_key_hash_agent");
    let agents_dir = dir.join("agents");
    fs::create_dir_all(&agents_dir).unwrap();
    fs::write(
        agents_dir.join("demo.md"),
        "---\nname: demo\ndescription: Demo\n---\n# Demo\n",
    )
    .unwrap();
    fs::write(
        dir.join("vstack.toml"),
        "[agent-additional-instructions]\nall = \"Fleet rule v1\"\n",
    )
    .unwrap();

    let entry = LockEntry {
        name: "demo".to_string(),
        kind: ItemKind::Agent,
        source: dir.display().to_string(),
        source_repo: None,
        harnesses: vec!["claude-code".to_string()],
        method: InstallMethod::Symlink,
        installed_at: "2026-08-09T00:00:00Z".to_string(),
        source_hash: String::new(),
    };

    let h1 = compute_source_hash(&entry);
    fs::write(
        dir.join("vstack.toml"),
        "[agent-additional-instructions]\nall = \"Fleet rule v2\"\n",
    )
    .unwrap();
    let h2 = compute_source_hash(&entry);
    assert!(!h1.is_empty());
    assert_ne!(
        h1, h2,
        "editing the shared `all` entry must stale every agent install"
    );

    // The `\"*\"` alias spelling must stale installs the same way.
    fs::write(
        dir.join("vstack.toml"),
        "[agent-additional-instructions]\n\"*\" = \"Fleet rule v3\"\n",
    )
    .unwrap();
    let h3 = compute_source_hash(&entry);
    assert_ne!(h2, h3);

    // A shared key in the SKILL instruction table must not stale agents:
    // cross-kind invalidation would report unrelated items outdated.
    fs::write(
        dir.join("vstack.toml"),
        "[agent-additional-instructions]\n\"*\" = \"Fleet rule v3\"\n\n[skill-instructions]\nall = \"Skill rule v1\"\n",
    )
    .unwrap();
    let h4 = compute_source_hash(&entry);
    fs::write(
        dir.join("vstack.toml"),
        "[agent-additional-instructions]\n\"*\" = \"Fleet rule v3\"\n\n[skill-instructions]\nall = \"Skill rule v2\"\n",
    )
    .unwrap();
    let h5 = compute_source_hash(&entry);
    assert_eq!(
        h4, h5,
        "editing [skill-instructions].all must not stale agent installs"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn agent_source_hash_tracks_multiline_shared_body() {
    let dir = sandbox("shared_key_hash_multiline");
    let agents_dir = dir.join("agents");
    fs::create_dir_all(&agents_dir).unwrap();
    fs::write(
        agents_dir.join("demo.md"),
        "---\nname: demo\ndescription: Demo\n---\n# Demo\n",
    )
    .unwrap();
    // The body contains an escaped quote run (`""\"`) — a naive scanner
    // would treat it as the closing delimiter and stop hashing there.
    let toml_v1 = "[agent-additional-instructions]\nall = \"\"\"\nFleet rule body v1\nquote run: \"\"\\\" done\nSecond line\n\"\"\"\n";
    fs::write(dir.join("vstack.toml"), toml_v1).unwrap();

    let entry = LockEntry {
        name: "demo".to_string(),
        kind: ItemKind::Agent,
        source: dir.display().to_string(),
        source_repo: None,
        harnesses: vec!["claude-code".to_string()],
        method: InstallMethod::Symlink,
        installed_at: "2026-08-09T00:00:00Z".to_string(),
        source_hash: String::new(),
    };

    let h1 = compute_source_hash(&entry);
    // Edit ONLY an unindented body line AFTER the escaped quote run.
    let toml_v2 = "[agent-additional-instructions]\nall = \"\"\"\nFleet rule body v1\nquote run: \"\"\\\" done\nSecond line EDITED\n\"\"\"\n";
    fs::write(dir.join("vstack.toml"), toml_v2).unwrap();
    let h2 = compute_source_hash(&entry);
    assert_ne!(
        h1, h2,
        "editing a multiline shared body (past escaped quotes) must stale the agent install"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn find_project_root_refuses_home_with_only_user_harness_dirs() {
    let dir = sandbox("find_root_home");
    let fake_home = dir.join("home");
    fs::create_dir_all(fake_home.join(".claude")).unwrap();
    fs::create_dir_all(fake_home.join(".pi")).unwrap();
    let workdir = fake_home.join("random-non-project");
    fs::create_dir_all(&workdir).unwrap();

    let root = find_project_root_within(&workdir, &fake_home);
    assert_eq!(
        root, workdir,
        "$HOME with .claude/.pi must NOT be claimed as project root; fall back to CWD"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn find_project_root_accepts_home_when_lock_file_present() {
    let dir = sandbox("find_root_home_lock");
    let fake_home = dir.join("home");
    fs::create_dir_all(&fake_home).unwrap();
    fs::write(fake_home.join(".vstack-lock.json"), "{}").unwrap();
    let workdir = fake_home.join("sub");
    fs::create_dir_all(&workdir).unwrap();

    let root = find_project_root_within(&workdir, &fake_home);
    assert_eq!(
        root.canonicalize().unwrap(),
        fake_home.canonicalize().unwrap(),
        "explicit lock file at $HOME overrides the home guard"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn find_project_root_finds_real_project_under_home() {
    let dir = sandbox("find_root_real_project");
    let fake_home = dir.join("home");
    fs::create_dir_all(fake_home.join(".claude")).unwrap();
    let project = fake_home.join("work").join("app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let workdir = project.join("src");
    fs::create_dir_all(&workdir).unwrap();

    let root = find_project_root_within(&workdir, &fake_home);
    assert_eq!(
        root, project,
        "real project under $HOME should still be detected"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn hook_hash_tracks_hook_events_table_changes() {
    let dir = sandbox("hook_hash_events");
    fs::create_dir_all(dir.join("hooks")).unwrap();
    fs::write(
        dir.join("hooks").join("my-hook.sh"),
        b"#!/usr/bin/env bash\necho hi\n",
    )
    .unwrap();
    fs::write(
        dir.join("vstack.toml"),
        "[hook-events]\n\"PostToolUse:Edit|Write\" = [\"engineer\"]\n",
    )
    .unwrap();

    let entry = LockEntry {
        name: "my-hook".to_string(),
        kind: ItemKind::Hook,
        source: dir.display().to_string(),
        source_repo: None,
        harnesses: vec!["claude-code".to_string()],
        method: InstallMethod::Symlink,
        installed_at: "2026-05-09T00:00:00Z".to_string(),
        source_hash: String::new(),
    };
    let h1 = compute_source_hash(&entry);

    // Re-target the hook without touching the .sh file.
    fs::write(
        dir.join("vstack.toml"),
        "[hook-events]\n\"PostToolUse:Edit|Write\" = \"all\"\n",
    )
    .unwrap();
    let h2 = compute_source_hash(&entry);

    assert_ne!(
        h1, h2,
        "changing [hook-events] role list must invalidate hook source hash"
    );
    let _ = fs::remove_dir_all(&dir);
}

fn test_hook_script(name: &str, body: &str) -> String {
    test_hook_script_with_event(name, "PreToolUse", body)
}

fn test_hook_script_with_event(name: &str, event: &str, body: &str) -> String {
    test_hook_script_with_meta(name, event, "Bash", "test hook", body)
}

fn test_hook_script_with_meta(
    name: &str,
    event: &str,
    matcher: &str,
    description: &str,
    body: &str,
) -> String {
    format!(
        "# ---
# name: {name}
# event: {event}
# matcher: {matcher}
# description: {description}
# ---
#!/usr/bin/env bash
{body}
"
    )
}

#[test]
fn scan_installed_hooks_on_disk_detects_concrete_project_artifacts() {
    let dir = sandbox("hook_scan_artifacts");
    let source = dir.join("source");
    let project = dir.join("project");
    fs::create_dir_all(source.join("hooks")).unwrap();
    let script = test_hook_script("my-hook", "echo source");
    let source_hook_path = source.join("hooks").join("my-hook.sh");
    fs::write(&source_hook_path, &script).unwrap();
    let hook = crate::hook::Hook::from_file(&source_hook_path).unwrap();

    fs::create_dir_all(project.join(".claude").join("hooks")).unwrap();
    fs::write(project.join(".claude/hooks/my-hook.sh"), &script).unwrap();
    fs::create_dir_all(project.join(".cursor").join("rules")).unwrap();
    fs::write(
        project.join(".cursor/rules/safety-my-hook.mdc"),
        crate::installer::cursor_hook_rule_contents(&hook),
    )
    .unwrap();
    fs::create_dir_all(project.join(".codex").join("hooks")).unwrap();
    fs::write(project.join(".codex/hooks/my-hook.sh"), &script).unwrap();
    fs::create_dir_all(project.join(".opencode").join("instructions")).unwrap();
    fs::write(
        project.join(".opencode/instructions/vstack-hook-my-hook.md"),
        crate::installer::opencode_hook_instruction_contents(&hook),
    )
    .unwrap();

    let items = scan_installed_hooks_on_disk_at(&project, false, &source.display().to_string());

    assert_eq!(items.len(), 1);
    assert_eq!(items[0].name, "my-hook");
    let mut harnesses = items[0].harnesses.clone();
    harnesses.sort();
    assert_eq!(
        harnesses,
        vec![
            "claude-code".to_string(),
            "codex".to_string(),
            "cursor".to_string(),
            "opencode".to_string()
        ]
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_hook_lock_entries_sets_empty_hash_for_refresh_summary() {
    let dir = sandbox("hook_recover_lock");
    let source = dir.join("source");
    let project = dir.join("project");
    fs::create_dir_all(source.join("hooks")).unwrap();
    let script = test_hook_script("my-hook", "echo source");
    fs::write(source.join("hooks").join("my-hook.sh"), &script).unwrap();
    fs::create_dir_all(project.join(".claude").join("hooks")).unwrap();
    fs::write(project.join(".claude/hooks/my-hook.sh"), &script).unwrap();
    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };

    let modified = recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
    );

    assert!(modified);
    let entry = lock.entries.get("my-hook").unwrap();
    assert_eq!(entry.kind, ItemKind::Hook);
    assert_eq!(entry.harnesses, vec!["claude-code".to_string()]);
    assert_eq!(entry.method, InstallMethod::Copy);
    assert!(
        entry.source_hash.is_empty(),
        "refresh should count recovered hooks as updated after reinstall"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_existing_hook_uses_lock_entry_source_identity_not_reconciliation_hint() {
    let dir = sandbox("hook_recover_existing_source_identity");
    let selected_source = dir.join("selected-source");
    let recorded_source = dir.join("recorded-source");
    let project = dir.join("project");
    fs::create_dir_all(selected_source.join("hooks")).unwrap();
    fs::create_dir_all(&recorded_source).unwrap();
    init_git_origin(
        &selected_source,
        "git@github.com:vanillagreencom/vstack.git",
    );
    init_git_origin(
        &recorded_source,
        "https://github.com/example/project-assets.git",
    );
    let script = test_hook_script("my-hook", "echo source");
    fs::write(selected_source.join("hooks/my-hook.sh"), &script).unwrap();
    fs::create_dir_all(project.join(".claude/hooks")).unwrap();
    fs::write(project.join(".claude/hooks/my-hook.sh"), &script).unwrap();

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "my-hook".to_string(),
        kind: ItemKind::Hook,
        source: recorded_source.display().to_string(),
        source_repo: None,
        harnesses: vec!["claude-code".to_string()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-21T00:00:00Z".to_string(),
        source_hash: String::new(),
    });

    assert!(recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &selected_source.display().to_string(),
        "2026-07-22T00:00:00Z",
    ));
    assert_eq!(
        lock.entries
            .get("my-hook")
            .and_then(|entry| entry.source_repo.as_deref()),
        Some("example/project-assets")
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_existing_hook_replaces_stale_source_identity_from_live_source() {
    let dir = sandbox("hook_recover_replaces_stale_identity");
    let selected_source = dir.join("selected-source");
    let recorded_source = dir.join("recorded-source");
    let project = dir.join("project");
    fs::create_dir_all(selected_source.join("hooks")).unwrap();
    fs::create_dir_all(&recorded_source).unwrap();
    init_git_origin(
        &recorded_source,
        "https://github.com/example/project-assets.git",
    );
    let script = test_hook_script("my-hook", "echo source");
    fs::write(selected_source.join("hooks/my-hook.sh"), &script).unwrap();
    fs::create_dir_all(project.join(".claude/hooks")).unwrap();
    fs::write(project.join(".claude/hooks/my-hook.sh"), &script).unwrap();

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "my-hook".to_string(),
        kind: ItemKind::Hook,
        source: recorded_source.display().to_string(),
        source_repo: Some("vanillagreencom/vstack".to_string()),
        harnesses: vec!["claude-code".to_string()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-21T00:00:00Z".to_string(),
        source_hash: String::new(),
    });

    assert!(recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &selected_source.display().to_string(),
        "2026-07-22T00:00:00Z",
    ));
    assert_eq!(
        lock.entries
            .get("my-hook")
            .and_then(|entry| entry.source_repo.as_deref()),
        Some("example/project-assets")
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_existing_hook_clears_stale_identity_for_live_source_without_origin() {
    let dir = sandbox("hook_recover_clears_stale_identity");
    let selected_source = dir.join("selected-source");
    let recorded_source = dir.join("recorded-source");
    let project = dir.join("project");
    fs::create_dir_all(selected_source.join("hooks")).unwrap();
    fs::create_dir_all(&recorded_source).unwrap();
    let script = test_hook_script("my-hook", "echo source");
    fs::write(selected_source.join("hooks/my-hook.sh"), &script).unwrap();
    fs::create_dir_all(project.join(".claude/hooks")).unwrap();
    fs::write(project.join(".claude/hooks/my-hook.sh"), &script).unwrap();

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "my-hook".to_string(),
        kind: ItemKind::Hook,
        source: recorded_source.display().to_string(),
        source_repo: Some("vanillagreencom/vstack".to_string()),
        harnesses: vec!["claude-code".to_string()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-21T00:00:00Z".to_string(),
        source_hash: String::new(),
    });

    assert!(recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &selected_source.display().to_string(),
        "2026-07-22T00:00:00Z",
    ));
    assert_eq!(lock.entries.get("my-hook").unwrap().source_repo, None);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_existing_hook_preserves_identity_when_recorded_source_is_unavailable() {
    let dir = sandbox("hook_recover_preserves_unavailable_identity");
    let selected_source = dir.join("selected-source");
    let missing_recorded_source = dir.join("missing-recorded-source");
    let project = dir.join("project");
    fs::create_dir_all(selected_source.join("hooks")).unwrap();
    let script = test_hook_script("my-hook", "echo source");
    fs::write(selected_source.join("hooks/my-hook.sh"), &script).unwrap();
    fs::create_dir_all(project.join(".claude/hooks")).unwrap();
    fs::write(project.join(".claude/hooks/my-hook.sh"), &script).unwrap();

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "my-hook".to_string(),
        kind: ItemKind::Hook,
        source: missing_recorded_source.display().to_string(),
        source_repo: Some("vanillagreencom/vstack".to_string()),
        harnesses: vec!["claude-code".to_string()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-21T00:00:00Z".to_string(),
        source_hash: String::new(),
    });

    assert!(!recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &selected_source.display().to_string(),
        "2026-07-22T00:00:00Z",
    ));
    assert_eq!(
        lock.entries
            .get("my-hook")
            .and_then(|entry| entry.source_repo.as_deref()),
        Some("vanillagreencom/vstack")
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_hook_lock_entries_recovers_stale_script_after_source_change() {
    let dir = sandbox("hook_recover_stale_script");
    let source = dir.join("source");
    let project = dir.join("project");
    fs::create_dir_all(source.join("hooks")).unwrap();
    fs::write(
        source.join("hooks").join("my-hook.sh"),
        test_hook_script("my-hook", "echo current source"),
    )
    .unwrap();
    fs::create_dir_all(project.join(".claude").join("hooks")).unwrap();
    fs::write(
        project.join(".claude/hooks/my-hook.sh"),
        test_hook_script("my-hook", "echo previously installed source"),
    )
    .unwrap();
    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };

    assert!(recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
    ));

    let entry = lock.entries.get("my-hook").unwrap();
    assert_eq!(entry.harnesses, vec!["claude-code".to_string()]);
    assert!(entry.source_hash.is_empty());
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_hook_lock_entries_skips_same_named_foreign_script() {
    let dir = sandbox("hook_recover_foreign");
    let source = dir.join("source");
    let project = dir.join("project");
    fs::create_dir_all(source.join("hooks")).unwrap();
    fs::write(
        source.join("hooks").join("my-hook.sh"),
        test_hook_script("my-hook", "echo source"),
    )
    .unwrap();
    fs::create_dir_all(project.join(".claude").join("hooks")).unwrap();
    fs::write(
        project.join(".claude/hooks/my-hook.sh"),
        "#!/usr/bin/env bash
echo foreign
",
    )
    .unwrap();
    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };

    let modified = recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
    );

    assert!(!modified);
    assert!(!lock.entries.contains_key("my-hook"));
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_hook_lock_entries_recovers_cursor_rule_only() {
    let dir = sandbox("hook_recover_cursor");
    let source = dir.join("source");
    let project = dir.join("project");
    fs::create_dir_all(source.join("hooks")).unwrap();
    let source_hook_path = source.join("hooks").join("cursor-hook.sh");
    fs::write(
        &source_hook_path,
        test_hook_script("cursor-hook", "echo source"),
    )
    .unwrap();
    let hook = crate::hook::Hook::from_file(&source_hook_path).unwrap();
    fs::create_dir_all(project.join(".cursor").join("rules")).unwrap();
    fs::write(
        project.join(".cursor/rules/safety-cursor-hook.mdc"),
        crate::installer::cursor_hook_rule_contents(&hook),
    )
    .unwrap();
    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };

    assert!(recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
    ));

    let entry = lock.entries.get("cursor-hook").unwrap();
    assert_eq!(entry.harnesses, vec!["cursor".to_string()]);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_hook_lock_entries_ignores_cursor_rule_for_global_scope() {
    let dir = sandbox("hook_recover_cursor_global");
    let source = dir.join("source");
    let project = dir.join("project");
    let cursor_global_rules_dir = dir.join("global-cursor").join("rules");
    fs::create_dir_all(source.join("hooks")).unwrap();
    let source_hook_path = source.join("hooks").join("cursor-hook.sh");
    fs::write(
        &source_hook_path,
        test_hook_script("cursor-hook", "echo source"),
    )
    .unwrap();
    let hook = crate::hook::Hook::from_file(&source_hook_path).unwrap();
    fs::create_dir_all(&cursor_global_rules_dir).unwrap();
    fs::write(
        cursor_global_rules_dir.join("safety-cursor-hook.mdc"),
        crate::installer::cursor_hook_rule_contents(&hook),
    )
    .unwrap();
    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };
    let modified = recover_hook_lock_entries_at_with_cursor_global_rules(
        &mut lock,
        &project,
        true,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
        &cursor_global_rules_dir,
    );

    assert!(
        !modified,
        "global recovery must not record project-only Cursor hooks"
    );
    assert!(
        !lock.entries.contains_key("cursor-hook"),
        "Cursor must be absent from global hook lock recovery"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_hook_lock_entries_recovers_codex_prose_fallback_only() {
    let dir = sandbox("hook_recover_codex_prose");
    let source = dir.join("source");
    let project = dir.join("project");
    fs::create_dir_all(source.join("hooks")).unwrap();
    let source_hook_path = source.join("hooks").join("prose-hook.sh");
    fs::write(
        &source_hook_path,
        test_hook_script_with_event("prose-hook", "TaskCompleted", "echo source"),
    )
    .unwrap();
    let hook = crate::hook::Hook::from_file(&source_hook_path).unwrap();
    fs::create_dir_all(project.join(".codex").join("agents")).unwrap();
    fs::write(
        project.join(".codex/agents/rust.toml"),
        format!(
            "developer_instructions = '''
{}
'''
",
            crate::installer::codex_hook_safety_block(&hook)
        ),
    )
    .unwrap();
    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };

    assert!(recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
    ));

    let entry = lock.entries.get("prose-hook").unwrap();
    assert_eq!(entry.harnesses, vec!["codex".to_string()]);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_hook_lock_entries_recovers_stale_generated_text_after_source_change() {
    let dir = sandbox("hook_recover_stale_text");
    let source = dir.join("source");
    let project = dir.join("project");
    let hooks_dir = source.join("hooks");
    fs::create_dir_all(&hooks_dir).unwrap();

    fs::write(
        hooks_dir.join("text-hook.sh"),
        test_hook_script_with_meta(
            "text-hook",
            "PreToolUse",
            "Bash",
            "current description",
            "echo current",
        ),
    )
    .unwrap();
    let old_text_hook_path = dir.join("old-text-hook.sh");
    fs::write(
        &old_text_hook_path,
        test_hook_script_with_meta(
            "text-hook",
            "PreToolUse",
            "Bash",
            "previous description",
            "echo previous",
        ),
    )
    .unwrap();
    let old_text_hook = crate::hook::Hook::from_file(&old_text_hook_path).unwrap();

    fs::write(
        hooks_dir.join("prose-hook.sh"),
        test_hook_script_with_meta(
            "prose-hook",
            "TaskCompleted",
            "Bash",
            "current description",
            "echo current",
        ),
    )
    .unwrap();
    let old_prose_hook_path = dir.join("old-prose-hook.sh");
    fs::write(
        &old_prose_hook_path,
        test_hook_script_with_meta(
            "prose-hook",
            "TaskCompleted",
            "Bash",
            "previous description",
            "echo previous",
        ),
    )
    .unwrap();
    let old_prose_hook = crate::hook::Hook::from_file(&old_prose_hook_path).unwrap();

    fs::create_dir_all(project.join(".cursor/rules")).unwrap();
    fs::write(
        project.join(".cursor/rules/safety-text-hook.mdc"),
        crate::installer::cursor_hook_rule_contents(&old_text_hook),
    )
    .unwrap();
    fs::create_dir_all(project.join(".opencode/instructions")).unwrap();
    fs::write(
        project.join(".opencode/instructions/vstack-hook-text-hook.md"),
        crate::installer::opencode_hook_instruction_contents(&old_text_hook),
    )
    .unwrap();
    fs::create_dir_all(project.join(".codex/agents")).unwrap();
    fs::write(
        project.join(".codex/agents/rust.toml"),
        format!(
            "developer_instructions = '''
{}
'''
",
            crate::installer::codex_hook_safety_block(&old_prose_hook)
        ),
    )
    .unwrap();

    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };
    assert!(recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
    ));

    let text_entry = lock.entries.get("text-hook").unwrap();
    assert_eq!(
        text_entry.harnesses,
        vec!["cursor".to_string(), "opencode".to_string()]
    );
    let prose_entry = lock.entries.get("prose-hook").unwrap();
    assert_eq!(prose_entry.harnesses, vec!["codex".to_string()]);
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_hook_lock_entries_rejects_same_named_foreign_generated_text() {
    let dir = sandbox("hook_recover_foreign_text");
    let source = dir.join("source");
    let project = dir.join("project");
    let hooks_dir = source.join("hooks");
    fs::create_dir_all(&hooks_dir).unwrap();

    fs::write(
        hooks_dir.join("text-hook.sh"),
        test_hook_script_with_meta(
            "text-hook",
            "PreToolUse",
            "Bash",
            "source description",
            "echo source",
        ),
    )
    .unwrap();
    let foreign_text_hook_path = dir.join("foreign-text-hook.sh");
    fs::write(
        &foreign_text_hook_path,
        test_hook_script_with_meta(
            "text-hook",
            "PostToolUse",
            "Edit|Write",
            "source description",
            "echo foreign",
        ),
    )
    .unwrap();
    let foreign_text_hook = crate::hook::Hook::from_file(&foreign_text_hook_path).unwrap();

    fs::write(
        hooks_dir.join("prose-hook.sh"),
        test_hook_script_with_meta(
            "prose-hook",
            "TaskCompleted",
            "Bash",
            "source description",
            "echo source",
        ),
    )
    .unwrap();
    let foreign_prose_hook_path = dir.join("foreign-prose-hook.sh");
    fs::write(
        &foreign_prose_hook_path,
        test_hook_script_with_meta(
            "prose-hook",
            "PreToolUse",
            "Bash",
            "source description",
            "echo foreign",
        ),
    )
    .unwrap();
    let foreign_prose_hook = crate::hook::Hook::from_file(&foreign_prose_hook_path).unwrap();

    fs::create_dir_all(project.join(".cursor/rules")).unwrap();
    fs::write(
        project.join(".cursor/rules/safety-text-hook.mdc"),
        crate::installer::cursor_hook_rule_contents(&foreign_text_hook),
    )
    .unwrap();
    fs::create_dir_all(project.join(".opencode/instructions")).unwrap();
    fs::write(
        project.join(".opencode/instructions/vstack-hook-text-hook.md"),
        crate::installer::opencode_hook_instruction_contents(&foreign_text_hook),
    )
    .unwrap();
    fs::create_dir_all(project.join(".codex/agents")).unwrap();
    fs::write(
        project.join(".codex/agents/rust.toml"),
        format!(
            "developer_instructions = '''
{}
'''
",
            crate::installer::codex_hook_safety_block(&foreign_prose_hook)
        ),
    )
    .unwrap();

    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };
    assert!(!recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
    ));
    assert!(lock.entries.is_empty());
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn recover_hook_lock_entries_codex_prose_requires_exact_header_line() {
    let dir = sandbox("hook_recover_codex_prefix");
    let source = dir.join("source");
    let project = dir.join("project");
    let hooks_dir = source.join("hooks");
    fs::create_dir_all(&hooks_dir).unwrap();
    fs::write(
        hooks_dir.join("foo.sh"),
        test_hook_script_with_event("foo", "TaskCompleted", "echo foo"),
    )
    .unwrap();
    let foo_bar_path = hooks_dir.join("foo-bar.sh");
    fs::write(
        &foo_bar_path,
        test_hook_script_with_event("foo-bar", "TaskCompleted", "echo foo-bar"),
    )
    .unwrap();
    let foo_bar_hook = crate::hook::Hook::from_file(&foo_bar_path).unwrap();

    fs::create_dir_all(project.join(".codex/agents")).unwrap();
    fs::write(
        project.join(".codex/agents/rust.toml"),
        format!(
            "developer_instructions = '''
{}
'''
",
            crate::installer::codex_hook_safety_block(&foo_bar_hook)
        ),
    )
    .unwrap();

    let mut lock = LockFile {
        version: 1,
        entries: std::collections::BTreeMap::new(),
        settings_seeds: std::collections::BTreeMap::new(),
    };
    assert!(recover_hook_lock_entries_at(
        &mut lock,
        &project,
        false,
        &source.display().to_string(),
        "2026-06-07T00:00:00Z",
    ));

    assert!(!lock.entries.contains_key("foo"));
    assert_eq!(
        lock.entries.get("foo-bar").unwrap().harnesses,
        vec!["codex".to_string()]
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn hash_dir_bytes_skips_unreadable_files_atomically() {
    // Build two trees: A has files (a, b). B has the same files plus a
    // third file (c) we'll make unreadable. Hashing B with c unreadable
    // must equal hashing A — i.e. an unreadable file must contribute
    // nothing, including no relpath bytes.
    let dir = sandbox("hash_dir_unreadable");
    let a = dir.join("a");
    let b = dir.join("b");
    fs::create_dir_all(&a).unwrap();
    fs::create_dir_all(&b).unwrap();
    fs::write(a.join("one.txt"), b"one").unwrap();
    fs::write(a.join("two.txt"), b"two").unwrap();
    fs::write(b.join("one.txt"), b"one").unwrap();
    fs::write(b.join("two.txt"), b"two").unwrap();
    let extra = b.join("three.txt");
    fs::write(&extra, b"three").unwrap();

    let hash_a = hash_dir_bytes(&a);
    // Sanity: with all files readable, hashes diverge.
    let hash_b_full = hash_dir_bytes(&b);
    assert_ne!(hash_a, hash_b_full);

    // Unreadable on Unix: chmod 000. Skip the assertion if we couldn't
    // strip read permission (e.g. running as root).
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        fs::set_permissions(&extra, fs::Permissions::from_mode(0o000)).unwrap();
        let readable = fs::read(&extra).is_ok();
        if !readable {
            let hash_b_partial = hash_dir_bytes(&b);
            // Restore so cleanup can run.
            let _ = fs::set_permissions(&extra, fs::Permissions::from_mode(0o644));
            assert_eq!(
                hash_a, hash_b_partial,
                "unreadable file must contribute neither relpath nor content bytes"
            );
        } else {
            let _ = fs::set_permissions(&extra, fs::Permissions::from_mode(0o644));
        }
    }
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn is_temporary_local_path_catches_nonexistent_temp_paths() {
    // Use the actual temp_dir() so the test works on whatever OS we run
    // on. Append a path component that we never create on disk.
    let temp = std::env::temp_dir();
    let phantom = temp.join("vstack-phantom-never-created-xyz123");
    assert!(
        !phantom.exists(),
        "precondition: phantom path must not exist"
    );

    assert!(
        is_temporary_local_path(&phantom.display().to_string()),
        "non-existent path under temp_dir must still be flagged temporary"
    );
}

#[test]
fn is_temporary_local_path_handles_tmp_private_tmp_aliasing() {
    // On macOS /tmp is a symlink to /private/tmp; on Linux they are
    // distinct dirs (but generally /tmp is the temp dir). We only
    // assert the positive direction: paths under /tmp are temp.
    if std::env::temp_dir() == Path::new("/tmp") || std::env::temp_dir().starts_with("/private/tmp")
    {
        assert!(is_temporary_local_path("/tmp/vstack-install-foo"));
    }
}

#[cfg(unix)]
#[test]
fn prunes_broken_generated_skill_symlinks_only() {
    use std::os::unix::fs::symlink;

    let dir = sandbox("prune_broken_skill_symlinks");
    let claude_skills = dir.join(".claude").join("skills");
    let managed_root = dir.join(".agents").join("skills");
    fs::create_dir_all(&claude_skills).unwrap();
    fs::create_dir_all(&managed_root).unwrap();

    let broken_managed = claude_skills.join("agent-browser");
    symlink("../../.agents/skills/agent-browser", &broken_managed).unwrap();

    let external_broken = claude_skills.join("external");
    symlink("../../not-vstack/skills/external", &external_broken).unwrap();

    fs::create_dir_all(managed_root.join("github")).unwrap();
    let live_managed = claude_skills.join("github");
    symlink("../../.agents/skills/github", &live_managed).unwrap();

    let modified = prune_broken_skill_symlinks_in_dirs(&[claude_skills], &[managed_root]);

    assert!(modified, "broken generated symlink should be pruned");
    assert!(
        !broken_managed.is_symlink(),
        "stale .claude/skills symlink to missing .agents/skills target must be removed"
    );
    assert!(
        external_broken.is_symlink(),
        "non-vstack broken symlinks must be left alone"
    );
    assert!(
        live_managed.is_symlink() && live_managed.exists(),
        "live generated symlinks must be preserved"
    );

    let _ = fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn migrates_copy_skill_lock_entry_when_existing_mirror_is_managed_symlink() {
    use std::os::unix::fs::symlink;

    let dir = sandbox("migrate_copy_skill_lock_symlink_mirror");
    let claude_skills = dir.join(".claude").join("skills");
    let managed_root = dir.join(".agents").join("skills");
    fs::create_dir_all(&claude_skills).unwrap();
    fs::create_dir_all(managed_root.join("reviewer")).unwrap();
    symlink(
        "../../.agents/skills/reviewer",
        claude_skills.join("reviewer"),
    )
    .unwrap();

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "reviewer".into(),
        kind: ItemKind::Skill,
        source: "source".into(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });

    let modified = migrate_copy_skill_lock_entries_with_symlink_mirrors(
        &mut lock,
        &[("claude-code".into(), claude_skills)],
        &[managed_root],
    );

    assert!(modified, "copy lock should migrate for managed symlink");
    let entry = lock.entries.get("reviewer").unwrap();
    assert_eq!(entry.method, InstallMethod::Symlink);
    assert!(
        !entry.source_hash.is_empty(),
        "migration must refresh source hash"
    );

    let _ = fs::remove_dir_all(&dir);
}

#[cfg(unix)]
#[test]
fn leaves_copy_skill_lock_entry_for_external_symlink() {
    use std::os::unix::fs::symlink;

    let dir = sandbox("migrate_copy_skill_lock_external_symlink");
    let claude_skills = dir.join(".claude").join("skills");
    let managed_root = dir.join(".agents").join("skills");
    let external_root = dir.join("external").join("skills");
    fs::create_dir_all(&claude_skills).unwrap();
    fs::create_dir_all(external_root.join("reviewer")).unwrap();
    symlink(
        "../../external/skills/reviewer",
        claude_skills.join("reviewer"),
    )
    .unwrap();

    let mut lock = LockFile::default();
    lock.add(LockEntry {
        name: "reviewer".into(),
        kind: ItemKind::Skill,
        source: "source".into(),
        source_repo: None,
        harnesses: vec!["claude-code".into()],
        method: InstallMethod::Copy,
        installed_at: "2026-07-03T00:00:00Z".into(),
        source_hash: String::new(),
    });

    let modified = migrate_copy_skill_lock_entries_with_symlink_mirrors(
        &mut lock,
        &[("claude-code".into(), claude_skills)],
        &[managed_root],
    );

    assert!(!modified, "external symlink must not migrate lock mode");
    assert_eq!(
        lock.entries.get("reviewer").unwrap().method,
        InstallMethod::Copy
    );

    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn reconcile_does_not_attribute_orphaned_skill_to_source_hint() {
    let dir = sandbox("reconcile_orphaned_skill_identity");
    let project = dir.join("project");
    let source = dir.join("source");
    fs::create_dir_all(project.join(".agents/skills/third-party")).unwrap();
    fs::write(
        project.join(".agents/skills/third-party/.vstack-refreshed"),
        "managed\n",
    )
    .unwrap();
    fs::create_dir_all(source.join("skills/third-party")).unwrap();
    fs::write(
        source.join("skills/third-party/SKILL.md"),
        "# Third party\n",
    )
    .unwrap();
    init_git_origin(&source, "git@github.com:vanillagreencom/vstack.git");

    let recovered = crate::test_util::with_project_root(&project, || {
        let mut lock = LockFile::default();
        assert!(reconcile_lock_with_disk(
            &mut lock,
            false,
            &source.display().to_string(),
        ));
        lock.entries.get("third-party").cloned()
    })
    .expect("orphaned managed skill should regain a lock entry");

    assert_eq!(recovered.source, source.display().to_string());
    assert_eq!(
        recovered.source_repo, None,
        "the reconciliation source hint is not proof of orphan ownership"
    );
    let _ = fs::remove_dir_all(&dir);
}

#[test]
fn reconcile_recovers_pi_extensions_present_on_disk_missing_from_lock() {
    // Drive reconciliation through a sandbox PI_CODING_AGENT_DIR. We
    // populate the source index plus a fake installed package, leave
    // the lock empty, and verify reconcile re-adds the lock entry.
    let dir = sandbox("reconcile_recovers_pi");
    let pi_dir = dir.join("pi-agent");
    fs::create_dir_all(&pi_dir).unwrap();
    let pkg_root = pi_dir.join("packages").join("@vanillagreen");
    let installed_pkg = pkg_root.join("pi-foo");
    fs::create_dir_all(&installed_pkg).unwrap();
    fs::write(
        installed_pkg.join("package.json"),
        r#"{"name":"@vanillagreen/pi-foo","version":"1.0.0"}"#,
    )
    .unwrap();

    // Source repo with a matching pi-extension dir so compute_source_hash succeeds.
    let source_repo = dir.join("source-repo");
    let src_pkg = source_repo.join("pi-extensions").join("pi-foo");
    fs::create_dir_all(&src_pkg).unwrap();
    fs::write(
        src_pkg.join("package.json"),
        r#"{"name":"@vanillagreen/pi-foo","version":"1.0.0"}"#,
    )
    .unwrap();

    // Source index pointing at the source repo.
    let index_path = pi_dir.join(".vstack-source.json");
    let index_json = serde_json::json!({
        "@vanillagreen/pi-foo": {
            "sourceRepo": source_repo.display().to_string(),
            "sourcePath": src_pkg.display().to_string(),
            "sourceVersion": "1.0.0"
        }
    });
    fs::write(&index_path, index_json.to_string()).unwrap();

    // Redirect global pi dir to the sandbox via the shared lock so we
    // don't race other PI_CODING_AGENT_DIR-mutating tests.
    let (modified, recovered) = crate::test_util::with_pi_dir(&pi_dir, || {
        let mut lock = LockFile {
            version: 1,
            ..Default::default()
        };
        let modified =
            reconcile_lock_with_disk(&mut lock, true, &source_repo.display().to_string());
        let recovered = lock.entries.get("@vanillagreen/pi-foo").cloned();
        (modified, recovered)
    });

    assert!(modified, "reconcile must report modification");
    let recovered = recovered.expect("pi extension lock entry must be re-added");
    assert_eq!(recovered.kind, ItemKind::PiExtension);
    assert_eq!(recovered.source, source_repo.display().to_string());
    assert!(
        !recovered.source_hash.is_empty(),
        "recovered entry must carry a source hash"
    );
    let _ = fs::remove_dir_all(&dir);
}

/// A directory that merely SITS INSIDE a repository is not that
/// repository: answering with the enclosing origin stamps the wrong
/// `source_repo` into the lock, and `vstack report` then files issues
/// against a repo that has nothing to do with the source.
#[test]
fn a_directory_inside_a_repository_does_not_inherit_that_repositorys_identity() {
    let root = sandbox("identity");
    let git = |args: &[&str], dir: &Path| {
        std::process::Command::new("git")
            .args(args)
            .current_dir(dir)
            .env("GIT_CONFIG_GLOBAL", "/dev/null")
            .env("GIT_CONFIG_SYSTEM", "/dev/null")
            .stdout(std::process::Stdio::null())
            .stderr(std::process::Stdio::null())
            .status()
            .map(|status| status.success())
            .unwrap_or(false)
    };
    assert!(
        git(&["init", "-q", "-b", "main", "."], &root),
        "git is required to run this regression test"
    );
    assert!(git(
        &[
            "remote",
            "add",
            "origin",
            "https://github.com/enclosing/repo.git"
        ],
        &root
    ));
    // Control: the repository root itself DOES have that identity.
    assert_eq!(
        source_repo_from_git_origin(&root),
        Some("enclosing/repo".to_string())
    );
    let inner = root.join("sources").join("local-source");
    std::fs::create_dir_all(&inner).unwrap();
    assert_eq!(
        source_repo_from_git_origin(&inner),
        None,
        "a plain subdirectory must not borrow the enclosing repository"
    );
    let _ = std::fs::remove_dir_all(&root);
}
