use super::*;
use crate::env::FakeOs;
use crate::model::HarnessId;
use std::collections::BTreeMap;
use std::fs;

/// One fixture home exercising every adapter: claude agent + skill +
/// hooks + mcp, codex agent + a prompt file Codex no longer reads, opencode mcp with a disabled
/// entry, pi package, and a registered project with a shared skill tree.
#[test]
fn scans_a_realistic_machine() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let env = Env::fake(home, FakeOs::Linux);

    fs::create_dir_all(home.join(".claude/agents")).unwrap();
    fs::write(
        home.join(".claude/agents/orch.md"),
        "---\ndescription: boss\n---\n",
    )
    .unwrap();
    fs::create_dir_all(home.join(".claude/skills/github")).unwrap();
    fs::write(home.join(".claude/skills/github/SKILL.md"), "# gh").unwrap();
    fs::write(
            home.join(".claude/settings.json"),
            r#"{"hooks":{"PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"bash guard.sh"}]}]}}"#,
        )
        .unwrap();
    fs::write(
        home.join(".claude.json"),
        r#"{"mcpServers":{"github":{"command":"gh-mcp"}}}"#,
    )
    .unwrap();

    fs::create_dir_all(home.join(".codex/agents")).unwrap();
    fs::write(
        home.join(".codex/agents/rust.toml"),
        "description = \"rust dev\"\n",
    )
    .unwrap();
    fs::create_dir_all(home.join(".codex/prompts")).unwrap();
    fs::write(home.join(".codex/prompts/ship.md"), "ship it").unwrap();

    fs::create_dir_all(home.join(".config/opencode")).unwrap();
    fs::write(
        home.join(".config/opencode/opencode.json"),
        r#"{"mcp":{"db":{"type":"local","enabled":false,"command":["db"]}}}"#,
    )
    .unwrap();

    fs::create_dir_all(home.join(".pi/agent")).unwrap();
    fs::write(
        home.join(".pi/agent/settings.json"),
        r#"{"packages":["npm:@vanillagreen/pi-hooks@1.2.0","./packages/pi-tmux"]}"#,
    )
    .unwrap();

    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".agents/skills/deploy")).unwrap();
    fs::write(project.join(".agents/skills/deploy/SKILL.md"), "# d").unwrap();

    let mut settings = AppSettings::default();
    settings.projects.push(project.clone());
    settings.projects.push(home.join("dev/vanished"));

    let result = scan(&env, &settings);

    assert_eq!(result.warnings, Vec::new());
    assert_eq!(
        result.missing_projects,
        [MissingProject {
            root: home.join("dev/vanished"),
            why: MissingWhy::Gone
        }]
    );
    // The other half, and the one anything may rest on: the folders this
    // scan opened. A project registered after it ran is in neither list,
    // which is what absence from the first cannot say.
    assert_eq!(result.read_projects, std::slice::from_ref(&project));

    let detected: Vec<_> = result.harnesses.iter().map(|h| h.harness).collect();
    assert_eq!(
        detected,
        [
            HarnessId::Claude,
            HarnessId::Codex,
            HarnessId::Opencode,
            HarnessId::Pi
        ]
    );

    let find = |kind: ItemKind, name: &str| {
        result
            .items
            .iter()
            .filter(|i| i.kind == kind && i.name == name)
            .collect::<Vec<_>>()
    };

    let agent = find(ItemKind::Agent, "orch");
    assert_eq!(agent.len(), 1);
    assert_eq!(agent[0].summary.as_deref(), Some("boss"));

    assert_eq!(find(ItemKind::Skill, "github").len(), 1);
    assert_eq!(find(ItemKind::Hook, "PreToolUse:Bash:guard").len(), 1);
    assert_eq!(find(ItemKind::McpServer, "github").len(), 1);
    assert_eq!(
        find(ItemKind::Agent, "rust")[0].summary.as_deref(),
        Some("rust dev")
    );
    // Codex removed custom prompts in 0.118; the file is nobody's command.
    assert_eq!(find(ItemKind::Command, "ship").len(), 0);

    let db = find(ItemKind::McpServer, "db");
    assert_eq!(db[0].enabled, Some(false));

    assert_eq!(
        find(ItemKind::PiExtension, "@vanillagreen/pi-hooks").len(),
        1
    );
    assert_eq!(find(ItemKind::PiExtension, "pi-tmux").len(), 1);

    // The shared .agents/skills tree surfaces once per harness that reads
    // it — every one but Claude Code — always at the same path.
    let deploy = find(ItemKind::Skill, "deploy");
    assert_eq!(deploy.len(), 7);
    assert!(deploy.iter().all(|item| item.path == deploy[0].path));
    let harnesses: Vec<_> = deploy.iter().map(|i| i.harness).collect();
    assert!(harnesses.contains(&HarnessId::Codex) && harnesses.contains(&HarnessId::Pi));
    assert!(!harnesses.contains(&HarnessId::Claude));
}

