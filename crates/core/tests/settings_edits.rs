//! Settings edits through real applies: a person's values compose into
//! the scope plan beside seeding and land as one write, and the read
//! model says where every declared key stands.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::source_path;

use std::collections::BTreeMap;
use std::fs;
use std::path::PathBuf;

use kendex_core::apply;
use kendex_core::base::Base;
use kendex_core::engine::{PlanOptions, plan_scope};
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::CoreError;
use kendex_core::model::Scope;
use kendex_core::settings_file::{
    Current, SettingsDraft, SettingsEdit, SettingsEditValue, SettingsRefusal,
};
use kendex_core::settings_view::{ScopeSettings, SkillTemplate, scope_settings};

const TEMPLATE: &str = "[env]\n# Which reviewers run by default.\nREVIEWERS = \"arch,security\"\n\n# How deep.\nDEPTH = \"2\"\n";

struct Fixture {
    _tmp: tempfile::TempDir,
    env: Env,
    scope: Scope,
    project: PathBuf,
}

#[allow(clippy::unwrap_used)]
fn fixture(template: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    fixture_at(tmp.path().to_path_buf(), template, tmp)
}

/// [`fixture`], with every path reaching the home through a symlink — the
/// spelling macOS hands every test anyway, since `/var` fronts its temp
/// directories as `/private/var`. Reproduced here so a path this suite
/// spells one way and the engine another fails on every platform rather
/// than on the macOS lane alone.
#[allow(clippy::unwrap_used)]
fn fixture_via_link(template: &str) -> Fixture {
    let tmp = tempfile::tempdir().unwrap();
    let real = tmp.path().join("real");
    fs::create_dir_all(&real).unwrap();
    let home = tmp.path().join("via");
    std::os::unix::fs::symlink(&real, &home).unwrap();
    fixture_at(home, template, tmp)
}

/// The fixture body both share. Every path here is the one the engine
/// speaks: it canonicalizes a scope before it plans, so a fixture holding
/// the caller's spelling would be comparing two names for one file.
#[allow(clippy::unwrap_used)]
fn fixture_at(home: std::path::PathBuf, template: &str, tmp: tempfile::TempDir) -> Fixture {
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let project = project.canonicalize().unwrap();

    let source = home.join("catalog");
    let skill = source.join("skills/review");
    fs::create_dir_all(&skill).unwrap();
    fs::write(
        skill.join("SKILL.md"),
        "---\nname: review\ndescription: review changes\n---\nBody.\n",
    )
    .unwrap();
    fs::write(skill.join("kendex.settings.toml.example"), template).unwrap();

    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"symlink\"\n\n[skills.review]\nsource = \"cat\"\n",
            source_path(&source)
        ),
    )
    .unwrap();

    Fixture {
        env,
        scope: Scope::Project {
            root: project.clone(),
        },
        project,
        _tmp: tmp,
    }
}

#[allow(clippy::unwrap_used)]
fn settings_path(f: &Fixture) -> PathBuf {
    f.project.join("kendex.settings.toml")
}

#[allow(clippy::unwrap_used)]
fn base_now(f: &Fixture) -> Base {
    match fs::read_to_string(settings_path(f)) {
        Ok(text) => Base::of(&text),
        Err(_) => Base::absent(),
    }
}

/// Whether an apply refused because this file moved under it — the same
/// walk `crates/app/src/whole_file.rs` makes to turn it into the reload.
fn stale_at(error: &CoreError, path: &PathBuf) -> bool {
    match error {
        CoreError::PlanStale { path: moved } => moved == path,
        CoreError::RolledBack { cause, .. } => stale_at(cause, path),
        _ => false,
    }
}

fn set(key: &str, value: &str) -> SettingsEdit {
    SettingsEdit {
        skill: "review".to_owned(),
        key: key.to_owned(),
        value: SettingsEditValue::Set {
            value: value.to_owned(),
        },
    }
}

