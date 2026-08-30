//! The consumer's `kendex.settings.toml`, as a plan writes it.
//!
//! Split from the rest of a scope's writes because what goes in this file
//! is decided by a different question. The manifest and the lock are
//! kendex's own records and every pass rewrites them; this one is the
//! consumer's, tracked in their repository, and a pass may put a line in
//! it only when the template it comes from is arriving or a save names the
//! key. What the seeding rule IS lives in [`crate::settings_seed`]; this
//! is where a scope asks it.

use crate::apply::{Op, PlannedOp, Pre};
use crate::error::Result;
use crate::lock::Lock;
use crate::model::{HarnessId, ItemKind, Scope};

use super::desired::DesiredState;
use super::{DriftRow, DriftState};

/// The row a plan carries for a settings file it cannot write.
///
/// Two shapes reach here and they end the same way: a path that is not a
/// regular file, and a document declaring env as an array of tables.
/// Neither is a place a setting can go, so seeding says so and leaves the
/// file alone — while an edit aimed at that same file refuses outright,
/// because the person asked for exactly it.
fn cannot_write(scope: &Scope, file: String, detail: String) -> DriftRow {
    DriftRow {
        kind: ItemKind::Skill,
        name: file,
        harness: HarnessId::Claude,
        scope: scope.clone(),
        state: DriftState::Conflict,
        detail,
        cause: None,
        compared: None,
        also_in_the_way: Vec::new(),
    }
}

/// What this pass writes into the project's kendex.settings.toml. A skill
/// arriving here writes the keys its template marks `# required`, and a
/// save writes the keys it names; a key the file already assigns anywhere
/// is never touched, and a skill the lock already carries writes nothing at
/// all. Seeded comment blocks whose template improved are refreshed while
/// provably unedited, gated by the lock's per-key ledger, which this plan
/// carries forward on `new_lock`.
///
/// A person's own edits are the third thing that reaches this file, and
/// they compose here rather than following as a second write: a manifest
/// save re-plans the scope and may seed or refresh this same file, and a
/// second write would bind to bytes the first one replaced. Seeds,
/// refreshes and edits become one `WriteFile` with one precondition, and
/// the ledger they all move rides out on the one lock this pass writes.
///
/// The notes go out before any of it: a shared key several packages give
/// different defaults is worth saying whether or not this pass has a write
/// to plan for it.
pub(super) fn plan_settings_seed(
    scope: &Scope,
    state: &DesiredState,
    options: &crate::engine::PlanOptions,
    lock: &Lock,
    new_lock: &mut crate::lock::Lock,
    ops: &mut Vec<PlannedOp>,
) -> Result<(Vec<String>, Vec<DriftRow>)> {
    let draft = options.settings_draft.as_ref();
    let edits = draft.map_or(&[][..], |draft| draft.edits.as_slice());
    let Scope::Project { root } = scope else {
        // Nothing global ships settings, so an edit here names a key no
        // template at this place declares — which is what it is refused
        // for, in the same words a project would refuse it.
        if let Some(edit) = edits.first() {
            return Err(crate::settings_file::SettingsRefusal::Undeclared {
                skill: edit.skill.clone(),
                key: edit.key.clone(),
            }
            .into());
        }
        return Ok((Vec::new(), Vec::new()));
    };
    if state.settings_env.is_empty() && edits.is_empty() {
        return Ok((Vec::new(), Vec::new()));
    }
    let notes = crate::settings_seed::seed_notes(&state.settings_env);
    let path = crate::settings_seed::settings_file_path(root);
    let file = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| crate::settings_seed::SETTINGS_FILE.to_owned());
    if path.is_symlink() || (path.exists() && !path.is_file()) {
        // Seeding reports this and carries on with the rest of the scope.
        // An edit cannot: the person asked for exactly this file.
        if !edits.is_empty() {
            return Err(crate::settings_file::SettingsRefusal::NotRegularFile { path }.into());
        }
        let row = cannot_write(
            scope,
            file,
            format!("{} is not a regular file", path.display()),
        );
        return Ok((notes, vec![row]));
    }
    let current = crate::fs::read_if_exists(&path)?;
    // A file that already declares env — as an array of tables, or in a
    // top-level assignment — has nowhere a setting can go, and writing
    // around it would leave a document that does not load. Said the way
    // the non-regular file is said: the plan reports it, and an edit
    // aimed at it refuses outright.
    if let Some(env) = current
        .as_deref()
        .and_then(crate::settings_seed::env_blocked)
    {
        if !edits.is_empty() {
            return Err(crate::settings_file::SettingsRefusal::EnvNotSeedable { path, env }.into());
        }
        let problem = format!(
            "{} {}, so no setting can be seeded",
            path.display(),
            env.problem()
        );
        return Ok((notes, vec![cannot_write(scope, file, problem)]));
    }
    let settled = settle(current.as_deref(), state, lock, draft, &path, new_lock)?;
    // Nothing to write when the finished text is what the file already
    // holds — and, where there was no file, when there is nothing to make.
    match &current {
        Some(original) if *original == settled.text => return Ok((notes, Vec::new())),
        None if settled.text.is_empty() => return Ok((notes, Vec::new())),
        _ => {}
    }
    let Settled {
        text,
        added,
        updated,
        edited,
    } = settled;
    let mut said = Vec::new();
    if !added.is_empty() {
        said.push(format!("seed {}", added.join(", ")));
    }
    if !updated.is_empty() {
        said.push(format!("refresh the comments on {}", updated.join(", ")));
    }
    if !edited.is_empty() {
        said.push(format!("set {}", edited.join(", ")));
    }
    ops.push(PlannedOp {
        description: format!("Update {file} ({})", said.join("; ")).into(),
        op: Op::WriteFile {
            // Bound to the bytes AND to their being a plain file. This
            // path refuses a symlinked settings file above, and a check
            // before a write is a race: swapped for a link afterwards, a
            // following precondition passes on the target's bytes and the
            // write lands outside the project. The refusal travels with
            // the operation instead. An edited copy binds to the file it
            // was read from, the way the manifest's does, so a writer
            // landing after the caller's own check is refused too.
            pre: match draft {
                Some(draft) => draft.base.plain_pre(),
                None => Pre::plain_observed(&path)?,
            },
            path,
            bytes: text.into_bytes(),
        },
    });
    Ok((notes, Vec::new()))
}

