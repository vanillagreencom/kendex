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

/// How many blockquote markers open this line, and what stands after the
/// last of them. Each marker takes up to three spaces of indent, its `>`,
/// and one space of its own.
///
/// The count is what a lazy continuation is read against: a line carrying
/// fewer markers than the paragraph above it is still that paragraph, and
/// only a line carrying more opens a quote inside it.
pub fn quote_depth(line: &str) -> (usize, &str) {
    let mut rest = line;
    let mut depth = 0;
    while let Some(after) = unindented(rest).and_then(|open| open.strip_prefix('>')) {
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
/// `Named` — a block-level tag from markdown's own list — at a blank line.
///
/// Markdown's seventh kind, any complete tag standing alone on its line,
/// is left out. It is the one kind that may not interrupt a paragraph, so
/// reading a line of prose that opens with a tag as a block of its own
/// would end a span markdown leaves running.
#[derive(Clone, Copy, PartialEq, Eq)]
pub enum Html {
    Raw,
    Comment,
    Question,
    Bang,
    Cdata,
    Named,
}

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

/// Which raw HTML block this line opens, if any. Every kind here may
/// interrupt a paragraph, so a line opening one ends the block above it.
pub fn html_opens(line: &str) -> Option<Html> {
    let after = unindented(line)?.strip_prefix('<')?.to_ascii_lowercase();
    if ["script", "pre", "style", "textarea"]
        .iter()
        .any(|name| tag_named(&after, name))
    {
        return Some(Html::Raw);
    }
    if after.starts_with("!--") {
        return Some(Html::Comment);
    }
    if after.starts_with('?') {
        return Some(Html::Question);
    }
    if after.starts_with("![cdata[") {
        return Some(Html::Cdata);
    }
    if let Some(rest) = after.strip_prefix('!')
        && rest.starts_with(|c: char| c.is_ascii_alphabetic())
    {
        return Some(Html::Bang);
    }
    let name = after.strip_prefix('/').unwrap_or(&after);
    BLOCK_TAGS
        .iter()
        .any(|tag| tag_named(name, tag))
        .then_some(Html::Named)
}

/// Whether `after` — a line past its `<` — opens with this tag name and
/// nothing but the tag's own end behind it. The end is what tells `<p `
/// from the `<param` standing one letter further on.
fn tag_named(after: &str, name: &str) -> bool {
    after.strip_prefix(name).is_some_and(|rest| {
        rest.is_empty()
            || rest.starts_with('>')
            || rest.starts_with("/>")
            || rest.starts_with(char::is_whitespace)
    })
}

/// Whether this line ends the open block. A kind that ends on a mark ends
/// on the line carrying it, the line that opened the block included.
pub fn html_closes(kind: Html, line: &str) -> bool {
    let lower = line.to_ascii_lowercase();
    match kind {
        Html::Raw => ["</script>", "</pre>", "</style>", "</textarea>"]
            .iter()
            .any(|end| lower.contains(end)),
        Html::Comment => lower.contains("-->"),
        Html::Question => lower.contains("?>"),
        Html::Bang => lower.contains('>'),
        Html::Cdata => lower.contains("]]>"),
        Html::Named => lower.trim().is_empty(),
    }
}