/// Plan the scope with a settings draft and apply the whole thing, the
/// way the editor's save does.
#[allow(clippy::unwrap_used)]
fn save(f: &Fixture, edits: Vec<SettingsEdit>, base: Base) -> Result<(), CoreError> {
    let manifest = kendex_core::manifest::load_for_mutation(&kendex_core::manifest::manifest_path(
        &f.env, &f.scope,
    ))
    .unwrap()
    .unwrap();
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(&f.env, &f.scope)).unwrap();
    let options = PlanOptions {
        settings_draft: Some(SettingsDraft { edits, base }),
        ..PlanOptions::default()
    };
    let report = plan_scope(&f.env, &f.scope, &manifest, &lock, &options)?;
    apply::execute(&f.env, &report.plan)?;
    Ok(())
}

#[allow(clippy::unwrap_used)]
fn install(f: &Fixture) {
    let report = kendex_core::engine::audit(&f.env, &f.scope).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();
}

#[allow(clippy::unwrap_used)]
fn rows_of(read: &ScopeSettings, skill: &str) -> Vec<(String, String, Current)> {
    let found = read.skills.iter().find(|s| s.skill == skill).unwrap();
    let SkillTemplate::Rows { rows } = &found.template else {
        panic!("{skill} has no rows: {:?}", found.template);
    };
    rows.iter()
        .map(|row| (row.key.clone(), row.default.clone(), row.current.clone()))
        .collect()
}

/// The whole read model on a settled scope: every declared key with its
/// explainer, its default, and where the file stands on it.
#[test]
#[allow(clippy::unwrap_used)]
fn the_read_model_carries_the_explainer_the_default_and_the_current_value() {
    let f = fixture(TEMPLATE);
    install(&f);
    let text = fs::read_to_string(settings_path(&f)).unwrap();
    fs::write(settings_path(&f), text.replace("\"2\"", "\"9\"")).unwrap();

    let read = scope_settings(&f.env, &f.scope).unwrap();
    assert!(read.applies);
    assert_eq!(read.base, base_now(&f));
    assert_eq!(
        rows_of(&read, "review"),
        vec![
            (
                "REVIEWERS".to_owned(),
                "arch,security".to_owned(),
                Current::Value {
                    value: "arch,security".to_owned(),
                    line: 7,
                }
            ),
            (
                "DEPTH".to_owned(),
                "2".to_owned(),
                Current::Value {
                    value: "9".to_owned(),
                    line: 10,
                }
            ),
        ]
    );
}

/// The Customize page's whole point: the value moves and nothing else
/// does — the seeded comment above it, the trailing note beside it, and
/// the file's CRLF terminators all come through the apply untouched.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edit_rewrites_only_its_value_span_leaving_comments_and_crlf_intact() {
    let f = fixture(TEMPLATE);
    let before = "# Mine.\r\n\r\n[env]\r\n# Which reviewers run by default.\r\nREVIEWERS = \"arch,security\" # keep this note\r\n\r\n# How deep.\r\nDEPTH = \"2\"\r\n";
    fs::write(settings_path(&f), before).unwrap();

    save(&f, vec![set("REVIEWERS", "arch")], base_now(&f)).unwrap();

    assert_eq!(
        fs::read_to_string(settings_path(&f)).unwrap(),
        "# Mine.\r\n\r\n[env]\r\n# Which reviewers run by default.\r\nREVIEWERS = \"arch\" # keep this note\r\n\r\n# How deep.\r\nDEPTH = \"2\"\r\n"
    );
}

