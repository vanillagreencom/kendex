//! The switch that turns a check off, and where on a line it counts.
//!
//! Split out of `rules.rs`. One rule, and the shapes of quoting, block
//! structure and argument passing it has to read correctly before it can
//! say a program was handed the switch.

use kendex_core::model::ItemKind;
use kendex_core::quality::Severity;

use super::rules::{document, rules_hit, severity_of, skill};

#[test]
fn safety_bypass_separates_a_switch_that_disables_a_check_from_prose_about_one() {
    let switch = document(ItemKind::Skill, "commit with git commit --no-verify\n");
    assert_eq!(
        severity_of(&switch, "safety-bypass"),
        Some(Severity::Critical)
    );

    let prose = document(
        ItemKind::Skill,
        "You may bypass safety when the build is green\n",
    );
    assert_eq!(severity_of(&prose, "safety-bypass"), Some(Severity::High));
}

/// A switch counts where the line would hand it to a program and nowhere
/// else. Each shape here is one a real guard writes: the flag named in
/// backticks, the message a hook prints, the `case` arm that catches it,
/// the comment above the check. The control is the last one — a line that
/// actually runs `git commit` with it — because a reading that stopped
/// flagging the switch everywhere would pass the other four and leave the
/// rule saying nothing.
#[test]
fn safety_bypass_reads_a_switch_only_where_a_line_would_run_it() {
    for (shape, files) in [
        (
            "named in prose",
            [("SKILL.md", "The bypass is `git commit --no-verify`.\n")],
        ),
        (
            "printed by a hook",
            [(
                "scripts/pre-commit",
                "echo \"blocked; bypass with 'git commit --no-verify'\"\n",
            )],
        ),
        (
            "caught by a case arm",
            [("scripts/pre-commit", "    --no-verify|-n) refuse ;;\n")],
        ),
        (
            "explained by a comment",
            [(
                "scripts/pre-commit",
                "# refuse a commit that passes --no-verify\n",
            )],
        ),
    ] {
        let result = skill(&files);
        assert!(
            !rules_hit(&result).contains(&"safety-bypass"),
            "{shape}: {:?}",
            result.findings
        );
    }

    let run = skill(&[("SKILL.md", "```sh\ngit commit --no-verify -m done\n```\n")]);
    assert_eq!(
        severity_of(&run, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        run.findings
    );
}

/// One innocent mention must not cover a use standing beside it: the rule
/// reads every occurrence on the line, not the first.
#[test]
fn safety_bypass_reads_past_a_mention_to_the_use_behind_it() {
    let result = skill(&[(
        "scripts/pre-commit",
        "echo 'never --no-verify'; git commit --no-verify -m done\n",
    )]);
    assert_eq!(
        severity_of(&result, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        result.findings
    );
}

/// A backtick that closes nothing quotes nothing. Markdown ends a run of
/// backticks only on a run of the same length, so an opener with no match
/// is literal text — and treating it as a toggle would let one stray
/// backtick hide every switch after it on the line, which is this rule
/// going quiet in a score somebody installs on.
#[test]
fn safety_bypass_still_reads_a_switch_after_a_backtick_that_closes_nothing() {
    let result = skill(&[(
        "SKILL.md",
        "Prefer `git commit -m done over git commit --no-verify -m done.\n",
    )]);
    assert_eq!(
        severity_of(&result, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        result.findings
    );
}

/// A span opened by two backticks holds single ones as its own text, which
/// is how markdown writes a backtick at all. Reading the inner one as the
/// close reports the rest of the span as though it stood in the open.
#[test]
fn safety_bypass_leaves_a_backtick_quoted_inside_a_longer_span() {
    let result = skill(&[(
        "SKILL.md",
        "The shape is ``git commit` --no-verify`` in a doc.\n",
    )]);
    assert!(
        !rules_hit(&result).contains(&"safety-bypass"),
        "{:?}",
        result.findings
    );
}

/// The line an indented block opens on is the block's own text, the same
/// as the line under it. Reading it as prose made a `#` an ordinary
/// character on the first line and a comment on the second, so a one-line
/// block warning against the switch scored Critical where the same words
/// with a second line under them scored nothing.
///
/// The control is the third case: the block's text is still read, and a
/// line handing the switch to git counts wherever it is indented.
#[test]
fn safety_bypass_reads_the_line_an_indented_block_opens_on_as_code() {
    let one = skill(&[("SKILL.md", "Refuse it:\n\n    # never pass --no-verify\n")]);
    assert!(
        !rules_hit(&one).contains(&"safety-bypass"),
        "{:?}",
        one.findings
    );

    let two = skill(&[(
        "SKILL.md",
        "Refuse it:\n\n    # never pass --no-verify\n    exit 1\n",
    )]);
    assert_eq!(rules_hit(&two), rules_hit(&one), "{:?}", two.findings);

    let run = skill(&[(
        "SKILL.md",
        "Never do this:\n\n    git commit --no-verify -m done\n",
    )]);
    assert_eq!(
        severity_of(&run, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        run.findings
    );
}

/// A code span closes on a later line of the same paragraph. Read one line
/// at a time the opener meets no match on its own line and the close meets
/// none on the next, so the switch quoted between them was reported as one
/// the line hands to a program.
///
/// The control is the second case: the reach is the paragraph, not the
/// document. A backtick whose partner stands past a blank line quotes
/// nothing, and the switch beside it still counts.
#[test]
fn safety_bypass_leaves_a_switch_quoted_by_a_span_that_crosses_a_newline() {
    let across = skill(&[(
        "SKILL.md",
        "The bypass is `git commit\n--no-verify`, which this never runs.\n",
    )]);
    assert!(
        !rules_hit(&across).contains(&"safety-bypass"),
        "{:?}",
        across.findings
    );

    let apart = skill(&[(
        "SKILL.md",
        "The bypass is `git commit\n\n--no-verify` runs it.\n",
    )]);
    assert_eq!(
        severity_of(&apart, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        apart.findings
    );
}

/// The shell takes its quote marks out before it builds the argument
/// list, so a quoted switch reaches the program exactly as a bare one
/// does. Reading a position rather than an argument scored this line
/// clean while the switch was being handed straight to git.
///
/// Three must-fail halves, and they are what keeps the reading honest.
/// The same quote marks around a sentence hand `echo` a sentence, and a
/// sentence turns off no check. A comment is still dead text however its
/// words are quoted. And a markdown code span is markdown's quotation,
/// not the shell's, so a command written into prose is still prose.
#[test]
fn safety_bypass_reads_a_switch_a_program_is_handed_inside_quotes() {
    let handed = skill(&[("scripts/pre-commit", "git commit -m done \"--no-verify\"\n")]);
    assert_eq!(
        severity_of(&handed, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        handed.findings
    );

    let said = skill(&[("scripts/pre-commit", "echo \"use --no-verify to skip\"\n")]);
    assert!(
        !rules_hit(&said).contains(&"safety-bypass"),
        "{:?}",
        said.findings
    );

    let commented = skill(&[(
        "scripts/pre-commit",
        "# never write git commit \"--no-verify\"\n",
    )]);
    assert!(
        !rules_hit(&commented).contains(&"safety-bypass"),
        "{:?}",
        commented.findings
    );

    let in_a_span = skill(&[(
        "SKILL.md",
        "The shape is `git commit \"--no-verify\"` in a doc.\n",
    )]);
    assert!(
        !rules_hit(&in_a_span).contains(&"safety-bypass"),
        "{:?}",
        in_a_span.findings
    );
}

/// An interpreter is handed a command line rather than an operand, so
/// what stands inside the quotes is what the inner shell runs. Three ways
/// to reach one, and every one of them hands git the same switch.
///
/// The must-fail half is the fourth case: a program that is not an
/// interpreter is handed a sentence, and the words inside it stay words.
#[test]
fn safety_bypass_reads_a_switch_inside_a_command_string() {
    for reached in [
        "eval \"git commit --no-verify -m done\"\n",
        "sh -c \"git commit --no-verify -m done\"\n",
        "ssh build.example \"git commit --no-verify -m done\"\n",
    ] {
        let result = skill(&[("scripts/pre-commit", reached)]);
        assert_eq!(
            severity_of(&result, "safety-bypass"),
            Some(Severity::Critical),
            "{reached}: {:?}",
            result.findings
        );
    }

    let printed = skill(&[(
        "scripts/pre-commit",
        "printf '%s\\n' \"git commit --no-verify -m done\"\n",
    )]);
    assert!(
        !rules_hit(&printed).contains(&"safety-bypass"),
        "{:?}",
        printed.findings
    );
}

/// A heading is a block of its own, so a run of backticks left open at the
/// end of one does not reach the paragraph under it. Joining the two into
/// a single run paired those stray backticks, and the switch standing
/// between them read as quoted: one unmatched backtick on each of two
/// lines, and a line telling a reader to hand git the switch scored
/// nothing.
#[test]
fn safety_bypass_reads_a_switch_a_heading_keeps_out_of_a_span() {
    let result = skill(&[(
        "SKILL.md",
        "# Committing past the `hook\nPass --no-verify` when it complains.\n",
    )]);
    assert_eq!(
        severity_of(&result, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        result.findings
    );
}

/// A heading underlined with `=` is the same block boundary written the
/// other way round, and the underline closes it. A run reaching past that
/// paired the two stray backticks and swallowed the line under it.
#[test]
fn safety_bypass_reads_a_switch_a_setext_heading_keeps_out_of_a_span() {
    let result = skill(&[(
        "SKILL.md",
        "Committing past the `hook\n=========================\nPass --no-verify` when it complains.\n",
    )]);
    assert_eq!(
        severity_of(&result, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        result.findings
    );
}

/// Each list item is a block of its own, so a backtick left open in one
/// does not reach the next. A line carrying no marker continues the item
/// above it, which is the second case: a span still crosses the newline
/// inside one item.
#[test]
fn safety_bypass_reads_a_switch_a_list_item_keeps_out_of_a_span() {
    let items = skill(&[(
        "SKILL.md",
        "- Write `git commit\n- Pass --no-verify` to git.\n",
    )]);
    assert_eq!(
        severity_of(&items, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        items.findings
    );

    let one = skill(&[(
        "SKILL.md",
        "- The bypass is `git commit\n  --no-verify`, which this never runs.\n",
    )]);
    assert!(
        !rules_hit(&one).contains(&"safety-bypass"),
        "{:?}",
        one.findings
    );
}

/// A blockquote is a block whether or not a blank line precedes it, so a
/// backtick in the prose above one does not reach into it. Its findings
/// still weigh one severity less, which is what a quotation is worth.
///
/// The control is the second case: two quoted lines are one block, so a
/// span opened on the first still closes on the second.
#[test]
fn safety_bypass_reads_a_switch_a_blockquote_keeps_out_of_a_span() {
    let into = skill(&[(
        "SKILL.md",
        "Write `git commit\n> Pass --no-verify` to git.\n",
    )]);
    assert_eq!(
        severity_of(&into, "safety-bypass"),
        Some(Severity::High),
        "{:?}",
        into.findings
    );

    let within = skill(&[(
        "SKILL.md",
        "> The bypass is `git commit\n> --no-verify`, which this never runs.\n",
    )]);
    assert!(
        !rules_hit(&within).contains(&"safety-bypass"),
        "{:?}",
        within.findings
    );
}

/// A backslash-escaped backtick is the character, not a delimiter. Reading
/// it as one let a pair of them quote the switch between, which is the
/// same silence one character smaller.
#[test]
fn safety_bypass_reads_a_switch_between_escaped_backticks() {
    let result = skill(&[(
        "SKILL.md",
        "Write \\`git commit --no-verify\\` and run it.\n",
    )]);
    assert_eq!(
        severity_of(&result, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        result.findings
    );
}

/// Switching an item off parks its file under a `.disabled` suffix and
/// changes nothing about what the file is. A disabled artifact that scored
/// differently would mean disabling something invented findings in it.
#[test]
fn a_disabled_markdown_artifact_scores_as_its_enabled_twin() {
    let body = "The bypass is `git commit --no-verify`, which this never runs.\n";
    let on = skill(&[("SKILL.md", body)]);
    let off = skill(&[("SKILL.md.disabled", body)]);
    assert!(
        !rules_hit(&off).contains(&"safety-bypass"),
        "{:?}",
        off.findings
    );
    assert_eq!(rules_hit(&off), rules_hit(&on));
    assert_eq!(off.safety.score, on.safety.score);
}

/// A `#` opens a comment wherever a word can start, and a shell operator
/// ends a word as surely as a space does. Every longer operator ends in
/// one of these characters, so the byte before the `#` settles it.
#[test]
fn safety_bypass_reads_a_comment_that_opens_after_an_operator() {
    for op in [";", "&&", "||", "|", "&", ">", "<", "(", ")"] {
        let text = format!("true{op}# never pass --no-verify\n");
        let result = skill(&[("scripts/pre-commit", text.as_str())]);
        assert!(
            !rules_hit(&result).contains(&"safety-bypass"),
            "{op}: {:?}",
            result.findings
        );
    }

    // Nothing else ends a word. After `}` the `#` is one more byte of the
    // word being built, and the switch behind it is still an argument this
    // line hands to a program.
    let word = skill(&[("scripts/pre-commit", "true}# never pass --no-verify\n")]);
    assert_eq!(
        severity_of(&word, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        word.findings
    );
}

/// Flags that ordinary tools carry say nothing on their own. The kendex
/// `github` skill uses `--force` forty-two times, every one of them about
/// its own documented override, and `--yes` is in every non-interactive
/// install line there is.
#[test]
fn safety_bypass_leaves_ordinary_tool_flags_alone() {
    let result = document(
        ItemKind::Skill,
        "git push --force-with-lease\napt install --yes ripgrep\n  --force          Skip checks\n",
    );
    assert!(
        !rules_hit(&result).contains(&"safety-bypass"),
        "{:?}",
        result.findings
    );
}

/// Which operand carries the command line is a position, and reaching it
/// means reading the two pieces of syntax the shell reads. A launcher
/// stands between the line and the interpreter — `env bash -c …` runs bash
/// — and an option letter travels in a bundle, where `-lc` is `-c` with an
/// `-l` in front of it. A reading that looked for a standalone `-c` after
/// a top-level interpreter found neither, and the switch went past.
///
/// The must-fail half is the last case, and it is what says the bundle is
/// read rather than listed. `c` takes the command line as its value, so in
/// `-cl` that value is the `l` beside it and the word after is only `$0`:
/// the shell runs a command called `l` and never the words quoted next to
/// it.
#[test]
fn safety_bypass_reaches_a_command_string_past_a_launcher_and_inside_a_bundle() {
    for reached in [
        "env bash -c \"git commit --no-verify -m done\"\n",
        "bash -lc \"git commit --no-verify -m done\"\n",
        "env -i bash -lc \"git commit --no-verify -m done\"\n",
    ] {
        let result = skill(&[("scripts/pre-commit", reached)]);
        assert_eq!(
            severity_of(&result, "safety-bypass"),
            Some(Severity::Critical),
            "{reached}: {:?}",
            result.findings
        );
    }

    let inline = skill(&[(
        "scripts/pre-commit",
        "bash -cl \"git commit --no-verify -m done\"\n",
    )]);
    assert!(
        !rules_hit(&inline).contains(&"safety-bypass"),
        "{:?}",
        inline.findings
    );
}

/// An interpreter handed `-c` reads exactly one operand as a command line.
/// Everything after it is the `$0`, `$1`, `$2` that command line is run
/// with — data the shell never parses, whatever is written inside it — so
/// reading every operand as code reports a switch nothing hands over.
#[test]
fn safety_bypass_leaves_the_operands_after_a_command_string_alone() {
    let positional = skill(&[(
        "scripts/pre-commit",
        "bash -c 'true' marker 'git commit --no-verify'\n",
    )]);
    assert!(
        !rules_hit(&positional).contains(&"safety-bypass"),
        "{:?}",
        positional.findings
    );
}

/// A program in a language this rule does not read hands its arguments
/// over through a call rather than a command line, and the switch inside
/// one is spelled in that language's quotes. Read as shell those quotes
/// are the shell's, so the switch stands inside a quotation, nothing
/// parses as argv either, and a file that hands git the switch scores
/// nothing at all.
///
/// The control is the last case: a shell script is still read as one, so
/// the switch named in a comment is still the dead text it was.
#[test]
fn safety_bypass_reads_a_switch_a_file_it_cannot_parse_hands_to_a_program() {
    let python = skill(&[(
        "scripts/deploy.py",
        "subprocess.run([\"git\", \"commit\", \"--no-verify\"])\n",
    )]);
    assert_eq!(
        severity_of(&python, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        python.findings
    );

    let rust = skill(&[(
        "src/commit.rs",
        "Command::new(\"git\").arg(\"commit\").arg(\"--no-verify\");\n",
    )]);
    assert_eq!(
        severity_of(&rust, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        rust.findings
    );

    let shell = skill(&[(
        "scripts/commit.sh",
        "# never pass --no-verify here\ngit commit -m done\n",
    )]);
    assert!(
        !rules_hit(&shell).contains(&"safety-bypass"),
        "{:?}",
        shell.findings
    );
}

/// What reads a file is what the file says reads it. A script written
/// without a suffix is the ordinary shape in a skill's `scripts/`
/// directory, and it is read as shell — so the switch its own warning
/// names is text, the way it is in every `.sh` beside it. A shebang
/// answers first and overrides the name: the same words in a file Python
/// runs are a file this rule cannot parse, and every position in it
/// counts.
#[test]
fn safety_bypass_judges_a_suffixless_file_by_its_shebang_and_then_as_shell() {
    for script in [
        "#!/usr/bin/env bash\n# never pass --no-verify here\n",
        "# never pass --no-verify here\n",
    ] {
        let result = skill(&[("scripts/commit", script)]);
        assert!(
            !rules_hit(&result).contains(&"safety-bypass"),
            "{script}: {:?}",
            result.findings
        );
    }

    let python = skill(&[(
        "scripts/commit",
        "#!/usr/bin/env python3\n# never pass --no-verify here\n",
    )]);
    assert_eq!(
        severity_of(&python, "safety-bypass"),
        Some(Severity::Critical),
        "{:?}",
        python.findings
    );
}
