# QR Code

> `iced::widget::qr_code` · iced 0.14.0 · feature = `qr_code`

Generates and displays a QR code from data. The `Data` struct encodes the content; the `QRCode` widget renders it.

## API

Iced 0.14.0 owns the declarations, bounds, feature gates and defaults: [widget/src/qr_code.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/qr_code.rs); [widget/src/helpers.rs](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/helpers.rs).

## Patterns

### Basic QR code

```rust
use iced::widget::qr_code;

struct State {
    data: qr_code::Data,
}

impl State {
    fn new() -> Self {
        Self {
            data: qr_code::Data::new("https://example.com").unwrap(),
        }
    }

    fn view(&self) -> Element<'_, Message> {
        qr_code(&self.data).into()
    }
}
```

### With error correction

```rust
let data = qr_code::Data::with_error_correction(
    "https://example.com",
    qr_code::ErrorCorrection::High,
).unwrap();
```

### Custom colors

```rust
qr_code(&state.data)
    .style(|_theme| qr_code::Style {
        cell: Color::from_rgb(0.0, 0.0, 0.5),
        background: Color::WHITE,
    })
```

## Gotchas

- Requires the `qr_code` crate feature.
- `Data::new()` returns `Result` -- it can fail if the input is too long for QR encoding.
- Construct `Data` once in state, not on every `view()` call.
- Higher error correction levels allow more damaged data to be recovered. Choose the level when constructing `Data`.

## See also

- `widget-image.md` -- raster image display
- `widget-svg.md` -- vector graphics display
- `catalog.md` -- the `Catalog` trait pattern
- `widgets.md` -- widget catalog
