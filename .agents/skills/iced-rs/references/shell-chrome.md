# Shell Chrome

Patterns for building app-level shell UI: header bars, action buttons, tab bars, and floating menus.

## Token-driven builders

Shell elements (action buttons, tab items, menu entries) repeat throughout the app. Extract them into builder functions that read sizing/spacing from `TOKENS` — never inline magic numbers.

```rust
fn shell_action<'a, Message: Clone + 'a>(
    content: impl Into<Element<'a, Message>>,
    on_press: Message,
) -> Element<'a, Message> {
    let t = &*TOKENS;
    button(
        container(content)
            .width(Length::Fixed(t.action_size))
            .height(Length::Fixed(t.action_size))
            .center(Length::Fill),
    )
    .padding(0)
    .style(action_style)
    .on_press(on_press)
    .into()
}
```

### Why builders, not components

A helper returning `Element` is zero-cost view construction. Reserve custom `Widget` impls for elements needing their own state or event handling.

### Sizing rules

- Action buttons: fixed square (`action_size × action_size`), icon centered
- Tab items: `Shrink` width (text-driven), fixed height matching the tab bar
- Header row: `Fill` width, fixed height from tokens
- All padding/spacing values from `TOKENS` — one change updates every instance

## Content-driven floating menus

Dropdown/context menus should derive their width from content rather than using a fixed size.

### Width computation

Measure the widest item and apply symmetric horizontal padding:

```rust
fn menu_width(items: &[MenuItem], t: &AppTokens) -> f32 {
    let max_text = items.iter()
        .map(|item| estimate_text_width(&item.label, t.font_size))
        .fold(0.0f32, f32::max);
    // icon + gap + text + right padding
    let content = t.menu_icon_size + t.space_sm + max_text + t.space_md;
    content + 2.0 * t.menu_padding_h
}
```

### Viewport clamping

Menus opened near edges must not overflow the window. Clamp the menu origin so `origin.x + width <= viewport_width` and `origin.y + height <= viewport_height`. Flip above the trigger if there's no room below.

### Dismiss behavior

- **Click outside**: `mouse_area` wrapping the menu captures clicks; any click outside the menu bounds sends a dismiss message
- **Hover exit with delay**: start a short timer (~200ms) on `CursorLeft`; cancel if cursor re-enters before the timer fires

### Composition

Use `float` or `stack` + `opaque` to layer the menu above siblings. The menu is an overlay — it must not affect the base layer's widget tree structure (see overlay state isolation rules in SKILL.md).

## Tab bars

Tab bars in title bars (pane_grid or standalone) follow the pick-area geometry rule:

```rust
// Tab row must use Shrink so the remaining space serves as pick area
pane_grid::TitleBar::new(
    row![tab_items].width(Length::Shrink)
)
```

For scrollable tab bars, wrap the tab row in a horizontal `scrollable` with `Shrink` width. The scrollable's max width is bounded by the title bar's available space.

### Active tab indicator

Place the indicator (underline, background highlight) inside the tab builder via conditional styling — not as a separate widget. This keeps the tree shape stable regardless of which tab is active.

```rust
fn tab_item<'a>(label: &str, active: bool, on_press: Message) -> Element<'a, Message> {
    let style = if active { tab_active_style } else { tab_inactive_style };
    button(text(label).size(TOKENS.tab_font_size))
        .padding([TOKENS.space_xs, TOKENS.space_sm])
        .style(style)
        .on_press(on_press)
        .into()
}
```
