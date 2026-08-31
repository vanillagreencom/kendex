use super::*;

const GOOD: &str = "[env]\n\n# What the reviewers do.\n# Comma separated.\nREVIEWERS = \"arch,security\"\n\n# How deep.\nDEPTH = \"2\"\n";

/// Every finding's problem text, so a fixture asserts what was said and
/// where without repeating the whole struct.
fn located(text: &str) -> Vec<(u32, String)> {
    read(text)
        .findings
        .into_iter()
        .map(|finding| (finding.line, finding.problem))
        .collect()
}

#[test]
fn a_clean_template_decodes_to_rows() {
    let read = read(GOOD);
    assert!(read.findings.is_empty(), "{:?}", read.findings);
    assert_eq!(read.entries.len(), 2);
    let first = &read.entries[0];
    assert_eq!(first.key, "REVIEWERS");
    assert_eq!(first.value, "arch,security");
    assert_eq!(
        first.comment,
        ["What the reviewers do.", "Comma separated."]
    );
    assert_eq!(first.comment_span, (3, 4));
    assert_eq!(first.line, 5);
    assert_eq!(read.entries[1].key, "DEPTH");
    assert_eq!(read.entries[1].comment_span, (7, 7));
}

#[test]
fn a_file_that_does_not_parse_is_one_finding() {
    let found = located("[env]\n# Why.\nDEPTH \"2\"\n");
    assert_eq!(found.len(), 1);
    assert!(
        found[0].1.starts_with("this is not valid TOML:"),
        "{found:?}"
    );
}

#[test]
fn an_assignment_outside_env_is_located() {
    let found = located("# Why.\nDEPTH = \"2\"\n\n[env]\n# Why.\nOTHER = \"1\"\n");
    assert_eq!(found, [(2, "DEPTH is assigned outside [env]".to_owned())]);
}

#[test]
fn a_second_env_header_is_located() {
    let found = located("[env]\n# Why.\nA = \"1\"\n\n[env]\n# Why.\nB = \"2\"\n");
    assert_eq!(
        found,
        [(
            5,
            "a second [env] header; the first is on line 1".to_owned()
        )]
    );
}

#[test]
fn a_key_with_no_comment_block_is_located() {
    let found = located("[env]\n# Why.\nA = \"1\"\n\nB = \"2\"\n");
    assert_eq!(found, [(5, "B has no comment block above it".to_owned())]);
}

#[test]
fn a_blank_line_cuts_a_comment_off_its_key() {
    let found = located("[env]\n# Why.\n\nA = \"1\"\n");
    assert_eq!(found, [(4, "A has no comment block above it".to_owned())]);
}

#[test]
fn a_value_that_is_not_a_plain_quoted_string_is_located() {
    let refused = [
        "[env]\n# Why.\nA = 2\n",
        "[env]\n# Why.\nA = true\n",
        "[env]\n# Why.\nA = \"\"\"long\"\"\"\n",
        "[env]\n# Why.\nA = \"say \\\"hi\\\"\"\n",
        "[env]\n# Why.\nA = \"C:\\\\tools\"\n",
        "[env]\n# Why.\nA = ['x']\n",
    ];
    for text in refused {
        assert_eq!(
            located(text),
            [(
                3,
                "A's default is not a one-line double-quoted string free of \" and \\".to_owned()
            )],
            "{text:?}"
        );
    }
}

#[test]
fn a_duplicate_key_is_located() {
    // Across tables: valid TOML, and exactly what seeding's file-wide
    // presence check trips over.
    let found = located("[other]\n# Why.\nA = \"1\"\n\n[env]\n# Why.\nA = \"2\"\n");
    assert_eq!(
        found,
        [
            (3, "A is assigned outside [env]".to_owned()),
            (7, "A is assigned again; it is already on line 3".to_owned()),
        ]
    );
}

