//! How the saved settings of several projects differ.
//!
//! Seeding writes a key once and never revisits it
//! (`docs/authoring/settings.md`), so projects that installed the same
//! package drift apart with nothing reporting it. This reads what each
//! project's own files would hand the shipped loaders for every public
//! key its installed packages declare, and reports the keys whose answers
//! differ. It writes nothing, picks no winner and fails nothing.
//!
//! The layers are the loaders' own, highest first: the private env file,
//! `.kendex/settings.toml`, `kendex.settings.toml`, then the template
//! default. The process environment the loaders put above all of them is
//! left out: one command has one environment, shared by every project it
//! reads, so it cannot differ between them, and a value there would hide
//! the saved values this report is for.
//!
//! A key any project declares as a credential, or that two of its packages
//! contest, leaves the report before any layer is read for it, so no secret
//! value is ever held here to print. A project whose templates cannot all
//! be read is unread, never compared: nothing could say which of its keys
//! are secret. What its readable templates do declare secret still leaves
//! the report for every other project.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::model::Scope;
use crate::settings_file::{Current, current_of, loaders_refuse, sites};
use crate::settings_secret::env_file;
use crate::settings_template::TemplateSource;

/// What several projects' saved settings say, where they differ.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct SettingsComparison {
    /// Every project asked about, in the order given.
    pub projects: Vec<PathBuf>,
    /// The keys two or more projects declare and answer differently, by
    /// key. A key every declaring project answers the same is absent.
    pub differing: Vec<DifferingKey>,
    /// The projects nothing was compared for, and why.
    pub unread: Vec<UnreadProject>,
}

/// One key the projects answer differently.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DifferingKey {
    pub key: String,
    /// Each distinct answer and the projects holding it, decided values
    /// first in value order. An undecided answer is never grouped with
    /// another: nothing can say two of them agree.
    pub answers: Vec<KeyAnswer>,
}

/// One answer to a key and the projects that give it.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct KeyAnswer {
    pub answer: Answer,
    pub holders: Vec<Holder>,
}

/// What one project's saved settings say about a key.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Answer {
    /// The value the loaders would read.
    Value(String),
    /// Something assigns the key in a shape nothing here reads as one
    /// value, so the value is unknown. The lines are what to look at.
    Undecided { problem: String, lines: Vec<u32> },
}

/// One project giving an answer, and the layer it came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct Holder {
    pub project: PathBuf,
    pub layer: Layer,
}

/// Where a project's answer to a key came from.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Layer {
    /// The project's private env file, project-relative.
    PrivateFile { file: String },
    /// `.kendex/settings.toml`.
    NestedSettings,
    /// `kendex.settings.toml`.
    RootSettings,
    /// Nothing in the project assigns the key: the default the declaring
    /// packages' templates ship, by package name.
    TemplateDefault { skills: Vec<String> },
}

impl std::fmt::Display for Layer {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Layer::PrivateFile { file } => f.write_str(file),
            Layer::NestedSettings => f.write_str(crate::settings_secret::NESTED_SETTINGS_FILE),
            Layer::RootSettings => f.write_str(crate::settings_seed::SETTINGS_FILE),
            Layer::TemplateDefault { skills } => write!(f, "the default of {}", skills.join(", ")),
        }
    }
}

/// A project nothing was compared for.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct UnreadProject {
    pub project: PathBuf,
    pub reason: Unread,
}

/// Why a project could not be compared.
#[derive(Debug, Clone, PartialEq, Eq, thiserror::Error)]
pub enum Unread {
    #[error("the project folder could not be read: {problem}")]
    Folder { problem: String },
    #[error("the installed packages could not be read: {problem}")]
    Packages { problem: String },
    #[error("the settings of {skill} could not be read: {problem}")]
    Template { skill: String, problem: String },
    #[error("{file} could not be read: {problem}")]
    SettingsFile { file: String, problem: String },
    #[error("the private env file could not be read: {problem}")]
    PrivateFile { problem: String },
}

