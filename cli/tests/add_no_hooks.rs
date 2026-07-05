use std::fs;
use std::path::PathBuf;
use std::process::Command;
use std::time::{SystemTime, UNIX_EPOCH};

fn unique_temp_dir(name: &str) -> PathBuf {
    let nanos = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .expect("system clock before epoch")
        .as_nanos();
    std::env::temp_dir().join(format!("vstack-{name}-{}-{nanos}", std::process::id()))
}

#[test]
fn agent_install_without_hooks_does_not_emit_claude_hook_frontmatter() {
    let root = unique_temp_dir("add-no-hooks");
    let source = root.join("source");
    let project = root.join("project");
    let home = root.join("home");
    let xdg = root.join("xdg");
    let pi_dir = root.join("pi");

    fs::create_dir_all(source.join("agents")).unwrap();
    fs::create_dir_all(source.join("skills/dev")).unwrap();
    fs::create_dir_all(source.join("hooks")).unwrap();
    fs::create_dir_all(&project).unwrap();
    fs::create_dir_all(&home).unwrap();
    fs::create_dir_all(&xdg).unwrap();

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
    fs::write(
        source.join("hooks/guard.sh"),
        r#"# ---
# name: guard
# event: PreToolUse
# matcher: Bash
# description: Guard bash
# ---
#!/usr/bin/env bash
exit 0
"#,
    )
    .unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_vstack"))
        .arg("add")
        .arg(&source)
        .args(["--agent", "rust", "--harness", "claude", "--copy", "-y"])
        .current_dir(&project)
        .env("HOME", &home)
        .env("XDG_CONFIG_HOME", &xdg)
        .env("PI_CODING_AGENT_DIR", &pi_dir)
        .output()
        .unwrap();

    assert!(
        output.status.success(),
        "vstack add failed\nstdout:\n{}\nstderr:\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    );

    let agent_path = project.join(".claude/agents/rust.md");
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
        !project.join(".claude/hooks/guard.sh").exists(),
        "unselected hook should not be installed"
    );

    let _ = fs::remove_dir_all(root);
}
