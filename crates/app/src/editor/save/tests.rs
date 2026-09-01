use super::*;
use kendex_core::manifest::{
    DEFAULT_SOURCE_NAME, DEFAULT_SOURCE_REPO, ItemDecl, MANIFEST_SCHEMA, SourceDecl,
};
use kendex_core::model::HarnessId;
use std::collections::BTreeMap;

#[path = "../../../../test_util.rs"]
mod test_util;
use test_util::source_path;

/// A project scope with no kendex.toml at all: the state the editor opens
/// an empty draft for, and the one a first save creates the file from.
fn scope_without_manifest() -> (tempfile::TempDir, Env, Scope) {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), kendex_core::env::FakeOs::Linux);
    let project = tmp.path().join("dev/app");
    std::fs::create_dir_all(project.join(".claude")).unwrap();
    (tmp, env, Scope::Project { root: project })
}

/// A project scope with a manifest already on disk, under a sandboxed
/// home, so a save runs the real plan-and-apply.
fn scope_with_manifest() -> (tempfile::TempDir, Env, Scope) {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), kendex_core::env::FakeOs::Linux);
    let project = tmp.path().join("dev/app");
    std::fs::create_dir_all(project.join(".claude")).unwrap();
    std::fs::write(
        project.join("kendex.toml"),
        format!("schema = {MANIFEST_SCHEMA}\n\n[install]\nharnesses = [\"claude\"]\n"),
    )
    .unwrap();
    (tmp, env, Scope::Project { root: project })
}

/// A scope whose agent's role gained a skill upstream since it was
/// installed: the one thing that still makes the plan write the manifest
/// itself, and so the one write `PlanOptions::manifest_base` binds.
///
/// Two phases, because the addition is measured against what the lock
/// recorded: install once with the role carrying `recon`, then let the
/// catalog give the role `probe` as well.
fn scope_gaining_a_catalog_skill() -> (tempfile::TempDir, Env, Scope) {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), kendex_core::env::FakeOs::Linux);
    let project = tmp.path().join("dev/app");
    std::fs::create_dir_all(project.join(".claude")).unwrap();
    let catalog = tmp.path().join("catalog");
    std::fs::create_dir_all(catalog.join("agents")).unwrap();
    let skill = |name: &str| {
        std::fs::create_dir_all(catalog.join("skills").join(name)).unwrap();
        std::fs::write(
            catalog.join("skills").join(name).join("SKILL.md"),
            format!("---\nname: {name}\ndescription: skill {name}\n---\nBody.\n"),
        )
        .unwrap();
    };
    skill("recon");
    skill("probe");
    std::fs::write(
        catalog.join("agents/rev.md"),
        "---\nname: rev\ndescription: agent rev\nrole: reviewer\n---\nBody.\n",
    )
    .unwrap();
    let role_skills = |carried: &str| {
        std::fs::write(
            catalog.join("kendex.toml"),
            format!("is_source_catalog = true\n\n[role-skills]\nreviewer = [{carried}]\n"),
        )
        .unwrap();
    };
    role_skills("\"recon\"");
    std::fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = {MANIFEST_SCHEMA}\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[agents.rev]\nsource = \"cat\"\n\n[skills.recon]\nsource = \"cat\"\n\n[agent-skills]\nrev = [\"recon\"]\n",
            source_path(&catalog)
        ),
    )
    .unwrap();
    let scope = Scope::Project {
        root: project.clone(),
    };

    // Phase one: install, so the lock records the upstream set an addition
    // is measured against.
    crate::audit::apply_scope(&env, &scope, false).unwrap();

    // Phase two: the role gains a skill the manifest does not name.
    role_skills("\"recon\", \"probe\"");
    (tmp, env, scope)
}

