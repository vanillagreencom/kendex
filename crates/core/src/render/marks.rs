//! What one line's opening characters say about the block it belongs to:
//! the container markers it carries, and the leaf blocks it may open.
//! [`super::blocks`] walks a document with these; on their own they say
//! nothing about what stands open above the line.

/// What stands past up to three spaces of indent, or `None` at four,
/// where markdown reads an indented block rather than a marker.
fn unindented(line: &str) -> Option<&str> {
    let rest = line.trim_start_matches(' ');
    (line.len() - rest.len() <= 3).then_some(rest)
}

/// Four spaces or a tab: the indent markdown reads as a code block, where
/// nothing else on the line opens one.
pub fn indented(line: &str) -> bool {
    line.starts_with("    ") || line.starts_with('\t')
}

/// How many blockquote markers open this line, taking at most `limit` of
/// them, and what stands after the ones taken.
///
/// The count is what a lazy continuation is read against: a line carrying
/// fewer markers than the paragraph above it is still that paragraph, and
/// only a line carrying more opens a quote inside it. The limit is for a
/// block already standing open, which owns the markers it opened at and no
/// others: inside a fence every further `>` is the code's own text, so
/// taking it as a marker would let a deeper line close a fence it never
/// stood in.
pub fn quote_depth(line: &str, limit: usize) -> (usize, &str) {
    let mut rest = line;
    let mut depth = 0;
    while depth < limit
        && let Some(after) = unindented(rest).and_then(|open| open.strip_prefix('>'))
    {
        depth += 1;
        rest = after.strip_prefix(' ').unwrap_or(after);
    }
    (depth, rest)
}

/// One to six `#`, then whitespace or the end of the line.
pub fn atx_heading(line: &str) -> bool {
    let Some(rest) = unindented(line) else {
        return false;
    };
    let hashes = rest.bytes().take_while(|b| *b == b'#').count();
    (1..=6).contains(&hashes)
        && rest[hashes..]
            .chars()
            .next()
            .is_none_or(char::is_whitespace)
}

/// Nothing but `=` or nothing but `-`, which closes the heading whose text
/// stands above it.
pub fn setext_underline(line: &str) -> bool {
    let Some(rest) = unindented(line).map(str::trim_end) else {
        return false;
    };
    !rest.is_empty() && (rest.bytes().all(|b| b == b'=') || rest.bytes().all(|b| b == b'-'))
}

/// Three or more of `*`, `-` or `_`, alone but for the whitespace between
/// them. Read before a list marker, because `* * *` carries one.
pub fn thematic_break(line: &str) -> bool {
    let Some(rest) = unindented(line).map(str::trim_end) else {
        return false;
    };
    let Some(mark) = rest.chars().next().filter(|c| matches!(c, '*' | '-' | '_')) else {
        return false;
    };
    rest.chars().filter(|c| *c == mark).count() >= 3
        && rest.chars().all(|c| c == mark || c.is_whitespace())
}

/// A list item's marker: `-`, `+` or `*`, or up to nine digits and a `.`
/// or `)`, then whitespace or the end of the line. The whitespace is what
/// tells a marker from the `--no-verify` that opens a line of prose.
pub fn list_marker(line: &str) -> bool {
    let Some(rest) = unindented(line) else {
        return false;
    };
    let after = match rest.as_bytes() {
        [b'-' | b'+' | b'*', tail @ ..] => tail,
        bytes => {
            let digits = bytes.iter().take_while(|b| b.is_ascii_digit()).count();
            match bytes.get(digits) {
                Some(b'.' | b')') if (1..=9).contains(&digits) => &bytes[digits + 1..],
                _ => return false,
            }
        }
    };
    after.first().is_none_or(u8::is_ascii_whitespace)
}

