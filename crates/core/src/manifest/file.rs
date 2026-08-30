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

/// What sits at a manifest path — absent, or the one schema this build
/// reads. Anything else is refused by the read that classified it.
#[derive(Debug, Clone, PartialEq)]
pub enum ManifestFile {
    Absent,
    Current(Box<Manifest>),
}

/// Whether a project root's kendex.toml marks itself the canonical catalog
/// (`is_source_catalog = true`), so install state routes to the sibling.
pub fn is_source_catalog(root: &Path) -> bool {
    std::fs::read_to_string(root.join(super::MANIFEST_FILE))
        .ok()
        .and_then(|text| text.parse::<toml::Table>().ok())
        .and_then(|table| {
            table
                .get("is_source_catalog")
                .and_then(toml::Value::as_bool)
        })
        .unwrap_or(false)
}

/// Where this scope's manifest lives. Off the canonical root, like every
/// scope-path derivation: the path must compare equal to the ones the
/// engine's plan speaks, whatever spelling the scope arrived under.
pub fn manifest_path(env: &Env, scope: &Scope) -> std::path::PathBuf {
    match &scope.canonical() {
        Scope::Global => env.global_manifest_file(),
        // A source catalog's own kendex.toml is the definition it
        // publishes; its install state goes to the sibling file.
        Scope::Project { root } if is_source_catalog(root) => root.join(super::LOCAL_MANIFEST_FILE),
        Scope::Project { root } => Env::project_manifest_file(root),
    }
}

pub fn load(path: &Path) -> Result<ManifestFile> {
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
    let schema = table.get("schema").and_then(toml::Value::as_integer);
    if schema.is_some_and(|schema| schema > i64::from(MANIFEST_SCHEMA)) {
        return Err(CoreError::SchemaTooNew {
            path: path.to_path_buf(),
            found: schema.unwrap_or_default(),
        });
    }
    // The floor. Nothing converts an older file, and reading one is not the
    // harmless half of that: every schema since 1 changed what a table
    // means, so a value read under the wrong one is a wrong answer, and the
    // write that follows makes it durable — including over the person's own
    // comments. So the file is left exactly as they wrote it and the
    // refusal says what to do with it.
    if schema != Some(i64::from(MANIFEST_SCHEMA)) {
        return Err(CoreError::LegacyManifest {
            path: path.to_path_buf(),
            message: match schema {
                Some(schema) => format!(
                    "it is a schema {schema} manifest, and this kendex writes schema {MANIFEST_SCHEMA}"
                ),
                None => "it names no schema, so nothing here can say what shape it is".to_owned(),
            },
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

/// The scope's manifest for a read that only annotates rows: what the
/// file declares, or nothing where there is no file and nothing this
/// build can read. A browse, a library table or a marketplace page shows
/// what is installed and marks which of it this scope declares; a scope
/// whose manifest came from another version of kendex marks nothing, and
/// blanking every other scope's rows over it is the failure this exists
/// to stop. Everything else still propagates — the refusal absorbed here
/// is exactly [`CoreError::is_unreadable_record`], never an IO error.
pub fn observed(path: &Path) -> Result<Manifest> {
    match load(path) {
        Ok(ManifestFile::Current(manifest)) => Ok(*manifest),
        Ok(ManifestFile::Absent) => Ok(Manifest::default()),
        Err(error) if error.is_unreadable_record() => Ok(Manifest::default()),
        Err(error) => Err(error),
    }
}

pub fn save(path: &Path, manifest: &Manifest) -> Result<()> {
    // Stamped at the write, the way the lock stamps its version: the
    // schema is a fact about the build doing the writing, and two places
    // deciding it is how a writer comes to put down something its own
    // reader refuses.
    let manifest = &Manifest {
        schema: MANIFEST_SCHEMA,
        ..manifest.clone()
    };
    let text = toml::to_string_pretty(manifest).map_err(|e| CoreError::TomlParse {
        path: path.to_path_buf(),
        message: e.to_string(),
    })?;
    atomic_write(path, &text)
}

/// Load for mutation. Only the current schema loads at all, so there is
/// nothing to upgrade here. [`read_for_mutation`] with the base dropped, so
/// the two cannot drift.
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
    let Some(text) = read_if_exists(path)? else {
        return Ok((None, Base::absent()));
    };
    let base = Base::of(&text);
    match parse_text(path, &text)? {
        ManifestFile::Absent => Ok((None, base)),
        ManifestFile::Current(manifest) => Ok((Some(*manifest), base)),
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
