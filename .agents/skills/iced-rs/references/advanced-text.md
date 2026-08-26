# Text

> `iced::advanced::text` · iced 0.14.0

Low-level text measurement and rendering for custom widgets. Central trait: `text::Renderer` with `fill_paragraph`, `fill_editor`, `fill_text`. Three types: `Text` (description), `Paragraph` (cached shaped glyphs), `Editor` (mutable text buffer).

## API

### `text::Renderer` trait

```rust
pub trait Renderer: iced_advanced::Renderer {
    type Font: Copy + PartialEq;
    type Paragraph: Paragraph<Font = Self::Font>;
    type Editor: Editor<Font = Self::Font>;

    const ICON_FONT: Self::Font;
    const CHECKMARK_ICON: char;
    const ARROW_DOWN_ICON: char;
    const SCROLL_UP_ICON: char;
    const SCROLL_DOWN_ICON: char;
    const SCROLL_LEFT_ICON: char;
    const SCROLL_RIGHT_ICON: char;
    const ICED_LOGO: char;

    fn default_font() -> Self::Font;
    fn default_size() -> Pixels;

    fn fill_paragraph(
        &mut self,
        text: &Self::Paragraph,
        position: Point,
        color: Color,
        clip_bounds: Rectangle,
    );

    fn fill_editor(
        &mut self,
        editor: &Self::Editor,
        position: Point,
        color: Color,
        clip_bounds: Rectangle,
    );

    fn fill_text(
        &mut self,
        text: Text<String, Self::Font>,
        position: Point,
        color: Color,
        clip_bounds: Rectangle,
    );
}
```

- **`default_font()` / `default_size()`** — The backend defaults for
  fallback fonts and size.
- **`fill_paragraph`** — Draw a pre-computed `Paragraph`. Prefer this for
  stable text: create the paragraph once (in `layout()`), store it in the
  widget's tree state, and draw it every frame.
- **`fill_editor`** — Draw an `Editor` instance, including caret and
  selection.
- **`fill_text`** — Draw raw text without caching. Convenient but slow —
  the renderer reshapes the text every frame.
- The icon constants let widgets reuse the built-in icon font for things
  like checkmarks and scroll arrows without shipping their own assets.

### `Text` struct

```rust
pub struct Text<Content, Font> {
    pub content: Content,
    pub bounds: Size,
    pub size: Pixels,
    pub line_height: LineHeight,
    pub font: Font,
    pub align_x: Alignment,
    pub align_y: Vertical,
    pub shaping: Shaping,
    pub wrapping: Wrapping,
}

impl<Content, Font> Text<Content, Font> {
    pub fn with_content<T>(self, content: T) -> Text<T, Font>;
    pub fn as_ref(&self) -> Text<&str, Font>;
}
```

The declarative description of a run of text. Most widgets build a `Text`
and hand it to either `fill_text` (for one-shot use) or convert it to a
`Paragraph` for caching.

### `Paragraph` trait

```rust
pub trait Paragraph {
    type Font: Copy + PartialEq;

    fn with_text(text: Text<&str, Self::Font>) -> Self;
    fn with_spans<Link>(
        text: Text<&[Span<'_, Link, Self::Font>], Self::Font>,
    ) -> Self;

    fn resize(&mut self, new_bounds: Size);
    fn compare(&self, text: Text<(), Self::Font>) -> Difference;

    fn size(&self) -> Pixels;
    fn font(&self) -> Self::Font;
    fn line_height(&self) -> LineHeight;
    fn align_x(&self) -> Alignment;
    fn align_y(&self) -> Vertical;
    fn wrapping(&self) -> Wrapping;
    fn shaping(&self) -> Shaping;

    fn bounds(&self) -> Size;
    fn min_bounds(&self) -> Size;

    fn hit_test(&self, point: Point) -> Option<Hit>;
    fn hit_span(&self, point: Point) -> Option<usize>;
    fn span_bounds(&self, index: usize) -> Vec<Rectangle>;
    fn grapheme_position(&self, line: usize, index: usize) -> Option<Point>;

    // Provided
    fn min_width(&self) -> f32 { ... }
    fn min_height(&self) -> f32 { ... }
}
```

- **`with_text(text)` / `with_spans(text)`** — Factory constructors. The
  rich-text variant takes a slice of `Span`s for inline formatting.
- **`resize(new_bounds)`** — Lay the paragraph out again with new
  constraints. Call when the container resizes but the content is unchanged.
- **`compare(text) -> Difference`** — Compare an existing paragraph against
  a desired `Text<()>`. Returns whether nothing / styling / layout / content
  changed. Use in `layout()` to decide whether to reshape.
- **`bounds()` / `min_bounds()`** — The available bounds it was laid out
  with, and the tight minimum bounds of the rendered glyphs.
- **`hit_test(point)` / `hit_span(point)`** — Map a pixel position back to
  a text index or span index. For cursor placement and link hit testing.
- **`span_bounds(index)`** — Returns all rectangles covered by a span (one
  per line it spans). Used to draw per-span backgrounds.
- **`grapheme_position(line, index)`** — The pixel position of a grapheme.
  Used to place the text cursor.
- The `Paragraph` trait is **not dyn-compatible**.

### `Shaping` enum

```rust
pub enum Shaping {
    Auto,
    Basic,
    Advanced,
}
```

- **`Auto`** — Chooses `Basic` for ASCII-only text and `Advanced` otherwise.
  Default when no feature flags are set.
- **`Basic`** — No shaping or font fallback. Very fast. Safe only if you
  control the content and the font has every glyph.
- **`Advanced`** — Full shaping and font fallback. Required for complex
  scripts (Arabic, Devanagari, CJK) or multi-font layouts. Computationally
  expensive.

`Wrapping` variants: `Word` (default), `Glyph`, `WordOrGlyph`, `None`.

## Patterns

### Cache a paragraph in widget state

```rust
struct State {
    paragraph: <Renderer as text::Renderer>::Paragraph,
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

- `fill_text` re-shapes every frame. For anything that is redrawn at 60 FPS
  and doesn't change per frame, cache a `Paragraph` instead.
- `Paragraph::with_text` takes `Text<&str, _>` — **it borrows** the content.
  If you cache the paragraph in widget state, the shaped glyphs are stored
  but the paragraph internally keeps references that live for the lifetime
  of the struct; creating a new paragraph each frame is what you're trying
  to avoid.
- `Shaping::Basic` is fast but silently drops glyphs that aren't in the
  font — double-check your font actually covers the text before using it.
  `Shaping::Auto` is the safer default.
- `compare()` returns `Difference::Shape` whenever the styling changes —
  you must fully rebuild the paragraph; resize is not enough.
- `hit_test` returns `None` outside the paragraph bounds, not the closest
  grapheme. If you want a "clamp to nearest" behaviour, clamp `point` to the
  paragraph's `min_bounds()` first.
- `min_bounds()` is tight glyph bounds -- don't confuse with `bounds()`.

## See also

- `advanced-renderer.md`
- `advanced-text-editor.md`
- `advanced-text-highlighter.md`
- `widget-text.md`
