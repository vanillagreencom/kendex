use std::path::Path;

use specta_typescript::Typescript;

fn exporter() -> Typescript {
    Typescript::default().header("// @ts-nocheck")
}

fn committed_path() -> &'static Path {
    Path::new(concat!(
        env!("CARGO_MANIFEST_DIR"),
        "/../../ui/src/bindings.ts"
    ))
}

/// `cargo test` fails whenever the committed bindings drift from the command
/// surface. Regenerate with:
/// `cargo test -p kendex-app -- --ignored regenerate_bindings`
#[test]
fn committed_bindings_are_current() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let fresh_path = tmp.path().join("bindings.ts");
    kendex_app::specta_builder()
        .export(exporter(), &fresh_path)
        .expect("bindings export");
    let fresh = std::fs::read_to_string(&fresh_path).expect("fresh bindings readable");
    let committed = std::fs::read_to_string(committed_path()).unwrap_or_default();
    assert_eq!(
        committed, fresh,
        "ui/src/bindings.ts is stale — run: cargo test -p kendex-app -- --ignored regenerate_bindings"
    );
}

/// Guards the window commands' wiring into `collect_commands!` — a command
/// defined but never registered would pass compilation and only show up
/// missing here.
#[test]
fn bindings_export_window_commands() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let fresh_path = tmp.path().join("bindings.ts");
    kendex_app::specta_builder()
        .export(exporter(), &fresh_path)
        .expect("bindings export");
    let fresh = std::fs::read_to_string(&fresh_path).expect("fresh bindings readable");
    for command in [
        "window_set_zoom",
        "window_launch_zoom",
        "window_minimize",
        "window_toggle_maximize",
        "window_close",
        "open_in_editor",
    ] {
        assert!(
            fresh.contains(command),
            "expected generated bindings to export `{command}`"
        );
    }
}

/// The slider reads its floor, ceiling, and step from the generated
/// constant, so dropping the constant would leave the UI inventing its own.
#[test]
fn bindings_export_the_zoom_range() {
    let tmp = tempfile::tempdir().expect("tempdir");
    let fresh_path = tmp.path().join("bindings.ts");
    kendex_app::specta_builder()
        .export(exporter(), &fresh_path)
        .expect("bindings export");
    let fresh = std::fs::read_to_string(&fresh_path).expect("fresh bindings readable");
    assert!(
        fresh.contains("export const ZOOM"),
        "expected generated bindings to export the zoom range"
    );
}

#[test]
#[ignore = "writes ui/src/bindings.ts in place"]
fn regenerate_bindings() {
    kendex_app::specta_builder()
        .export(exporter(), committed_path())
        .expect("bindings export");
}
