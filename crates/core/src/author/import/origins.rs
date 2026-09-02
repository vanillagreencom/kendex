//! Where each candidate's bytes actually live: the provenance join, the
//! per-row origin reads (marketplace beside its edited install), and the
//! apply-time re-resolution that revalidates the previewed hash.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::library::Origin;
use crate::manifest::{INPLACE_SOURCE_NAME, Manifest, ManifestFile};
use crate::model::{ItemKind, Scope};
use crate::source_read::SealedSource;

use super::{Bytes, CandidateGroup, ImportSelection, ResolvedSelection, license_recognized};

mod notices;
use notices::notice_files;

/// The observed on-disk path of every installation — provenance rows carry
/// no path, so the scan is asked once and joined here. Managed installs
/// are included: their observed bytes are what an "edited copy" is.
pub(super) fn unmanaged_paths(
    env: &Env,
    scopes: &[Scope],
) -> BTreeMap<(Scope, ItemKind, String), PathBuf> {
    let Ok(settings) = crate::settings::load(env) else {
        return BTreeMap::new();
    };
    let scopes: Vec<Scope> = scopes.iter().map(Scope::canonical).collect();
    let observed = crate::scan::scan_scopes(env, &settings.harness_roots, &scopes);
    let mut paths = BTreeMap::new();
    for item in observed.items {
        if item.vendor.is_some() {
            continue;
        }
        paths
            .entry((item.scope, item.kind, item.name))
            .or_insert(item.path);
    }
    paths
}

/// Where one provenance row's bytes live — possibly two answers, when the
/// installed copy of a marketplace package differs from the marketplace's
/// own bytes. Empty for rows import cannot carry (config-entry kinds have
/// no file of their own to copy).
/// The `String` is where the bytes were read from, said the way kendex
/// says a path: [`crate::paths::slashed`], because callers match on it
/// (`.agents/skills/…`) and a `\` there matches nothing.
type OriginRead = (CandidateGroup, Option<Bytes>, String, Option<PathBuf>);

/// Why these bytes cannot be the agent a catalog stores, when they cannot.
///
/// A catalog keeps an agent at `agents/<name>.md` ([`crate::source::local_slot`])
/// and every install reads that file as markdown with a frontmatter block
/// ([`crate::render::agent::parse_source_agent`]). A harness that keeps its
/// agents in some other format offers files that would land in that slot
/// unchanged — Codex writes TOML — and nothing downstream catches it: the
/// catalog check's structural pass never validates an agent, so the author
/// is told the package is fine and every consumer's install refuses it.
/// The offer is where it stops.
///
/// Asked of the bytes, never of the extension. Cursor writes `.mdc` and a
/// switched-off agent is parked at `.md.disabled`; both are frontmatter,
/// and the spellings do not end.
///
/// Not [`crate::render::skill::bytes_named`], which answers the narrower
/// question of whether a *rename* can be written in: it also refuses a
/// name given twice or one running past its line, and an import keeping
/// the candidate's name copies those bytes verbatim today.
fn agent_shape_problem(kind: ItemKind, bytes: &Bytes) -> Option<&'static str> {
    if kind != ItemKind::Agent {
        return None;
    }
    // A tree is unconstructible for an agent: `read_bytes` makes a skill a
    // tree and every other kind a file.
    let Bytes::File(bytes) = bytes else {
        return None;
    };
    let Ok(text) = std::str::from_utf8(bytes) else {
        return Some("the file is not text");
    };
    match crate::frontmatter::split(text) {
        Ok(_) => None,
        // The two send a reader to different edits, which is why `split`
        // tells them apart.
        Err(problem) if problem.contains("unterminated") => {
            Some("its frontmatter block is never closed")
        }
        Err(_) => Some("it has no frontmatter"),
    }
}

/// One origin as the wizard may offer it. Bytes a catalog cannot store are
/// listed without their hash — the shape [`marketplace_origins`] already
/// uses for a marketplace nobody fetched — so the row shows and nothing
/// can select it, and the location carries the reason rather than leaving
/// the person to guess why their agent is not offerable.
fn offered(kind: ItemKind, bytes: Bytes, location: String) -> (Option<Bytes>, String) {
    match agent_shape_problem(kind, &bytes) {
        Some(problem) => (
            None,
            format!("{location} — {problem}, and a catalog stores an agent as markdown"),
        ),
        None => (Some(bytes), location),
    }
}

