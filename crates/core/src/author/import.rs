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
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::env::Env;
use crate::error::{CoreError, Result};
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
    /// The installed copy of a marketplace package whose bytes have drifted
    /// from the marketplace's — "your edited copy", shown beside the
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
    pub fn licensed_source(&self) -> Option<(&str, Option<&str>, bool)> {
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
            // Grouped by the package, not by what a tool stores it as: a
            // Cursor hook is observed as an agent named `safety-…`, and
            // keying that would offer a candidate no catalog has.
            let package = row.package_ref();
            let origins = candidates.entry((package.kind, package.name)).or_default();
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
/// schema-1 read that failed, and a set one names unstorable bytes. The
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

/// Whether a copy of this kind is something a catalog-shaped tree can
/// hold: a package with files of its own, at the slot
/// [`crate::source::local_slot`] resolves for it. A plugin and a Pi
/// extension are a registry's and a carrier's, installed with what brings
/// them rather than copied on their own.
///
/// One judgement, because two copiers reach it — the import into an
/// authored catalog, and the copy a template takes into its own store —
/// and a kind one of them carried and the other refused would be bytes
/// written into a slot nothing can read back.
pub fn carries(kind: ItemKind) -> bool {
    matches!(
        kind,
        ItemKind::Skill
            | ItemKind::Agent
            | ItemKind::Hook
            | ItemKind::Command
            | ItemKind::McpServer
    )
}

mod apply;
mod origins;
pub use apply::apply;
use origins::{origins_of, resolve_selection, unmanaged_paths};

/// One previewed selection's bytes, re-read from the machine and
/// revalidated against the hash the preview showed, with the licence
/// notices a licensed origin travels with.
///
/// The same resolution an import into a catalog runs, offered to a caller
/// that copies the bytes somewhere else — a template's own store. What
/// counts as an origin, which bytes a catalog can hold, and what a stale
/// preview refuses with are decided once, here, so a second copier cannot
/// answer any of them differently.
pub struct ResolvedBytes {
    /// `(relative path, bytes)` pairs. A skill is its tree; every other
    /// kind is the one file it keeps, under the leaf it was read as.
    pub files: Vec<(PathBuf, Vec<u8>)>,
    /// The licence and attribution files a licensed origin travels with,
    /// at the `NOTICES/<source>/<file>` paths a catalog-shaped tree keeps
    /// them under. Empty for content that is the person's own.
    pub notices: Vec<(PathBuf, Vec<u8>)>,
}

/// Re-resolve one selection's bytes, past the same gates the import into
/// a catalog passes.
///
/// The hash the preview showed is revalidated, so bytes that changed
/// underneath refuse rather than copy; a name no harness could hold
/// refuses; a kind with no package boundary of its own refuses; and
/// licensed bytes refuse without the person's evidence. A caller that
/// copies what this hands back does not repeat any of those questions,
/// and cannot skip one by not knowing it existed.
pub fn resolve(env: &Env, scopes: &[Scope], selection: &ImportSelection) -> Result<ResolvedBytes> {
    if let Some(problem) = crate::names::item_problem(&selection.destination) {
        return Err(CoreError::Authoring {
            message: format!(
                "'{}' cannot name a copied {} — {problem}",
                crate::names::shown(&selection.destination),
                selection.kind.name()
            ),
        });
    }
    if !carries(selection.kind) {
        return Err(CoreError::Authoring {
            message: format!(
                "a {} is installed with the package that carries it, so it cannot be copied on its own",
                selection.kind.name()
            ),
        });
    }
    let answer = resolve_selection(env, scopes, selection)?;
    license_gate(selection, &answer.group)?;
    let files = match answer.bytes {
        Bytes::Tree(files) => files,
        Bytes::File(bytes) => {
            let leaf = answer
                .read_from
                .as_deref()
                .and_then(std::path::Path::file_name)
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from(&selection.name));
            vec![(leaf, bytes)]
        }
    };
    // Laid out the way an authored catalog lays them out, so bytes that
    // travel on carry their terms in the one place every reader of a
    // catalog-shaped tree already looks.
    let notices = match answer.group.licensed_source() {
        Some((source, _, _)) => answer
            .notices
            .into_iter()
            .map(|(name, bytes)| Ok((notice_path(source, &name)?, bytes)))
            .collect::<Result<Vec<_>>>()?,
        None => Vec::new(),
    };
    Ok(ResolvedBytes { files, notices })
}

/// Where licence and attribution files sit inside a catalog-shaped tree:
/// `NOTICES/<source>/<file>`. One spelling, because the import writes it
/// and the template store and every destination read it back.
pub const NOTICES_DIR: &str = "NOTICES";

