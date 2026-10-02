//! Agent-name compatibility shared by catalog lookup and consumer planning.
//! Retain the old reads until the next major release; changelog.d/README.md's
//! release standard holds a removal that breaks a consumer to a major.

use std::collections::{BTreeMap, BTreeSet};

use crate::error::{CoreError, Result};
use crate::manifest::{HookAgents, LOCAL_SOURCE_NAME, Manifest};
use crate::model::ItemKind;
use crate::render::agent::{Selects, selects};

const ALIASES: [(&str, &str); 2] = [("generalist", "maintainer"), ("engineer", "runtime")];

/// Catalog aliases never change identities captured by adopt or fork.
pub(crate) fn resolve<'a>(name: &'a str, source: &str) -> &'a str {
    if source == LOCAL_SOURCE_NAME {
        return name;
    }
    ALIASES
        .iter()
        .find_map(|(old, new)| (*old == name).then_some(*new))
        .unwrap_or(name)
}

/// A planning pass collects all affected settings before emitting one notice
/// per old name. Repeated harness renders contribute no duplicate notice.
#[derive(Debug, Default)]
pub(crate) struct Uses {
    sources: BTreeMap<String, String>,
    settings: BTreeMap<String, BTreeSet<String>>,
}

impl Uses {
    pub(crate) fn new(manifest: &Manifest) -> Self {
        Self {
            sources: manifest
                .agents
                .iter()
                .map(|(name, decl)| (name.clone(), decl.source.clone()))
                .collect(),
            settings: BTreeMap::new(),
        }
    }

    fn source(&self, name: &str) -> &str {
        self.sources.get(name).map_or("", String::as_str)
    }

    fn name(&mut self, name: &str, setting: &str) -> String {
        let resolved = resolve(name, self.source(name));
        if resolved != name {
            self.settings
                .entry(name.to_owned())
                .or_default()
                .insert(setting.to_owned());
        }
        resolved.to_owned()
    }

    fn keys<T>(&mut self, values: &mut BTreeMap<String, T>, section: &str) -> Result<()> {
        for (old, _) in ALIASES {
            let new = resolve(old, self.source(old));
            if old == new {
                continue;
            }
            if values.contains_key(old) && values.contains_key(new) {
                return Err(CoreError::AgentAliasCollision {
                    old: old.to_owned(),
                    new: new.to_owned(),
                    setting: section.to_owned(),
                });
            }
            if let Some(value) = values.remove(old) {
                let key = self.name(old, &format!("{section}.{old}"));
                values.insert(key, value);
            }
        }
        Ok(())
    }

    pub(crate) fn manifest(&mut self, manifest: &mut Manifest) -> Result<()> {
        self.keys(&mut manifest.agents, "kendex.toml: agents")?;
        self.keys(&mut manifest.agent_skills, "kendex.toml: agent-skills")?;
        self.keys(
            &mut manifest.agent_launch_instructions,
            "kendex.toml: agent-launch-instructions",
        )?;
        self.keys(
            &mut manifest.agent_additional_instructions,
            "kendex.toml: agent-additional-instructions",
        )?;
        if let Some(names) = manifest.suppressed.get_mut(&ItemKind::Agent) {
            for name in names {
                *name = self.name(name, "kendex.toml: suppressed.agent");
            }
        }
        if let Some(forks) = manifest.forks.get_mut(&ItemKind::Agent) {
            self.keys(forks, "kendex.toml: forks.agent")?;
        }

        for (harness, agents) in &mut manifest.agent_frontmatter {
            self.keys(agents, &format!("kendex.toml: agent-frontmatter.{harness}"))?;
            for (agent, overrides) in agents {
                if let Some(names) = &mut overrides.allowed_subagents {
                    for name in names {
                        *name = self.name(
                            name,
                            &format!(
                                "kendex.toml: agent-frontmatter.{harness}.{agent}.allowed-subagents"
                            ),
                        );
                    }
                }
            }
        }
        for (index, hook) in manifest.custom_hooks.iter_mut().enumerate() {
            let names = match &mut hook.agents {
                HookAgents::One(name) => std::slice::from_mut(name),
                HookAgents::Many(names) => names.as_mut_slice(),
            };
            for name in names {
                if selects(name) == Selects::Named {
                    *name = self.name(name, &format!("kendex.toml: custom-hooks[{index}].agents"));
                }
            }
        }
        for (skill, instructions) in &mut manifest.skill_instructions {
            *instructions = self.labels(
                instructions,
                &format!("kendex.toml: skill-instructions.{skill}"),
            );
        }
        for (section, agents) in [
            (
                "agent-launch-instructions",
                &mut manifest.agent_launch_instructions,
            ),
            (
                "agent-additional-instructions",
                &mut manifest.agent_additional_instructions,
            ),
        ] {
            for (agent, instructions) in agents {
                *instructions =
                    self.labels(instructions, &format!("kendex.toml: {section}.{agent}"));
            }
        }
        Ok(())
    }

