//! The Customize tab's whole-manifest read and write.
//!
//! Every other write in the app is a targeted operation that loads,
//! changes and saves in one breath. This one hands a person the whole
//! file, waits while they type, and writes all of it back — so it is the
//! one write that can put an older file over a newer one, and the only
//! one that carries the base of the file its copy came from to stop that.

use kendex_core::apply::{self, Op, PlannedOp, Pre};
use kendex_core::base::Base;
use kendex_core::engine::{self, PlanOptions, ops};
use kendex_core::env::Env;
use kendex_core::lock::{load as load_lock, lock_path};
use kendex_core::manifest::{self, Finding, Manifest};
use kendex_core::model::Scope;
use serde::Serialize;
use specta::Type;

use super::env;
use crate::audit::{AuditView, view};
use crate::whole_file::{WriteRefused, stale_at, targets};

/// A place's manifest and what the file it came from was at that moment.
/// One value, because a copy without its base cannot be written back
/// safely, and the two read apart could describe different files.
#[derive(Serialize, Type)]
#[serde(rename_all = "camelCase")]
pub struct ManifestRead {
    /// Absent where the place has no manifest yet — the editor still
    /// opens, on an empty one.
    pub manifest: Option<Manifest>,
    /// The file these bytes came from, read with them and never apart.
    pub base: Base,
}