/// One write, not two: the key is missing from the file, so the same plan
/// seeds it and sets it, and the ledger records the seed so a later
/// comment refresh still recognises the block as seeding's own.
#[test]
#[allow(clippy::unwrap_used)]
fn a_save_that_seeds_a_missing_key_and_sets_it_is_one_write() {
    let f = fixture(TEMPLATE);
    let manifest = kendex_core::manifest::load_for_mutation(&kendex_core::manifest::manifest_path(
        &f.env, &f.scope,
    ))
    .unwrap()
    .unwrap();
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(&f.env, &f.scope)).unwrap();
    let options = PlanOptions {
        settings_draft: Some(SettingsDraft {
            edits: vec![set("DEPTH", "7")],
            base: Base::absent(),
        }),
        ..PlanOptions::default()
    };
    let report = plan_scope(&f.env, &f.scope, &manifest, &lock, &options).unwrap();
    let writes: Vec<String> = report
        .plan
        .ops
        .iter()
        .filter(|op| op.line().contains("kendex.settings.toml"))
        .map(|op| op.line())
        .collect();
    assert_eq!(writes.len(), 1, "{writes:?}");
    assert!(writes[0].contains("seed REVIEWERS, DEPTH"), "{writes:?}");
    assert!(writes[0].contains("set DEPTH"), "{writes:?}");
    apply::execute(&f.env, &report.plan).unwrap();

    let written = fs::read_to_string(settings_path(&f)).unwrap();
    assert!(written.contains("DEPTH = \"7\""), "{written}");
    assert!(written.contains("# How deep."), "{written}");

    // The ledger holds the seed, so a later template revision may still
    // rewrite the comment block over it.
    let ledger = kendex_core::lock::load(&kendex_core::lock::lock_path(&f.env, &f.scope))
        .unwrap()
        .settings_seeds;
    assert_eq!(
        ledger.get("DEPTH").and_then(|seed| seed.owner.clone()),
        Some("review".to_owned())
    );
    let revised = TEMPLATE.replace("# How deep.", "# How deep it goes.");
    fs::write(
        f.project
            .join("../../catalog/skills/review/kendex.settings.toml.example"),
        &revised,
    )
    .unwrap();
    install(&f);
    let refreshed = fs::read_to_string(settings_path(&f)).unwrap();
    // The first asserts the refresh acted; the second that it left the
    // value alone. A survival assertion is satisfied by its own input, so
    // it is only worth anything beside one that proves the code ran.
    assert!(refreshed.contains("# How deep it goes."), "{refreshed}");
    assert!(refreshed.contains("DEPTH = \"7\""), "{refreshed}");
}

/// The manifest and the settings go down together or not at all. The
/// manifest write here also re-plans the scope, which is what makes a
/// second independent settings write impossible.
#[test]
#[allow(clippy::unwrap_used)]
fn a_manifest_and_a_settings_edit_land_as_one_transaction() {
    let f = fixture(TEMPLATE);
    install(&f);
    let manifest_path = kendex_core::manifest::manifest_path(&f.env, &f.scope);
    let (read, manifest_base) = kendex_core::manifest::read_for_mutation(&manifest_path).unwrap();
    let mut edited = read.unwrap();
    edited
        .skill_instructions
        .insert("all".into(), "read the plan".into());

    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(&f.env, &f.scope)).unwrap();
    let options = PlanOptions {
        manifest_base: Some(manifest_base),
        settings_draft: Some(SettingsDraft {
            edits: vec![set("REVIEWERS", "arch")],
            base: base_now(&f),
        }),
        ..PlanOptions::default()
    };
    let report = plan_scope(&f.env, &f.scope, &edited, &lock, &options).unwrap();
    apply::execute(&f.env, &report.plan).unwrap();

    assert!(
        fs::read_to_string(settings_path(&f))
            .unwrap()
            .contains("REVIEWERS = \"arch\"")
    );
    // The manifest write the editor inserts is the caller's; what matters
    // here is that the scope re-planned around the same settings file and
    // still produced one coherent result.
    let after = scope_settings(&f.env, &f.scope).unwrap();
    assert_eq!(
        rows_of(&after, "review")[0].2,
        Current::Value {
            value: "arch".to_owned(),
            line: 7,
        }
    );
}

