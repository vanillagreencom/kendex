# Elements

Read when composing Iced 0.14.0 views or mapping child messages. The pinned [Element implementation](https://github.com/iced-rs/iced/blob/0.14.0/core/src/element.rs) owns construction, mapping, widget access and layout explanation. The [versioned Pocket Guide](https://docs.rs/iced/0.14.0/iced/) shows view/update composition.

## Composition

An element hides a concrete widget type behind the common widget interface. Built-in widgets normally convert with `.into()`. Use an explicit `Element` return or conversion when Rust cannot infer the message or target type. `Element::new` also accepts a widget directly when implementing a custom conversion.

The view's resulting message type must match update. Map child messages into the parent's enum while composing the view:

```rust
child_component.view().map(Message::Child)
```

Keep the child identifier in that mapping when more than one child instance can emit the same message. The pinned `Element::map` example demonstrates indexed counters and delegation back to their update method.

## Lifetimes and inspection

The element's lifetime bounds the data its widget borrows. A view can borrow application state; it cannot return an element that borrows a temporary destroyed by that view call. Keep persistent application/widget state in its state owner rather than storing a borrowed view to extend its lifetime. An element that owns its data can have a different lifetime, so do not infer a universal expiration at the next view call.

`as_widget` and `as_widget_mut` expose the underlying widget interface. They do not expose a general iterator of child elements or return the runtime's state tree. Use custom-widget/tree contracts when implementing traversal.

For a layout diagnostic, wrap an element with `explain(color)`:

```rust
element.explain(iced::Color::from_rgb(1.0, 0.0, 0.0))
```

The renderer draws that explanation. Confirm its output in the target application rather than treating the wrapper as a screenshot or layout test.

## Related references

- `advanced-widget.md`
- `advanced-tree.md`
- `application.md`
- `widget-column-row.md`
