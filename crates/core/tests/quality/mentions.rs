//! Where a switch stands in a shell file: named, or used. One table over
//! the shapes the shipped guards write and the shapes an attacker would,
//! and one case that moves a guard's own operand out of its comment.

use kendex_core::model::ItemKind;
use kendex_core::quality::{AuditInput, AuditResult, Content, Publisher, audit};

use super::rules::{document, skill};

fn hook(script: &str) -> AuditResult {
    audit(AuditInput {
        kind: ItemKind::Hook,
        name: "guard".to_owned(),
        harness: None,
        publisher: Publisher::Other,
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
        (
            "echo \"rm -rf /\" > \"$out\"\n",
            &["dangerous-commands"],
            &[],
        ),
        (
            "echo \"rm -rf /\" >\"run.sh\"\n",
            &["dangerous-commands"],
            &[],
        ),
        ("x=$(echo \"rm -rf /\")\n", &["dangerous-commands"], &[]),
        ("run \"rm -rf /\"\n", &["dangerous-commands"], &[]),
        ("sh <<EOF\nrm -rf /\nEOF\n", &["dangerous-commands"], &[]),
        // A one-line function is judged on its own line, not the next.
        (
            "run() { eval \"$1\"; }\nrun \"rm -rf /\"\n",
            &["dangerous-commands"],
            &[],
        ),
        (
            "say() { echo \"$1\"; }\nsay \"rm -rf /\"\n",
            &[],
            &["dangerous-commands"],
        ),
        // A name redefined in the file is diagnostic only if both are.
        (
            "say() { echo \"$1\"; }\nsay() { eval \"$1\"; }\nsay \"rm -rf /\"\n",
            &["dangerous-commands"],
            &[],
        ),
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

/// A string is named only under a function every file of the tree defines
/// as one that only prints; the same call to a function that runs its
/// argument, in either file and in either order, is a use. The library
/// files are read with the script that calls them.
#[test]
fn a_string_handed_to_a_tree_function_is_named_only_when_that_function_only_prints() {
    let says = "say() {\n  printf '%s\\n' \"$*\" >&2\n}\n";
    let runs = "say() {\n  eval \"$*\"\n}\n";
    let script = "#!/usr/bin/env bash\n. \"$(dirname \"$0\")/lib.sh\"\nsay \"refused: rm -rf /\"\n";
    /// A case: its name, the library files, the rules that fire, the
    /// rules that read a mention.
    type Case<'a> = (
        &'a str,
        &'a [(&'a str, &'a str)],
        &'a [&'a str],
        &'a [&'a str],
    );
    let rows: &[Case] = &[
        (
            "prints",
            &[("scripts/lib.sh", says)],
            &[],
            &["dangerous-commands"],
        ),
        (
            "runs",
            &[("scripts/lib.sh", runs)],
            &["dangerous-commands"],
            &[],
        ),
        (
            "runs then prints",
            &[("scripts/a.sh", runs), ("scripts/b.sh", says)],
            &["dangerous-commands"],
            &[],
        ),
        (
            "prints then runs",
            &[("scripts/a.sh", says), ("scripts/b.sh", runs)],
            &["dangerous-commands"],
            &[],
        ),
    ];
    for (case, libs, flagged, named) in rows {
        let mut files = vec![("SKILL.md", "Run it.\n"), ("scripts/guard", script)];
        files.extend_from_slice(libs);
        let result = skill(&files);
        assert_eq!(
            rules(&result.findings),
            *flagged,
            "{case}: {:#?}",
            result.findings
        );
        assert_eq!(
            rules(&result.mentions),
            *named,
            "{case}: {:#?}",
            result.mentions
        );
    }
}

