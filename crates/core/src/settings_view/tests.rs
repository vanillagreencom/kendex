use super::*;
use crate::settings_file::sites;
use crate::settings_secret::{SecretState, read_of};

const TEMPLATE: &str = "[env]\n# How loud it is.\nMODE = \"quiet\"\n";

/// A private file standing in for the project's, so these tests drive the
/// view rather than the project checks.
fn private(text: Option<&str>) -> SecretsRead {
    read_of(text)
}

#[test]
fn a_skill_that_ships_nothing_and_one_nothing_could_read_are_told_apart() {
    assert_eq!(
        template_of(&TemplateSource::Absent, &[], &private(None), &[]),
        SkillTemplate::NoTemplate
    );
    assert_eq!(
        template_of(
            &TemplateSource::Unreadable("switched off".to_owned()),
            &[],
            &private(None),
            &[],
        ),
        SkillTemplate::Unreadable {
            reason: "switched off".to_owned(),
        }
    );
}

/// The state a naive reader gets wrong: the strict reader refuses this
/// template, and the lenient seeder still put `MODE` in the file. Saying
/// "invalid" must not be heard as "nothing is there", so the findings
/// carry their lines and the file is read all the same.
#[test]
fn an_invalid_template_reports_findings_with_their_lines() {
    let no_comment = "[env]\nMODE = \"quiet\"\n";
    let SkillTemplate::Invalid { findings } = template_of(
        &TemplateSource::Text(no_comment.to_owned()),
        &sites("[env]\nMODE = \"mine\"\n"),
        &private(None),
        &[],
    ) else {
        panic!("a template with no comment block is invalid");
    };
    assert_eq!(findings.len(), 1);
    assert_eq!(findings[0].line, 2);
    assert!(findings[0].problem.contains("no comment block"));
}

#[test]
fn a_clean_template_carries_its_explainer_default_and_where_the_file_stands() {
    let SkillTemplate::Rows { rows, .. } = template_of(
        &TemplateSource::Text(TEMPLATE.to_owned()),
        &sites("[env]\nMODE = \"mine\"\n"),
        &private(None),
        &[],
    ) else {
        panic!("a clean template has rows");
    };
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].key, "MODE");
    assert_eq!(rows[0].explainer, vec!["How loud it is.".to_owned()]);
    assert_eq!(rows[0].default, "quiet");
    assert_eq!(
        rows[0].current,
        Current::Value {
            value: "mine".to_owned(),
            line: 2,
        }
    );
}

#[test]
fn a_key_the_file_never_assigns_reads_as_absent() {
    let SkillTemplate::Rows { rows, .. } = template_of(
        &TemplateSource::Text(TEMPLATE.to_owned()),
        &[],
        &private(None),
        &[],
    ) else {
        panic!("a clean template has rows");
    };
    assert_eq!(rows[0].current, Current::Absent);
}

/// Global scope answers, rather than leaving the question open: a reader
/// asking "does this place have settings" gets false and an empty list,
/// never an empty list it has to guess the meaning of.
#[test]
fn global_scope_is_a_known_empty_answer() {
    let tmp = tempfile::tempdir().unwrap();
    let env = crate::env::Env::fake(tmp.path(), crate::env::FakeOs::Linux);
    let read = scope_settings(&env, &Scope::Global, None).unwrap();
    assert!(!read.applies);
    assert!(read.skills.is_empty());
    assert_eq!(read.base, Base::absent());
}

/// A package whose whole declaration is a credential has settings to
/// configure. A section that appeared only for public keys would leave
/// its field unreachable.
#[test]
fn a_secret_only_template_has_rows_of_its_own() {
    let SkillTemplate::Rows { rows, secrets } = template_of(
        &TemplateSource::Text("[secrets]\n# The API key.\nAPI_KEY = \"\" # required\n".to_owned()),
        &[],
        &private(Some("API_KEY='dummy'\n")),
        &[],
    ) else {
        panic!("a secret-only template has rows");
    };
    assert_eq!(rows, []);
    assert_eq!(secrets.len(), 1);
    assert_eq!(secrets[0].key, "API_KEY");
    assert!(secrets[0].required);
    assert_eq!(secrets[0].current, SecretState::Set);
}

/// The row says a key is set and never what it is set to: no member of
/// it can carry the value, and the whole read serialises without one.
#[test]
fn a_stored_secret_never_reaches_the_row() {
    let SkillTemplate::Rows { secrets, .. } = template_of(
        &TemplateSource::Text("[secrets]\n# The API key.\nAPI_KEY = \"\"\n".to_owned()),
        &[],
        &private(Some("API_KEY='sk-live-secret'\n")),
        &[],
    ) else {
        panic!("a secret-only template has rows");
    };
    let shown = serde_json::to_string(&secrets).unwrap();
    assert!(!shown.contains("sk-live-secret"), "{shown}");
}

/// A key nothing assigns is Not set; one nothing could check is Unknown,
/// which is never read as Not set — a person told a key is missing sets
/// it again, over whatever is there.
#[test]
fn an_unassigned_key_and_an_unreadable_file_are_told_apart() {
    let rows = |text: Option<&str>| {
        let SkillTemplate::Rows { secrets, .. } = template_of(
            &TemplateSource::Text("[secrets]\n# The API key.\nAPI_KEY = \"\"\n".to_owned()),
            &[],
            &private(text),
            &[],
        ) else {
            panic!("a secret-only template has rows");
        };
        secrets
    };
    assert_eq!(rows(None)[0].current, SecretState::NotSet);
    assert_eq!(rows(Some("OTHER='x'\n"))[0].current, SecretState::NotSet);
    // Assigned twice: the last line is what loads, so nothing here can
    // say which value a package would read.
    let twice = rows(Some("API_KEY='one'\nAPI_KEY='two'\n"));
    assert!(matches!(twice[0].current, SecretState::Unknown { .. }));
}

/// A key one package declares public and another declares secret is
/// offered by neither route: showing it under either would be an offer to
/// write a credential somewhere the other declaration forbids.
#[test]
fn a_contested_key_is_offered_by_neither_route() {
    let contested = crate::settings_secret::contested(
        &[
            (
                "one".to_owned(),
                TemplateSource::Text("[env]\n# Why.\nSHARED = \"\"\n".to_owned()),
            ),
            (
                "two".to_owned(),
                TemplateSource::Text("[secrets]\n# The key.\nSHARED = \"\"\n".to_owned()),
            ),
        ]
        .into_iter()
        .collect(),
    );
    assert_eq!(contested.len(), 1, "{contested:?}");
    let SkillTemplate::Rows { rows, secrets } = template_of(
        &TemplateSource::Text(
            "[env]\n# Why.\nSHARED = \"\"\n\n[secrets]\n# The key.\nOWN = \"\"\n".to_owned(),
        ),
        &[],
        &private(None),
        &contested,
    ) else {
        panic!("a clean template has rows");
    };
    assert_eq!(rows, []);
    assert_eq!(secrets.len(), 1);
    assert_eq!(secrets[0].key, "OWN");
}
