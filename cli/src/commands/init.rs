//! `vstack init` — scaffold new agent / skill / hook files in a vstack source repo.
//!
//! This is a maintainer tool: it writes to `./agents/`, `./skills/`, or
//! `./hooks/` in the current directory, expecting that directory to be (or
//! become) a vstack source repo. End users iterating in their own project
//! don't need this — they consume packages, they don't author them.

use anyhow::{Result, bail};
use std::path::Path;

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
pub enum Kind {
    Agent,
    Skill,
    Hook,
}

impl Kind {
    fn parse(s: &str) -> Result<Self> {
        match s.trim().to_ascii_lowercase().as_str() {
            "agent" | "agents" | "a" => Ok(Kind::Agent),
            "skill" | "skills" | "s" => Ok(Kind::Skill),
            "hook" | "hooks" | "h" => Ok(Kind::Hook),
            other => bail!("unknown kind '{other}': expected agent | skill | hook"),
        }
    }
}

pub fn run(name: Option<&str>, kind: Option<&str>) -> Result<()> {
    let Some(name) = name else {
        eprintln!(
            "Usage: vstack init <name> --kind <agent|skill|hook>\n\
             \n\
             Examples:\n\
               vstack init my-agent --kind agent\n\
               vstack init my-skill --kind skill\n\
               vstack init my-hook  --kind hook\n"
        );
        return Ok(());
    };
    let Some(kind) = kind else {
        eprintln!(
            "Missing --kind. Pass one of: agent, skill, hook.\n\
             \n\
             Example: vstack init {name} --kind agent\n"
        );
        bail!("init requires --kind");
    };
    let kind = Kind::parse(kind)?;

    if name.contains('/') || name.starts_with('-') {
        bail!("invalid name '{name}': must not contain '/' or start with '-'");
    }

    match kind {
        Kind::Agent => init_agent(name),
        Kind::Skill => init_skill(name),
        Kind::Hook => init_hook(name),
    }
}

fn init_agent(name: &str) -> Result<()> {
    let path = Path::new("agents").join(format!("{name}.md"));
    if path.exists() {
        eprintln!("Agent already exists: {}", path.display());
        return Ok(());
    }
    std::fs::create_dir_all("agents")?;
    let body = format!(
        "---\nname: {name}\ndescription: TODO — describe when to use this agent\nmodel: sonnet\nrole: engineer\ncolor: green\n---\n\n# {title}\n\nTODO — describe what this agent does.\n\n## Capabilities\n\n- TODO\n\n## Guidelines\n\n- TODO\n",
        title = title_case(name),
    );
    std::fs::write(&path, body)?;
    eprintln!("Created agent: {}", path.display());
    Ok(())
}

fn init_skill(name: &str) -> Result<()> {
    let dir = Path::new("skills").join(name);
    if dir.exists() {
        eprintln!("Skill directory already exists: {}", dir.display());
        return Ok(());
    }
    std::fs::create_dir_all(&dir)?;
    let body = skill_body(name);
    std::fs::write(dir.join("SKILL.md"), body)?;
    eprintln!("Created skill: {}/SKILL.md", dir.display());
    Ok(())
}

fn skill_body(name: &str) -> String {
    format!(
        "---\nname: {name}\ndescription: TODO — describe this skill\nlicense: MIT\nuser-invocable: true\n# dependencies:\n#   required: [skill-a, skill-b]\n#   optional: [skill-c]\nmetadata:\n  author: your-name\n  # source: your-project\n  # repository: \"https://github.com/owner/repo\"\n  # bugs: \"https://github.com/owner/repo/issues\"\n  version: \"1.0.0\"\n---\n\n# {title}\n\n> **Problem with this skill?** Run `vstack report` — it files to the owning repo automatically. Do not hand-file.\n\nTODO — skill instructions.\n",
        title = title_case(name),
    )
}

fn init_hook(name: &str) -> Result<()> {
    let path = Path::new("hooks").join(format!("{name}.sh"));
    if path.exists() {
        eprintln!("Hook already exists: {}", path.display());
        return Ok(());
    }
    std::fs::create_dir_all("hooks")?;
    let body = format!(
        "#!/usr/bin/env bash\n# ---\n# name: {name}\n# event: PreToolUse       # PreToolUse | PostToolUse | PostCompact | TaskCompleted | Stop | SessionStart | UserPromptSubmit | PermissionRequest\n# matcher: Bash           # Bash | Edit|Write | (empty for all)\n# description: TODO — describe what this hook does and when it fires\n# safety: TODO — explain what risk this hook prevents\n# # harnesses: [claude-code, codex]   # optional allowlist; default = all\n# ---\n\nset -euo pipefail\n\nINPUT=$(cat)\n\n# TODO — implement hook logic. Read tool input from $INPUT (JSON), exit 0 to\n# allow the tool call, exit non-zero with a message on stderr to block it.\n\nexit 0\n",
    );
    std::fs::write(&path, body)?;
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        let mut perms = std::fs::metadata(&path)?.permissions();
        perms.set_mode(0o755);
        std::fs::set_permissions(&path, perms)?;
    }
    eprintln!("Created hook: {}", path.display());
    Ok(())
}

fn title_case(s: &str) -> String {
    s.split('-')
        .map(|word| {
            let mut chars = word.chars();
            match chars.next() {
                Some(c) => format!("{}{}", c.to_uppercase(), chars.as_str()),
                None => String::new(),
            }
        })
        .collect::<Vec<_>>()
        .join(" ")
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_kind_aliases() {
        assert_eq!(Kind::parse("agent").unwrap(), Kind::Agent);
        assert_eq!(Kind::parse("a").unwrap(), Kind::Agent);
        assert_eq!(Kind::parse("AGENTS").unwrap(), Kind::Agent);
        assert_eq!(Kind::parse("skill").unwrap(), Kind::Skill);
        assert_eq!(Kind::parse("hook").unwrap(), Kind::Hook);
        assert!(Kind::parse("widget").is_err());
    }

    #[test]
    fn title_case_handles_hyphens() {
        assert_eq!(title_case("foo-bar"), "Foo Bar");
        assert_eq!(title_case("rust"), "Rust");
        assert_eq!(title_case(""), "");
    }

    #[test]
    fn skill_scaffold_includes_ownership_metadata_guidance() {
        let body = skill_body("my-skill");

        assert!(body.contains("user-invocable: true"));
        assert!(body.contains("metadata:\n  author: your-name"));
        assert!(body.contains("  # source: your-project"));
        assert!(body.contains("  # repository: \"https://github.com/owner/repo\""));
        assert!(body.contains("  # bugs: \"https://github.com/owner/repo/issues\""));
        // A new skill must point at the routing command, not only at a bugs URL:
        // the ownership guard is a backstop for issues that bypassed it (#863).
        assert!(body.contains("Run `vstack report`"));
    }

    #[test]
    fn run_without_kind_errors() {
        let result = run(Some("foo"), None);
        assert!(result.is_err());
    }

    #[test]
    fn run_without_name_returns_help() {
        // Returns Ok(()) after printing usage, by design.
        assert!(run(None, None).is_ok());
    }

    #[test]
    fn run_rejects_invalid_names() {
        assert!(run(Some("foo/bar"), Some("agent")).is_err());
        assert!(run(Some("-foo"), Some("agent")).is_err());
    }
}