pub(super) fn origins_of(
    env: &Env,
    row: &crate::library::ProvenanceRow,
    observed: &BTreeMap<(Scope, ItemKind, String), PathBuf>,
) -> Vec<OriginRead> {
    match &row.origin {
        Origin::Own { source, .. } => {
            // The reserved source names where the bytes live: the local
            // capture, or the shared tree an in-place skill is read from
            // (a scope with no such tree holds no in-place rows).
            let root = if source == INPLACE_SOURCE_NAME {
                match crate::source::inplace_source_root(&row.scope) {
                    Some(root) => root,
                    None => return Vec::new(),
                }
            } else {
                crate::source::local_source_root(env, &row.scope)
            };
            match catalog_bytes(&root, source, row) {
                Some((bytes, location, read_from)) => {
                    vec![(CandidateGroup::Own, bytes, location, Some(read_from))]
                }
                None => Vec::new(),
            }
        }
        Origin::Marketplace { source, repo } => {
            marketplace_origins(env, row, source, repo, observed)
        }
        Origin::Unmanaged => {
            if !matches!(
                row.kind,
                ItemKind::Skill | ItemKind::Agent | ItemKind::Command
            ) {
                return Vec::new();
            }
            let Some(path) = observed.get(&(row.scope.clone(), row.kind, row.name.clone())) else {
                return Vec::new();
            };
            let Some(bytes) = path
                .parent()
                .and_then(|parent| SealedSource::open(parent).ok())
                .and_then(|sealed| read_bytes(&sealed, row.kind, path))
            else {
                return Vec::new();
            };
            let (bytes, location) = offered(row.kind, bytes, crate::paths::slashed(path));
            vec![(
                CandidateGroup::Unmanaged,
                bytes,
                location,
                Some(path.clone()),
            )]
        }
    }
}

/// A marketplace row's origins: the marketplace's own bytes, and — when
/// the installed copy no longer matches them — the edited copy beside the
/// original, so the choice pass 3 requires is a real choice.
pub(super) fn marketplace_origins(
    env: &Env,
    row: &crate::library::ProvenanceRow,
    source: &str,
    repo: &str,
    observed: &BTreeMap<(Scope, ItemKind, String), PathBuf>,
) -> Vec<OriginRead> {
    let manifest = scope_manifest(env, &row.scope);
    let unreachable = |license: Option<String>| {
        vec![(
            CandidateGroup::Marketplace {
                source: source.to_owned(),
                repo: repo.to_owned(),
                license_recognized: license.as_deref().is_some_and(license_recognized),
                license,
            },
            None,
            format!("{repo} (not fetched)"),
            None,
        )]
    };
    let resolved = match crate::source::resolve(env, &row.scope, source, &manifest) {
        Ok(crate::source::SourceState::Ready(resolved)) => resolved,
        // Unreachable provenance is listed, not guessed: the row shows
        // with no bytes and selecting it refuses.
        _ => return unreachable(None),
    };
    let Ok(sealed) = SealedSource::open(&resolved.root) else {
        return unreachable(None);
    };
    let Ok(config) = crate::source::source_config_for(&sealed, &resolved.provenance) else {
        return unreachable(None);
    };
    let license = config
        .marketplace
        .as_ref()
        .and_then(|meta| meta.license.clone());
    let Some(path) = crate::source::find_item(&sealed, &config, row.kind, &row.name) else {
        return unreachable(license);
    };
    let Some(bytes) = read_bytes(&sealed, row.kind, &path) else {
        return unreachable(license);
    };
    let source_hash = bytes.hash();
    let (bytes, location) = offered(row.kind, bytes, format!("{repo}:{}", rel(&sealed, &path)));
    let mut origins = vec![(
        CandidateGroup::Marketplace {
            source: source.to_owned(),
            repo: repo.to_owned(),
            license: license.clone(),
            license_recognized: license.as_deref().is_some_and(license_recognized),
        },
        bytes,
        location,
        Some(path.clone()),
    )];
    // The installed copy, when it diverged: read at its observed path.
    if let Some(installed) = observed.get(&(row.scope.clone(), row.kind, row.name.clone()))
        && let Some(edited) = installed
            .parent()
            .and_then(|parent| SealedSource::open(parent).ok())
            .and_then(|sealed| read_bytes(&sealed, row.kind, installed))
        && edited.hash() != source_hash
    {
        // An agent installs as the file its harness reads, so the edited
        // copy of a marketplace agent under Codex is the TOML rendering —
        // the same bytes a catalog cannot store, arriving by the other
        // door.
        let (edited, location) = offered(row.kind, edited, crate::paths::slashed(installed));
        origins.push((
            CandidateGroup::Edited {
                source: source.to_owned(),
                repo: repo.to_owned(),
                license_recognized: license.as_deref().is_some_and(license_recognized),
                license,
            },
            edited,
            location,
            Some(installed.clone()),
        ));
    }
    origins
}

