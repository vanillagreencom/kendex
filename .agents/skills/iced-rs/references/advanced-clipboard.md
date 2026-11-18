# Clipboard

> `iced::advanced::Clipboard` · iced 0.14.0

System clipboard trait. Read/write text via `&mut dyn Clipboard` in `Widget::update()`. `Kind::Standard` for Ctrl+C/V, `Kind::Primary` for X11/Wayland middle-click selection.

Read when implementing or debugging clipboard behavior in a custom widget or backend. Enable Iced’s `advanced` feature for the `iced::advanced` paths used here.

## Declarations

Pinned Iced 0.14.0 declarations, signatures, defaults and implementation:

- [core/src/clipboard.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/core/src/clipboard.rs).
- [winit/src/clipboard.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/winit/src/clipboard.rs).

## Patterns

```rust
fn update(
    &mut self,
    _tree: &mut Tree,
    event: &Event,
    _layout: Layout<'_>,
    _cursor: Cursor,
    _renderer: &Renderer,
    clipboard: &mut dyn Clipboard,
    shell: &mut Shell<'_, Message>,
    _viewport: &Rectangle,
) {
    // Copy
    if is_copy_shortcut(event) {
        clipboard.write(Kind::Standard, self.selected_text());
    }

    // Paste
    if is_paste_shortcut(event) {
        if let Some(text) = clipboard.read(Kind::Standard) {
            shell.publish((self.on_paste)(text));
        }
    }
}
```


## Gotchas

- The trait takes `&self` for `read` but `&mut self` for `write`. You can call `read` from any context that holds a shared reference to the clipboard.
- The winit backend returns `None` for an unavailable connection or a failed read. Handle absence without assuming why it occurred.
- Primary selection support depends on the platform backend. An unsupported primary read returns `None`; an unsupported primary write is ignored. Use `Kind::Standard` for ordinary copy/paste.
- The trait is **dyn-compatible** — widgets receive it as `&mut dyn Clipboard` through `update()`.
- This trait transfers text. It exposes no image, file or custom MIME operation.

## See also

- `advanced-widget.md`
- `advanced-shell.md`
- `widget-text-input.md`
