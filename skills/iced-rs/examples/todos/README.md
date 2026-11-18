# Todos

Manage a task list with a changing layout, text inputs, checkboxes, scrolling, and icons. The app saves tasks and text in the new task field in the background.

[![A task list with filters and a new task field](https://iced.rs/examples/todos.gif)](https://iced.rs/examples/todos.mp4)

The app uses [TodoMVC](https://todomvc.com/) as its model for the list and filters. The desktop app saves to a JSON file. The browser version uses local storage.

Read the [example source](src/main.rs).

## Run

Run from the root of the [Iced 0.14.0 workspace](../README.md#install).

```sh
cargo run --package todos
```

## Web

With [Trunk](https://trunk-rs.github.io/trunk/guide/) installed, run from the upstream workspace root.

```sh
cd examples/todos
trunk serve
```
