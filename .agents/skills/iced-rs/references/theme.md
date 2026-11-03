# Theme

Read when selecting or constructing application themes in iced 0.14.0. The pinned [Theme declaration](https://github.com/iced-rs/iced/blob/0.14.0/core/src/theme.rs) owns built-in variants, custom storage and constructors. Preserve the skill's [token and custom-Theme rules](../SKILL.md#theming-no-custom-theme-type-for-tokens).

## Selection

Supply the application's theme callback from state. For a simple mode switch:

```rust
use iced::Theme;

fn theme(state: &State) -> Theme {
    if state.dark_mode {
        Theme::Dark
    } else {
        Theme::Light
    }
}
```

Register that callback with the [application builder](application.md). The [styling example](../examples/styling/src/main.rs) demonstrates selection across built-in themes. `Theme::ALL` contains built-ins; maintain an application-owned list when a picker also offers custom themes.

Do not confuse selecting an application theme with observing the system preference. [System](system.md) provides preference requests and changes; the application's callback decides what appearance to return.

## Construction and lookup

`Theme::custom` creates a theme from a name and base palette, using the standard extended generator. `custom_with_fn` accepts a one-time generator for precise derived colors. The custom theme retains its base and generated palette in shared storage; the generator does not run on every lookup.

```rust
use iced::theme::{palette::Extended, Palette};
use iced::{Color, Theme};

let seed = Palette {
    primary: Color::from_rgb(0.4, 0.7, 1.0),
    ..Theme::Dark.palette()
};
let theme = Theme::custom_with_fn("Midnight", seed, Extended::generate);
```

Use `palette()` when the base seeds are needed and `extended_palette()` for borrowed derived colors and text/surface pairs. [Palette guidance](theme-palette.md) owns those relationships. [Catalogs](catalog.md) own per-widget style/class contracts; a custom application theme does not make every widget use the same styling signature.

Keep custom theme choices and light/dark relationships in application state. Check rendered contrast and widget states in the consuming app; source construction alone proves no native appearance or font result.

See [widget-local themes](widget-themer.md).