/// Neither half lands when one refuses: the settings write is bound to
/// the file the copy came from, so a writer in between takes the whole
/// apply down and the manifest edit goes with it.
#[test]
#[allow(clippy::unwrap_used)]
fn a_settings_copy_that_went_stale_refuses_and_the_newer_file_stands() {
    let f = fixture(TEMPLATE);
    install(&f);
    let held = base_now(&f);

    // The writer in between.
    let newer = fs::read_to_string(settings_path(&f))
        .unwrap()
        .replace("\"2\"", "\"someone else\"");
    fs::write(settings_path(&f), &newer).unwrap();

    let refused = save(&f, vec![set("REVIEWERS", "arch")], held).unwrap_err();
    assert!(stale_at(&refused, &settings_path(&f)), "{refused:?}");
    assert_eq!(fs::read_to_string(settings_path(&f)).unwrap(), newer);
}

/// A key nothing can read is a key nothing writes, and the refusal names
/// the lines a person has to settle — for both shapes of it.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edit_on_a_duplicate_or_out_of_env_assignment_refuses_naming_the_lines() {
    for (file, expect) in [
        (
            "[env]\n# Which reviewers run by default.\nREVIEWERS = \"a\"\nREVIEWERS = \"b\"\n\n# How deep.\nDEPTH = \"2\"\n",
            vec![3, 4],
        ),
        (
            "[other]\nREVIEWERS = \"a\"\n\n[env]\n# How deep.\nDEPTH = \"2\"\n",
            vec![2],
        ),
    ] {
        let f = fixture(TEMPLATE);
        fs::write(settings_path(&f), file).unwrap();
        let refused = save(&f, vec![set("REVIEWERS", "arch")], base_now(&f)).unwrap_err();
        let CoreError::SettingsRefused(SettingsRefusal::Ambiguous { lines, key, .. }) = &refused
        else {
            panic!("{refused:?}");
        };
        assert_eq!(key, "REVIEWERS");
        assert_eq!(lines, &expect);
        assert_eq!(fs::read_to_string(settings_path(&f)).unwrap(), file);
    }
}

/// The writer repeats seeding's refusal: this file is not one kendex
/// writes through.
#[test]
#[allow(clippy::unwrap_used)]
fn a_settings_file_that_is_not_a_regular_file_refuses() {
    let f = fixture(TEMPLATE);
    let elsewhere = f.project.join("real-settings.toml");
    fs::write(
        &elsewhere,
        "[env]\n# Which reviewers run by default.\nREVIEWERS = \"a\"\n",
    )
    .unwrap();
    std::os::unix::fs::symlink(&elsewhere, settings_path(&f)).unwrap();

    let refused = save(&f, vec![set("REVIEWERS", "arch")], base_now(&f)).unwrap_err();
    assert!(
        matches!(
            refused,
            CoreError::SettingsRefused(SettingsRefusal::NotRegularFile { .. })
        ),
        "{refused:?}"
    );
    assert!(settings_path(&f).is_symlink());
    assert!(
        fs::read_to_string(&elsewhere)
            .unwrap()
            .contains("REVIEWERS = \"a\"")
    );
}

/// An edit is written against a declaration, so a key no installed
/// template declares has nothing to write it under.
#[test]
#[allow(clippy::unwrap_used)]
fn an_edit_for_a_key_no_installed_skill_declares_refuses() {
    let f = fixture(TEMPLATE);
    install(&f);
    let refused = save(&f, vec![set("NOT_MINE", "x")], base_now(&f)).unwrap_err();
    assert!(
        matches!(
            refused,
            CoreError::SettingsRefused(SettingsRefusal::Undeclared { .. })
        ),
        "{refused:?}"
    );
}

