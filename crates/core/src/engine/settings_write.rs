//! The consumer's `kendex.settings.toml`, as a plan writes it.
//!
//! Split from the rest of a scope's writes because what goes in this file
//! is decided by a different question. The manifest and the lock are
//! kendex's own records; this one is the
//! consumer's, tracked in their repository, and a pass puts a line in it
//! only for an operation `docs/authoring/settings.md` lists.
//! Arrival rides in on the plan's options, because the
//! only thing that arrives a skill is the `add` that declares it. What the
//! seeding rule lives in [`crate::settings_seed`]; compatibility lives in
//! `crate::source::config::agent_names`.

use crate::apply::{Op, PlannedOp, Pre};
use crate::error::Result;
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

/// What this pass writes into the project's kendex.settings.toml: the
/// keys [`crate::settings_seed::Seeding`] admits, and the legacy labels
/// the shared agent resolver replaces. Seeding never overwrites an
/// assigned key, and neither does a supplied value.
///
/// The keys edited compose here rather than following as a second write:
/// they are inserted by this same pass, so a second write would bind to
/// bytes the first one replaced. Inserts and edits become one `WriteFile`
/// under one precondition.
///
/// The notes ride out either way: a key several packages give different
/// defaults, and a required key this file still does not answer, are worth
/// saying whether or not this pass has a write to plan.
pub(super) fn plan_settings_seed(
    scope: &Scope,
    state: &mut DesiredState,
    options: &crate::engine::PlanOptions,
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
        if let Some(supplied) = options.supplied_settings.first() {
            return Err(crate::settings_file::SettingsRefusal::NotDeclaredHere {
                key: supplied.key.clone(),
            }
            .into());
        }
        return Ok((Vec::new(), Vec::new()));
    };
    let Declarations {
        declared,
        edits,
        supplied,
        mut notes,
    } = declarations(state, options, edits)?;
    // A file this pass cannot read is one that answers no key, which is
    // what the notes below are then told. Nothing is written there either
    // way, so the required keys are reported as unanswered, which is the
    // true thing to say about a file kendex cannot see into.
    let unread = crate::settings_seed::Answered::read(None, &declared);
    // And a pass that gives up writes nothing whatever it meant to write,
    // so the notes for one are built from a seeding that admits nothing.
    // Handed the pass's own, the notes speak for a write that is not going
    // to happen: `unanswered_notes` stays silent about every key seeding
    // would have answered, and a conflict note names an owner whose value
    // never lands. On an arrival that is the one pass a marked key would
    // ever have been written on, so it goes neither into the file nor into
    // a note.
    let giving_up = crate::settings_seed::Seeding::default();
    let path = crate::settings_seed::settings_file_path(root);
    let file = path
        .file_name()
        .map(|name| name.to_string_lossy().into_owned())
        .unwrap_or_else(|| crate::settings_seed::SETTINGS_FILE.to_owned());
    if path.is_symlink() || (path.exists() && !path.is_file()) {
        if declared.is_empty() && edits.is_empty() {
            return Ok((notes, Vec::new()));
        }
        // Seeding reports this and carries on with the rest of the scope.
        // An edit or a supplied value cannot: the person asked for exactly
        // this file.
        if !edits.is_empty() || !supplied.is_empty() {
            return Err(crate::settings_file::SettingsRefusal::NotRegularFile { path }.into());
        }
        let row = cannot_write(
            scope,
            file,
            format!("{} is not a regular file", path.display()),
        );
        notes.extend(crate::settings_seed::seed_notes(
            &declared, &unread, &giving_up,
        ));
        return Ok((notes, vec![row]));
    }
    let current = crate::fs::read_if_exists(&path)?;
    let compatible = current
        .as_deref()
        .map(|text| state.agent_names.settings(text, &path))
        .transpose()?;
    if declared.is_empty() && edits.is_empty() && compatible == current {
        return Ok((notes, Vec::new()));
    }
    // Where every declared key stands in the text this pass writes on,
    // which is the file after the label rename: the notes and the values
    // an install supplies are judged from that one reading. Both views at
    // once, because the questions take different ones: whether a write can
    // land on the name, and whether any script would read what is there.
    let answered = crate::settings_seed::Answered::read(compatible.as_deref(), &declared);
    // A file that already declares env — as an array of tables, or in a
    // top-level assignment — has nowhere a setting can go, and writing
    // around it would leave a document that does not load. Said the way
    // the non-regular file is said: the plan reports it, and an edit
    // aimed at it refuses outright.
    if let Some(env) = current
        .as_deref()
        .and_then(crate::settings_seed::env_blocked)
    {
        if !edits.is_empty() || !supplied.is_empty() {
            return Err(crate::settings_file::SettingsRefusal::EnvNotSeedable { path, env }.into());
        }
        let problem = format!(
            "{} {}, so no setting can be seeded",
            path.display(),
            env.problem()
        );
        notes.extend(crate::settings_seed::seed_notes(
            &declared, &answered, &giving_up,
        ));
        return Ok((notes, vec![cannot_write(scope, file, problem)]));
    }
    let (kept, said) = kept_values(&answered, &options.supplied_settings);
    notes.extend(said);
    let edits: Vec<_> = edits
        .into_iter()
        .chain(
            supplied
                .into_iter()
                .filter(|edit| !kept.contains(&edit.key)),
        )
        .collect();
    // What this pass may put in the file: a template's required keys where
    // its skill is arriving, plus the keys a save names or an install
    // supplies — a value has to have an assignment to land on, and most
    // keys never get one from an install at all.
    let seeding = crate::settings_seed::Seeding::new(
        options.arriving_skills.iter().cloned(),
        edits.iter().map(|edit| edit.key.clone()),
    );
    notes.extend(crate::settings_seed::seed_notes(
        &declared, &answered, &seeding,
    ));
    let settled = settle(compatible.as_deref(), &declared, &seeding, &edits, &path)?;
    // Nothing to write when the finished text is what the file already
    // holds — and, where there was no file, when there is nothing to make.
    match &current {
        Some(original) if *original == settled.text => return Ok((notes, Vec::new())),
        None if settled.text.is_empty() => return Ok((notes, Vec::new())),
        _ => {}
    }
    plan_settings_write(path, file, draft, settled, compatible != current, ops)?;
    Ok((notes, Vec::new()))
}

