# Shell chrome

Read when building header actions, tabs or floating menus. Follow the skill's [token policy](../SKILL.md#theming-no-custom-theme-type-for-tokens), [interaction ownership](../SKILL.md#single-message-per-interaction) and [overlay state isolation](../SKILL.md#overlay-state-isolation).

## Builders

Use shared view builders for repeated actions, tabs and menu entries. Read every size and spacing value from the application's `TOKENS`. Use a custom Widget when composition cannot supply the required state, events or layout; see [surface selection](guide-surface-selection.md).

Action buttons use a fixed square with a centered icon. Tabs use content-driven width and a token-defined bar height. Header rows fill the available width and use a token-defined height. This builder assumes the application's token value and `action_style` closure:

```rust
fn shell_action<'a, Message: Clone + 'a>(
    content: impl Into<Element<'a, Message>>,
    on_press: Message,
) -> Element<'a, Message> {
    let t = &*TOKENS;
    button(
        container(content)
            .width(t.action_size)
            .height(t.action_size)
            .center(Length::Fill),
    )
    .padding(0)
    .style(action_style)
    .on_press(on_press)
    .into()
}
```

## Floating menus

Derive menu width from its widest label, icon space, gaps and horizontal padding. An estimated text width needs checking against the rendered font; use the [text measurement contract](advanced-text.md) when exact geometry matters.

Clamp the menu origin to the viewport. Flip above the trigger when it cannot fit below. Handle a menu larger than the viewport as part of that layout. Use `float` or `stack` with `opaque` for layering while keeping the base widget tree stable; follow the [overlay guide](guide-custom-overlays.md) for state and viewport rules.

For outside-click dismissal, the hit area must cover the outside region. A `mouse_area` sized only to the menu cannot receive those clicks. The [bundled modal helper](../examples/modal/src/main.rs) places opaque content inside a backdrop mouse area, then places that layer above the base. Preserve its nesting so inside clicks do not dismiss through the backdrop.

For delayed hover dismissal, start an application timer when the pointer leaves the menu and cancel it on re-entry. About 200 ms is the suggested delay. The [MouseArea implementation](https://github.com/iced-rs/iced/blob/0.14.0/widget/src/mouse_area.rs) reports entry/exit from bounds and cursor state; a raw window `CursorLeft` event alone does not describe leaving a menu.

## Tabs

Pane-grid title content uses `Shrink` width so empty space remains draggable:

```rust
pane_grid::TitleBar::new(row![tab_items].width(Length::Shrink))
```

For a scrollable tab row, use horizontal scrolling with content-driven width and bound it to the title bar's available space. Check that the resulting layout still leaves the intended pick area. [TitleBar::is_over_pick_area](https://github.com/iced-rs/iced/blob/0.14.0/widget/src/pane_grid/title_bar.rs) owns the hit-test geometry; [pane-grid rules](../SKILL.md#pane_grid) own drag behavior.

Draw the active indicator through the tab's conditional style rather than inserting another widget. This keeps the tree structure stable as selection changes. A tab builder that borrows its label returns `Element<'a, Message>` from `label: &'a str`.

Check narrow windows, overflow, dismissal, hover re-entry, scrolling and drag capture in the consuming app. The source patterns do not establish native input or rendered results.
