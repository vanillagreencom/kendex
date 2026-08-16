use std::fs;
use std::path::{Path, PathBuf};
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn unique_temp_dir(name: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_nanos();
    std::env::temp_dir().join(format!("vstack-{name}-{}-{nanos}", std::process::id()))
}

fn write_fixture_source(source: &Path, hook_harnesses: Option<&str>) {
    fs::create_dir_all(source.join("agents")).unwrap();
    fs::create_dir_all(source.join("skills/dev")).unwrap();
    fs::create_dir_all(source.join("hooks")).unwrap();

    fs::write(
        source.join("vstack.toml"),
        r#"[agent-skills]
rust = ["dev"]

[hook-events]
"PreToolUse:Bash" = "all"
"#,
    )
    .unwrap();
    fs::write(
        source.join("agents/rust.md"),
        r#"---
name: rust
description: Rust agent
model: sonnet
role: engineer
---
# Rust

Body.
"#,
    )
    .unwrap();
    fs::write(
        source.join("skills/dev/SKILL.md"),
        r#"---
name: dev
description: Dev skill
license: MIT
---
# Dev
"#,
    )
    .unwrap();
    write_hook(source, hook_harnesses);
}

fn write_hook(source: &Path, harnesses: Option<&str>) {
    let harness_line = harnesses
        .map(|value| format!("# harnesses: {value}\n"))
        .unwrap_or_default();
    fs::write(
        source.join("hooks/guard.sh"),
        format!(
            r#"# ---
# name: guard
# event: PreToolUse
# matcher: Bash
# description: Guard bash
{harness_line}# ---
#!/usr/bin/env bash
exit 0
"#
        ),
    )
    .unwrap();
}

fn write_custom_hook(
    source: &Path,
    name: &str,
    event: &str,
    matcher: Option<&str>,
    timeout: Option<u32>,
    harnesses: Option<&str>,
) {
    let matcher_line = matcher
        .map(|value| format!("# matcher: {value}\n"))
        .unwrap_or_default();
    let timeout_line = timeout
        .map(|value| format!("# timeout: {value}\n"))
        .unwrap_or_default();
    let harness_line = harnesses
        .map(|value| format!("# harnesses: {value}\n"))
        .unwrap_or_default();
    fs::write(
        source.join("hooks").join(format!("{name}.sh")),
        format!(
            r#"# ---
# name: {name}
# event: {event}
{matcher_line}# description: {name} hook
{timeout_line}{harness_line}# safety: Keep state safe.
# ---
#!/usr/bin/env bash
exit 0
"#
        ),
    )
    .unwrap();
}

struct Sandbox {
    root: PathBuf,
    source: PathBuf,
    project: PathBuf,
    home: PathBuf,
    xdg: PathBuf,
    pi_dir: PathBuf,
}

impl Sandbox {
    fn new(name: &str) -> Self {
        let root = unique_temp_dir(name);
        let source = root.join("source");
        let project = root.join("project");
        let home = root.join("home");
        let xdg = root.join("xdg");
        let pi_dir = root.join("pi");
        fs::create_dir_all(&project).unwrap();
        fs::create_dir_all(&home).unwrap();
        fs::create_dir_all(&xdg).unwrap();
        fs::create_dir_all(&pi_dir).unwrap();
        write_fixture_source(&source, None);
        Self {
            root,
            source,
            project,
            home,
            xdg,
            pi_dir,
        }
    }

    fn vstack(&self) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_vstack"));
        command
            .current_dir(&self.project)
            .env("HOME", &self.home)
            .env("XDG_CONFIG_HOME", &self.xdg)
            .env("PI_CODING_AGENT_DIR", &self.pi_dir);
        command
    }
}

