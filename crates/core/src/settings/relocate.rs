//! Reconnecting a registered project to the folder it now sits in.
//!
//! A project folder renamed or moved outside kendex leaves the registry
//! pointing at a path nothing is at. What is installed there did not
//! change: the manifest, the record, the customizations and the files are
//! all in the folder that moved. So the recovery is one registry entry
//! replaced by another, and nothing on disk written — never a removal and
//! a fresh install, which is what loses the local packages, the ignored
//! env files and the uncommitted work in that folder.
//!
//! Two steps, because the person has to be able to see what they are
//! agreeing to before it happens: [`inspect`] says what stands at the
//! folder they picked, and [`relocate_project`] makes the move. Both judge
//! the destination by the same [`Standing`], so what the confirmation
//! explains is what the write enforces.

use std::path::{Path, PathBuf};

use serde::Serialize;
use specta::Type;

use crate::base::Base;
use crate::env::Env;
use crate::error::{CoreError, Result};
use crate::model::Scope;
use crate::package::updates::{IgnoredUpdate, scope_key};

use super::{AppSettings, mutate, recorded_entry};

/// What stands at the folder a project would be reconnected to.
///
/// One answer, in precedence order: everything that refuses the move
/// outranks everything that allows it, so a folder holding another
/// project's record is never offered as a place to join entries at.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum Standing {
    /// The folder cannot be read as a folder on this machine, in the words
    /// the system gave.
    FolderMissing { said: String },
    /// It holds a record this build cannot read, which supports no claim
    /// about whose folder it is.
    RecordUnreadable { said: String },
    /// It holds a record written under a third project. This is not the
    /// project being reconnected, whatever the folder is called.
    RecordElsewhere { root: PathBuf },
    /// It is the folder this entry already names.
    Unchanged,
    /// It is a registered project in its own right, so the move joins two
    /// entries into one. Only an explicit choice may do that.
    Registered,
    /// It holds the record written under the folder being left: this is
    /// that project, moved.
    Moved,
    /// It holds a record naming itself — the shape a move leaves once
    /// anything has applied here since.
    Settled,
    /// It holds no kendex record. Nothing there contradicts the move and
    /// nothing confirms it: a project registered before anything was
    /// installed in it leaves no record behind.
    NoRecord,
}

impl Standing {
    /// Whether a move to a folder in this standing may go ahead.
    /// `consolidate` is the person's explicit choice to join two entries.
    fn refusal(&self, to: &Path, consolidate: bool) -> Option<CoreError> {
        let path = to.to_path_buf();
        match self {
            Standing::FolderMissing { said } => Some(CoreError::ProjectFolderMissing {
                path,
                said: said.clone(),
            }),
            Standing::RecordUnreadable { said } => Some(CoreError::ProjectRecordUnreadable {
                path,
                said: said.clone(),
            }),
            Standing::RecordElsewhere { root } => Some(CoreError::ProjectRecordElsewhere {
                path,
                recorded: root.clone(),
            }),
            Standing::Unchanged => Some(CoreError::ProjectAlreadyRegistered { path }),
            Standing::Registered if !consolidate => {
                Some(CoreError::ProjectFolderRegistered { path })
            }
            Standing::Registered | Standing::Moved | Standing::Settled | Standing::NoRecord => None,
        }
    }
}

/// What the person may be offered for a folder in this standing.
///
/// Decided here, from the one table [`Standing::refusal`] holds, so a
/// window drawing the choice and the write enforcing it cannot come
/// apart: a standing added later reaches both through this.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum Confirm {
    /// The move may not go ahead: the folder is explained and nothing is
    /// offered.
    None,
    /// It may, on the ordinary confirmation.
    Reconnect,
    /// It may only as the choice to join two entries into one.
    Consolidate,
}

/// One proposed reconnection: the entry it replaces, the folder it would
/// point at, what stands there, and what may be offered for it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct Relocation {
    /// The registry entry being replaced, in the spelling the registry
    /// stores it under.
    pub from: PathBuf,
    /// The folder picked, canonical where it resolved (invariant 17) and
    /// as it was given where nothing is there to resolve.
    pub to: PathBuf,
    pub standing: Standing,
    pub confirm: Confirm,
}

impl Relocation {
    /// Asked of the refusal table itself rather than of the standing's
    /// name: what a person may press is exactly what the write accepts.
    fn confirm_for(standing: &Standing, to: &Path) -> Confirm {
        match (
            standing.refusal(to, false).is_none(),
            standing.refusal(to, true).is_none(),
        ) {
            (true, _) => Confirm::Reconnect,
            (false, true) => Confirm::Consolidate,
            (false, false) => Confirm::None,
        }
    }
}

/// What the person is agreeing to, without doing any of it.
///
/// Reads the registry and the destination and nothing else: a look at a
/// folder somebody typed or picked must not be able to change anything.
pub fn inspect(env: &Env, from: &Path, to: &Path) -> Result<Relocation> {
    let settings = super::load(env)?;
    let from = recorded_entry(&settings, from)?;
    let Some(to) = reachable(to) else {
        let standing = unreachable_standing(to);
        let confirm = Relocation::confirm_for(&standing, to);
        return Ok(Relocation {
            from,
            to: to.to_path_buf(),
            standing,
            confirm,
        });
    };
    let standing = standing_at(env, &settings, &from, &to);
    let confirm = Relocation::confirm_for(&standing, &to);
    Ok(Relocation {
        from,
        to,
        standing,
        confirm,
    })
}

