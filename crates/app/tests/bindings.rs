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

/// The bindings `specta_builder` emits right now, written somewhere the test
/// can read them without touching the committed file.
#[allow(
    clippy::expect_used,
    reason = "an export or a read that fails is the test's own fixture, and the panic names which"
)]
fn generated() -> String {
    let tmp = tempfile::tempdir().expect("tempdir");
    let fresh_path = tmp.path().join("bindings.ts");
    kendex_app::specta_builder()
        .export(exporter(), &fresh_path)
        .expect("bindings export");
    std::fs::read_to_string(&fresh_path).expect("fresh bindings readable")
}

/// `cargo test` fails whenever the committed bindings drift from the command
/// surface. Regenerate with:
/// `cargo test -p kendex-app -- --ignored regenerate_bindings`
#[test]
fn committed_bindings_are_current() {
    let committed = std::fs::read_to_string(committed_path()).unwrap_or_default();
    assert_eq!(
        committed,
        generated(),
        "ui/src/bindings.ts is stale — run: cargo test -p kendex-app -- --ignored regenerate_bindings"
    );
}

/// Guards the window commands' wiring into `collect_commands!` — a command
/// defined but never registered would pass compilation and only show up
/// missing here.
#[test]
fn bindings_export_window_commands() {
    let fresh = generated();
    for command in [
        "window_set_zoom",
        "window_zoom_state",
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
    let fresh = generated();
    assert!(
        fresh.contains("export const ZOOM"),
        "expected generated bindings to export the zoom range"
    );
}

/// The `commands` object, from its opening line to the line that closes it.
#[allow(
    clippy::expect_used,
    reason = "a generated file without a commands object is a reader that stopped matching it, and the panic says so"
)]
fn commands_block(bindings: &str) -> &str {
    let start = bindings
        .find("export const commands = {")
        .expect("generated bindings declare a commands object");
    let rest = &bindings[start..];
    let end = rest.find("\n}\n").expect("the commands object closes");
    &rest[..end]
}

/// Every command the bindings invoke, paired with whether the `typedError`
/// fold stands between the bridge and the caller. Read off the generated
/// file rather than off a list here: an entry reads `=> typedError<…>(
/// __TAURI_INVOKE…)` where the fold applies and `=> __TAURI_INVOKE…` where it
/// does not, and the command's own name is the invocation's first argument
/// either way.
#[allow(
    clippy::expect_used,
    reason = "an invocation that does not match this shape is a reader that stopped matching it, and the panic says so"
)]
fn invoked_commands(bindings: &str) -> Vec<(String, bool)> {
    const INVOKE: &str = "__TAURI_INVOKE";
    let block = commands_block(bindings);
    let mut found = Vec::new();
    let mut at = 0;
    while let Some(offset) = block[at..].find(INVOKE) {
        let call = at + offset;
        let arrow = block[..call]
            .rfind("=>")
            .expect("every command entry is an arrow function");
        let folded = block[arrow..call].contains("typedError");
        let opened = call
            + block[call..]
                .find("(\"")
                .expect("the invocation names its command")
            + 2;
        let closed = opened
            + block[opened..]
                .find('"')
                .expect("the command name is quoted");
        found.push((block[opened..closed].to_owned(), folded));
        at = closed;
    }
    found
}

/// The commands whose rejection reaches their caller unfolded. Each one
/// needs a caller that catches: `deep_link_take` is read through `caught` in
/// `ui/src/lib/deep-link.ts`.
const OUTSIDE_THE_FOLD: [&str; 1] = ["deep_link_take"];

/// tauri-specta wraps a command only where its `Result` gives it a refusal
/// type to name, so a plain-value command added later regenerates clean and
/// `committed_bindings_are_current` stays green while its rejection escapes
/// its caller. Joining the fold is a return type; leaving it is an edit here.
#[test]
fn only_the_pinned_commands_bypass_the_transport_fold() {
    let fresh = generated();
    let invoked = invoked_commands(&fresh);
    assert!(
        invoked.len() > 50,
        "the reader found {} commands in the generated bindings — it is what \
         broke, not the command surface that thinned",
        invoked.len()
    );
    let outside: Vec<&str> = invoked
        .iter()
        .filter(|(_, folded)| !folded)
        .map(|(name, _)| name.as_str())
        .collect();
    assert_eq!(
        outside, OUTSIDE_THE_FOLD,
        "a command outside the transport fold rejects to its caller unfolded — \
         return `Result` from it, or add it to OUTSIDE_THE_FOLD and give it a \
         caller that catches"
    );
}

#[test]
#[ignore = "writes ui/src/bindings.ts in place"]
fn regenerate_bindings() {
    kendex_app::specta_builder()
        .export(exporter(), committed_path())
        .expect("bindings export");
}
