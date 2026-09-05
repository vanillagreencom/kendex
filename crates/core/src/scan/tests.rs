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

    assert_eq!(result.warnings, Vec::<String>::new());
    assert_eq!(result.missing_projects, [home.join("dev/vanished")]);

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
    assert_eq!(agent[0].description.as_deref(), Some("boss"));

    assert_eq!(find(ItemKind::Skill, "github").len(), 1);
    assert_eq!(find(ItemKind::Hook, "PreToolUse:Bash:guard").len(), 1);
    assert_eq!(find(ItemKind::McpServer, "github").len(), 1);
    assert_eq!(
        find(ItemKind::Agent, "rust")[0].description.as_deref(),
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

    assert_eq!(result.warnings, Vec::<String>::new());
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
        .find(|w| w.contains("reviewer"))
        .expect("nothing said the tag was wrong");
    assert!(warning.contains("did you mean `testing`?"), "{warning}");
}

/// A pi package registered by a relative spec is a folder of its own, so it
/// can say what it is and when it changed. One registered by name is only a
/// line in a shared config file, and has neither.
#[test]
fn a_local_pi_package_reports_its_own_description_and_mtime() {
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
    assert_eq!(local.description.as_deref(), Some("Caveman mode"));
    assert_eq!(local.path, package);
    assert!(local.modified_at.is_some(), "no mtime for a real folder");

    let remote = find("@vg/remote");
    assert_eq!(remote.description.as_deref(), Some("npm:@vg/remote@1.0"));
    assert_eq!(remote.modified_at, None);
}
