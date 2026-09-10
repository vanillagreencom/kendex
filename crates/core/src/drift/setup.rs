//! What one scope's package checks are about to write, read from the plan
//! that would write them.
//!
//! The surface offering to switch the checks on has to say which files it
//! changes and which tools it registers with, before anything is written.
//! Both answers come from the planner here — the same derivation the
//! install itself runs — so a preview can never name a file the install
//! skips or miss one it writes.

use std::collections::BTreeSet;
use std::path::{Path, PathBuf};

use serde::{Deserialize, Serialize};
use specta::Type;

use crate::engine::desired::Artifact;
use crate::env::Env;
use crate::error::Result;
use crate::lock::{Lock, LockFile};
use crate::manifest::ManifestFile;
use crate::model::{HarnessId, ItemKind, Scope};

use super::hook::{HOOK_NAME, HOOK_SCRIPT};

/// What one file the setup writes is for. The reader gets a role rather
/// than a path to interpret: `.claude/settings.json` says nothing about
/// why a session-start check needs it.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum FileRole {
    /// The script a session start runs.
    CheckScript,
    /// A tool's own configuration, which is what makes it run the script.
    StartupRegistration,
    /// The project's kendex.toml, where the check is declared like any
    /// other installed package.
    Declaration,
    /// kendex's record of what it installed here.
    InstallRecord,
}

/// Whether the file is there already. Read from disk at preview time, so a
/// project that has had the checks before is not told they are all new.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum FileChange {
    Add,
    Change,
}

/// Why a file has no preview beside it. A reason rather than silence: a
/// list where some rows open and others do not is a list the reader
/// cannot trust.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum NoPreview {
    /// One entry goes into a file the tool shares with the person's own
    /// settings. The rest of that file is theirs and is left alone, so
    /// there is no whole-file content to show ahead of the write.
    SharedFile,
    /// Written from what the apply did, so its content does not exist
    /// until the apply has run.
    Generated,
}

/// One file the setup writes.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct PlannedFile {
    /// Relative to the project root, `/`-spelled.
    pub path: String,
    pub change: FileChange,
    pub role: FileRole,
    /// The tool this file belongs to, where it belongs to one.
    pub harness: Option<HarnessId>,
    /// The bytes the write puts there, where kendex holds them before
    /// writing. `None` with a reason in `no_preview`; never both empty.
    pub preview: Option<String>,
    pub no_preview: Option<NoPreview>,
}

/// What switching a scope's package checks on would do.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct SetupPlan {
    /// The tools this installation registers the check in, in the order
    /// the declaration names them.
    pub harnesses: Vec<HarnessId>,
    pub files: Vec<PlannedFile>,
    /// Changes this project already has waiting that switching the checks
    /// on does not ask for. While any stand, the action writes the script
    /// and the declaration and the registration waits with them: a yes to
    /// the checks is not a yes to unrelated work.
    pub other_pending: u32,
    /// Positions in this project that nothing can settle on its own —
    /// what an apply of those pending changes would refuse at, said as
    /// the audit says it. Empty is the ordinary case.
    pub conflicts: Vec<String>,
}

