//! Reading and writing a manifest file: what sits at a path, how a
//! mutation upgrades the schema as a side effect of writing at all, and
//! the one place a new scope gets its default source.

use std::path::Path;

use serde::{Deserialize, Serialize};
use specta::Type;

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
pub fn load_for_mutation(path: &Path) -> Result<Option<Manifest>> {
    match load(path)? {
        ManifestFile::Absent => Ok(None),
        ManifestFile::Legacy { .. } => Err(CoreError::LegacyManifest {
            path: path.to_path_buf(),
        }),
        ManifestFile::Current(mut manifest) => {
            manifest.schema = MANIFEST_SCHEMA;
            Ok(Some(*manifest))
        }
    }
}

/// What a copy of a whole file remembers about the file it came from.
///
/// There is one way to derive one — [`Base::of`], over the bytes it
/// describes — because the failure this exists to prevent is a base paired
/// with content nobody read together. A base taken by a read separate from
/// the content it answers for describes a different moment: a writer
/// landing between the two hands the caller old content under the new
/// file's name, and the write that follows is accepted over that writer.
/// Nothing here takes a path and hands back a base, deliberately — a path
/// is not the bytes, and reading them apart is how the two come adrift.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(transparent)]
pub struct Base(Option<String>);

impl Base {
    /// The base of exactly these bytes.
    pub fn of(text: &str) -> Base {
        Base(Some(crate::hash::hash_bytes(text.as_bytes())))
    }

    /// Nothing was there, which is an answer a copy can hold: a write
    /// carrying it says "there was no file", and is refused if there is
    /// one now.
    pub fn absent() -> Base {
        Base(None)
    }

    /// What a caller in another process says its copy came from.
    ///
    /// The bytes are behind an IPC boundary, so they cannot be read here
    /// and this is the one base not derived from content in hand. It is
    /// never trusted: its only use is to be compared with a base this
    /// process derived, and anything but equal refuses.
    pub fn claimed(value: Option<String>) -> Base {
        Base(value)
    }

    /// What it says, for the one thing inside this crate that has to spell
    /// it out: the precondition a write binds to. Reading a base is safe —
    /// deriving one is what is kept to a single door.
    pub(crate) fn hash(&self) -> Option<&str> {
        self.0.as_deref()
    }
}

/// A manifest and the base of the file it came from, from one read.
///
/// Two reads would pair a manifest with the base of whatever replaced it:
/// a writer landing between them hands the caller old content under the new
/// file's name, and the write that follows is accepted over that writer —
/// the one thing a base exists to prevent. So the text is read once and
/// both answers come from it.
pub fn read_for_mutation(path: &Path) -> Result<(Option<Manifest>, Base)> {
    crate::rename::refuse_both_generations(path)?;
    let Some(text) = read_if_exists(path)? else {
        return Ok((None, Base::absent()));
    };
    parse_with_base(path, &text)
}

/// [`read_for_mutation`] for text already in hand, and where the pairing is
/// provable: the base is taken over exactly these bytes.
///
/// Not public beyond this module, and that is the point. It proves the base
/// matches *these* bytes; it cannot prove these are the bytes the caller
/// went on to write. Reachable from outside, that is a way to assemble by
/// hand the pairing [`Base`] exists to prevent — the same fault as a base
/// read separately from its content, arriving by value instead of by path.
/// In here there is one caller, and it hands over the bytes it just read.
pub(super) fn parse_with_base(path: &Path, text: &str) -> Result<(Option<Manifest>, Base)> {
    let base = Base::of(text);
    match parse_text(path, text)? {
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

/// Refuse a whole-file write whose copy came from a file that is no longer
/// there. Writing it would put the older content back over whatever
/// replaced it, and the writer is the only place that can know: a caller
/// can forget to ask, and forgetting is silent.
/// The file's own base is derived here and never handed back — a caller
/// holding one would be holding a base for content it never read, which is
/// the shape [`Base`] exists to keep unspellable.
pub fn check_base(path: &Path, held: &Base) -> Result<()> {
    let now = match read_if_exists(path)? {
        Some(text) => Base::of(&text),
        None => Base::absent(),
    };
    match now == *held {
        true => Ok(()),
        false => Err(CoreError::PlanStale {
            path: path.to_path_buf(),
        }),
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
