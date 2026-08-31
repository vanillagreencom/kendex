use std::fmt;

use toml::Table;
use toml::Value;

/// One validation problem, always paired with a machine-actionable fix.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Finding {
    pub location: String,
    pub problem: String,
    pub fix: String,
}

impl fmt::Display for Finding {
    /// One finding, one line. `CoreError::ManifestInvalid` joins these
    /// with newlines, and a surface printing that message keeps the breaks
    /// — so the parts are escaped here, where the message is composed. A
    /// location is a key somebody wrote in their own manifest, and a TOML
    /// key can hold a newline; unescaped, one key would forge a finding.
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(
            f,
            "{}: {} — fix: {}",
            crate::names::shown(&self.location),
            crate::names::shown(&self.problem),
            crate::names::shown(&self.fix)
        )
    }
}

/// The findings of one manifest, as the lines
/// [`crate::error::CoreError::ManifestInvalid`] carries. The only way to
/// build that message, so a finding cannot reach the door that keeps line
/// breaks without going through the escape above.
pub fn joined(findings: &[Finding]) -> String {
    findings
        .iter()
        .map(Finding::to_string)
        .collect::<Vec<_>>()
        .join("\n")
}

const TOP_LEVEL: &[&str] = &[
    "schema",
    "sources",
    "install",
    "agents",
    "skills",
    "hooks",
    "commands",
    "mcp-servers",
    "plugins",
    "pi-extensions",
    "bundles",
    "suppressed",
    "optional-dependencies",
    "agent-skills",
    "agent-launch-instructions",
    "agent-additional-instructions",
    "skill-instructions",
    "agent-frontmatter",
    "custom-hooks",
    "forks",
];

/// What one `[sources.<name>]` table may hold. `rev` names the revision of
/// a remote to read — a commit id pins, a tag or branch tracks.
const SOURCE_KEYS: &[&str] = &["repo", "path", "rev", "enabled"];

/// The tools a manifest may name: the ones kendex writes to. Read from the
/// capability table rather than listed here, so a tool can never be
/// accepted as a target before anything it declares would be installed.
fn known_events() -> String {
    crate::hook::EVENTS
        .iter()
        .map(|event| event.name)
        .collect::<Vec<_>>()
        .join(", ")
}

fn harnesses() -> Vec<&'static str> {
    crate::model::HarnessId::ALL
        .into_iter()
        .filter(|harness| crate::harness::installable(*harness))
        .map(crate::model::HarnessId::name)
        .collect()
}

const FRONTMATTER_KEYS: &[&str] = &[
    "color",
    "model",
    "deny-tools",
    "allow-tools",
    "allowed-subagents",
    "pane",
    "background",
    "effort",
    "isolation",
    "memory",
    "mode",
    "sandbox-mode",
    "model-reasoning-effort",
    "nickname-candidates",
];

pub fn validate(table: &Table) -> Vec<Finding> {
    let mut findings = Vec::new();

    let schema = table.get("schema").and_then(Value::as_integer);
    if schema != Some(i64::from(super::MANIFEST_SCHEMA)) {
        findings.push(Finding {
            location: "schema".into(),
            problem: "missing or unsupported schema version".into(),
            fix: format!("set schema = {}", super::MANIFEST_SCHEMA),
        });
    }
    for key in table.keys() {
        if !TOP_LEVEL.contains(&key.as_str()) {
            findings.push(Finding {
                location: key.clone(),
                problem: "unknown table or key".into(),
                fix: format!("remove it, or use one of: {}", TOP_LEVEL.join(", ")),
            });
        }
    }
    validate_sources(table, &mut findings);
    validate_install(table, &mut findings);
    items::validate_items(table, &mut findings);
    items::validate_plugins(table, &mut findings);
    items::validate_dependency_choices(table, &mut findings);
    items::validate_forks(table, &mut findings);
    validate_frontmatter(table, &mut findings);
    validate_hooks(table, &mut findings);
    findings
}

