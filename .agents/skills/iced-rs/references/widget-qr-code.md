# QR Code

> `iced::widget::qr_code` · iced 0.14.0 · feature = `qr_code`

Generates and displays a QR code from data. The `Data` struct encodes the content; the `QRCode` widget renders it.

## API

### `QRCode` struct

```rust
pub struct QRCode<'a, Theme = Theme>
where
    Theme: Catalog,
{ /* private fields */ }

impl<'a, Theme> QRCode<'a, Theme>
where
    Theme: Catalog,
{
    pub fn new(data: &'a Data) -> Self;

    pub fn cell_size(self, cell_size: impl Into<Pixels>) -> Self;

    pub fn style(
        self,
        style: impl Fn(&Theme) -> Style + 'a,
    ) -> Self
    where
        <Theme as Catalog>::Class<'a>: From<Box<dyn Fn(&Theme) -> Style + 'a>>;

    pub fn class(
        self,
        class: impl Into<<Theme as Catalog>::Class<'a>>,
    ) -> Self; // feature = "advanced"
}
```

### `Data` struct

```rust
pub struct Data { /* private fields */ }

impl Data {
    pub fn new(data: impl AsRef<[u8]>) -> Result<Data, Error>;

    pub fn with_error_correction(
        data: impl AsRef<[u8]>,
        error_correction: ErrorCorrection,
    ) -> Result<Data, Error>;
}
```

### `ErrorCorrection` enum

```rust
pub enum ErrorCorrection {
    Low,
    Medium,
    Quartile,
    High,
}
```

### `Style` struct

```rust
pub struct Style {
    pub cell: Color,
    pub background: Color,
}
```

### `Catalog` trait

```rust
pub trait Catalog {
    type Class<'a>;
    fn default<'a>() -> Self::Class<'a>;
    fn style(&self, class: &Self::Class<'_>) -> Style;
}
```

### Functions

```rust
pub fn qr_code<'a, Theme>(data: &'a Data) -> QRCode<'a, Theme>
where
    Theme: Catalog + 'a;
```

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
- Construct `Data` once in state, not on every `view()` call. QR encoding is relatively expensive.
- Higher `ErrorCorrection` levels increase resilience but produce denser (larger) codes.

## See also

- `widget-image.md` -- raster image display
- `widget-svg.md` -- vector graphics display
- `catalog.md` -- the `Catalog` trait pattern
- `widgets.md` -- widget catalog
