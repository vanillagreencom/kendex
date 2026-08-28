use super::*;
use crate::settings_file::sites;

const TEMPLATE: &str = "[env]\n# How loud it is.\nMODE = \"quiet\"\n";

#[test]
fn a_skill_that_ships_nothing_and_one_nothing_could_read_are_told_apart() {
    assert_eq!(
        template_of(&TemplateSource::Absent, &[]),
        SkillTemplate::NoTemplate
    );
    assert_eq!(
        template_of(&TemplateSource::Unreadable("switched off".to_owned()), &[]),
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
    ) else {
        panic!("a template with no comment block is invalid");
    };
    assert_eq!(findings.len(), 1);
    assert_eq!(findings[0].line, 2);
    assert!(findings[0].problem.contains("no comment block"));
}

#[test]
fn a_clean_template_carries_its_explainer_default_and_where_the_file_stands() {
    let SkillTemplate::Rows { rows } = template_of(
        &TemplateSource::Text(TEMPLATE.to_owned()),
        &sites("[env]\nMODE = \"mine\"\n"),
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
    let SkillTemplate::Rows { rows } = template_of(&TemplateSource::Text(TEMPLATE.to_owned()), &[])
    else {
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
    let read = scope_settings(&env, &Scope::Global).unwrap();
    assert!(!read.applies);
    assert!(read.skills.is_empty());
    assert_eq!(read.base, Base::absent());
}
