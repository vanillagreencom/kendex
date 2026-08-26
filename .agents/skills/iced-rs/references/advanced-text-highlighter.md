# Text Highlighter (advanced)

> `iced::advanced::text::highlighter` · iced 0.14.0

The `Highlighter` trait defines the contract for syntax highlighting in text editors. Highlighters process lines sequentially and must be notified when lines change so subsequent lines can be re-highlighted.

## API

### `Highlighter` trait

```rust
pub trait Highlighter: 'static {
    type Settings: PartialEq + Clone;
    type Highlight;
    type Iterator<'a>: Iterator<Item = (Range<usize>, Self::Highlight)>
        where Self: 'a;

    fn new(settings: &Self::Settings) -> Self;
    fn update(&mut self, new_settings: &Self::Settings);
    fn change_line(&mut self, line: usize);
    fn highlight_line(&mut self, line: &str) -> Self::Iterator<'_>;
    fn current_line(&self) -> usize;
}
```

- **`Settings`** -- configuration type (e.g., language, theme name). Compared with `PartialEq` to detect when re-initialization is needed.
- **`Highlight`** -- the output token type. Mapped to `Format<Font>` by the widget.
- **`Iterator<'a>`** -- yields `(Range<usize>, Highlight)` pairs: byte range + highlight token for each segment of a line.
- **`new(settings)`** -- construct from settings.
- **`update(new_settings)`** -- apply new settings without full reconstruction.
- **`change_line(line)`** -- notify that the line at `line` was modified. The highlighter resets its internal state to at most this line index.
- **`highlight_line(line)`** -- highlight one line, returning an iterator of range-highlight pairs. Called sequentially from `current_line()` forward.
- **`current_line()`** -- the line index the highlighter is currently positioned at.

### `Format<Font>` struct

```rust
pub struct Format<Font> {
    pub color: Option<Color>,
    pub font: Option<Font>,
}
```

The output format applied to each highlighted span. `color` overrides the default text color; `font` overrides the default font (e.g., to switch to bold/italic variants).

### `PlainText` struct (no-op highlighter)

```rust
pub struct PlainText;

impl Highlighter for PlainText {
    type Settings = ();
    type Highlight = ();
    type Iterator<'a> = std::iter::Empty<(Range<usize>, ())>;

    fn new(_settings: &()) -> Self { PlainText }
    fn update(&mut self, _new_settings: &()) {}
    fn change_line(&mut self, _line: usize) {}
    fn highlight_line(&mut self, _line: &str) -> Self::Iterator<'_> {
        std::iter::empty()
    }
    fn current_line(&self) -> usize { 0 }
}
```

Used as the default when no highlighting is configured. `TextEditor::new()` uses `PlainText` internally.

## Patterns

### Custom keyword highlighter

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
        // ... tokenize `line`, push (range, is_keyword) pairs ...
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
