use super::*;

fn kinds(text: &str) -> Vec<Line<'_>> {
    rows(text).into_iter().map(|row| row.kind).collect()
}

fn keys(text: &str) -> Vec<String> {
    rows(text)
        .iter()
        .filter_map(|row| row.assignment())
        .filter_map(|(key, _, _)| key_of(key))
        .map(|key| key.name)
        .collect()
}

#[test]
fn the_ordinary_shapes_read_as_themselves() {
    assert_eq!(
        kinds("\n# note\n[env]\nMODE = \"quiet\"\njunk\n"),
        vec![
            Line::Blank,
            Line::Comment,
            Line::Table,
            Line::Assignment {
                key: "MODE ",
                value: " \"quiet\"",
                value_at: 6,
            },
            Line::Other,
        ]
    );
}

/// The defect this reader exists for: a multiline value's interior is the
/// value, whatever it looks like. Read a line at a time, `MODE` here is an
/// assignment, and a view built on that hands an editor a span inside
/// `BLOB` to write over.
#[test]
fn nothing_inside_a_multiline_value_is_structure() {
    for open in ["\"\"\"", "'''"] {
        let text = format!(
            "[env]\nBLOB = {open}\nMODE = \"fake\"\n# not a comment\n[other]\n{open}\nREAL = \"yes\"\n"
        );
        let kinds = kinds(&text);
        // Lines 3 to 6 are BLOB's value: an assignment, a comment and a
        // table header by their own shape, and none of them structure.
        assert!(
            kinds[2..6].iter().all(|kind| *kind == Line::InValue),
            "{open}: {kinds:?}"
        );
        assert_eq!(kinds[0], Line::Table, "{open}");
        assert!(
            matches!(kinds[1], Line::Assignment { key: "BLOB ", .. }),
            "{open}"
        );
        assert!(
            matches!(kinds[6], Line::Assignment { key: "REAL ", .. }),
            "{open}"
        );
        assert_eq!(keys(&text), vec!["BLOB".to_owned(), "REAL".to_owned()]);
    }
}

/// A multiline that opens and closes on one line never carries.
#[test]
fn a_multiline_closed_on_its_own_line_leaves_the_next_line_alone() {
    assert_eq!(
        keys("A = \"\"\"one line\"\"\"\nMODE = \"real\"\n"),
        vec!["A".to_owned(), "MODE".to_owned()]
    );
    // Three to five quotes end it: the extras are content.
    assert_eq!(
        keys("A = \"\"\"say \"\"\"\"\"\nMODE = \"real\"\n"),
        vec!["A".to_owned(), "MODE".to_owned()]
    );
}

/// A backslash escapes the delimiter in a basic string and does not in a
/// literal one, so the two close in different places.
#[test]
fn an_escaped_delimiter_does_not_close_a_basic_string() {
    assert_eq!(
        keys("A = \"\"\"\n\\\"\"\"\n\"\"\"\nMODE = \"real\"\n"),
        vec!["A".to_owned(), "MODE".to_owned()]
    );
    assert_eq!(
        keys("A = '''\n\\'''\nMODE = \"real\"\n"),
        vec!["A".to_owned(), "MODE".to_owned()]
    );
}

/// TOML reads all three spellings as one key. Seeding beside any of them
/// would put the key in the file twice; only the bare one is a name a
/// shell exports, and both facts travel together.
#[test]
fn three_spellings_of_one_key_share_a_name_and_differ_on_being_bare() {
    for text in ["MODE = \"a\"\n", "\"MODE\" = \"a\"\n", "'MODE' = \"a\"\n"] {
        assert_eq!(keys(text), vec!["MODE".to_owned()], "{text}");
    }
    assert_eq!(
        key_of("MODE"),
        Some(Key {
            name: "MODE".to_owned(),
            quoted: false
        })
    );
    for spelling in ["\"MODE\"", "'MODE'"] {
        assert_eq!(
            key_of(spelling),
            Some(Key {
                name: "MODE".to_owned(),
                quoted: true
            }),
            "{spelling}"
        );
    }
    assert_eq!(key_of("   "), None);
}

/// The `=` that splits an assignment is the first one no string holds, so
/// a key or a value containing one does not split the line in the wrong
/// place.
#[test]
fn an_equals_inside_a_string_does_not_split_the_line() {
    assert_eq!(keys("\"a=b\" = \"c\"\n"), vec!["a=b".to_owned()]);
    let rows = rows("MODE = \"x = y\"\n");
    assert_eq!(
        rows[0].assignment().map(|(_, value, _)| value),
        Some(" \"x = y\"")
    );
}

