//! Folding a manifest into the document the person wrote.
//!
//! kendex.toml is written by hand, so a write may not re-serialize it.
//! What kendex holds is serialized on its own, and the two documents are
//! walked together: a value that already says the right thing is not
//! touched at all, a value that changed keeps its formatting, a key kendex
//! dropped goes, and a key kendex gained is appended where its neighbours
//! are. Comments, blank lines, key order and the spelling of every
//! untouched value survive that, because nothing rewrote them.
//!
//! Three things the walk is careful about.
//!
//! What a write may remove is settled by `held`, a third document: the
//! same serialization taken of the manifest read back out of this very
//! file. A key it names and the target does not is a key the manifest
//! really did drop, and the sweep takes it. A key it never names was
//! never the manifest's — a note somebody left inside a declaration, or a
//! flag the serializer omits at its default — and the sweep passes over
//! it. Nothing has to know which keys the model can spell, and nothing
//! the serializer chooses to leave out reads as a deletion.
//!
//! Containers are edited in the shape they were written in. An inline
//! `custom-hooks = [{ … }]` and a `[[custom-hooks]]` array say the same
//! thing, and the walk dispatches on the destination, so neither is
//! rewritten into the other.
//!
//! List entries are paired by what an entry is — a hook by its name, or
//! by what it runs where only one side has been named, and a scalar by
//! its own value — and what identity could not place takes the slot it
//! sat in, where identity has not already claimed that slot. What
//! somebody wrote about an entry then travels with that entry through a
//! removal or a re-sort. The positional half is what keeps an edit an
//! edit rather than a drop and an append, and it has a price: an entry
//! paired that way inherits what was written about whatever stood in its
//! slot. Where a list holds one value twice, identity claims the earlier
//! slot first and an edited neighbour is left none, so its own line's
//! annotation goes with nobody rather than moving. Both are asserted in
//! `tests::a_value_paired_by_position_keeps_the_note_written_in_its_slot`
//! and `tests::a_repeated_value_leaves_an_edited_neighbour_unpaired`.
//!
//! Where those bytes are is not where they look. An array of values keeps
//! them in [`layout`]'s four places, an entry and its annotation always
//! one slot apart; an array of tables keeps a table's annotation on the
//! table, so [`rebuilt_tables`] carries it by moving the table itself.

use toml_edit::{ArrayOfTables, DocumentMut, Item, Table, TableLike, Value};

mod layout;
use layout::{brace_run, rebuilt_array, reseat_brace};

/// The text a write should leave behind.
///
/// `current` is the file as it stands, `held` the serialization of the
/// manifest that file reads back as, and `desired` the serialization of
/// the manifest to write. Every parse is answered rather than assumed:
/// `current` is somebody's file, and the other two are this crate's own
/// serializer, so a failure on any of them is a refusal and never a
/// rewrite.
pub(super) fn merged(
    current: &str,
    held: &str,
    desired: &str,
) -> Result<String, toml_edit::TomlError> {
    let mut document: DocumentMut = current.parse()?;
    let held: DocumentMut = held.parse()?;
    let target: DocumentMut = desired.parse()?;
    merge_table(
        document.as_table_mut(),
        Some(held.as_table()),
        target.as_table(),
    );
    Ok(document.to_string())
}

/// Walk two tables together. Keys are compared by name, so a table spelled
/// `[a.b]`, `a.b = {}` or `a.b.c = 1` all merge as the same table — the
/// destination keeps whichever spelling it already had.
fn merge_table(
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
            Some(item) => merge_item(item, held.and_then(|held| held.get(key)), wanted),
            None => {
                destination.insert(key, fresh(wanted));
            }
        }
    }
}

