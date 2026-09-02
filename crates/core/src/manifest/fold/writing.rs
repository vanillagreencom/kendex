//! The writing about each entry of a list: reading it off the slots TOML
//! keeps it in, and putting it back.
//!
//! This module exists to make one invariant hold for both list spellings: the
//! writing about an entry has to be reachable from that entry, or moving the
//! entry hands its annotation to whatever lands in its slot.
//!
//! A `[[table]]` entry meets that as parsed — a table's comment is its own
//! prefix, which is why [`as_tables`] moves the table and nothing else.
//! An array of values does not. TOML keeps the run between one value and the
//! next against the LOWER value, so the annotation somebody wrote after an
//! entry is stored on the entry below it, and the bytes before `]` are the
//! last value's suffix or the array's trailing text depending on a comma. So
//! the array is read into [`Written`] first, and [`as_array`] works from that
//! rather than from raw decoration: a spelling that cannot say what was
//! written about its own entries cannot be rebuilt at all, which is what stops
//! the next one from opting out by omission.
//!
//! Nothing here decides which entry continues which — that is `paired`'s — and
//! nothing here reads a manifest. It owns the punctuation and no more.

use toml_edit::{Array, ArrayOfTables, Item, RawString, Table, Value};

/// The writing about one entry, in the three places TOML keeps it.
#[derive(Clone, Default)]
pub(super) struct Written {
    /// What the entry sits behind on its own line.
    pub(super) lead: String,
    /// What stands between the entry and the comma after it.
    pub(super) close: String,
    /// The rest of the line the entry sat on, after that comma.
    pub(super) tail: String,
}

/// One array's bracket span: what was written about each entry it held, and
/// what belongs to the brackets themselves.
pub(super) struct Span {
    /// The rest of the line the `[` sat on.
    pub(super) opener: String,
    /// What sits on its own lines before the `]`.
    pub(super) closer: String,
    entries: Vec<Written>,
    indent: String,
    broken: bool,
}

impl Span {
    pub(super) fn of(array: &Array) -> Span {
        let prefixes: Vec<String> = array
            .iter()
            .map(|value| decoration(value.decor().prefix()))
            .collect();
        let suffixes: Vec<String> = array
            .iter()
            .map(|value| decoration(value.decor().suffix()))
            .collect();
        let trailing = decoration(Some(array.trailing()));
        // Where the run before `]` is kept: the array's trailing text when the
        // list ends with a comma, the last value's suffix when it does not. An
        // array with no values keeps the whole span in its trailing.
        let closing = match (array.trailing_comma(), suffixes.last()) {
            (false, Some(last)) => last.clone(),
            _ => trailing.clone(),
        };
        let last = prefixes.len().saturating_sub(1);
        let entries: Vec<Written> = prefixes
            .iter()
            .enumerate()
            .map(|(index, prefix)| Written {
                lead: split(prefix).1.to_owned(),
                close: match (index == last, array.trailing_comma()) {
                    // With no comma after it, the last value's suffix is not a
                    // suffix at all: it is the run before the bracket, and
                    // `tail` and `closer` have it.
                    (true, false) => String::new(),
                    _ => suffixes[index].clone(),
                },
                tail: match index == last {
                    true => split(&closing).0.to_owned(),
                    false => split(&prefixes[index + 1]).0.to_owned(),
                },
            })
            .collect();
        Span {
            opener: split(prefixes.first().unwrap_or(&trailing)).0.to_owned(),
            closer: split(&closing).1.to_owned(),
            // The last line of the first entry's lead, because a lead can
            // carry whole comment lines of its own and only the run after the
            // final break is what holds a value out from the margin.
            indent: entries
                .first()
                .and_then(|first| first.lead.rsplit('\n').next())
                .unwrap_or_default()
                .to_owned(),
            broken: prefixes
                .iter()
                .chain(&suffixes)
                .chain(std::iter::once(&trailing))
                .any(|run| run.contains('\n')),
            entries,
        }
    }

    /// What was written about the entry that stood at `at`.
    ///
    /// An entry the list did not have has nothing written about it, so it
    /// takes the shape the list is already in: the array's own indent and a
    /// line of its own where the array breaks across lines, and otherwise the
    /// single space that separates entries — before it where it lands last,
    /// after it everywhere else, because the entry it displaced carries its
    /// own lead and would double the space.
    pub(super) fn written(&self, at: Option<usize>, last: bool) -> Written {
        match at.and_then(|at| self.entries.get(at)) {
            Some(written) => written.clone(),
            None if self.broken => Written {
                lead: self.indent.clone(),
                tail: "\n".to_owned(),
                ..Written::default()
            },
            None if last => Written {
                lead: " ".to_owned(),
                ..Written::default()
            },
            None => Written {
                tail: " ".to_owned(),
                ..Written::default()
            },
        }
    }
}