/// The chain that turns a mid-apply refusal into the stale choice,
/// exercised whole: the plan's own manifest write binds to the editor
/// copy's base (`PlanOptions::manifest_base`), a writer lands after
/// the copy was read, and the apply refuses in a way `stale_at`
/// recognises while the writer's bytes stand. A plan observing the
/// file instead of taking the base would accept this writer.
#[test]
fn a_writer_landing_after_the_editor_read_is_refused_mid_apply() {
    let (_tmp, env, scope) = scope_gaining_a_catalog_skill();
    let path = manifest::manifest_path(&env, &scope);
    let (read, base) = manifest::read_for_mutation(&path).unwrap();
    let editor_copy = read.unwrap();

    // The writer in between: lands after the editor copy left, before
    // the plan is made.
    let original = std::fs::read_to_string(&path).unwrap();
    std::fs::write(
        &path,
        format!("{original}\n[skill-instructions]\nall = \"kept\"\n"),
    )
    .unwrap();

    let lock = load_lock(&lock_path(&env, &scope)).unwrap();
    let options = PlanOptions {
        manifest_base: Some(base),
        ..PlanOptions::default()
    };
    let report = engine::plan_scope(&env, &scope, &editor_copy, &lock, &options).unwrap();
    assert!(
        engine::persists_manifest(&report.plan.ops),
        "the catalog's new skill is the plan's manifest write: {:?}",
        report.plan.ops
    );

    let error = kendex_core::apply::execute(&env, &report.plan).unwrap_err();
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
    let (tmp, env, _real) = scope_gaining_a_catalog_skill();
    std::os::unix::fs::symlink(tmp.path().join("dev"), tmp.path().join("via")).unwrap();
    let scope = Scope::Project {
        root: tmp.path().join("via/app"),
    };

    let path = manifest::manifest_path(&env, &scope);
    let (read, base) = manifest::read_for_mutation(&path).unwrap();
    let editor_copy = read.unwrap();
    let lock = load_lock(&lock_path(&env, &scope)).unwrap();
    let options = PlanOptions {
        manifest_base: Some(base),
        ..PlanOptions::default()
    };
    let report = engine::plan_scope(&env, &scope, &editor_copy, &lock, &options).unwrap();
    assert!(
        engine::persists_manifest(&report.plan.ops),
        "{:?}",
        report.plan.ops
    );

    // The writer in between, landing through the same link.
    let original = std::fs::read_to_string(&path).unwrap();
    std::fs::write(
        &path,
        format!("{original}\n[skill-instructions]\nall = \"kept\"\n"),
    )
    .unwrap();

    let error = kendex_core::apply::execute(&env, &report.plan).unwrap_err();
    assert!(
        stale_at(
            &error,
            std::slice::from_ref(&manifest::manifest_path(&env, &scope))
        ),
        "{error:?}"
    );
}

