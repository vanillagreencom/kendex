//! The cross-project settings report: which saved values differ between
//! projects, read from every project layer, with no secret key in it and
//! an unreadable project named rather than counted.

use std::fs;
use std::path::{Path, PathBuf};

use kendex_core::env::{Env, FakeOs};
use kendex_core::settings_compare::{
    Answer, DifferingKey, Holder, KeyAnswer, Layer, Unread, compare_settings,
};

use super::{TEMPLATE, project_at};
use crate::test_util::rooted;

/// A home and its environment; every project in a test sits under it.
fn home() -> (tempfile::TempDir, PathBuf, Env) {
    let tmp = tempfile::tempdir().unwrap_or_else(|error| panic!("temporary home: {error}"));
    let home = rooted(&tmp);
    let env = Env::fake(&home, FakeOs::Linux);
    (tmp, home, env)
}

#[allow(clippy::unwrap_used)]
fn write(project: &Path, file: &str, text: &str) {
    let path = project.join(file);
    fs::create_dir_all(path.parent().unwrap()).unwrap();
    fs::write(path, text).unwrap();
}

fn value(value: &str, holders: &[(&Path, Layer)]) -> KeyAnswer {
    KeyAnswer {
        answer: Answer::Value(value.to_owned()),
        holders: holders
            .iter()
            .map(|(project, layer)| Holder {
                project: project.to_path_buf(),
                layer: layer.clone(),
            })
            .collect(),
    }
}

fn private() -> Layer {
    Layer::PrivateFile {
        file: ".env.local".to_owned(),
    }
}

/// Two projects agreeing and one differing: the key carries both values
/// and all three projects, and the key all three leave on the template
/// default is not reported.
#[test]
fn a_key_one_project_answers_differently_names_every_value_and_project() {
    let (_tmp, home, env) = home();
    let app = project_at(&home, "app", "review", TEMPLATE);
    let api = project_at(&home, "api", "review", TEMPLATE);
    let web = project_at(&home, "web", "review", TEMPLATE);
    write(&app, "kendex.settings.toml", "[env]\nDEPTH = \"3\"\n");
    write(&api, ".kendex/settings.toml", "[env]\nDEPTH = \"3\"\n");
    write(&web, "kendex.settings.toml", "[env]\nDEPTH = \"5\"\n");

    let compared = compare_settings(&env, &[app.clone(), api.clone(), web.clone()]);

    assert_eq!(compared.unread, Vec::new());
    assert_eq!(
        compared.differing,
        vec![DifferingKey {
            key: "DEPTH".to_owned(),
            answers: vec![
                value(
                    "3",
                    &[(&app, Layer::RootSettings), (&api, Layer::NestedSettings)]
                ),
                value("5", &[(&web, Layer::RootSettings)]),
            ],
        }]
    );
}

/// Identical tracked files, different private values: a reader of the
/// tracked files alone calls these two equal.
#[test]
fn identical_tracked_files_with_different_private_values_differ() {
    let (_tmp, home, env) = home();
    let app = project_at(&home, "app", "review", TEMPLATE);
    let api = project_at(&home, "api", "review", TEMPLATE);
    for project in [&app, &api] {
        write(project, "kendex.settings.toml", "[env]\nDEPTH = \"3\"\n");
    }
    write(&app, ".env.local", "DEPTH='4'\n");
    write(&api, ".env.local", "DEPTH='6'\n");

    let compared = compare_settings(&env, &[app.clone(), api.clone()]);

    assert_eq!(compared.unread, Vec::new());
    assert_eq!(
        compared.differing,
        vec![DifferingKey {
            key: "DEPTH".to_owned(),
            answers: vec![
                value("4", &[(&app, private())]),
                value("6", &[(&api, private())]),
            ],
        }]
    );
}

/// A worktree links its private file back to the main checkout. That link
/// is the project's own layout, which the loaders read, so the project is
/// compared on what the linked file says.
#[cfg(unix)]
#[test]
#[allow(clippy::unwrap_used)]
fn a_private_file_linked_from_another_checkout_is_read() {
    let (_tmp, home, env) = home();
    let main = project_at(&home, "main", "review", TEMPLATE);
    let tree = project_at(&home, "tree", "review", TEMPLATE);
    let web = project_at(&home, "web", "review", TEMPLATE);
    write(&main, ".env.local", "DEPTH='7'\n");
    std::os::unix::fs::symlink(main.join(".env.local"), tree.join(".env.local")).unwrap();
    write(&web, "kendex.settings.toml", "[env]\nDEPTH = \"3\"\n");

    let compared = compare_settings(&env, &[main.clone(), tree.clone(), web.clone()]);

    assert_eq!(compared.unread, Vec::new());
    assert_eq!(
        compared.differing,
        vec![DifferingKey {
            key: "DEPTH".to_owned(),
            answers: vec![
                value("3", &[(&web, Layer::RootSettings)]),
                value("7", &[(&main, private()), (&tree, private())]),
            ],
        }]
    );
}