/// Bind the combined seed, edit and label rename to the original file bytes.
fn plan_settings_write(
    path: std::path::PathBuf,
    file: String,
    draft: Option<&crate::settings_file::SettingsDraft>,
    settled: Settled,
    renamed: bool,
    ops: &mut Vec<PlannedOp>,
) -> Result<()> {
    let Settled {
        text,
        added,
        edited,
    } = settled;
    let mut said = Vec::new();
    if renamed {
        said.push("rename legacy agent labels".to_owned());
    }
    if !added.is_empty() {
        said.push(format!("seed {}", added.join(", ")));
    }
    if !edited.is_empty() {
        said.push(format!("set {}", edited.join(", ")));
    }
    ops.push(PlannedOp {
        description: format!("Update {file} ({})", said.join("; ")).into(),
        op: Op::WriteFile {
            // An edited copy binds to the bytes it was read from, the way
            // the manifest's does, so a writer landing after the caller's
            // own check is refused too.
            pre: match draft {
                Some(draft) => Pre::from(&draft.base),
                None => Pre::observed(&path)?,
            },
            path,
            bytes: text.into_bytes(),
        },
    });
    Ok(())
}

/// What the file becomes, and what moved to get there.
struct Settled {
    text: String,
    /// Keys this pass inserted, in the order they were written.
    added: Vec<String>,
    /// Keys whose value this pass changed.
    edited: Vec<String>,
}

