# Theme palettes

Read when selecting theme colors or deriving widget appearances in iced 0.14.0. The pinned [palette source](https://github.com/iced-rs/iced/blob/0.14.0/core/src/theme/palette.rs) owns seed fields, built-in constants, generated tiers and contrast helpers. Follow the skill's [token policy](../SKILL.md#theming-no-custom-theme-type-for-tokens) for application design values.

## Seed and derived colors

`Palette` supplies the background/text pair and primary, success, warning and danger seeds. `Extended::generate` derives background and accent groups from those inputs. Use `theme.extended_palette()` to borrow those groups when styling a widget.

A `Pair` keeps a surface color with its corresponding text color. Use them together rather than moving the text color onto an unrelated surface:

```rust
let palette = theme.extended_palette();
let surface = palette.background.weak;
let background_color = surface.color;
let text_color = surface.text;
```

Background has more variation levels than the accent groups. Look up the group declaration before selecting a level; do not assume every group has the same fields or generator parameters. In particular, Secondary derives from background/text, while Primary and the semantic accents also take their own base color.

## Customization

Start from a complete seed and change the roles the application needs:

```rust
use iced::theme::Palette;
use iced::{Color, Theme};

let seed = Palette {
    primary: Color::from_rgb(0.42, 0.69, 1.0),
    ..Theme::Dark.palette()
};
let custom = Theme::custom_with_fn(
    "Midnight",
    seed,
    iced::theme::palette::Extended::generate,
);
```

For specific derived overrides, the generator can first create an `Extended`, change its public fields, then return it. Keep the foreground/background relationship intact; `Pair::new` applies the source's readability adjustment. Use the current seed background when deriving an accent rather than mixing it with a stale background.

`is_dark` classifies the seed background through the implementation's lightness calculation. Treat it as a theme-selection hint, not a guarantee about every color pair or icon. The source uses Oklch for lightness adjustments; its formulas and constants stay at that owner.

Inspect actual contrast, disabled/hovered states and icons at the target scale. Generated pairs and source declarations do not establish a rendered accessibility result.

See [themes](theme.md), [catalogs](catalog.md) and [renderer primitives](advanced-renderer.md).