/// The first save on a scope with no kendex.toml creates the file. The
/// schema the draft arrives with is what decides it: `check` runs before
/// the plan's `manifest::save` would stamp one, so a draft naming any
/// other version is refused and nothing is created. That is why the
/// editor's empty draft reads the number off the exported
/// `MANIFEST_SCHEMA` rather than keeping a copy — see `emptyDraft` in
/// ui/src/lib/editor-draft.ts.
#[test]
fn a_first_save_creates_the_manifest_and_the_draft_schema_decides_it() {
    let (_tmp, env, scope) = scope_without_manifest();
    let path = manifest::manifest_path(&env, &scope);
    assert!(!path.exists(), "{}", path.display());

    let stale = Manifest {
        schema: MANIFEST_SCHEMA - 1,
        ..Manifest::default()
    };
    let Err(refused) = write_customize(&env, scope.clone(), Some((stale, Base::absent())), None)
    else {
        panic!("a draft below this build's schema must not create a file");
    };
    let WriteRefused::Failed { message } = &refused else {
        panic!("the schema refusal is a validation failure, not a stale copy: {refused:?}");
    };
    assert!(message.contains("schema"), "{message}");
    assert!(!path.exists(), "and nothing is created: {}", path.display());

    let draft = Manifest {
        schema: MANIFEST_SCHEMA,
        ..Manifest::default()
    };
    write_customize(&env, scope, Some((draft, Base::absent())), None).unwrap();
    let (created, _) = manifest::read_for_mutation(&path).unwrap();
    assert_eq!(created.unwrap().schema, MANIFEST_SCHEMA);
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
    write_customize(&env, scope, Some((edited, base)), None).unwrap();

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

    let Err(refused) = write_customize(&env, scope, Some((stale, base)), None) else {
        panic!("a stale save must be refused");
    };

    assert!(matches!(refused, WriteRefused::Stale { .. }), "{refused:?}");
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
    let Err(refused) = write_customize(&env, scope, Some((empty, Base::absent())), None) else {
        panic!("a no-file claim against an existing file must be refused");
    };
    assert!(matches!(refused, WriteRefused::Stale { .. }), "{refused:?}");
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

/// A key the skill's own code already defaults, which an install never
/// writes. The app is what puts it in the file, and only when someone
/// changes it.
const TEMPLATE: &str = "[env]\n# Which reviewers run by default.\nREVIEWERS = \"arch,security\"\n";

/// A project whose one installed skill ships settings, so a save has both
/// halves to carry.
fn scope_with_settings_skill() -> (tempfile::TempDir, Env, Scope) {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), kendex_core::env::FakeOs::Linux);
    let project = tmp.path().join("dev/app");
    std::fs::create_dir_all(project.join(".claude")).unwrap();
    let skill = tmp.path().join("catalog/skills/review");
    std::fs::create_dir_all(&skill).unwrap();
    std::fs::write(
        skill.join("SKILL.md"),
        "---\nname: review\ndescription: review changes\n---\nBody.\n",
    )
    .unwrap();
    std::fs::write(skill.join("kendex.settings.toml.example"), TEMPLATE).unwrap();
    std::fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\n\n[skills.review]\nsource = \"cat\"\n",
            source_path(&tmp.path().join("catalog"))
        ),
    )
    .unwrap();
    (tmp, env, Scope::Project { root: project })
}

fn edit(key: &str, value: &str) -> SettingsEdit {
    SettingsEdit {
        skill: "review".to_owned(),
        key: key.to_owned(),
        value: kendex_core::settings_file::SettingsEditValue::Set {
            value: value.to_owned(),
        },
    }
}

/// The reason a settings edit cannot be a second write: saving the
/// manifest re-plans the scope, and that plan seeds this very file. Both
/// drafts go into one plan and land together.
#[test]
fn a_manifest_and_a_settings_draft_land_in_one_save() {
    let (tmp, env, scope) = scope_with_settings_skill();
    let settings = tmp.path().join("dev/app/kendex.settings.toml");
    let manifest_path = manifest::manifest_path(&env, &scope);
    // An install writes none of this template, so the save is the first
    // thing to reach the file: it holds no bytes, and the write makes it.
    write_customize(&env, scope.clone(), None, None).unwrap();
    assert!(!settings.exists(), "an install wrote nothing here");
    let held = Base::claimed(None);

    let (read, base) = manifest::read_for_mutation(&manifest_path).unwrap();
    let mut edited = read.unwrap();
    edited
        .skill_instructions
        .insert("all".into(), "read the plan".into());
    write_customize(
        &env,
        scope,
        Some((edited, base)),
        Some(kendex_core::settings_file::SettingsDraft {
            edits: vec![edit("REVIEWERS", "arch")],
            base: held,
        }),
    )
    .unwrap();

    assert!(
        std::fs::read_to_string(&settings)
            .unwrap()
            .contains("REVIEWERS = \"arch\"")
    );
    let (saved, _) = manifest::read_for_mutation(&manifest_path).unwrap();
    assert_eq!(
        saved
            .unwrap()
            .skill_instructions
            .get("all")
            .map(String::as_str),
        Some("read the plan")
    );
}