/// Seed and edit, in that order, into one finished text.
///
/// The order is the point. Edits land on the seeded text and never on the
/// file as it was: a key this pass just inserted is one the same pass can
/// then set, and the two are one write.
///
/// Template revisions never revisit an existing block. Agent-label
/// compatibility is applied to the input before this seed-and-edit pass.
fn settle(
    current: Option<&str>,
    declared: &[crate::settings_seed::SeededEnv],
    seeding: &crate::settings_seed::Seeding,
    edits: &[crate::settings_file::SettingsEdit],
    path: &std::path::Path,
) -> Result<Settled> {
    let (seeded, added) = match crate::settings_seed::merge(current, declared, seeding) {
        Some((text, added)) => (text, added),
        None => (current.unwrap_or_default().to_owned(), Vec::new()),
    };
    let (text, edited) = crate::settings_file::apply_edits(&seeded, edits, declared, path)?;
    Ok(Settled {
        text,
        added,
        edited,
    })
}

/// What [`declarations`] hands the pass: the keys it may write, the
/// edits a save asks for, the values an install supplies as edits of
/// their owning declaration, and the notes either way.
struct Declarations {
    declared: Vec<crate::settings_seed::SeededEnv>,
    edits: Vec<crate::settings_file::SettingsEdit>,
    supplied: Vec<crate::settings_file::SettingsEdit>,
    notes: Vec<String>,
}

/// What this pass may write, and what it may not.
///
/// A key one installed package declares a setting and another declares a
/// credential has no destination anything here can choose: writing it as
/// a setting could put a credential in a tracked file, and refusing it as
/// a secret would leave the package unable to read it. So it is seeded by
/// nothing, refused as an edit or a supplied value, and named in a note.
///
/// The private file a save names comes back as an edit of kendex's own
/// key, on kendex's own declaration, so recording the choice is the same
/// seed-and-set this file already does for every package key.
fn declarations(
    state: &DesiredState,
    options: &crate::engine::PlanOptions,
    edits: &[crate::settings_file::SettingsEdit],
) -> Result<Declarations> {
    let contested = crate::settings_secret::contested(&state.settings_templates);
    if let Some(against) = contested.iter().find(|against| {
        edits.iter().any(|edit| edit.key == against.key)
            || options
                .supplied_settings
                .iter()
                .any(|supplied| supplied.key == against.key)
    }) {
        return Err(crate::settings_secret::SecretRefusal::Sensitivity {
            contested: Box::new(against.clone()),
        }
        .into());
    }
    let mut declared: Vec<crate::settings_seed::SeededEnv> = state
        .settings_env
        .iter()
        .filter(|seeded| !contested.iter().any(|one| one.key == seeded.entry.key))
        .cloned()
        .collect();
    let mut edits = edits.to_vec();
    if let Some(file) = recorded_choice(options) {
        declared.push(crate::settings_secret::env_file_declaration());
        edits.push(crate::settings_file::SettingsEdit {
            skill: crate::settings_secret::KENDEX_OWNER.to_owned(),
            key: crate::settings_secret::ENV_FILE_KEY.to_owned(),
            value: crate::settings_file::SettingsEditValue::Set { value: file },
        });
    }
    let supplied = options
        .supplied_settings
        .iter()
        .map(|supplied| supplied_edit(&declared, supplied))
        .collect::<Result<_>>()?;
    let notes = contested
        .iter()
        .map(|against| against.problem.clone())
        .collect();
    Ok(Declarations {
        declared,
        edits,
        supplied,
        notes,
    })
}

