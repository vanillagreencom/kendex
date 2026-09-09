//! The credentials a package needs, and the one private file this project
//! keeps them in.
//!
//! The public half of this system is deliberately unable to hold one. A
//! package declares its settings in `[env]`, seeding copies those entries
//! into the consumer's tracked `kendex.settings.toml`, and every value
//! that reaches that file is one an author decided was safe to commit
//! ([`crate::settings_seed`]). Nothing in that path can be made to carry
//! a credential without also making the tracked file a place credentials
//! live.
//!
//! So a credential travels a different way end to end. It is declared
//! under `[secrets]`, where a declaration is a key name, an explanation
//! and whether the package refuses to run without it, and where the
//! grammar admits no value at all ([`crate::settings_template`]). It is
//! read as presence and never as content: a row here says a key is set,
//! never what it is set to, so nothing downstream — a view, a plan
//! description, a diff, an error, a commit offer, an exported template —
//! has a value to leak. And it is written to the project's own private
//! env file, which git does not carry and which the shipped package
//! loaders already read.
//!
//! Two rules hold the whole thing together and both are checked on every
//! read rather than recorded once:
//!
//! - The destination stays inside this project and out of git's reach
//!   ([`mod@destination`]). Configuration is not evidence: a path that was
//!   safe when it was chosen is checked again before every write.
//! - One key is public or secret and never both. Where two installed
//!   packages disagree, the key is offered by neither route and refused by
//!   both ([`contested`]), because a reader that chose between them could
//!   send a credential into committed configuration.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::base::Base;
use crate::error::Result;
use crate::settings_template::{SecretEntry, TemplateSource};

mod destination;
pub mod env_file;
pub use destination::{
    DEFAULT_ENV_FILE, Destination, DestinationState, IGNORE_FILE, NESTED_SETTINGS_FILE,
    destination, destination_layered,
};

/// The settings key naming this project's private env file. Read by
/// kendex and by every shipped package loader, so one project names one
/// file once.
pub const ENV_FILE_KEY: &str = "KENDEX_ENV_FILE";

/// The name [`ENV_FILE_KEY`] is declared under. Every other key in a
/// consumer's settings file belongs to a package; this one is kendex's,
/// and the name is what a refusal and a conflict note call it.
pub const KENDEX_OWNER: &str = "kendex";

/// The comment block kendex writes above [`ENV_FILE_KEY`]. It is what a
/// consumer reads beside the key in their own settings file, so it says
/// what the key does rather than why it is there.
const ENV_FILE_EXPLAINER: [&str; 3] = [
    "# The file this project keeps its secrets in, beside this one. It is",
    "# read by kendex and by the packages that need a credential, and git",
    "# must not track it. Empty or absent means .env.local.",
];

/// kendex's own declaration of [`ENV_FILE_KEY`], so the pass that seeds
/// and sets a package's settings records this project's private file the
/// same way, in the same write.
///
/// The assignment ships empty and the value arrives as an edit: what the
/// seed puts in the file is a place for the answer, and the answer is the
/// path the person chose.
pub fn env_file_declaration() -> crate::settings_seed::SeededEnv {
    crate::settings_seed::SeededEnv {
        entry: crate::settings_seed::EnvEntry {
            key: ENV_FILE_KEY.to_owned(),
            comment: ENV_FILE_EXPLAINER.map(str::to_owned).to_vec(),
            assignment: format!("{ENV_FILE_KEY} = \"\""),
            required: false,
        },
        owner: KENDEX_OWNER.to_owned(),
    }
}

/// One credential a package declares, bound to the package that declares
/// it — the package a refusal names, and the one an edit is checked
/// against.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DeclaredSecret {
    pub entry: SecretEntry,
    pub owner: String,
}

/// Where one key stands in this project's private file. Presence and
/// nothing else: a stored value says a person supplied one, never that a
/// provider accepted it, so nothing here is evidence of a working
/// credential.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(tag = "state", rename_all = "kebab-case")]
pub enum SecretState {
    /// The private file assigns no such key.
    NotSet,
    /// The private file assigns it.
    Set,
    /// Nothing here could say, and why. Never read as "not set": a person
    /// told a key is missing sets it again, over whatever is there.
    Unknown { reason: String },
}

/// One credential field, as the app shows it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SecretRow {
    pub key: String,
    /// The template's comment block, `#` markers stripped — what the
    /// author wrote to say what the key lets the package do.
    pub explainer: Vec<String>,
    /// Whether the package refuses to run without it.
    pub required: bool,
    pub current: SecretState,
}

