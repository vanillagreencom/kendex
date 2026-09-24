//! Everything a scope plan writes that is not one item's own artifact: the
//! shared config files edits land in, the install record, the manifest's
//! format line, and the settings a project's skills seed.

use std::collections::BTreeMap;
use std::path::Path;

use crate::apply::{Op, PlannedOp, Pre};
use crate::base::Base;
use crate::env::Env;
use crate::error::Result;
use crate::lock::{BundleRev, Lock, SourceRev, lock_path};
use crate::manifest::Manifest;
use crate::model::Scope;
use crate::source::{ResolvedSource, SourceState};

use super::config_edits;
use super::desired::DesiredState;
use super::report_types::{StoodIn, StoodInRecord};

/// Whether a plan already persists the manifest. A caller about to insert
/// its own save must know: a second write to the same file binds to bytes
/// the first one replaces and could never run.
pub fn persists_manifest(ops: &[PlannedOp]) -> bool {
    ops.iter()
        .any(|op| matches!(op.op, Op::WriteManifest { .. }))
}

/// The precondition the plan's one manifest write binds to: the base of
/// the editor copy when the manifest arrived whole from one, otherwise
/// the file as it is now. An editor copy's write must bind to the file
/// that copy was read from — observing the path here instead would accept
/// a writer that landed after the copy left the editor.
pub(super) fn manifest_pre(base: Option<&Base>, path: &Path) -> Result<Pre> {
    match base {
        Some(base) => Ok(base.into()),
        None => Pre::observed(path),
    }
}

/// The plan's one manifest write, when anything needs it: skills an agent
/// gained upstream. Nothing else asks for the file — only the current
/// schema loads, so there is no upgrade to plan, and a write planned for
/// its own sake would put a precondition and a plan line in front of the
/// person for a write that lands nothing. One write whatever put it
/// there: a second manifest write could never run, its precondition binds
/// to the bytes the first one replaces.
pub(super) fn plan_manifest_write(
    env: &Env,
    scope: &Scope,
    base: Option<&Base>,
    state: &DesiredState,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    let Some(update) = &state.manifest_update else {
        return Ok(());
    };
    let path = crate::manifest::manifest_path(env, scope);
    // The schema is not set here: `manifest::save` stamps it, and one
    // place deciding it is the whole point of stamping at the write.
    let written = update.clone();
    ops.push(PlannedOp {
        description: "Add new catalog skills to kendex.toml".into(),
        op: Op::WriteManifest {
            pre: manifest_pre(base, &path)?,
            path,
            manifest: Box::new(written),
        },
    });
    Ok(())
}

/// One mutation per config file, whatever asked for it — a single
/// precondition can hold; per-edit preconditions against the same original
/// bytes cannot.
pub(super) fn plan_config_edits(
    config_edits: config_edits::ConfigEditPlan,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    for (path, (labels, edits)) in config_edits.by_file {
        // Config edits bind to the bytes reachable at planning. A link
        // already there is kept and its target updated; a same-byte link
        // arriving later also satisfies this precondition.
        let pre = crate::apply::Pre::observed(&path)?;
        let current = crate::fs::read_if_exists(&path)?.unwrap_or_default();
        let remove_empty = crate::configedit::ConfigEdit::removes_empty_document(&edits, &current)
            .map_err(|message| crate::error::CoreError::ConfigEdit {
                path: path.clone(),
                message,
            })?;
        if remove_empty && !path.is_symlink() && path.exists() {
            ops.push(super::removal::trash(
                "Move empty OpenCode settings to the trash".into(),
                path,
            )?);
            continue;
        }
        let file = path
            .file_name()
            .map(|name| name.to_string_lossy().into_owned())
            .unwrap_or_else(|| path.display().to_string());
        ops.push(PlannedOp {
            description: format!("Update {file} ({})", labels.join(", ")).into(),
            op: Op::EditFile { pre, path, edits },
        });
    }
    Ok(())
}

/// What the record can say of one source or set this pass.
pub(super) enum Reading<T> {
    /// Resolved this pass, apart from the record: the entry to record.
    Fresh(T),
    /// Not resolved apart from the record: its entry, when it has one, is
    /// carried forward unread, and a proof over the record names it.
    StoodIn(StoodIn),
    /// Nothing to record: a path or reserved source, a disabled one, a
    /// name the manifest does not declare, and a set read from any of
    /// them. A recorded entry for one is dropped.
    Unrecorded,
}

