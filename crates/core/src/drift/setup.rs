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
    /// kendex's own bookkeeping in the repository: the ignore rule that
    /// keeps its records out of the person's commits, and the inventory
    /// of what it generated. Written by this action, because this action
    /// is what first makes this a project kendex manages.
    ///
    /// Not the person's pending work — the count says so — and still a
    /// file this press writes. Both are true at once, which is why these
    /// rows are read off the plan rather than described here.
    RepositoryFile,
}

/// What this action does to the file, read from the operations it will
/// run rather than from what happens to sit on disk. A person pressing a
/// button is told what the press does; a file already as the setup needs
/// it, and one the press deliberately leaves for later, are not changes
/// the press makes.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize, Type)]
#[serde(rename_all = "kebab-case")]
pub enum FileChange {
    /// Written by this action; nothing is there now.
    Add,
    /// Written by this action over something already there.
    Change,
    /// Already what the setup needs. This action writes nothing here.
    Unchanged,
    /// Part of the setup, and not written by this action: the render
    /// waits with the changes this project already had.
    Later,
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
    /// Positions in this project that nothing can settle on its own and
    /// that the check does not sit at. They hold up their own items and
    /// nothing else. Empty is the ordinary case.
    pub conflicts: Vec<String>,
    /// Unsettled positions at the check's own destinations. These do stop
    /// its registration, which is what tells them from `conflicts` — a
    /// surface saying the same thing about both would be false about one
    /// of them.
    pub blocked: Vec<String>,
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
    // A declaration under the check's name that came from somewhere else
    // is refused before a single row is built: disclosing this binary's
    // script for a declaration the render would take from a marketplace
    // is the one thing this preview must never do.
    super::hook::refuse_foreign(env, &scope)?;
    let root = project_root(&scope);

    // What this action will actually run, and what it will hold back.
    //
    // The declaration plan is the ops that land now — it omits the script
    // write when the script already matches, so a re-enable does not claim
    // a file it never touches. The render plan is the scope as it stands
    // with the check declared: its ops are the registrations and the
    // record, and whether they run now is the same judgement the install
    // makes, that nothing unrelated is waiting.
    let unrelated = pending_without_checks(env, &scope)?;
    let with_checks = plan_with_checks(env, &scope)?;
    let renders_now = unrelated.plan.is_empty();
    let script = super::hook::script_path(env, &scope);
    let declaration = crate::manifest::manifest_path(env, &scope);
    let mut writes = Writes {
        // The declaration step runs whatever else is waiting, and its plan
        // is the judge of what it writes: it omits the script when the
        // script already matches, so a re-enable claims no file it does
        // not touch.
        now: super::hook::install_plan(env, &scope)?
            .ops
            .iter()
            .flat_map(|planned| planned.op.touched())
            .collect(),
        later: BTreeSet::new(),
    };

    // Everything the render puts in place, the tools it reaches, and the
    // record it writes at the end.
    let (harnesses, mut rendered) = rendered_into(env, &scope)?;
    rendered.push(Rendered {
        path: crate::lock::lock_path(env, &scope),
        role: FileRole::InstallRecord,
        harness: None,
        preview: None,
    });
    // Everything else this action puts in the repository, read off the
    // plan that has the check declared rather than named here: the ignore
    // rule that keeps the install record out of the person's commits, and
    // the inventory of generated paths. Each is decided by the pass that
    // writes it — the ignore rule by `engine::posture`, the inventory by
    // the render's own desired state — so neither can be asked for on its
    // own, and a second notion of what kendex owes a repository is what
    // reading the plan avoids.
    //
    // The person's own waiting work is taken out through the same judge
    // the count uses, so a held press lists what the check's setup reaches
    // and never somebody else's files. With nothing waiting that plan is
    // empty and nothing is subtracted.
    // Every position the render actually acts on. One reading of the
    // plan, used both to decide which destinations this press writes and
    // to gather what else it puts in the repository.
    let rendering: BTreeSet<PathBuf> = with_checks
        .plan
        .ops
        .iter()
        .flat_map(|planned| planned.op.touched())
        .collect();
    let theirs: BTreeSet<PathBuf> = unrelated
        .plan
        .ops
        .iter()
        .flat_map(|planned| planned.op.touched())
        .collect();
    let already: BTreeSet<PathBuf> = rendered
        .iter()
        .map(|row| row.path.clone())
        .chain([script.clone(), declaration.clone()])
        .collect();
    for path in &rendering {
        if theirs.contains(path) || already.contains(path) {
            continue;
        }
        rendered.push(Rendered {
            path: path.clone(),
            role: FileRole::RepositoryFile,
            harness: None,
            preview: None,
        });
    }

