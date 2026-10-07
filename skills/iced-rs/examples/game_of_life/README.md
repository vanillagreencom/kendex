## Game of Life

An interactive version of the [Game of Life], invented by [John Horton Conway].

It runs a simulation in a background thread while allowing interaction with a `Canvas` that displays an infinite grid with zooming, panning, and drawing support.

The __[`main`]__ file contains the relevant code of the example.

<div align="center">
  <img src="https://iced.rs/examples/game_of_life.gif">
</div>

These sources are a read-only copy. To run it, clone the upstream workspace at the release (`git clone --branch 0.14.0 https://github.com/iced-rs/iced`) and, from its root:
```
cargo run --package game_of_life
```

[`main`]: src/main.rs
[Game of Life]: https://en.wikipedia.org/wiki/Conway%27s_Game_of_Life
[John Horton Conway]: https://en.wikipedia.org/wiki/John_Horton_Conway
