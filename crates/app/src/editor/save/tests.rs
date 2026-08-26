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

/// The chain that turns a mid-apply refusal into the stale choice,
/// exercised whole: the plan's own manifest write binds to the editor
/// copy's base (`PlanOptions::manifest_base`), a writer lands after
/// the copy was read, and the apply refuses in a way `stale_at`
/// recognises while the writer's bytes stand. A plan observing the
/// file instead of taking the base would accept this writer.
#[test]
fn a_writer_landing_after_the_editor_read_is_refused_mid_apply() {
    let (_tmp, env, scope) = scope_with_manifest();
    let path = manifest::manifest_path(&env, &scope);
    std::fs::write(&path, "schema = 4\n\n[install]\nharnesses = [\"claude\"]\n").unwrap();
    let (read, base) = manifest::read_for_mutation(&path).unwrap();
    let mut editor_copy = read.unwrap();
    // Reading for mutation normalizes the schema; the engine plans the
    // upgrade write when the copy it is handed still carries the old
    // one — and must bind that write to the base when one is given.
    editor_copy.schema = 4;

    // The writer in between: lands after the editor copy left, before
    // the plan is made.
    std::fs::write(
        &path,
        "schema = 4\n\n[install]\nharnesses = [\"claude\"]\n\n[skill-instructions]\nall = \"kept\"\n",
    )
    .unwrap();

    let lock = load_lock(&lock_path(&env, &scope)).unwrap();
    let options = PlanOptions {
        manifest_base: Some(base),
        ..PlanOptions::default()
    };
    let report = engine::plan_scope(&env, &scope, &editor_copy, &lock, &options).unwrap();
    assert!(
        report
            .plan
            .ops
            .iter()
            .any(|op| op.description.contains("Upgrade")),
        "the schema upgrade is the plan's manifest write: {:?}",
        report.plan.ops
    );

    let error = apply::execute(&env, &report.plan, None).unwrap_err();
    assert!(
        stale_at(
            &error,
            std::slice::from_ref(&manifest::manifest_path(&env, &scope))
        ),
        "{error:?}"
    );
    let kept = std::fs::read_to_string(&path).unwrap();
    assert!(kept.contains("all = \"kept\""), "{kept}");
}

/// The mid-apply refusal with the scope root reached through a symlink:
/// the plan speaks the canonical spelling, so the targets a caller matches
/// the refusal against must speak it too, whatever spelling the scope
/// arrived under. macOS reaches every temp directory through `/var` →
/// `/private/var` and runs the tests above this way; the link reproduces
/// that shape on every platform.
#[cfg(unix)]
#[test]
fn a_refusal_through_a_symlinked_root_is_still_the_stale_choice() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), kendex_core::env::FakeOs::Linux);
    let real = tmp.path().join("dev/app");
    std::fs::create_dir_all(real.join(".claude")).unwrap();
    std::fs::write(
        real.join("kendex.toml"),
        "schema = 4\n\n[install]\nharnesses = [\"claude\"]\n",
    )
    .unwrap();
    std::os::unix::fs::symlink(tmp.path().join("dev"), tmp.path().join("via")).unwrap();
    let scope = Scope::Project {
        root: tmp.path().join("via/app"),
    };

    let path = manifest::manifest_path(&env, &scope);
    let (read, base) = manifest::read_for_mutation(&path).unwrap();
    let mut editor_copy = read.unwrap();
    // The old schema keeps the upgrade in the plan — the manifest write
    // the base binds to, exactly as in the direct-spelling test above.
    editor_copy.schema = 4;
    let lock = load_lock(&lock_path(&env, &scope)).unwrap();
    let options = PlanOptions {
        manifest_base: Some(base),
        ..PlanOptions::default()
    };
    let report = engine::plan_scope(&env, &scope, &editor_copy, &lock, &options).unwrap();

    // The writer in between, landing through the same link.
    std::fs::write(
        &path,
        "schema = 4\n\n[skill-instructions]\nall = \"kept\"\n",
    )
    .unwrap();

    let error = apply::execute(&env, &report.plan, None).unwrap_err();
    assert!(
        stale_at(
            &error,
            std::slice::from_ref(&manifest::manifest_path(&env, &scope))
        ),
        "{error:?}"
    );
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
    // Written raw, the way a hand edit or another process lands.
    let mut newer = manifest::load_for_mutation(&path).unwrap().unwrap();
    newer
        .agent_launch_instructions
        .insert("all".into(), "kept".into());
    std::fs::write(&path, toml::to_string_pretty(&newer).unwrap()).unwrap();

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