impl Drop for Sandbox {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn assert_success(output: std::process::Output, context: &str) {
    assert!(
        output.status.success(),
        "{context} failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );
}

fn agent_frontmatter(content: &str) -> &str {
    content
        .strip_prefix("---\n")
        .and_then(|rest| rest.split_once("\n---\n"))
        .map(|(frontmatter, _)| frontmatter)
        .expect("frontmatter present")
}

fn assert_single_trailing_newline(bytes: &[u8], context: &str) {
    assert!(bytes.ends_with(b"\n"), "{context} has no trailing newline");
    assert!(
        !bytes.ends_with(b"\n\n"),
        "{context} has multiple trailing newlines"
    );
    serde_json::from_slice::<serde_json::Value>(bytes)
        .unwrap_or_else(|error| panic!("{context} is not valid JSON: {error}"));
}

#[test]
fn opencode_project_config_is_newline_terminated_across_refreshes() {
    let sandbox = Sandbox::new("opencode-config-newline");

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args(["--hook", "guard", "--harness", "opencode", "--copy", "-y"])
        .output()
        .unwrap();
    assert_success(output, "vstack add");

    let config_path = sandbox.project.join("opencode.json");
    let installed = fs::read(&config_path).unwrap();
    assert_single_trailing_newline(&installed, "installed OpenCode project config");

    for refresh_number in 1..=2 {
        let output = sandbox
            .vstack()
            .args(["refresh", "--scope", "project", "-v"])
            .output()
            .unwrap();
        assert_success(output, &format!("vstack refresh {refresh_number}"));

        let refreshed = fs::read(&config_path).unwrap();
        assert_single_trailing_newline(
            &refreshed,
            &format!("OpenCode project config after refresh {refresh_number}"),
        );
        assert_eq!(
            refreshed, installed,
            "refresh {refresh_number} changed the rendered OpenCode project config"
        );
    }
}

#[test]
fn agent_install_without_hooks_does_not_emit_claude_hook_frontmatter() {
    let sandbox = Sandbox::new("add-no-hooks");

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args(["--agent", "rust", "--harness", "claude", "--copy", "-y"])
        .output()
        .unwrap();
    assert_success(output, "vstack add");

    let agent_path = sandbox.project.join(".claude/agents/rust.md");
    let content = fs::read_to_string(&agent_path).unwrap();
    assert!(
        content.contains("skills: dev"),
        "agent missing selected skill"
    );
    assert!(
        !content.lines().any(|line| line.trim() == "hooks:"),
        "agent unexpectedly contains hook frontmatter:\n{content}"
    );
    assert!(
        !content.contains(".claude/hooks/guard.sh"),
        "agent references uninstalled hook:\n{content}"
    );
    assert!(
        !sandbox.project.join(".claude/hooks/guard.sh").exists(),
        "unselected hook should not be installed"
    );
}

#[test]
fn selected_hook_install_emits_claude_hook_frontmatter_and_script() {
    let sandbox = Sandbox::new("add-selected-hook");

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args([
            "--agent",
            "rust",
            "--hook",
            "guard",
            "--harness",
            "claude",
            "--copy",
            "-y",
        ])
        .output()
        .unwrap();
    assert_success(output, "vstack add");

    let agent = fs::read_to_string(sandbox.project.join(".claude/agents/rust.md")).unwrap();
    assert!(agent.lines().any(|line| line.trim() == "hooks:"));
    assert!(agent.contains("$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh"));
    let parsed: serde_json::Value =
        serde_yaml::from_str(agent_frontmatter(&agent)).expect("valid Claude YAML frontmatter");
    assert_eq!(
        parsed
            .pointer("/hooks/PreToolUse/0/hooks/0/command")
            .and_then(|value| value.as_str()),
        Some("bash \"$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh\"")
    );
    assert!(sandbox.project.join(".claude/hooks/guard.sh").exists());
    let settings = fs::read_to_string(sandbox.project.join(".claude/settings.json")).unwrap();
    assert!(settings.contains(".claude/hooks/guard.sh"));
}

#[test]
fn hook_only_add_regenerates_existing_agent_with_no_installed_skills() {
    let sandbox = Sandbox::new("hook-only-no-skills");

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args([
            "--agent",
            "rust",
            "--harness",
            "claude",
            "--copy",
            "--no-auto-skills",
            "-y",
        ])
        .output()
        .unwrap();
    assert_success(output, "vstack add agent without skills");
    let before = fs::read_to_string(sandbox.project.join(".claude/agents/rust.md")).unwrap();
    assert!(
        !before.contains("skills:"),
        "unexpected skills before hook add:\n{before}"
    );

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args(["--hook", "guard", "--harness", "claude", "--copy", "-y"])
        .output()
        .unwrap();
    assert_success(output, "vstack add hook only");

    let agent = fs::read_to_string(sandbox.project.join(".claude/agents/rust.md")).unwrap();
    assert!(agent.lines().any(|line| line.trim() == "hooks:"));
    assert!(agent.contains("$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh"));
    assert!(sandbox.project.join(".claude/hooks/guard.sh").exists());
    let settings = fs::read_to_string(sandbox.project.join(".claude/settings.json")).unwrap();
    assert!(settings.contains("bash \\\"$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh\\\""));
}

#[test]
fn claude_hook_add_preserves_user_handler_with_same_script_basename() {
    let sandbox = Sandbox::new("claude-preserve-user-hook");
    fs::create_dir_all(sandbox.project.join(".claude")).unwrap();
    fs::write(
        sandbox.project.join(".claude/settings.json"),
        r#"{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash ./scripts/guard.sh"}]
      }
    ]
  }
}"#,
    )
    .unwrap();

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args(["--hook", "guard", "--harness", "claude", "--copy", "-y"])
        .output()
        .unwrap();
    assert_success(output, "vstack add hook");

    let settings = fs::read_to_string(sandbox.project.join(".claude/settings.json")).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&settings).unwrap();
    let entries = parsed
        .pointer("/hooks/PreToolUse")
        .and_then(|value| value.as_array())
        .expect("PreToolUse entries");
    assert_eq!(
        entries.len(),
        2,
        "user hook should be preserved: {settings}"
    );
    assert!(settings.contains("bash ./scripts/guard.sh"));
    assert!(settings.contains("bash \\\"$CLAUDE_PROJECT_DIR/.claude/hooks/guard.sh\\\""));
}