/// Compare the saved settings of these projects.
///
/// Every project is answered for: compared, or unread with its reason. An
/// unread project never counts as agreeing, and the rest are compared
/// without it.
pub fn compare_settings(env: &Env, projects: &[PathBuf]) -> SettingsComparison {
    let scanned: Vec<(&PathBuf, Declarations)> = projects
        .iter()
        .map(|project| (project, declarations(env, project)))
        .collect();
    // Settled across every project before any value is read, unread ones
    // included: a key one project holds as a credential is a credential in
    // each of them, as far as this report is concerned.
    let secret: BTreeSet<String> = scanned
        .iter()
        .flat_map(|(_, found)| found.secret.iter().cloned())
        .collect();
    let mut unread = Vec::new();
    let mut answered: BTreeMap<String, Vec<(Answer, Holder)>> = BTreeMap::new();
    for (project, found) in scanned {
        let public = match found.public {
            Ok(public) => public,
            Err(reason) => {
                unread.push(UnreadProject {
                    project: project.clone(),
                    reason,
                });
                continue;
            }
        };
        let public: BTreeMap<&String, &Vec<(String, String)>> = public
            .iter()
            .filter(|(key, _)| !secret.contains(*key))
            .collect();
        match answers(&found.root, &public) {
            Ok(per_key) => {
                for (key, (answer, layer)) in per_key {
                    answered.entry(key).or_default().push((
                        answer,
                        Holder {
                            project: project.clone(),
                            layer,
                        },
                    ));
                }
            }
            Err(reason) => unread.push(UnreadProject {
                project: project.clone(),
                reason,
            }),
        }
    }
    unread.sort_by_key(|one| projects.iter().position(|p| *p == one.project));
    SettingsComparison {
        projects: projects.to_vec(),
        differing: answered
            .into_iter()
            .filter_map(|(key, held)| differing(key, held))
            .collect(),
        unread,
    }
}

/// What one project's installed packages declare.
struct Declarations {
    root: PathBuf,
    /// Each public key and every `(package, default)` declaring it, or why
    /// the project cannot be compared.
    public: Result<BTreeMap<String, Vec<(String, String)>>, Unread>,
    /// The keys kendex or any readable template here declares as a
    /// credential, or contests. Collected whether or not the project can
    /// be compared.
    secret: BTreeSet<String>,
}

fn declarations(env: &Env, project: &Path) -> Declarations {
    let unread = |reason| Declarations {
        root: project.to_path_buf(),
        public: Err(reason),
        secret: BTreeSet::new(),
    };
    let root = match crate::paths::canonical(project) {
        Ok(root) => root,
        Err(error) => {
            return unread(Unread::Folder {
                problem: error.to_string(),
            });
        }
    };
    let templates =
        match crate::engine::settings_templates(env, &Scope::Project { root: root.clone() }) {
            Ok(templates) => templates,
            Err(error) => {
                return unread(Unread::Packages {
                    problem: error.to_string(),
                });
            }
        };
    let mut first_unread = None;
    let mut public: BTreeMap<String, Vec<(String, String)>> = BTreeMap::new();
    // `declared` and `contested` pass over a template that breaks the
    // grammar. Its decoded `[secrets]` rows still say what its author
    // holds as a credential, and this report prints values, so they leave
    // it too.
    let mut broken_secrets = BTreeSet::new();
    for (skill, source) in &templates {
        let text = match source {
            TemplateSource::Absent => continue,
            TemplateSource::Unreadable(reason) => {
                first_unread.get_or_insert_with(|| Unread::Template {
                    skill: skill.clone(),
                    problem: reason.clone(),
                });
                continue;
            }
            TemplateSource::Text(text) => text,
        };
        let read = crate::settings_template::read(text);
        if !read.findings.is_empty() {
            first_unread.get_or_insert_with(|| Unread::Template {
                skill: skill.clone(),
                problem: format!(
                    "its template breaks the settings grammar in {} place(s)",
                    read.findings.len()
                ),
            });
            broken_secrets.extend(read.secrets.into_iter().map(|entry| entry.key));
            continue;
        }
        for entry in read.entries {
            public
                .entry(entry.key)
                .or_default()
                .push((skill.clone(), entry.value));
        }
    }
    let secret = crate::settings_secret::declared(&templates)
        .into_iter()
        .map(|one| one.entry.key)
        .chain(
            crate::settings_secret::contested(&templates)
                .into_iter()
                .map(|one| one.key),
        )
        .chain(broken_secrets)
        .collect();
    Declarations {
        root,
        public: first_unread.map_or(Ok(public), Err),
        secret,
    }
}

