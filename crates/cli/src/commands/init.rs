use std::fs;
use std::path::Path;

use super::{CliResult, out, say};

/// Maintainer scaffolding: create a source-catalog item skeleton in the
/// current directory (v1 contract: no name → usage + exit 0; a name
/// without --kind, or with '/' or a leading '-', → error).
pub fn run(name: Option<String>, kind: Option<String>) -> CliResult {
    let Some(name) = name else {
        say("usage: kendex init <name> --kind agent|skill|hook");
        return Ok(());
    };
    let Some(kind) = kind else {
        return Err("pass --kind agent|skill|hook".into());
    };
    if name.contains('/') || name.starts_with('-') {
        return Err("item names must not contain '/' or start with '-'".into());
    }
    let cwd = std::env::current_dir()?;
    match kind.as_str() {
        "agent" | "agents" | "a" => {
            let path = cwd.join("agents").join(format!("{name}.md"));
            write_new(
                &path,
                &format!(
                    "---\nname: {name}\ndescription: What this agent is for. Trigger conditions.\nmodel: sonnet\nrole: engineer\n---\n\n# {name}\n\nOperating instructions.\n"
                ),
            )?;
            out(&format!("created {}", path.display()));
        }
        "skill" | "skills" | "s" => {
            let path = cwd.join("skills").join(&name).join("SKILL.md");
            write_new(
                &path,
                &format!(
                    "---\nname: {name}\ndescription: When to reach for this skill.\n---\n\n# {name}\n\nHow to use it. The body is do-only — commands to run, rules to follow; never how it works inside.\n"
                ),
            )?;
            out(&format!("created {}", path.display()));
        }
        "hook" | "hooks" | "h" => {
            let path = cwd.join("hooks").join(format!("{name}.sh"));
            write_new(
                &path,
                &format!(
                    "#!/usr/bin/env bash\n# ---\n# name: {name}\n# event: PreToolUse\n# matcher: Bash\n# description: What this hook protects against.\n# ---\nset -euo pipefail\nexit 0\n"
                ),
            )?;
            out(&format!("created {}", path.display()));
        }
        other => return Err(format!("unknown --kind '{other}' (agent | skill | hook)").into()),
    }
    declare_catalog(&cwd)?;
    Ok(())
}

/// What a freshly declared catalog says about itself. The `[bundles]` keys
/// come from the list that reads them rather than from a copy: a marker
/// teaching a shape no reader looks at is how the four kendex bundles
/// shipped installing nothing.
fn catalog_marker() -> String {
    format!(
        "# This file marks the folder as a kendex catalog. Items live in\n\
         # agents/, skills/, hooks/, commands/ and mcp/. Optional tables:\n\
         # [marketplace] name, description, author, license, tags\n\
         # [bundles.<name>] description, then one list of bare names per\n\
         # kind: {}\n",
        kendex_core::source::bundles::member_list_keys()
    )
}

/// Executable kinds install only from a catalog that declared kendex's
/// layout — a bare `hooks/` folder is repository tooling. Scaffolding
/// therefore declares the folder, once, and never touches a declaration
/// that already exists.
fn declare_catalog(cwd: &Path) -> CliResult {
    let control = cwd.join(kendex_core::manifest::MANIFEST_FILE);
    if control.exists() {
        return Ok(());
    }
    fs::write(&control, catalog_marker())?;
    say(&format!("declared the catalog ({})", control.display()));
    Ok(())
}

fn write_new(path: &Path, content: &str) -> CliResult {
    if path.exists() {
        return Err(format!("{} already exists", path.display()).into());
    }
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    }
    fs::write(path, content)?;
    Ok(())
}