#[tauri::command(async)]
#[specta::specta]
pub fn get_manifest(scope: Scope) -> Result<ManifestRead, String> {
    let env = env()?;
    let (manifest, base) = manifest::read_for_mutation(&manifest::manifest_path(&env, &scope))
        .map_err(|e| e.to_string())?;
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
fn on_first_creation(mut manifest: Manifest, seed: Manifest) -> Manifest {
    if manifest.sources.is_empty() {
        manifest.sources = seed.sources;
        if manifest.install.harnesses.is_empty() {
            manifest.install.harnesses = seed.install.harnesses;
        }
    }
    manifest
}

/// Write an edited manifest and reconcile the scope to it.
///
/// `base` is what the file was when this copy was read. A whole manifest
/// goes back with every save, so a copy read before something else wrote
/// the file would put that back — and the caller cannot be relied on to
/// notice. Refusing here needs no caller to remember anything.
#[tauri::command(async)]
#[specta::specta]
pub fn update_manifest(
    scope: Scope,
    manifest: Manifest,
    base: Option<String>,
) -> Result<AuditView, WriteRefused> {
    // The bytes behind this base were read in the editor, so it arrives
    // as a claim and is only ever compared, never believed.
    write_manifest(&env()?, scope, manifest, Base::claimed(base))
}

/// The write itself, against a given environment — which is what makes it
/// reachable from a test. The command above only finds the environment.
fn write_manifest(
    env: &Env,
    scope: Scope,
    manifest: Manifest,
    claimed: Base,
) -> Result<AuditView, WriteRefused> {
    let path = manifest::manifest_path(env, &scope);
    // One read answers both questions: whether the file is still the one
    // the copy came from, and whether there is a file at all — the moment
    // first-creation seeding happens. A file that cannot be read is a
    // failure to say out loud, not a stale copy: the reload cannot fix a
    // permission or an encoding, and offering it would hide what did.
    let (current, now) = manifest::read_for_mutation(&path).map_err(|e| e.to_string())?;
    if now != claimed {
        return Err(WriteRefused::Stale);
    }
    let mut manifest = match current {
        Some(_) => manifest,
        None => on_first_creation(
            manifest,
            ops::manifest_for_mutation(env, &scope).map_err(|e| e.to_string())?,
        ),
    };
    // A custom hook's name is its identity everywhere downstream; saving is
    // when a derived one stops being derived.
    kendex_core::hook::name_custom_hooks(&mut manifest);
    check(&manifest)?;
    let lock = load_lock(&lock_path(env, &scope)).map_err(|e| e.to_string())?;
    // The plan binds its own manifest write to the file this copy came
    // from, so a writer landing after the check above is refused by the
    // apply rather than overwritten.
    let options = PlanOptions {
        manifest_base: Some(claimed.clone()),
        ..PlanOptions::default()
    };
    let mut report =
        engine::plan_scope(env, &scope, &manifest, &lock, &options).map_err(|e| e.to_string())?;
    let persisted = engine::persists_manifest(&report.plan.ops);
    if !persisted {
        report.plan.ops.insert(
            0,
            PlannedOp {
                description: "Save kendex.toml".into(),
                op: Op::WriteManifest {
                    pre: Pre::from(&claimed),
                    // First in the plan: a scope still under the old
                    // product name renames the file further down, which
                    // carries this write to the new name with the bytes it
                    // just put there. Written after the rename it would
                    // recreate the old file.
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
    // check gives — so it reaches the editor as the same choice.
    apply::execute(env, &report.plan, None).map_err(|error| match stale_at(&error, &targets) {
        true => WriteRefused::Stale,
        false => WriteRefused::Failed {
            message: error.to_string(),
        },
    })?;
    Ok(view(env, &scope))
}

#[cfg(test)]
mod tests {
    use super::*;
    use kendex_core::manifest::{
        DEFAULT_SOURCE_NAME, DEFAULT_SOURCE_REPO, ItemDecl, MANIFEST_SCHEMA, SourceDecl,
    };
    use kendex_core::model::HarnessId;
    use std::collections::BTreeMap;

    /// A project scope with a manifest already on disk, under a sandboxed
    /// home, so a save runs the real plan-and-apply.
    fn scope_with_manifest() -> (tempfile::TempDir, Env, Scope) {
        let tmp = tempfile::tempdir().unwrap();
        let env = Env::fake(tmp.path(), kendex_core::env::FakeOs::Linux);
        let project = tmp.path().join("dev/app");
        std::fs::create_dir_all(project.join(".claude")).unwrap();
        std::fs::write(
            project.join("kendex.toml"),
            "schema = 5\n\n[install]\nharnesses = [\"claude\"]\n",
        )
        .unwrap();
        (tmp, env, Scope::Project { root: project })
    }

    #[test]
    fn a_save_carrying_the_base_of_the_file_it_read_lands() {
        let (_tmp, env, scope) = scope_with_manifest();
        let path = manifest::manifest_path(&env, &scope);
        let (read, base) = manifest::read_for_mutation(&path).unwrap();

        let mut edited = read.unwrap();
        edited
            .skill_instructions
            .insert("all".into(), "read the plan".into());
        write_manifest(&env, scope, edited, base).unwrap();

        let (saved, _) = manifest::read_for_mutation(&path).unwrap();
        assert_eq!(
            saved
                .unwrap()
                .skill_instructions
                .get("all")
                .map(String::as_str),
            Some("read the plan")
        );
    }

    /// The loss this command used to allow: a copy read before something
    /// else wrote the file, saved wholesale, would put the older file back
    /// over the writer in between. It is refused now, and the newer file
    /// stands untouched.
    #[test]
    fn a_save_from_a_stale_copy_is_refused_and_the_newer_file_stands() {
        let (_tmp, env, scope) = scope_with_manifest();
        let path = manifest::manifest_path(&env, &scope);
        let (read, base) = manifest::read_for_mutation(&path).unwrap();
        let mut stale = read.unwrap();
        stale
            .skill_instructions
            .insert("all".into(), "older edit".into());

        // The writer in between — the write refusing exists to protect.
        let mut newer = manifest::load_for_mutation(&path).unwrap().unwrap();
        newer
            .agent_launch_instructions
            .insert("all".into(), "kept".into());
        manifest::save(&path, &newer).unwrap();

        let Err(refused) = write_manifest(&env, scope, stale, base) else {
            panic!("a stale save must be refused");
        };

        assert!(matches!(refused, WriteRefused::Stale), "{refused:?}");
        let (kept, _) = manifest::read_for_mutation(&path).unwrap();
        let kept = kept.unwrap();
        assert_eq!(
            kept.agent_launch_instructions
                .get("all")
                .map(String::as_str),
            Some("kept")
        );
        assert!(kept.skill_instructions.is_empty());
    }

    /// The other refusal direction: a copy that remembers "there was no
    /// file" arrives after a first save created one.
    #[test]
    fn a_copy_predating_the_first_save_is_refused_once_a_file_exists() {
        let (_tmp, env, scope) = scope_with_manifest();
        let empty = Manifest {
            schema: MANIFEST_SCHEMA,
            ..Manifest::default()
        };
        let Err(refused) = write_manifest(&env, scope, empty, Base::absent()) else {
            panic!("a no-file claim against an existing file must be refused");
        };
        assert!(matches!(refused, WriteRefused::Stale), "{refused:?}");
    }

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
        let seeded = on_first_creation(
            Manifest {
                schema: MANIFEST_SCHEMA,
                ..Manifest::default()
            },
            manifest::seed(&[HarnessId::Claude]),
        );
        assert!(seeded.sources.contains_key("kendex"));
        assert_eq!(seeded.install.harnesses, [HarnessId::Claude]);

        let declared = on_first_creation(manifest(), manifest::seed(&[HarnessId::Pi]));
        assert_eq!(declared.sources.len(), 1);
        assert!(declared.install.harnesses.is_empty());
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