pub(super) fn catalog_bytes(
    root: &Path,
    provenance: &str,
    row: &crate::library::ProvenanceRow,
) -> Option<(Option<Bytes>, String, PathBuf)> {
    let sealed = SealedSource::open(root).ok()?;
    let config = crate::source::source_config_for(&sealed, provenance).ok()?;
    let path = crate::source::find_item(&sealed, &config, row.kind, &row.name)?;
    let bytes = read_bytes(&sealed, row.kind, &path)?;
    let location = crate::paths::slashed(&root.join(rel_path(&sealed, &path)));
    // A catalog's own agent slot is `<name>.md`, so this is bytes somebody
    // already wrote there in another format — copying them on would carry
    // the breakage into a second package.
    let (bytes, location) = offered(row.kind, bytes, location);
    Some((bytes, location, path))
}

pub(super) fn read_bytes(sealed: &SealedSource, kind: ItemKind, path: &Path) -> Option<Bytes> {
    match kind {
        ItemKind::Skill => {
            let dir = match sealed.is_dir(path) {
                true => path.to_path_buf(),
                // A one-skill repo hands the SKILL.md itself.
                false => path.parent()?.to_path_buf(),
            };
            let files = sealed.collect_skill_tree(&dir).ok()?;
            Some(Bytes::Tree(files))
        }
        _ => Some(Bytes::File(sealed.read(path).ok()?)),
    }
}

/// Where `path` sits inside the catalog, as text a caller can match: an
/// origin's location is read back against catalog paths, and those are
/// `/`-spelled wherever they are written down.
pub(super) fn rel(sealed: &SealedSource, path: &Path) -> String {
    crate::paths::slashed(rel_path(sealed, path))
}

/// The same as a path, for a caller that has more to join on before the
/// spelling is settled — spelling a path in two halves leaves the seam in
/// whichever spelling the platform joined with.
fn rel_path<'a>(sealed: &SealedSource, path: &'a Path) -> &'a Path {
    path.strip_prefix(sealed.root()).unwrap_or(path)
}

pub(super) fn scope_manifest(env: &Env, scope: &Scope) -> Manifest {
    crate::manifest::load(&crate::manifest::manifest_path(env, scope))
        .ok()
        .and_then(|file| match file {
            ManifestFile::Current(manifest) => Some(*manifest),
            _ => None,
        })
        .unwrap_or_default()
}

/// The bytes behind one selection, re-read now so the hash the person saw
/// is revalidated against what is on disk at apply time — along with the
/// provenance that governs it and its licence evidence files.
pub(super) fn resolve_selection(
    env: &Env,
    scopes: &[Scope],
    selection: &ImportSelection,
) -> Result<ResolvedSelection> {
    let observed = unmanaged_paths(env, scopes);
    // Where the bytes were, for a selection nothing matches. Every origin
    // this name has is unselectable, and their locations say why — a
    // marketplace nobody fetched, an agent in a format a catalog cannot
    // store — so the refusal repeats that rather than blaming a change
    // nobody made.
    let mut unusable: Vec<String> = Vec::new();
    let mut selectable = false;
    for row in crate::library::provenance(env, scopes)? {
        if row.kind != selection.kind || row.name != selection.name {
            continue;
        }
        for (group, bytes, location, read_from) in origins_of(env, &row, &observed) {
            let Some(bytes) = bytes else {
                // One place per line of the refusal: the same file is
                // claimed twice where a marketplace install is also
                // scanned unmanaged.
                if !unusable.contains(&location) {
                    unusable.push(location);
                }
                continue;
            };
            selectable = true;
            if bytes.hash() != selection.hash {
                continue;
            }
            let notices = match group.licensed_source() {
                Some((source, _, _)) => notice_files(env, &row.scope, source)?,
                None => Vec::new(),
            };
            return Ok(ResolvedSelection {
                bytes,
                group,
                notices,
                read_from,
            });
        }
    }
    if !selectable && !unusable.is_empty() {
        return Err(CoreError::Authoring {
            message: format!(
                "{} '{}' has no bytes kendex can import: {}",
                selection.kind.name(),
                crate::names::shown(&selection.name),
                // A location is a path off disk like the name is, and the
                // refusal quotes both.
                crate::names::shown(&unusable.join("; "))
            ),
        });
    }
    Err(CoreError::Authoring {
        message: format!(
            "the bytes of {} '{}' changed since the preview — re-open the import to re-preview",
            selection.kind.name(),
            selection.name
        ),
    })
}
