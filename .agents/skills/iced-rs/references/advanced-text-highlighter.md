# Text Highlighter (advanced)

> `iced::advanced::text::highlighter` · iced 0.14.0

The `Highlighter` trait defines the contract for syntax highlighting in text editors. Highlighters process lines sequentially and must be notified when lines change so subsequent lines can be re-highlighted.

Read when implementing or debugging text highlighter behavior in a custom widget or backend. Enable Iced’s `advanced` feature for the `iced::advanced` paths used here.

## Declarations

Pinned Iced 0.14.0 declarations, signatures, defaults and implementation:

- [core/src/text/highlighter.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/text/highlighter.rs).
- [widget/src/text_editor.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/text_editor.rs).

## Patterns

### Custom keyword highlighter

This stateless example matches whitespace-separated words, including UTF-8 byte offsets. It does not tokenize punctuation or carry syntax state across lines. Returning line zero asks the backend to revisit visible lines; a stateful highlighter must track and reset its current line.

```rust
use iced::advanced::text::highlighter::{self, Format, Highlighter};
use std::ops::Range;

struct KeywordHighlighter {
    keywords: Vec<String>,
}

#[derive(Clone, PartialEq)]
struct Settings {
    keywords: Vec<String>,
}

impl Highlighter for KeywordHighlighter {
    type Settings = Settings;
    type Highlight = bool; // true = keyword
    type Iterator<'a> = std::vec::IntoIter<(Range<usize>, bool)>;

    fn new(settings: &Settings) -> Self {
        Self { keywords: settings.keywords.clone() }
    }

    fn update(&mut self, new_settings: &Settings) {
        self.keywords = new_settings.keywords.clone();
    }

    fn change_line(&mut self, _line: usize) {}

    fn highlight_line(&mut self, line: &str) -> Self::Iterator<'_> {
        let mut spans = Vec::new();
        let mut offset = 0;
        for token in line.split_inclusive(char::is_whitespace) {
            let word = token.trim_end();
            if self.keywords.iter().any(|keyword| keyword == word) {
                spans.push((offset..offset + word.len(), true));
            }
            offset += token.len();
        }
        spans.into_iter()
    }

    fn current_line(&self) -> usize { 0 }
}
```

### Wire a custom highlighter into TextEditor

```rust
use iced::widget::text_editor;

text_editor(&state.content)
    .on_action(Message::Edit)
    .highlight_with::<KeywordHighlighter>(
        Settings { keywords: vec!["fn".into(), "let".into()] },
        |is_keyword, _theme| {
            Format {
                color: if *is_keyword { Some(Color::from_rgb(0.4, 0.7, 1.0)) } else { None },
                font: None,
            }
        },
    )
```

### Use the built-in syntax highlighter

```rust
// Requires feature = "highlighter"
text_editor(&state.content)
    .on_action(Message::Edit)
    .highlight("rs", highlighter_theme)
```

## Gotchas

- `Highlighter` is **not dyn-compatible** -- you cannot use `Box<dyn Highlighter>`.
- Lines are fed sequentially. If `change_line(5)` is called, the next `highlight_line` call will be for line 5, then 6, etc. The highlighter must handle this reset correctly.
- `Settings` must implement `PartialEq + Clone`. The widget compares old vs new settings each frame to decide whether to call `update`.
- `Format.color = None` means "inherit the default text color", not "invisible".
- The `highlighter` feature flag enables the built-in `syntect`-based highlighter; custom highlighters work without it.

## See also

- `widget-text-editor.md` -- the `TextEditor` widget that consumes highlighters
- `advanced-text-editor.md` -- the `Editor` trait that calls `highlight()`
- `advanced-text.md` -- `text::Renderer`, `Paragraph`, `Shaping`
- `catalog.md` -- styling pattern (separate from highlighting)
