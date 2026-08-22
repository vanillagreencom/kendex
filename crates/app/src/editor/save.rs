//! The Customize tab's whole-manifest read and write.
//!
//! Every other write in the app is a targeted operation that loads, changes
//! and saves in one breath. This one hands a person the whole file, waits
//! while they type, and writes all of it back — so it is the one write that
//! can put an older file over a newer one, and the only one that carries
//! the base of the file its copy came from to stop that.

use kendex_core::apply::{self, Op, PlannedOp, Pre};
use kendex_core::engine::{self, PlanOptions, ops};
use kendex_core::lock::{load as load_lock, lock_path};
use kendex_core::manifest::{self, Finding, Manifest};
use kendex_core::model::Scope;
use serde::Serialize;
use specta::Type;

use super::env;
use crate::audit::{AuditView, view};

mod refusal;
use refusal::{refusal, stale_at, targets};

/// A place's manifest and what the file it came from was at that moment.
/// One value, because a copy without its base cannot be written back
/// safely, and the two read apart could describe different files.
#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ManifestRead {
    /// Absent where the place has no manifest yet — the editor still opens,
    /// on an empty one.
    pub manifest: Option<Manifest>,
    /// The file these bytes came from, read with them and never apart.
    pub base: manifest::Base,
}

/// Why a whole-manifest write did not happen. Refusing is a normal answer
/// here, not a failure, so it is a shape the editor can act on rather than
/// a message it would have to recognise by its words.
#[derive(Debug, Serialize, Type)]
#[serde(tag = "kind", rename_all = "kebab-case")]
pub enum WriteRefused {
    /// The file is no longer the one this copy was read from. Something
    /// else wrote it — a fork, a hold, a dismissal, an install — and
    /// writing this copy would put that back.
    Stale,
    Failed {
        message: String,
    },
}

impl From<String> for WriteRefused {
    fn from(message: String) -> WriteRefused {
        WriteRefused::Failed { message }
    }
}

/// A whole-manifest write that landed, and what the file is now: the base
/// for the next write from the same copy, so saving twice in a row does not
/// have to wait for a re-read in between.
#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ManifestWritten {
    pub view: AuditView,
    /// What the file is now, as the apply that wrote it saw it before
    /// letting the scope go — the base for the next write from this copy.
    ///
    /// Absent where the write landed and the file could not be read back.
    /// The copy on screen has nothing to carry then, so its next save asks
    /// for a reload rather than writing against a base nobody vouched for;
    /// what it must not do is read the file itself, which is the pairing
    /// this whole protection exists to prevent.
    pub base: Option<manifest::Base>,
    /// Whether the write put down something the caller did not send: the
    /// default source and harnesses a first manifest is seeded with, or a
    /// name derived for a custom hook that arrived without one.
    ///
    /// No copy in hand holds it, so none of them is this file — not even
    /// the one that went. Told otherwise, the editor hands the file's base
    /// to a copy that never had it, and the next save passes every check
    /// and writes it away: the seed back to nothing, or a second hook
    /// under a second derived name with the first left running.
    pub wrote_more: bool,
}

#[tauri::command(async)]
#[specta::specta]
pub fn get_manifest(scope: Scope) -> Result<ManifestRead, String> {
    let env = env()?;
    let path = manifest::manifest_path(&env, &scope);
    // One read for both halves: read apart, the manifest could be the old
    // file's and the base the new one's, and the write that follows would
    // be accepted over the writer in between.
    let (manifest, base) = manifest::read_for_mutation(&path).map_err(|e| e.to_string())?;
    Ok(ManifestRead { manifest, base })
}

/// Validate an edited manifest the way a hand-written file is validated, so
/// the editor rejects exactly the same things — fix strings included.
fn check(manifest: &Manifest) -> Result<(), String> {
    let text = toml::to_string_pretty(manifest).map_err(|e| e.to_string())?;
    let table: toml::Table = text.parse().map_err(|e: toml::de::Error| e.to_string())?;
    let findings = manifest::validate(&table);
    if findings.is_empty() {
        return Ok(());
    }
    Err(findings
        .iter()
        .map(Finding::to_string)
        .collect::<Vec<_>>()
        .join("\n"))
}

