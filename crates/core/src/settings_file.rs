//! The consumer's `kendex.settings.toml`: where a key stands in it, and
//! how one value is replaced without disturbing a byte around it.
//!
//! Seeding ([`crate::settings_seed`]) writes whole entries into this file
//! and never touches a value line. This is the other half: reading what a
//! value currently is, and writing a new one over exactly the quoted span
//! it occupies — so the comment beside it, the file's line terminators,
//! and every unrelated line come through untouched.
//!
//! Which assignments count is seeding's judgment, not a second opinion:
//! the presence check is file-wide, so an assignment outside `[env]` is a
//! site here as it is there. What the loaders read is narrower, and the
//! gap is the point — a key assigned twice, assigned outside `[env]`, or
//! written with a value they refuse has no value to show and no span to
//! write over. [`current_of`] names that gap, so seeding's notes ask it
//! too ([`crate::settings_seed::Answered`]) rather than guessing.

use std::collections::BTreeMap;
use std::ops::Range;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::base::Base;
use crate::error::Result;
use crate::settings_seed::{EnvBlocked, SeededEnv, loaders_read_env};
use crate::settings_template::decoded_value;
use crate::settings_toml::{Line, decoded, key_of, quoted_span};

/// What the private halves of an edit hand back: a refusal in its own
/// shape, which `?` widens into a [`crate::error::CoreError`] at the one
/// public entry.
type Refused<T> = std::result::Result<T, SettingsRefusal>;

/// Why a settings edit did not happen. Every one of these is an answer
/// for the person to act on rather than a failure of the machinery, so
/// each carries the key, the file, or the lines to look at — never only a
/// sentence a caller would have to read to know what happened.
#[derive(Debug, thiserror::Error)]
pub enum SettingsRefusal {
    #[error("{key} is not a setting '{skill}' declares, so nothing here writes it")]
    Undeclared { skill: String, key: String },

    #[error("{key} cannot be set here — {problem}")]
    Value { key: String, problem: String },

    #[error(
        "{key} cannot be set here — {problem}: {path}, {}",
        lines_phrase(lines)
    )]
    Ambiguous {
        path: PathBuf,
        key: String,
        lines: Vec<u32>,
        problem: String,
    },

    #[error("{path} is not a regular file, and settings are never written through one")]
    NotRegularFile { path: PathBuf },

    #[error(
        "{key} is set twice in one save — {} — so nothing was written; save one of them",
        by.iter().zip(wanted).map(|(skill, value)| format!("{skill} wants \"{value}\""))
            .collect::<Vec<_>>().join(" and ")
    )]
    Contested {
        key: String,
        /// The skills whose rows carried an edit, in the order they came.
        by: Vec<String>,
        /// What each of them asked for, resolved — a reset is that
        /// skill's own default, and two skills may ship different ones.
        wanted: Vec<String>,
    },

    #[error(
        "{path} {}, so there is nowhere a setting can go — make it a plain [env] table",
        env.problem()
    )]
    EnvNotSeedable { path: PathBuf, env: EnvBlocked },
}

/// One assignment of one key in the file.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Site {
    /// The key seeding matches on: quotes trimmed, so `"WAIT" = "x"` and
    /// `WAIT = "x"` are one key's two spellings and neither is seeded over.
    pub key: String,
    /// How the key was spelled. Every spelling of a name blocks a seed of
    /// it; the loaders match the text as written, so only the bare one is
    /// a name they read.
    pub written: Written,
    /// 1-based line.
    pub line: u32,
    /// Whether the `[env]` header is the last one above this line.
    pub in_env: bool,
    /// The value with its quotes off, `None` where the loaders refuse the
    /// shape.
    pub value: Option<String>,
    /// Byte range of the value's inside — between the quotes — in the text
    /// this site was read from. Present exactly when `value` is.
    pub inner: Option<Range<usize>>,
}

/// How a key was spelled where it sits.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Written {
    Bare,
    Quoted,
    /// A dotted path, whatever its first segment's own spelling. It
    /// declares that name as a table rather than assigning it a value, so
    /// it occupies the name and holds no value to read.
    Dotted,
}

/// Where one key stands in the file, as a reader can act on it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum Current {
    /// Nothing in the file assigns it.
    Absent,
    /// One `[env]` assignment the loaders read. The only state a default
    /// can be compared against.
    Value { value: String, line: u32 },
    /// Something is there, and nothing here can say what the value is:
    /// assigned twice, assigned where nothing reads it, or written in a
    /// shape the loaders refuse. The lines are what a person has to look
    /// at to settle it.
    Ambiguous { problem: String, lines: Vec<u32> },
}