/// Point one registry entry at the folder its project moved to.
///
/// One targeted settings mutation: the entry is replaced, the machine-local
/// preferences recorded against the old folder come with it, and every
/// other entry and setting in the file is left exactly as it was. Neither
/// folder is written to, moved or removed; the destination is read, since
/// [`inspect`] opens it and reads the record it holds.
///
/// `consolidate` is the person's choice to join this entry with one the
/// destination already has. Without it a destination that is already
/// registered is refused, so no answer that was never given can turn two
/// projects into one.
pub fn relocate_project(
    env: &Env,
    from: &Path,
    to: &Path,
    consolidate: bool,
) -> Result<(Relocation, AppSettings, Base)> {
    let plan = inspect(env, from, to)?;
    if let Some(refusal) = plan.standing.refusal(&plan.to, consolidate) {
        return Err(refusal);
    }
    let (settings, base) = mutate(env, |settings| {
        // Judged again against the file being written rather than against
        // the copy `inspect` read: another window or another process can
        // register the destination in between, and joining two projects
        // is the one thing here that needs an answer nobody gave.
        if !settings.projects.contains(&plan.from) {
            return Err(CoreError::ProjectNotRegistered {
                path: plan.from.clone(),
            });
        }
        if !consolidate && settings.projects.contains(&plan.to) {
            return Err(CoreError::ProjectFolderRegistered {
                path: plan.to.clone(),
            });
        }
        // Both dropped and one put back, so a consolidation lands as one
        // entry rather than two spellings of the same folder.
        settings
            .projects
            .retain(|project| *project != plan.from && *project != plan.to);
        settings.projects.push(plan.to.clone());
        settings.projects.sort();
        carry_preferences(settings, &plan.from, &plan.to);
        Ok(())
    })?;
    Ok((plan, settings, base))
}

/// The destination in the one spelling everything else compares against,
/// or `None` where it is not a folder this machine can read.
fn reachable(to: &Path) -> Option<PathBuf> {
    let canonical = crate::paths::canonical(to).ok()?;
    crate::scan::missing_why(&canonical)
        .is_none()
        .then_some(canonical)
}

/// Why the folder could not be reached, in the words the system gave.
/// Asked of the path as it came in, since it never resolved.
fn unreachable_standing(to: &Path) -> Standing {
    let said = match crate::scan::missing_why(to) {
        Some(crate::scan::MissingWhy::Gone) => "no folder is there".to_owned(),
        Some(crate::scan::MissingWhy::NotAFolder) => "it is not a folder".to_owned(),
        Some(crate::scan::MissingWhy::Unreadable { said }) => said,
        // The path resolves and is a folder, so what failed is the
        // resolution itself — a link that points nowhere, a component the
        // account may not traverse. The system's own words for it come
        // from asking again the one way that failed.
        None => match crate::paths::canonical(to) {
            Ok(_) => "it could not be resolved".to_owned(),
            Err(e) => e.to_string(),
        },
    };
    Standing::FolderMissing { said }
}

/// What the destination turns out to be, judged in precedence order.
///
/// Paths compare by spelling. A registry entry and a record's root are
/// both written canonical (invariant 17), so one spelling is the only one
/// either can be in, and a comparison that resolved them again would be a
/// second answer to a question already settled.
fn standing_at(env: &Env, settings: &AppSettings, from: &Path, to: &Path) -> Standing {
    let record = crate::lock::stated_root(&crate::lock::lock_path(
        env,
        &Scope::Project {
            root: to.to_path_buf(),
        },
    ));
    match record {
        Err(e) => Standing::RecordUnreadable {
            said: e.to_string(),
        },
        Ok(Some(root)) if root != from && root != to => Standing::RecordElsewhere { root },
        // Asked after the record, not before it: the recorded path
        // existing is not proof it is still the project, so the folder the
        // entry already names can be the one holding another project's
        // record or one nothing can read. Answered first, that folder
        // would be sent away with "it already points here" and the
        // mismatch never said.
        _ if to == from => Standing::Unchanged,
        Ok(_) if settings.projects.contains(&to.to_path_buf()) => Standing::Registered,
        Ok(None) => Standing::NoRecord,
        Ok(Some(root)) if root == from => Standing::Moved,
        Ok(Some(_)) => Standing::Settled,
    }
}

/// The machine-local preferences recorded against the folder being left,
/// moved onto the one it is now at: which packages have their updates
/// turned off there. They are the person's answers about this project, and
/// a project that moved is the same project.
///
/// A consolidation can bring an answer the destination already holds, so
/// the list keeps the first of each: a preference is a fact about a
/// package at a place, and the same fact twice is one row and a duplicate.
fn carry_preferences(settings: &mut AppSettings, from: &Path, to: &Path) {
    let leaving = scope_key(&Scope::Project {
        root: from.to_path_buf(),
    });
    let arriving = scope_key(&Scope::Project {
        root: to.to_path_buf(),
    });
    for ignored in &mut settings.ignored_updates {
        if ignored.scope == leaving {
            ignored.scope.clone_from(&arriving);
        }
    }
    let mut kept: Vec<IgnoredUpdate> = Vec::new();
    for ignored in std::mem::take(&mut settings.ignored_updates) {
        if !kept.contains(&ignored) {
            kept.push(ignored);
        }
    }
    settings.ignored_updates = kept;
}

#[cfg(test)]
mod tests;
