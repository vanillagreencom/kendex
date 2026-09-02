//! Folding a write into the document the person wrote.
//!
//! kendex.toml is written by hand, so a write may not re-serialize it. What
//! kendex holds is serialized on its own and walked against the file that is
//! there, and only where the two disagree is anything edited. `toml_edit`
//! keeps the bytes of every key the walk does not touch, so comments, blank
//! lines, key order and the spelling of every untouched value survive
//! because nothing rewrote them.
//!
//! Two things the walk is careful about.
//!
//! What a write may remove is settled by `held`, a third document: the same
//! serialization taken of the manifest read back out of this very file. A key
//! it names and the target does not is a key the manifest really dropped, and
//! the sweep takes it. A key it never names was never the manifest's — a note
//! somebody left inside a declaration, or a flag the serializer omits at its
//! default — and the sweep passes over it. Nothing here has to know which keys
//! the model can spell.
//!
//! Lists are edited in the shape they were written in. An inline
//! `custom-hooks = [{ … }]` and a `[[custom-hooks]]` array say the same thing,
//! so entries fold against each other across the two spellings and neither is
//! rewritten into the other. Which entry continues which is decided against
//! `held` — an entry whose model view the target still holds keeps its slot,
//! so the comment above it and the keys inside it the model does not carry
//! travel with it through a removal or a re-sort. What identity cannot place
//! pairs in order, which is what keeps an edit an edit rather than a drop and
//! an append, and it has a price: an entry paired that way stands under
//! whatever was written about the entry that held its slot.

use toml_edit::{Array, ArrayOfTables, DocumentMut, Item, Table, TableLike, Value};

/// The text a write should leave behind: the document that is already
/// there, with the keys this write names edited into it.
///
/// `current` is the file as it stands, `held` the serialization of the
/// manifest that file reads back as, and `desired` the serialization of the
/// manifest to write.
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
                destination.insert(key, fresh(wanted));
            }
        }
    }
}

/// The one walk. Tables recurse, lists fold entry by entry, and everything
/// else is a leaf: one that already says what kendex holds keeps its own
/// bytes, and one that changed keeps the writing around it — the whitespace
/// before the value and any comment after it belong to the key, not to the
/// value that was there.
fn fold_item(destination: &mut Item, held: Option<&Item>, target: &Item) {
    // The outer test is what makes the brace run readable: it is taken off
    // the whole item before the walk and put back after, and inside the
    // let-chain the destination is already borrowed mutably.
    if target.as_table_like().is_some() && destination.as_table_like().is_some() {
        let brace = brace_run(destination);
        if let Some(wanted) = target.as_table_like()
            && let Some(item) = destination.as_table_like_mut()
        {
            fold_table(item, held.and_then(Item::as_table_like), wanted);
        }
        reseat_brace(destination, brace);
        return;
    }
    if fold_entries(destination, held, target) {
        return;
    }
    if let (Item::Value(item), Item::Value(wanted)) = (&mut *destination, target) {
        if same_value(item, wanted) {
            return;
        }
        let mut replacement = wanted.clone();
        *replacement.decor_mut() = item.decor().clone();
        *item = replacement;
        return;
    }
    *destination = fresh(target);
}

/// One list, folded entry by entry in the spelling the destination is written
/// in. `false` where either side is not a list, so the caller falls through to
/// its leaf handling.
///
/// Each surviving entry is the destination's own, folded against the target
/// entry it continues, so the writing around it and the keys inside it the
/// manifest does not carry stay where they were put. An entry the list did not
/// have arrives unpositioned, which is what places a gained `[[table]]` beside
/// its siblings rather than at the end of the file.
fn fold_entries(destination: &mut Item, held: Option<&Item>, target: &Item) -> bool {
    let (Some(standing), Some(wanted)) = (entries(destination), entries(target)) else {
        return false;
    };
    let held = held.and_then(entries).unwrap_or_default();
    let rebuilt: Vec<Item> = wanted
        .iter()
        .zip(paired(standing.len(), &held, &wanted))
        .map(|(wanted, at)| match at.and_then(|at| standing.get(at)) {
            Some(entry) => {
                let mut entry = entry.clone();
                fold_item(&mut entry, at.and_then(|at| held.get(at)), wanted);
                entry
            }
            None => fresh(wanted),
        })
        .collect();
    match destination {
        Item::ArrayOfTables(tables) => *tables = as_tables(&rebuilt),
        Item::Value(Value::Array(array)) => *array = as_array(array, &rebuilt),
        // `entries` answered for this item one statement ago, and it admits
        // exactly the two spellings above.
        other => unreachable!("a list is a table array or an array, not {other:?}"),
    }
    true
}

