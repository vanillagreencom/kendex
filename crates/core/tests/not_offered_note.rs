//! A declaration the catalog does not carry is refused with a note that
//! names what the source offers of that kind, so a manifest still carrying
//! a name the catalog retired reads its remedy where it is refused.
#![cfg(unix)]

#[path = "../../test_util.rs"]
mod test_util;
use test_util::{rooted, source_path};

use std::fs;

use kendex_core::engine::audit;
use kendex_core::env::{Env, FakeOs};
use kendex_core::model::Scope;

const SKILL: &str = "---\nname: NAME\ndescription: Use NAME.\n---\n\nSteps.\n";

#[allow(clippy::unwrap_used)]
fn notes_for(declared: &str) -> Vec<String> {
    notes_for_catalog(declared, &["deploy", "review"])
}

#[allow(clippy::unwrap_used)]
fn notes_for_catalog(declared: &str, offered: &[&str]) -> Vec<String> {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    let project = home.join("dev/app");
    fs::create_dir_all(project.join(".claude")).unwrap();
    let source = home.join("catalog");
    fs::create_dir_all(source.join("skills")).unwrap();
    for name in offered {
        fs::create_dir_all(source.join("skills").join(name)).unwrap();
        fs::write(
            source.join("skills").join(name).join("SKILL.md"),
            SKILL.replace("NAME", name),
        )
        .unwrap();
    }
    fs::write(source.join("kendex.toml"), "is_source_catalog = true\n").unwrap();
    fs::write(
        project.join("kendex.toml"),
        format!(
            "schema = 6\n\n[sources.cat]\n{}\n\n[install]\nharnesses = [\"claude\"]\nmethod = \"copy\"\n\n[skills.{declared}]\nsource = \"cat\"\n",
            source_path(&source)
        ),
    )
    .unwrap();
    let scope = Scope::Project { root: project };
    audit(&env, &scope).unwrap().notes
}

#[test]
fn a_name_the_catalog_does_not_carry_is_refused_naming_what_it_offers() {
    let notes = notes_for("retired");
    let note = notes
        .iter()
        .find(|note| note.starts_with("retired: not found in source 'cat'"))
        .unwrap_or_else(|| panic!("no refusal note in {notes:?}"));
    assert!(
        note.ends_with("its skills are deploy, review; declare one of those"),
        "{note}"
    );
}

#[test]
fn a_catalog_offering_nothing_of_that_kind_says_so() {
    let notes = notes_for_catalog("retired", &[]);
    assert!(
        notes
            .iter()
            .any(|note| note == "retired: not found in source 'cat', which offers no skill"),
        "{notes:?}"
    );
}

#[test]
fn a_name_the_catalog_carries_gets_no_refusal_note() {
    let notes = notes_for("deploy");
    assert!(
        notes
            .iter()
            .all(|note| !note.contains("not found in source")),
        "{notes:?}"
    );
}