/// The one walk. Containers recurse, and equality lives at the leaf: a
/// scalar that already says the right thing is left with its own bytes,
/// and everything above it is a no-op when nothing under it changed.
fn merge_item(destination: &mut Item, held: Option<&Item>, target: &Item) {
    if target.as_table_like().is_some() && destination.as_table_like().is_some() {
        let brace = brace_run(destination);
        if let Some(wanted) = target.as_table_like()
            && let Some(item) = destination.as_table_like_mut()
        {
            merge_table(item, held.and_then(Item::as_table_like), wanted);
        }
        reseat_brace(destination, brace);
        return;
    }
    if merge_entries(destination, held, target) {
        return;
    }
    if let (Item::Value(item), Item::Value(wanted)) = (&mut *destination, target) {
        if same_scalar(item, wanted) {
            return;
        }
        // A value that changed keeps its own decoration. The whitespace
        // before it and any comment after it are the person's, and they
        // belong to the key rather than to the value that was there.
        let mut replacement = wanted.clone();
        *replacement.decor_mut() = item.decor().clone();
        *item = replacement;
        return;
    }
    *destination = fresh(target);
}

/// A list, in the shape the destination spells it. `[[custom-hooks]]`
/// entries and an inline array of tables are the same list, so the one
/// that is on disk is the one that is edited.
///
/// `held` is that list as the model reads it back out of this same file,
/// so its entries stand one for one against the destination's and each
/// merge gets the model's view of the entry it is editing.
fn merge_entries(destination: &mut Item, held: Option<&Item>, target: &Item) -> bool {
    let (Some(standing), Some(wanted)) = (entries(destination), entries(target)) else {
        return false;
    };
    let held = held.and_then(entries).unwrap_or_default();
    // Each merged entry keeps the destination place it continues, so the
    // rebuild can hand it back the writing that was written about it.
    let merged: Vec<(Option<usize>, Item)> = wanted
        .iter()
        .zip(paired(&standing, &wanted))
        .map(|(wanted, at)| match at {
            Some(at) => {
                let mut entry = standing[at].clone();
                merge_item(&mut entry, held.get(at), wanted);
                (Some(at), entry)
            }
            None => (None, fresh(wanted)),
        })
        .collect();
    match destination {
        Item::ArrayOfTables(tables) => *tables = rebuilt_tables(merged),
        Item::Value(Value::Array(array)) => *array = rebuilt_array(array, merged),
        // `entries` answered for this item one statement ago, and it
        // admits exactly the two spellings above.
        other => unreachable!("a list is a table array or an array, not {other:?}"),
    }
    true
}

/// Which destination entry each target entry continues: by identity, one
/// key at a time from the strongest, and by position for whatever no key
/// could place. An entry that pairs with nothing is gained; a destination
/// entry nothing pairs with is dropped, and the comment written above it
/// goes with it.
fn paired(standing: &[Item], target: &[Item]) -> Vec<Option<usize>> {
    let standing_keys: Vec<Identity> = standing.iter().map(identity).collect();
    let target_keys: Vec<Identity> = target.iter().map(identity).collect();
    let mut taken = vec![false; standing.len()];
    let mut pairing = vec![None; target.len()];
    // A rank at a time, so a stronger key never loses a slot to a weaker
    // one, and like is compared with like: an entry that answers on one
    // rank and not another is simply absent from that round.
    for rank in 0..RANKS {
        for (index, wanted) in target_keys.iter().enumerate() {
            let (None, Some(key)) = (pairing[index], wanted[rank].as_ref()) else {
                continue;
            };
            for (at, entry) in standing_keys.iter().enumerate() {
                if taken[at] || entry[rank].as_ref() != Some(key) {
                    continue;
                }
                pairing[index] = Some(at);
                taken[at] = true;
                break;
            }
        }
    }
    for (index, slot) in pairing.iter_mut().enumerate() {
        if slot.is_none() && taken.get(index) == Some(&false) {
            *slot = Some(index);
            taken[index] = true;
        }
    }
    pairing
}

