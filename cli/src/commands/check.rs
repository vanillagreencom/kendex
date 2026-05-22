use crate::config::{self, LockEntry, LockFile};
use crate::frontmatter::split_yaml_frontmatter;
use crate::harness::Harness;
use crate::scope::ScopeFilter;
use anyhow::Result;
use std::path::{Path, PathBuf};

fn skill_disk_path(global: bool, name: &str) -> PathBuf {
    if global {
        config::global_state_dir().join("skills").join(name)
    } else {
        config::project_root()
            .join(".agents")
            .join("skills")
            .join(name)
    }
}

fn find_installed_agent_file(global: bool, agent: &LockEntry) -> Option<PathBuf> {
    for harness in Harness::ALL {
        let dir = harness.agents_dir(global);
        let path = dir.join(format!("{}.md", agent.name));
        if path.exists() {
            return Some(path);
        }
        let toml = dir.join(format!("{}.toml", agent.name));
        if toml.exists() {
            return Some(toml);
        }
    }
    None
}

fn parse_skills_field(frontmatter: &str) -> Vec<String> {
    for line in frontmatter.lines() {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix("skills:") {
            let rest = rest.trim();
            // YAML inline list `skills: a, b, c` (Cursor / Claude / OpenCode
            // generated agents) — split on commas.
            if !rest.is_empty() && !rest.starts_with('[') {
                return rest
                    .split(',')
                    .map(|s| s.trim().trim_matches('"').trim_matches('\''))
                    .filter(|s| !s.is_empty())
                    .map(String::from)
                    .collect();
            }
            // YAML inline list `skills: [a, b]`
            if let Some(stripped) = rest.strip_prefix('[').and_then(|r| r.strip_suffix(']')) {
                return stripped
                    .split(',')
                    .map(|s| s.trim().trim_matches('"').trim_matches('\''))
                    .filter(|s| !s.is_empty())
                    .map(String::from)
                    .collect();
            }
        }
    }
    Vec::new()
}

fn read_agent_skills(path: &Path) -> Vec<String> {
    let Ok(content) = std::fs::read_to_string(path) else {
        return Vec::new();
    };
    if let Ok((fm, _body)) = split_yaml_frontmatter(&content) {
        return parse_skills_field(&fm);
    }
    // Codex agents use [developer_instructions] TOML, not YAML frontmatter.
    // Detect skill blocks via a `skills =` TOML line.
    for line in content.lines() {
        let trimmed = line.trim_start();
        if let Some(rest) = trimmed.strip_prefix("skills =") {
            let rest = rest.trim();
            if let Some(stripped) = rest.strip_prefix('[').and_then(|r| r.strip_suffix(']')) {
                return stripped
                    .split(',')
                    .map(|s| s.trim().trim_matches('"').trim_matches('\''))
                    .filter(|s| !s.is_empty())
                    .map(String::from)
                    .collect();
            }
        }
    }
    Vec::new()
}

