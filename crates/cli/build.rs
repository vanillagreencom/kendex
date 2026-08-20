fn main() {
    // The release feed keys its assets by the build target, so the binary
    // carries the triple Cargo built it for instead of guessing from cfg.
    let Ok(target) = std::env::var("TARGET") else {
        println!("cargo:warning=cargo sets TARGET for build scripts; it is missing");
        std::process::exit(1);
    };
    println!("cargo:rustc-env=KENDEX_TARGET={target}");
}