/// The edit a supplied value becomes: bound to the first declaration of
/// its key in package-name order, the owner a save writes under too. Its
/// value is checked here, before the file is read, so a value the loaders
/// would refuse is refused whether or not the file keeps its own.
fn supplied_edit(
    declared: &[crate::settings_seed::SeededEnv],
    supplied: &crate::settings_file::SuppliedSetting,
) -> Result<crate::settings_file::SettingsEdit> {
    use crate::settings_file::SettingsRefusal;
    let owner = declared
        .iter()
        .find(|seeded| seeded.entry.key == supplied.key)
        .ok_or_else(|| SettingsRefusal::NotDeclaredHere {
            key: supplied.key.clone(),
        })?;
    crate::settings_file::check_value(&supplied.value).map_err(|problem| {
        SettingsRefusal::Value {
            key: supplied.key.clone(),
            problem,
        }
    })?;
    Ok(crate::settings_file::SettingsEdit {
        skill: owner.owner.clone(),
        key: supplied.key.clone(),
        value: crate::settings_file::SettingsEditValue::Set {
            value: supplied.value.clone(),
        },
    })
}

/// The supplied keys the file already assigns, which keep their value,
/// and one note for each whose value the supply would have changed. A key
/// assigned anywhere in the file is the consumer's, by the same file-wide
/// reading seeding takes; the note is owed where the value the loaders
/// read differs from the one supplied, or where they read none. Both
/// questions go to `answered`, the reading the notes take too.
fn kept_values(
    answered: &crate::settings_seed::Answered,
    supplied: &[crate::settings_file::SuppliedSetting],
) -> (Vec<String>, Vec<String>) {
    use crate::settings_file::Current;
    let mut kept = Vec::new();
    let mut notes = Vec::new();
    for one in supplied.iter().filter(|one| answered.occupies(&one.key)) {
        let same = match answered.of(&one.key) {
            Some(Current::Value { value, .. }) => *value == one.value,
            Some(Current::Absent | Current::Ambiguous { .. }) => false,
            None => {
                unreachable!("a supplied key is declared: supplied_edit refuses one that is not")
            }
        };
        if !same {
            notes.push(format!(
                "{} keeps the value kendex.settings.toml already assigns it; the value this install supplied was not written",
                one.key
            ));
        }
        kept.push(one.key.clone());
    }
    (kept, notes)
}

/// Both halves of what a save writes into a project's own configuration:
/// the tracked settings file, then the private file beside it. One entry
/// point because the order between them is not the caller's to choose —
/// naming a private file records the choice in the settings write, so
/// that write has to be planned first.
///
/// Everything a pass writes into the project's own files, in the order it
/// has to write them.
///
/// The git posture goes first. The one line it may add for this pass is
/// the `.gitignore` entry that keeps git off the private env file the
/// credential below is about to go into, and a plan runs in order: a line
/// planned after that write is a line planned after the window it exists
/// to close. Rolling both back on a refusal is not the same promise as
/// never having written an unprotected credential at all.
///
/// Then the tracked settings file, then the private file beside it.
/// Naming a private file records the choice in the settings write, so
/// that write is planned before the private one — and the destination is
/// resolved once, at the top, because all three steps read it.
pub(super) fn plan_project_files(
    scope: &Scope,
    state: &mut DesiredState,
    options: &crate::engine::PlanOptions,
    ops: &mut Vec<PlannedOp>,
) -> Result<(Vec<String>, Vec<DriftRow>)> {
    let target = super::secrets_write::target(scope, options)?;
    let mut notes = Vec::new();
    super::posture::plan_posture(
        scope,
        super::secrets_write::owed_ignore(options, target.as_ref()),
        ops,
        &mut notes,
    )?;
    let (settings_notes, drift) = plan_settings_seed(scope, state, options, ops)?;
    notes.extend(settings_notes);
    notes.extend(super::secrets_write::plan_secrets(
        scope,
        state,
        options,
        target.as_ref(),
        ops,
    )?);
    Ok((notes, drift))
}

/// The private file a save is recording as this project's, where it is
/// recording one. A save that only stores a value into the file the
/// project already uses records nothing: the key is only written when the
/// person names a file the project does not already name.
fn recorded_choice(options: &crate::engine::PlanOptions) -> Option<String> {
    let draft = options.secrets_draft.as_ref()?;
    draft.choose.then(|| draft.file.clone())
}