#[test]
fn global_claude_hook_install_remove_preserves_user_same_basename_handler() {
    let sandbox = Sandbox::new("global-claude-hook");
    let claude_dir = sandbox.home.join(".claude");
    fs::create_dir_all(&claude_dir).unwrap();
    fs::write(
        claude_dir.join("settings.json"),
        r#"{
  "hooks": {
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [{"type": "command", "command": "bash /usr/local/bin/guard.sh"}]
      }
    ]
  }
}"#,
    )
    .unwrap();

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args([
            "--global",
            "--hook",
            "guard",
            "--harness",
            "claude",
            "--copy",
            "-y",
        ])
        .output()
        .unwrap();
    assert_success(output, "vstack global add hook");

    let hook_path = sandbox.home.join(".claude/hooks/guard.sh");
    assert!(hook_path.exists());
    let expected_command = format!("bash {}", hook_path.display());
    let settings = fs::read_to_string(claude_dir.join("settings.json")).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&settings).unwrap();
    let entries = parsed
        .pointer("/hooks/PreToolUse")
        .and_then(|value| value.as_array())
        .expect("PreToolUse entries");
    assert_eq!(
        entries.len(),
        2,
        "global user hook should be preserved: {settings}"
    );
    assert!(settings.contains("bash /usr/local/bin/guard.sh"));
    assert!(settings.contains(&expected_command));

    let output = sandbox
        .vstack()
        .args(["remove", "guard", "--scope", "global"])
        .output()
        .unwrap();
    assert_success(output, "vstack global remove hook");

    assert!(!hook_path.exists());
    let settings = fs::read_to_string(claude_dir.join("settings.json")).unwrap();
    assert!(settings.contains("bash /usr/local/bin/guard.sh"));
    assert!(!settings.contains(&expected_command));
}

#[test]
fn refresh_upserts_claude_hook_registration_when_event_changes() {
    let sandbox = Sandbox::new("refresh-claude-hook-upsert");

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args(["--hook", "guard", "--harness", "claude", "--copy", "-y"])
        .output()
        .unwrap();
    assert_success(output, "vstack add");

    write_custom_hook(&sandbox.source, "guard", "PostCompact", None, Some(7), None);
    let output = sandbox
        .vstack()
        .args(["refresh", "--scope", "project"])
        .output()
        .unwrap();
    assert_success(output, "vstack refresh");

    let settings = fs::read_to_string(sandbox.project.join(".claude/settings.json")).unwrap();
    let parsed: serde_json::Value = serde_json::from_str(&settings).unwrap();
    assert!(parsed.pointer("/hooks/PreToolUse").is_none());
    let post = parsed
        .pointer("/hooks/PostCompact")
        .and_then(|value| value.as_array())
        .expect("PostCompact hook present");
    assert_eq!(post.len(), 1, "stale or duplicate hooks: {settings}");
    assert!(post[0].pointer("/matcher").is_none());
    assert!(
        post[0].pointer("/timeout").is_none(),
        "timeout must not sit on the matcher group: {settings}"
    );
    assert_eq!(
        post[0].pointer("/hooks/0/timeout").and_then(|v| v.as_u64()),
        Some(7)
    );
}

#[test]
fn codex_fallback_hook_add_keeps_agent_safety_prose_after_reconcile() {
    let sandbox = Sandbox::new("add-codex-fallback-hook");
    write_custom_hook(
        &sandbox.source,
        "finish",
        "TaskCompleted",
        None,
        None,
        Some("[codex]"),
    );

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args([
            "--agent",
            "rust",
            "--hook",
            "finish",
            "--harness",
            "codex",
            "--copy",
            "-y",
        ])
        .output()
        .unwrap();
    assert_success(output, "vstack add agent+hook");

    let agent = fs::read_to_string(sandbox.project.join(".codex/agents/rust.toml")).unwrap();
    assert!(
        agent.contains("## Safety: finish"),
        "missing fallback prose:\n{agent}"
    );
}

