fn main() {
    // The release feed keys assets by Cargo's build target. Baking it in
    // avoids guessing the package lane from runtime OS and architecture.
    let Ok(target) = std::env::var("TARGET") else {
        println!("cargo:warning=cargo sets TARGET for build scripts; it is missing");
        std::process::exit(1);
    };
    println!("cargo:rustc-env=KENDEX_TARGET={target}");
    // The tauri context macro requires the frontend dist dir to exist even on
    // a fresh clone that has never built the ui.
    if let Err(e) = std::fs::create_dir_all("../../ui/dist") {
        panic!("cannot create ui/dist: {e}");
    }
    windows_test_binaries_get_the_app_manifest();
    tauri_build::build()
}

/// Tauri calls `TaskDialogIndirect`, which only version 6 of `comctl32.dll`
/// exports. A process reaches version 6 by naming it in an application
/// manifest; without one the loader binds version 5.82 and refuses to start
/// the process at all, with `STATUS_ENTRYPOINT_NOT_FOUND`. `tauri_build`
/// embeds that manifest through `cargo:rustc-link-arg-bins`, which reaches
/// the app binary and no test binary, so every test that links this crate
/// dies before its first assertion. Same dependency, declared to the linker
/// for the targets the resource misses.
fn windows_test_binaries_get_the_app_manifest() {
    let windows = std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("windows");
    let msvc = std::env::var("CARGO_CFG_TARGET_ENV").as_deref() == Ok("msvc");
    if !(windows && msvc) {
        return;
    }
    // The dependency lands in an embedded manifest or nowhere, and asking
    // for the embedding is cheaper than depending on rustc still supplying
    // one of its own.
    println!("cargo:rustc-link-arg-tests=/MANIFEST:EMBED");
    println!(
        "cargo:rustc-link-arg-tests=/MANIFESTDEPENDENCY:type='win32' \
         name='Microsoft.Windows.Common-Controls' version='6.0.0.0' \
         processorArchitecture='*' publicKeyToken='6595b64144ccf1df' language='*'"
    );
}
