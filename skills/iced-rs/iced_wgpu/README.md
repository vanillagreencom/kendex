# Iced’s wgpu renderer

Read the bundled renderer source when developing a custom Iced 0.14 shader or tracing how Iced draws a primitive.

## How it works

This directory copies the [Iced 0.14.0 renderer](https://github.com/iced-rs/iced/tree/3997291f318a8bc06fa522f5579836fb3feb94df/wgpu). Iced’s default features include the wgpu renderer and the tiny-skia software fallback. The [Iced manifest](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/Cargo.toml) declares the renderer features. Use the [shader reference](../references/shader.md) for the role of each drawing stage.

## Licence

[MIT, Iced contributors](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/LICENSE)
