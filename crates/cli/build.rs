fn main() {
    // The release feed keys its assets by the build target, so the binary
    // carries the triple Cargo built it for instead of guessing from cfg.
    let Ok(target) = std::env::var("TARGET") else {
        println!("cargo:warning=cargo sets TARGET for build scripts; it is missing");
        std::process::exit(1);
    };
    println!("cargo:rustc-env=KENDEX_TARGET={target}");

    println!("cargo:rerun-if-env-changed=KENDEX_GIT_COMMIT");
    let version = env!("CARGO_PKG_VERSION");
    let display = match std::env::var("KENDEX_GIT_COMMIT") {
        Ok(commit)
            if commit.len() == 40
                && commit
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte)) =>
        {
            format!("{version}+main.{commit}")
        }
        Ok(commit) if !commit.is_empty() => {
            println!("cargo:warning=KENDEX_GIT_COMMIT must be a full lowercase Git commit");
            std::process::exit(1);
        }
        Ok(_) | Err(std::env::VarError::NotPresent) => version.to_owned(),
        Err(std::env::VarError::NotUnicode(_)) => {
            println!("cargo:warning=KENDEX_GIT_COMMIT is not text");
            std::process::exit(1);
        }
    };
    println!("cargo:rustc-env=KENDEX_BUILD_VERSION={display}");
}