/// The editor can create the first manifest for a scope, and first creation
/// is where the default source is seeded — skipping it here would drop it
/// for good, since later reconciliation never re-adds it.
///
/// Reports whether anything was filled in. What goes on disk is then not
/// what the caller sent, and a copy typed while this write was away never
/// held it: the editor needs to be told so it does not treat that copy as
/// descended from this file and let its next save drop the seed.
fn on_first_creation(manifest: &mut Manifest, seed: Manifest) -> bool {
    if !manifest.sources.is_empty() {
        return false;
    }
    let mut filled = !seed.sources.is_empty();
    manifest.sources = seed.sources;
    if manifest.install.harnesses.is_empty() && !seed.install.harnesses.is_empty() {
        manifest.install.harnesses = seed.install.harnesses;
        filled = true;
    }
    filled
}

/// Bring what the caller sent to what actually goes on disk, and say
/// whether the two differ. `seed` is present only where there is no file
/// yet, which is the one moment seeding happens.
///
/// Both normalizations answer here so neither can be added without the
/// caller being told: a write that quietly holds more than it was sent is
/// a write the editor will mistake for its own copy.
fn as_written(manifest: &mut Manifest, seed: Option<Manifest>) -> bool {
    let seeded = seed.is_some_and(|seed| on_first_creation(manifest, seed));
    // A custom hook's name is its identity everywhere downstream; saving is
    // when a derived one stops being derived.
    let named = kendex_core::hook::name_custom_hooks(manifest);
    seeded || named
}

