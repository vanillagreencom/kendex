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
//! `held` — an entry whose model view the target still holds keeps its slot, so
//! the comment written about it and the keys inside it the model does not carry
//! travel with it through a removal or a re-sort. Where an entry has to be
//! placed by position instead, [`writing`] owns what that means for the bytes
//! and `fold_entries` owns what it means for the keys.
//!
//! The price, in full, and it is one shape: a write that both removes an entry
//! and changes another. The changed entry can only be placed by position, and
//! with the slots moved under it that position is another declaration's. It
//! comes back under the comment written about that declaration, and the keys
//! the model does not carry — a note somebody left inside either one — are
//! gone from the file rather than moved between declarations, because a
//! dropped key is visible where a migrated one reads as if a person put it
//! there. A write that only removes, only adds, only re-sorts, or only changes
//! an entry pays none of it.

use toml_edit::{DocumentMut, Item, TableLike, Value};

mod writing;

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
                destination.insert(key, writing::fresh(wanted));
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
    // Read before the walk, because it is taken off the whole item and the
    // mutable borrow below reaches inside one. Put back after `fold_table`,
    // which is where that borrow's last use ends it.
    let brace = brace_run(destination);
    if let Some(wanted) = target.as_table_like()
        && let Some(item) = destination.as_table_like_mut()
    {
        fold_table(item, held.and_then(Item::as_table_like), wanted);
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
    *destination = writing::fresh(target);
}

/// One list, folded entry by entry in the spelling the destination is written
/// in. `false` where either side is not a list, so the caller falls through to
/// its leaf handling.
///
/// An entry `held` identified is the destination's own, folded against the
/// target entry it continues, so the writing around it and the keys inside it
/// the manifest does not carry stay where they were put.
///
/// An entry nothing identified took its slot by position, and what that slot
/// still says about it depends on whether the list kept its length. It did:
/// nothing has shifted, so the slot is the one this entry would have had, an
/// edit is an edit, and the writing around it and the keys inside it are still
/// about it. It did not: an entry is gone and every slot after it has moved
/// under something else, so this entry is standing where another declaration
/// stood. It keeps what was written AROUND that slot, which is the price
/// pairing in order has always had and which the module doc names. It keeps
/// none of the keys INSIDE it: `held` cannot answer for a declaration it is not
/// the model view of, and a key migrating into a declaration a person never put
/// it in reads exactly as if they had. [`stripped`] takes those before the
/// fold, because dropping a key is visible and moving one is not.
fn fold_entries(destination: &mut Item, held: Option<&Item>, target: &Item) -> bool {
    let (Some(standing), Some(wanted)) = (entries(destination), entries(target)) else {
        return false;
    };
    let held = held.and_then(entries).unwrap_or_default();
    let settled = standing.len() == wanted.len();
    let rebuilt: Vec<(Option<usize>, Item)> = wanted
        .iter()
        .zip(paired(standing.len(), &held, &wanted))
        .map(|(wanted, slot)| match slot {
            Some(Slot { at, identified }) => {
                let mut entry = standing[at].clone();
                let mine = identified || settled;
                if !mine {
                    stripped(&mut entry, wanted);
                }
                fold_item(&mut entry, mine.then(|| held.get(at)).flatten(), wanted);
                (Some(at), entry)
            }
            None => (None, writing::fresh(wanted)),
        })
        .collect();
    writing::rebuild(destination, &rebuilt);
    true
}

/// Everything the target does not name, taken off an entry that is about to
/// stand for a different declaration. `held` is what says a key is not
/// kendex's to remove, and it speaks for the slot rather than for whatever is
/// landing in it, so it cannot answer here at all.
fn stripped(entry: &mut Item, target: &Item) {
    let (Some(item), Some(wanted)) = (entry.as_table_like_mut(), target.as_table_like()) else {
        return;
    };
    let gone: Vec<String> = item
        .iter()
        .map(|(key, _)| key.to_owned())
        .filter(|key| wanted.get(key).is_none())
        .collect();
    for key in gone {
        item.remove(&key);
    }
    for (key, wanted) in wanted.iter() {
        if let Some(item) = item.get_mut(key) {
            stripped(item, wanted);
        }
    }
}

/// One destination slot, and how the target entry came by it.
#[derive(Clone, Copy)]
struct Slot {
    at: usize,
    /// Whether `held` recognized this as the same entry still standing, rather
    /// than the slot simply being the one left over.
    identified: bool,
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
fn paired(standing: usize, held: &[Item], target: &[Item]) -> Vec<Option<Slot>> {
    let mut taken = vec![false; standing];
    let mut pairing: Vec<Option<Slot>> = vec![None; target.len()];
    for (index, wanted) in target.iter().enumerate() {
        for (at, entry) in held.iter().enumerate().take(standing) {
            if !taken[at] && same_entry(entry, wanted) {
                pairing[index] = Some(Slot {
                    at,
                    identified: true,
                });
                taken[at] = true;
                break;
            }
        }
    }
    let mut free = (0..standing).filter(|at| !taken[*at]);
    for slot in pairing.iter_mut().filter(|slot| slot.is_none()) {
        *slot = free.next().map(|at| Slot {
            at,
            identified: false,
        });
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

#[cfg(test)]
mod tests;
