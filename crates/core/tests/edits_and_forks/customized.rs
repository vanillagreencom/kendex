//! A supported customization is not an edit: the project's own
//! instructions overlaid into a skill through the manifest, and a setting
//! value saved in the project's settings file, both change what a person
//! sees without touching the bytes kendex compares — so the package must
//! never be counted as edited, and a hand edit beside them still must.

use std::fs;

use super::*;

#[test]
#[allow(clippy::unwrap_used)]
fn a_settings_customized_package_is_not_edited_until_a_file_is_changed() {
    let w = world();
    write_skill(&w.upstream, "gh", "Upstream.");
    fs::write(
        w.upstream.join("skills/gh/kendex.settings.toml.example"),
        "[env]\n# Which reviewers run by default.\nREVIEWERS = \"arch\" # required\n",
    )
    .unwrap();
    commit(&w.upstream, "one");
    declare(
        &w,
        "[skills.gh]\nsource = \"cat\"\n\n[skill-instructions]\ngh = \"Run the project's own checks first.\"\n",
    );
    fs::write(
        w.home.join("app/kendex.settings.toml"),
        "[env]\nREVIEWERS = \"security\"\n",
    )
    .unwrap();
    sync_and_apply(&w);
    let rendered = fs::read_to_string(skill_file(&w)).unwrap();
    assert!(
        rendered.contains("Run the project's own checks first."),
        "the overlay is in the render: {rendered}"
    );

    let row = |report: &kendex_core::package::updates::UpdatesReport| {
        report
            .rows
            .iter()
            .find(|row| row.kind == ItemKind::Skill && row.name == "gh")
            .cloned()
            .unwrap()
    };
    let customized = row(&kendex_core::package::updates::updates(&w.env, &w.scope).unwrap());
    assert!(
        !customized.blocked_by_local_edit && customized.edited_harnesses.is_empty(),
        "{customized:?}"
    );

    // The must-fail control: a hand edit on top of the same customizations
    // is still an edit.
    fs::write(skill_file(&w), rendered + "My own line.\n").unwrap();
    let edited = row(&kendex_core::package::updates::updates(&w.env, &w.scope).unwrap());
    assert!(edited.blocked_by_local_edit, "{edited:?}");
    assert_eq!(edited.edited_harnesses, vec![HarnessId::Claude]);
}