/// A raw HTML block's kind, which is what says where it ends: `Raw` at a
/// closing `</script>`, `</pre>`, `</style>` or `</textarea>`, `Comment`
/// at `-->`, `Question` at `?>`, `Bang` at `>`, `Cdata` at `]]>`, and
/// `Named` at a blank line.
///
/// `Named` is two of markdown's kinds, which end alike and start
/// differently. A block-level tag from markdown's own list opens one
/// wherever it stands, an open paragraph included. Any other whole tag
/// alone on its line opens one only where no paragraph stands open: that
/// kind may not interrupt one, so reading it as a block under a paragraph
/// ends a span markdown leaves running, and refusing it everywhere leaves
/// a span running that markdown ends. Both directions are a switch scored
/// as the wrong thing, which is why the rule is the conditional one rather
/// than either half of it.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Html {
    Raw,
    Comment,
    Question,
    Bang,
    Cdata,
    Named,
}

/// The tags whose content markdown reads raw, ending only at a closing tag
/// of their own.
const RAW_TAGS: [&str; 4] = ["script", "pre", "style", "textarea"];

/// The tags markdown reads as a block of their own, from its own list.
const BLOCK_TAGS: [&str; 62] = [
    "address",
    "article",
    "aside",
    "base",
    "basefont",
    "blockquote",
    "body",
    "caption",
    "center",
    "col",
    "colgroup",
    "dd",
    "details",
    "dialog",
    "dir",
    "div",
    "dl",
    "dt",
    "fieldset",
    "figcaption",
    "figure",
    "footer",
    "form",
    "frame",
    "frameset",
    "h1",
    "h2",
    "h3",
    "h4",
    "h5",
    "h6",
    "head",
    "header",
    "hr",
    "html",
    "iframe",
    "legend",
    "li",
    "link",
    "main",
    "menu",
    "menuitem",
    "nav",
    "noframes",
    "ol",
    "optgroup",
    "option",
    "p",
    "param",
    "search",
    "section",
    "summary",
    "table",
    "tbody",
    "td",
    "tfoot",
    "th",
    "thead",
    "title",
    "tr",
    "track",
    "ul",
];

/// Which raw HTML block this line opens, if any. `paragraph` says whether
/// one stands open above it, which is what the whole-tag kind turns on;
/// every other kind interrupts a paragraph, so a line opening one of those
/// ends the block above it.
pub fn html_opens(line: &str, paragraph: bool) -> Option<Html> {
    let after = unindented(line)?.strip_prefix('<')?;
    // A comment, a processing instruction, a declaration and a CDATA
    // section are spelled, not named: their openers are literal text, so
    // none of them is read against a lowercase copy. `CDATA` in
    // particular is the spelling markdown asks for and the only one.
    if after.starts_with("!--") {
        return Some(Html::Comment);
    }
    if after.starts_with('?') {
        return Some(Html::Question);
    }
    if after.starts_with("![CDATA[") {
        return Some(Html::Cdata);
    }
    if after
        .strip_prefix('!')
        .is_some_and(|rest| rest.starts_with(|c: char| c.is_ascii_alphabetic()))
    {
        return Some(Html::Bang);
    }
    // A tag name is case-insensitive, so the kinds named by one are the
    // only ones read against a lowercase copy.
    let lower = after.to_ascii_lowercase();
    if RAW_TAGS.iter().any(|name| tag_named(&lower, name, false)) {
        return Some(Html::Raw);
    }
    let named = lower.strip_prefix('/').unwrap_or(&lower);
    if BLOCK_TAGS.iter().any(|tag| tag_named(named, tag, true)) {
        return Some(Html::Named);
    }
    (!paragraph && whole_tag(after)).then_some(Html::Named)
}

/// Whether `after` — a line past its `<` — opens with this tag name and
/// nothing but the name's own end behind it. `empty_tag` admits the `/>`
/// that closes a tag holding nothing, which the raw-text kind does not
/// take: `<script/>` has no content for markdown to read raw and no
/// closing tag coming, so reading it as that kind runs the block to the
/// end of the document.
fn tag_named(after: &str, name: &str, empty_tag: bool) -> bool {
    let Some(rest) = after.strip_prefix(name) else {
        return false;
    };
    rest.is_empty()
        || rest.starts_with('>')
        || rest.starts_with(char::is_whitespace)
        || (empty_tag && rest.starts_with("/>"))
}

