# Shell

Read when a custom Iced 0.14.0 widget publishes messages, captures input or requests runtime work. The pinned [Shell declaration](https://github.com/iced-rs/iced/blob/0.14.0/core/src/shell.rs) owns its methods and merge semantics. `animation.md` owns redraw scheduling and the redraw/rebuild distinction.

## Messages and capture

Publish a message when the application must handle an interaction. Capture the event when ancestors should not handle it as well. Publishing alone does not capture; keep both actions in the handler when both are needed.

```rust
if cursor.is_over(layout.bounds()) {
    shell.publish((self.on_press)());
    shell.capture_event();
}
```

Run that pattern inside the intended event branch, such as a left-button press. Check current capture status when forwarding input through a composite widget.

## Invalidation and input methods

Use layout invalidation when geometry changes. Use widget invalidation when the runtime must rebuild widget values as well. The pinned [UserInterface runtime](https://github.com/iced-rs/iced/blob/0.14.0/runtime/src/user_interface.rs) consumes these flags; they are separate from requesting another frame.

Send input-method requests during `window::Event::RedrawRequested`, as the Shell contract requires. Retain preedit/cursor information in the widget's state until that request can be made. Check the target's native IME behavior; the method declaration is not a native delivery test.

## Child shells

A child shell can collect child messages before mapping them into the parent's message type. `merge` consumes that shell, maps and drains its messages, combines layout/widget invalidation and capture, takes the earliest redraw request and merges input-method requests. Merge the complete child shell instead of copying only its message buffer and losing those effects.

## Related references

- `advanced-widget.md`
- `advanced-overlay.md`
- `advanced-tree.md`
- `events.md`
- `animation.md`