#[test]
fn codex_fallback_hook_only_add_updates_existing_agent_after_reconcile() {
    let sandbox = Sandbox::new("add-codex-fallback-hook-only");
    write_custom_hook(
        &sandbox.source,
        "finish",
        "TaskCompleted",
        None,
        None,
        Some("[codex]"),
    );

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args(["--agent", "rust", "--harness", "codex", "--copy", "-y"])
        .output()
        .unwrap();
    assert_success(output, "vstack add agent");

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args(["--hook", "finish", "--harness", "codex", "--copy", "-y"])
        .output()
        .unwrap();
    assert_success(output, "vstack add hook");

    let agent = fs::read_to_string(sandbox.project.join(".codex/agents/rust.toml")).unwrap();
    assert!(
        agent.contains("## Safety: finish"),
        "missing fallback prose:\n{agent}"
    );
}

#[test]
fn adding_codex_agent_after_fallback_hook_installed_adds_safety_prose() {
    let sandbox = Sandbox::new("add-codex-agent-after-fallback-hook");
    write_custom_hook(
        &sandbox.source,
        "finish",
        "TaskCompleted",
        None,
        None,
        Some("[codex]"),
    );

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args(["--hook", "finish", "--harness", "codex", "--copy", "-y"])
        .output()
        .unwrap();
    assert_success(output, "vstack add hook");

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args(["--agent", "rust", "--harness", "codex", "--copy", "-y"])
        .output()
        .unwrap();
    assert_success(output, "vstack add agent");

    let agent = fs::read_to_string(sandbox.project.join(".codex/agents/rust.toml")).unwrap();
    assert!(
        agent.contains("## Safety: finish"),
        "missing fallback prose:\n{agent}"
    );
}

#[test]
fn removing_one_codex_fallback_hook_keeps_remaining_fallback_prose() {
    let sandbox = Sandbox::new("remove-one-codex-fallback-hook");
    write_custom_hook(
        &sandbox.source,
        "finish-a",
        "TaskCompleted",
        None,
        None,
        Some("[codex]"),
    );
    write_custom_hook(
        &sandbox.source,
        "finish-b",
        "TaskCompleted",
        None,
        None,
        Some("[codex]"),
    );

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args([
            "--agent",
            "rust",
            "--hook",
            "finish-a",
            "--hook",
            "finish-b",
            "--harness",
            "codex",
            "--copy",
            "-y",
        ])
        .output()
        .unwrap();
    assert_success(output, "vstack add agent+hooks");

    let before = fs::read_to_string(sandbox.project.join(".codex/agents/rust.toml")).unwrap();
    assert!(before.contains("## Safety: finish-a"));
    assert!(before.contains("## Safety: finish-b"));

    let output = sandbox
        .vstack()
        .args(["remove", "finish-a", "--scope", "project"])
        .output()
        .unwrap();
    assert_success(output, "vstack remove fallback hook");

    let after = fs::read_to_string(sandbox.project.join(".codex/agents/rust.toml")).unwrap();
    assert!(
        !after.contains("## Safety: finish-a"),
        "removed hook stayed: {after}"
    );
    assert!(
        after.contains("## Safety: finish-b"),
        "remaining fallback prose missing:\n{after}"
    );
}

#[test]
fn remove_hook_cleans_claude_artifacts_settings_agents_and_lock() {
    let sandbox = Sandbox::new("remove-hook");

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args([
            "--agent",
            "rust",
            "--hook",
            "guard",
            "--harness",
            "claude",
            "--copy",
            "-y",
        ])
        .output()
        .unwrap();
    assert_success(output, "vstack add");
    assert!(sandbox.project.join(".claude/hooks/guard.sh").exists());
    let agent_before = fs::read_to_string(sandbox.project.join(".claude/agents/rust.md")).unwrap();
    assert!(agent_before.contains(".claude/hooks/guard.sh"));

    let output = sandbox
        .vstack()
        .args(["remove", "guard", "--scope", "project"])
        .output()
        .unwrap();
    assert_success(output, "vstack remove");

    assert!(!sandbox.project.join(".claude/hooks/guard.sh").exists());
    let agent_after = fs::read_to_string(sandbox.project.join(".claude/agents/rust.md")).unwrap();
    let parsed: serde_json::Value =
        serde_yaml::from_str(agent_frontmatter(&agent_after)).expect("valid Claude frontmatter");
    assert!(
        parsed.get("hooks").is_none(),
        "stale agent hook frontmatter: {agent_after}"
    );
    assert!(!agent_after.contains(".claude/hooks/guard.sh"));
    let settings = fs::read_to_string(sandbox.project.join(".claude/settings.json")).unwrap();
    assert!(!settings.contains("guard.sh"), "stale settings: {settings}");
    let lock = fs::read_to_string(sandbox.project.join(".vstack-lock.json")).unwrap();
    assert!(!lock.contains("guard"), "stale lock entry: {lock}");
}