    // The render's own positions. Whether they are written by this press
    // is the same judgement the install makes — nothing unrelated waiting
    // — so a held press names them without claiming to write them.
    //
    // Where it does render, the plan is still the judge of which of them
    // it writes: a position the render refused carries no op, and calling
    // it a change would contradict the very list naming it as one kendex
    // will not write over. Asked of the plan's own ops rather than of a
    // second idea here of what it does, so the row and the refusal cannot
    // disagree.
    let destinations: BTreeSet<PathBuf> = rendered.iter().map(|row| row.path.clone()).collect();
    match renders_now {
        true => writes
            .now
            .extend(destinations.intersection(&rendering).cloned()),
        false => writes.later = destinations,
    }

    let mut files = vec![
        planned(
            &script,
            root,
            FileRole::CheckScript,
            None,
            Some(HOOK_SCRIPT.to_owned()),
            &writes,
        ),
        planned(
            &declaration,
            root,
            FileRole::Declaration,
            None,
            None,
            &writes,
        ),
    ];
    for row in rendered {
        files.push(planned(
            &row.path,
            root,
            row.role,
            row.harness,
            row.preview,
            &writes,
        ));
    }
    dedupe(&mut files);

    Ok(SetupPlan {
        harnesses,
        files,
        // A count of rows a person reads, not an index: saturating rather
        // than wrapping keeps a nonsense count from reading as none.
        other_pending: u32::try_from(unrelated.plan.ops.len()).unwrap_or(u32::MAX),
        conflicts: conflicts(&unrelated),
        // Read from the plan that has the check declared, because the one
        // that strips it cannot hold a row about the check's own
        // positions — which is exactly where a conflict stops the
        // registration rather than something else's.
        blocked: check_conflicts(&with_checks),
    })
}

/// One position the render occupies, and what the reader is told it is.
struct Rendered {
    path: PathBuf,
    role: FileRole,
    harness: Option<HarnessId>,
    preview: Option<String>,
}

/// Where the render puts the check in each tool, and which of that tool's
/// own files reaches it — asked of the renderer that will place it, so no
/// list here can name a destination the render does not use. Read without
/// writing anything: the script's bytes are this binary's, so the
/// placement does not need the install to have happened.
///
/// The tools answered are the ones the render reaches. A tool that never
/// fires the event registers nothing, and is left off rather than named
/// as a target with no file: the card reads these tools to say where the
/// check runs.
fn rendered_into(env: &Env, scope: &Scope) -> Result<(Vec<HarnessId>, Vec<Rendered>)> {
    let script: crate::hook::HookSpec = crate::hook::parse_hook(HOOK_SCRIPT)
        .map_err(|problem| crate::error::CoreError::CheckScriptUnreadable { problem })?
        .into();
    let mut harnesses = Vec::new();
    let mut rendered = Vec::new();
    let mut notes = crate::engine::desired::DesiredState::default();
    for harness in super::hook::target_harnesses(scope) {
        let Some(artifact) = crate::engine::desired_kinds::restated_hook_artifact(
            env, scope, HOOK_NAME, &script, true, harness, &mut notes,
        ) else {
            continue;
        };
        harnesses.push(harness);
        for (path, role, preview) in places(&artifact) {
            rendered.push(Rendered {
                path: path.clone(),
                role,
                harness: Some(harness),
                preview,
            });
        }
    }
    Ok((harnesses, rendered))
}

