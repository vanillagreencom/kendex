# Widget state tree

Read when storing or reconciling custom-widget state in Iced 0.14.0. The pinned [Tree, Tag and State declarations](https://github.com/iced-rs/iced/blob/0.14.0/core/src/widget/tree.rs) own construction, reconciliation and downcasts. The [runtime build](https://github.com/iced-rs/iced/blob/0.14.0/runtime/src/user_interface.rs) calls reconciliation when constructing a user interface.

## Persistent state

Use the same concrete type for a widget's tag, initial state and subsequent downcasts. A stateless or mismatched downcast panics. A changed tag recreates the tree, resetting the state associated with the old widget.

```rust
fn tag(&self) -> tree::Tag {
    tree::Tag::of::<MyWidgetState>()
}

fn state(&self) -> tree::State {
    tree::State::new(MyWidgetState::default())
}
```

Read that state through the `Tree` passed to widget methods. The bundled `examples/custom_widget/src/main.rs` and `examples/loading_spinners/src/circular.rs` show custom widget construction and persistent animation state. Keep the tree on the UI thread; its erased state is not a thread-transfer contract.

## Children and identity

Composite widgets create child trees in `children()` and reconcile them in `diff()`. Keep that order consistent with layout, drawing and event traversal. `diff_children` handles positional children; custom reconciliation helpers serve explicit identity rules. Read `guide-animated-layout.md` before implementing keyed or reorderable content.

Keep wrappers and state types stable when only a handler or visibility changes. A changed tree shape can reset or misassociate interaction state. Preserve all children required by the widget's contract rather than dropping their state only because an overlay is hidden.

Reconciliation belongs to a rebuild, not an unconditional callback on every paint frame. Keep it cheap. Layout and paragraph measurement belong in layout; per-frame custom-widget animation data belongs in tree state. `animation.md` owns how redraws observe that state without rebuilding widget values.

## Related references

- `advanced-widget.md`
- `advanced-shell.md`
- `guide-custom-widgets.md`
- `guide-animated-layout.md`
- `animation.md`
