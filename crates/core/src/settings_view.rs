//! What a scope's settings amount to, per skill: the keys a skill's
//! template declares, what each one says it is for, its default, and
//! where the consumer's file currently stands on it.
//!
//! A skill is in exactly one of four states here, and none of them is
//! silence. It ships no template; its template could not be read at all
//! (the source has not arrived, the skill is switched off, the source no
//! longer carries it); the strict reader refused the template; or it has
//! rows. The third is the one worth being careful about: seeding is
//! lenient, so a template the strict reader refuses may well have seeded
//! keys into the file anyway — "invalid" never means "nothing is there".
//!
//! Global scope has no settings file at all, and says so as an answer
//! rather than an empty list, so a reader's "does this place have
//! settings" resolves to false instead of staying unasked.

use std::collections::BTreeMap;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::base::Base;
use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, LockFile, lock_path};
use crate::manifest::{self, ManifestFile};
use crate::model::Scope;
use crate::settings_file::{Current, current_of, sites};
use crate::settings_template::{TemplateFinding, read};

/// What a scope pass found where a skill's settings template would be.
/// Carried on the desired state so the strict reading happens once, here,
/// and never in the planning path.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum TemplateSource {
    /// The template's bytes, as the skill's source ships them.
    Text(String),
    /// The skill ships no `kendex.settings.toml.example`.
    Absent,
    /// Nothing here could read one, and why.
    Unreadable(String),
}

/// One skill's settings, in whichever of the four states it is in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum SkillTemplate {
    /// This skill declares no settings.
    NoTemplate,
    /// Its template is out of reach here — a source that has not arrived,
    /// a skill switched off, a source that no longer carries it.
    Unreadable {
        reason: String,
    },
    /// The template does not hold to the authoring contract. Seeding is
    /// lenient and may have seeded keys from it regardless, so this says
    /// nothing about what the settings file contains.
    Invalid {
        findings: Vec<TemplateFinding>,
    },
    Rows {
        rows: Vec<SettingsRow>,
    },
}

/// One key a skill declares, and where the consumer's file stands on it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SettingsRow {
    pub key: String,
    /// The template's comment block, `#` markers stripped — what the
    /// author wrote to explain the key.
    pub explainer: Vec<String>,
    pub default: String,
    /// Only a [`Current::Value`] is comparable with `default`; the other
    /// two say what is in the way instead.
    pub current: Current,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SkillSettings {
    pub skill: String,
    pub template: SkillTemplate,
}

/// Everything one place's settings view needs, read together.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ScopeSettings {
    /// Whether this place has a settings file at all. Global never does —
    /// skills seed on a project install alone — and false with no skills
    /// is the whole answer for it, never "not asked yet".
    pub applies: bool,
    /// One entry per skill this place installs, by name.
    pub skills: Vec<SkillSettings>,
    /// The settings file as it was when these rows were read. An edit
    /// written from them carries it back, and a file that moved in
    /// between is refused rather than overwritten.
    pub base: Base,
}

/// Read one place's settings: what every installed skill declares, and
/// what the file currently says about each key.
pub fn scope_settings(env: &Env, scope: &Scope) -> Result<ScopeSettings> {
    let scope = &scope.canonical();
    let Scope::Project { root } = scope else {
        return Ok(ScopeSettings {
            applies: false,
            skills: Vec::new(),
            base: Base::absent(),
        });
    };
    let current = crate::fs::read_if_exists(&crate::settings_seed::settings_file_path(root))?;
    let base = current.as_deref().map_or_else(Base::absent, Base::of);
    let empty = ScopeSettings {
        applies: true,
        skills: Vec::new(),
        base: base.clone(),
    };
    // A place whose files this build reads but will not write declares
    // nothing it could act on — the same posture `plan_apply` takes.
    let ManifestFile::Current(manifest) = manifest::load(&manifest::manifest_path(env, scope))?
    else {
        return Ok(empty);
    };
    let lock = match crate::lock::load_file(&lock_path(env, scope))? {
        LockFile::Current(lock) => lock,
        // A place that has never installed still declares skills, and
        // what they declare is what this view is for — the same reading
        // `plan_apply` gives an absent lock.
        LockFile::Absent => Lock {
            version: crate::lock::LOCK_VERSION,
            ..Lock::default()
        },
        LockFile::Legacy { .. } => return Ok(empty),
    };
    let state = crate::engine::desired::desired_state(env, scope, &manifest, &lock, false)?;
    let sites = current.as_deref().map(sites).unwrap_or_default();
    Ok(ScopeSettings {
        applies: true,
        skills: state
            .settings_templates
            .iter()
            .map(|(skill, source)| SkillSettings {
                skill: skill.clone(),
                template: template_of(source, &sites),
            })
            .collect(),
        base,
    })
}

fn template_of(source: &TemplateSource, sites: &[crate::settings_file::Site]) -> SkillTemplate {
    let text = match source {
        TemplateSource::Absent => return SkillTemplate::NoTemplate,
        TemplateSource::Unreadable(reason) => {
            return SkillTemplate::Unreadable {
                reason: reason.clone(),
            };
        }
        TemplateSource::Text(text) => text,
    };
    let template = read(text);
    if !template.findings.is_empty() {
        return SkillTemplate::Invalid {
            findings: template.findings,
        };
    }
    SkillTemplate::Rows {
        rows: template
            .entries
            .into_iter()
            .map(|entry| SettingsRow {
                current: current_of(sites, &entry.key),
                key: entry.key,
                explainer: entry.comment,
                default: entry.value,
            })
            .collect(),
    }
}

/// What a plan records for a skill it has not reached yet: every declared
/// skill starts out of reach, and the pass overwrites this the moment it
/// can say better. A skill still carrying it is one whose source never
/// resolved, whose item the source no longer has, or that a hostile
/// catalog read refused.
pub(crate) fn out_of_reach(
    scope: &Scope,
    name: &str,
    templates: &mut BTreeMap<String, TemplateSource>,
) {
    if matches!(scope, Scope::Project { .. }) {
        templates.insert(
            name.to_owned(),
            TemplateSource::Unreadable(
                "nothing here could read this skill's source, so what it declares is unknown"
                    .to_owned(),
            ),
        );
    }
}

/// Why this skill seeds nothing even though its source read fine.
pub(crate) fn seeds_nothing(
    scope: &Scope,
    name: &str,
    reason: &str,
    templates: &mut BTreeMap<String, TemplateSource>,
) {
    if matches!(scope, Scope::Project { .. }) {
        templates.insert(
            name.to_owned(),
            TemplateSource::Unreadable(reason.to_owned()),
        );
    }
}

#[cfg(test)]
mod tests;
