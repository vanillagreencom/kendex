## Todos

A todos tracker inspired by [TodoMVC]. It showcases dynamic layout, text input, checkboxes, scrollables, icons, and async actions! It automatically saves your tasks in the background, even if you did not finish typing them.

All the example code is located in the __[`main`]__ file.

<div align="center">
  <a href="https://iced.rs/examples/todos.mp4">
    <img src="https://iced.rs/examples/todos.gif">
  </a>
</div>

These sources are a read-only copy. To run it, clone the upstream workspace at the release (`git clone --branch 0.14.0 https://github.com/iced-rs/iced`) and, from its root:
```
cargo run --package todos
```

The web version can be run with [`trunk`]:

```
cd examples/todos
trunk serve
```

[`main`]: src/main.rs
[TodoMVC]: http://todomvc.com/
[`trunk`]: https://trunkrs.dev/
