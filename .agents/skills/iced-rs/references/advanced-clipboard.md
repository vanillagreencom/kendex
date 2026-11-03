# Widget clipboard access

Read when handling text copy/paste in an Iced 0.14.0 custom widget. The pinned [Clipboard contract](https://github.com/iced-rs/iced/blob/0.14.0/core/src/clipboard.rs) owns read/write and clipboard kinds. The [winit backend](https://github.com/iced-rs/iced/blob/0.14.0/winit/src/clipboard.rs) owns connection and native forwarding.

## Copy and paste

Widgets receive a clipboard trait object during update. Read accepts a shared reference and returns optional text; write needs a mutable reference and accepts owned text. This trait carries text, not image/file/custom MIME payloads.

Inside the appropriate shortcut handler, write the selected text or publish a paste message when text is available:

```rust
use iced::advanced::clipboard::Kind;

clipboard.write(Kind::Standard, selected_text);

if let Some(text) = clipboard.read(Kind::Standard) {
    shell.publish(Message::Paste(text));
}
```

Keep copy and paste in their separate event branches. Handle a missing read without substituting empty text as proof of a successful paste.

## Availability

Use Standard for normal copy/paste. Primary is the selection clipboard, documented as normally present on X11/Wayland. If an application requires both standard copy/paste and primary-selection behavior, write the intended text to both kinds and check the supported backends.

The backend can be connected to a window or unavailable. An unavailable read returns no text; an unavailable write has no effect. A missing result alone does not establish which permission, connection or platform condition caused it. Verify foreground/background access and primary behavior on each target rather than assuming identical support or a universal Windows/macOS outcome.

## Related references

- `advanced-widget.md`
- `advanced-shell.md`
- `widget-text-input.md`