#[test]
fn remove_hook_keeps_lock_entry_when_codex_cleanup_fails() {
    let sandbox = Sandbox::new("remove-hook-codex-failure");
    let source = sandbox.source.to_string_lossy();
    fs::create_dir_all(sandbox.project.join(".codex/hooks")).unwrap();
    fs::write(
        sandbox.project.join(".codex/hooks/guard.sh"),
        "#!/usr/bin/env bash\n",
    )
    .unwrap();
    fs::write(sandbox.project.join(".codex/hooks.json"), "{not-json").unwrap();
    fs::write(
        sandbox.project.join(".vstack-lock.json"),
        format!(
            r#"{{
  "version": 1,
  "entries": {{
    "guard": {{
      "name": "guard",
      "kind": "hook",
      "source": "{source}",
      "harnesses": ["codex"],
      "method": "copy",
      "installed_at": "2026-07-03T00:00:00Z"
    }}
  }}
}}
"#
        ),
    )
    .unwrap();

    let output = sandbox
        .vstack()
        .args(["remove", "guard", "--scope", "project"])
        .output()
        .unwrap();
    assert!(
        !output.status.success(),
        "vstack remove should fail when Codex cleanup fails\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let lock = fs::read_to_string(sandbox.project.join(".vstack-lock.json")).unwrap();
    assert!(lock.contains("\"guard\""), "lock entry lost: {lock}");
    assert!(
        lock.contains("\"codex\""),
        "Codex harness lost from lock: {lock}"
    );
    let stderr = String::from_utf8_lossy(&output.stderr);
    assert!(
        stderr.contains("failed to remove guard"),
        "stderr: {stderr}"
    );
    assert!(
        sandbox.project.join(".codex/hooks/guard.sh").exists(),
        "hook script should remain when config cleanup fails"
    );
}

#[test]
fn remove_hook_keeps_claude_script_when_settings_cleanup_fails() {
    let sandbox = Sandbox::new("remove-hook-claude-failure");
    let source = sandbox.source.to_string_lossy();
    fs::create_dir_all(sandbox.project.join(".claude/hooks")).unwrap();
    fs::write(
        sandbox.project.join(".claude/hooks/guard.sh"),
        "#!/usr/bin/env bash\n",
    )
    .unwrap();
    fs::write(sandbox.project.join(".claude/settings.json"), "{not-json").unwrap();
    fs::write(
        sandbox.project.join(".vstack-lock.json"),
        format!(
            r#"{{
  "version": 1,
  "entries": {{
    "guard": {{
      "name": "guard",
      "kind": "hook",
      "source": "{source}",
      "harnesses": ["claude-code"],
      "method": "copy",
      "installed_at": "2026-07-03T00:00:00Z"
    }}
  }}
}}
"#
        ),
    )
    .unwrap();

    let output = sandbox
        .vstack()
        .args(["remove", "guard", "--scope", "project"])
        .output()
        .unwrap();
    assert!(
        !output.status.success(),
        "vstack remove should fail when Claude cleanup fails\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    assert!(
        sandbox.project.join(".claude/hooks/guard.sh").exists(),
        "hook script should remain when settings cleanup fails"
    );
    let lock = fs::read_to_string(sandbox.project.join(".vstack-lock.json")).unwrap();
    assert!(lock.contains("\"guard\""), "lock entry lost: {lock}");
}

#[test]
fn refresh_prunes_hook_artifacts_when_harness_allowlist_drops_claude() {
    let sandbox = Sandbox::new("refresh-prune-hook");

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args(["--hook", "guard", "--harness", "claude", "--copy", "-y"])
        .output()
        .unwrap();
    assert_success(output, "vstack add");
    assert!(sandbox.project.join(".claude/hooks/guard.sh").exists());

    write_hook(&sandbox.source, Some("[codex]"));
    let output = sandbox
        .vstack()
        .args(["refresh", "--scope", "project"])
        .output()
        .unwrap();
    assert_success(output, "vstack refresh");

    assert!(!sandbox.project.join(".claude/hooks/guard.sh").exists());
    let settings = fs::read_to_string(sandbox.project.join(".claude/settings.json")).unwrap();
    assert!(!settings.contains("guard.sh"), "stale settings: {settings}");
    let lock = fs::read_to_string(sandbox.project.join(".vstack-lock.json")).unwrap();
    assert!(!lock.contains("guard"), "stale lock entry: {lock}");
}