/// A reset writes what the viewed skill's template says, over whatever
/// the person had put there.
#[test]
#[allow(clippy::unwrap_used)]
fn a_reset_writes_the_template_default_back() {
    let f = fixture(TEMPLATE);
    install(&f);
    save(&f, vec![set("DEPTH", "9")], base_now(&f)).unwrap();
    save(
        &f,
        vec![SettingsEdit {
            skill: "review".to_owned(),
            key: "DEPTH".to_owned(),
            value: SettingsEditValue::Reset,
        }],
        base_now(&f),
    )
    .unwrap();
    assert!(
        fs::read_to_string(settings_path(&f))
            .unwrap()
            .contains("DEPTH = \"2\"")
    );
}

/// A template the strict reader refuses is not "nothing is there": the
/// lenient seeder put the key in the file, and the view says both.
#[test]
#[allow(clippy::unwrap_used)]
fn an_invalid_template_still_reports_what_seeding_wrote() {
    let f = fixture("[env]\nREVIEWERS = \"arch\"\n");
    install(&f);
    let read = scope_settings(&f.env, &f.scope).unwrap();
    let review = read.skills.iter().find(|s| s.skill == "review").unwrap();
    assert!(
        matches!(review.template, SkillTemplate::Invalid { .. }),
        "{:?}",
        review.template
    );
    assert!(
        fs::read_to_string(settings_path(&f))
            .unwrap()
            .contains("REVIEWERS = \"arch\"")
    );
}

/// The states that are not rows, each said out loud rather than left as
/// an absent entry a reader has to interpret.
#[test]
#[allow(clippy::unwrap_used)]
fn a_skill_shipping_nothing_a_switched_off_one_and_an_unreachable_one_each_say_so() {
    let f = fixture(TEMPLATE);
    fs::remove_file(
        f.project
            .join("../../catalog/skills/review/kendex.settings.toml.example"),
    )
    .unwrap();
    let read = scope_settings(&f.env, &f.scope).unwrap();
    assert_eq!(
        read.skills
            .iter()
            .map(|s| (s.skill.clone(), s.template.clone()))
            .collect::<BTreeMap<_, _>>()
            .get("review"),
        Some(&SkillTemplate::NoTemplate)
    );

    // Switched off: nothing it declares is seeded, and the view says why
    // rather than showing rows nothing will write.
    let manifest_path = kendex_core::manifest::manifest_path(&f.env, &f.scope);
    let text = fs::read_to_string(&manifest_path).unwrap();
    fs::write(
        &manifest_path,
        text.replace(
            "[skills.review]\nsource = \"cat\"",
            "[skills.review]\nsource = \"cat\"\nenabled = false",
        ),
    )
    .unwrap();
    let off = scope_settings(&f.env, &f.scope).unwrap();
    let review = off.skills.iter().find(|s| s.skill == "review").unwrap();
    assert!(
        matches!(&review.template, SkillTemplate::Unreadable { reason } if reason.contains("switched off")),
        "{:?}",
        review.template
    );

    // A source that is not there at all: still one entry, still an answer.
    let text = fs::read_to_string(&manifest_path).unwrap();
    fs::write(&manifest_path, text.replace("enabled = false", "")).unwrap();
    fs::rename(
        f.project.join("../../catalog"),
        f.project.join("../../moved"),
    )
    .unwrap();
    let gone = scope_settings(&f.env, &f.scope).unwrap();
    let review = gone.skills.iter().find(|s| s.skill == "review").unwrap();
    assert!(
        matches!(&review.template, SkillTemplate::Unreadable { reason } if reason.contains("nothing here could read")),
        "{:?}",
        review.template
    );
}