/// A comment before any `=` means there is no assignment on the line.
#[test]
fn a_comment_swallows_the_rest_of_its_line() {
    assert_eq!(kinds("# MODE = \"a\"\n"), vec![Line::Comment]);
    assert_eq!(kinds("  x # MODE = \"a\"\n"), vec![Line::Other]);
}

/// A span is only ever produced for a value the loaders would read, and it
/// names exactly the characters between the quotes.
#[test]
fn a_span_covers_the_value_and_only_where_one_is_readable() {
    let text = "[env]\nMODE = \"quiet\" # keep\n";
    let row = &rows(text)[1];
    let (_, value, at) = row.assignment().unwrap();
    let inner = quoted_span(value, at).unwrap();
    assert_eq!(&text[inner], "quiet");
    assert_eq!(decoded(value), Some("quiet".to_owned()));

    for refused in [" 3", " \"\"\"a\"\"\"", " \"a\\tb\"", " \"a\" b", " x\"a\""] {
        assert_eq!(quoted_span(refused, 0), None, "{refused}");
    }
}

/// An unterminated single-line string ends with its line rather than
/// swallowing the rest of the file — which is also what the grep-shaped
/// shell loaders do with one.
#[test]
fn an_unterminated_single_line_string_does_not_carry() {
    assert_eq!(
        keys("A = \"oops\nMODE = \"real\"\n"),
        vec!["A".to_owned(), "MODE".to_owned()]
    );
}

/// Rows carry their own bytes back: `raw` re-emits the line terminator and
/// nothing else, which is what every byte-faithful splice re-emits.
#[test]
fn a_row_carries_the_bytes_it_was_read_from() {
    let text = "# a\r\nMODE = \"x\"\r\nlast";
    let rows = rows(text);
    assert_eq!(
        rows.iter().map(|row| row.raw).collect::<Vec<_>>(),
        ["# a\r\n", "MODE = \"x\"\r\n", "last"]
    );
    assert_eq!(rows[1].text, "MODE = \"x\"");
    assert_eq!(
        &text[rows[1].at..rows[1].at + rows[1].text.len()],
        "MODE = \"x\""
    );
    assert_eq!(rows[2].line, 3);
}

/// TOML reads `"MODE"` and `MODE` as one key. Undecoded, the
/// collision is missed and seeding adds a second `MODE` — the duplicate
/// the quoted spellings were closed for.
#[test]
fn a_basic_key_decodes_its_escapes_and_a_literal_key_does_not() {
    for spelling in ["\"MO\\u0044E\"", "\"MO\\U00000044E\"", "\"MODE\""] {
        assert_eq!(
            key_of(spelling),
            Some(Key {
                name: "MODE".to_owned(),
                quoted: true
            }),
            "{spelling}"
        );
        assert_eq!(
            keys(&format!("{spelling} = \"a\"\n")),
            vec!["MODE".to_owned()]
        );
    }
    // A literal key processes no escapes, so this is a different key —
    // decoding it would make two distinct keys collide.
    assert_eq!(
        key_of("'MO\\u0044E'"),
        Some(Key {
            name: "MO\\u0044E".to_owned(),
            quoted: true
        })
    );
    // The rest of the basic escapes, and one TOML does not define.
    assert_eq!(
        key_of("\"a\\tb\\nc\\\\d\\\"e\"").map(|k| k.name),
        Some("a\tb\nc\\d\"e".to_owned())
    );
    assert_eq!(
        key_of("\"a\\qb\"").map(|k| k.name),
        Some("a\\qb".to_owned())
    );
    assert_eq!(
        key_of("\"a\\u00\"").map(|k| k.name),
        Some("a\\u00".to_owned())
    );
}