/// One value a person set, bound to the skill whose template declares the
/// key — the declaration is what core checks the edit against, so an edit
/// naming a skill that does not ship the key is refused rather than
/// written under somebody else's name.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SettingsEdit {
    pub skill: String,
    pub key: String,
    pub value: SettingsEditValue,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum SettingsEditValue {
    Set {
        value: String,
    },
    /// Write the template default of the skill this edit names.
    Reset,
}

/// A scope plan's settings half: the edits, and what the file was when
/// they were made. Both together, because edits without their base cannot
/// be written back safely.
#[derive(Debug, Clone)]
pub struct SettingsDraft {
    pub edits: Vec<SettingsEdit>,
    pub base: Base,
}

/// Every assignment in the file, in file order. Read through
/// [`crate::settings_toml`], so nothing inside a multiline value is
/// mistaken for one — the span an edit writes over comes from the same
/// walk that decided the line was an assignment at all.
pub fn sites(text: &str) -> Vec<Site> {
    let mut out = Vec::new();
    let mut in_env = false;
    for row in crate::settings_toml::rows(text) {
        if row.kind == Line::Table {
            // MEMBERSHIP: this view answers "would a script read this
            // key", so it tracks what the loaders read and not what TOML
            // says. A key under a header they refuse is not a setting.
            in_env = loaders_read_env(row.text);
            continue;
        }
        let Some((key, value, at)) = row.assignment() else {
            continue;
        };
        let Some(key) = key_of(key) else {
            continue;
        };
        out.push(Site {
            written: match (key.dotted(), key.quoted) {
                (true, _) => Written::Dotted,
                (false, true) => Written::Quoted,
                (false, false) => Written::Bare,
            },
            key: key.name,
            line: row.line,
            in_env,
            inner: quoted_span(value, at),
            value: decoded(value),
        });
    }
    out
}

/// Where one key stands, given the file's sites.
pub fn current_of(sites: &[Site], key: &str) -> Current {
    let mine: Vec<&Site> = sites.iter().filter(|site| site.key == key).collect();
    match mine.as_slice() {
        [] => Current::Absent,
        [one] => match readable(one, key) {
            Ok(value) => Current::Value {
                value,
                line: one.line,
            },
            Err(problem) => Current::Ambiguous {
                problem,
                lines: vec![one.line],
            },
        },
        many => Current::Ambiguous {
            problem: "it is assigned more than once, and nothing here can say which one wins"
                .to_owned(),
            lines: many.iter().map(|site| site.line).collect(),
        },
    }
}

/// The value the shell loaders read off this line, or why they read none.
fn readable(site: &Site, key: &str) -> std::result::Result<String, String> {
    if !site.in_env {
        return Err("it is assigned outside the [env] table, where no script reads it".to_owned());
    }
    match site.written {
        Written::Bare => {}
        Written::Quoted => {
            return Err(format!(
                "it is assigned as a quoted key, which is not a name a shell can export — spell it {key}"
            ));
        }
        Written::Dotted => {
            return Err(format!(
                "it is assigned as a dotted key, which makes {key} a table rather than a setting"
            ));
        }
    }
    site.value.clone().ok_or_else(|| {
        "its value is not a one-line double-quoted string free of \" and \\".to_owned()
    })
}

/// Whether this text can be written as a whole `[env]` value: one line
/// between double quotes, with nothing in it the quotes cannot hold. The
/// grammar is the shell loaders', spelled once here so an edit and the
/// template check refuse the same strings.
pub fn check_value(value: &str) -> std::result::Result<(), String> {
    if value.contains('\n') || value.contains('\r') {
        return Err("a value is one line, and this one has a line break in it".to_owned());
    }
    if value.contains('"') {
        return Err(
            "a value is written between double quotes, so it cannot contain one".to_owned(),
        );
    }
    if value.contains('\\') {
        return Err("there are no escapes here, so a value cannot contain a backslash".to_owned());
    }
    // A control character is not TOML between quotes, and is not something
    // a shell that exported it would survive either. A tab is the one the
    // grammar allows.
    if let Some(control) = value.chars().find(|c| c.is_control() && *c != '\t') {
        return Err(format!(
            "a value cannot hold a control character, and this one holds {}",
            control.escape_debug()
        ));
    }
    Ok(())
}

