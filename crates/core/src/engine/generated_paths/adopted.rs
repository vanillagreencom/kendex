//! Adoption records bind workflow copies to bytes from declared packages.
//! The package's adoption command writes the declaration; refresh only
//! updates its hash. Recorded paths never become apply or restore targets.

use std::collections::{BTreeMap, BTreeSet};
use std::path::{Component, Path, PathBuf};

use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};

use crate::error::{CoreError, Result};

use super::super::desired::{Artifact, DesiredState};
use super::{GeneratedPaths, INVENTORY};

#[derive(Debug, Clone, PartialEq, Eq, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct Record {
    path: String,
    template: String,
    template_hash: String,
}

#[derive(Deserialize, Serialize)]
#[serde(untagged)]
enum Entry {
    Path(String),
    Adopted(Record),
}

impl Entry {
    fn path(&self) -> &str {
        match self {
            Self::Path(path) => path,
            Self::Adopted(record) => &record.path,
        }
    }
}

/// A workflow's expected provenance and its equality findings.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct AdoptedWorkflow {
    record: Record,
    pub(crate) problems: Vec<String>,
}

pub(crate) fn inventory_paths(bytes: &[u8]) -> serde_json::Result<BTreeSet<String>> {
    let entries = parse(bytes)?;
    Ok(entries
        .into_iter()
        .map(|entry| entry.path().to_owned())
        .collect())
}

pub(crate) fn committable_paths(bytes: &[u8]) -> serde_json::Result<BTreeSet<String>> {
    Ok(parse(bytes)?
        .into_iter()
        .filter_map(|entry| match entry {
            Entry::Path(path) => Some(path),
            Entry::Adopted(_) => None,
        })
        .collect())
}

fn parse(bytes: &[u8]) -> serde_json::Result<Vec<Entry>> {
    use serde::de::Error as _;
    let entries: Vec<Entry> = serde_json::from_slice(bytes)?;
    for entry in &entries {
        if let Entry::Adopted(record) = entry {
            let valid_hash = record
                .template_hash
                .strip_prefix("sha256:")
                .is_some_and(|hash| {
                    hash.len() == 64
                        && hash
                            .bytes()
                            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte))
                });
            if !valid_hash
                || !relative(&record.path)
                || !relative(&record.template)
                || Path::new(&record.path).parent() != Some(Path::new(".github/workflows"))
                || !matches!(
                    Path::new(&record.path)
                        .extension()
                        .and_then(|value| value.to_str()),
                    Some("yml" | "yaml")
                )
            {
                return Err(serde_json::Error::custom(
                    "invalid adopted workflow path, template path, or SHA-256 hash",
                ));
            }
        }
    }
    Ok(entries)
}

pub(super) fn document(generated: &GeneratedPaths, root: &Path) -> Result<String> {
    let mut entries = BTreeMap::new();
    for path in generated.relative(root) {
        entries.insert(path.clone(), Entry::Path(path));
    }
    for workflow in generated.adopted.values() {
        entries.insert(
            workflow.record.path.clone(),
            Entry::Adopted(workflow.record.clone()),
        );
    }
    let lines = entries
        .values()
        .map(serde_json::to_string)
        .collect::<serde_json::Result<Vec<_>>>()
        .map_err(|error| invalid(root, error))?;
    Ok(format!("[\n  {}\n]\n", lines.join(",\n  ")))
}

fn invalid(root: &Path, error: impl std::fmt::Display) -> CoreError {
    CoreError::JsonParse {
        path: root.join(INVENTORY),
        message: error.to_string(),
    }
}

fn relative(path: &str) -> bool {
    !path.is_empty()
        && !path.contains('\\')
        && !path.contains(['\n', '\0'])
        && Path::new(path)
            .components()
            .all(|part| matches!(part, Component::Normal(_)))
}

fn hash(bytes: &[u8]) -> String {
    format!("sha256:{}", crate::hash::hex(&Sha256::digest(bytes)))
}

pub(super) fn collect(
    root: &Path,
    state: &DesiredState,
) -> Result<Option<BTreeMap<PathBuf, AdoptedWorkflow>>> {
    let Some(text) = crate::fs::read_if_exists(&root.join(INVENTORY))? else {
        return Ok(Some(BTreeMap::new()));
    };
    let Ok(entries) = parse(text.as_bytes()) else {
        // The attestation reports the parse failure. Keep the unreadable
        // declarations on disk instead of planning an empty replacement.
        return Ok(None);
    };
    let mut adopted = BTreeMap::new();
    for entry in entries {
        let Entry::Adopted(mut record) = entry else {
            continue;
        };
        let path = root.join(&record.path);
        let template = root.join(&record.template);
        let mut problems = Vec::new();
        let mut candidates = state
            .items
            .iter()
            .filter(|item| item.enabled)
            .filter_map(|item| {
                let Artifact::Tree {
                    canonical, files, ..
                } = &item.artifact
                else {
                    return None;
                };
                let relative = template.strip_prefix(canonical).ok()?;
                if relative.parent() != Some(Path::new("templates")) {
                    return None;
                }
                files
                    .iter()
                    .find(|(name, _)| name == relative)
                    .map(|(_, bytes)| bytes)
            });
        match candidates.next() {
            Some(bytes) => {
                if candidates.any(|other| other != bytes) {
                    problems.push(format!(
                        "template {} has conflicting declared package bytes",
                        record.template
                    ));
                }
                record.template_hash = hash(bytes);
                match std::fs::symlink_metadata(&path) {
                    Ok(metadata) if metadata.file_type().is_file() => {
                        let actual =
                            std::fs::read(&path).map_err(|error| CoreError::io(&path, error))?;
                        if actual != *bytes {
                            problems.push(format!("differs from template {}", record.template));
                        }
                    }
                    Ok(_) => problems.push("not a regular workflow file".to_owned()),
                    Err(error) if error.kind() == std::io::ErrorKind::NotFound => {
                        problems.push("adopted workflow is missing".to_owned());
                    }
                    Err(error) => return Err(CoreError::io(&path, error)),
                }
            }
            None => problems.push(format!(
                "template {} is not in a declared package",
                record.template
            )),
        }
        if adopted
            .insert(path, AdoptedWorkflow { record, problems })
            .is_some()
        {
            return Err(invalid(root, "duplicate adopted workflow path"));
        }
    }
    Ok(Some(adopted))
}