    /// Only complete agent-label tokens change. A longer custom label such
    /// as agent:engineer-extra is not an alias.
    pub(crate) fn labels(&mut self, text: &str, setting: &str) -> String {
        let mut output = String::with_capacity(text.len());
        let mut end = 0;
        for (start, _) in text.match_indices("agent:") {
            if start > 0 && label_char(text[..start].chars().next_back().unwrap_or(' ')) {
                continue;
            }
            let name_start = start + "agent:".len();
            let name_end = text[name_start..]
                .find(|c: char| !label_char(c))
                .map_or(text.len(), |offset| name_start + offset);
            let name = text[name_start..name_end].trim_end_matches('.');
            let name_end = name_start + name.len();
            if resolve(name, self.source(name)) == name {
                continue;
            }
            output.push_str(&text[end..name_start]);
            output.push_str(&self.name(name, setting));
            end = name_end;
        }
        output.push_str(&text[end..]);
        output
    }

    /// The consumer taxonomy is an existing setting, not a template default.
    /// Edit its value in place so comments and unrelated settings survive.
    pub(crate) fn settings(&mut self, text: &str, path: &std::path::Path) -> Result<String> {
        if !ALIASES
            .iter()
            .any(|(old, _)| text.contains(&format!("agent:{old}")))
        {
            return Ok(text.to_owned());
        }
        let mut doc: toml_edit::DocumentMut =
            text.parse()
                .map_err(|error: toml_edit::TomlError| CoreError::TomlParse {
                    path: path.to_path_buf(),
                    message: error.to_string(),
                })?;
        let Some(item) = doc
            .get_mut("env")
            .and_then(|env| env.get_mut("LINEAR_AGENT_LABELS"))
        else {
            return Ok(text.to_owned());
        };
        let Some(value) = item.as_value_mut() else {
            return Ok(text.to_owned());
        };
        let Some(original) = value.as_str() else {
            return Ok(text.to_owned());
        };
        let updated = self.labels(
            original,
            &format!("{}: env.LINEAR_AGENT_LABELS", path.display()),
        );
        if original == updated {
            return Ok(text.to_owned());
        }
        let decor = value.decor().clone();
        *value = toml_edit::Value::from(updated);
        *value.decor_mut() = decor;
        Ok(doc.to_string())
    }

    pub(crate) fn extend(&mut self, other: Self) {
        for (name, settings) in other.settings {
            self.settings.entry(name).or_default().extend(settings);
        }
    }

    pub(crate) fn warnings(&self) -> Vec<crate::engine::ItemWarning> {
        self.settings.iter().map(|(old, settings)| crate::engine::ItemWarning {
            kind: ItemKind::Agent,
            name: old.clone(),
            harness: None,
            message: format!("agent name '{old}' is deprecated; use '{}'; legacy settings: {}", resolve(old, self.source(old)), settings.iter().cloned().collect::<Vec<_>>().join(", ")),
            remediation: Some(format!("Rename '{old}' to '{}' in the listed settings. Compatibility remains until the next major release.", resolve(old, self.source(old)))),
        }).collect()
    }
}

fn label_char(c: char) -> bool {
    c.is_alphanumeric() || matches!(c, '_' | '-' | ':' | '/' | '.')
}