/// A key declared as a credential is never read, in any project: not
/// where it is declared so, and not where another package declares it
/// public.
#[test]
fn a_secret_key_never_appears_whatever_its_private_values() {
    const VAULT: &str = "[env]\n# Mode.\nMODE = \"a\"\n\n[secrets]\n# The token.\nTOKEN = \"\"\n";
    const OPEN: &str = "[env]\n# The token, public here.\nTOKEN = \"x\"\n";
    let (_tmp, home, env) = home();
    let one = project_at(&home, "one", "vault", VAULT);
    let two = project_at(&home, "two", "vault", VAULT);
    let three = project_at(&home, "three", "open", OPEN);
    let four = project_at(&home, "four", "open", OPEN);
    write(&one, ".env.local", "TOKEN='alpha-secret'\nMODE='b'\n");
    write(&two, ".env.local", "TOKEN='bravo-secret'\n");
    write(&three, ".env.local", "TOKEN='charlie-secret'\n");
    write(&four, ".env.local", "TOKEN='delta-secret'\n");

    let compared = compare_settings(&env, &[one.clone(), two.clone(), three, four]);

    assert_eq!(compared.unread, Vec::new());
    // The comparison ran: the public key the same projects differ on is
    // there.
    assert_eq!(
        compared.differing,
        vec![DifferingKey {
            key: "MODE".to_owned(),
            answers: vec![
                value(
                    "a",
                    &[(
                        &two,
                        Layer::TemplateDefault {
                            skills: vec!["vault".to_owned()]
                        }
                    )]
                ),
                value("b", &[(&one, private())]),
            ],
        }]
    );
    let rendered = format!("{compared:?}");
    for secret in [
        "alpha-secret",
        "bravo-secret",
        "charlie-secret",
        "delta-secret",
    ] {
        assert!(!rendered.contains(secret), "a secret value was read");
    }
}

/// Each way a project cannot be read: it is named with its reason, and
/// the projects that can be read are still compared.
#[test]
fn an_unreadable_project_is_named_and_the_rest_are_compared() {
    type Plant = fn(&Path, &Path) -> PathBuf;
    type Expected = fn(&Unread) -> bool;
    let rows: [(&str, Plant, Expected); 4] = [
        (
            "a folder that is gone",
            |home, _| home.join("dev/gone"),
            |reason| matches!(reason, Unread::Folder { .. }),
        ),
        (
            "a settings file the loaders refuse",
            |_, bad| {
                write(
                    bad,
                    "kendex.settings.toml",
                    "[env]\nDEPTH = \"1\"\nDEPTH = \"2\"\n",
                );
                bad.to_path_buf()
            },
            |reason| matches!(reason, Unread::SettingsFile { file, .. } if file == "kendex.settings.toml"),
        ),
        (
            "a private file named outside the project",
            |_, bad| {
                write(
                    bad,
                    "kendex.settings.toml",
                    "[env]\nKENDEX_ENV_FILE = \"../elsewhere\"\n",
                );
                bad.to_path_buf()
            },
            |reason| matches!(reason, Unread::PrivateFile { .. }),
        ),
        (
            "a template the strict reader refuses",
            |home, _| project_at(home, "broken", "broken", "[env]\nNO_COMMENT = \"1\"\n"),
            |reason| matches!(reason, Unread::Template { skill, .. } if skill == "broken"),
        ),
    ];
    for (case, plant, expected) in rows {
        let (_tmp, home, env) = home();
        let app = project_at(&home, "app", "review", TEMPLATE);
        let api = project_at(&home, "api", "review", TEMPLATE);
        let bad = project_at(&home, "bad", "review", TEMPLATE);
        write(&api, "kendex.settings.toml", "[env]\nDEPTH = \"9\"\n");
        let bad = plant(&home, &bad);

        let compared = compare_settings(&env, &[app.clone(), bad.clone(), api.clone()]);

        assert_eq!(compared.unread.len(), 1, "{case}");
        assert_eq!(compared.unread[0].project, bad, "{case}");
        assert!(
            expected(&compared.unread[0].reason),
            "{case}: {:?}",
            compared.unread[0].reason
        );
        assert_eq!(
            compared.differing,
            vec![DifferingKey {
                key: "DEPTH".to_owned(),
                answers: vec![
                    value(
                        "2",
                        &[(
                            &app,
                            Layer::TemplateDefault {
                                skills: vec!["review".to_owned()]
                            }
                        )]
                    ),
                    value("9", &[(&api, Layer::RootSettings)]),
                ],
            }],
            "{case}"
        );
    }
}
