//! Optional selections, harness hold-backs, removal preconditions,
//! and preview-first refresh.

use super::*;

/// An optional dependency is installed when it is chosen and not otherwise,
/// and the choice — not what it pulled in — is what the manifest keeps.
#[test]
#[allow(clippy::unwrap_used)]
fn an_optional_dependency_installs_only_once_it_is_chosen() {
    let f = fixture("[skills.dev]\nsource = \"cat\"\n");
    skill(
        &f.source,
        "dev",
        "dependencies:\n  required: [github]\n  optional: [linear]\n",
    );
    skill(&f.source, "linear", "");
    apply_now(&f);
    assert!(!installed(&f, "linear"));

    fs::write(
        f.project.join("kendex.toml"),
        format!(
            "{}\n[optional-dependencies]\ndev = [\"linear\"]\n",
            fs::read_to_string(f.project.join("kendex.toml")).unwrap()
        ),
    )
    .unwrap();
    let report = plan_refresh(&f.env, &f.scope).unwrap();
    assert!(
        report
            .set_changes
            .iter()
            .any(|c| c.name == "linear" && c.direction == SetDirection::Add)
    );
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(installed(&f, "linear"));

    // The choice survives a refresh, and the item it brought in is recorded
    // as required, never as something the user asked for.
    let report = plan_refresh(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(installed(&f, "linear"));
    assert!(
        !lock_of(&f).entries["skill:linear:claude"]
            .reasons
            .contains(&Reason::Requested)
    );
}

/// A dependency its own declaration keeps off a tool is honored there, and
/// the item that needs it is told which tool will run without it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_dependency_held_back_from_a_tool_warns_the_item_that_needs_it() {
    let f = fixture(
        "[skills.dev]\nsource = \"cat\"\nharnesses = [\"claude\", \"codex\"]\n\n[skills.github]\nsource = \"cat\"\nharnesses = [\"claude\"]\n",
    );
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    let lock = lock_of(&f);
    assert!(lock.entries.contains_key("skill:dev:codex"));
    assert!(!lock.entries.contains_key("skill:github:codex"));
    assert!(
        report.warnings.iter().any(|w| {
            w.name == "dev" && w.message.contains("Codex") && w.message.contains("github")
        }),
        "{:?}",
        report.warnings
    );
}

/// A removal binds to what the preview showed (invariant 7): content edited
/// in between is never moved to the trash on the strength of a stale plan.
#[test]
#[allow(clippy::unwrap_used)]
fn a_file_changed_after_the_preview_aborts_its_removal() {
    let f = fixture("[skills.dev]\nsource = \"cat\"\nmethod = \"copy\"\n");
    apply_now(&f);
    let skill_md = f.project.join(".claude/skills/dev/SKILL.md");
    assert!(skill_md.is_file());

    let report = ops::remove(&f.env, &f.scope, &["dev".to_owned()], None, true).unwrap();
    fs::write(&skill_md, "edited after the preview\n").unwrap();
    let error = apply::execute(&f.env, &report.plan).unwrap_err();
    assert!(
        matches!(error, kendex_core::error::CoreError::RolledBack { .. }),
        "{error:?}"
    );
    assert_eq!(
        fs::read_to_string(&skill_md).unwrap(),
        "edited after the preview\n"
    );
}

/// Refresh sees the closure move in both directions, and says so before
/// anything is written.
#[test]
#[allow(clippy::unwrap_used)]
fn refresh_previews_what_upstream_added_and_took_away() {
    let f = fixture("[skills.dev]\nsource = \"cat\"\n");
    apply_now(&f);
    assert!(
        plan_refresh(&f.env, &f.scope)
            .unwrap()
            .set_changes
            .is_empty()
    );

    skill(
        &f.source,
        "dev",
        "dependencies:\n  required: [github, worktree]\n",
    );
    skill(&f.source, "worktree", "");
    let added = plan_refresh(&f.env, &f.scope).unwrap();
    assert_eq!(added.set_changes.len(), 1);
    assert_eq!(added.set_changes[0].name, "worktree");
    assert_eq!(added.set_changes[0].direction, SetDirection::Add);
    assert!(added.set_changes[0].reason.contains("required by"));
    apply::execute(&f.env, &added.plan).unwrap();

    skill(&f.source, "dev", "dependencies:\n  required: [github]\n");
    let dropped = plan_refresh(&f.env, &f.scope).unwrap();
    assert_eq!(dropped.set_changes.len(), 1);
    assert_eq!(dropped.set_changes[0].name, "worktree");
    assert_eq!(dropped.set_changes[0].direction, SetDirection::Remove);
    apply::execute(&f.env, &dropped.plan).unwrap();
    assert!(!installed(&f, "worktree"));
    assert!(installed(&f, "dev") && installed(&f, "github"));
}

