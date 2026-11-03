# Text

Read when measuring or drawing text in a custom widget for Iced 0.14.0. The pinned [text declarations](https://github.com/iced-rs/iced/blob/0.14.0/core/src/text.rs) own `Text`, shaping, wrapping, alignment and the renderer contract. The [paragraph declarations](https://github.com/iced-rs/iced/blob/0.14.0/core/src/text/paragraph.rs) own paragraph construction, comparison and hit testing.

## Drawing

Use `fill_paragraph` for a paragraph retained in widget state, `fill_editor` for an editor buffer and `fill_text` for an owned text description. Renderer defaults are instance methods. The renderer's icon font and icon constants provide the built-in widget symbols.

Keep the paragraph in `Tree::state` and update it during layout. The pinned [Text widget's layout and draw helpers](https://github.com/iced-rs/iced/blob/0.14.0/core/src/widget/text.rs) show how to update its paragraph, measure minimum bounds, calculate the alignment anchor and pass the viewport as clipping bounds. Drawing an editor buffer alone does not establish that a caret or selection is drawn; inspect the editor widget for those paths.

`fill_text` does not promise a reshape on every frame. The bundled `iced_wgpu/src/lib.rs` text renderer queues it, and `iced_wgpu/src/text.rs::prepare` uses a buffer cache. Choose a retained paragraph when the widget needs explicit measurement and reuse; measure the actual backend before claiming a performance difference.

## Paragraph updates

Check content changes separately from `Paragraph::compare`, whose input has `()` content. The existing `paragraph::Plain::update` owns this reconciliation pattern:

- Changed content creates a paragraph from the new text.
- `Difference::None` reuses it.
- `Difference::Bounds` resizes it.
- `Difference::Shape` creates it again because shaping attributes changed.

`Text::with_content` borrows the description and returns one with replacement content. `Paragraph::with_text` accepts borrowed input, but the renderer's associated paragraph is `'static`; that input does not impose a matching string-borrow lifetime on cached widget state. The pinned [graphics paragraph implementation](https://github.com/iced-rs/iced/blob/0.14.0/graphics/src/text/paragraph.rs) owns its text buffer.

## Shaping and hit testing

Use basic shaping only when you control the text and know the font covers it. It has no shaping or font fallback for missing glyphs. Advanced shaping handles complex scripts and fallback. `Auto` chooses from the content; enabled shaping features select the default. The text declaration owns the exact defaults and wrapping variants.

`bounds()` is the available layout area; `min_bounds()` is the minimum area that fits the content. Use hit testing for character positions, `hit_span` for span indices, `span_bounds` for per-line span rectangles and `grapheme_position` for cursor placement. Handle their optional results. Do not assume the trait guarantees either clamping or `None` outside the paragraph: the graphics implementation delegates character hit testing to its text buffer. Check the selected backend when outside-bounds behavior matters.

## Related references

- `advanced-renderer.md`
- `advanced-text-editor.md`
- `advanced-text-highlighter.md`
- `widget-text.md`
