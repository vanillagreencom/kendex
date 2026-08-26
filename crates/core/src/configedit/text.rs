//! Edits over files kept as text — a TOML the user comments, a Markdown
//! the harness appends to — where re-serializing would lose what they wrote.

/// Preserves comments, ordering and line endings: sets `hooks = true` in
/// the `[features]` table, adding the table at the end when there is none.
/// A `hooks` key already there is the user's — whatever it says — and a
/// deprecated `codex_hooks` key is renamed in place.
pub(super) fn codex_enable_hooks(current: &str) -> String {
    let newline = match current.contains("\r\n") {
        true => "\r\n",
        false => "\n",
    };
    let mut lines: Vec<String> = current.split_inclusive('\n').map(str::to_owned).collect();
    let mut in_features = false;
    let mut header = None;
    for (index, line) in lines.iter_mut().enumerate() {
        let body = line.trim();
        if body.starts_with('[') {
            in_features = body == "[features]";
            if in_features {
                header = Some(index);
            }
            continue;
        }
        let key = body.split('=').next().unwrap_or_default().trim();
        if in_features && key == "hooks" {
            return current.to_owned();
        }
        if in_features && key == "codex_hooks" {
            *line = line.replacen("codex_hooks", "hooks", 1);
            return lines.concat();
        }
    }
    let feature = format!("hooks = true{newline}");
    match header {
        Some(index) => lines.insert(index + 1, feature),
        None => {
            if let Some(last) = lines.last_mut()
                && !last.ends_with('\n')
            {
                last.push_str(newline);
            }
            if lines.last().is_some_and(|l| l.trim() != "") {
                lines.push(newline.to_owned());
            }
            lines.push(format!("[features]{newline}"));
            lines.push(feature);
        }
    }
    lines.concat()
}

fn marker_bounds(name: &str) -> (String, String) {
    (
        format!("<!-- kendex:append-system {name} begin -->"),
        format!("<!-- kendex:append-system {name} end -->"),
    )
}

pub fn upsert_marker_block(current: &str, name: &str, block: &str) -> String {
    let stripped = remove_marker_block(current, name);
    let (begin, end) = marker_bounds(name);
    let base = stripped.trim_end();
    if base.is_empty() {
        format!("{begin}\n{block}\n{end}\n")
    } else {
        format!("{base}\n\n{begin}\n{block}\n{end}\n")
    }
}

pub fn remove_marker_block(current: &str, name: &str) -> String {
    let (begin, end) = marker_bounds(name);
    remove_between(current, &begin, &end)
}

fn remove_between(current: &str, begin: &str, end: &str) -> String {
    let Some((start, stop)) = marker_block_span(current, begin, end) else {
        return current.to_owned();
    };
    let before = current[..start].trim_end_matches('\n');
    let after = current[stop..].trim_start_matches('\n');
    match (before.is_empty(), after.is_empty()) {
        (true, true) => String::new(),
        (true, false) => after.to_owned(),
        (false, true) => format!("{before}\n"),
        (false, false) => format!("{before}\n\n{after}"),
    }
}

/// The byte span of the marker block, begin line through end line. A marker
/// counts only when its whole line, trimmed, is the marker and the line sits
/// outside any fenced code region — a document quoting its own markers in an
/// example must never lose the example or anything around it. `None` when no
/// real block exists; a begin with no end is user damage, also untouched.
fn marker_block_span(current: &str, begin: &str, end: &str) -> Option<(usize, usize)> {
    let mut fence: Option<char> = None;
    let mut start: Option<usize> = None;
    let mut offset = 0;
    for line in current.split_inclusive('\n') {
        let next = offset + line.len();
        let body = line.trim();
        match fence {
            Some(open) => {
                let run = body.chars().take_while(|c| *c == open).count();
                if run >= 3 && body[run..].trim().is_empty() {
                    fence = None;
                }
            }
            None if body.starts_with("```") => fence = Some('`'),
            None if body.starts_with("~~~") => fence = Some('~'),
            None => {
                if start.is_none() && body == begin {
                    start = Some(offset);
                } else if let Some(start) = start
                    && body == end
                {
                    return Some((start, next));
                }
            }
        }
        offset = next;
    }
    None
}

#[cfg(test)]
mod tests {
    use super::codex_enable_hooks;

    /// The file is the user's: only the one key changes, its line endings
    /// stay, and text that merely mentions `codex_hooks` is not a key.
    #[test]
    fn enabling_hooks_edits_one_line_and_nothing_else() {
        let crlf = "model = \"gpt\"\r\nnotify = [\"~/.codex/codex_hooks/n.py\"]\r\n\r\n[features]\r\ncodex_hooks = true\r\n";
        let migrated = codex_enable_hooks(crlf);
        assert_eq!(
            migrated,
            "model = \"gpt\"\r\nnotify = [\"~/.codex/codex_hooks/n.py\"]\r\n\r\n[features]\r\nhooks = true\r\n"
        );
        assert_eq!(codex_enable_hooks(&migrated), migrated);

        let declined = "[features]\nhooks = false\n";
        assert_eq!(codex_enable_hooks(declined), declined);

        let elsewhere = "[other]\nhooks = true\n";
        assert_eq!(
            codex_enable_hooks(elsewhere),
            "[other]\nhooks = true\n\n[features]\nhooks = true\n"
        );
        assert_eq!(
            codex_enable_hooks("model = \"gpt\""),
            "model = \"gpt\"\n\n[features]\nhooks = true\n"
        );
    }
}