/// A run split into the tail of the line before it and what sits on its own
/// lines after that. A run with no line break is all tail of the line before,
/// because a comment cannot end without one.
fn split(text: &str) -> (&str, &str) {
    match text.find('\n') {
        Some(at) => text.split_at(at + 1),
        None => (text, ""),
    }
}

/// The bytes a decoration stands for. A parsed document spells every one of
/// them; anything the encoder would have defaulted reads as empty here, which
/// is what a rebuilt array states outright instead.
fn decoration(raw: Option<&RawString>) -> String {
    raw.and_then(RawString::as_str)
        .unwrap_or_default()
        .to_owned()
}

/// Both spellings put an entry back with the writing about that entry, and this
/// is the one place that says what that means. A table carries its own
/// decoration, so [`as_tables`] moves the table; a value does not, so
/// [`as_array`] goes through [`Span`], which reads the bracket run into
/// the writing about each entry before anything moves. A list spelled some
/// third way reaches neither and cannot be rebuilt, rather than being rebuilt
/// out of raw decoration that means something else.
pub(super) fn rebuild(destination: &mut Item, rebuilt: &[(Option<usize>, Item)]) {
    match destination {
        Item::ArrayOfTables(tables) => *tables = as_tables(rebuilt),
        Item::Value(Value::Array(array)) => *array = as_array(array, rebuilt),
        // `entries` answered for this item one statement ago, and it admits
        // exactly the two spellings above.
        other => unreachable!("a list is a table array or an array, not {other:?}"),
    }
}

/// The folded entries as an array of tables, in the places the surviving
/// entries already held. A table renders where its position says, so entries
/// that changed places have to change positions with them or the file would
/// come back in the old order. The places redealt are the survivors' own, so
/// no table OUTSIDE this list changes position — an entry may cross one that
/// sits between two of the list's own places, which is what a person asked for
/// when they re-sorted a list written around another table. An entry the list
/// gained has no position and renders beside the one before it.
fn as_tables(rebuilt: &[(Option<usize>, Item)]) -> ArrayOfTables {
    let mut tables: Vec<Table> = rebuilt
        .iter()
        .map(|(_, entry)| match entry {
            Item::Table(table) => table.clone(),
            Item::Value(Value::InlineTable(table)) => table.clone().into_table(),
            // Every entry came out of `entries`, which yields a table for one
            // spelling and a value for the other; a scalar list is not a
            // shape `[[key]]` can hold.
            other => unreachable!("a table array holds tables, not {other:?}"),
        })
        .collect();
    let mut places: Vec<isize> = tables.iter().filter_map(Table::position).collect();
    places.sort_unstable();
    let mut places = places.into_iter();
    for table in &mut tables {
        if table.position().is_some() {
            table.set_position(places.next());
        }
    }
    let mut built = ArrayOfTables::new();
    for table in tables {
        built.push(table);
    }
    built
}

/// The folded entries as an inline array, each carrying the writing about
/// itself and the brackets keeping what is theirs. A list nothing changed
/// comes back byte for byte; an entry that went takes the annotation written
/// about it and leaves every other one on the entry it describes.
fn as_array(destination: &Array, rebuilt: &[(Option<usize>, Item)]) -> Array {
    let span = Span::of(destination);
    let mut built = Array::new();
    built.set_trailing_comma(destination.trailing_comma());
    *built.decor_mut() = destination.decor().clone();
    let last = rebuilt.len().saturating_sub(1);
    let mut lead = span.opener.clone();
    let mut tail = String::new();
    for (index, (at, entry)) in rebuilt.iter().enumerate() {
        let written = span.written(*at, index == last);
        let mut value = match entry {
            Item::Value(value) => value.clone(),
            Item::Table(table) => Value::InlineTable(table.clone().into_inline_table()),
            other => unreachable!("an array holds values, not {other:?}"),
        };
        value
            .decor_mut()
            .set_prefix(format!("{lead}{}", written.lead));
        value.decor_mut().set_suffix(written.close);
        built.push_formatted(value);
        lead.clone_from(&written.tail);
        tail = written.tail;
    }
    // A list nothing is left in closes on the bracket it opened on: the lines
    // its entries stood on are the entries', and they went with them.
    built.set_trailing(match rebuilt.is_empty() {
        true => String::new(),
        false => format!("{tail}{}", span.closer),
    });
    built
}

/// A subtree lifted out of the serialized document and ready to land in
/// somebody else's. The serializer's own table positions come with it and
/// would place the table by where its field sat there; cleared, a table
/// renders after the one it was inserted behind, which is where its
/// neighbours are.
pub(super) fn fresh(item: &Item) -> Item {
    let mut item = item.clone();
    unposition(&mut item);
    item
}

fn unposition(item: &mut Item) {
    match item {
        Item::Table(table) => unposition_table(table),
        Item::ArrayOfTables(tables) => tables.iter_mut().for_each(unposition_table),
        Item::Value(_) | Item::None => {}
    }
}

fn unposition_table(table: &mut Table) {
    table.set_position(None);
    for (_, item) in table.iter_mut() {
        unposition(item);
    }
}
