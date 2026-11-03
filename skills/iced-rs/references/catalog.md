# Widget catalogs

Read when overriding or implementing widget styling in Iced 0.14.0. Each widget owns its catalog contract. The pinned [button](https://github.com/iced-rs/iced/blob/0.14.0/widget/src/button.rs) and [container](https://github.com/iced-rs/iced/blob/0.14.0/widget/src/container.rs) declarations show two different forms; do not assume one universal signature.

## Classes and styles

A class is the style selector stored by the widget. A style is the resulting appearance. The catalog's `default` method chooses the initial class; it is distinct from `Style::default`.

Button styling uses the theme, class and interaction status. Container styling uses the theme and class without a status argument. Read the target widget before adding fields, status parameters or state transitions to its implementation.

Built-in theme catalogs commonly use a boxed style closure. An enum class can serve a fixed set of variants. The button source includes that example. If callers also need `.style(closure)`, satisfy the setter's actual conversion bound; an enum alone does not provide that conversion. A `.class(...)` call selects the stored class directly.

## Overrides

Start from the widget's existing style function when changing only a few fields. Preserve its status handling and override the affected appearance fields. `Style::default` supplies a plain appearance value and may differ from the theme's default class.

```rust
button("Click me")
    .on_press(Message::Clicked)
    .style(|theme, status| match status {
        button::Status::Hovered => button::Style {
            background: Some(theme.extended_palette().primary.strong.color.into()),
            ..button::primary(theme, status)
        },
        _ => button::primary(theme, status),
    })
```

The class lifetime allows a closure to borrow data that outlives the returned element. It cannot make view-local temporaries live longer. Widgets remain generic over the applicable catalog; these lifetime-parameterized class traits are not trait-object APIs.

For a custom widget, define the appearance and status it actually needs, initialize its class through the catalog and resolve the appearance while drawing. If status carries extra state, keep it in that status value instead of adding a parallel styling parameter. `theme.md` and `theme-palette.md` own this package's theme/token guidance.

## Related references

- `widget-button.md`
- `widget-container.md`
- `theme.md`
- `theme-palette.md`