/// A key two installed packages disagree about: one declares it public,
/// the other a credential.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ContestedKey {
    pub key: String,
    /// Packages declaring it under `[env]`, in name order.
    pub public: Vec<String>,
    /// Packages declaring it under `[secrets]`, in name order.
    pub secret: Vec<String>,
    /// The one sentence every surface says about this key. Composed here
    /// and carried, rather than left to each reader: the note on the page,
    /// the plan's note and the refusal all say the same thing about the
    /// same disagreement, and a second composition of it in another
    /// language is one that comes to say something else.
    pub problem: String,
}

impl ContestedKey {
    fn of(key: String, public: Vec<String>, secret: Vec<String>) -> Self {
        let problem = format!(
            "{} declares {key} as a setting and {} declares it as a secret, so nothing can say where its value may be written",
            public.join(", "),
            secret.join(", ")
        );
        ContestedKey {
            key,
            public,
            secret,
            problem,
        }
    }
}

/// Everything one project's secret fields need beside the rows: where a
/// value would go, what else it could go to, and what the private file
/// was when the rows were read.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SecretsView {
    pub destination: Destination,
    /// Other files in the project's root that already look like a private
    /// env file, project-relative and in name order. What a person picks
    /// from when the default is not the file this project uses.
    pub candidates: Vec<String>,
    /// The private file as it was when these rows were read. An edit
    /// written from them carries it back, and a file that moved in
    /// between is refused rather than overwritten.
    pub base: Base,
}

/// One project's private storage, read. The file's text stays inside:
/// every answer this hands out is about presence, so there is no value
/// here for a caller to put on a screen or in a log.
pub struct SecretsRead {
    pub view: SecretsView,
    /// The file's assignments, where the file could be read.
    assignments: Vec<env_file::Assignment>,
    /// Why no key can be answered for, where that is so.
    unreadable: Option<String>,
}

impl SecretsRead {
    /// Where one key stands.
    pub fn state_of(&self, key: &str) -> SecretState {
        if let Some(reason) = &self.unreadable {
            return SecretState::Unknown {
                reason: reason.clone(),
            };
        }
        match env_file::standing(&self.assignments, key) {
            env_file::Standing::Absent => SecretState::NotSet,
            env_file::Standing::At(_) => SecretState::Set,
            env_file::Standing::Blocked { problem, lines } => SecretState::Unknown {
                reason: format!(
                    "{problem}: {} of {}",
                    crate::settings_file::lines_phrase(&lines),
                    self.view.destination.file
                ),
            },
        }
    }

    /// The rows one package's declarations become.
    pub fn rows(&self, secrets: &[SecretEntry]) -> Vec<SecretRow> {
        secrets
            .iter()
            .map(|entry| SecretRow {
                current: self.state_of(&entry.key),
                key: entry.key.clone(),
                explainer: entry.comment.clone(),
                required: entry.required,
            })
            .collect()
    }
}

/// Read one project's private storage: where it is, whether it may be
/// written, and which of the declared keys it already holds.
///
/// A destination that refuses, and a file that will not read, are both
/// answers rather than failures — every key comes back `Unknown` with the
/// reason, so no field reads as unset because a check could not run.
pub fn read(root: &Path, settings: Option<&str>, want: Option<&str>) -> Result<SecretsRead> {
    let destination = destination_layered(root, &settings_layers(root, settings)?, want);
    let path = destination.path(root);
    let (text, unreadable) = match &destination.state {
        DestinationState::Refused { problem, .. } => (None, Some(problem.clone())),
        _ => match crate::fs::read_if_exists(&path) {
            Ok(text) => (text, None),
            // A file kendex cannot decode is one whose keys it cannot
            // count. Saying so is the whole answer; guessing "not set"
            // would offer to write a key that may already be there.
            Err(error) => (
                None,
                Some(format!("{} could not be read ({error})", destination.file)),
            ),
        },
    };
    Ok(of(
        destination.clone(),
        candidates(root, &destination.file),
        text.as_deref(),
        unreadable,
    ))
}

/// One project's private storage, assembled from what was read. Held
/// apart from [`read`] so a test can drive the view over a file's text
/// without a project on disk.
fn of(
    destination: Destination,
    candidates: Vec<String>,
    text: Option<&str>,
    unreadable: Option<String>,
) -> SecretsRead {
    SecretsRead {
        assignments: text.map(env_file::assignments).unwrap_or_default(),
        view: SecretsView {
            candidates,
            base: text.map_or_else(Base::absent, Base::of),
            destination,
        },
        unreadable,
    }
}