/// What stands past a tag name — an ASCII letter, then letters, digits and
/// `-` — or `None` where no name stands there.
fn past_name(text: &str) -> Option<&str> {
    let len = text
        .bytes()
        .take_while(|b| b.is_ascii_alphanumeric() || *b == b'-')
        .count();
    let named = text.bytes().next().is_some_and(|b| b.is_ascii_alphabetic());
    named.then(|| &text[len..])
}

/// What stands past one attribute, or `None` where none stands there. An
/// attribute is whitespace, a name, and optionally `=` and a value — bare,
/// or run to the quote that opened it.
fn past_attribute(text: &str) -> Option<&str> {
    let rest = text.strip_prefix(char::is_whitespace)?.trim_start();
    let opens = rest
        .bytes()
        .next()
        .is_some_and(|b| b.is_ascii_alphabetic() || matches!(b, b'_' | b':'));
    if !opens {
        return None;
    }
    let len = rest
        .bytes()
        .take_while(|b| b.is_ascii_alphanumeric() || matches!(b, b'_' | b':' | b'.' | b'-'))
        .count();
    let rest = &rest[len..];
    let Some(value) = rest.trim_start().strip_prefix('=') else {
        return Some(rest);
    };
    let value = value.trim_start();
    match value.bytes().next() {
        Some(quote @ (b'"' | b'\'')) => {
            let inner = &value[1..];
            let end = inner.find(char::from(quote))?;
            Some(&inner[end + 1..])
        }
        _ => {
            let len = value
                .bytes()
                .take_while(|b| !b" \t\"'=<>`".contains(b))
                .count();
            (len > 0).then(|| &value[len..])
        }
    }
}

/// Whether what stands past a `<` is one whole tag with nothing but
/// whitespace behind it: a name, any attributes and `>` for an open tag, or
/// `/`, a name and `>` for a closing one.
///
/// An open tag naming one of the raw-text elements is not one of these.
/// Markdown gives those their own kind, which ends at a closing tag rather
/// than at a blank line, and a line that fails that kind's start condition
/// — `<script/>`, which ends the tag before the space or `>` it wants —
/// opens no block at all.
fn whole_tag(after: &str) -> bool {
    if let Some(closing) = after.strip_prefix('/') {
        return past_name(closing).is_some_and(shuts);
    }
    let Some(mut rest) = past_name(after) else {
        return false;
    };
    let name = &after[..after.len() - rest.len()];
    if RAW_TAGS.iter().any(|raw| name.eq_ignore_ascii_case(raw)) {
        return false;
    }
    while let Some(more) = past_attribute(rest) {
        rest = more;
    }
    let rest = rest.trim_start();
    match rest.strip_prefix('/') {
        // Spacing stands before the slash of an empty tag and never after
        // it: `/>` is one thing markdown reads, not two it finds either
        // side of a gap.
        Some(empty) => empty
            .strip_prefix('>')
            .is_some_and(|tail| tail.trim().is_empty()),
        None => shuts(rest),
    }
}

/// Whether a tag ends here: `>` and then nothing but whitespace.
fn shuts(rest: &str) -> bool {
    rest.trim_start()
        .strip_prefix('>')
        .is_some_and(|tail| tail.trim().is_empty())
}

/// Whether this line ends the open block. A kind that ends on a mark ends
/// on the line carrying it, the line that opened the block included.
pub fn html_closes(kind: Html, line: &str) -> bool {
    match kind {
        Html::Raw => {
            let lower = line.to_ascii_lowercase();
            RAW_TAGS
                .iter()
                .any(|name| lower.contains(&format!("</{name}>")))
        }
        Html::Comment => line.contains("-->"),
        Html::Question => line.contains("?>"),
        Html::Bang => line.contains('>'),
        Html::Cdata => line.contains("]]>"),
        Html::Named => line.trim().is_empty(),
    }
}
