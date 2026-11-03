# Custom overlays

Read when implementing an Iced 0.14.0 overlay after `guide-custom-overlays.md`. The pinned [Overlay and child aggregation](https://github.com/iced-rs/iced/blob/0.14.0/core/src/overlay.rs) and [Group](https://github.com/iced-rs/iced/blob/0.14.0/core/src/overlay/group.rs) declarations own the interfaces. Prefer the built-in alternatives the guide names when they meet the task.

## State and geometry

An overlay implements layout and drawing, with optional input, operations, cursor feedback and nested overlays. Its methods differ from Widget methods: Overlay draw/update do not take a viewport parameter. Follow the guide's viewport rule when forwarding to descendant widgets rather than adding that parameter to the overlay method.

Keep persistent open/closed and animation state in the originating widget's tree. Overlay values borrow that state and may be requested again for update, draw or operation traversal. The pinned [UserInterface runtime](https://github.com/iced-rs/iced/blob/0.14.0/runtime/src/user_interface.rs) owns those calls; do not assume one retained overlay value per animation.

Respect accumulated parent translation when locating the anchor, including through scrollables. Use layout bounds for the overlay's own coordinate space. The guide's positioning patterns and `examples/toast/src/main.rs` show anchor/translation handling.

Returning no overlay removes its drawing path; it does not schedule a fade. Retain the overlay while a custom fade is active, then remove it after completion under the guide's visibility/invalidation rules. Check rendered alpha and interaction in the target renderer.

## Groups and traversal

Use `from_children` to collect child overlays from matching widget, tree and layout entries. A Group combines overlay elements and forwards layout, drawing, events, operations and nested overlays. It does not repair mismatched child structures.

Higher overlay indices draw above lower indices. The declaration owns the default. Give siblings explicit indices when relative order matters; Group's unstable sort does not guarantee input order for equal indices. Forward operations when focus/scroll queries must reach content inside the overlay.

Read `guide-custom-overlays.md` for the complete custom contract and `examples/toast/src/main.rs` for a composite overlay. The declaration and example are source evidence, not native viewport, fade or layering proof.

## Related references

- `advanced-widget.md`
- `advanced-tree.md`
- `advanced-operation.md`
- `guide-custom-overlays.md`
- `widget-tooltip.md`
