//! Folding a write into the document the person wrote.
//!
//! kendex.toml is written by hand, so a write may not re-serialize it. What
//! kendex holds is serialized on its own and walked against the file that is
//! there, and only where the two disagree is anything edited. `toml_edit`
//! keeps the bytes of every key the walk does not touch, so comments, blank
//! lines, key order and the spelling of every untouched value survive
//! because nothing rewrote them.

use toml_edit::{DocumentMut, Item, TableLike, Value};

/// The text a write should leave behind: the document that is already
/// there, with the keys this write names edited into it.
///
/// `current` is the file as it stands, `held` the serialization of the
/// manifest that file reads back as, and `desired` the serialization of the
/// manifest to write. `held` is what settles a removal: a key it names and
/// `desired` does not is a key the manifest really dropped, and a key it
/// never names was never the manifest's — a note somebody left inside a
/// declaration, or a flag the serializer omits at its default — so nothing
/// here has to know which keys the model can spell.
///
/// Every parse is answered rather than assumed: `current` is somebody's
/// file and the other two are this crate's own serializer, so a failure on
/// any of them is a refusal and never a rewrite.
pub(super) fn folded(
    current: &str,
    held: &str,
    desired: &str,
) -> std::result::Result<String, toml_edit::TomlError> {
    let mut document: DocumentMut = current.parse()?;
    let held: DocumentMut = held.parse()?;
    let target: DocumentMut = desired.parse()?;
    fold_table(
        document.as_table_mut(),
        Some(held.as_table()),
        target.as_table(),
    );
    Ok(document.to_string())
}

/// Walk two tables together. Keys are compared by name, so a table spelled
/// `[a.b]`, `a.b = {}` or `a.b.c = 1` all fold as the same table — the
/// destination keeps whichever spelling it already had.
fn fold_table(
    destination: &mut dyn TableLike,
    held: Option<&dyn TableLike>,
    target: &dyn TableLike,
) {
    let gone: Vec<String> = destination
        .iter()
        .map(|(key, _)| key.to_owned())
        .filter(|key| target.get(key).is_none())
        .filter(|key| held.is_some_and(|held| held.get(key).is_some()))
        .collect();
    for key in gone {
        destination.remove(&key);
    }
    for (key, wanted) in target.iter() {
        match destination.get_mut(key) {
            Some(item) => fold_item(item, held.and_then(|held| held.get(key)), wanted),
            None => {
                destination.insert(key, wanted.clone());
            }
        }
    }
}

/// The one walk. Tables recurse; everything else is a leaf, and a leaf that
/// already says what kendex holds is left with its own bytes.
///
/// A leaf that changed is written in the serializer's own spelling, so a
/// list an operation edits comes back on one line however it was written.
/// What the person wrote *around* the key survives — the whitespace before
/// the value and any comment after it belong to the key, not to the value
/// that was there — and what they wrote *inside* a list they are editing
/// does not. That is the boundary invariant 10 draws: a write changes the
/// keys it names and nothing else.
///
/// A `[[table]]` array is the one list that recurses, while it keeps its
/// length: each entry stays the table it was, in the place it was written,
/// so the note above one hook and the flag written inside another survive a
/// write that names neither. An entry gained or dropped moves everything
/// after it, and the array is written whole like any other list.
fn fold_item(destination: &mut Item, held: Option<&Item>, target: &Item) {
    if target.as_table_like().is_some() && destination.as_table_like().is_some() {
        if let Some(wanted) = target.as_table_like()
            && let Some(item) = destination.as_table_like_mut()
        {
            fold_table(item, held.and_then(Item::as_table_like), wanted);
        }
        return;
    }
    if let (Item::ArrayOfTables(standing), Item::ArrayOfTables(wanted)) =
        (&mut *destination, target)
        && standing.len() == wanted.len()
    {
        // `held` is this same file read back, so its entries stand one for
        // one against the destination's and each fold gets the model's view
        // of the entry it is editing.
        let held = match held {
            Some(Item::ArrayOfTables(held)) if held.len() == wanted.len() => Some(held),
            _ => None,
        };
        for (index, (entry, wanted)) in standing.iter_mut().zip(wanted.iter()).enumerate() {
            let held = held
                .and_then(|held| held.get(index))
                .map(|held| held as &dyn TableLike);
            fold_table(entry, held, wanted);
        }
        return;
    }
    if same_item(destination, target) {
        return;
    }
    if let (Item::Value(item), Item::Value(wanted)) = (&mut *destination, target) {
        let mut replacement = wanted.clone();
        *replacement.decor_mut() = item.decor().clone();
        *item = replacement;
        return;
    }
    *destination = target.clone();
}

/// Whether this subtree already says what kendex holds. Only a difference
/// reaches an edit, which is what keeps a write off the spelling of every
/// value it did not change.
fn same_item(left: &Item, right: &Item) -> bool {
    if let (Some(left), Some(right)) = (left.as_table_like(), right.as_table_like()) {
        return left.len() == right.len()
            && left
                .iter()
                .all(|(key, value)| right.get(key).is_some_and(|other| same_item(value, other)));
    }
    if let (Some(left), Some(right)) = (entries(left), entries(right)) {
        return left.len() == right.len()
            && left
                .iter()
                .zip(&right)
                .all(|(left, right)| same_item(left, right));
    }
    match (left, right) {
        (Item::Value(left), Item::Value(right)) => same_value(left, right),
        (Item::None, Item::None) => true,
        _ => false,
    }
}

/// A read-only view of a list's entries, whichever way it is spelled. An
/// inline `custom-hooks = [{ … }]` and a `[[custom-hooks]]` array say the
/// same thing, so a write that changes neither leaves the one on disk alone.
fn entries(item: &Item) -> Option<Vec<Item>> {
    match item {
        Item::ArrayOfTables(tables) => Some(tables.iter().cloned().map(Item::Table).collect()),
        Item::Value(Value::Array(values)) => {
            Some(values.iter().cloned().map(Item::Value).collect())
        }
        _ => None,
    }
}

/// Whether this leaf already says what kendex holds.
fn same_value(left: &Value, right: &Value) -> bool {
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