/// Every position one tool's rendering occupies, whichever shape the
/// renderer gives it, and what each position is.
///
/// The split is the same in every shape: bytes kendex renders are the
/// script a session runs, and an entry or a link in the tool's own files
/// is what makes the tool reach it. A rendered script described as what
/// makes the tool run the script tells the reader the opposite of what it
/// is. An exhaustive match rather than one arm, so a renderer that changes
/// shape cannot quietly drop rows out of the list.
fn places(artifact: &Artifact) -> Vec<(&PathBuf, FileRole, Option<String>)> {
    match artifact {
        Artifact::Registration { script, edits } => script
            .iter()
            .map(|(path, bytes)| {
                (
                    path,
                    FileRole::CheckScript,
                    String::from_utf8(bytes.clone()).ok(),
                )
            })
            .chain(
                edits
                    .iter()
                    .map(|(path, _)| (path, FileRole::StartupRegistration, None)),
            )
            .collect(),
        Artifact::File { path, bytes } => vec![(
            path,
            FileRole::CheckScript,
            String::from_utf8(bytes.clone()).ok(),
        )],
        Artifact::Tree {
            canonical, link, ..
        } => std::iter::once((canonical, FileRole::CheckScript, None))
            .chain(
                link.iter()
                    .map(|path| (path, FileRole::StartupRegistration, None)),
            )
            .collect(),
    }
}

/// The scope planned with the check declared: what the render will write,
/// and what stands in its way at the check's own destinations.
fn plan_with_checks(env: &Env, scope: &Scope) -> Result<crate::engine::EngineReport> {
    let mut wanted = crate::engine::ops::manifest_for_mutation(env, scope)?;
    super::hook::declare(&mut wanted, scope);
    crate::engine::plan_scope(
        env,
        scope,
        &wanted,
        &loaded_lock(env, scope)?,
        &crate::engine::PlanOptions::default(),
    )
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
    // This strips the check's declaration to count what is left, so a
    // foreign declaration under that name would be taken out of somebody
    // else's count. Refused here too: the app asks this before it asks
    // anything else.
    super::hook::refuse_foreign(env, &scope)?;
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
    let lock = loaded_lock(env, &scope)?;
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
    // Nor is the inventory of what kendex renders here. It is written for
    // CI and never read back by a plan, so it is never a change of the
    // person's — and taking the check's declaration out above is itself
    // what makes this pass want to rewrite it without the check's paths.
    // Counting that told a project with nothing waiting that it had one
    // change waiting, and held the render back over an op this question
    // brought about.
    //
    // Which file that is belongs to the render's own bookkeeping, so it is
    // asked of the owner rather than named here.
    if let Some(root) = project_root(&scope) {
        let companions = crate::engine::generated_paths::companions(root);
        report
            .plan
            .ops
            .retain(|op| !op.op.touched().iter().any(|path| companions.contains(path)));
    }
    Ok(report)
}

/// Whether every tool the check runs in has its registration in place.
///
/// A bit for the caller that only needs one; [`targets_waiting`] keeps
/// which tools they are.
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
    Ok(targets_waiting(env, scope, report)?.is_empty())
}

