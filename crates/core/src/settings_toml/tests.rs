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
            quoted: false,
            under: Vec::new()
        })
    );
    for spelling in ["\"MODE\"", "'MODE'"] {
        assert_eq!(
            key_of(spelling),
            Some(Key {
                name: "MODE".to_owned(),
                quoted: true,
                under: Vec::new()
            }),
            "{spelling}"
        );
    }
    assert_eq!(key_of("   "), None);
}

/// A dotted key names a PATH. Read as one literal name it occupies
/// nothing anyone asks about: `env.MODE` leaves `env` looking undeclared
/// and `MODE.part` leaves `MODE` looking absent, and the seed written
/// beside either one defines its name a second time and stops the file
/// loading. The name a dotted key declares is its FIRST segment; what
/// hangs below it is that table's business.
#[test]
fn a_dotted_key_reads_as_the_path_it_names() {
    // One path, however its segments are spelled and spaced.
    for spelling in ["env.MODE", "env.\"MODE\"", "env.'MODE'", "env . MODE"] {
        assert_eq!(
            key_of(spelling),
            Some(Key {
                name: "env".to_owned(),
                quoted: false,
                under: vec!["MODE".to_owned()]
            }),
            "{spelling}"
        );
    }
    // A `.` inside a quoted segment is that name's character, not a
    // separator: this is ONE segment and declares nothing called `a`.
    assert_eq!(
        key_of("\"a.b\""),
        Some(Key {
            name: "a.b".to_owned(),
            quoted: true,
            under: Vec::new()
        })
    );
    assert!(!key_of("\"a.b\"").expect("a key").dotted());
    assert!(key_of("a.b").expect("a key").dotted());
    // A segment TOML would not accept is not half a key: the whole key is
    // none, as an empty one already was.
    for spelling in ["a.", ".b", "a..b"] {
        assert_eq!(key_of(spelling), None, "{spelling}");
    }
    // The declared name is what a walk over the file reports.
    assert_eq!(keys("MODE.part = \"x\"\n"), vec!["MODE".to_owned()]);
    assert_eq!(keys("env.MODE = \"x\"\n"), vec!["env".to_owned()]);
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
                quoted: true,
                under: Vec::new()
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
            quoted: true,
            under: Vec::new()
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

/// An inline table that closes on its own line leaves nothing open, so the
/// line below it is structure again. What it held reaches no decision: the
/// assignment's `=` is the first one outside a string, and only a
/// line-leading `[` is a table.
#[test]
fn a_closed_inline_table_does_not_reach_the_line_below_it() {
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

/// One header parse for everyone, carrying the facts each caller needs:
/// the dotted key TOML reads, whether the shell loaders read a header of
/// that shape, and whether it declares an array of tables rather than the
/// table itself. Three modules each kept their own version of this and
/// the copies disagreed — which table a seed splices into is not the same
/// question as which table's keys a script reads.
#[test]
fn a_header_carries_its_key_and_whether_the_loaders_read_it() {
    let env = header_of("[env]").expect("a header");
    assert!(env.opens("env") && env.lone && !env.array);

    // Every spelling TOML gives the same table. None but the first is one
    // the loaders read, and all of them are still that table — which is
    // what a seed is spliced against.
    for spelling in [
        "[env] # note",
        "[ env ]",
        "[\"env\"]",
        "['env']",
        "[\"e\\u006ev\"]",
    ] {
        let header = header_of(spelling).unwrap_or_else(|| panic!("{spelling}"));
        assert!(header.opens("env"), "{spelling}");
        assert!(!header.lone, "{spelling}");
    }

    // An array of tables is not the table of that name.
    let items = header_of("[[env]]").expect("a header");
    assert!(items.array && !items.opens("env"));
    assert_eq!(items.path, vec!["env".to_owned()]);

    // Dotted keys keep their parts, and quoting decides where a dot
    // separates rather than belongs.
    assert_eq!(
        header_of("[a.b-c_d]").map(|h| h.path),
        Some(vec!["a".to_owned(), "b-c_d".to_owned()])
    );
    assert_eq!(
        header_of("[ a . b ]").map(|h| h.path),
        Some(vec!["a".to_owned(), "b".to_owned()])
    );
    assert_eq!(
        header_of("[\"a.b\"]").map(|h| h.path),
        Some(vec!["a.b".to_owned()])
    );
    assert_eq!(
        header_of("[\"has]bracket\"]").map(|h| h.path),
        Some(vec!["has]bracket".to_owned()])
    );
    assert!(!header_of("[a.env]").expect("a header").opens("env"));

    // Not headers at all.
    for refused in [
        "[env",
        "[]",
        "[[env]",
        "[not a table]",
        "[a..b]",
        "MODE = \"a\"",
        "",
    ] {
        assert_eq!(header_of(refused), None, "{refused}");
    }
}

/// `carries` is [`Line::InValue`] told from the line that opened the
/// value, and the two are not interchangeable: a caller holding an
/// assignment reads the fact off that line, which is the only place it is
/// there to read when the file ends with the value still open.
#[test]
fn a_line_says_for_itself_whether_it_left_a_value_open() {
    let carries = |text: &str| -> Vec<bool> { rows(text).iter().map(|row| row.carries).collect() };
    for open in ["\"\"\"", "'''", "["] {
        // Opened, carried, closed: only the last line is clear again.
        let closed = format!("A = {open}\ntext\n{}\n", close_of(open));
        assert_eq!(carries(&closed), [true, true, false], "{open}");
        // Left open at the end of the file, where no line below it exists
        // to be InValue.
        let unclosed = format!("A = {open}\n");
        assert_eq!(carries(&unclosed), [true], "{open}");
    }
    // A value that closes on its own line carries nothing.
    assert_eq!(carries("A = \"one\"\nB = \"two\"\n"), [false, false]);
}

/// The delimiter that closes what this one opens.
fn close_of(open: &str) -> &str {
    match open {
        "[" => "]",
        other => other,
    }
}

/// The other half of what a line leaves behind, and not the negation of
/// `carries`: a single-line string ends with its line, so one left
/// unterminated carries nothing and is still not finished. A caller
/// reading completeness off `carries` alone calls `TOKEN = "` closed.
#[test]
fn a_form_the_grammar_cannot_continue_says_so_without_carrying() {
    let ends = |text: &str| -> Vec<(bool, bool)> {
        rows(text)
            .iter()
            .map(|row| (row.carries, row.broken))
            .collect()
    };
    for quote in ['"', '\''] {
        assert_eq!(
            ends(&format!("TOKEN = {quote}\nMODE = \"real\"\n")),
            [(false, true), (false, false)],
            "{quote}: broken, and the line under it is structure again"
        );
    }
    // Nothing else can be broken: every other container carries, so a
    // later line closes it or the carry runs off the end of the file.
    // A value that closes says neither, whatever its form.
    for closed in [
        "TOKEN = \"ok\"\n",
        "MAP = { a = 1 }\n",
        "MAP = { a = { b = 1 } }\n",
        "MAP = { a = \"}\" }\n",
        "LIST = [1, 2]\n",
        // The scalars, which have no delimiters to leave open at all.
        "N = 12\n",
        "F = 1.5\n",
        "B = true\n",
        "D = 1979-05-27T07:32:00Z\n",
        "D = 1979-05-27\n",
        "D = 07:32:00\n",
    ] {
        assert_eq!(ends(closed), [(false, false)], "{closed:?}");
    }
    // And one that carries says only that it carries — the string and
    // array answers are unchanged.
    assert_eq!(
        ends("BLOB = \"\"\"\ntext\n\"\"\"\n"),
        [(true, false), (true, false), (false, false)]
    );
    assert_eq!(
        ends("LIST = [\n  1,\n]\n"),
        [(true, false), (true, false), (false, false)]
    );
    // An inline table carries by depth like an array, so what is legal
    // inside one is whatever is legal in any other container.
    assert_eq!(
        ends("MAP = {\na = 1\n}\n"),
        [(true, false), (true, false), (false, false)],
        "the lines under it are the value's, not structure"
    );
    assert_eq!(
        ends("MAP = { items = [\n  1,\n] }\n"),
        [(true, false), (true, false), (false, false)],
        "a multiline array nested in an inline table"
    );
    assert_eq!(
        ends("MAP = { a = { b = 1 }\n"),
        [(true, false)],
        "the outer table is still open"
    );
    assert_eq!(
        ends("LIST = [\n  { a = 1 },\n]\n"),
        [(true, false), (true, false), (false, false)],
        "and an inline table nested in an array"
    );
    // Depth is what answers, so the two nest through each other.
    assert_eq!(
        ends("LIST = [\n  { a = [\n    1,\n  ] },\n]\n"),
        [
            (true, false),
            (true, false),
            (true, false),
            (true, false),
            (false, false)
        ]
    );
}

/// What follows a readable value, and where. The offset matters because a
/// caller cutting the comment off cannot re-find the `#`: the first one on
/// the line may be inside the value.
#[test]
fn a_trailing_comment_is_read_with_the_offset_that_cuts_it() {
    assert_eq!(
        trailing_comment(" \"900\" # required"),
        Some((7, "required"))
    );
    assert_eq!(trailing_comment(" \"900\"#required"), Some((6, "required")));
    assert_eq!(trailing_comment(" \"900\" #"), Some((7, "")));
    assert_eq!(trailing_comment(" \"900\""), None);
    assert_eq!(trailing_comment(" \"a # b\""), None);
    let value = " \"a # b\" # required";
    let (at, said) = trailing_comment(value).expect("the comment after the value");
    assert_eq!(said, "required");
    assert_eq!(&value[..at], " \"a # b\" ");
    // Not a value the loaders read: nothing to say about what follows it.
    assert_eq!(trailing_comment(" 900 # required"), None);
}
