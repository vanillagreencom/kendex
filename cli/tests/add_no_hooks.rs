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
    assert!(sandbox.project.join(".claude/hooks/guard.sh").exists());
    let settings = fs::read_to_string(sandbox.project.join(".claude/settings.json")).unwrap();
    assert!(settings.contains(".claude/hooks/guard.sh"));
}

#[test]
fn remove_hook_cleans_claude_artifacts_settings_and_lock() {
    let sandbox = Sandbox::new("remove-hook");

    let output = sandbox
        .vstack()
        .arg("add")
        .arg(&sandbox.source)
        .args(["--hook", "guard", "--harness", "claude", "--copy", "-y"])
        .output()
        .unwrap();
    assert_success(output, "vstack add");
    assert!(sandbox.project.join(".claude/hooks/guard.sh").exists());

    let output = sandbox
        .vstack()
        .args(["remove", "guard", "--scope", "project"])
        .output()
        .unwrap();
    assert_success(output, "vstack remove");

    assert!(!sandbox.project.join(".claude/hooks/guard.sh").exists());
    let settings = fs::read_to_string(sandbox.project.join(".claude/settings.json")).unwrap();
    assert!(!settings.contains("guard.sh"), "stale settings: {settings}");
    let lock = fs::read_to_string(sandbox.project.join(".vstack-lock.json")).unwrap();
    assert!(!lock.contains("guard"), "stale lock entry: {lock}");
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
