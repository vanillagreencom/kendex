//! Where a switch stands in a shell file: named, or used. One table over
//! the shapes the shipped guards write and the shapes an attacker would,
//! and one case that moves a guard's own operand out of its comment.

use kendex_core::model::ItemKind;
use kendex_core::quality::{AuditInput, AuditResult, Content, audit};

use crate::rules::skill;

fn hook(script: &str) -> AuditResult {
    audit(AuditInput {
        kind: ItemKind::Hook,
        name: "guard".to_owned(),
        harness: None,
        location: "hooks/guard.sh".to_owned(),
        content: Content::Hook {
            event: "PreToolUse".to_owned(),
            matcher: None,
            command: "bash hooks/guard.sh".to_owned(),
            values: None,
            script: Some(script.to_owned()),
        },
    })
}

fn rules(findings: &[kendex_core::quality::Finding]) -> Vec<&str> {
    findings.iter().map(|f| f.rule.as_str()).collect()
}

/// One row per shape: the script, the rules that fire, the rules that
/// read a mention instead.
#[test]
fn a_shell_line_names_a_switch_or_uses_it() {
    let rows: &[(&str, &[&str], &[&str])] = &[
        (
            "# refuses rm -rf / on sight\n",
            &[],
            &["dangerous-commands"],
        ),
        (
            "echo \"bypass with --no-verify\" >&2\n",
            &[],
            &["safety-bypass"],
        ),
        (
            "printf '%s\\n' 'never rm -rf /'\n",
            &[],
            &["dangerous-commands"],
        ),
        ("rm -rf /\n", &["dangerous-commands"], &[]),
        ("git commit --no-verify\n", &["safety-bypass"], &[]),
        ("bash -c 'rm -rf /'\n", &["dangerous-commands"], &[]),
        ("eval \"rm -rf /\"\n", &["dangerous-commands"], &[]),
        ("echo \"rm -rf /\" | sh\n", &["dangerous-commands"], &[]),
        ("echo \"rm -rf /\" > run.sh\n", &["dangerous-commands"], &[]),
        ("x=$(echo \"rm -rf /\")\n", &["dangerous-commands"], &[]),
        ("run \"rm -rf /\"\n", &["dangerous-commands"], &[]),
        ("sh <<EOF\nrm -rf /\nEOF\n", &["dangerous-commands"], &[]),
    ];
    for (body, flagged, named) in rows {
        let result = hook(&format!("#!/usr/bin/env bash\n{body}"));
        assert_eq!(
            rules(&result.findings),
            *flagged,
            "{body:?}: {:#?}",
            result.findings
        );
        assert_eq!(
            rules(&result.mentions),
            *named,
            "{body:?}: {:#?}",
            result.mentions
        );
    }
}

/// A string is named only under a function the tree defines as one that
/// only prints; the same call to a function that runs its argument is a
/// use. The library file is read with the script that calls it.
#[test]
fn a_string_handed_to_a_tree_function_is_named_only_when_that_function_only_prints() {
    let says = "say() {\n  printf '%s\\n' \"$*\" >&2\n}\n";
    let runs = "say() {\n  eval \"$*\"\n}\n";
    let script = "#!/usr/bin/env bash\n. \"$(dirname \"$0\")/lib.sh\"\nsay \"refused: rm -rf /\"\n";
    let named = skill(&[
        ("SKILL.md", "Run it.\n"),
        ("scripts/lib.sh", says),
        ("scripts/guard", script),
    ]);
    assert_eq!(
        rules(&named.findings),
        Vec::<&str>::new(),
        "{:#?}",
        named.findings
    );
    assert_eq!(rules(&named.mentions), vec!["dangerous-commands"]);
    let used = skill(&[
        ("SKILL.md", "Run it.\n"),
        ("scripts/lib.sh", runs),
        ("scripts/guard", script),
    ]);
    assert_eq!(
        rules(&used.findings),
        vec!["dangerous-commands"],
        "{:#?}",
        used.findings
    );
    assert_eq!(rules(&used.mentions), Vec::<&str>::new());
}

/// The shipped guard with its refused operand moved from the comment
/// that explains it into a line that runs it is flagged again.
#[test]
fn a_guard_whose_operand_moves_out_of_its_comment_is_flagged() {
    let path =
        std::path::Path::new(env!("CARGO_MANIFEST_DIR")).join("../../hooks/block-unsafe-rm.sh");
    let shipped =
        std::fs::read_to_string(&path).unwrap_or_else(|why| panic!("{}: {why}", path.display()));
    let comment = shipped
        .lines()
        .find(|line| line.trim_start().starts_with('#') && line.contains("rm -rf /"))
        .expect("the guard's comment names the operand it refuses");
    assert_eq!(rules(&hook(&shipped).findings), Vec::<&str>::new());
    let moved = shipped.replacen(comment, "rm -rf /var/tmp/x", 1);
    assert_eq!(rules(&hook(&moved).findings), vec!["dangerous-commands"]);
}