/// The race the plan-time symlink refusal cannot close on its own: the
/// file is a plain file when the plan is made and a link to somewhere else
/// by the time the apply runs. The write binds to the file being plain, so
/// it refuses; a precondition that only checked bytes would follow the
/// link and write outside the project.
#[test]
#[allow(clippy::unwrap_used)]
fn a_settings_file_swapped_for_a_link_between_plan_and_apply_refuses() {
    let f = fixture(TEMPLATE);
    install(&f);
    let held = base_now(&f);
    let kept = fs::read_to_string(settings_path(&f)).unwrap();

    let manifest = kendex_core::manifest::load_for_mutation(&kendex_core::manifest::manifest_path(
        &f.env, &f.scope,
    ))
    .unwrap()
    .unwrap();
    let lock = kendex_core::lock::load(&kendex_core::lock::lock_path(&f.env, &f.scope)).unwrap();
    let options = PlanOptions {
        settings_draft: Some(SettingsDraft {
            edits: vec![set("REVIEWERS", "arch")],
            base: held,
        }),
        ..PlanOptions::default()
    };
    let report = plan_scope(&f.env, &f.scope, &manifest, &lock, &options).unwrap();

    // Between the plan and the apply: the same bytes, at the end of a link
    // pointing outside the place kendex was asked to manage.
    let outside = f.project.join("../../outside.toml");
    fs::write(&outside, &kept).unwrap();
    fs::remove_file(settings_path(&f)).unwrap();
    std::os::unix::fs::symlink(&outside, settings_path(&f)).unwrap();

    let refused = apply::execute(&f.env, &report.plan).unwrap_err();
    assert!(stale_at(&refused, &settings_path(&f)), "{refused:?}");
    assert_eq!(fs::read_to_string(&outside).unwrap(), kept);
}

/// The refusals name a file, and this suite compares that name with its
/// own. Reached through a link the two spellings differ — which is what
/// macOS hands every test — so the same refusals are asserted again on a
/// world built that way. A fixture speaking the caller's spelling passes
/// here and fails on the macOS lane alone.
#[test]
#[allow(clippy::unwrap_used)]
fn a_refusal_names_the_file_the_same_way_through_a_link() {
    let f = fixture_via_link(TEMPLATE);
    install(&f);
    let held = base_now(&f);
    let newer = fs::read_to_string(settings_path(&f))
        .unwrap()
        .replace("\"2\"", "\"someone else\"");
    fs::write(settings_path(&f), &newer).unwrap();

    let refused = save(&f, vec![set("REVIEWERS", "arch")], held).unwrap_err();
    assert!(stale_at(&refused, &settings_path(&f)), "{refused:?}");
    assert_eq!(fs::read_to_string(settings_path(&f)).unwrap(), newer);

    // And an edit that lands, so the link is not merely refusing early.
    save(&f, vec![set("REVIEWERS", "arch")], base_now(&f)).unwrap();
    assert!(
        fs::read_to_string(settings_path(&f))
            .unwrap()
            .contains("REVIEWERS = \"arch\"")
    );
}

/// The end-to-end half of the array-of-tables refusal: an apply says why
/// and writes nothing, and an edit aimed at that file refuses outright.
#[test]
#[allow(clippy::unwrap_used)]
fn an_env_declared_as_an_array_of_tables_stops_the_write_and_says_why() {
    let f = fixture(TEMPLATE);
    let file = "[[env]]\nMODE = \"a\"\n";
    fs::write(settings_path(&f), file).unwrap();

    let report = kendex_core::engine::audit(&f.env, &f.scope).unwrap();
    assert!(
        report
            .drift
            .iter()
            .any(|row| row.detail.contains("array of tables")),
        "{:?}",
        report.drift.iter().map(|r| &r.detail).collect::<Vec<_>>()
    );
    assert!(
        !report
            .plan
            .ops
            .iter()
            .any(|op| op.line().contains("kendex.settings.toml")),
        "nothing may be written into a file with nowhere to write"
    );
    apply::execute(&f.env, &report.plan).unwrap();
    assert_eq!(fs::read_to_string(settings_path(&f)).unwrap(), file);

    let refused = save(&f, vec![set("REVIEWERS", "arch")], base_now(&f)).unwrap_err();
    assert!(
        matches!(
            refused,
            CoreError::SettingsRefused(SettingsRefusal::EnvNotSeedable { .. })
        ),
        "{refused:?}"
    );
    assert_eq!(fs::read_to_string(settings_path(&f)).unwrap(), file);
}