/// Read what switching the checks on at this scope would write.
///
/// Refuses a registered project whose folder is not there, like the
/// install itself: a preview that answered would be a dialog offering to
/// rebuild a folder the person moved.
pub fn setup_plan(env: &Env, scope: &Scope) -> Result<SetupPlan> {
    let scope = scope.canonical();
    if let Some(check) = super::hook::folder_check(&scope) {
        check.check()?;
    }
    let root = project_root(&scope);
    let mut files = vec![
        planned(
            &super::hook::script_path(env, &scope),
            root,
            FileRole::CheckScript,
            None,
            Some(HOOK_SCRIPT.to_owned()),
        ),
        planned(
            &crate::manifest::manifest_path(env, &scope),
            root,
            FileRole::Declaration,
            None,
            None,
        ),
    ];

    // Where the script lands in each tool, and which of that tool's own
    // files registers it — asked of the renderer that will place it, so
    // the list cannot name a destination the render does not use. Read
    // without writing anything: the script's bytes are this binary's, so
    // the placement does not need the install to have happened.
    let script: crate::hook::HookSpec = crate::hook::parse_hook(HOOK_SCRIPT)
        .map_err(|problem| crate::error::CoreError::CheckScriptUnreadable { problem })?
        .into();
    let mut harnesses = Vec::new();
    let mut notes = crate::engine::desired::DesiredState::default();
    for harness in super::hook::target_harnesses(&scope) {
        let Some(artifact) = crate::engine::desired_kinds::restated_hook_artifact(
            env, &scope, HOOK_NAME, &script, true, harness, &mut notes,
        ) else {
            // The tool never fires this event, so the install registers
            // nothing there. Left off both lists rather than named as a
            // target with no file: the card reads this list to say which
            // tools run the check.
            continue;
        };
        harnesses.push(harness);
        // Every position the rendering occupies for this tool, whichever
        // shape the renderer gives it — a registration today, and an
        // exhaustive match rather than one arm so a renderer that changes
        // shape cannot quietly drop rows out of the list.
        let places: Vec<(&PathBuf, Option<String>)> = match &artifact {
            Artifact::Registration { script, edits } => script
                .iter()
                .map(|(path, bytes)| (path, String::from_utf8(bytes.clone()).ok()))
                .chain(edits.iter().map(|(path, _)| (path, None)))
                .collect(),
            Artifact::File { path, bytes } => {
                vec![(path, String::from_utf8(bytes.clone()).ok())]
            }
            Artifact::Tree {
                canonical, link, ..
            } => std::iter::once(canonical)
                .chain(link.iter())
                .map(|path| (path, None))
                .collect(),
        };
        for (path, preview) in places {
            files.push(planned(
                path,
                root,
                FileRole::StartupRegistration,
                Some(harness),
                preview,
            ));
        }
    }
    files.push(planned(
        &crate::lock::lock_path(env, &scope),
        root,
        FileRole::InstallRecord,
        None,
        None,
    ));
    dedupe(&mut files);

    let unrelated = pending_without_checks(env, &scope)?;
    Ok(SetupPlan {
        harnesses,
        files,
        // A count of rows a person reads, not an index: saturating rather
        // than wrapping keeps a nonsense count from reading as none.
        other_pending: u32::try_from(unrelated.plan.ops.len()).unwrap_or(u32::MAX),
        conflicts: conflicts(&unrelated),
    })
}

/// Everything waiting in this scope that the checks did not ask for: the
/// scope planned with the check's declaration taken out, so every op left
/// is unrelated by construction.
///
/// One judge for the count the confirmation shows and the decision the
/// install makes about whether it may render. Subtracting the check's own
/// positions from the whole-scope plan would not do: a tool's settings
/// file holds the check's registration and the person's other pending
/// hooks in one document, and a position cannot say which of them a write
/// there is for.
///
/// The plan that comes back is what the person still has waiting, not
/// what an apply would run: kendex's own housekeeping is taken out of it.
pub fn pending_without_checks(env: &Env, scope: &Scope) -> Result<crate::engine::EngineReport> {
    let scope = scope.canonical();
    // The manifest as it sits, never a seeded one. Seeding a kendex.toml
    // for a scope that has none, and the bookkeeping the planner then
    // brings about around it, is what enabling the checks does here — not
    // work the person already had. Counting it turned every freshly
    // registered project into a partial setup.
    let file = crate::manifest::load(&crate::manifest::manifest_path(env, &scope))?;
    let ManifestFile::Current(mut declared) = file else {
        // Nothing is declared here, so nothing waits that the checks did
        // not ask for. Answered through the ordinary whole-scope read, so
        // this and an apply cannot disagree about such a scope.
        return crate::engine::plan_apply(env, &scope, &crate::engine::PlanOptions::default());
    };
    declared.hooks.remove(HOOK_NAME);
    let lock = match crate::lock::load_file(&crate::lock::lock_path(env, &scope))? {
        LockFile::Current(lock) => lock,
        LockFile::Absent => Lock {
            version: crate::lock::LOCK_VERSION,
            ..Lock::default()
        },
    };
    let mut report = crate::engine::plan_scope(
        env,
        &scope,
        &declared,
        &lock,
        &crate::engine::PlanOptions::default(),
    )?;
    // Kendex's own housekeeping is not the person's waiting work either.
    // The ignore line that keeps the install ledger out of the repository
    // is wanted because kendex manages this project at all, and it is the
    // install the person is authorising that first writes that ledger — so
    // counting it told them a project they had declared nothing in had a
    // change of their own waiting, and held the render back over it.
    // Asked of the one function that adds it.
    let housekeeping = crate::engine::posture::planned(&scope)?;
    report.plan.ops.retain(|op| !housekeeping.contains(op));
    Ok(report)
}

