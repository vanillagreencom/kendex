//! Values an add supplies for declared keys (`kendex add --setting`): one
//! write with the seeds through the same settings pass, landing only where
//! the file assigns the key nowhere, and refused before anything is
//! written where no package here declares the key or the loaders would
//! not read the value.

use std::fs;

use kendex_core::apply;
use kendex_core::engine::ops::{self, AddRequest};
use kendex_core::engine::{EngineReport, PlanOptions, plan_scope};
use kendex_core::error::CoreError;
use kendex_core::model::Scope;
use kendex_core::settings_file::{SettingsRefusal, SuppliedSetting};

use super::scope::{Fixture, fixture};

/// The scope fixture with `review` not yet declared, so the add below is
/// the one that arrives it.
#[allow(clippy::unwrap_used)]
fn undeclared() -> Fixture {
    let f = fixture(true);
    let manifest = f.project.join("kendex.toml");
    let text = fs::read_to_string(&manifest).unwrap();
    let without = text.replace("\n[skills.review]\nsource = \"cat\"\nenabled = true\n", "");
    assert_ne!(
        without, text,
        "the fixture's review declaration was not found"
    );
    fs::write(&manifest, without).unwrap();
    f
}

fn supplied(pairs: &[(&str, &str)]) -> Vec<SuppliedSetting> {
    pairs
        .iter()
        .map(|(key, value)| SuppliedSetting {
            key: (*key).to_owned(),
            value: (*value).to_owned(),
        })
        .collect()
}

fn add(f: &Fixture, pairs: &[(&str, &str)]) -> Result<EngineReport, CoreError> {
    ops::add(
        &f.env,
        &f.scope,
        &AddRequest {
            source: Some("cat".to_owned()),
            skills: vec!["review".to_owned()],
            settings: supplied(pairs),
            ..AddRequest::default()
        },
    )
}

fn kept_note(report: &EngineReport, key: &str) -> bool {
    report.notes.iter().any(|note| {
        note.starts_with(&format!(
            "{key} keeps the value kendex.settings.toml already assigns it"
        ))
    })
}

/// What one row expects.
enum Want {
    /// The add plans; after its apply the file holds every line in
    /// `holds` and none in `lacks`, and the kept-value note for `DEPTH`
    /// is said exactly when `noted`.
    Written {
        holds: &'static [&'static str],
        lacks: &'static [&'static str],
        noted: bool,
    },
    /// The add is refused with this refusal, and the file is as it was.
    Refused(fn(&SettingsRefusal) -> bool),
}

/// The settings file before the add, the values it supplies, and what the
/// pass does with them.
type Row = (
    &'static str,
    Option<&'static str>,
    &'static [(&'static str, &'static str)],
    Want,
);

fn rows() -> [Row; 7] {
    [
        (
            "an unmarked key lands with the arriving skill's own seed",
            None,
            &[("DEPTH", "5")],
            Want::Written {
                holds: &["DEPTH = \"5\"", "REVIEWERS = \"arch,security\""],
                lacks: &[],
                noted: false,
            },
        ),
        (
            "a marked key lands with the supplied value in place of its default",
            None,
            &[("REVIEWERS", "mine")],
            Want::Written {
                holds: &["REVIEWERS = \"mine\""],
                lacks: &["arch,security"],
                noted: false,
            },
        ),
        (
            "an assigned value is kept and the kept value is said",
            Some("[env]\nDEPTH = \"3\"\n"),
            &[("DEPTH", "5")],
            Want::Written {
                holds: &["DEPTH = \"3\""],
                lacks: &["DEPTH = \"5\""],
                noted: true,
            },
        ),
        (
            "an assigned value the supply agrees with says nothing",
            Some("[env]\nDEPTH = \"5\"\n"),
            &[("DEPTH", "5")],
            Want::Written {
                holds: &["DEPTH = \"5\""],
                lacks: &[],
                noted: false,
            },
        ),
        (
            "an assignment outside [env] keeps the name too",
            Some("DEPTH = \"3\"\n\n[env]\n"),
            &[("DEPTH", "5")],
            Want::Written {
                holds: &["DEPTH = \"3\""],
                lacks: &["DEPTH = \"5\""],
                noted: true,
            },
        ),
        (
            "a key no package here declares is refused",
            None,
            &[("NOPE", "1")],
            Want::Refused(
                |refusal| matches!(refusal, SettingsRefusal::NotDeclaredHere { key } if key == "NOPE"),
            ),
        ),
        (
            "a value the loaders would not read is refused even where the file keeps its own",
            Some("[env]\nDEPTH = \"3\"\n"),
            &[("DEPTH", "a\"b")],
            Want::Refused(
                |refusal| matches!(refusal, SettingsRefusal::Value { key, .. } if key == "DEPTH"),
            ),
        ),
    ]
}

#[test]
#[allow(clippy::unwrap_used, clippy::panic)]
fn a_supplied_setting_lands_only_where_the_file_assigns_none() {
    for (name, before, pairs, want) in rows() {
        let f = undeclared();
        let path = f.project.join("kendex.settings.toml");
        if let Some(text) = before {
            fs::write(&path, text).unwrap();
        }
        let planned = add(&f, pairs);
        match want {
            Want::Written {
                holds,
                lacks,
                noted,
            } => {
                let report = planned.unwrap_or_else(|error| panic!("{name}: refused: {error}"));
                assert_eq!(
                    kept_note(&report, "DEPTH"),
                    noted,
                    "{name}: {:?}",
                    report.notes
                );
                apply::execute(&f.env, &report.plan).unwrap();
                let after = fs::read_to_string(&path).unwrap();
                for line in holds {
                    assert!(after.contains(line), "{name}: no {line} in\n{after}");
                }
                for line in lacks {
                    assert!(!after.contains(line), "{name}: {line} in\n{after}");
                }
            }
            Want::Refused(is) => {
                let refusal = match &planned {
                    Err(CoreError::SettingsRefused(refusal)) => refusal,
                    Err(other) => panic!("{name}: refused as {other}"),
                    Ok(report) => panic!("{name}: planned, saying {:?}", report.notes),
                };
                assert!(is(refusal), "{name}: refused as {refusal:?}");
                assert_eq!(fs::read_to_string(&path).ok().as_deref(), before, "{name}");
            }
        }
    }
}

/// Nothing global ships settings, so a supplied value there names a key
/// nothing at that scope declares.
#[test]
#[allow(clippy::unwrap_used, clippy::panic)]
fn a_supplied_setting_at_the_personal_scope_is_refused() {
    let f = fixture(true);
    let options = PlanOptions {
        supplied_settings: supplied(&[("DEPTH", "5")]),
        ..PlanOptions::current()
    };
    let refused = plan_scope(
        &f.env,
        &Scope::Global,
        &kendex_core::manifest::Manifest::default(),
        &kendex_core::lock::Lock::default(),
        &options,
    );
    let Err(CoreError::SettingsRefused(SettingsRefusal::NotDeclaredHere { key })) = &refused else {
        panic!("not refused as undeclared: {:?}", refused.err());
    };
    assert_eq!(key, "DEPTH");
}