/// Neither half lands when one is refused. The settings copy is the stale
/// one here, and the manifest edit beside it must not go in on its own.
#[test]
fn a_stale_settings_copy_refuses_and_takes_the_manifest_edit_with_it() {
    let (tmp, env, scope) = scope_with_settings_skill();
    let settings = tmp.path().join("dev/app/kendex.settings.toml");
    let manifest_path = manifest::manifest_path(&env, &scope);
    write_customize(
        &env,
        scope.clone(),
        None,
        Some(kendex_core::settings_file::SettingsDraft {
            edits: vec![edit("REVIEWERS", "arch,security")],
            base: Base::claimed(None),
        }),
    )
    .unwrap();
    let held = Base::of(&std::fs::read_to_string(&settings).unwrap());

    // The writer in between.
    let newer = std::fs::read_to_string(&settings)
        .unwrap()
        .replace("arch,security", "theirs");
    std::fs::write(&settings, &newer).unwrap();

    let (read, base) = manifest::read_for_mutation(&manifest_path).unwrap();
    let mut edited = read.unwrap();
    edited
        .skill_instructions
        .insert("all".into(), "older edit".into());
    let Err(refused) = write_customize(
        &env,
        scope,
        Some((edited, base)),
        Some(kendex_core::settings_file::SettingsDraft {
            edits: vec![edit("REVIEWERS", "arch")],
            base: held,
        }),
    ) else {
        panic!("a stale settings copy must be refused");
    };
    assert!(matches!(refused, WriteRefused::Stale { .. }), "{refused:?}");
    assert_eq!(std::fs::read_to_string(&settings).unwrap(), newer);
    let (kept, _) = manifest::read_for_mutation(&manifest_path).unwrap();
    assert!(kept.unwrap().skill_instructions.is_empty());
}

/// A settings-only save carries no manifest draft: the scope reconciles to
/// the file as it sits, and the value goes in.
#[test]
fn a_settings_only_save_carries_no_manifest_draft() {
    let (tmp, env, scope) = scope_with_settings_skill();
    let settings = tmp.path().join("dev/app/kendex.settings.toml");
    write_customize(&env, scope.clone(), None, None).unwrap();
    assert!(!settings.exists(), "an install wrote nothing here");
    write_customize(
        &env,
        scope,
        None,
        Some(kendex_core::settings_file::SettingsDraft {
            edits: vec![edit("REVIEWERS", "arch")],
            base: Base::claimed(None),
        }),
    )
    .unwrap();
    let written = std::fs::read_to_string(&settings).unwrap();
    assert!(written.contains("REVIEWERS = \"arch\""), "{written}");
    assert!(
        written.contains("# Which reviewers run by default."),
        "the key arrives with the explainer the template ships: {written}"
    );
}