/// Each public key's answer in one project, with the layer that gave it.
fn answers(
    root: &Path,
    public: &BTreeMap<&String, &Vec<(String, String)>>,
) -> Result<BTreeMap<String, (Answer, Layer)>, Unread> {
    let refused = |file: &str, problem: String| Unread::SettingsFile {
        file: file.to_owned(),
        problem,
    };
    let root_file = crate::settings_seed::SETTINGS_FILE;
    let nested_file = crate::settings_secret::NESTED_SETTINGS_FILE;
    let root_text = crate::fs::read_if_exists(&crate::settings_seed::settings_file_path(root))
        .map_err(|error| refused(root_file, error.to_string()))?;
    let layers = crate::settings_secret::settings_layers(root, root_text.as_deref())
        .map_err(|error| refused(nested_file, error.to_string()))?;
    // A file the loaders refuse stops them before they read any key, so
    // no key in this project has an answer to compare.
    for (file, text) in [root_file, nested_file].into_iter().zip(&layers) {
        if let Some(problem) = text.as_deref().and_then(loaders_refuse) {
            return Err(refused(file, problem));
        }
    }
    let file = crate::settings_secret::private_file(root, &layers)
        .map_err(|problem| Unread::PrivateFile { problem })?;
    let private = private_text(root, &file)?;
    let assignments = private
        .as_deref()
        .map(env_file::assignments)
        .unwrap_or_default();
    let layer_sites = |at: usize| {
        layers
            .get(at)
            .and_then(Option::as_deref)
            .map(sites)
            .unwrap_or_default()
    };
    let (tracked, nested) = (layer_sites(0), layer_sites(1));
    let mut out = BTreeMap::new();
    for (key, declared) in public {
        let private_layer = || Layer::PrivateFile { file: file.clone() };
        let answer = match env_file::standing(&assignments, key) {
            env_file::Standing::At(at) => Some((
                // The key is public by every installed declaration, so its
                // value is one the packages commit to configuration.
                match private
                    .as_deref()
                    .and_then(|text| env_file::value_of(text, &at))
                {
                    Some(value) => Answer::Value(value.to_owned()),
                    None => Answer::Undecided {
                        problem: "kendex could not read back the value on this line".to_owned(),
                        lines: vec![at.line],
                    },
                },
                private_layer(),
            )),
            // Sourcing `KEY=''` leaves the key holding nothing, and that
            // is what every loader reads: the layers below never answer.
            env_file::Standing::Empty(_) => Some((Answer::Value(String::new()), private_layer())),
            env_file::Standing::Blocked { problem, lines } => {
                Some((Answer::Undecided { problem, lines }, private_layer()))
            }
            env_file::Standing::Absent => None,
        }
        .or_else(|| settings_answer(&nested, key, Layer::NestedSettings))
        .or_else(|| settings_answer(&tracked, key, Layer::RootSettings))
        .unwrap_or_else(|| template_default(declared));
        out.insert((*key).clone(), answer);
    }
    Ok(out)
}

/// The private file's text, or `None` where there is none.
///
/// A link at the file is read through, as the loaders source it. One that
/// resolves to nothing fails their load rather than being skipped, so it
/// is no answer of "absent" here either.
fn private_text(root: &Path, file: &str) -> Result<Option<String>, Unread> {
    let path = root.join(file);
    let unreadable = |problem: String| Unread::PrivateFile {
        problem: format!("{file}: {problem}"),
    };
    match crate::fs::read_if_exists(&path) {
        Ok(None) if std::fs::symlink_metadata(&path).is_ok() => Err(unreadable(
            "it is a link that resolves to nothing".to_owned(),
        )),
        Ok(text) => Ok(text),
        Err(error) => Err(unreadable(error.to_string())),
    }
}

/// One settings file's answer to a key, or `None` where it assigns none
/// and the layer below decides.
fn settings_answer(
    sites: &[crate::settings_file::Site],
    key: &str,
    layer: Layer,
) -> Option<(Answer, Layer)> {
    match current_of(sites, key) {
        Current::Absent => None,
        Current::Value { value, .. } => Some((Answer::Value(value), layer)),
        Current::Ambiguous { problem, lines } => {
            Some((Answer::Undecided { problem, lines }, layer))
        }
    }
}

/// The default the declaring packages ship. Packages that ship different
/// defaults leave nothing to say which one a script falls back to.
fn template_default(declared: &[(String, String)]) -> (Answer, Layer) {
    let skills = declared.iter().map(|(skill, _)| skill.clone()).collect();
    let defaults: BTreeSet<&String> = declared.iter().map(|(_, value)| value).collect();
    let answer = match defaults.into_iter().collect::<Vec<_>>().as_slice() {
        [one] => Answer::Value((*one).clone()),
        _ => Answer::Undecided {
            problem: "the packages declaring it ship different defaults".to_owned(),
            lines: Vec::new(),
        },
    };
    (answer, Layer::TemplateDefault { skills })
}

/// The key as a difference, or `None` where fewer than two projects
/// declare it or every one of them reads the same value.
fn differing(key: String, held: Vec<(Answer, Holder)>) -> Option<DifferingKey> {
    if held.len() < 2 {
        return None;
    }
    let mut values: BTreeMap<String, Vec<Holder>> = BTreeMap::new();
    let mut undecided = Vec::new();
    for (answer, holder) in held {
        match answer {
            Answer::Value(value) => values.entry(value).or_default().push(holder),
            Answer::Undecided { problem, lines } => undecided.push(KeyAnswer {
                answer: Answer::Undecided { problem, lines },
                holders: vec![holder],
            }),
        }
    }
    if undecided.is_empty() && values.len() == 1 {
        return None;
    }
    let mut answers: Vec<KeyAnswer> = values
        .into_iter()
        .map(|(value, holders)| KeyAnswer {
            answer: Answer::Value(value),
            holders,
        })
        .collect();
    answers.extend(undecided);
    Some(DifferingKey { key, answers })
}