/// A read of the default destination over the given text, for tests that
/// exercise a reader of these rows rather than the project checks.
#[cfg(test)]
pub(crate) fn read_of(text: Option<&str>) -> SecretsRead {
    of(
        Destination {
            file: DEFAULT_ENV_FILE.to_owned(),
            chosen: false,
            state: DestinationState::Ready,
        },
        Vec::new(),
        text,
        None,
    )
}

/// Every settings layer that can name this project's private file, in the
/// order the shell loaders read them: `kendex.settings.toml` first, then
/// `.kendex/settings.toml`, whose assignment wins.
///
/// The caller has usually read the root file already, for the settings
/// rows, so it is passed in rather than read twice.
pub fn settings_layers(root: &Path, root_text: Option<&str>) -> Result<Vec<Option<String>>> {
    Ok(vec![
        root_text.map(str::to_owned),
        crate::fs::read_if_exists(&root.join(NESTED_SETTINGS_FILE))?,
    ])
}

/// The files in a project's root that already look like a private env
/// file, other than the one in use. Names alone: nothing is read, and
/// picking one runs every protection check again.
fn candidates(root: &Path, chosen: &str) -> Vec<String> {
    let Ok(entries) = std::fs::read_dir(root) else {
        return Vec::new();
    };
    let mut found: BTreeSet<String> = BTreeSet::new();
    for entry in entries.flatten() {
        let Ok(name) = entry.file_name().into_string() else {
            continue;
        };
        if name == chosen || !(name == ".env" || name.starts_with(".env.")) {
            continue;
        }
        if entry.path().is_file() && !entry.path().is_symlink() {
            found.insert(name);
        }
    }
    found.into_iter().collect()
}

/// Every credential the installed packages declare, by package. Read
/// through the strict template reader, so a template with any defect
/// declares nothing here and is reported as invalid by
/// [`crate::settings_view`] rather than half-read.
pub fn declared(templates: &BTreeMap<String, TemplateSource>) -> Vec<DeclaredSecret> {
    let mut out = Vec::new();
    for (owner, source) in templates {
        let TemplateSource::Text(text) = source else {
            continue;
        };
        let read = crate::settings_template::read(text);
        if !read.findings.is_empty() {
            continue;
        }
        for entry in read.secrets {
            out.push(DeclaredSecret {
                entry,
                owner: owner.clone(),
            });
        }
    }
    out
}

/// The keys the installed packages disagree about, by key.
///
/// One key is public or secret and never both. Two packages may share a
/// key — the settings conflict note exists because they do — but they may
/// not disagree about where its value is allowed to be written. Neither
/// route offers a contested key and both refuse it, because the reader
/// that chose between the two declarations could send a credential into
/// committed configuration.
pub fn contested(templates: &BTreeMap<String, TemplateSource>) -> Vec<ContestedKey> {
    let mut public: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    let mut secret: BTreeMap<String, BTreeSet<String>> = BTreeMap::new();
    for (owner, source) in templates {
        let TemplateSource::Text(text) = source else {
            continue;
        };
        let read = crate::settings_template::read(text);
        if !read.findings.is_empty() {
            continue;
        }
        for entry in read.entries {
            public.entry(entry.key).or_default().insert(owner.clone());
        }
        for entry in read.secrets {
            secret.entry(entry.key).or_default().insert(owner.clone());
        }
    }
    public
        .into_iter()
        .filter_map(|(key, owners)| {
            let against = secret.get(&key)?;
            Some(ContestedKey::of(
                key.clone(),
                owners.into_iter().collect(),
                against.iter().cloned().collect(),
            ))
        })
        .collect()
}

/// One value a person set, bound to the package whose template declares
/// the key — the declaration is what core checks the edit against, so an
/// edit naming a package that does not declare the key is refused rather
/// than written under somebody else's name.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SecretEdit {
    pub skill: String,
    pub key: String,
    pub value: SecretEditValue,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum SecretEditValue {
    /// Write this value, over whatever the key holds.
    Set { value: String },
    /// Take the key out of the private file.
    Clear,
}

impl SecretEdit {
    /// Whether this edit puts a value in the file, which is the half a
    /// destination has to be writable for.
    pub fn stores(&self) -> bool {
        matches!(self.value, SecretEditValue::Set { .. })
    }
}

