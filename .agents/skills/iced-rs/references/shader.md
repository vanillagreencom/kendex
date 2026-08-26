# Shader

> `iced::widget::shader` · iced 0.14.0

Custom GPU pipeline widget. Implement `shader::Program<Message>` to produce a `Primitive`, then implement `shader::Primitive` to prepare and render in a wgpu render pass. Requires the `wgpu` feature. Use for 3D rendering, particle systems, or GPU-based data visualization.

## API

### `Shader` struct

```rust
pub struct Shader<'a, Message, P: Program<Message>> { /* ... */ }

impl<'a, Message, P: Program<Message>> Shader<'a, Message, P> {
    pub fn new(program: P) -> Self;
    pub fn width(self, width: impl Into<Length>) -> Self;
    pub fn height(self, height: impl Into<Length>) -> Self;
}
```

### `Program` trait

```rust
pub trait Program<Message> {
    type State: Default + 'static;
    type Primitive: Primitive + 'static;

    // Required
    fn draw(
        &self,
        state: &Self::State,
        cursor: Cursor,
        bounds: Rectangle,
    ) -> Self::Primitive;

    // Provided
    fn update(
        &self,
        _state: &mut Self::State,
        _event: &Event,
        _bounds: Rectangle,
        _cursor: Cursor,
    ) -> Option<Action<Message>> { ... }

    fn mouse_interaction(
        &self,
        _state: &Self::State,
        _bounds: Rectangle,
        _cursor: Cursor,
    ) -> Interaction { ... }
}
```

### `Primitive` trait

```rust
pub trait Primitive:
    Debug
    + MaybeSend
    + MaybeSync
    + 'static
{
    type Pipeline: Pipeline + MaybeSend + MaybeSync;

    // Required
    fn prepare(
        &self,
        pipeline: &mut Self::Pipeline,
        device: &Device,
        queue: &Queue,
        bounds: &Rectangle,
        viewport: &Viewport,
    );

    // Provided
    fn draw(
        &self,
        _pipeline: &Self::Pipeline,
        _render_pass: &mut RenderPass<'_>,
    ) -> bool { ... }

    fn render(
        &self,
        _pipeline: &Self::Pipeline,
        _encoder: &mut CommandEncoder,
        _target: &TextureView,
        _clip_bounds: &Rectangle<u32>,
    ) { ... }
}
```

### `Storage`

```rust
pub struct Storage { /* private */ }

impl Storage {
    pub fn has<T>(&self) -> bool;
    pub fn store<T, P>(&mut self, pipeline: P)
    where
        P: Pipeline;
    pub fn get<T>(&self) -> Option<&(dyn Any + 'static)>;
    pub fn get_mut<T>(&mut self) -> Option<&mut (dyn Any + 'static)>;
    pub fn trim(&mut self);
}
```

Type-keyed storage for pipelines (`wgpu` feature only).

## Patterns

### Minimal shader program skeleton

```rust
use iced::widget::shader;
use iced::{Rectangle, mouse::Cursor};

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

### Pipeline lifecycle via `Storage`

1. First frame: `storage.has::<MyPipeline>()` -- if false, build and `storage.store(pipeline)`.
2. Every frame: `storage.get_mut::<MyPipeline>()` to update buffers and render.

## Gotchas

- The `wgpu` feature is required, and `Shader` is only meaningful in
  renderers that speak `wgpu` (e.g. `iced_wgpu`). Software backends
  ignore it.
- `Primitive::draw` returns `bool`. Return `true` if you've done the
  drawing inside the supplied render pass. Return `false` if you couldn't
  and want iced to invoke `render()` with a fresh encoder — that path is
  slower because it needs its own command encoder and render target.
- `prepare()` is called every frame and is the only place where you can
  touch the `Device` / `Queue` (for uploading buffers). It must be fast
  and must not do heavy GPU work.
- `Pipeline` objects live as long as the shared `Storage`. If you store
  too many pipelines, call `Storage::trim()` to drop unused ones.
- `Primitive` types are compared by `TypeId` for pipeline sharing — two
  different primitive structs cannot share a pipeline even if their
  behaviour is identical.
- Follow iced's coordinate conventions: the `bounds` and `viewport`
  passed to `prepare` are in logical pixels; multiply by the viewport's
  scale factor when uploading physical pixel data.
- The iced repository's `custom_shader` example is the canonical full reference.

## See also

- `canvas.md`
- `advanced-renderer.md`
- `guide-surface-selection.md`