/// Write each edit over the value it names, byte-faithfully. Returns the
/// finished text and the keys whose value actually changed.
///
/// Sites are re-read for every edit rather than once for all of them: a
/// replacement moves every byte after it, and a span read before that
/// would name the wrong characters.
pub fn apply_edits(
    text: &str,
    edits: &[SettingsEdit],
    templates: &[SeededEnv],
    path: &Path,
) -> Result<(String, Vec<String>)> {
    let mut out = text.to_owned();
    let mut changed = Vec::new();
    for (key, value) in wanted(edits, templates)? {
        let inner = span_for(&out, &key, path)?;
        if out[inner.clone()] == value {
            continue;
        }
        out.replace_range(inner, &value);
        changed.push(key);
    }
    Ok((out, changed))
}

/// What this save asks of each key, once, in the order the edits came.
///
/// Two skills may declare one key — the shared-key note exists because
/// they do — so the view shows it under each of them and a save can carry
/// a row from both. Applied in turn the later would silently win and the
/// other choice would be gone with nothing said, which is worse than a
/// refusal. Two rows that agree are not a disagreement and pass as one;
/// two that differ stop the save before a byte moves.
fn wanted(edits: &[SettingsEdit], templates: &[SeededEnv]) -> Result<Vec<(String, String)>> {
    let mut asked: Vec<(String, String)> = Vec::new();
    let mut by: BTreeMap<&str, Vec<&SettingsEdit>> = BTreeMap::new();
    for edit in edits {
        let value = resolve(edit, templates)?;
        by.entry(&edit.key).or_default().push(edit);
        match asked.iter().find(|(key, _)| *key == edit.key) {
            None => asked.push((edit.key.clone(), value)),
            Some((_, first)) if *first == value => {}
            Some(_) => {
                let contesting = by.remove(edit.key.as_str()).unwrap_or_default();
                let mut wanted = Vec::new();
                for edit in &contesting {
                    wanted.push(resolve(edit, templates)?);
                }
                return Err(SettingsRefusal::Contested {
                    key: edit.key.clone(),
                    by: contesting.iter().map(|edit| edit.skill.clone()).collect(),
                    wanted,
                }
                .into());
            }
        }
    }
    Ok(asked)
}

/// The value this edit writes: the one it carries, or the template
/// default of the skill it names. Either way the key has to be one that
/// skill declares — an edit is written against a template, and a key no
/// installed template declares has no default to reset to and no
/// explainer to have been read beside it.
fn resolve(edit: &SettingsEdit, templates: &[SeededEnv]) -> Refused<String> {
    let declared = templates
        .iter()
        .find(|seeded| seeded.owner == edit.skill && seeded.entry.key == edit.key)
        .ok_or_else(|| SettingsRefusal::Undeclared {
            skill: edit.skill.clone(),
            key: edit.key.clone(),
        })?;
    let value = match &edit.value {
        SettingsEditValue::Set { value } => value.clone(),
        SettingsEditValue::Reset => {
            let line = declared.entry.opening();
            decoded_value(line).ok_or_else(|| SettingsRefusal::Value {
                key: edit.key.clone(),
                problem: format!(
                    "{}'s template does not spell its default as a plain one-line string, so there is nothing to reset it to",
                    edit.skill
                ),
            })?
        }
    };
    check_value(&value).map_err(|problem| SettingsRefusal::Value {
        key: edit.key.clone(),
        problem,
    })?;
    Ok(value)
}

/// The span one edit writes over: the key's single readable `[env]`
/// assignment. Everything else refuses, naming the lines a person has to
/// look at — writing over one of two assignments would leave the other
/// deciding what the scripts read.
fn span_for(text: &str, key: &str, path: &Path) -> Refused<Range<usize>> {
    let sites = sites(text);
    match current_of(&sites, key) {
        Current::Value { line, .. } => sites
            .iter()
            .find(|site| site.line == line)
            .and_then(|site| site.inner.clone())
            .ok_or_else(|| SettingsRefusal::Value {
                key: key.to_owned(),
                problem: "its value could not be located on the line it was read from".to_owned(),
            }),
        Current::Ambiguous { problem, lines } => Err(SettingsRefusal::Ambiguous {
            path: path.to_path_buf(),
            key: key.to_owned(),
            lines,
            problem,
        }),
        // Seeding runs first over the keys this save names — most of them
        // are keys no install ever wrote — so nothing readable is missing
        // by the time an edit reaches this.
        Current::Absent => Err(SettingsRefusal::Value {
            key: key.to_owned(),
            problem: "it is not assigned in this file and seeding did not insert it".to_owned(),
        }),
    }
}

/// Line numbers as a refusal says them.
pub fn lines_phrase(lines: &[u32]) -> String {
    let shown: Vec<String> = lines.iter().map(u32::to_string).collect();
    match shown.len() {
        1 => format!("line {}", shown[0]),
        _ => format!("lines {}", shown.join(", ")),
    }
}

#[cfg(test)]
mod tests;
