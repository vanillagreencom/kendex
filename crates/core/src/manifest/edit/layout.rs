//! Who owns which bytes between one value and the next.
//!
//! Two places a person's writing hides inside a value's own punctuation.
//! An array of values: TOML stores the run before a value against that
//! value, so the annotation somebody put after one entry belongs to the
//! entry below the one holding it, and [`rebuilt_array`] puts each entry
//! back together with what was written about it before anything moves.
//! An inline table: the spacing before its closing brace is stored on
//! whichever key sits last, which [`reseat_brace`] hands back to the
//! brace when a gained key takes that place.
//!
//! Neither covers an array of tables. A table carries its annotation in
//! its own decoration, so `edit`'s `rebuilt_tables` moves the table and
//! the annotation goes with it.

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
    let last = merged.len().saturating_sub(1);
    for (index, (at, entry)) in merged.into_iter().enumerate() {
        let mut value = entry
            .into_value()
            .unwrap_or_else(|other| unreachable!("an array holds values, not {other:?}"));
        let owned = layout.around(at, index == 0, index == last);
        let mut prefix = format!("{leading}{}", owned.before);
        // An entry the list did not have needs separating from the comma
        // before it, and the entry it follows may have been last, whose
        // own trailing run faced the bracket rather than a neighbour.
        if at.is_none() && index > 0 && prefix.is_empty() {
            prefix = layout.separator.clone();
        }
        value.decor_mut().set_prefix(prefix);
        value.decor_mut().set_suffix(owned.suffix);
        rebuilt.push_formatted(value);
        leading = owned.after;
    }
    rebuilt.set_trailing(format!("{leading}{}", layout.closer));
    rebuilt
}

/// Who owns which bytes inside an array, across the whole bracket span.
///
/// toml_edit splits the span four ways: each value's prefix, each value's
/// suffix, the run after the last comma, and — with no trailing comma —
/// nothing at all, because the bytes before `]` are then the last value's
/// suffix. A comment written after a value, the common way to annotate a
/// list, lands in whichever of those the comma's placement decides.
///
/// So none of them can ride with the slot they are stored in. Each entry
/// is given what was written *about* it: `before` is its own prefix from
/// the first line break onward, `suffix` what stood between it and the
/// comma after it, and `after` the next prefix up to and including its
/// first line break — the rest of the line the entry sat on. What is left
/// over belongs to the brackets: `opener` is the rest of the line the `[`
/// sat on, `closer` what sits on its own lines before the `]`.
struct Layout {
    opener: String,
    closer: String,
    around: Vec<Around>,
    indent: String,
    separator: String,
    broken: bool,
}

/// The bytes written about one entry, in the three places TOML keeps them.
struct Around {
    before: String,
    suffix: String,
    after: String,
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
        let suffixes: Vec<String> = array
            .iter()
            .map(|value| decoration(value.decor().suffix(), ""))
            .collect();
        let trailing = decoration(Some(array.trailing()), "");
        // Where the run before `]` is kept: the array's trailing text when
        // it ends with a comma, the last value's suffix when it does not.
        // An array with no values keeps the whole span in its trailing.
        let closing = match (array.trailing_comma(), suffixes.last()) {
            (false, Some(last)) => last.as_str(),
            _ => trailing.as_str(),
        };
        let (closing_head, closer) = split(closing);
        let opener = split(prefixes.first().map_or(trailing.as_str(), String::as_str)).0;

        let last = prefixes.len().saturating_sub(1);
        let around: Vec<Around> = prefixes
            .iter()
            .enumerate()
            .map(|(index, prefix)| Around {
                before: split(prefix).1.to_owned(),
                suffix: match index == last && !array.trailing_comma() {
                    true => closing_head.to_owned(),
                    false => suffixes[index].clone(),
                },
                after: match (index == last, array.trailing_comma()) {
                    (true, true) => split(&trailing).0.to_owned(),
                    (true, false) => trailing.clone(),
                    (false, _) => split(&prefixes[index + 1]).0.to_owned(),
                },
            })
            .collect();

        let broken = prefixes
            .iter()
            .chain(&suffixes)
            .chain(std::iter::once(&trailing))
            .any(|run| run.contains('\n'));
        // What a line of this array is indented by: whatever follows the
        // last line break of a prefix that takes one, or the whitespace
        // the closing bracket is held out by where no entry has a prefix.
        let indent = prefixes
            .iter()
            .find(|prefix| prefix.contains('\n'))
            .and_then(|prefix| prefix.rsplit('\n').next())
            .unwrap_or_else(|| closer.trim_end_matches(|c: char| !c.is_whitespace() && c != ' '));
        Layout {
            opener: opener.to_owned(),
            closer: closer.to_owned(),
            around,
            indent: match broken {
                true => indent
                    .chars()
                    .take_while(|c| *c == ' ' || *c == '\t')
                    .collect(),
                false => String::new(),
            },
            separator: " ".to_owned(),
            broken,
        }
    }

    /// What was written about the entry that stood at `at`. An entry the
    /// list did not have has nothing written about it, so it takes the
    /// indentation the array already uses and a line of its own where the
    /// array takes lines, and otherwise leaves the separating space to
    /// the entry after it — put before it, it would double the space the
    /// entry it displaced already carries. Nothing follows the entry that
    /// ends the list but the bracket, so it leaves no separator at all.
    fn around(&self, at: Option<usize>, first: bool, last: bool) -> Around {
        match at.and_then(|at| self.around.get(at)) {
            Some(around) => Around {
                before: around.before.clone(),
                suffix: around.suffix.clone(),
                after: around.after.clone(),
            },
            None => Around {
                before: match self.broken {
                    true => self.indent.clone(),
                    false => String::new(),
                },
                suffix: String::new(),
                after: match (self.broken, first || last) {
                    (true, _) => "\n".to_owned(),
                    (false, true) => String::new(),
                    (false, false) => self.separator.clone(),
                },
            },
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