/// The pass's reading of every declared source and set, by name: the one
/// place the record's provenance is decided, so the record written and the
/// record proved are read alike.
pub(super) struct RecordReadings {
    sources: BTreeMap<String, Reading<SourceRev>>,
    sets: BTreeMap<String, Reading<BundleRev>>,
}

/// Reads every declared source and set for the record. A source no item
/// named, one only a Pi extension names among them, has no resolution in
/// the pass and is read from its mirror alone, so its entry is held to the
/// declaration like any other.
pub(super) fn record_readings(
    env: &Env,
    manifest: &Manifest,
    state: &DesiredState,
) -> RecordReadings {
    let sources = manifest
        .sources
        .keys()
        .map(|name| {
            let reading = match repository(manifest, name) {
                Some((repo, rev)) => {
                    match commit_reading(env, repo, rev, state.sources.get(name)) {
                        Ok(commit) => Reading::Fresh(SourceRev {
                            repo: repo.to_owned(),
                            rev: rev.map(str::to_owned),
                            commit,
                        }),
                        Err(stood_in) => Reading::StoodIn(stood_in),
                    }
                }
                None => Reading::Unrecorded,
            };
            (name.clone(), reading)
        })
        .collect();
    let sets = manifest
        .bundles
        .iter()
        .map(|(name, decl)| {
            let reading = match repository(manifest, &decl.source) {
                Some((repo, source_rev)) => {
                    let (rev, resolution) = match &decl.rev {
                        Some(rev) => (
                            Some(rev.as_str()),
                            state.pinned.get(&(decl.source.clone(), rev.clone())),
                        ),
                        None => (source_rev, state.sources.get(&decl.source)),
                    };
                    match commit_reading(env, repo, rev, resolution) {
                        Ok(commit) => Reading::Fresh(BundleRev {
                            source: decl.source.clone(),
                            source_repo: repo.to_owned(),
                            commit,
                        }),
                        Err(stood_in) => Reading::StoodIn(stood_in),
                    }
                }
                None => Reading::Unrecorded,
            };
            (name.clone(), reading)
        })
        .collect();
    RecordReadings { sources, sets }
}

/// The repository and revision an enabled repository source is declared
/// at, or `None` for any source the record carries nothing for.
fn repository<'a>(manifest: &'a Manifest, name: &str) -> Option<(&'a str, Option<&'a str>)> {
    let decl = manifest.sources.get(name)?;
    let repo = decl.repo.as_deref()?;
    decl.enabled.then_some((repo, decl.rev.as_deref()))
}

/// The commit one enabled repository declaration reads at this pass: the
/// resolution the pass made, or, where it made none, the mirror's answer.
/// Never the record's own: a commit the record chose is the reason it
/// stood in.
fn commit_reading(
    env: &Env,
    repo: &str,
    rev: Option<&str>,
    resolution: Option<&SourceState>,
) -> std::result::Result<String, StoodIn> {
    match resolution {
        Some(SourceState::Ready(ResolvedSource {
            commit: Some(commit),
            from_record: false,
            ..
        })) => Ok(commit.clone()),
        Some(SourceState::Ready(ResolvedSource {
            from_record: true, ..
        })) => Err(StoodIn::RecordedCommit),
        Some(SourceState::Pending { .. }) => Err(StoodIn::Unserved),
        // An enabled repository declaration resolves Ready with a commit,
        // Pending, or not at all, where the resolver's failure left it out
        // of the pass. Whatever else stands here, the mirror is asked, so
        // no reading falls back to the record.
        Some(SourceState::Ready(ResolvedSource {
            commit: None,
            from_record: false,
            ..
        }))
        | Some(SourceState::Disabled { .. } | SourceState::Missing { .. })
        | None => crate::remote::mirror_commit(env, repo, rev).ok_or(StoodIn::Unserved),
    }
}

impl RecordReadings {
    /// Which commit each source resolved to, for the lock to record. What
    /// earlier passes resolved is carried forward where this one resolved
    /// nothing apart from the record — a source that is offline today
    /// should not lose the commit it was reading yesterday — and an entry
    /// the pass records nothing for drops out.
    pub(super) fn source_revisions(&self, lock: &Lock) -> BTreeMap<String, SourceRev> {
        revisions(&self.sources, &lock.sources)
    }

    /// Which commit each installed set was read at, on the same terms as
    /// [`Self::source_revisions`]: a set is read at its declaration's
    /// revision, so what it came out as is what that resolution resolved to.
    pub(super) fn bundle_revisions(&self, lock: &Lock) -> BTreeMap<String, BundleRev> {
        revisions(&self.sets, &lock.bundles)
    }

