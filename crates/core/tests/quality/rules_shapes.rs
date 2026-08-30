//! One shape the dangerous-commands rule must not misread: a list of words
//! a shell parser skips.

use kendex_core::model::ItemKind;
use kendex_core::quality::Severity;

use super::rules::{document, severity_of};

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

    // Only the pattern is exempt, and only the pattern is cut: what follows
    // the `)` is read as the command it is. Nothing else on these lines can
    // fire the rule, so each one is the sudo body alone answering for
    // itself — the previous control said `rm -rf /`, which fires either way.
    let body = document(ItemKind::Skill, "  sudo) sudo apt-get update ;;\n");
    assert_eq!(
        severity_of(&body, "dangerous-commands"),
        Some(Severity::Medium)
    );
    let alternatives = document(
        ItemKind::Skill,
        "  sudo | command) sudo apt-get update ;;\n",
    );
    assert_eq!(
        severity_of(&alternatives, "dangerous-commands"),
        Some(Severity::Medium)
    );
    let spaced = document(ItemKind::Skill, "  sudo rm $(ls) /etc/hosts\n");
    assert_eq!(
        severity_of(&spaced, "dangerous-commands"),
        Some(Severity::Medium)
    );
}