/// The path one licensed origin's licence file sits at inside a
/// catalog-shaped tree, refusing a source alias that could not be one
/// directory name.
///
/// The alias is the person's, not kendex's: `kendex subscribe --name` and
/// the app's subscribe field take it as typed, and a project's
/// `kendex.toml` names a source by its table key. Joined unexamined it
/// spells its own destination, so licence bytes would land outside the
/// tree the caller passed — the template's store, or an authored catalog.
/// [`crate::names::segment_problem`] is the judge, the rule this
/// repository already keeps for what one name may be and what Windows will
/// quietly make of one; a test against the literal `..` never sees
/// `..\victim`, where the backslash is the separator.
///
/// The file's own name is not asked here: it is a directory entry's
/// `file_name` read off the origin's catalog root, which no filesystem
/// lets hold a separator. The write boundaries ask every segment again —
/// `template::store::write` does — because they are what a path reaching
/// them may not leave.
pub fn notice_path(source: &str, name: &str) -> Result<PathBuf> {
    if let Some(problem) = crate::names::segment_problem(source) {
        return Err(CoreError::Authoring {
            message: format!(
                "'{}' cannot name the marketplace these terms came from — {problem}",
                crate::names::shown(source)
            ),
        });
    }
    Ok(PathBuf::from(NOTICES_DIR).join(source).join(name))
}

/// How a licence file already at a destination stands against the bytes
/// that want to be there.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum NoticeStanding {
    /// Nothing is there. The bytes are written.
    Absent,
    /// The same bytes are already there. Nothing to write, and nothing
    /// wrong: one licence file reached through two origins is one file.
    Same,
    /// Different bytes are already there, or bytes that cannot be read
    /// back to compare. The caller refuses.
    Different,
}

/// The one rule for a licence file that is already where these bytes go.
///
/// Bytes that match are the same terms, so the write is dropped; bytes
/// that differ are somebody else's terms under a name these bytes claim,
/// so the caller refuses and says which file. Never an overwrite, which
/// puts one origin's terms over another's, and never a silent skip, which
/// leaves content associated with terms that are not its own — the two
/// ways of getting this wrong, and the reason every site asks here rather
/// than deciding for itself.
///
/// Bytes that will not read back are `Different` deliberately: bytes that
/// cannot be compared cannot be confirmed as these.
pub fn notice_standing(dest: &Path, bytes: &[u8]) -> NoticeStanding {
    if dest.symlink_metadata().is_err() {
        return NoticeStanding::Absent;
    }
    match std::fs::read(dest) {
        Ok(existing) if existing == bytes => NoticeStanding::Same,
        _ => NoticeStanding::Different,
    }
}

/// Whether the evidence a person gave satisfies [`license_gate`] for
/// bytes offered under `license`.
///
/// The gate's own rule, asked without a resolved origin in hand, so a
/// surface can say which answer is still needed before the copy runs
/// rather than restating the rule and drifting from it. The gate is still
/// what refuses; this only decides whether it would.
pub fn license_answered(
    license: Option<&str>,
    recognized: bool,
    confirmed: bool,
    basis: Option<&str>,
) -> bool {
    match license {
        // A licence kendex recognizes takes the confirmation and nothing
        // else: a stated basis is what stands in for one it cannot judge.
        Some(_) if recognized => confirmed,
        _ => basis_given(basis),
    }
}

fn basis_given(basis: Option<&str>) -> bool {
    basis.map(str::trim).is_some_and(|basis| !basis.is_empty())
}

/// Licensed-origin content copies only past licence evidence: a shown,
/// *recognized* licence the person confirmed, or an explicit basis they
/// stated. Confirmation never synthesizes permission — an unrecognized
/// licence cannot be checkbox-approved.
///
/// Both copiers ask it: the import into an authored catalog, and the copy
/// a template takes into its own store. It lives here rather than in
/// either of them so a second copier cannot arrive without it.
pub(super) fn license_gate(selection: &ImportSelection, group: &CandidateGroup) -> Result<()> {
    let Some((source, license, recognized)) = group.licensed_source() else {
        return Ok(());
    };
    let basis_given = basis_given(selection.license_basis.as_deref());
    match license {
        Some(license) if recognized => match selection.license_confirmed {
            true => Ok(()),
            false => Err(CoreError::Authoring {
                message: format!(
                    "'{}' comes from marketplace '{source}' under licence {license} — confirm the licence permits republishing, or pick another origin",
                    selection.name
                ),
            }),
        },
        Some(license) if basis_given => {
            let _ = license;
            Ok(())
        }
        Some(license) => Err(CoreError::Authoring {
            message: format!(
                "'{}' comes from marketplace '{source}' under '{license}', which kendex does not recognize as redistributable — state your basis for copying it (--license-basis), or pick another origin",
                selection.name
            ),
        }),
        None if basis_given => Ok(()),
        None => Err(CoreError::Authoring {
            message: format!(
                "'{}' comes from marketplace '{source}' with no detectable licence — state your basis for copying it (--license-basis), or pick another origin",
                selection.name
            ),
        }),
    }
}

#[cfg(test)]
mod tests;