#[test]
fn a_commented_out_key_is_comment_and_not_an_assignment() {
    let read = read("[env]\n# An example.\n# A = \"1\"\n\n# Why.\nB = \"2\"\n");
    assert!(read.findings.is_empty(), "{:?}", read.findings);
    assert_eq!(read.entries.len(), 1);
    assert_eq!(read.entries[0].key, "B");
}

#[test]
fn decoded_value_reads_only_plain_one_line_strings() {
    assert_eq!(decoded_value("A = \"x\""), Some("x".to_owned()));
    assert_eq!(decoded_value("A = \"\""), Some(String::new()));
    assert_eq!(decoded_value("A = \"1\""), Some("1".to_owned()));
    assert_eq!(decoded_value("A = \""), None);
    assert_eq!(decoded_value("A = 1"), None);
    assert_eq!(decoded_value("A"), None);
}

#[test]
fn the_required_marker_rides_with_the_value_and_nothing_else_may() {
    let marked = read("[env]\n# How long to wait.\nWAIT = \"900\" # required\n");
    assert!(marked.findings.is_empty(), "{:?}", marked.findings);
    assert_eq!(marked.entries[0].value, "900");

    // A misspelled marker loads exactly as a correct one does, so the
    // loaders never see it and the key silently stops being written.
    let typo = read("[env]\n# How long to wait.\nWAIT = \"900\" # requried\n");
    assert_eq!(
        typo.findings
            .iter()
            .map(|finding| finding.line)
            .collect::<Vec<_>>(),
        [3]
    );
    assert!(
        typo.findings[0].problem.contains("#requried"),
        "{:?}",
        typo.findings
    );

    let plain = read("[env]\n# How long to wait.\nWAIT = \"900\"\n");
    assert!(plain.findings.is_empty(), "{:?}", plain.findings);

    // Presentation is not folded on this side. After a value the exact
    // word is what the seeder honours, so every other presentation of it
    // is a template refused — and the seeder is asked in the same loop,
    // because the check exists to keep the two from parting. Fold one and
    // not the other and `# Required` passes review while the seeder still
    // ignores it: the key is never written AND never reported unanswered.
    for said in ["Required", "REQUIRED", "required.", "required:"] {
        let template = format!("[env]\n# How long to wait.\nWAIT = \"900\" # {said}\n");
        assert_eq!(
            located(&template),
            [(
                3,
                format!(
                    "WAIT carries `#{said}` after its value, and the only marker a template writes there is `# required`"
                )
            )],
            "{said:?}"
        );
        let entries = crate::settings_seed::extract_env_entries(&template);
        assert!(
            !entries[0].required,
            "{said:?}: the seeder honours the exact word only: {entries:?}"
        );
    }
}

