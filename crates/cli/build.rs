fn main() {
    // The release feed keys its assets by the build target, so the binary
    // carries the triple Cargo built it for instead of guessing from cfg.
    let Ok(target) = std::env::var("TARGET") else {
        println!("cargo:warning=cargo sets TARGET for build scripts; it is missing");
        std::process::exit(1);
    };
    println!("cargo:rustc-env=KENDEX_TARGET={target}");

    println!("cargo:rerun-if-env-changed=KENDEX_GIT_COMMIT");
    println!("cargo:rerun-if-env-changed=KENDEX_MAIN_BUILD");
    let display = match build_version_from_env(env!("CARGO_PKG_VERSION")) {
        Ok(version) => version,
        Err(error) => {
            println!("cargo:warning={error}");
            std::process::exit(1);
        }
    };
    println!("cargo:rustc-env=KENDEX_BUILD_VERSION={display}");
}

pub fn build_version_from_env(package_version: &str) -> Result<String, String> {
    build_version_from_values(
        package_version,
        text_env("KENDEX_GIT_COMMIT")?.as_deref(),
        text_env("KENDEX_MAIN_BUILD")?.as_deref(),
    )
}

pub fn build_version_from_values(
    package_version: &str,
    commit: Option<&str>,
    build: Option<&str>,
) -> Result<String, String> {
    match (commit, build) {
        (None, None) => Ok(package_version.to_owned()),
        (Some(commit), Some(build)) => {
            let valid_commit = commit.len() == 40
                && commit
                    .bytes()
                    .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte));
            if !valid_commit {
                return Err("KENDEX_GIT_COMMIT must be a full lowercase Git commit".to_owned());
            }
            let build: u64 = build
                .parse()
                .map_err(|_| "KENDEX_MAIN_BUILD must be an unsigned integer".to_owned())?;
            let separator = if package_version.contains('+') {
                "."
            } else {
                "+"
            };
            Ok(format!("{package_version}{separator}main.{build}.{commit}"))
        }
        (Some(_), None) | (None, Some(_)) => {
            Err("KENDEX_GIT_COMMIT and KENDEX_MAIN_BUILD must be set together".to_owned())
        }
    }
}

fn text_env(name: &str) -> Result<Option<String>, String> {
    match std::env::var(name) {
        Ok(value) if value.is_empty() => Ok(None),
        Ok(value) => Ok(Some(value)),
        Err(std::env::VarError::NotPresent) => Ok(None),
        Err(std::env::VarError::NotUnicode(_)) => Err(format!("{name} is not text")),
    }
}