/// Write an edited manifest and reconcile the scope to it.
///
/// `base` is what the file was when this copy was read. A whole manifest
/// goes back with every save, so a copy read before something else wrote
/// the file would put that back — and the caller cannot be relied on to
/// notice: the app tells the editor about every such write, and a caller
/// that forgets to says nothing at all. Refusing here needs no caller to
/// remember anything.
#[tauri::command(async)]
#[specta::specta]
pub fn update_manifest(
    scope: Scope,
    manifest: Manifest,
    base: Option<String>,
) -> Result<ManifestWritten, WriteRefused> {
    let env = env()?;
    let path = manifest::manifest_path(&env, &scope);
    // The bytes behind this base were read in the editor, so it arrives as
    // a claim and is only ever compared, never believed.
    let claimed = manifest::Base::claimed(base);
    let held = Pre::from(&claimed);
    // Only a file that became something else is a stale copy. A file that
    // could not be read at all is a failure to say out loud: offering the
    // reload for it sends someone to a remedy that cannot fix a permission
    // or an encoding, and hides what did.
    if let Err(error) = manifest::check_base(&path, &claimed) {
        return Err(refusal(error));
    }
    let mut manifest = manifest;
    let seed = match manifest::load_for_mutation(&path).map_err(|e| e.to_string())? {
        Some(_) => None,
        None => Some(ops::manifest_for_mutation(&env, &scope).map_err(|e| e.to_string())?),
    };
    let wrote_more = as_written(&mut manifest, seed);
    check(&manifest)?;
    let lock = load_lock(&lock_path(&env, &scope)).map_err(|e| e.to_string())?;
    // Whoever plans a write of this file, it is the copy on screen being
    // written, so the plan binds its own manifest write to the file that
    // copy came from. Binding afterwards by path cannot: a scope still
    // under the old product name has its writes retargeted to the new
    // filename after planning, and a search for the path this command knew
    // would find nothing and leave that write bound to what the plan saw.
    let options = PlanOptions {
        manifest_base: Some(claimed),
        ..PlanOptions::default()
    };
    let mut report =
        engine::plan_scope(&env, &scope, &manifest, &lock, &options).map_err(|e| e.to_string())?;
    let persisted = engine::persists_manifest(&report.plan.ops);
    if !persisted {
        report.plan.ops.insert(
            0,
            PlannedOp {
                description: "Save kendex.toml".into(),
                op: Op::WriteManifest {
                    pre: held.clone(),
                    // The name the file has now, and first in the plan for
                    // that reason: a scope still under the old product name
                    // renames it further down, which carries this write to
                    // the new name with the bytes it just put there. Written
                    // after the rename it would recreate the old file.
                    path: path.clone(),
                    manifest: Box::new(manifest),
                },
            },
        );
    }
    // Where this write ends up, which is not always where it was aimed: a
    // rename generation retargets every write planned against the old name,
    // and a refusal from one of those names the file it was retargeted to.
    let targets = targets(&report.plan, &path);
    // The bound precondition refuses a file that moved between the check
    // above and the write itself, and that refusal is the same answer the
    // check gives — so it reaches the editor as the same choice. Told as a
    // failure it would reach them as a message they cannot act on, which
    // is the whole reason the refusal is a shape and not a string.
    let outcome = apply::execute(&env, &report.plan, None).map_err(|error| {
        match stale_at(&error, &targets) {
            true => WriteRefused::Stale,
            false => WriteRefused::Failed {
                message: error.to_string(),
            },
        }
    })?;
    Ok(ManifestWritten {
        view: view(&env, &scope),
        // From the apply, which read it before letting the scope go. Read
        // here instead and the answer could already be somebody else's,
        // handed back paired with the copy this write came from.
        base: outcome.manifest_base,
        wrote_more,
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    use kendex_core::manifest::{
        DEFAULT_SOURCE_NAME, DEFAULT_SOURCE_REPO, ItemDecl, MANIFEST_SCHEMA, SourceDecl,
    };
    use kendex_core::model::HarnessId;
    use std::collections::BTreeMap;

    fn manifest() -> Manifest {
        Manifest {
            schema: MANIFEST_SCHEMA,
            sources: BTreeMap::from([(
                DEFAULT_SOURCE_NAME.to_owned(),
                SourceDecl {
                    repo: Some(DEFAULT_SOURCE_REPO.to_owned()),
                    path: None,
                    rev: None,
                    enabled: true,
                },
            )]),
            ..Manifest::default()
        }
    }

    #[test]
    fn customization_tables_pass_the_same_check_a_file_gets() {
        let mut edited = manifest();
        edited
            .agent_skills
            .insert("orch".to_owned(), vec!["github".to_owned()]);
        edited
            .agent_launch_instructions
            .insert("all".to_owned(), "read the plan".to_owned());
        edited.custom_hooks.push(kendex_core::manifest::CustomHook {
            name: None,
            event: "PreToolUse".to_owned(),
            matcher: Some("Bash".to_owned()),
            command: "./guard.sh".to_owned(),
            description: None,
            timeout: None,
            harnesses: None,
            enabled: true,
            agents: kendex_core::manifest::HookAgents::One("all".to_owned()),
        });
        assert_eq!(check(&edited), Ok(()));
    }

    #[test]
    fn creating_a_manifest_here_still_seeds_the_default_source() {
        let mut fresh = Manifest {
            schema: MANIFEST_SCHEMA,
            ..Manifest::default()
        };
        assert!(on_first_creation(
            &mut fresh,
            manifest::seed(&[HarnessId::Claude])
        ));
        assert!(fresh.sources.contains_key("kendex"));
        assert_eq!(fresh.install.harnesses, [HarnessId::Claude]);

        let mut declared = manifest();
        // Nothing was filled in, so the copy the caller sent is the file:
        // the editor is told nothing was added and its base still stands.
        assert!(!on_first_creation(
            &mut declared,
            manifest::seed(&[HarnessId::Pi])
        ));
        assert_eq!(declared.sources.len(), 1);
        assert!(declared.install.harnesses.is_empty());
    }

    // Both normalizations are the same fact to the caller: the file holds
    // something no copy in hand does. Naming a hook is the one that reaches
    // a manifest that already exists.
    #[test]
    fn naming_a_hook_is_the_write_holding_more_than_it_was_sent() {
        let unnamed = || kendex_core::manifest::CustomHook {
            name: None,
            event: "PreToolUse".to_owned(),
            matcher: None,
            command: "./guard.sh".to_owned(),
            description: None,
            timeout: None,
            harnesses: None,
            enabled: true,
            agents: kendex_core::manifest::HookAgents::One("all".to_owned()),
        };

        // An existing file, so nothing is seeded: the naming alone answers.
        let mut arriving = manifest();
        arriving.custom_hooks.push(unnamed());
        assert!(as_written(&mut arriving, None));
        assert!(arriving.custom_hooks[0].name.is_some());

        // And a manifest the write leaves exactly as it came says so, or
        // every ordinary save would refuse the copy that made it.
        let mut settled = manifest();
        settled.custom_hooks.push(unnamed());
        settled.custom_hooks[0].name = Some("guard".to_owned());
        assert!(!as_written(&mut settled, None));
    }

    #[test]
    fn rejected_edits_come_back_with_their_fix_string() {
        let mut edited = manifest();
        edited
            .skills
            .insert("github".to_owned(), ItemDecl::from_source("gone"));
        let error = check(&edited).expect_err("undeclared source must be rejected");
        assert!(error.contains("skills.github"), "{error}");
        assert!(error.contains("fix: declare [sources.gone]"), "{error}");
    }
}