/// What makes one entry of a list the same entry across a write. Every
/// entry a manifest list can hold answers here, because the decoration the
/// merge carries from entry to entry is the person's writing about that
/// entry: a comment above a harness names that harness, and a comment
/// above a hook describes that hook.
///
/// A scalar is its own identity, so a list that lost an element or was
/// re-sorted — `Manifest::suppress` sorts on every removal — moves each
/// annotation with the value it was written against.
///
/// A table answers on two keys, because one is not enough to survive the
/// editor. `name` is the identity `[[custom-hooks]]` documents and the
/// stronger key: a hook whose command was edited is still that hook. But
/// `hook::name_custom_hooks` stamps a name onto every hook the editor
/// saves, so on that path the target is named and the file it is folded
/// into is not, and nothing about the names can match. What the name was
/// derived from can: a hook also answers on the event and command it
/// runs, and `paired` tries that key once the names have placed what they
/// can. Duplicates pair first-unclaimed, which the caller's `taken` sweep
/// already decides.
///
/// Nothing here identifies an entry whose value changed, and nothing can:
/// a value edited in place is a different value. It pairs by the slot it
/// sat in, so it keeps the note written there — which is what makes an
/// edit an edit, and what makes `"Write", # no writing files` read
/// `"WebFetch", # no writing files` afterwards.
///
/// That holds while the slot is still free. Identity runs over the whole
/// target before position places anything, so where a list holds one
/// value twice the surviving copy claims the earlier slot, the edited
/// entry finds none and lands as a gained one, and the annotation on the
/// slot nobody claimed is dropped rather than moved. Both readings are
/// asserted, in
/// `tests::a_value_paired_by_position_keeps_the_note_written_in_its_slot`
/// and `tests::a_repeated_value_leaves_an_edited_neighbour_unpaired`, so
/// the trade is a fixture rather than a sentence.
/// How many keys an entry can be recognized by, strongest first.
const RANKS: usize = 2;

/// The keys one entry answers on, `None` where it answers on none.
type Identity = [Option<String>; RANKS];

fn identity(entry: &Item) -> Identity {
    let Some(table) = entry.as_table_like() else {
        return [None, scalar(entry)];
    };
    let named = text(table, "name").map(|name| format!("named {name}"));
    let runs = match (text(table, "event"), text(table, "command")) {
        (Some(event), Some(command)) => Some(format!("runs {event}\u{1f}{command}")),
        _ => None,
    };
    [named, runs]
}

fn scalar(entry: &Item) -> Option<String> {
    match entry.as_value()? {
        Value::String(value) => Some(format!("text {}", value.value())),
        Value::Integer(value) => Some(format!("whole {}", value.value())),
        Value::Boolean(value) => Some(format!("flag {}", value.value())),
        // A float has no spelling that compares safely, and a datetime and
        // an array are not shapes a manifest list holds. Nothing
        // identifies them, so they pair by position, as they did before.
        Value::Float(_) | Value::Datetime(_) | Value::Array(_) | Value::InlineTable(_) => None,
    }
}

fn text(entry: &dyn TableLike, key: &str) -> Option<String> {
    entry
        .get(key)
        .and_then(Item::as_str)
        .map(std::borrow::ToOwned::to_owned)
}

/// The merged entries as an array of tables, in the places the surviving
/// entries already held. A table renders where its position says, so
/// entries that changed places have to change positions with them or the
/// file would come back in the old order; the places are the survivors'
/// own, so nothing moves past a table that is not part of this list.
fn rebuilt_tables(merged: Vec<(Option<usize>, Item)>) -> ArrayOfTables {
    let mut tables: Vec<Table> = merged
        .into_iter()
        .map(|(_, entry)| {
            entry
                .into_table()
                // Refused before the fold rather than here: `held_by_model`
                // deserializes the file through `Manifest` first, and serde
                // takes no array of tables for a list of strings.
                .unwrap_or_else(|other| unreachable!("a table array holds tables, not {other:?}"))
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
    let mut rebuilt = ArrayOfTables::new();
    for table in tables {
        rebuilt.push(table);
    }
    rebuilt
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

/// Whether this leaf already says what kendex holds. Only a difference
/// here reaches an edit, which is what keeps a write off the spelling of
/// every value it did not change.
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