/// The marker on a line of its own marks nothing, and it is the mistake an
/// author is invited to make: every template header names `# required`
/// inside a sentence before they ever see one after a value. Unflagged it
/// is silent twice over — the key is never written, and it is never
/// reported as unanswered either, because nothing knows it was marked.
///
/// Pinned here rather than as a corpus row, like every other rule only a
/// template has. The loaders read a comment line cleanly whatever it says,
/// so a row for this would assert the reader and the loaders disagree,
/// which is what the corpus is for refusing. Adding one fails
/// `the_reader_flags_exactly_what_the_loaders_cannot_read`.
#[test]
fn a_marker_on_its_own_comment_line_is_located() {
    // However the word is presented. Case and everything at either end
    // that is not a letter or a digit: a closed list of trailing ASCII
    // marks left an ellipsis, a bracket, wrapping quotes and an invisible
    // character each one keystroke from the same silence.
    for said in [
        "required",
        "Required",
        "REQUIRED",
        "  required  ",
        "required.",
        "Required:",
        "required!",
        "required\u{2026}",
        "Required)",
        " (required)",
        " \"required\"",
        " *required*",
        "required\u{200b}",
    ] {
        assert_eq!(
            located(&format!(
                "[env]\n# How long to wait.\n#{said}\nWAIT = \"900\"\n"
            )),
            [(
                3,
                format!(
                    "this comment line is just `{}`, which marks nothing",
                    said.trim()
                )
            )],
            "{said:?}"
        );
    }
    // `##` opens a comment as plainly as `#` does.
    assert_eq!(
        located("[env]\n# How long to wait.\n## Required\nWAIT = \"900\"\n")
            .iter()
            .map(|(line, _)| *line)
            .collect::<Vec<u32>>(),
        [3]
    );
    // A misspelling gets no finding, and deliberately. Telling `# requried`
    // from an ordinary comment line means guessing at what the author
    // meant, and a line of free prose is what it would guess against;
    // presentation is a closed set and misspelling is not. After a value,
    // where the exact spelling is what gets honoured, these are all caught.
    for said in ["requried", "requireds", "require", "requires"] {
        assert!(
            located(&format!(
                "[env]\n# How long to wait.\n# {said}\nWAIT = \"900\"\n"
            ))
            .is_empty(),
            "{said:?}"
        );
    }
    // Inside a multiline value the line is the value and not a comment, so
    // the widened word does not reach in: one finding, and it is the
    // value's.
    assert_eq!(
        located("[env]\n# What it holds.\nBLOB = \"\"\"\n# required\n\"\"\"\n"),
        [(
            3,
            "BLOB's default is not a one-line double-quoted string free of \" and \\".to_owned()
        )]
    );
    // Outside `[env]` too: a marker nothing reads is a marker nothing
    // reads, whichever table it sits over.
    assert_eq!(
        located("# required\n[env]\n# How long to wait.\nWAIT = \"900\"\n")
            .iter()
            .map(|(line, _)| *line)
            .collect::<Vec<u32>>(),
        [1]
    );
    // The word inside a sentence is what every shipped template writes,
    // and it is not a marker. Only the ends of the line are folded, so a
    // comment that merely contains the word keeps a letter at both ends
    // and stays an ordinary comment however short it is.
    for said in [
        "Keys marked `# required` land on arrival.",
        "required for CI",
        "The team is required.",
        "(required for a Linear write)",
        "required1",
    ] {
        assert!(
            located(&format!(
                "[env]\n# How long to wait.\n# {said}\nWAIT = \"900\"\n"
            ))
            .is_empty(),
            "{said:?}"
        );
    }
}

#[test]
fn a_header_the_loaders_refuse_is_located_and_does_not_cascade() {
    // `[other] # note` is where the lenient reader kept reading [env]
    // entries out of another table.
    let read = read("[env]\n# Why.\nA = \"1\"\n\n[other] # theirs\n");
    assert_eq!(
        located("[env]\n# Why.\nA = \"1\"\n\n[other] # theirs\n"),
        [(
            5,
            "this is not a table header the settings loaders read".to_owned()
        )]
    );
    // The entry before it still decodes: one bad header, one finding.
    assert_eq!(read.entries.len(), 1);
}

#[test]
fn a_key_no_shell_can_export_is_located() {
    for key in ["FOO-BAR", "FOO.BAR", "1WAIT", "\"WAIT\""] {
        assert_eq!(
            located(&format!("[env]\n# Why.\n{key} = \"1\"\n")),
            [(
                3,
                format!("{key} is not a name a shell can export, so nothing reads it")
            )],
            "{key}"
        );
    }
}

#[test]
fn a_toml_error_in_column_one_reports_its_own_line() {
    // An assignment with no key is one the line scan reads past, so TOML is
    // what refuses it, and its span opens at that line's very first byte —
    // the offset a prefix-line count reports one line early, because a
    // prefix ending in a terminator has no trailing line to count.
    let found = located("[env]\n# Why.\nA = \"1\"\n= \"2\"\n");
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0].0, 4, "{found:?}");
    assert!(
        found[0].1.starts_with("this is not valid TOML:"),
        "{found:?}"
    );
}

