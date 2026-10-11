//! `{{shared-text:NAME}}`, the token a `[skill-instructions]` value uses to
//! place a `[shared-text]` entry. Parsed here only, for the expansion and
//! for validation alike.

use std::borrow::Cow;
use std::collections::BTreeMap;
use std::ops::Range;

const OPEN: &str = "{{shared-text:";
const CLOSE: &str = "}}";

/// Each token in `value`: the bytes it spans and the name it holds.
pub(super) fn tokens(value: &str) -> impl Iterator<Item = (Range<usize>, &str)> {
    let mut from = 0;
    std::iter::from_fn(move || {
        let start = from + value[from..].find(OPEN)?;
        let name_start = start + OPEN.len();
        let name_end = name_start + value[name_start..].find(CLOSE)?;
        from = name_end + CLOSE.len();
        Some((start..from, &value[name_start..name_end]))
    })
}

pub(super) fn expand<'a>(value: &'a str, shared: &BTreeMap<String, String>) -> Cow<'a, str> {
    let mut out = String::new();
    let mut end = 0;
    for (span, name) in tokens(value) {
        let Some(text) = shared.get(name) else {
            continue;
        };
        out.push_str(&value[end..span.start]);
        out.push_str(text.trim_end());
        end = span.end;
    }
    match end {
        0 => Cow::Borrowed(value),
        _ => {
            out.push_str(&value[end..]);
            Cow::Owned(out)
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn each_declared_token_is_replaced_in_place_and_nothing_else_moves() {
        let shared = BTreeMap::from([
            ("delivery".to_owned(), "Ship it.\n\n".to_owned()),
            ("tests".to_owned(), "Test it.".to_owned()),
        ]);
        for (value, expected, borrowed) in [
            ("Plain text.\n", "Plain text.\n", true),
            ("{{shared-text:delivery}}", "Ship it.", false),
            (
                "Own.\n\n{{shared-text:delivery}}\n\n{{shared-text:tests}} End.",
                "Own.\n\nShip it.\n\nTest it. End.",
                false,
            ),
            (
                "{{shared-text:missing}} kept",
                "{{shared-text:missing}} kept",
                true,
            ),
            ("{{shared-text:delivery", "{{shared-text:delivery", true),
            ("{{args}} {{shared-text:tests}}", "{{args}} Test it.", false),
        ] {
            let expanded = expand(value, &shared);
            assert_eq!(expanded, expected, "{value:?}");
            assert_eq!(matches!(expanded, Cow::Borrowed(_)), borrowed, "{value:?}");
        }
    }
}
