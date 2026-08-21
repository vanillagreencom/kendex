//! Two rules and the shapes they must not misread: a list of words a shell
//! parser skips, and a message that is about a file rather than about
//! something quoted from it.

use kendex_core::model::ItemKind;
use kendex_core::quality::Severity;

use super::rules::{document, severity_of, skill};

/// A `case` arm's pattern list is words a parser skips, not a command it
/// runs. Reading one as a command is the rule mistaking a list for an
/// instruction — and the fix for that is the rule, never a script written
/// in an order the matcher happens to miss.
#[test]
fn a_case_pattern_naming_sudo_is_not_running_sudo() {
    let pattern = document(
        ItemKind::Skill,
        "```sh\ncase \"$tok\" in\n  sudo | command | env) continue ;;\nesac\n```\n",
    );
    assert_eq!(severity_of(&pattern, "dangerous-commands"), None);

    // Only the pattern is exempt. An arm that runs something still reads as
    // running it, and a pattern is a list of single words — anything else
    // is a command line that happens to contain a bracket.
    let body = document(ItemKind::Skill, "  sudo) sudo rm -rf /tmp/x ;;\n");
    assert_eq!(
        severity_of(&body, "dangerous-commands"),
        Some(Severity::Medium)
    );
    let spaced = document(ItemKind::Skill, "  sudo rm $(ls) /etc/hosts\n");
    assert_eq!(
        severity_of(&spaced, "dangerous-commands"),
        Some(Severity::Medium)
    );
}
/// Two rules describe the file rather than quoting what they matched. A
/// decision binds to the rule and the sentence, so the sentence has to name
/// which file — otherwise one hidden character is shown, dismissed, and
/// silently settles another in a file nobody was told about, in the rule
/// whose whole job is surfacing content that is not what it looks like.
#[test]
#[allow(clippy::unwrap_used)]
fn a_finding_about_a_file_names_which_file() {
    let tree = skill(&[
        (
            "SKILL.md",
            "---\nname: t\ndescription: t\n---\n\nplain\u{200b}text\n",
        ),
        ("references/glossary.md", "other\u{200b}text\n"),
    ]);
    let obfuscated: Vec<&kendex_core::quality::Finding> = tree
        .findings
        .iter()
        .filter(|finding| finding.rule == "obfuscated-content")
        .collect();
    assert_eq!(obfuscated.len(), 2, "{:?}", tree.findings);
    assert_ne!(
        obfuscated[0].fingerprint(),
        obfuscated[1].fingerprint(),
        "two files are two questions"
    );
    assert!(
        obfuscated
            .iter()
            .any(|finding| finding.message.contains("glossary.md")),
        "{:?}",
        obfuscated
    );
}