#[test]
fn refresh_prune_uses_hook_lock_source_when_duplicate_hook_names_exist() {
    let sandbox = Sandbox::new("refresh-multisource-hook");
    let source_a = &sandbox.source;
    let source_b = sandbox.root.join("source-b");
    write_hook(source_a, Some("[codex]"));
    write_fixture_source(&source_b, Some("[claude-code]"));

    let source_a = source_a.to_string_lossy();
    let source_b = source_b.to_string_lossy();
    fs::write(
        sandbox.project.join(".vstack-lock.json"),
        format!(
            r#"{{
  "version": 1,
  "entries": {{
    "dev": {{
      "name": "dev",
      "kind": "skill",
      "source": "{source_a}",
      "harnesses": ["claude-code"],
      "method": "copy",
      "installed_at": "2026-07-03T00:00:00Z"
    }},
    "guard": {{
      "name": "guard",
      "kind": "hook",
      "source": "{source_b}",
      "harnesses": ["claude-code"],
      "method": "copy",
      "installed_at": "2026-07-03T00:00:00Z"
    }},
    "rust": {{
      "name": "rust",
      "kind": "agent",
      "source": "{source_a}",
      "harnesses": ["claude-code"],
      "method": "copy",
      "installed_at": "2026-07-03T00:00:00Z"
    }}
  }}
}}
"#
        ),
    )
    .unwrap();

    let output = sandbox
        .vstack()
        .args(["refresh", "--scope", "project"])
        .output()
        .unwrap();
    assert_success(output, "vstack refresh");

    assert!(sandbox.project.join(".claude/hooks/guard.sh").exists());
    let settings = fs::read_to_string(sandbox.project.join(".claude/settings.json")).unwrap();
    assert!(
        settings.contains("guard.sh"),
        "missing settings hook: {settings}"
    );
    let lock = fs::read_to_string(sandbox.project.join(".vstack-lock.json")).unwrap();
    assert!(
        lock.contains("\"guard\""),
        "missing hook lock entry: {lock}"
    );
    assert!(
        lock.contains("\"claude-code\""),
        "missing Claude harness in lock: {lock}"
    );
}

#[test]
fn refresh_agent_hook_frontmatter_uses_hook_harness_from_lock() {
    let sandbox = Sandbox::new("refresh-hook-harness-scope");
    let source = sandbox.source.to_string_lossy();
    fs::write(
        sandbox.project.join(".vstack-lock.json"),
        format!(
            r#"{{
  "version": 1,
  "entries": {{
    "rust": {{
      "name": "rust",
      "kind": "agent",
      "source": "{source}",
      "harnesses": ["claude-code", "codex"],
      "method": "copy",
      "installed_at": "2026-07-03T00:00:00Z"
    }},
    "dev": {{
      "name": "dev",
      "kind": "skill",
      "source": "{source}",
      "harnesses": ["claude-code", "codex"],
      "method": "copy",
      "installed_at": "2026-07-03T00:00:00Z"
    }},
    "guard": {{
      "name": "guard",
      "kind": "hook",
      "source": "{source}",
      "harnesses": ["codex"],
      "method": "copy",
      "installed_at": "2026-07-03T00:00:00Z"
    }}
  }}
}}
"#
        ),
    )
    .unwrap();

    let output = sandbox
        .vstack()
        .args(["refresh", "--scope", "project"])
        .output()
        .unwrap();
    assert_success(output, "vstack refresh");

    let claude_agent = fs::read_to_string(sandbox.project.join(".claude/agents/rust.md")).unwrap();
    assert!(
        !claude_agent.contains(".claude/hooks/guard.sh"),
        "Claude agent referenced hook installed only for Codex:\n{claude_agent}"
    );
    assert!(sandbox.project.join(".codex/hooks/guard.sh").exists());
}

