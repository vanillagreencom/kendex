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
use crate::settings_secret::{ContestedKey, SecretRow, SecretsRead, SecretsView};
use crate::settings_template::{TemplateFinding, TemplateSource, read};

/// One skill's settings, in whichever of the four states it is in.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum SkillTemplate {
    /// This skill declares no settings.
    NoTemplate,
    /// Its template is out of reach here — a source that has not arrived,
    /// a skill switched off, a source that does not carry it.
    Unreadable { reason: String },
    /// The template does not hold to the authoring contract. Seeding is
    /// lenient and may have seeded keys from it regardless, so this says
    /// nothing about what the settings file contains.
    Invalid { findings: Vec<TemplateFinding> },
    /// The template reads. Either list may be empty and both are shown:
    /// a package declaring only credentials has settings to configure
    /// here, and a section that appeared only for public keys would hide
    /// it.
    Rows {
        rows: Vec<SettingsRow>,
        secrets: Vec<SecretRow>,
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
    /// What the settings file is called — the file every public value on
    /// this page is written to, named once here so a page saying where a
    /// value goes does not hold a second copy of the name.
    pub file: String,
    /// The settings file as it was when these rows were read. An edit
    /// written from them carries it back, and a file that moved in
    /// between is refused rather than overwritten.
    pub base: Base,
    /// Where this place keeps credentials, and what the private file was
    /// when the secret rows were read. `None` outside a project: a
    /// private file is a project's, and a global install has none — which
    /// is a different answer from a project whose file could not be
    /// written, and never reads as one.
    pub secrets: Option<SecretsView>,
    /// Keys the installed packages disagree about, one declaring a
    /// setting where another declares a credential. Neither route offers
    /// them and both refuse them, so they are reported here rather than
    /// shown as a field with no safe destination.
    pub contested: Vec<ContestedKey>,
}

/// Read one place's settings: what every installed skill declares, what
/// the file currently says about each key, and where each declared
/// credential stands in this project's private file.
/// The project's own private file is the destination; `want` reads the
/// same place against another file instead, which is how a person sees
/// what choosing one would mean before they save it.
pub fn scope_settings(env: &Env, scope: &Scope, want: Option<&str>) -> Result<ScopeSettings> {
    let scope = &scope.canonical();
    let Scope::Project { root } = scope else {
        return Ok(ScopeSettings {
            applies: false,
            skills: Vec::new(),
            file: crate::settings_seed::SETTINGS_FILE.to_owned(),
            base: Base::absent(),
            secrets: None,
            contested: Vec::new(),
        });
    };
    let current = crate::fs::read_if_exists(&crate::settings_seed::settings_file_path(root))?;
    let sites = current.as_deref().map(sites).unwrap_or_default();
    let templates = crate::engine::settings_templates(env, scope)?;
    let contested = crate::settings_secret::contested(&templates);
    let private = crate::settings_secret::read(root, current.as_deref(), want)?;
    Ok(ScopeSettings {
        applies: true,
        skills: templates
            .into_iter()
            .map(|(skill, source)| SkillSettings {
                template: template_of(&source, &sites, &private, &contested),
                skill,
            })
            .collect(),
        file: crate::settings_seed::SETTINGS_FILE.to_owned(),
        base: current.as_deref().map_or_else(Base::absent, Base::of),
        secrets: Some(private.view),
        contested,
    })
}

fn template_of(
    source: &TemplateSource,
    sites: &[Site],
    private: &SecretsRead,
    contested: &[ContestedKey],
) -> SkillTemplate {
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
    // A contested key is offered by neither route. Dropped from both
    // lists rather than shown disabled under each: a field a person
    // cannot use is worth one line of explanation, which
    // `ScopeSettings::contested` carries, and two dead controls is worse
    // than none.
    let taken = |key: &str| contested.iter().any(|one| one.key == key);
    SkillTemplate::Rows {
        rows: template
            .entries
            .into_iter()
            .filter(|entry| !taken(&entry.key))
            .map(|entry| SettingsRow {
                current: current_of(sites, &entry.key),
                key: entry.key,
                explainer: entry.comment,
                default: entry.value,
            })
            .collect(),
        secrets: private.rows(
            &template
                .secrets
                .into_iter()
                .filter(|entry| !taken(&entry.key))
                .collect::<Vec<_>>(),
        ),
    }
}

#[cfg(test)]
mod tests;
