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
//!
//! Which skills are installed here, and which of them ship a template, is
//! the closure's answer and comes through the engine's one entry point
//! for it ([`crate::engine::settings_templates`]). Everything after that —
//! parsing a template strictly, and saying where the consumer's file
//! stands on each key — is this module's, and none of it is planning.

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::base::Base;
use crate::env::Env;
use crate::error::Result;
use crate::model::Scope;
use crate::settings_file::{Current, Site, current_of, sites};
use crate::settings_template::{TemplateFinding, TemplateSource, read};

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
    let sites = current.as_deref().map(sites).unwrap_or_default();
    Ok(ScopeSettings {
        applies: true,
        skills: crate::engine::settings_templates(env, scope)?
            .into_iter()
            .map(|(skill, source)| SkillSettings {
                template: template_of(&source, &sites),
                skill,
            })
            .collect(),
        base: current.as_deref().map_or_else(Base::absent, Base::of),
    })
}

fn template_of(source: &TemplateSource, sites: &[Site]) -> SkillTemplate {
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

#[cfg(test)]
mod tests;