/// A hook entry recording a remote source whose clone is not on this machine
/// must not be judged against a same-named hook from another loaded source:
/// prune uninstalled the artifacts and dropped the lock entry against the
/// wrong `harnesses:` list, and the agent frontmatter took the wrong event.
#[test]
fn refresh_keeps_a_hook_whose_remote_source_is_not_cached() {
    let sandbox = Sandbox::new("refresh-uncached-hook-source");

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args([
            "--hook",
            "guard",
            "--harness",
            "claude-code",
            "--copy",
            "-y",
        ])
        .output()
        .unwrap();
    assert_success(output, "vstack add --hook");
    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args([
            "--agent",
            "rust",
            "--harness",
            "claude-code",
            "--copy",
            "-y",
        ])
        .output()
        .unwrap();
    assert_success(output, "vstack add --agent");
    assert!(sandbox.project.join(".claude/hooks/guard.sh").exists());

    // The local source keeps a same-named hook — a different event, and an
    // allowlist that excludes the harness the entry is installed for.
    write_custom_hook(
        &sandbox.source,
        "guard",
        "PostToolUse",
        Some("Edit|Write"),
        None,
        Some("[codex]"),
    );
    // The entry's own source is a remote with no clone under this HOME.
    let lock_path = sandbox.project.join(".vstack-lock.json");
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&lock_path).unwrap()).unwrap();
    lock["entries"]["guard"]["source"] = serde_json::Value::String("owner/repo".into());
    fs::write(&lock_path, serde_json::to_string_pretty(&lock).unwrap()).unwrap();
    let agent_path = sandbox.project.join(".claude/agents/rust.md");
    let agent_before = fs::read_to_string(&agent_path).unwrap();
    assert!(agent_before.contains(".claude/hooks/guard.sh"), "fixture");

    let output = sandbox
        .vstack()
        .args(["refresh", "--scope", "project"])
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&output.stdout).into_owned()
        + &String::from_utf8_lossy(&output.stderr);
    assert!(
        sandbox.project.join(".claude/hooks/guard.sh").exists(),
        "the installed hook artifact was removed:\n{stderr}"
    );
    let lock = fs::read_to_string(&lock_path).unwrap();
    let lock: serde_json::Value = serde_json::from_str(&lock).unwrap();
    assert_eq!(
        lock["entries"]["guard"]["harnesses"],
        serde_json::json!(["claude-code"]),
        "the lock entry was pruned against another source's hook: {lock}"
    );
    let claude_agent = fs::read_to_string(&agent_path).unwrap();
    assert!(
        !claude_agent.contains("PostToolUse"),
        "agent frontmatter took the other source's hook event:\n{claude_agent}"
    );
    // The agent is left exactly as installed rather than rewritten without a
    // hook this run could not read: its script and its settings.json
    // registration both survive, so dropping it from the frontmatter alone
    // would be a silent half-uninstall.
    assert_eq!(
        claude_agent, agent_before,
        "the agent was rewritten with a hook set the run could not determine:\n{stderr}"
    );
    assert!(
        stderr.contains("rust"),
        "the agent left untouched must be named:\n{stderr}"
    );
    assert!(
        !output.status.success(),
        "an entry whose source has no clone must not report success:\n{stderr}"
    );
}

/// The CLI removal path has already deleted the hook artifact and its lock
/// entry when the agents are regenerated, so a regeneration that cannot run
/// must be reported as the failure it is.
#[test]
fn remove_hook_fails_when_the_agent_source_has_no_clone() {
    let sandbox = Sandbox::new("remove-hook-unresolved-agent-source");

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args([
            "--hook",
            "guard",
            "--harness",
            "claude-code",
            "--copy",
            "-y",
        ])
        .output()
        .unwrap();
    assert_success(output, "vstack add --hook");
    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args([
            "--agent",
            "rust",
            "--harness",
            "claude-code",
            "--copy",
            "-y",
        ])
        .output()
        .unwrap();
    assert_success(output, "vstack add --agent");

    // The agent's source is a remote with no clone under this HOME.
    let lock_path = sandbox.project.join(".vstack-lock.json");
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&lock_path).unwrap()).unwrap();
    lock["entries"]["rust"]["source"] = serde_json::Value::String("owner/repo".into());
    fs::write(&lock_path, serde_json::to_string_pretty(&lock).unwrap()).unwrap();

    let output = sandbox
        .vstack()
        .args(["remove", "guard", "--scope", "project"])
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();
    assert!(
        !output.status.success(),
        "removal reported success with the agent left stale:\n{stderr}"
    );
    assert!(
        stderr.contains("regenerate agents"),
        "the failure must name what did not happen:\n{stderr}"
    );
    // The cause leads; a `0 failure(s)` prefix used to sit in front of it.
    assert!(
        !stderr.contains("0 failure(s)"),
        "the message contradicts itself:\n{stderr}"
    );
    assert!(
        stderr.contains("not regenerated: rust"),
        "the message must lead with what was not regenerated:\n{stderr}"
    );
    let claude_agent = fs::read_to_string(sandbox.project.join(".claude/agents/rust.md")).unwrap();
    assert!(
        claude_agent.contains(".claude/hooks/guard.sh"),
        "the stale frontmatter the failure is about:\n{claude_agent}"
    );
}