/// A test hands the launch lines it checks to its stubs and assertions as
/// data, and runs a switch only where it hands it to a program it does not
/// define or to a string a shell runs. One row per shape: the lines of
/// `tests/launch.sh`, which defines `check` and `run_case`, and whether
/// the switch there is a finding.
#[test]
fn a_test_hands_a_switch_to_its_stubs_as_data_and_runs_it_as_code() {
    let helpers = "#!/usr/bin/env bash\ncheck() { [ \"$2\" = \"$3\" ] || exit 1; }\nrun_case() { \"$LAUNCH\" \"$@\"; }\n";
    let rows: &[(&str, bool)] = &[
        ("BYPASS=\"claude --dangerously-skip-permissions\"", false),
        (
            "printf '%s\\n' \"claude --dangerously-skip-permissions\" > \"$stub\"",
            false,
        ),
        (
            "echo) printf '%s\\n' \"claude --dangerously-skip-permissions\" ;;",
            false,
        ),
        (
            "check launch \"$(cat \"$CAP\")\" \"claude --dangerously-skip-permissions\"",
            false,
        ),
        (
            "jq -n '{line: \"claude --dangerously-skip-permissions\"}' > \"$state\"",
            false,
        ),
        ("run_case walled -- --dangerously-skip-permissions", false),
        (
            "run_case walled \\\n  -- --dangerously-skip-permissions",
            false,
        ),
        (
            "check launch \\\n  \"claude --dangerously-skip-permissions\"",
            false,
        ),
        ("claude --dangerously-skip-permissions", true),
        ("\"$LAUNCH\" --dangerously-skip-permissions", true),
        ("claude \\\n  --dangerously-skip-permissions", true),
        ("eval \"claude --dangerously-skip-permissions\"", true),
        ("bash -c \"claude --dangerously-skip-permissions\"", true),
        (
            "# a comment \\\nclaude --dangerously-skip-permissions",
            true,
        ),
    ];
    for (body, runs) in rows {
        let result = skill(&[
            ("SKILL.md", "Run it.\n"),
            ("tests/lib.sh", helpers),
            ("tests/launch.sh", &format!("#!/usr/bin/env bash\n{body}\n")),
        ]);
        let (flagged, named): (&[&str], &[&str]) = match runs {
            true => (&["safety-bypass"], &[]),
            false => (&[], &["safety-bypass"]),
        };
        assert_eq!(
            rules(&result.findings),
            flagged,
            "{body:?}: {:#?}",
            result.findings
        );
        assert_eq!(
            rules(&result.mentions),
            named,
            "{body:?}: {:#?}",
            result.mentions
        );
    }
    // The same data outside a test directory is a file a harness loads
    // spelling the switch, and the reading stops at the tests.
    let script = skill(&[
        ("SKILL.md", "Run it.\n"),
        (
            "scripts/launch.sh",
            "#!/usr/bin/env bash\nBYPASS=\"claude --dangerously-skip-permissions\"\n",
        ),
    ]);
    assert_eq!(
        rules(&script.findings),
        vec!["safety-bypass"],
        "{:#?}",
        script.findings
    );
}

/// A markdown code span names a switch and not a destructive command: the
/// switch in backticks is a document describing it, the `rm -rf /` in
/// backticks is what a reader will paste.
#[test]
fn a_markdown_code_span_names_a_switch_but_not_a_destructive_command() {
    let result = document(
        ItemKind::Agent,
        "Never pass `--no-verify`. Clean up with `rm -rf /` first.\n",
    );
    assert_eq!(
        rules(&result.findings),
        vec!["dangerous-commands"],
        "{:#?}",
        result.findings
    );
    assert_eq!(
        rules(&result.mentions),
        vec!["safety-bypass"],
        "{:#?}",
        result.mentions
    );
}

/// A line that nests substitutions a hundred thousand deep, and a chain of
/// as many functions each calling the next, are judged as code on a small
/// stack rather than walked: the audit returns, and nothing reads as
/// named.
#[test]
fn nesting_past_the_bound_is_judged_not_walked() {
    let deep = format!(
        "#!/usr/bin/env bash\necho {}\"rm -rf /\"{}\n",
        "$(".repeat(100_000),
        ")".repeat(100_000)
    );
    let chain: String = (0..100_000)
        .map(|n| format!("f{n}() {{ f{}; }}\n", n + 1))
        .chain(["f0 \"rm -rf /\"\n".to_owned()])
        .collect();
    let audited = std::thread::Builder::new()
        .stack_size(2 * 1024 * 1024)
        .spawn(move || (hook(&deep), hook(&chain)))
        .expect("a thread")
        .join()
        .expect("the audit returns");
    for result in [audited.0, audited.1] {
        assert_eq!(
            rules(&result.findings),
            vec!["dangerous-commands"],
            "{:#?}",
            result.findings
        );
        assert_eq!(rules(&result.mentions), Vec::<&str>::new());
    }
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
