pub mod agent;
mod blocks;
pub mod command;
mod fences;
mod marks;
pub mod permission;
pub mod skill;
pub mod validate;
pub mod vocab;

/// Where a document's code is: which lines stand inside a block, which is
/// what tells whitespace that is a block's own content from whitespace
/// that separates prose, and where the code spans of each line are.
pub(crate) use blocks::{code_spans_by_line, inside_a_block};

/// One thing the user should hear about a rendering, with the fix when
/// there is one — every render lint travels through this shape.
#[derive(Debug, Clone, PartialEq)]
pub struct RenderWarning {
    pub message: String,
    pub remediation: Option<String>,
}

impl RenderWarning {
    pub fn new(message: impl Into<String>) -> RenderWarning {
        RenderWarning {
            message: message.into(),
            remediation: None,
        }
    }

    pub fn with_fix(message: impl Into<String>, remediation: impl Into<String>) -> RenderWarning {
        RenderWarning {
            message: message.into(),
            remediation: Some(remediation.into()),
        }
    }
}

/// Emit a YAML scalar that parses back as exactly this string. Values that
/// could read as another type (YAML 1.1 reserved words, leading digits),
/// open a construct (`*`, `&`, `[`, …), or smuggle structure (newlines,
/// quotes, `: `) are double-quoted with escapes; everything else stays
/// plain. Interpolated foreign text — tool names, descriptions, skill
/// names — must always pass through here: a raw newline in a generated
/// file is a frontmatter injection, not a cosmetic bug.
pub fn yaml_scalar(text: &str) -> String {
    if !needs_quoting(text) {
        return text.to_owned();
    }
    yaml_quoted(text)
}

/// The always-quoted form, for fields whose values are prose or commands —
/// quoting them unconditionally keeps the output shape stable.
pub fn yaml_quoted(text: &str) -> String {
    let mut out = String::with_capacity(text.len() + 2);
    out.push('"');
    for ch in text.chars() {
        match ch {
            '\\' => out.push_str("\\\\"),
            '"' => out.push_str("\\\""),
            '\n' => out.push_str("\\n"),
            '\r' => out.push_str("\\r"),
            '\t' => out.push_str("\\t"),
            ch if ch.is_control() => out.push_str(&format!("\\u{:04X}", ch as u32)),
            ch => out.push(ch),
        }
    }
    out.push('"');
    out
}

fn needs_quoting(text: &str) -> bool {
    let reserved = matches!(
        text.to_ascii_lowercase().as_str(),
        "" | "~" | "null" | "true" | "false" | "yes" | "no" | "on" | "off"
    );
    let first_unsafe = text.chars().next().is_some_and(|c| {
        c.is_ascii_digit()
            || matches!(
                c,
                ' ' | '\t'
                    | '!'
                    | '&'
                    | '*'
                    | '-'
                    | '?'
                    | ':'
                    | ','
                    | '['
                    | ']'
                    | '{'
                    | '}'
                    | '#'
                    | '|'
                    | '>'
                    | '@'
                    | '`'
                    | '"'
                    | '\''
                    | '%'
            )
    });
    reserved
        || first_unsafe
        || text.ends_with([' ', '\t', ':'])
        || text.contains(": ")
        || text.contains(" #")
        || text.contains(['\n', '\r', '"', '\\'])
        || text.chars().any(char::is_control)
}

#[cfg(test)]
mod tests {
    use super::yaml_scalar;

    #[test]
    fn safe_text_stays_plain_and_everything_else_quotes() {
        assert_eq!(yaml_scalar("rust engineer"), "rust engineer");
        assert_eq!(yaml_scalar("Read, Grep"), "Read, Grep");
        assert_eq!(yaml_scalar("no"), "\"no\"");
        assert_eq!(yaml_scalar("2 approaches"), "\"2 approaches\"");
        assert_eq!(yaml_scalar("*star"), "\"*star\"");
        assert_eq!(yaml_scalar("use when: x"), "\"use when: x\"");
        assert_eq!(yaml_scalar(""), "\"\"");
    }

    #[test]
    fn newlines_and_quotes_cannot_escape_the_scalar() {
        assert_eq!(yaml_scalar("a\nb: c"), "\"a\\nb: c\"");
        assert_eq!(yaml_scalar("say \"hi\""), "\"say \\\"hi\\\"\"");
        assert_eq!(yaml_scalar("tab\there"), "\"tab\\there\"");
        assert_eq!(yaml_scalar("bell\u{7}"), "\"bell\\u0007\"");
    }
}