fn validate_sources(table: &Table, findings: &mut Vec<Finding>) {
    let Some(sources) = table.get("sources").and_then(Value::as_table) else {
        return;
    };
    for (name, decl) in sources {
        let location = format!("sources.{name}");
        let Some(decl) = decl.as_table() else {
            findings.push(Finding {
                location,
                problem: "source must be a table".into(),
                fix: "write [sources.<name>] with repo = \"owner/repo\" or path = \"…\"".into(),
            });
            continue;
        };
        for key in decl.keys() {
            if !SOURCE_KEYS.contains(&key.as_str()) {
                findings.push(Finding {
                    location: location.clone(),
                    problem: format!("unknown key '{key}'"),
                    fix: format!("remove it, or use one of: {}", SOURCE_KEYS.join(", ")),
                });
            }
        }
        let has_repo = decl.get("repo").is_some_and(|v| v.is_str());
        let has_path = decl.get("path").is_some_and(|v| v.is_str());
        if has_repo == has_path {
            findings.push(Finding {
                location: location.clone(),
                problem: "a source needs exactly one of repo or path".into(),
                fix: "keep either repo = \"owner/repo\" or path = \"…\", not both or neither"
                    .into(),
            });
        }
        if let Some(rev) = decl.get("rev") {
            if !rev.is_str() {
                findings.push(Finding {
                    location: location.clone(),
                    problem: "rev must be a string".into(),
                    fix: "write rev = \"<commit, tag or branch>\"".into(),
                });
            } else if !has_repo {
                findings.push(Finding {
                    location,
                    problem: "only a repo has revisions".into(),
                    fix: "remove rev, or point this source at repo = \"owner/repo\"".into(),
                });
            }
        }
    }
}

fn validate_install(table: &Table, findings: &mut Vec<Finding>) {
    let declared = table
        .get("install")
        .and_then(Value::as_table)
        .and_then(|install| install.get("harnesses"))
        .and_then(Value::as_array);
    for entry in declared.into_iter().flatten() {
        let name = entry.as_str().unwrap_or_default();
        if !harnesses().contains(&name) {
            findings.push(Finding {
                location: "install.harnesses".into(),
                problem: format!("unknown harness '{name}'"),
                fix: format!("use one of: {}", harnesses().join(", ")),
            });
        }
    }
}

fn validate_frontmatter(table: &Table, findings: &mut Vec<Finding>) {
    let Some(frontmatter) = table.get("agent-frontmatter").and_then(Value::as_table) else {
        return;
    };
    for (harness, agents) in frontmatter {
        if !harnesses().contains(&harness.as_str()) {
            findings.push(Finding {
                location: format!("agent-frontmatter.{harness}"),
                problem: format!("unknown harness '{harness}'"),
                fix: format!("use one of: {}", harnesses().join(", ")),
            });
            continue;
        }
        let Some(agents) = agents.as_table() else {
            continue;
        };
        for (agent, overrides) in agents {
            let Some(overrides) = overrides.as_table() else {
                continue;
            };
            for key in overrides.keys() {
                if !FRONTMATTER_KEYS.contains(&key.as_str()) {
                    findings.push(Finding {
                        location: format!("agent-frontmatter.{harness}.{agent}.{key}"),
                        problem: "unknown frontmatter override".into(),
                        fix: format!("use one of: {}", FRONTMATTER_KEYS.join(", ")),
                    });
                }
            }
        }
    }
}

const HOOK_KEYS: &[&str] = &[
    "name",
    "event",
    "matcher",
    "command",
    "description",
    "timeout",
    "harnesses",
    "enabled",
    "agents",
];

/// Longest hook run any harness accepts; Gemini counts milliseconds in a
/// u32, and an hour stays far inside that after the ×1000.
const HOOK_TIMEOUT_MAX: i64 = 3600;

fn valid_hook_name(name: &str) -> bool {
    !name.is_empty()
        && name.starts_with(|c: char| c.is_ascii_lowercase() || c.is_ascii_digit())
        && name
            .chars()
            .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == '-')
}