/// Gemini and Copilot installations are read the same way as everyone
/// else's — and Copilot's reach into `.claude/` never becomes a second
/// installation of a file that already belongs to Claude Code.
#[test]
fn sees_gemini_and_copilot_without_double_counting_claude_files() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let env = Env::fake(home, FakeOs::Linux);

    fs::create_dir_all(home.join(".gemini/agents")).unwrap();
    fs::write(
        home.join(".gemini/agents/plan.md"),
        "---\ndescription: planner\n---\n",
    )
    .unwrap();
    fs::write(
        home.join(".gemini/settings.json"),
        r#"{"mcpServers":{"docs":{"httpUrl":"https://docs.example"}},
                "hooks":{"BeforeTool":[{"matcher":"run_shell_command",
                "hooks":[{"type":"command","command":"bash audit.sh"}]}]}}"#,
    )
    .unwrap();
    fs::create_dir_all(home.join(".gemini/extensions/security")).unwrap();
    fs::write(
        home.join(".gemini/extensions/security/gemini-extension.json"),
        r#"{"name":"security"}"#,
    )
    .unwrap();

    fs::create_dir_all(home.join(".copilot/agents")).unwrap();
    fs::write(home.join(".copilot/agents/review.agent.md"), "---\n---\n").unwrap();

    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".github/skills/deploy")).unwrap();
    fs::write(project.join(".github/skills/deploy/SKILL.md"), "# d").unwrap();
    fs::create_dir_all(project.join(".claude/skills/private")).unwrap();
    fs::write(project.join(".claude/skills/private/SKILL.md"), "# p").unwrap();

    let mut settings = AppSettings::default();
    settings.projects.push(project.clone());
    let result = scan(&env, &settings);

    assert_eq!(result.warnings, Vec::new());
    let detected: Vec<_> = result.harnesses.iter().map(|h| h.harness).collect();
    assert!(detected.contains(&HarnessId::Gemini) && detected.contains(&HarnessId::Copilot));

    let of = |harness: HarnessId| {
        result
            .items
            .iter()
            .filter(|i| i.harness == harness)
            .map(|i| (i.kind, i.name.as_str()))
            .collect::<Vec<_>>()
    };
    assert_eq!(
        of(HarnessId::Gemini),
        [
            (ItemKind::Agent, "plan"),
            (ItemKind::Hook, "BeforeTool:run_shell_command:audit"),
            (ItemKind::McpServer, "docs"),
            (ItemKind::Plugin, "security"),
        ]
    );
    // The `.agent.md` pair is one extension, not part of the name; the
    // skill under `.claude/` stays Claude Code's alone.
    assert_eq!(
        of(HarnessId::Copilot),
        [(ItemKind::Agent, "review"), (ItemKind::Skill, "deploy")]
    );
}

/// The tags a file declares reach the scan result, and a word that is not a
/// tag reaches the warnings naming the file it was written in — without
/// either, an author gets no tags and no idea why.
#[test]
fn a_skill_s_tags_are_scanned_and_a_bad_one_is_reported() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let env = Env::fake(home, FakeOs::Linux);
    let skill = home.join(".claude/skills/reviewer");
    fs::create_dir_all(&skill).unwrap();
    fs::write(
        skill.join("SKILL.md"),
        "---\nname: reviewer\ntags: [review, tests]\n---\nbody\n",
    )
    .unwrap();

    let result = scan_scopes(&env, &BTreeMap::new(), &[Scope::Global]);

    let row = result
        .items
        .iter()
        .find(|item| item.name == "reviewer" && item.kind == ItemKind::Skill)
        .expect("the skill was not scanned");
    assert_eq!(row.tags, vec![crate::tags::Tag::Review]);
    let warning = result
        .warnings
        .iter()
        .find(|w| w.path == skill)
        .expect("nothing said the tag was wrong");
    assert_eq!(
        (warning.harness, warning.kind),
        (HarnessId::Claude, ItemKind::Skill)
    );
    let ScanProblem::UnknownTag { message } = &warning.problem else {
        panic!("{warning}");
    };
    assert!(message.contains("did you mean `testing`?"), "{warning}");
}

