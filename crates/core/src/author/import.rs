//! The Import wizard's core: every package on this machine as a candidate,
//! and the previewed copy that brings chosen ones into an authored catalog.
//!
//! One inventory, keyed by `(kind, name)`, every byte origin listed.
//! Provenance decides the group: the person's own local-source content,
//! marketplace content (whose licence gates the copy), an edited copy of
//! marketplace content (shown beside the original, gated the same), and
//! unmanaged on-disk content captured as-is. Nothing is guessed: identical
//! bytes collapse to one origin under the *strictest* provenance, an
//! unrecognized licence cannot be confirmed away, a moved origin refuses
//! at apply, and collisions — byte, path or case-fold, on disk or between
//! selections — are refused before anything is written.

use std::collections::BTreeMap;
use std::path::PathBuf;

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::error::Result;
use crate::model::{ItemKind, Scope};

/// One importable package, with every byte origin that offers it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ImportCandidate {
    pub kind: ItemKind,
    pub name: String,
    /// Why a harness would refuse this name, when one would — the wizard
    /// requires a different destination name then.
    pub name_problem: Option<String>,
    /// Distinct byte variants, presentation-ordered own → marketplace →
    /// edited → unmanaged. Identical bytes collapse to one entry listing
    /// every location, under the strictest provenance among them; differing
    /// bytes stay separate for the person to choose.
    pub origins: Vec<CandidateOrigin>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct CandidateOrigin {
    pub group: CandidateGroup,
    /// Every place these exact bytes were seen.
    pub locations: Vec<String>,
    /// Content identity — what apply revalidates before copying. Empty
    /// where there is nothing to select.
    pub hash: String,
    /// Why these bytes are not on offer, when a catalog is what refused
    /// them: an agent in a format it cannot store. Null where the bytes
    /// were never read at all.
    pub problem: Option<String>,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(
    tag = "group",
    rename_all = "kebab-case",
    rename_all_fields = "camelCase"
)]
pub enum CandidateGroup {
    /// The person's own content in a local source.
    Own,
    /// Copied from a subscribed marketplace; its licence is shown and
    /// gates the copy.
    Marketplace {
        source: String,
        repo: String,
        license: Option<String>,
        /// Whether kendex recognizes the licence as redistributable — a
        /// recognized one is confirmable, anything else needs a basis.
        license_recognized: bool,
    },
    /// The installed copy of a marketplace package that no longer matches
    /// the marketplace's bytes — "your edited copy", shown beside the
    /// original and gated by the same licence.
    Edited {
        source: String,
        repo: String,
        license: Option<String>,
        license_recognized: bool,
    },
    /// On disk, managed by nothing — captured the way adopt captures.
    Unmanaged,
}

impl CandidateGroup {
    /// Merge order for identical bytes: the strictest provenance wins, so
    /// equal bytes can never dodge a licence gate by also existing
    /// somewhere friendlier.
    fn strictness(&self) -> u8 {
        match self {
            CandidateGroup::Marketplace { .. } => 3,
            CandidateGroup::Edited { .. } => 2,
            CandidateGroup::Unmanaged => 1,
            CandidateGroup::Own => 0,
        }
    }

    /// The licence question applies to marketplace bytes and to edited
    /// copies of them alike — editing does not launder provenance.
    pub(super) fn licensed_source(&self) -> Option<(&str, Option<&str>, bool)> {
        match self {
            CandidateGroup::Marketplace {
                source,
                license,
                license_recognized,
                ..
            }
            | CandidateGroup::Edited {
                source,
                license,
                license_recognized,
                ..
            } => Some((source, license.as_deref(), *license_recognized)),
            _ => None,
        }
    }
}

/// What the wizard chose for one candidate.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ImportSelection {
    pub kind: ItemKind,
    /// The inventory name the bytes are found under.
    pub name: String,
    /// The name to write into the catalog — the inventory name unless a
    /// harness would refuse it.
    pub destination: String,
    /// Which bytes: the chosen origin's hash.
    pub hash: String,
    /// Licensed-origin only: the person confirms the shown, recognized
    /// licence permits republishing. An unrecognized licence cannot be
    /// confirmed — it needs a basis.
    #[serde(default)]
    pub license_confirmed: bool,
    /// Licensed-origin with no recognized licence: the person's stated
    /// basis for copying ("author granted permission", say). Never
    /// synthesized.
    #[serde(default)]
    pub license_basis: Option<String>,
}

/// What one apply wrote, for the wizard's summary line.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ImportOutcome {
    pub written: Vec<String>,
    /// Selections whose exact bytes were already at the destination.
    pub already_present: Vec<String>,
}

/// The bytes of one origin: a single file or a whole skill tree.
pub(super) enum Bytes {
    File(Vec<u8>),
    Tree(Vec<(PathBuf, Vec<u8>)>),
}

impl Bytes {
    pub(super) fn hash(&self) -> String {
        match self {
            Bytes::File(bytes) => crate::hash::hash_bytes(bytes),
            Bytes::Tree(files) => crate::hash::hash_files(files),
        }
    }
}

/// One selection's bytes re-resolved at apply time, with the provenance
/// that governs it and the licence evidence files that travel with it.
pub(super) struct ResolvedSelection {
    pub bytes: Bytes,
    pub group: CandidateGroup,
    /// Root-level LICENSE/NOTICE/COPYING files of a licensed origin's
    /// catalog — copied beside the bytes, provenance retained.
    pub notices: Vec<(String, Vec<u8>)>,
    /// Where on this machine the bytes were read from, when they were —
    /// what the target-overlap refusal compares against.
    pub read_from: Option<PathBuf>,
}