    /// Each source and set the record carries that this pass could not hold
    /// to a resolution: the entries the revisions above carried forward
    /// unread. One the record does not carry has no entry to hold.
    pub(super) fn stood_in(&self, lock: &Lock) -> StoodInRecord {
        StoodInRecord {
            sources: stood_in(&self.sources, &lock.sources),
            sets: stood_in(&self.sets, &lock.bundles),
        }
    }
}

fn revisions<T: Clone>(
    readings: &BTreeMap<String, Reading<T>>,
    recorded: &BTreeMap<String, T>,
) -> BTreeMap<String, T> {
    readings
        .iter()
        .filter_map(|(name, reading)| match reading {
            Reading::Fresh(revision) => Some((name.clone(), revision.clone())),
            Reading::StoodIn(_) => recorded
                .get(name)
                .map(|revision| (name.clone(), revision.clone())),
            Reading::Unrecorded => None,
        })
        .collect()
}

fn stood_in<T>(
    readings: &BTreeMap<String, Reading<T>>,
    recorded: &BTreeMap<String, T>,
) -> BTreeMap<String, StoodIn> {
    readings
        .iter()
        .filter_map(|(name, reading)| match reading {
            Reading::StoodIn(why) if recorded.contains_key(name) => Some((name.clone(), *why)),
            Reading::StoodIn(_) | Reading::Fresh(_) | Reading::Unrecorded => None,
        })
        .collect()
}

/// Which commit each declared revision resolved to this pass, by source
/// name and the revision the declaration pins — `None` for a declaration
/// read at the source's own revision, whose resolution the record
/// carries (earlier passes' included, on [`RecordReadings::source_revisions`]' terms),
/// and the pinned revision for one read at a pin of its own. Reported
/// whether or not the plan writes a record: a pass that refuses every
/// install writes none, and a line naming what a refused install was
/// measured against still has to say which commit that was.
pub(super) fn resolved_revisions(
    new_lock: &Lock,
    state: &DesiredState,
) -> BTreeMap<(String, Option<String>), SourceRev> {
    let mut revisions: BTreeMap<(String, Option<String>), SourceRev> = new_lock
        .sources
        .iter()
        .map(|(name, revision)| ((name.clone(), None), revision.clone()))
        .collect();
    for ((name, rev), resolution) in &state.pinned {
        let SourceState::Ready(ready) = resolution else {
            continue;
        };
        let Some(commit) = ready.commit.clone() else {
            continue;
        };
        revisions.insert(
            (name.clone(), Some(rev.clone())),
            SourceRev {
                repo: ready.provenance.clone(),
                rev: Some(rev.clone()),
                commit,
            },
        );
    }
    revisions
}

/// A carrier declaration needs a scope marker while its payload is absent.
fn declares_carrier_installs(manifest: &Manifest) -> bool {
    !manifest.pi_extensions.is_empty()
}

/// Keep a scope marker for carrier declarations even before a payload can be
/// recorded. A scope without declarations or installations needs no lock.
pub(super) fn plan_lock_write(
    env: &Env,
    scope: &Scope,
    manifest: &Manifest,
    lock: &Lock,
    new_lock: &Lock,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    let entries_unchanged = new_lock.entries == lock.entries
        && (lock.version == crate::lock::LOCK_VERSION || lock.entries.is_empty());
    let provenance_unchanged = new_lock.sources == lock.sources && new_lock.bundles == lock.bundles;
    // Whether a file sits at the path is the one question left, and it is
    // asked only where the answer can change what this does: reading it
    // hashes the record, and a scope that has nothing to write and
    // declares nothing the plan leaves unrecorded is done either way.
    if entries_unchanged && provenance_unchanged && !declares_carrier_installs(manifest) {
        return Ok(());
    }
    let path = lock_path(env, scope);
    // The same read the write below binds to. An absent lock and an empty
    // one read alike by this point, and only the file still tells them
    // apart.
    let pre = Pre::observed(&path)?;
    // A scope with no record file and no entries needs none for its
    // provenance alone; one that has a record keeps its provenance true,
    // entries or not, or the record a proof is held to goes stale.
    let unchanged = match pre.binds_nothing() {
        true => entries_unchanged && !declares_carrier_installs(manifest),
        false => entries_unchanged && provenance_unchanged,
    };
    if unchanged {
        return Ok(());
    }
    ops.push(PlannedOp {
        description: "Update the install record".into(),
        op: Op::WriteLock {
            pre,
            path,
            lock: Box::new(new_lock.clone()),
        },
    });
    Ok(())
}
