# Text

> `iced::advanced::text` · iced 0.14.0

Low-level text measurement and rendering for custom widgets. Central trait: `text::Renderer` with `fill_paragraph`, `fill_editor`, `fill_text`. Three types: `Text` (description), `Paragraph` (cached shaped glyphs), `Editor` (mutable text buffer).

Read when implementing or debugging text behavior in a custom widget or backend. Enable Iced’s `advanced` feature for the `iced::advanced` paths used here.

## Declarations

Pinned Iced 0.14.0 declarations, signatures, defaults and implementation:

- [core/src/text.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/text.rs).
- [core/src/text/paragraph.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/text/paragraph.rs).
- [graphics/src/text/paragraph.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/graphics/src/text/paragraph.rs).

## Patterns

Usage fragments below assume the surrounding widget implementation, imports and application message/state types.

### Cache a paragraph in widget state

```rust
struct State {
    paragraph: <Renderer as text::Renderer>::Paragraph,
    content: String,
}

// in layout():
let state = tree.state.downcast_mut::<State>();
let difference = state.paragraph.compare(Text {
    content: (),
    bounds: limits.max(),
    size: self.size,
    line_height: self.line_height,
    font: self.font,
    align_x: self.align_x,
    align_y: self.align_y,
    shaping: self.shaping,
    wrapping: self.wrapping,
});

// compare(Text<()>) cannot compare the text content itself.
let difference = if state.content != self.content {
    state.content = self.content.clone();
    Difference::Shape
} else {
    difference
};

match difference {
    Difference::None => {}
    Difference::Bounds => state.paragraph.resize(limits.max()),
    Difference::Shape => {
        state.paragraph = <Renderer as text::Renderer>::Paragraph::with_text(Text {
            content: self.content.as_str(),
            // ... (full Text)
        });
    }
}
```

### Draw a paragraph

```rust
fn draw(...) {
    let state = tree.state.downcast_ref::<State>();
    renderer.fill_paragraph(
        &state.paragraph,
        layout.position(),
        style.text_color,
        *viewport,
    );
}
```

### One-shot text without caching

```rust
renderer.fill_text(
    Text {
        content: "hello".to_string(),
        bounds: layout.bounds().size(),
        size: renderer.default_size(),
        line_height: LineHeight::default(),
        font: renderer.default_font(),
        align_x: Alignment::Start,
        align_y: Vertical::Top,
        shaping: Shaping::Auto,
        wrapping: Wrapping::Word,
    },
    layout.position(),
    style.text_color,
    *viewport,
);
```


## Gotchas

- Cache stable text in a `Paragraph` instead of relying on a backend’s `fill_text` cache. Keep paragraph creation and updates in layout; drawing can reuse it.
- `Paragraph::with_text` borrows the input for construction. Its returned `Self` has no input lifetime; the input need not remain borrowed for the paragraph’s lifetime.
- Use `Shaping::Basic` only when you control the text and font coverage; it provides no font fallback. `Auto` selects Basic for ASCII and Advanced otherwise. Shaping defaults also depend on the `basic-shaping` and `advanced-shaping` features in the linked declaration.
- Rebuild on `Difference::Shape`; resize on `Difference::Bounds`. Compare content separately: `compare(Text<()>)` checks shape attributes and bounds, not the string. `paragraph::Plain` offers a content-aware cache.
- The graphics backend delegates `hit_test` to its text buffer. Do your own bounds check when a pointer outside the widget must be rejected; do not treat the returned `Option` as a viewport check.
- `min_bounds()` is the minimum space that fits the contents; `bounds()` is the available layout space.

## See also

- `advanced-renderer.md`
- `advanced-text-editor.md`
- `advanced-text-highlighter.md`
- `widget-text.md`