/// A project carrying a package that declares an uninstaller, installed
/// and on disk, with a manifest the editor can save a package out of.
///
/// No `writes` inside `.git`, so the disclosure's git stand-down does not
/// apply and no work tree is needed to prove what the removal runs.
#[cfg(unix)]
fn scope_carrying_a_declaring_package() -> (tempfile::TempDir, Env, Scope) {
    use std::os::unix::fs::PermissionsExt;
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), kendex_core::env::FakeOs::Linux);
    let project = tmp.path().join("dev/app");
    std::fs::create_dir_all(project.join(".claude")).unwrap();
    let catalog = tmp.path().join("catalog");
    let scripts = catalog.join("skills/guards/scripts");
    std::fs::create_dir_all(&scripts).unwrap();
    std::fs::write(
        catalog.join("skills/guards/SKILL.md"),
        "---\nname: guards\ndescription: gates the commits\n\
         repo-effects:\n  summary: \"gates every commit here\"\n  \
         installer: \"scripts/arm\"\n  uninstaller: \"scripts/arm --uninstall\"\n\
         ---\nBody.\n",
    )
    .unwrap();
    std::fs::write(
        scripts.join("arm"),
        "#!/bin/sh\ncase \" $* \" in *\" --uninstall \"*) echo 'guards: disarmed';; \
         *) echo 'guards: armed';; esac\n",
    )
    .unwrap();
    std::fs::set_permissions(scripts.join("arm"), std::fs::Permissions::from_mode(0o755)).unwrap();
    // An agent whose role gains a skill upstream between the two phases,
    // so a later plan writes the manifest itself. That write is the one op
    // binding `manifest_base`, and so the only way to drive a refusal that
    // lands after the uninstaller has already run.
    let skill = |name: &str| {
        std::fs::create_dir_all(catalog.join("skills").join(name)).unwrap();
        std::fs::write(
            catalog.join("skills").join(name).join("SKILL.md"),
            format!("---\nname: {name}\ndescription: skill {name}\n---\nBody.\n"),
        )
        .unwrap();
    };
    skill("recon");
    skill("probe");
    std::fs::create_dir_all(catalog.join("agents")).unwrap();
    std::fs::write(
        catalog.join("agents/rev.md"),
        "---\nname: rev\ndescription: agent rev\nrole: reviewer\n---\nBody.\n",
    )
    .unwrap();
    let role_skills = |carried: &str| {
        std::fs::write(
            catalog.join("kendex.toml"),
            format!("is_source_catalog = true\n\n[role-skills]\nreviewer = [{carried}]\n"),
        )
        .unwrap();
    };
    role_skills("\"recon\"");
    std::fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = {MANIFEST_SCHEMA}\n\n[sources.cat]\n{}\n\n\
             [install]\nharnesses = [\"claude\"]\n\n\
             [skills.guards]\nsource = \"cat\"\n\n[agents.rev]\nsource = \"cat\"\n\n\
             [skills.recon]\nsource = \"cat\"\n\n[agent-skills]\nrev = [\"recon\"]\n",
            source_path(&catalog)
        ),
    )
    .unwrap();
    // Install it, so the tree whose uninstaller a removal runs is on disk.
    write_customize(
        &env,
        Scope::Project {
            root: project.clone(),
        },
        None,
        None,
    )
    .unwrap();
    assert!(
        project.join(".agents/skills/guards/scripts/arm").is_file(),
        "the fixture did not install the package"
    );
    // And the role gains its second skill, so the next plan writes the
    // manifest itself — the one op that binds `manifest_base`, and so the
    // only way to drive a refusal landing AFTER the uninstaller has run.
    role_skills("\"recon\", \"probe\"");
    (tmp, env, Scope::Project { root: project })
}

/// Dropping a declaration is not the same as removing the package.
///
/// With orphan removal off, a package taken out of the manifest keeps its
/// lock entry and its files, so this save reconciles the declaration away
/// and runs nothing. That is a fact about THIS door only — a refused
/// rendering drops the entry regardless, which
/// `an_uninstaller_that_ran_before_a_refusal_is_still_reported` proves
/// below. Both are here because one of them used to stand for the whole
/// route, and a doc comment rested on it.
#[cfg(unix)]
#[test]
fn dropping_a_declaration_leaves_the_package_and_runs_nothing() {
    let (tmp, env, scope) = scope_carrying_a_declaring_package();
    let manifest_path = manifest::manifest_path(&env, &scope);
    let (current, base) = manifest::read_for_mutation(&manifest_path).unwrap();
    let mut edited = current.unwrap();
    edited.skills.remove("guards");

    let view = write_customize(&env, scope, Some((edited, base)), None).unwrap();

    assert!(
        view.undone.is_empty(),
        "the editor's save reported a removal it does not make: {:?}",
        view.undone
    );
    // And it really did leave the package's files alone — an empty account
    // over a removal that happened would be the defect, not the state.
    assert!(
        tmp.path()
            .join("dev/app/.agents/skills/guards/scripts/arm")
            .is_file(),
        "the save took the package off disk after all"
    );
}