/// What the file becomes, and what moved to get there.
struct Settled {
    text: String,
    /// Keys this pass inserted, in the order they were written.
    added: Vec<String>,
    /// Keys whose seeded comment block was rewritten to its template's.
    updated: Vec<String>,
    /// Keys whose value this pass changed.
    edited: Vec<String>,
}

/// Seed, refresh and edit, in that order, into one finished text.
///
/// The order is the point. Edits land on the seeded text and never on the
/// file as it was: a key this pass just inserted is one the same pass can
/// then set, and the two are one write. The ledger's seed records move
/// here too, because what was written and what is recorded are one answer
/// and asking them apart is how they come to disagree.
fn settle(
    current: Option<&str>,
    state: &DesiredState,
    lock: &Lock,
    draft: Option<&crate::settings_file::SettingsDraft>,
    path: &std::path::Path,
    new_lock: &mut crate::lock::Lock,
) -> Result<Settled> {
    let edits = draft.map_or(&[][..], |draft| draft.edits.as_slice());
    // What this pass may put in the file: a template's required keys where
    // its skill is arriving, plus the keys a save names — a value has to
    // have an assignment to land on, and most keys never get one from an
    // install at all.
    let seeding = crate::settings_seed::Seeding::for_pass(
        &state.settings_env,
        &crate::lock::skill_names(lock),
        edits.iter().map(|edit| edit.key.clone()),
    );
    let (seeded, added, updated) = match current {
        None => match crate::settings_seed::merge(None, &state.settings_env, &seeding) {
            Some((text, added)) => (text, added, Vec::new()),
            None => (String::new(), Vec::new(), Vec::new()),
        },
        Some(original) => {
            let (refreshed, updated) = crate::settings_seed::refresh_comments(
                original,
                &state.settings_env,
                &mut new_lock.settings_seeds,
            );
            match crate::settings_seed::merge(Some(&refreshed), &state.settings_env, &seeding) {
                Some((text, added)) => (text, added, updated),
                None => (refreshed, Vec::new(), updated),
            }
        }
    };
    let (text, edited) =
        crate::settings_file::apply_edits(&seeded, edits, &state.settings_env, path)?;
    crate::settings_seed::record_seeds(
        &mut new_lock.settings_seeds,
        &state.settings_env,
        &added,
        &seeding,
    );
    Ok(Settled {
        text,
        added,
        updated,
        edited,
    })
}