/// A structured surface that cannot be read says whose file it is and the
/// shape of what is wrong — an empty file and a malformed one are one
/// parser error and two remedies, so the scan tells them apart before
/// anything downstream words a remedy off the result.
#[test]
fn an_unreadable_config_names_its_tool_kind_path_and_problem_shape() {
    type Expect = Option<fn(&ScanProblem) -> bool>;
    let rows: [(&str, Expect); 4] = [
        ("", Some(|problem| *problem == ScanProblem::EmptyFile)),
        (
            "   \n// only a comment\n",
            Some(|problem| *problem == ScanProblem::EmptyFile),
        ),
        (
            "{\"mcpServers\": {",
            Some(|problem| matches!(problem, ScanProblem::InvalidJson { .. })),
        ),
        ("{\"mcpServers\": {}}", None),
    ];
    for (text, expected) in rows {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        let env = Env::fake(home, FakeOs::Linux);
        let config = home.join(".gemini/config/mcp_config.json");
        fs::create_dir_all(config.parent().unwrap()).unwrap();
        fs::write(&config, text).unwrap();

        let result = scan_scopes(&env, &BTreeMap::new(), &[Scope::Global]);

        let about = result.warnings.iter().find(|w| w.path == config);
        match (about, expected) {
            (Some(warning), Some(expected)) => {
                assert_eq!(
                    (warning.harness, warning.kind),
                    (HarnessId::Antigravity, ItemKind::McpServer),
                    "{text:?}: {warning}"
                );
                assert!(expected(&warning.problem), "{text:?}: {warning}");
            }
            (None, None) => {}
            (found, _) => panic!("{text:?}: {found:?}"),
        }
    }
}

/// The TOML surface has its own parser and its own shape: Codex's
/// config.toml that does not parse is said as invalid TOML, by Codex.
#[test]
fn a_malformed_toml_config_is_said_as_invalid_toml() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let env = Env::fake(home, FakeOs::Linux);
    let config = home.join(".codex/config.toml");
    fs::create_dir_all(config.parent().unwrap()).unwrap();
    fs::write(&config, "[mcp_servers\n").unwrap();

    let result = scan_scopes(&env, &BTreeMap::new(), &[Scope::Global]);

    let warning = result
        .warnings
        .iter()
        .find(|w| w.path == config)
        .expect("nothing said the file was malformed");
    assert_eq!(
        (warning.harness, warning.kind),
        (HarnessId::Codex, ItemKind::McpServer)
    );
    assert!(
        matches!(warning.problem, ScanProblem::InvalidToml { .. }),
        "{warning}"
    );
}

/// One skill, two spellings, one warning: a project's `.agents/skills`
/// tree is read by Codex and again by Claude through `.claude/skills`, a
/// link to it. A bad tag in that skill is one mistake, not one per tool.
#[cfg(unix)]
#[test]
fn a_skill_read_through_a_link_is_warned_about_once() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let env = Env::fake(home, FakeOs::Linux);
    let project = home.join("dev/app");
    let real = project.join(".agents/skills/reviewer");
    fs::create_dir_all(&real).unwrap();
    fs::write(
        real.join("SKILL.md"),
        "---\nname: reviewer\ntags: [tests]\n---\nbody\n",
    )
    .unwrap();
    let link = project.join(".claude/skills/reviewer");
    fs::create_dir_all(link.parent().unwrap()).unwrap();
    std::os::unix::fs::symlink("../../.agents/skills/reviewer", &link).unwrap();

    let result = scan_scopes(&env, &BTreeMap::new(), &[Scope::Project { root: project }]);

    // Both spellings were read — the dedupe is what leaves one warning,
    // not a scan that never followed the link.
    let spellings: Vec<_> = result
        .items
        .iter()
        .filter(|item| item.kind == ItemKind::Skill && item.name == "reviewer")
        .map(|item| item.path.clone())
        .collect();
    assert!(
        spellings.contains(&real) && spellings.contains(&link),
        "{spellings:?}"
    );
    let about: Vec<_> = result
        .warnings
        .iter()
        .filter(|w| matches!(w.problem, ScanProblem::UnknownTag { .. }))
        .collect();
    assert_eq!(about.len(), 1, "{about:?}");
    assert!(about[0].path == real || about[0].path == link, "{about:?}");
}

/// One file, several surfaces, one warning: Claude's settings.json is
/// read for hooks and again for plugins, and an empty one would otherwise
/// be said twice — two rows on Home and two units of the footer's count
/// for one file.
#[test]
fn a_file_two_surfaces_read_is_warned_about_once() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let env = Env::fake(home, FakeOs::Linux);
    let project = home.join("dev/app");
    let settings = project.join(".claude/settings.json");
    fs::create_dir_all(settings.parent().unwrap()).unwrap();
    fs::write(&settings, "").unwrap();

    let result = scan_scopes(&env, &BTreeMap::new(), &[Scope::Project { root: project }]);

    let about: Vec<_> = result
        .warnings
        .iter()
        .filter(|w| w.path == settings)
        .collect();
    assert_eq!(about.len(), 1, "{about:?}");
    assert_eq!(about[0].problem, ScanProblem::EmptyFile);
}