/// A `[` line that also opens a multiline string. It is a table line by
/// its first character AND a line the next one continues, and a branch
/// that answers the first question while forgetting the second lets every
/// following line read as structure — including an assignment sitting
/// inside the string, which is a byte span an editor would write into.
#[test]
fn a_bracket_line_that_opens_a_string_still_carries_it() {
    for open in ["\"\"\"", "'''"] {
        let text =
            format!("BLOB = [\n  [{open}\n[env]\nMODE = \"shadow\"\n{open}]\n]\nREAL = \"yes\"\n");
        let kinds = kinds(&text);
        assert!(
            kinds[2..5].iter().all(|kind| *kind == Line::InValue),
            "{open}: the string's own lines are the string — {kinds:?}"
        );
        assert_eq!(
            keys(&text),
            vec!["BLOB".to_owned(), "REAL".to_owned()],
            "{open}"
        );
    }
}

/// Arrays carry across lines and nest, so depth is counted rather than
/// flagged. A nested bracket is not a table header, and the lines of an
/// array are the value — which is what keeps a seed from being spliced
/// into the middle of one.
#[test]
fn an_array_carries_across_lines_and_nests() {
    let text = "[env]\nLIST = [\n  [\n    [env]\n  ],\n]\nMODE = \"real\"\n";
    let kinds = kinds(text);
    assert_eq!(kinds[0], Line::Table);
    assert!(
        kinds[2..6].iter().all(|kind| *kind == Line::InValue),
        "{kinds:?}"
    );
    assert!(matches!(kinds[6], Line::Assignment { key: "MODE ", .. }));
    assert_eq!(keys(text), vec!["LIST".to_owned(), "MODE".to_owned()]);
}

/// A header's own brackets balance, so the line after one is structure
/// again — for a plain table and for an array of tables alike.
#[test]
fn a_table_header_leaves_nothing_open() {
    for header in ["[env]", "[a.b]", "[[items]]", "[env] # note"] {
        let text = format!("{header}\nMODE = \"real\"\n");
        assert_eq!(kinds(&text)[0], Line::Table, "{header}");
        assert_eq!(keys(&text), vec!["MODE".to_owned()], "{header}");
    }
}

/// An inline table holds no newline in TOML 1.0, so it carries nothing;
/// its `=` and `[` reach no decision, because the assignment's `=` is the
/// first one outside a string and only a line-leading `[` is a table.
#[test]
fn an_inline_table_carries_nothing_across_a_line() {
    let text = "[env]\nA = { b = [1], c = \"x\" }\nMODE = \"real\"\n";
    assert_eq!(keys(text), vec!["A".to_owned(), "MODE".to_owned()]);
    assert_eq!(
        kinds(text)[2],
        Line::Assignment {
            key: "MODE ",
            value: " \"real\"",
            value_at: 6,
        }
    );
}

/// Every scalar is one token with nothing structural in it, so a line
/// holding one leaves nothing open and the next line reads as itself.
#[test]
fn a_scalar_leaves_nothing_open() {
    for scalar in [
        "1",
        "-0.5",
        "true",
        "1979-05-27T07:32:00Z",
        "07:32:00",
        "0xdead_beef",
    ] {
        let text = format!("[env]\nA = {scalar}\nMODE = \"real\"\n");
        assert_eq!(
            keys(&text),
            vec!["A".to_owned(), "MODE".to_owned()],
            "{scalar}"
        );
    }
}

/// A stray `]` cannot take the depth below zero: an unbalanced file is not
/// TOML, and underflowing would read everything after it as one value.
#[test]
fn an_unbalanced_bracket_does_not_swallow_the_file() {
    assert_eq!(keys("]\n[env]\nMODE = \"real\"\n"), vec!["MODE".to_owned()]);
}

/// One header parse for everyone, carrying both facts: the name TOML
/// reads, and whether the shell loaders read a header of that shape. Three
/// modules each kept their own version of this and the copies disagreed —
/// which table a seed splices into is not the same question as which
/// table's keys a script reads.
#[test]
fn a_header_carries_the_name_and_whether_the_loaders_read_it() {
    assert_eq!(
        header_of("[env]"),
        Some(Header {
            name: "env",
            lone: true
        })
    );
    assert_eq!(
        header_of("  [env] # the table"),
        Some(Header {
            name: "env",
            lone: false
        }),
        "a typo in the header does not stop it being the env table"
    );
    assert_eq!(header_of("[a.b-c_d]").map(|h| h.name), Some("a.b-c_d"));
    // Not headers: no closing bracket, an empty name, an array of tables,
    // and whitespace inside the brackets, which the loaders never match.
    for refused in ["[env", "[]", "[[items]]", "[ env ]", "MODE = \"a\"", ""] {
        assert_eq!(header_of(refused), None, "{refused}");
    }
}