/// A template with no `[env]` table seeds nothing at all, whatever else it
/// says. The corpus next door is the shell loaders' grammar, and they have
/// no opinion here — a consumer's settings file without `[env]` simply
/// resolves every key to its built-in default. This is the template's own
/// rule, so it is pinned here rather than as a corpus row.
#[test]
fn a_template_with_no_env_table_is_located() {
    let absent = [
        "",
        "# Just a preamble, and nothing under it.\n",
        "# What this package reads.\n# It never gets there.\nWAIT = \"900\"\n",
        "[envs]\n# How long to wait.\nWAIT = \"900\"\n",
    ];
    for text in absent {
        assert_eq!(
            located(text),
            [(
                0,
                "there is no [env] table, so this template seeds nothing".to_owned()
            )],
            "{text:?}"
        );
    }
}

#[test]
fn a_header_shaped_wrong_is_not_also_reported_as_an_absent_table() {
    let found = located("[env] # the table\n# How long to wait.\nWAIT = \"900\"\n");
    assert_eq!(
        found,
        [(
            1,
            "this is not a table header the settings loaders read".to_owned()
        )]
    );
}

#[test]
fn an_independent_toml_error_is_reported_beside_the_scan_finding() {
    // The value on line 3 is a shape the loaders refuse; line 5 is a
    // separate syntax error the scan reads past. Fixing one and coming
    // back for the other is a round trip nobody needs.
    let found = located("[env]\n# Why.\nWAIT = 900\n# Why.\nDEPTH \"2\"\n");
    assert_eq!(found.len(), 2, "{found:?}");
    assert_eq!(found[0].0, 3, "{found:?}");
    assert_eq!(found[1].0, 5, "{found:?}");
    assert!(
        found[1].1.starts_with("this is not valid TOML:"),
        "{found:?}"
    );
}

#[test]
fn one_defect_the_parser_also_sees_is_reported_once() {
    // Every shape where the scan and the parser land on the same line: the
    // scan names the key, the parser would only say "duplicate key".
    for text in [
        "[env]\n# Why.\nWAIT = \"900\"\n# Again.\nWAIT = \"600\"\n",
        "[env]\n# Why.\nA = \"1\"\n\n[env]\n# Why.\nB = \"2\"\n",
        "[env]\n# A path.\nWAIT = \"base\".tsv\n",
        "[env][env]\n# Why.\nWAIT = \"900\"\n",
    ] {
        let found = located(text);
        assert_eq!(found.len(), 1, "{text:?} -> {found:?}");
        assert!(
            !found[0].1.starts_with("this is not valid TOML:"),
            "{text:?} -> {found:?}"
        );
    }
}

#[test]
fn a_duplicate_does_not_hide_the_rest_of_its_own_line() {
    // Deleting the first WAIT and re-running to be told the second was
    // never a readable value is a round trip the author should not make.
    let found = located("[env]\n# Why.\nWAIT = \"900\"\n# Again.\nWAIT = 900\n");
    assert_eq!(
        found,
        [
            (
                5,
                "WAIT is assigned again; it is already on line 3".to_owned()
            ),
            (
                5,
                "WAIT's default is not a one-line double-quoted string free of \" and \\"
                    .to_owned()
            ),
        ]
    );
}

#[test]
fn a_duplicate_that_is_otherwise_fine_is_one_finding_and_no_row() {
    let read = read("[env]\n# Why.\nWAIT = \"900\"\n# Again.\nWAIT = \"600\"\n");
    assert_eq!(read.findings.len(), 1, "{:?}", read.findings);
    // The first assignment is the row; the second is a line to delete.
    assert_eq!(read.entries.len(), 1);
    assert_eq!(read.entries[0].value, "900");
}

#[test]
fn one_assignment_wrong_two_ways_is_two_findings() {
    // No comment block AND a value the loaders refuse. Being told about
    // one, fixing it, and only then hearing about the other is the round
    // trip every both-defects rule here exists to prevent.
    let found = located("[env]\n# Why.\nA = \"1\"\nB = 2\n");
    assert_eq!(
        found,
        [
            (4, "B has no comment block above it".to_owned()),
            (
                4,
                "B's default is not a one-line double-quoted string free of \" and \\".to_owned()
            ),
        ]
    );
}