/// A removal made while the catalog is offline sticks. What still wants an
/// item is written into the record when it is installed, so the plan can say
/// it has to stay removed with nothing to read — and the catalog coming back
/// does not undo it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_removal_made_while_the_catalog_is_offline_is_not_undone_by_its_return() {
    let f = fixture("[skills.dev]\nsource = \"cat\"\n\n[skills.github]\nsource = \"cat\"\n");
    apply_now(&f);
    assert!(installed(&f, "github"));

    let offline = f.source.with_extension("offline");
    fs::rename(&f.source, &offline).unwrap();
    let report = remove(&f, "github", false);
    assert!(!installed(&f, "github"));
    assert!(
        manifest_of(&f).is_suppressed(ItemKind::Skill, "github"),
        "the removal was not written down"
    );
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("cannot be read right now")),
        "{:?}",
        report.notes
    );

    fs::rename(&offline, &f.source).unwrap();
    let report = plan_refresh(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(
        !installed(&f, "github"),
        "the catalog's return brought it back"
    );
    assert!(
        audit(&f.env, &f.scope)
            .unwrap()
            .warnings
            .iter()
            .any(|w| w.name == "dev" && w.message.contains("missing required dependency"))
    );
}

/// The record is a cache, so a removal has to work without one too: with the
/// record deleted the catalogs still say what would come back, and the
/// removal is written down from that rather than quietly doing nothing.
#[test]
#[allow(clippy::unwrap_used)]
fn a_removal_is_written_down_with_the_record_deleted() {
    let f = fixture("[skills.dev]\nsource = \"cat\"\n\n[skills.github]\nsource = \"cat\"\n");
    apply_now(&f);
    fs::remove_file(lock_path(&f.env, &f.scope)).unwrap();

    remove(&f, "github", false);
    assert!(manifest_of(&f).is_suppressed(ItemKind::Skill, "github"));

    let report = plan_refresh(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(
        !lock_of(&f).entries.contains_key("skill:github:claude"),
        "a refresh took it back on"
    );
    assert!(installed(&f, "dev"));
}

/// A declaration and a recorded removal for one name contradict each other.
/// A removal only ever speaks for what would otherwise be derived, so the
/// declaration wins: the item installs, and nothing calls it missing while it
/// sits on disk.
#[test]
#[allow(clippy::unwrap_used)]
fn a_declared_skill_installs_and_reports_nothing_missing_when_it_is_also_kept_removed() {
    let f = fixture(
        "[skills.dev]\nsource = \"cat\"\n\n[skills.github]\nsource = \"cat\"\n\n[suppressed]\nskill = [\"github\"]\n",
    );
    let report = audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    assert!(installed(&f, "github"));
    assert!(
        !report
            .warnings
            .iter()
            .any(|w| w.message.contains("kept removed")),
        "{:?}",
        report.warnings
    );
    assert!(
        report
            .notes
            .iter()
            .any(|note| note.contains("github") && note.contains("declaration wins")),
        "{:?}",
        report.notes
    );
}

/// Two skills that require each other are walked more than once, because each
/// pass teaches the other one something new. What they have to report is
/// still reported once.
#[test]
#[allow(clippy::unwrap_used)]
fn skills_that_require_each_other_report_each_finding_once() {
    let f = fixture("[skills.dev]\nsource = \"cat\"\n");
    skill(
        &f.source,
        "dev",
        "dependencies:\n  required: [github, nowhere]\n",
    );
    skill(&f.source, "github", "dependencies:\n  required: [dev]\n");

    let said: Vec<String> = audit(&f.env, &f.scope)
        .unwrap()
        .warnings
        .iter()
        .filter(|w| w.message.contains("nowhere"))
        .map(|w| w.name.clone())
        .collect();
    assert_eq!(said, ["dev"]);

    // A dependency both of them require and the user took away: each says so,
    // and each says it once.
    let f = fixture("[skills.dev]\nsource = \"cat\"\n\n[suppressed]\nskill = [\"docs\"]\n");
    skill(
        &f.source,
        "dev",
        "dependencies:\n  required: [github, docs]\n",
    );
    skill(
        &f.source,
        "github",
        "dependencies:\n  required: [dev, docs]\n",
    );
    skill(&f.source, "docs", "");

    let said: Vec<String> = audit(&f.env, &f.scope)
        .unwrap()
        .warnings
        .iter()
        .filter(|w| w.message.contains("kept removed"))
        .map(|w| w.name.clone())
        .collect();
    assert_eq!(said, ["dev", "github"]);
}

/// A catalog that cannot be read this pass knows nothing about what needs
/// what, so it must not be the reason anything is uninstalled.
#[test]
#[allow(clippy::unwrap_used)]
fn an_unreadable_catalog_never_sweeps_a_dependency() {
    let f = fixture("[skills.dev]\nsource = \"cat\"\n");
    apply_now(&f);
    assert!(installed(&f, "github"));

    fs::rename(&f.source, f.source.with_extension("moved")).unwrap();
    let report = plan_refresh(&f.env, &f.scope).unwrap();
    assert!(report.set_changes.is_empty(), "{:?}", report.set_changes);
    apply::execute(&f.env, &report.plan).unwrap();
    assert!(installed(&f, "github") && installed(&f, "dev"));
}
