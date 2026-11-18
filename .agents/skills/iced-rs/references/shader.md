# Shader

> `iced::widget::shader` · iced 0.14.0

Custom GPU pipeline widget. Implement `shader::Program<Message>` to produce a `Primitive`, then implement `shader::Primitive` to prepare and render in a wgpu render pass. Enable `wgpu`. Use for 3D rendering, particle systems, or GPU-based data visualization.

Read when implementing a Shader widget or its GPU pipeline.

## API

Read the [Iced 0.14.0 declarations](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/shader.rs) for the widget. The [program contract](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/widget/src/shader/program.rs) and [primitive/pipeline contracts](https://github.com/iced-rs/iced/blob/3997291f318a8bc06fa522f5579836fb3feb94df/wgpu/src/primitive.rs) own the rendering signatures.

## Patterns

### Minimal shader program skeleton

```rust
use iced::widget::shader;
use iced::{Rectangle, mouse::Cursor, wgpu};

#[derive(Debug)]
struct MyProgram;

impl shader::Program<Message> for MyProgram {
    type State = ();
    type Primitive = MyPrimitive;

    fn draw(
        &self,
        _state: &Self::State,
        _cursor: Cursor,
        bounds: Rectangle,
    ) -> MyPrimitive {
        MyPrimitive { bounds }
    }
}

#[derive(Debug)]
struct MyPrimitive {
    bounds: Rectangle,
}

impl shader::Primitive for MyPrimitive {
    type Pipeline = MyPipeline;

    fn prepare(
        &self,
        pipeline: &mut Self::Pipeline,
        device: &wgpu::Device,
        queue: &wgpu::Queue,
        bounds: &Rectangle,
        viewport: &shader::Viewport,
    ) {
        pipeline.upload_uniforms(queue, bounds);
    }

    fn draw(
        &self,
        pipeline: &Self::Pipeline,
        render_pass: &mut wgpu::RenderPass<'_>,
    ) -> bool {
        pipeline.render_in_pass(render_pass);
        true
    }
}
```

### Pipeline lifecycle

Implement `shader::Pipeline::new(device, queue, format)` for `MyPipeline`. Iced creates the pipeline when it first encounters `MyPrimitive`, stores it under that primitive type, and shares it across instances of that type. `prepare` receives the stored pipeline for uploads; `draw` or `render` uses it to draw. See the bundled `examples/custom_shader/src/scene.rs` for a complete implementation.

## Gotchas

- Use Shader with a wgpu-backed renderer. The software fallback does not draw shader primitives.
- `Primitive::draw` returns `bool`. Return `true` if you've done the drawing inside the supplied render pass. Return `false` for a custom composition path through `render()`, which receives the existing encoder, target and physical clip bounds. The upstream contract recommends reusing the supplied render pass when possible.
- Use `Pipeline::new` for initialization and `prepare` for per-instance GPU buffer uploads. Both receive the device and queue. Keep repeated preparation work small.
- `Pipeline` objects live as long as the shared `Storage`. `Storage::trim()` asks each pipeline to trim its own caches; it does not remove pipeline entries.
- `Primitive` types are compared by `TypeId` for pipeline sharing — two different primitive structs cannot share a pipeline even if their behaviour is identical.
- Follow iced's coordinate conventions: `prepare` receives logical bounds and a `Viewport` exposing both logical and physical dimensions. Use its scale factor when converting logical geometry to physical pixel data.
- The iced repository's `custom_shader` example is the canonical full reference.

## See also

- `canvas.md`
- `advanced-renderer.md`
- `guide-surface-selection.md`
