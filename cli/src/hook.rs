use anyhow::{Context, Result};
use std::path::{Path, PathBuf};

/// A hook parsed from a shell script with YAML-in-comments frontmatter.
#[derive(Debug, Clone)]
pub struct Hook {
    pub name: String,
    pub event: String,
    pub matcher: Option<String>,
    pub description: String,
    pub safety: Option<String>,
    pub timeout: Option<u32>,
    /// Harness ids this hook applies to (e.g. ["claude-code", "codex"]).
    /// `None` = all harnesses. Use to scope a hook away from a harness whose
    /// wire format or event semantics it doesn't support.
    pub harnesses: Option<Vec<String>>,
    /// Full script content
    pub script: String,
    /// Source file path
    pub source_path: PathBuf,
}

impl Hook {
    /// Parse a hook from a shell script file.
    /// Expects YAML-in-comments frontmatter between `# ---` delimiters.
    pub fn from_file(path: &Path) -> Result<Self> {
        let content =
            std::fs::read_to_string(path).with_context(|| format!("reading {}", path.display()))?;

        let meta = parse_hook_frontmatter(&content)
            .with_context(|| format!("parsing hook frontmatter in {}", path.display()))?;

        Ok(Hook {
            name: meta.name,
            event: meta.event,
            matcher: meta.matcher,
            description: meta.description,
            safety: meta.safety,
            timeout: meta.timeout,
            harnesses: meta.harnesses,
            script: content.clone(),
            source_path: path.to_path_buf(),
        })
    }

    /// Return `true` when this hook should be installed for the given harness.
    pub fn applies_to(&self, harness_id: &str) -> bool {
        match &self.harnesses {
            None => true,
            Some(list) => list.iter().any(|h| h == harness_id),
        }
    }

    /// Generate the safety advisory prose for harnesses without native hook support.
    /// Used by Codex (developer_instructions) and Cursor (rule content).
    pub fn safety_prose(&self) -> String {
        let mut prose = String::new();
        prose.push_str(&format!("**Safety: {}**\n", self.description));
        if let Some(ref safety) = self.safety {
            prose.push_str(&format!("{}\n", safety));
        }
        let action = match self.event.as_str() {
            "PreToolUse" => "Before executing",
            "PostToolUse" => "After executing",
            "PermissionRequest" => "When requesting permission for",
            "PostCompact" => "After context compaction",
            "TaskCompleted" => "Before marking a task complete",
            _ => "When handling",
        };
        let target = self.matcher.as_deref().unwrap_or("any tool");
        prose.push_str(&format!(
            "{action} {target} operations, the agent should verify this constraint is met.\n"
        ));
        prose
    }
}

struct HookMeta {
    name: String,
    event: String,
    matcher: Option<String>,
    description: String,
    safety: Option<String>,
    timeout: Option<u32>,
    harnesses: Option<Vec<String>>,
}

/// Parse YAML-in-comments frontmatter from a shell script.
/// Format:
/// ```
/// # ---
/// # name: hook-name
/// # event: PreToolUse
/// # matcher: Bash
/// # description: What this hook does
/// # ---
/// ```
fn parse_hook_frontmatter(content: &str) -> Result<HookMeta> {
    let mut in_frontmatter = false;
    let mut yaml_lines = Vec::new();

    for line in content.lines() {
        let trimmed = line.trim();
        if trimmed == "# ---" {
            if in_frontmatter {
                break;
            } else {
                in_frontmatter = true;
                continue;
            }
        }
        if in_frontmatter {
            // Strip leading "# " from YAML lines
            let yaml_line = if let Some(stripped) = trimmed.strip_prefix("# ") {
                stripped
            } else if let Some(stripped) = trimmed.strip_prefix('#') {
                stripped
            } else {
                anyhow::bail!("unexpected line in hook frontmatter: {}", trimmed);
            };
            yaml_lines.push(yaml_line.to_string());
        }
    }

    if yaml_lines.is_empty() {
        anyhow::bail!("no frontmatter found");
    }

    let yaml_str = yaml_lines.join("\n");
    let yaml: serde_yaml::Value = serde_yaml::from_str(&yaml_str).context("parsing hook YAML")?;

    let map = yaml
        .as_mapping()
        .context("hook frontmatter must be a YAML mapping")?;

    let name = map
        .get("name")
        .and_then(|v| v.as_str())
        .context("hook missing 'name' field")?
        .to_string();

    let event = map
        .get("event")
        .and_then(|v| v.as_str())
        .context("hook missing 'event' field")?
        .to_string();

    let matcher = map
        .get("matcher")
        .and_then(|v| v.as_str())
        .filter(|s| !s.is_empty())
        .map(|s| s.to_string());

    let description = map
        .get("description")
        .and_then(|v| v.as_str())
        .unwrap_or("")
        .to_string();

    let safety = map
        .get("safety")
        .and_then(|v| v.as_str())
        .map(|s| s.to_string());

    let timeout = map
        .get("timeout")
        .and_then(|v| v.as_u64())
        .map(|v| v as u32);

    let harnesses = match map.get("harnesses") {
        None => None,
        Some(v) => {
            if let Some(s) = v.as_str() {
                Some(
                    s.split(',')
                        .map(|t| t.trim().to_string())
                        .filter(|t| !t.is_empty())
                        .collect(),
                )
            } else if let Some(seq) = v.as_sequence() {
                Some(
                    seq.iter()
                        .filter_map(|item| item.as_str().map(|s| s.to_string()))
                        .collect(),
                )
            } else {
                anyhow::bail!("hook 'harnesses' must be a string or list of strings");
            }
        }
    };

    Ok(HookMeta {
        name,
        event,
        matcher,
        description,
        safety,
        timeout,
        harnesses,
    })
}

