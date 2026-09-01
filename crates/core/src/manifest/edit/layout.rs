//! Who owns which bytes between one value and the next.
//!
//! A TOML document stores the run before a value against that value, so
//! the writing that sits between two entries of a list — the annotation
//! somebody put after the first of them — belongs to the entry above the
//! one holding it. Everything here is the arithmetic that puts each
//! entry back together with what was written about it, so a list can lose
//! an entry or change its order without an annotation staying behind.

use toml_edit::{Array, Item, Value};

/// The run an inline table keeps before its closing brace, against the key
/// it is stored on. That spacing belongs to the brace rather than to
/// whichever key happens to sit last, so a gained key would otherwise
/// strand it in the middle: `{ a = 1 , b = 2}`. `None` for a standard
/// table, where a value's suffix is a trailing comment and stays on the
/// line it was written on.
pub(super) fn brace_run(destination: &Item) -> Option<(String, String)> {
    let Item::Value(Value::InlineTable(table)) = destination else {
        return None;
    };
    let (key, value) = table.iter().last()?;
    Some((key.to_owned(), decoration(value.decor().suffix(), "")))
}

/// [`brace_run`], put back on the key that is last now.
pub(super) fn reseat_brace(destination: &mut Item, brace: Option<(String, String)>) {
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

/// The merged entries as an inline array, each carrying the writing that
/// was written about it. See [`Layout`] for why that is not the same as
/// keeping each entry's decoration.
pub(super) fn rebuilt_array(destination: &Array, merged: Vec<(Option<usize>, Item)>) -> Array {
    let layout = Layout::of(destination);
    let mut rebuilt = Array::new();
    rebuilt.set_trailing_comma(destination.trailing_comma());
    *rebuilt.decor_mut() = destination.decor().clone();
    let mut leading = layout.opener.clone();
    for (index, (at, entry)) in merged.into_iter().enumerate() {
        let mut value = entry
            .into_value()
            .unwrap_or_else(|other| unreachable!("an array holds values, not {other:?}"));
        let (before, after) = layout.around(at, index == 0);
        value.decor_mut().set_prefix(format!("{leading}{before}"));
        value.decor_mut().set_suffix("");
        rebuilt.push_formatted(value);
        leading = after;
    }
    rebuilt.set_trailing(format!("{leading}{}", layout.closer));
    rebuilt
}

/// Who owns which bytes inside an array.
///
/// toml_edit hangs everything between one value and the next on the later
/// value's prefix, so a comment written after a value — the common way to
/// annotate a list — is stored against the value below it, and the last
/// value's annotation is stored in the array's trailing text. Carrying an
/// entry's own prefix with it would therefore move every annotation one
/// entry along on a re-sort, and dropping an entry would delete the
/// annotation of the entry above it.
///
/// So each entry is given what was written *about* it: `before` is its own
/// prefix from the first line break onward, and `after` is the next
/// prefix up to and including its first line break — the rest of the line
/// the entry sat on. What is left over belongs to the brackets: `opener`
/// is the rest of the line the `[` sat on, `closer` the indentation before
/// the `]`.
struct Layout {
    opener: String,
    closer: String,
    around: Vec<(String, String)>,
    indent: String,
    broken: bool,
}

impl Layout {
    fn of(array: &Array) -> Layout {
        let prefixes: Vec<String> = array
            .iter()
            .enumerate()
            .map(|(index, value)| {
                let default = if index == 0 { "" } else { " " };
                decoration(value.decor().prefix(), default)
            })
            .collect();
        let trailing = decoration(Some(array.trailing()), "");
        let (opener, first) = split(prefixes.first().map_or("", String::as_str));
        let heads: Vec<&str> = prefixes
            .iter()
            .skip(1)
            .map(|prefix| split(prefix).0)
            .chain(std::iter::once(split(&trailing).0))
            .collect();
        let tails = std::iter::once(first).chain(prefixes.iter().skip(1).map(|p| split(p).1));
        let around: Vec<(String, String)> = tails
            .zip(&heads)
            .map(|(before, after)| ((*before).to_owned(), (*after).to_owned()))
            .collect();
        let broken = prefixes.iter().any(|prefix| prefix.contains('\n'));
        let indent = prefixes
            .first()
            .and_then(|prefix| prefix.rsplit('\n').next())
            .filter(|_| broken)
            .unwrap_or("");
        Layout {
            opener: opener.to_owned(),
            closer: split(&trailing).1.to_owned(),
            around,
            indent: indent.to_owned(),
            broken,
        }
    }

    /// What was written about the entry that stood at `at`. An entry the
    /// list did not have has nothing written about it, so it takes the
    /// indentation the array already uses and a line of its own where the
    /// array takes lines — a space after the comma where it does not, and
    /// nothing at all where it opens the array.
    fn around(&self, at: Option<usize>, first: bool) -> (String, String) {
        match at.and_then(|at| self.around.get(at)) {
            Some(around) => around.clone(),
            None if self.broken => (self.indent.clone(), "\n".to_owned()),
            None if first => (String::new(), String::new()),
            None => (" ".to_owned(), String::new()),
        }
    }
}

/// A prefix or trailing run split into the tail of the line before it and
/// what sits on its own lines after that. A run with no line break is all
/// tail of the line before, because a comment cannot end without one.
fn split(text: &str) -> (&str, &str) {
    match text.find('\n') {
        Some(at) => text.split_at(at + 1),
        None => (text, ""),
    }
}

/// The bytes a decoration stands for. A parsed document spells every one
/// of them; `default` is what the encoder would have written for a
/// decoration nothing set.
fn decoration(raw: Option<&toml_edit::RawString>, default: &str) -> String {
    raw.and_then(toml_edit::RawString::as_str)
        .unwrap_or(default)
        .to_owned()
}