/// Which destination entry each target entry continues.
///
/// `held` is what the destination's entries mean to the model, one for one, so
/// a target entry equal to one of them is that entry still standing: it keeps
/// its slot through a removal or a re-sort, and the comment written above it
/// and the keys inside it the model does not carry go with it. A target entry
/// no held entry matches is either gained or an edit of one; it takes, in
/// order, whatever slot identity left free, and `None` once none are.
///
/// `held` stands one for one against the destination wherever it speaks for it
/// at all. Where it is longer — a slot filled by position rather than by
/// identity can hand an entry the model's view of a different one — the
/// reading stops at the destination's own length, so nothing identifies an
/// entry that is not there and every slot past it pairs by position.
fn paired(standing: usize, held: &[Item], target: &[Item]) -> Vec<Option<usize>> {
    let mut taken = vec![false; standing];
    let mut pairing: Vec<Option<usize>> = vec![None; target.len()];
    for (index, wanted) in target.iter().enumerate() {
        for (at, entry) in held.iter().enumerate().take(standing) {
            if !taken[at] && same_entry(entry, wanted) {
                pairing[index] = Some(at);
                taken[at] = true;
                break;
            }
        }
    }
    let mut free = (0..standing).filter(|at| !taken[*at]);
    for slot in pairing.iter_mut().filter(|slot| slot.is_none()) {
        *slot = free.next();
    }
    pairing
}

/// Whether two serialized entries say the same thing. Both sides come from
/// this crate's own serializer, so this is structural equality and nothing is
/// exempt from it — the question `paired` asks is which entry of the manifest
/// this used to be, not which bytes a person wrote around it.
fn same_entry(left: &Item, right: &Item) -> bool {
    if let (Some(left), Some(right)) = (left.as_table_like(), right.as_table_like()) {
        return left.len() == right.len()
            && left
                .iter()
                .all(|(key, value)| right.get(key).is_some_and(|other| same_entry(value, other)));
    }
    if let (Some(left), Some(right)) = (entries(left), entries(right)) {
        return left.len() == right.len()
            && left
                .iter()
                .zip(&right)
                .all(|(left, right)| same_entry(left, right));
    }
    match (left, right) {
        (Item::Value(left), Item::Value(right)) => same_value(left, right),
        (Item::None, Item::None) => true,
        _ => false,
    }
}

/// A read-only view of a list's entries, whichever way it is spelled.
fn entries(item: &Item) -> Option<Vec<Item>> {
    match item {
        Item::ArrayOfTables(tables) => Some(tables.iter().cloned().map(Item::Table).collect()),
        Item::Value(Value::Array(values)) => {
            Some(values.iter().cloned().map(Item::Value).collect())
        }
        _ => None,
    }
}

/// The folded entries as an array of tables, in the places the surviving
/// entries already held. A table renders where its position says, so entries
/// that changed places have to change positions with them or the file would
/// come back in the old order; the places are the survivors' own, so nothing
/// moves past a table that is not part of this list, and an entry the list
/// gained has no position and renders beside the one before it.
fn as_tables(rebuilt: &[Item]) -> ArrayOfTables {
    let mut tables: Vec<Table> = rebuilt
        .iter()
        .map(|entry| match entry {
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

/// The folded entries as an inline array, each keeping the bytes written
/// around it and the array keeping its own. A list nothing changed comes back
/// byte for byte; an entry that went takes the run before it with it.
fn as_array(destination: &Array, rebuilt: &[Item]) -> Array {
    let mut built = Array::new();
    built.set_trailing_comma(destination.trailing_comma());
    built.set_trailing(destination.trailing().clone());
    *built.decor_mut() = destination.decor().clone();
    for entry in rebuilt {
        built.push_formatted(match entry {
            Item::Value(value) => value.clone(),
            Item::Table(table) => Value::InlineTable(table.clone().into_inline_table()),
            other => unreachable!("an array holds values, not {other:?}"),
        });
    }
    built
}

/// Whether this leaf already says what kendex holds. Only a difference here
/// reaches an edit, which is what keeps a write off the spelling of every
/// value it did not change.
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

/// The run an inline table keeps before its closing brace, against the key it
/// is stored on. That spacing belongs to the brace rather than to whichever
/// key happens to sit last, so a gained key would otherwise strand it in the
/// middle: `{ a = 1 , b = 2}`. `None` for a standard table, where a value's
/// suffix is a trailing comment and stays on the line it was written on.
fn brace_run(destination: &Item) -> Option<(String, String)> {
    let Item::Value(Value::InlineTable(table)) = destination else {
        return None;
    };
    let (key, value) = table.iter().last()?;
    let run = value
        .decor()
        .suffix()
        .and_then(toml_edit::RawString::as_str)
        .unwrap_or_default();
    Some((key.to_owned(), run.to_owned()))
}

/// [`brace_run`], put back on the key that is last now.
fn reseat_brace(destination: &mut Item, brace: Option<(String, String)>) {
    let Some((was, spacing)) = brace.filter(|(_, spacing)| !spacing.is_empty()) else {
        return;
    };
    let Item::Value(Value::InlineTable(table)) = destination else {
        return;
    };
    let Some(now) = table.iter().last().map(|(key, _)| key.to_owned()) else {
        return;
    };
    if now == was {
        return;
    }
    if let Some(value) = table.get_mut(&was) {
        value.decor_mut().set_suffix("");
    }
    if let Some(value) = table.get_mut(&now) {
        value.decor_mut().set_suffix(spacing);
    }
}

/// A subtree lifted out of the serialized document and ready to land in
/// somebody else's. The serializer's own table positions come with it and
/// would place the table by where its field sat there; cleared, a table
/// renders after the one it was inserted behind, which is where its
/// neighbours are.
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
