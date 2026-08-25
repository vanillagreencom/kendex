//! Reading and writing a manifest file: what sits at a path, how a
//! mutation upgrades the schema as a side effect of writing at all, and
//! the one place a new scope gets its default source.

use std::path::Path;

use crate::base::Base;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::fs::{atomic_write, read_if_exists};
use crate::model::{HarnessId, Scope};

use super::{
    DEFAULT_SOURCE_NAME, DEFAULT_SOURCE_REPO, Finding, MANIFEST_SCHEMA, Manifest, SourceDecl,
    validate,
};

/// What sits at a manifest path. A schema-less file is a v1 manifest: v2
/// never mutates it — hard "migration required" error until the importer.
#[derive(Debug, Clone, PartialEq)]
pub enum ManifestFile {
    Absent,
    Legacy { raw: String },
    Current(Box<Manifest>),
}

/// Where this scope's manifest lives right now: the new name, or the old
/// one when only it exists — an old-name scope keeps loading until its
/// rename op runs (the read-as-import posture, not a second format).
pub fn manifest_path(env: &Env, scope: &Scope) -> std::path::PathBuf {
    let (new, old) = crate::rename::manifest_pair(env, scope);
    crate::rename::existing_or_new(new, old)
}

/// Every name this scope's manifest can answer to: the current one, and
/// the old product name while a scope is still under it. A rename
/// generation retargets writes planned against the old name, so a refusal
/// out of an apply can name either — a caller matching refusals against
/// only the name it read from would misread the retargeted one.
pub fn manifest_paths(env: &Env, scope: &Scope) -> [std::path::PathBuf; 2] {
    let (new, old) = crate::rename::manifest_pair(env, scope);
    [new, old]
}

pub fn load(path: &Path) -> Result<ManifestFile> {
    crate::rename::refuse_both_generations(path)?;
    let Some(text) = read_if_exists(path)? else {
        return Ok(ManifestFile::Absent);
    };
    parse_text(path, &text)
}

/// [`load`] for text the caller already read — the importer classifies the
/// exact bytes its preconditions bind to.
pub fn parse_text(path: &Path, text: &str) -> Result<ManifestFile> {
    let table: toml::Table = text
        .parse()
        .map_err(|e: toml::de::Error| CoreError::TomlParse {
            path: path.to_path_buf(),
            message: e.to_string(),
        })?;
    if !table.contains_key("schema") {
        return Ok(ManifestFile::Legacy {
            raw: text.to_owned(),
        });
    }
    if let Some(schema) = table.get("schema").and_then(toml::Value::as_integer)
        && schema > i64::from(MANIFEST_SCHEMA)
    {
        return Err(CoreError::SchemaTooNew {
            path: path.to_path_buf(),
            found: schema,
        });
    }
    let findings = validate(&table);
    if !findings.is_empty() {
        return Err(CoreError::ManifestInvalid {
            path: path.to_path_buf(),
            findings: findings.iter().map(Finding::to_string).collect(),
        });
    }
    let manifest: Manifest =
        toml::from_str(text).map_err(|e: toml::de::Error| CoreError::TomlParse {
            path: path.to_path_buf(),
            message: e.to_string(),
        })?;
    Ok(ManifestFile::Current(Box::new(manifest)))
}

pub fn save(path: &Path, manifest: &Manifest) -> Result<()> {
    let text = toml::to_string_pretty(manifest).map_err(|e| CoreError::TomlParse {
        path: path.to_path_buf(),
        message: e.to_string(),
    })?;
    atomic_write(path, &text)
}

/// Load for mutation: a legacy file is a hard error, never a write target.
/// Whatever schema was read, a mutation writes the current one — every
/// write path upgrades as a side effect of writing at all.
/// [`read_for_mutation`] with the base dropped, so the two cannot drift.
pub fn load_for_mutation(path: &Path) -> Result<Option<Manifest>> {
    Ok(read_for_mutation(path)?.0)
}

/// A manifest and the base of the file it came from, from one read.
///
/// Two reads would pair a manifest with the base of whatever replaced it:
/// a writer landing between them hands the caller old content under the
/// new file's name, and the write that follows is accepted over that
/// writer — the one thing a base exists to prevent. So the text is read
/// once and both answers come from it.
pub fn read_for_mutation(path: &Path) -> Result<(Option<Manifest>, Base)> {
    crate::rename::refuse_both_generations(path)?;
    let Some(text) = read_if_exists(path)? else {
        return Ok((None, Base::absent()));
    };
    let base = Base::of(&text);
    match parse_text(path, &text)? {
        ManifestFile::Absent => Ok((None, base)),
        ManifestFile::Legacy { .. } => Err(CoreError::LegacyManifest {
            path: path.to_path_buf(),
        }),
        ManifestFile::Current(mut manifest) => {
            manifest.schema = MANIFEST_SCHEMA;
            Ok((Some(*manifest), base))
        }
    }
}

/// First manifest for a scope: the default source is seeded exactly once,
/// here — later reconciliation never re-adds it (its removal is durable).
pub fn seed(detected_harnesses: &[HarnessId]) -> Manifest {
    let mut manifest = Manifest {
        schema: MANIFEST_SCHEMA,
        ..Manifest::default()
    };
    manifest.sources.insert(
        DEFAULT_SOURCE_NAME.to_owned(),
        SourceDecl {
            repo: Some(DEFAULT_SOURCE_REPO.to_owned()),
            path: None,
            rev: None,
            enabled: true,
        },
    );
    manifest.install.harnesses = detected_harnesses.to_vec();
    manifest
}