/// Whether every tool the check runs in has its registration in place.
///
/// The one answer to "are the checks running here", asked after a write by
/// the surface that has to report what it achieved: an installer's return
/// value says a plan ran, never that every promised target is live.
///
/// Each target must show positive evidence — a record of the install and
/// no drift row against it — because the states that matter raise no row.
/// An orphaned or unmanaged row is not a target waiting on this install:
/// neither says a declared registration is missing.
pub fn every_target_registered(
    env: &Env,
    scope: &Scope,
    report: &crate::engine::EngineReport,
) -> Result<bool> {
    let scope = scope.canonical();
    // A pass that could not derive everything it was asked for has not
    // looked at every target, and a target it never reached raises no row.
    if report.declaration_status == crate::engine::DeclarationStatus::Incomplete {
        return Ok(false);
    }
    let targets = super::hook::target_harnesses(&scope);
    if targets.is_empty() {
        return Ok(false);
    }
    let LockFile::Current(lock) = crate::lock::load_file(&crate::lock::lock_path(env, &scope))?
    else {
        return Ok(false);
    };
    Ok(targets.into_iter().all(|harness| {
        // Positive evidence, both halves. The record says the install put
        // it there; the drift rows say nothing has happened to it since.
        // Absence of a complaint alone is not evidence: a target the pass
        // never reached, and one a narrower declaration never asked for,
        // both raise no row at all.
        let recorded = lock.entries.values().any(|entry| {
            entry.kind == ItemKind::Hook && entry.name == HOOK_NAME && entry.harness == harness
        });
        let complained = report.drift.iter().any(|row| {
            row.kind == ItemKind::Hook
                && row.name == HOOK_NAME
                && row.harness == harness
                && !matches!(
                    row.state,
                    crate::engine::DriftState::Orphaned | crate::engine::DriftState::Unmanaged
                )
        });
        recorded && !complained
    }))
}

/// Positions in a scope that nothing can settle on its own, said as the
/// audit says them: the reader gets the position rather than a verdict
/// about it.
pub fn conflicts(report: &crate::engine::EngineReport) -> Vec<String> {
    report
        .drift
        .iter()
        .filter(|row| row.state == crate::engine::DriftState::Conflict)
        .map(|row| row.detail.clone())
        .collect()
}

/// The root the listed paths are shown against — the project's own, or
/// nothing at global scope, where each tool owns a directory of its own
/// and there is no one root to be relative to.
fn project_root(scope: &Scope) -> Option<&Path> {
    match scope {
        Scope::Global => None,
        Scope::Project { root } => Some(root.as_path()),
    }
}

fn planned(
    path: &Path,
    root: Option<&Path>,
    role: FileRole,
    harness: Option<HarnessId>,
    preview: Option<String>,
) -> PlannedFile {
    let no_preview = match (&preview, role) {
        (Some(_), _) => None,
        (None, FileRole::StartupRegistration) => Some(NoPreview::SharedFile),
        (None, _) => Some(NoPreview::Generated),
    };
    PlannedFile {
        path: shown(path, root),
        change: match path.exists() {
            true => FileChange::Change,
            false => FileChange::Add,
        },
        role,
        harness,
        preview,
        no_preview,
    }
}

/// One position, said the way the reader knows it: relative to the
/// project root where it is under one, absolute where it is not — a tool
/// whose global configuration a project install still edits is outside
/// the folder, and a bare relative path would put it inside.
fn shown(path: &Path, root: Option<&Path>) -> String {
    let relative = root.and_then(|root| path.strip_prefix(root).ok());
    let said = relative.unwrap_or(path).display().to_string();
    said.replace(std::path::MAIN_SEPARATOR, "/")
}

/// One row per position. Two harnesses can register in one shared file,
/// and the same file can be a registration for one and the declaration
/// for another; the first row keeps the position, so the roles stay in
/// the order the list was built in.
fn dedupe(files: &mut Vec<PlannedFile>) {
    let mut seen: BTreeSet<String> = BTreeSet::new();
    files.retain(|file| seen.insert(file.path.clone()));
}
