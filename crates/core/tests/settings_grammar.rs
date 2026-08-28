//! One grammar, two readers, one corpus.
//!
//! A template's `[env]` table is copied into a consumer's
//! `kendex.settings.toml`, where the shell loaders read it. So the loaders
//! decide what a template may say, and `settings_template::read` has to
//! report a finding for exactly the samples they refuse or skip. Both sides
//! run against `fixtures/settings-grammar.tsv` here: a divergence in either
//! direction fails this test instead of reaching a review.
#![cfg(unix)]

use std::path::{Path, PathBuf};
use std::process::Command;

use kendex_core::settings_template::{decoded_value, read};

/// What the loaders do with one sample.
#[derive(Debug, PartialEq, Eq)]
enum Verdict {
    /// Loaded, and the key exports this value.
    Loads(String),
    /// The whole file fails loud.
    Refused,
    /// Loaded, and nothing ever reads the key.
    Unread,
}

struct Row {
    name: String,
    verdict: Verdict,
    key: String,
    body: String,
}

fn root() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("../..")
}

fn corpus_path() -> PathBuf {
    Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/settings-grammar.tsv")
}

/// `\n` is a newline and `\\` a backslash; every other byte is itself.
fn unescape(body: &str) -> String {
    let mut out = String::with_capacity(body.len());
    let mut chars = body.chars();
    while let Some(c) = chars.next() {
        match (c, chars.clone().next()) {
            ('\\', Some('n')) => {
                chars.next();
                out.push('\n');
            }
            ('\\', Some('\\')) => {
                chars.next();
                out.push('\\');
            }
            _ => out.push(c),
        }
    }
    out
}

#[allow(clippy::unwrap_used)]
fn rows() -> Vec<Row> {
    let text = std::fs::read_to_string(corpus_path()).unwrap();
    text.lines()
        .filter(|line| !line.is_empty() && !line.starts_with('#'))
        .map(|line| {
            let fields: Vec<&str> = line.split('\t').collect();
            assert_eq!(fields.len(), 5, "five columns per row: {line}");
            let verdict = match fields[1] {
                "loads" => Verdict::Loads(
                    fields[3]
                        .strip_prefix('"')
                        .and_then(|value| value.strip_suffix('"'))
                        .unwrap_or_else(|| panic!("a loads row quotes its value: {line}"))
                        .to_owned(),
                ),
                "refused" => Verdict::Refused,
                "unread" => Verdict::Unread,
                other => panic!("unknown verdict {other}: {line}"),
            };
            Row {
                name: fields[0].to_owned(),
                verdict,
                key: fields[2].to_owned(),
                body: unescape(fields[4]),
            }
        })
        .collect()
}

/// The real loaders, run over every sample by
/// `fixtures/settings-grammar-loaders.sh`: `name -> (kendex-env.sh,
/// settings.sh)`.
#[allow(clippy::unwrap_used)]
fn observed() -> Vec<(String, String, String)> {
    let script =
        Path::new(env!("CARGO_MANIFEST_DIR")).join("tests/fixtures/settings-grammar-loaders.sh");
    let output = Command::new("bash")
        .arg(&script)
        .arg(root())
        .arg(corpus_path())
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "the loader harness failed:\n{}",
        String::from_utf8_lossy(&output.stderr)
    );
    String::from_utf8_lossy(&output.stdout)
        .lines()
        .map(|line| {
            let fields: Vec<&str> = line.split('\t').collect();
            assert_eq!(fields.len(), 3, "three columns per observation: {line}");
            (
                fields[0].to_owned(),
                fields[1].to_owned(),
                fields[2].to_owned(),
            )
        })
        .collect()
}

fn spelled(verdict: &Verdict) -> String {
    match verdict {
        Verdict::Loads(value) => format!("loads:{value}"),
        Verdict::Refused => "refused".to_owned(),
        Verdict::Unread => "unread".to_owned(),
    }
}

/// The corpus records what the loaders actually do. Both families are run,
/// because a key resolves through whichever one its skill vendored: a
/// sample they disagree on is a defect in the loaders, not a verdict to
/// record.
#[test]
#[allow(clippy::unwrap_used)]
fn the_corpus_records_what_both_loaders_do() {
    let rows = rows();
    let observed = observed();
    assert_eq!(rows.len(), observed.len(), "one observation per row");
    for (row, (name, env_sh, settings_sh)) in rows.iter().zip(observed) {
        assert_eq!(row.name, name, "the harness walks the corpus in order");
        assert_eq!(env_sh, settings_sh, "the two loaders disagree on {name}");
        assert_eq!(env_sh, spelled(&row.verdict), "{name}");
    }
}

/// The reader reports a finding for every sample the loaders will not read
/// as written, and none for a sample they read cleanly. Every body is an
/// otherwise well-formed template — one `[env]` table, a comment block over
/// every key — so a finding here is about the grammar and nothing else.
#[test]
#[allow(clippy::unwrap_used)]
fn the_reader_flags_exactly_what_the_loaders_cannot_read() {
    for row in rows() {
        let found = read(&row.body).findings;
        match &row.verdict {
            Verdict::Loads(_) => assert!(
                found.is_empty(),
                "{}: the loaders read this, the reader refused it: {found:?}",
                row.name
            ),
            _ => assert!(
                !found.is_empty(),
                "{}: the loaders will not read this and the reader said nothing",
                row.name
            ),
        }
    }
}

/// A value the loaders read decodes to the value they export. This is the
/// half a finding count cannot catch: a reader that accepts the line and
/// then decodes something else seeds a default nobody chose.
#[test]
#[allow(clippy::unwrap_used)]
fn a_readable_value_decodes_to_what_the_loaders_export() {
    for row in rows() {
        let Verdict::Loads(exported) = &row.verdict else {
            continue;
        };
        let entries = read(&row.body).entries;
        let entry = entries
            .iter()
            .find(|entry| entry.key == row.key)
            .unwrap_or_else(|| panic!("{}: no row for {}", row.name, row.key));
        assert_eq!(&entry.value, exported, "{}", row.name);
        let line = row
            .body
            .lines()
            .nth(entry.line - 1)
            .unwrap_or_else(|| panic!("{}: line {} is off the end", row.name, entry.line));
        assert_eq!(decoded_value(line).as_ref(), Some(exported), "{}", row.name);
    }
}