/// The other door a package leaves by, and the one that makes the account
/// worth carrying through a refusal.
///
/// A refused rendering drops its lock entry whatever `remove_orphans`
/// says — `plan_refusals` re-inserts the entry on one arm only — so this
/// route can run an uninstaller without anybody asking for a removal. A
/// catalog tree carrying both spellings of its skill file is the cheapest
/// way to make the engine refuse one.
#[cfg(unix)]
fn scope_whose_package_stops_rendering(
    from: &(tempfile::TempDir, Env, Scope),
) -> std::path::PathBuf {
    let catalog = from.0.path().join("catalog");
    let disabled = catalog.join("skills/guards/SKILL.md.disabled");
    std::fs::write(
        &disabled,
        "---\nname: guards\ndescription: gates the commits\n---\n",
    )
    .unwrap();
    disabled
}

/// A refusal that lands after the uninstaller ran keeps its account.
///
/// This is the issue's own end state reached from the other direction: the
/// repository is disarmed, the write does not land, and a bare reload
/// notice would tell the person nothing happened. The lines ride on the
/// refusal instead.
#[cfg(unix)]
#[test]
fn an_uninstaller_that_ran_before_a_refusal_is_still_reported() {
    let held = scope_carrying_a_declaring_package();
    let (_tmp, env, scope) = (&held.0, &held.1, &held.2);
    scope_whose_package_stops_rendering(&held);

    // Planned and applied whole, the way the editor's save does: the
    // refused rendering drops the package, and its uninstaller runs.
    let view = crate::audit::apply_scope(env, scope, false).unwrap();

    assert_eq!(
        view.undone,
        vec![
            "guards: running scripts/arm --uninstall".to_owned(),
            "guards: disarmed".to_owned()
        ],
        "a refused rendering removed the package without saying what it ran"
    );
}

/// And the account survives the refusal itself.
///
/// The uninstaller runs before the plan writes, so a refusal landing after
/// that point is a refusal with a disarmed repository behind it. Dropping
/// the lines into a unit variant told the person only to reload, which is
/// the one shape where "nothing happened" is a lie — and it is this
/// issue's own end state reached from the other direction.
///
/// Driven through the real executor against a real moved precondition:
/// the manifest the plan binds is rewritten after the report is built, so
/// the apply rolls back with the uninstaller already run.
#[cfg(unix)]
#[test]
fn a_refusal_after_the_uninstaller_ran_still_carries_the_account() {
    let held = scope_carrying_a_declaring_package();
    let (_tmp, env, scope) = (&held.0, &held.1, &held.2);
    scope_whose_package_stops_rendering(&held);
    let path = manifest::manifest_path(env, scope);
    let (read, base) = manifest::read_for_mutation(&path).unwrap();
    let editor_copy = read.unwrap();
    let lock = load_lock(&lock_path(env, scope)).unwrap();
    let report = engine::plan_scope(
        env,
        scope,
        &editor_copy,
        &lock,
        &PlanOptions {
            manifest_base: Some(base),
            ..PlanOptions::default()
        },
    )
    .unwrap();
    assert!(
        !report.repo_effects_leaving.is_empty(),
        "the fixture built a report with nothing leaving"
    );

    // The writer in between: lands after the report was built, so the
    // apply rolls back on the precondition it bound.
    let original = std::fs::read_to_string(&path).unwrap();
    std::fs::write(
        &path,
        format!("{original}\n[skill-instructions]\nall = \"kept\"\n"),
    )
    .unwrap();

    let refused = crate::repo_effects::execute(env, &report).unwrap_err();
    let refused = refused_write(refused, std::slice::from_ref(&path));

    let undone = match refused {
        WriteRefused::Stale { undone } => undone,
        other => panic!("expected a stale refusal, got {other:?}"),
    };
    assert_eq!(
        undone,
        vec![
            "guards: running scripts/arm --uninstall".to_owned(),
            "guards: disarmed".to_owned(),
        ],
        "the refusal reported a reload over a repository it had just disarmed"
    );
}