#[test]
fn a_template_rule_does_not_silence_the_parser_on_its_line() {
    // `B B` is a name no shell exports — a template rule — and it is also
    // not a key TOML accepts. The value decodes fine, so nothing the scan
    // says is about this line's syntax, and the parser's word is the only
    // account of that half. Keying its finding on the line alone dropped it.
    let found = located("[env]\n# Why.\nA = \"1\"\n# Why.\nB B = \"2\"\n");
    assert_eq!(found.len(), 2, "{found:?}");
    assert_eq!(
        found[0],
        (
            5,
            "B B is not a name a shell can export, so nothing reads it".to_owned()
        )
    );
    assert!(
        found[1].1.starts_with("this is not valid TOML:"),
        "{found:?}"
    );
}

/// The documented limit, kept honest: `toml::de::Error` carries one message
/// and one span, and the crate offers no way to ask for more, so a file
/// with two independent syntax errors gives up the second only once the
/// first is fixed. If that ever stops being true, this is where to notice.
#[test]
fn two_independent_syntax_errors_come_one_run_at_a_time() {
    let both = "[env]\n# Why.\nA = \"1\"\n= \"2\"\n= \"3\"\n";
    let found = located(both);
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0].0, 4, "{found:?}");

    // Fixing the first surfaces the second, and nothing else changed.
    let first_fixed = "[env]\n# Why.\nA = \"1\"\n# Why.\nB = \"2\"\n= \"3\"\n";
    let found = located(first_fixed);
    assert_eq!(found.len(), 1, "{found:?}");
    assert_eq!(found[0].0, 6, "{found:?}");
}

/// A multiline value's own lines are the value. Judged as syntax they name
/// keys the template does not have, and send an author to fix them — and
/// the `#` inside one gets attached as the explainer for whatever key
/// comes next.
#[test]
fn nothing_inside_a_multiline_value_is_read_as_template_syntax() {
    for open in ["\"\"\"", "'''"] {
        let text = format!(
            "[env]\n# What it holds.\nBLOB = {open}\nX = \"1\"\n# not an explainer\n{open}\n\n# How deep.\nDEPTH = \"2\"\n"
        );
        let found = located(&text);
        assert_eq!(
            found,
            vec![(
                3,
                "BLOB's default is not a one-line double-quoted string free of \" and \\"
                    .to_owned()
            )],
            "{open}"
        );
        // The key after the value keeps its own comment block, not the one
        // that sat inside the value.
        let entries = read(&text).entries;
        assert_eq!(entries.len(), 1, "{open}");
        assert_eq!(entries[0].key, "DEPTH");
        assert_eq!(entries[0].comment, vec!["How deep.".to_owned()]);
    }
}

/// A quoted key is one TOML reads and no shell exports, in either
/// spelling, and two spellings of one key are the duplicate they are.
#[test]
fn a_quoted_key_is_located_and_collides_with_its_bare_spelling() {
    for spelling in ["\"DEPTH\"", "'DEPTH'"] {
        let text = format!("[env]\n# How deep.\n{spelling} = \"2\"\n");
        assert_eq!(
            located(&text),
            vec![(
                3,
                format!("{spelling} is not a name a shell can export, so nothing reads it")
            )],
            "{spelling}"
        );
        assert!(read(&text).entries.is_empty(), "{spelling}");

        let both = format!("[env]\n# How deep.\nDEPTH = \"2\"\n\n# Again.\n{spelling} = \"3\"\n");
        assert!(
            located(&both).iter().any(|(line, problem)| *line == 6
                && problem == "DEPTH is assigned again; it is already on line 3"),
            "{:?}",
            located(&both)
        );
    }
}
