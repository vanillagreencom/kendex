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
    tauri_build::build()
}
