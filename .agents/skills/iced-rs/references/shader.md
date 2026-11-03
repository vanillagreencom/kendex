# Shader

Read when a custom GPU pipeline is needed in iced 0.14.0. The pinned [Shader widget](https://github.com/iced-rs/iced/blob/0.14.0/widget/src/shader.rs) and [Program contract](https://github.com/iced-rs/iced/blob/0.14.0/widget/src/shader/program.rs) own the API. The widget requires the `wgpu` feature and a renderer implementing the primitive-rendering contract. Check [surface selection](guide-surface-selection.md) before choosing it over Canvas or ordinary widgets.

## Program

Keep transient widget state in `Program::State`. `update` can return an action that publishes a message, requests redraw or captures the event. `draw` produces a primitive from the current state, bounds and cursor. It does not directly issue GPU commands.

The [bundled Scene](../examples/custom_shader/src/scene.rs) demonstrates the separation:

```rust
impl<Message> shader::Program<Message> for Scene {
    type State = ();
    type Primitive = Primitive;

    fn draw(
        &self,
        _state: &Self::State,
        _cursor: mouse::Cursor,
        bounds: Rectangle,
    ) -> Self::Primitive {
        Primitive::new(
            &self.cubes,
            &self.camera,
            bounds,
            self.show_depth_buffer,
            self.light_color,
        )
    }
}
```

Read that module's imports and primitive implementation with this excerpt. Its [pipeline](../examples/custom_shader/src/scene/pipeline.rs) supplies resource creation and rendering. `mouse_interaction` can affect the cursor outside the shader's bounds; check the cursor against bounds when that is not intended.

## GPU resources

The bundled [Primitive and Pipeline contracts](../iced_wgpu/src/primitive.rs) define resource creation, preparation and rendering. `Pipeline::new` creates reusable GPU resources. `Primitive::prepare` updates them for an instance and receives its logical bounds and viewport. Keep expensive resource work out of repeated preparation where the pipeline can retain it; measure the consuming workload before claiming a performance result.

Implement `Primitive::draw` to reuse the supplied render pass when it suits the composition. Return `true` after drawing. Returning `false` selects `render`, which receives an encoder, target and physical clip bounds. The existing pass has its viewport/scissor set for the primitive. The [renderer](../iced_wgpu/src/lib.rs) owns pass transitions; do not assume the fallback creates a new encoder or target.

Renderer storage shares one pipeline per primitive type. Different primitive types receive separate entries even if they name the same pipeline type. Ordinary shader programs let the renderer manage that storage. `Storage::trim` calls each pipeline's trim method; it does not evict the pipeline entries. Release a pipeline's unused cached resources in its own trim implementation when needed.

[`Viewport`](https://github.com/iced-rs/iced/blob/0.14.0/graphics/src/viewport.rs) exposes both logical and physical sizes plus the scale factor. Convert the quantities your GPU data needs explicitly. Do not treat every viewport quantity as logical pixels.

Check clipping, scaling, composition, resource lifetime and backend availability in the target. No local shader build, GPU output or performance measurement is established by this reference.

See [Canvas](canvas.md) and [renderer primitives](advanced-renderer.md).