/// A pi package registered by a relative spec is a folder of its own, so it
/// can say what it is and when it changed. One registered by name is only a
/// line in a shared config file, and has neither.
#[test]
fn a_local_pi_package_reports_its_own_summary_and_mtime() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let env = Env::fake(home, FakeOs::Linux);

    let package = home.join(".pi/agent/packages/@vg/caveman");
    fs::create_dir_all(&package).unwrap();
    fs::write(
        package.join("package.json"),
        r#"{"description": "Caveman mode"}"#,
    )
    .unwrap();
    fs::write(
        home.join(".pi/agent/settings.json"),
        r#"{"packages":["./packages/@vg/caveman","npm:@vg/remote@1.0"]}"#,
    )
    .unwrap();

    let result = scan_scopes(&env, &BTreeMap::new(), &[Scope::Global]);
    let find = |name: &str| {
        result
            .items
            .iter()
            .find(|i| i.kind == ItemKind::PiExtension && i.name == name)
            .expect("the extension was not scanned")
    };

    let local = find("caveman");
    assert_eq!(local.summary.as_deref(), Some("Caveman mode"));
    assert_eq!(local.action.as_deref(), Some("./packages/@vg/caveman"));
    assert_eq!(local.path, package);
    assert!(local.modified_at.is_some(), "no mtime for a real folder");

    // A registry spec is where the package comes from, not a sentence
    // about it: the row says nothing rather than showing the locator.
    let remote = find("@vg/remote");
    assert_eq!(remote.summary, None);
    assert_eq!(remote.action.as_deref(), Some("npm:@vg/remote@1.0"));
    assert_eq!(remote.modified_at, None);
}

/// What stood in the way of reading a registered path as a folder, told
/// apart: a folder that is gone is reconnected to wherever it moved, a
/// path holding something else is neither, and a path the account cannot
/// read is read again once it can. One empty reading, three remedies.
#[test]
fn a_path_that_is_not_a_readable_folder_says_which_it_is() {
    let tmp = tempfile::tempdir().unwrap();
    let home = crate::test_util::rooted(&tmp);
    fs::create_dir_all(home.join("dev")).unwrap();
    fs::write(home.join("dev/file.txt"), "not a folder").unwrap();

    assert_eq!(missing_why(&home.join("dev")), None);
    assert_eq!(missing_why(&home.join("dev/gone")), Some(MissingWhy::Gone));
    assert_eq!(
        missing_why(&home.join("dev/file.txt")),
        Some(MissingWhy::NotAFolder)
    );
    // A component of the path is a file, so nothing can be opened at it.
    // Which of the three readings that is belongs to the platform, and
    // both are the system's own words: Unix fails the stat as "not a
    // directory", and Windows resolves the path first, so a file in the
    // way makes the path itself not found — which is what it is there.
    // Neither says a file stands at this path, and the card offers the
    // reading's own remedy either way.
    #[cfg(unix)]
    assert!(
        matches!(
            missing_why(&home.join("dev/file.txt/inside")),
            Some(MissingWhy::Unreadable { said }) if !said.is_empty()
        ),
        "a path that could not be read at all is neither gone nor a file"
    );
    #[cfg(windows)]
    assert_eq!(
        missing_why(&home.join("dev/file.txt/inside")),
        Some(MissingWhy::Gone)
    );

    // A folder the account may not open. It stats like any other, so a
    // reading that stopped at the stat would call this place readable and
    // report the empty scan of it as a project holding nothing.
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt as _;
        let sealed = home.join("dev/sealed");
        fs::create_dir_all(&sealed).unwrap();
        fs::set_permissions(&sealed, fs::Permissions::from_mode(0o000)).unwrap();
        let denied = fs::read_dir(&sealed).is_err();
        let answer = missing_why(&sealed);
        // Unsealed before anything can panic: a sealed directory outlives
        // the TempDir that cannot remove it.
        fs::set_permissions(&sealed, fs::Permissions::from_mode(0o700)).unwrap();
        // Permissions do not bind this user (root): there is no denial to
        // read here, and nothing to assert about one.
        if denied {
            assert!(
                matches!(answer, Some(MissingWhy::Unreadable { said }) if !said.is_empty()),
                "a folder the account cannot open is unreadable, never a place holding nothing"
            );
        }
    }
}