pub fn run(scope: ScopeFilter) -> Result<()> {
    // Check CLI version
    let local_version = env!("CARGO_PKG_VERSION");
    let local_hash = env!("VSTACK_GIT_HASH");
    eprintln!("vstack {} ({})", local_version, local_hash);

    if let Some(remote_version) = crate::commands::update::get_remote_version() {
        if remote_version != local_version {
            eprintln!(
                "  CLI update available: {} → {}  (run: vstack update)",
                local_version, remote_version
            );
        } else {
            eprintln!("  CLI is up to date.");
        }
    }

    // Check installed items
    let mut missing_skill_refs = 0;
    for &global in scope.globals() {
        let lock_path = config::lock_file_path(global);
        let lock = LockFile::load(&lock_path)?;

        let scope_label = if global { "global" } else { "project" };

        // Scan disk for skills that should be in the lock but aren't
        let disk_skills = config::scan_installed_skills_on_disk(global);
        let lock_names: std::collections::HashSet<&str> =
            lock.entries.keys().map(|s| s.as_str()).collect();
        let orphaned: Vec<&str> = disk_skills
            .iter()
            .filter(|d| !lock_names.contains(d.name.as_str()))
            .map(|d| d.name.as_str())
            .collect();

        // Check for lock entries whose files are missing from disk
        let disk_skill_names: std::collections::HashSet<&str> =
            disk_skills.iter().map(|d| d.name.as_str()).collect();
        let phantom: Vec<&str> = lock
            .entries
            .iter()
            .filter(|(_, e)| {
                e.kind == config::ItemKind::Skill && !disk_skill_names.contains(e.name.as_str())
            })
            .filter(|(_, e)| {
                // Only report if the canonical dir is truly gone
                let canonical = if global {
                    config::global_state_dir().join("skills").join(&e.name)
                } else {
                    config::project_root()
                        .join(".agents")
                        .join("skills")
                        .join(&e.name)
                };
                !canonical.exists()
            })
            .map(|(name, _)| name.as_str())
            .collect();

        if lock.entries.is_empty() && orphaned.is_empty() {
            continue;
        }

        eprintln!("\n{scope_label} scope: {} item(s)", lock.entries.len());

        let mut outdated = 0;
        for entry in lock.entries.values() {
            let status = check_staleness(entry);
            if status == "outdated" {
                outdated += 1;
            }
            let icon = match status {
                "ok" => "✓",
                "outdated" => "!",
                _ => "?",
            };
            eprintln!(
                "  {icon} {} ({}){}",
                entry.name,
                entry.kind,
                if status == "outdated" {
                    "  ← outdated"
                } else {
                    ""
                }
            );
        }

        if outdated > 0 {
            eprintln!("\n  {outdated} outdated — run `vstack add` to update");
        }

        if !orphaned.is_empty() {
            eprintln!(
                "\n  {} installed on disk but missing from lock:",
                orphaned.len()
            );
            for name in &orphaned {
                eprintln!("    ? {name} (skill)");
            }
            eprintln!("  Run `vstack add` to recover these entries.");
        }

        if !phantom.is_empty() {
            eprintln!("\n  {} in lock but missing from disk:", phantom.len());
            for name in &phantom {
                eprintln!("    ✗ {name} (skill)");
            }
            eprintln!("  Run `vstack add` to clean up, or `vstack remove` to remove.");
        }

        // vstack#71: for every installed agent, verify each skill its
        // frontmatter references is actually installed. The bug bites
        // when [role-skills] declares a skill the user never ran
        // `vstack add --skill <name>` for, and the agent ends up
        // referencing a SKILL.md that does not exist on disk.
        let installed_skill_names: std::collections::HashSet<String> = lock
            .entries
            .values()
            .filter(|e| e.kind == config::ItemKind::Skill)
            .map(|e| e.name.clone())
            .chain(
                config::scan_installed_skills_on_disk(global)
                    .into_iter()
                    .map(|d| d.name),
            )
            .collect();

        let agents: Vec<&LockEntry> = lock
            .entries
            .values()
            .filter(|e| e.kind == config::ItemKind::Agent)
            .collect();
        let mut agents_with_missing: Vec<(String, Vec<String>)> = Vec::new();
        for agent in agents {
            let Some(agent_path) = find_installed_agent_file(global, agent) else {
                continue;
            };
            let skills = read_agent_skills(&agent_path);
            let mut missing: Vec<String> = Vec::new();
            for skill_name in skills {
                if installed_skill_names.contains(&skill_name) {
                    continue;
                }
                if skill_disk_path(global, &skill_name)
                    .join("SKILL.md")
                    .exists()
                {
                    continue;
                }
                missing.push(skill_name);
            }
            if !missing.is_empty() {
                missing.sort();
                missing.dedup();
                agents_with_missing.push((agent.name.clone(), missing));
            }
        }
        if !agents_with_missing.is_empty() {
            eprintln!(
                "\n  {} agent(s) reference uninstalled skill(s):",
                agents_with_missing.len()
            );
            for (agent_name, missing) in &agents_with_missing {
                for skill_name in missing {
                    eprintln!(
                        "    ✗ agent {agent_name} references skill {skill_name} but it's not installed; run `vstack add --skill {skill_name} .` or `vstack add` to auto-install dependent skills."
                    );
                    missing_skill_refs += 1;
                }
            }
        }
    }

    if missing_skill_refs > 0 {
        anyhow::bail!(
            "{missing_skill_refs} skill reference(s) missing from install; see warnings above"
        );
    }
    Ok(())
}

fn check_staleness(entry: &LockEntry) -> &'static str {
    if config::is_source_changed(entry) {
        "outdated"
    } else {
        "ok"
    }
}

#[cfg(test)]
mod parse_skills_field_tests {
    use super::parse_skills_field;

    #[test]
    fn comma_separated_inline() {
        // Real-world shape from .claude/agents/<name>.md.
        let fm = "name: reviewer-error\nskills: linear-dev, linear\nrole: engineer";
        let skills = parse_skills_field(fm);
        assert_eq!(skills, vec!["linear-dev".to_string(), "linear".to_string()]);
    }

    #[test]
    fn yaml_inline_list_brackets() {
        let fm = "name: rust\nskills: [rust-tooling, rust-runtime, \"rust-unsafe\"]";
        let skills = parse_skills_field(fm);
        assert_eq!(
            skills,
            vec![
                "rust-tooling".to_string(),
                "rust-runtime".to_string(),
                "rust-unsafe".to_string(),
            ]
        );
    }

    #[test]
    fn quoted_values_are_unwrapped() {
        let fm = "skills: \"github\", 'linear'";
        let skills = parse_skills_field(fm);
        assert_eq!(skills, vec!["github".to_string(), "linear".to_string()]);
    }

    #[test]
    fn empty_or_missing_field_yields_empty_vec() {
        assert!(parse_skills_field("name: x").is_empty());
        assert!(parse_skills_field("skills:").is_empty());
        assert!(parse_skills_field("skills: []").is_empty());
    }
}