/// A save's secret half: the edits, the destination the rows on screen
/// named, and what that file was when they were read.
#[derive(Debug, Clone)]
pub struct SecretsDraft {
    pub edits: Vec<SecretEdit>,
    /// Project-relative, as [`Destination::file`] gave it. A project that
    /// has since been pointed at another file is refused rather than
    /// written: the person confirmed one destination and would get
    /// another.
    pub file: String,
    /// Whether this save also records `file` as the project's private
    /// file. False binds the save to the destination the project already
    /// uses; true is the person naming a different one, which the same
    /// save writes into `kendex.settings.toml` so the packages read it
    /// too.
    pub choose: bool,
    pub base: Base,
}

/// Why a secret edit did not happen. Every one is an answer for the
/// person to act on, so each carries the key, the file or the lines to
/// look at — and none of them carries a value.
#[derive(Debug, thiserror::Error)]
pub enum SecretRefusal {
    #[error("{key} is not a secret '{skill}' declares, so nothing here writes it")]
    Undeclared { skill: String, key: String },

    #[error("{key} cannot be stored — {problem}")]
    Value { key: String, problem: String },

    #[error(
        "{key} cannot be stored in {path} — {problem}: {}",
        crate::settings_file::lines_phrase(lines)
    )]
    Blocked {
        path: PathBuf,
        key: String,
        problem: String,
        lines: Vec<u32>,
    },

    #[error(
        "this project now keeps its secrets in {now}, not {then}; check the destination and save again"
    )]
    Moved { then: String, now: String },

    #[error("nothing can be stored in {file} — {problem}")]
    Unavailable { file: String, problem: String },

    #[error("{key} is set twice in one save, so nothing was written; save one of them")]
    Twice { key: String },

    #[error("{}", contested.problem)]
    Sensitivity { contested: Box<ContestedKey> },
}

/// What the private file becomes once this save's edits are in it, and
/// the keys that actually moved.
///
/// Every edit is checked before a byte moves: the key is one the package
/// it names declares, the value is one both loaders read back as written,
/// and the line it lands on is one kendex may write. A save that refuses
/// leaves the file exactly as it was.
pub fn apply_edits(
    text: &str,
    edits: &[SecretEdit],
    declared: &[DeclaredSecret],
    contested: &[ContestedKey],
    path: &Path,
) -> Result<(String, Vec<String>)> {
    let mut out = text.to_owned();
    let mut changed = Vec::new();
    let mut asked: BTreeSet<&str> = BTreeSet::new();
    for edit in edits {
        // Two rows for one key in one save would have the later silently
        // win, and the choice the person made in the other would be gone
        // with nothing said.
        if !asked.insert(edit.key.as_str()) {
            return Err(SecretRefusal::Twice {
                key: edit.key.clone(),
            }
            .into());
        }
        check(edit, declared, contested)?;
        // Read again for every edit: a replacement moves every byte after
        // it, and a span read before that would name the wrong bytes.
        let assignments = env_file::assignments(&out);
        if let env_file::Standing::Blocked { problem, lines } =
            env_file::standing(&assignments, &edit.key)
        {
            return Err(SecretRefusal::Blocked {
                path: path.to_path_buf(),
                key: edit.key.clone(),
                problem,
                lines,
            }
            .into());
        }
        let next = match &edit.value {
            SecretEditValue::Set { value } => env_file::with_value(&out, &edit.key, value),
            SecretEditValue::Clear => env_file::without_key(&out, &edit.key),
        };
        if next == out {
            continue;
        }
        out = next;
        changed.push(edit.key.clone());
    }
    Ok((out, changed))
}

/// Whether this edit may be written at all: the package declares the key,
/// no other package contests it, and the value is one every loader reads
/// back as written.
fn check(
    edit: &SecretEdit,
    declared: &[DeclaredSecret],
    contested: &[ContestedKey],
) -> std::result::Result<(), SecretRefusal> {
    if let Some(against) = contested.iter().find(|one| one.key == edit.key) {
        return Err(SecretRefusal::Sensitivity {
            contested: Box::new(against.clone()),
        });
    }
    if !declared
        .iter()
        .any(|one| one.owner == edit.skill && one.entry.key == edit.key)
    {
        return Err(SecretRefusal::Undeclared {
            skill: edit.skill.clone(),
            key: edit.key.clone(),
        });
    }
    let SecretEditValue::Set { value } = &edit.value else {
        return Ok(());
    };
    env_file::check_value(value).map_err(|problem| SecretRefusal::Value {
        key: edit.key.clone(),
        problem,
    })
}

#[cfg(test)]
mod tests;
