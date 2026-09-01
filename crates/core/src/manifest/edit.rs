//! Folding a manifest into the document the person wrote.
//!
//! kendex.toml is the one file in the product that is entirely somebody's
//! own writing, so a write may not re-serialize it. What kendex holds is
//! serialized on its own, and the two documents are walked together: a key
//! whose value already says the right thing is not touched at all, a key
//! that changed keeps its formatting and takes the new value, a key kendex
//! no longer holds goes, and a key kendex gained is appended where its
//! neighbours are. Comments, blank lines, key order and the spelling of
//! every untouched value survive that, because nothing rewrote them.
//!
//! The one thing a write still adds where nobody asked is a field serde
//! spells out at its default — `enabled = true` under a declaration that
//! omitted it. Skipping those in the serialization would put them on the
//! other side of this walk, where a key kendex holds and the
//! serialization does not mention reads as a key kendex dropped: the
//! `enabled = true` somebody typed by hand would be deleted. A line added
//! once and stable after is the better of the two.

use toml_edit::{ArrayOfTables, DocumentMut, Item, Table, TableLike, Value};

/// The text a write should leave behind: `desired` — the serialization of
/// what kendex holds — folded into `current`, the file as it stands.
///
/// Both parses are answered rather than assumed: `current` is somebody's
/// file, and `desired` is this crate's own serializer, so a failure on
/// either is a refusal and never a rewrite.
pub(super) fn merged(current: &str, desired: &str) -> Result<String, toml_edit::TomlError> {
    let mut document: DocumentMut = current.parse()?;
    let target: DocumentMut = desired.parse()?;
    merge_table(document.as_table_mut(), target.as_table());
    Ok(document.to_string())
}

/// Walk two tables together. Keys are compared by name, so a table spelled
/// `[a.b]`, `a.b = {}` or `a.b.c = 1` all merge as the same table — the
/// destination keeps whichever spelling it already had.
fn merge_table(destination: &mut dyn TableLike, target: &dyn TableLike) {
    let gone: Vec<String> = destination
        .iter()
        .map(|(key, _)| key.to_owned())
        .filter(|key| target.get(key).is_none())
        .collect();
    for key in gone {
        destination.remove(&key);
    }
    for (key, wanted) in target.iter() {
        match destination.get_mut(key) {
            Some(held) => merge_item(held, wanted),
            None => {
                destination.insert(key, fresh(wanted));
            }
        }
    }
}

fn merge_item(destination: &mut Item, target: &Item) {
    if same_item(destination, target) {
        return;
    }
    if let Some(wanted) = target.as_table_like()
        && let Some(held) = destination.as_table_like_mut()
    {
        merge_table(held, wanted);
        return;
    }
    if let (Item::ArrayOfTables(held), Item::ArrayOfTables(wanted)) = (&mut *destination, target) {
        merge_array_of_tables(held, wanted);
        return;
    }
    // A value that changed keeps its own decoration — the whitespace
    // before it and any comment after it are the person's, not the old
    // value's. Anything else is replaced whole, which is only reached
    // where the two documents disagree about what shape the key is.
    if let (Item::Value(held), Item::Value(wanted)) = (&mut *destination, target) {
        let mut replacement = wanted.clone();
        *replacement.decor_mut() = held.decor().clone();
        *held = replacement;
        return;
    }
    *destination = fresh(target);
}

/// `[[custom-hooks]]`: entries are matched by position, so editing one
/// hook leaves the comments inside every other entry alone.
fn merge_array_of_tables(destination: &mut ArrayOfTables, target: &ArrayOfTables) {
    while destination.len() > target.len() {
        destination.remove(destination.len() - 1);
    }
    for (index, wanted) in target.iter().enumerate() {
        match destination.get_mut(index) {
            Some(held) => merge_table(held, wanted),
            None => {
                let mut table = wanted.clone();
                unposition_table(&mut table);
                destination.push(table);
            }
        }
    }
}

/// A subtree lifted out of the serialized document and ready to land in
/// somebody else's. The serializer's own table positions come with it and
/// would place the table by where it sat there; cleared, a table renders
/// after the one it was inserted behind, which is where its neighbours are.
fn fresh(item: &Item) -> Item {
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

/// Whether these two say the same thing, whatever they look like. This is
/// what keeps a write off every key it did not change: only a difference
/// here reaches an edit.
fn same_item(left: &Item, right: &Item) -> bool {
    if let (Some(left), Some(right)) = (left.as_table_like(), right.as_table_like()) {
        return same_table(left, right);
    }
    if let (Some(left), Some(right)) = (sequence(left), sequence(right)) {
        return left.len() == right.len()
            && left
                .iter()
                .zip(&right)
                .all(|(left, right)| same_item(left, right));
    }
    match (left, right) {
        (Item::Value(left), Item::Value(right)) => same_scalar(left, right),
        _ => false,
    }
}

fn same_table(left: &dyn TableLike, right: &dyn TableLike) -> bool {
    let held = |table: &dyn TableLike| -> Vec<String> {
        table
            .iter()
            .filter(|(_, item)| !item.is_none())
            .map(|(key, _)| key.to_owned())
            .collect()
    };
    let keys = held(left);
    keys.len() == held(right).len()
        && keys
            .iter()
            .all(|key| match (left.get(key), right.get(key)) {
                (Some(left), Some(right)) => same_item(left, right),
                _ => false,
            })
}

/// The two spellings of a list — `[[table]]` entries and an inline array —
/// read as one sequence, so neither is rewritten into the other.
fn sequence(item: &Item) -> Option<Vec<Item>> {
    match item {
        Item::ArrayOfTables(tables) => Some(tables.iter().cloned().map(Item::Table).collect()),
        Item::Value(Value::Array(values)) => {
            Some(values.iter().cloned().map(Item::Value).collect())
        }
        _ => None,
    }
}

fn same_scalar(left: &Value, right: &Value) -> bool {
    match (left, right) {
        (Value::String(left), Value::String(right)) => left.value() == right.value(),
        (Value::Integer(left), Value::Integer(right)) => left.value() == right.value(),
        // By bits: two floats that print the same are the same bytes, and
        // that is the question here, not numeric equality.
        (Value::Float(left), Value::Float(right)) => {
            left.value().to_bits() == right.value().to_bits()
        }
        (Value::Boolean(left), Value::Boolean(right)) => left.value() == right.value(),
        (Value::Datetime(left), Value::Datetime(right)) => left.value() == right.value(),
        _ => false,
    }
}

#[cfg(test)]
mod tests;