/// The tools the check runs in that have no registration in place —
/// [`every_target_registered`] with the answer kept rather than folded to
/// a bit, for the surface that has to say which ones are waiting.
pub fn targets_waiting(
    env: &Env,
    scope: &Scope,
    report: &crate::engine::EngineReport,
) -> Result<Vec<HarnessId>> {
    let scope = scope.canonical();
    let targets = super::hook::target_harnesses(&scope);
    // A pass that could not derive everything it was asked for has not
    // looked at every target, and a target it never reached raises no row.
    if report.declaration_status == crate::engine::DeclarationStatus::Incomplete {
        return Ok(targets);
    }
    if targets.is_empty() {
        return Ok(Vec::new());
    }
    let LockFile::Current(lock) = crate::lock::load_file(&crate::lock::lock_path(env, &scope))?
    else {
        return Ok(targets);
    };
    Ok(targets
        .into_iter()
        .filter(|harness| {
            // Positive evidence, both halves. The record says the install put
            // it there; the drift rows say nothing has happened to it since.
            // Absence of a complaint alone is not evidence: a target the pass
            // never reached, and one a narrower declaration never asked for,
            // both raise no row at all.
            let recorded = lock.entries.values().any(|entry| {
                entry.kind == ItemKind::Hook && entry.name == HOOK_NAME && entry.harness == *harness
            });
            let complained = report.drift.iter().any(|row| {
                about_the_check(row)
                    && row.harness == *harness
                    && !matches!(
                        row.state,
                        crate::engine::DriftState::Orphaned | crate::engine::DriftState::Unmanaged
                    )
            });
            !recorded || complained
        })
        .collect())
}

/// The scope's lock, or an empty one where it has none.
fn loaded_lock(env: &Env, scope: &Scope) -> Result<Lock> {
    Ok(
        match crate::lock::load_file(&crate::lock::lock_path(env, scope))? {
            LockFile::Current(lock) => lock,
            LockFile::Absent => Lock {
                version: crate::lock::LOCK_VERSION,
                ..Lock::default()
            },
        },
    )
}

/// Whether a drift row is about the check itself. The one predicate the
/// two questions below are asked through, so neither can drift into a
/// second reading of what belongs to the check.
fn about_the_check(row: &crate::engine::DriftRow) -> bool {
    row.kind == ItemKind::Hook && row.name == HOOK_NAME
}

/// Positions nothing can settle that the check does not sit at, said as
/// the audit says them: the reader gets the position rather than a
/// verdict about it. These hold up their own items and nothing else.
pub fn conflicts(report: &crate::engine::EngineReport) -> Vec<String> {
    unsettled(report, |row| !about_the_check(row))
}

/// Positions nothing can settle at the check's own destinations. Read
/// from a report planned WITH the check declared — one that strips it
/// cannot carry a row about the check's positions at all, and reading
/// that one is what left an unreadable settings file out of the
/// confirmation.
pub fn check_conflicts(report: &crate::engine::EngineReport) -> Vec<String> {
    unsettled(report, about_the_check)
}

fn unsettled(
    report: &crate::engine::EngineReport,
    about: impl Fn(&crate::engine::DriftRow) -> bool,
) -> Vec<String> {
    report
        .drift
        .iter()
        .filter(|row| row.state == crate::engine::DriftState::Conflict && about(row))
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

/// What the ops of this invocation say about one position.
///
/// The whole judge of a row's status. `now` is every path the operations
/// this action runs will touch, and `later` every path the setup reaches
/// that this action leaves for the render it is holding back; a position
/// in neither is already what the setup needs. The disk is read only to
/// tell an add from a change, never to decide whether this action writes
/// at all — that is what the operations say.
struct Writes {
    now: BTreeSet<PathBuf>,
    later: BTreeSet<PathBuf>,
}

impl Writes {
    fn of(&self, path: &Path) -> FileChange {
        if self.now.contains(path) {
            return match path.exists() {
                true => FileChange::Change,
                false => FileChange::Add,
            };
        }
        match self.later.contains(path) {
            true => FileChange::Later,
            false => FileChange::Unchanged,
        }
    }
}

fn planned(
    path: &Path,
    root: Option<&Path>,
    role: FileRole,
    harness: Option<HarnessId>,
    preview: Option<String>,
    writes: &Writes,
) -> PlannedFile {
    let no_preview = match (&preview, role) {
        // One line into a file that is otherwise the person's own.
        (None, FileRole::RepositoryFile) => Some(NoPreview::SharedFile),
        (Some(_), _) => None,
        (None, FileRole::StartupRegistration) => Some(NoPreview::SharedFile),
        (None, _) => Some(NoPreview::Generated),
    };
    PlannedFile {
        path: shown(path, root),
        change: writes.of(path),
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