fn validate_hooks(table: &Table, findings: &mut Vec<Finding>) {
    let Some(hooks) = table.get("custom-hooks").and_then(Value::as_array) else {
        return;
    };
    // A custom hook's lock key is `hook:<name>:<harness>`, the same shape a
    // catalog hook gets — so its name must not collide with one, or with a
    // sibling's, or the two would own each other's artifacts.
    let catalog_names: Vec<&str> = table
        .get("hooks")
        .and_then(Value::as_table)
        .map(|t| t.keys().map(String::as_str).collect())
        .unwrap_or_default();
    let mut seen: Vec<&str> = Vec::new();
    for (index, hook) in hooks.iter().enumerate() {
        let Some(hook) = hook.as_table() else {
            continue;
        };
        for key in hook.keys() {
            if !HOOK_KEYS.contains(&key.as_str()) {
                findings.push(Finding {
                    location: format!("custom-hooks[{index}]"),
                    problem: format!("unknown key '{key}'"),
                    fix: format!("remove it, or use one of: {}", HOOK_KEYS.join(", ")),
                });
            }
        }
        for required in ["event", "command"] {
            if !hook.get(required).is_some_and(|v| v.is_str()) {
                findings.push(Finding {
                    location: format!("custom-hooks[{index}]"),
                    problem: format!("missing {required}"),
                    fix: format!("add {required} = \"…\""),
                });
            }
        }
        // An event nobody fires is a hook that never runs, and nothing
        // downstream would have said so: it renders into the agent file
        // exactly as written and simply never matches.
        let event = hook.get("event").and_then(Value::as_str);
        if let Some(event) = event.filter(|name| !crate::hook::known_event(name)) {
            findings.push(Finding {
                location: format!("custom-hooks[{index}].event"),
                problem: format!("no harness fires '{event}'"),
                fix: format!("use one of: {}", known_events()),
            });
        }
        if let Some(name) = hook.get("name") {
            let location = format!("custom-hooks[{index}].name");
            match name.as_str() {
                None => findings.push(Finding {
                    location,
                    problem: "name must be a string".into(),
                    fix: "write name = \"my-hook\"".into(),
                }),
                Some(name) if !valid_hook_name(name) => findings.push(Finding {
                    location,
                    problem: format!("'{name}' is not a usable hook name"),
                    fix:
                        "use lowercase letters, digits and dashes, starting with a letter or digit"
                            .into(),
                }),
                Some(name) if seen.contains(&name) => findings.push(Finding {
                    location,
                    problem: format!("'{name}' names two custom hooks"),
                    fix: "give each custom hook its own name".into(),
                }),
                Some(name) if catalog_names.contains(&name) => findings.push(Finding {
                    location,
                    problem: format!("'{name}' is already an installed hook"),
                    fix: "pick a name no [hooks] entry uses".into(),
                }),
                Some(name) => seen.push(name),
            }
        }
        if let Some(timeout) = hook.get("timeout") {
            let seconds = timeout.as_integer();
            if !seconds.is_some_and(|s| (1..=HOOK_TIMEOUT_MAX).contains(&s)) {
                findings.push(Finding {
                    location: format!("custom-hooks[{index}].timeout"),
                    problem: "timeout must be whole seconds, 1 to 3600".into(),
                    fix: "write timeout = 30".into(),
                });
            }
        }
        for entry in hook
            .get("harnesses")
            .and_then(Value::as_array)
            .into_iter()
            .flatten()
        {
            let name = entry.as_str().unwrap_or_default();
            if !harnesses().contains(&name) {
                findings.push(Finding {
                    location: format!("custom-hooks[{index}].harnesses"),
                    problem: format!("unknown harness '{name}'"),
                    fix: format!("use one of: {}", harnesses().join(", ")),
                });
            }
        }
    }
}

mod items;

#[cfg(test)]
mod tests;