/// Discover all hook scripts in a directory.
#[cfg(test)]
pub fn discover_hooks(dir: &Path) -> Result<Vec<Hook>> {
    let mut hooks = Vec::new();
    if !dir.exists() {
        return Ok(hooks);
    }
    for entry in std::fs::read_dir(dir)? {
        let entry = entry?;
        let path = entry.path();
        if path.extension().is_some_and(|ext| ext == "sh") {
            match Hook::from_file(&path) {
                Ok(hook) => hooks.push(hook),
                Err(e) => eprintln!("Warning: skipping hook {}: {e}", path.display()),
            }
        }
    }
    hooks.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(hooks)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn parse_hook_script() {
        let content = r#"#!/usr/bin/env bash
# ---
# name: test-hook
# event: PreToolUse
# matcher: Bash
# description: A test hook
# safety: Prevents bad things
# timeout: 30
# ---

set -euo pipefail
echo "hello"
"#;
        let meta = parse_hook_frontmatter(content).unwrap();
        assert_eq!(meta.name, "test-hook");
        assert_eq!(meta.event, "PreToolUse");
        assert_eq!(meta.matcher.as_deref(), Some("Bash"));
        assert_eq!(meta.description, "A test hook");
        assert_eq!(meta.safety.as_deref(), Some("Prevents bad things"));
        assert_eq!(meta.timeout, Some(30));
    }

    #[test]
    fn parse_hook_with_harness_list() {
        let content = r#"#!/usr/bin/env bash
# ---
# name: claude-only
# event: TaskCompleted
# matcher:
# description: claude-only hook
# harnesses: [claude-code]
# ---

echo ok
"#;
        let meta = parse_hook_frontmatter(content).unwrap();
        assert_eq!(
            meta.harnesses.as_deref(),
            Some(&["claude-code".to_string()][..])
        );
    }

    #[test]
    fn parse_hook_with_harness_csv_string() {
        let content = r#"#!/usr/bin/env bash
# ---
# name: pair
# event: PreToolUse
# matcher: Bash
# description: limited
# harnesses: claude-code, codex
# ---

exit 0
"#;
        let meta = parse_hook_frontmatter(content).unwrap();
        assert_eq!(
            meta.harnesses.as_deref(),
            Some(&["claude-code".to_string(), "codex".to_string()][..])
        );
    }

    #[test]
    fn applies_to_defaults_to_all() {
        let hook = Hook {
            name: "h".into(),
            event: "PreToolUse".into(),
            matcher: None,
            description: String::new(),
            safety: None,
            timeout: None,
            harnesses: None,
            script: String::new(),
            source_path: PathBuf::new(),
        };
        assert!(hook.applies_to("codex"));
        assert!(hook.applies_to("claude-code"));
    }

    #[test]
    fn applies_to_respects_allowlist() {
        let hook = Hook {
            name: "h".into(),
            event: "TaskCompleted".into(),
            matcher: None,
            description: String::new(),
            safety: None,
            timeout: None,
            harnesses: Some(vec!["claude-code".into()]),
            script: String::new(),
            source_path: PathBuf::new(),
        };
        assert!(hook.applies_to("claude-code"));
        assert!(!hook.applies_to("codex"));
    }

    #[test]
    fn parse_hook_no_matcher() {
        let content = r#"#!/usr/bin/env bash
# ---
# name: post-compact
# event: PostCompact
# matcher:
# description: Warn after compaction
# ---

echo "warning"
"#;
        let meta = parse_hook_frontmatter(content).unwrap();
        assert_eq!(meta.name, "post-compact");
        assert!(meta.matcher.is_none());
    }
}
