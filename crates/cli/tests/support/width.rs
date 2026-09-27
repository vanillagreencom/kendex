//! A drawn line's visible cells, measured one way by the unit tests and
//! the presentation suite: escape sequences are not counted, and neither
//! is an OSC 8 hyperlink's target, which `console` alone would count.

pub fn visible_width(line: &str) -> usize {
    let mut rest = line;
    let mut visible = String::new();
    while let Some((before, after)) = rest.split_once("\x1b]8;;") {
        visible.push_str(before);
        let (_, after) = after
            .split_once("\x1b\\")
            .unwrap_or_else(|| panic!("unterminated hyperlink: {line:?}"));
        rest = after;
    }
    visible.push_str(rest);
    console::measure_text_width(&visible)
}
