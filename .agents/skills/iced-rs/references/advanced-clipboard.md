# Clipboard

> `iced::advanced::Clipboard` · iced 0.14.0

System clipboard trait. Read/write text via `&mut dyn Clipboard` in `Widget::update()`. `Kind::Standard` for Ctrl+C/V, `Kind::Primary` for X11/Wayland middle-click selection.

## API

### Trait definition

```rust
pub trait Clipboard {
    fn read(&self, kind: Kind) -> Option<String>;
    fn write(&mut self, kind: Kind, contents: String);
}
```

- **`read(kind)`** — Reads the current content of the clipboard as text.
  Returns `None` if the clipboard is empty or the operation fails.
- **`write(kind, contents)`** — Writes the given text contents to the
  clipboard.

### `Kind` enum

```rust
pub enum Kind {
    Standard,
    Primary,
}
```

- **`Standard`** — The standard clipboard (Ctrl+C / Ctrl+V on most systems).
- **`Primary`** — The primary selection clipboard. Normally only present on
  X11 and Wayland; middle-click paste.

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

- The trait takes `&self` for `read` but `&mut self` for `write`. You can
  call `read` from any context that holds a shared reference to the
  clipboard.
- Most platforms restrict clipboard access to foreground windows; a `read()`
  from a background window may silently return `None`.
- `Kind::Primary` is a no-op on Windows/macOS; both reads return `None` and
  writes are dropped. Write to both for cross-platform drag-like flows.
- The trait is **dyn-compatible** — widgets receive it as `&mut dyn Clipboard`
  through `update()`.
- Only text MIME type supported -- no images, files, or custom types.

## See also

- `advanced-widget.md`
- `advanced-shell.md`
- `widget-text-input.md`
