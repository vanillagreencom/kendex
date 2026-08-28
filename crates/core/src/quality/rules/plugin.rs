//! Where a plugin came from and what it runs while installing itself.
//!
//! Both rules read files. At plan time a declared plugin is one switch in a
//! settings file and there are no files anywhere to read, so both report
//! themselves not applicable there rather than passing an item nobody
//! looked at.

use crate::model::ItemKind;

use super::super::{PluginSources, UNREADABLE_PLUGIN};
use super::{AuditRule, Content, Finding, Outcome, Prepared, Severity};

pub(super) fn rules() -> Vec<Box<dyn AuditRule>> {
    vec![
        Box::new(PluginSourceTrust),
        Box::new(PluginLifecycleScripts),
    ]
}

fn sources(prepared: &Prepared) -> Result<&PluginSources, Outcome> {
    if prepared.input.kind != ItemKind::Plugin {
        return Err(Outcome::OutOfScope);
    }
    match &prepared.input.content {
        Content::Plugin(sources) => Ok(sources),
        Content::Unread { why } => Err(Outcome::NotApplicable(why)),
        _ => Err(Outcome::NotApplicable(UNREADABLE_PLUGIN)),
    }
}

struct PluginSourceTrust;

impl AuditRule for PluginSourceTrust {
    fn id(&self) -> &'static str {
        "plugin-source-trust"
    }

    fn check(&self, prepared: &Prepared) -> Outcome {
        let sources = match sources(prepared) {
            Ok(sources) => sources,
            Err(outcome) => return outcome,
        };
        let mut findings = Vec::new();
        let location = prepared.input.location.clone();
        if sources.manifests.is_empty() {
            findings.push(Finding {
                rule: self.id().to_owned(),
                severity: Severity::Low,
                location: location.clone(),
                line: None,
                message: "this plugin carries no manifest, so nothing on disk says what it is or who wrote it".to_owned(),
                remediation: "ask the author for a plugin.json, or remove the plugin".to_owned(),
            });
        }
        if sources.git_origin.is_none() {
            findings.push(Finding {
                rule: self.id().to_owned(),
                severity: Severity::Medium,
                location,
                line: None,
                message: "this plugin's files are not from a tracked repository, so there is no history to review and no upstream to compare against".to_owned(),
                remediation: "install it from its published repository instead of a loose copy".to_owned(),
            });
        }
        Outcome::Ran(findings)
    }
}

/// Script names npm runs by itself, before anyone has read the package.
const LIFECYCLE: &[&str] = &["preinstall", "install", "postinstall", "prepare"];

/// What turns an install script from housekeeping into a fetch.
const REACHES_OUT: &[&str] = &["curl", "wget", "sh ", "bash", "eval", "nc ", "python -c"];

struct PluginLifecycleScripts;

impl AuditRule for PluginLifecycleScripts {
    fn id(&self) -> &'static str {
        "plugin-lifecycle-scripts"
    }

    fn check(&self, prepared: &Prepared) -> Outcome {
        let sources = match sources(prepared) {
            Ok(sources) => sources,
            Err(outcome) => return outcome,
        };
        let Some(scripts) = sources.package_json.as_deref().and_then(script_table) else {
            return Outcome::Ran(Vec::new());
        };
        let findings = LIFECYCLE
            .iter()
            .filter_map(|name| scripts.get(*name).and_then(|v| v.as_str()).map(|body| (name, body)))
            .map(|(name, body)| {
                let lower = body.to_ascii_lowercase();
                let reaches = REACHES_OUT.iter().any(|verb| lower.contains(verb));
                Finding {
                    rule: self.id().to_owned(),
                    severity: match reaches {
                        true => Severity::Medium,
                        false => Severity::Low,
                    },
                    location: format!("{}/package.json", prepared.input.location),
                    line: None,
                    message: match reaches {
                        true => format!(
                            "this plugin's `{name}` script fetches and runs something while it installs, before anyone has read it"
                        ),
                        false => format!("this plugin runs a `{name}` script while it installs"),
                    },
                    remediation:
                        "read the script before enabling the plugin; ask the author to move setup into a command the user runs on purpose"
                            .to_owned(),
                }
            })
            .collect();
        Outcome::Ran(findings)
    }
}

fn script_table(package_json: &str) -> Option<serde_json::Map<String, serde_json::Value>> {
    let value: serde_json::Value = serde_json::from_str(package_json).ok()?;
    value.get("scripts")?.as_object().cloned()
}