/// The removal path regenerates agents from the hooks that remain. A hook whose
/// own source did not resolve cannot be read, so regenerating anyway rewrote
/// every agent without it while its script, its settings.json registration and
/// its lock entry all survived — a silent half-uninstall, with a success exit.
#[test]
fn remove_hook_fails_when_another_hooks_source_has_no_clone() {
    let sandbox = Sandbox::new("remove-hook-uncached-sibling");
    write_custom_hook(
        &sandbox.source,
        "keeper",
        "PreToolUse",
        Some("Bash"),
        None,
        None,
    );

    for args in [
        vec!["--hook", "guard"],
        vec!["--hook", "keeper"],
        vec!["--agent", "rust"],
    ] {
        let output = sandbox
            .vstack()
            .arg("add")
            .arg(&sandbox.source)
            .args(args.clone())
            .args(["--harness", "claude-code", "--copy", "-y"])
            .output()
            .unwrap();
        assert_success(output, &format!("vstack add {args:?}"));
    }
    let agent_path = sandbox.project.join(".claude/agents/rust.md");
    let agent_before = fs::read_to_string(&agent_path).unwrap();
    assert!(
        agent_before.contains("keeper.sh"),
        "fixture: {agent_before}"
    );

    // Only the sibling hook's source is a remote with no clone under this HOME.
    let lock_path = sandbox.project.join(".vstack-lock.json");
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&lock_path).unwrap()).unwrap();
    lock["entries"]["keeper"]["source"] = serde_json::Value::String("owner/repo".into());
    fs::write(&lock_path, serde_json::to_string_pretty(&lock).unwrap()).unwrap();

    let output = sandbox
        .vstack()
        .args(["remove", "guard", "--scope", "project"])
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr).into_owned();

    assert_eq!(
        fs::read_to_string(&agent_path).unwrap(),
        agent_before,
        "the agent was regenerated without the hook that could not be read:\n{stderr}"
    );
    assert!(sandbox.project.join(".claude/hooks/keeper.sh").exists());
    assert!(
        !output.status.success(),
        "removal reported success after skipping a hook it could not read:\n{stderr}"
    );
    assert!(stderr.contains("keeper"), "{stderr}");
}

/// A `./`-relative recorded source is as owned as an absolute one. It used to
/// fall outside the ownership branch entirely, so the entry borrowed whichever
/// same-named hook sorted first across all loaded sources — and prune then
/// judged it against that foreign hook's `harnesses:` list, deleting the
/// artifact and the lock entry with a success exit.
#[test]
fn refresh_keeps_a_hook_whose_recorded_source_is_relative() {
    let sandbox = Sandbox::new("refresh-relative-hook-source");
    // The other source sorts first among loaded sources (its lock entry `dev`
    // precedes `guard`), so a name-only fallback picks ITS guard.
    write_custom_hook(
        &sandbox.source,
        "guard",
        "PostToolUse",
        Some("Edit|Write"),
        None,
        Some("[codex]"),
    );
    let relative = sandbox.project.join("vendor/a");
    fs::create_dir_all(relative.join("hooks")).unwrap();
    write_hook(&relative, None);

    // An entry from the other source, named so it sorts first among loaded
    // sources — a name-only fallback then reaches ITS guard.
    write_custom_hook(
        &sandbox.source,
        "alpha",
        "PreToolUse",
        Some("Bash"),
        None,
        None,
    );
    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args([
            "--hook",
            "alpha",
            "--harness",
            "claude-code",
            "--copy",
            "-y",
        ])
        .output()
        .unwrap();
    assert_success(output, "vstack add --hook alpha");
    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&relative)
        .args([
            "--hook",
            "guard",
            "--harness",
            "claude-code",
            "--copy",
            "-y",
        ])
        .output()
        .unwrap();
    assert_success(output, "vstack add --hook");

    // The entry records the source the way a project-relative install does.
    let lock_path = sandbox.project.join(".vstack-lock.json");
    let mut lock: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&lock_path).unwrap()).unwrap();
    lock["entries"]["guard"]["source"] = serde_json::Value::String("./vendor/a".into());
    fs::write(&lock_path, serde_json::to_string_pretty(&lock).unwrap()).unwrap();

    let output = sandbox
        .vstack()
        .args(["refresh", "--scope", "project"])
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&output.stdout).into_owned()
        + &String::from_utf8_lossy(&output.stderr);
    assert!(
        sandbox.project.join(".claude/hooks/guard.sh").exists(),
        "the hook was uninstalled against another source's allowlist:\n{stderr}"
    );
    let saved: serde_json::Value =
        serde_json::from_str(&fs::read_to_string(&lock_path).unwrap()).unwrap();
    assert_eq!(
        saved["entries"]["guard"]["harnesses"],
        serde_json::json!(["claude-code"]),
        "{saved}"
    );
    assert_success(output, "vstack refresh");
}