/// Every package the given scopes hold, grouped and deduplicated. Origins
/// with nothing to select are listed with an empty hash, and with a
/// `problem` where a catalog is what refused them, so the wizard can show
/// them and say why; selecting one refuses at apply.
pub fn inventory(env: &Env, scopes: &[Scope]) -> Result<Vec<ImportCandidate>> {
    let unmanaged = unmanaged_paths(env, scopes);
    let mut candidates: BTreeMap<(ItemKind, String), Vec<CandidateOrigin>> = BTreeMap::new();
    for row in crate::library::provenance(env, scopes)? {
        for read in origins_of(env, &row, &unmanaged) {
            let hash = read.bytes.map(|bytes| bytes.hash()).unwrap_or_default();
            let origins = candidates.entry((row.kind, row.name.clone())).or_default();
            // Identical bytes are one origin whatever offered them; the
            // strictest provenance among the claimants governs it. With no
            // bytes there is no hash to match on, so the same place
            // refused for the same reason is the one row — a file claimed
            // both as a marketplace's edited copy and by the unmanaged
            // scan would otherwise be listed and printed twice.
            match origins.iter_mut().find(|origin| match hash.is_empty() {
                false => origin.hash == hash,
                true => {
                    origin.hash.is_empty()
                        && origin.problem == read.problem
                        && origin.locations.contains(&read.location)
                }
            }) {
                Some(origin) => {
                    if !origin.locations.contains(&read.location) {
                        origin.locations.push(read.location);
                    }
                    if read.group.strictness() > origin.group.strictness() {
                        origin.group = read.group;
                    }
                }
                None => origins.push(CandidateOrigin {
                    group: read.group,
                    locations: vec![read.location],
                    hash,
                    problem: read.problem,
                }),
            }
        }
    }
    Ok(candidates
        .into_iter()
        .map(|((kind, name), mut origins)| {
            origins.sort_by_key(|origin| match origin.group {
                CandidateGroup::Own => 0u8,
                CandidateGroup::Marketplace { .. } => 1,
                CandidateGroup::Edited { .. } => 2,
                CandidateGroup::Unmanaged => 3,
            });
            ImportCandidate {
                kind,
                name_problem: crate::names::item_problem(&name),
                name,
                origins,
            }
        })
        .collect())
}

/// The versioned envelope `marketplace import --json` wraps its candidates
/// in. Schema 2 adds a `problem` to an origin whose bytes read fine but a
/// catalog cannot store them, and widens what an empty `hash` means: under
/// schema 1 it was a read that failed, and it now also covers those
/// unstorable bytes. `problem` tells the two apart. Null is still the
/// schema-1 read that failed, and a set one names the new case. The
/// addition is free; the change of meaning in a field that was already
/// there is what the bump is for, the same call
/// [`crate::check_catalog::CHECK_SCHEMA`] made when a finding's line came
/// out of `file`.
pub const IMPORT_SCHEMA: u32 = 2;

/// How the places under [`no_importable_bytes`] are laid out.
pub enum Places {
    /// All on the sentence's own line. What a [`crate::error::CoreError`]
    /// takes: a message that does not own its breaks has them escaped
    /// where the CLI prints it.
    OneLine,
    /// One place per line, for a caller whose refusal owns its breaks.
    PerLine,
}

/// The refusal for a name whose every origin is unusable — one sentence,
/// wherever it is said.
///
/// Two callers reach it: the apply-time resolve, which has the origins in
/// hand, and the CLI, which refuses before a selection exists. They differ
/// only in layout, which is presentation and stays theirs; the sentence,
/// the place-and-reason join and the escaping are one thing and live here.
///
/// Every value is spelled through [`crate::names::shown`]: a name is read
/// off a directory on disk and a place is a path off one, so either can
/// carry a control character or a bidi override, and no caller has to
/// remember. The same place refused for the same reason is said once.
pub fn no_importable_bytes(
    kind: ItemKind,
    name: &str,
    places: &[(String, Option<String>)],
    layout: Places,
) -> String {
    let (lead, between) = match layout {
        Places::OneLine => (" ", "; "),
        Places::PerLine => ("\n", "\n"),
    };
    let mut said: Vec<String> = Vec::new();
    for (place, problem) in places {
        let line = match problem {
            Some(problem) => format!("{place} — {problem}"),
            None => place.clone(),
        };
        let line = crate::names::shown(&line);
        if !said.contains(&line) {
            said.push(line);
        }
    }
    format!(
        "{} '{}' has no bytes kendex can import:{lead}{}",
        kind.name(),
        crate::names::shown(name),
        said.join(between)
    )
}

/// Licences kendex recognizes as redistributable. A licence outside this
/// list is not "unknown but confirmable" — it needs a stated basis, the
/// same as no licence at all, because a checkbox cannot make proprietary
/// text copyable.
pub const REDISTRIBUTABLE: &[&str] = &[
    "MIT",
    "Apache-2.0",
    "BSD-2-Clause",
    "BSD-3-Clause",
    "ISC",
    "MPL-2.0",
    "Unlicense",
    "CC0-1.0",
    "0BSD",
    "Zlib",
    "CC-BY-4.0",
    "CC-BY-SA-4.0",
];

pub fn license_recognized(license: &str) -> bool {
    REDISTRIBUTABLE.contains(&license)
}

mod apply;
mod origins;
pub use apply::apply;
use origins::{origins_of, resolve_selection, unmanaged_paths};

#[cfg(test)]
mod tests;
