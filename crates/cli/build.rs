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
    println!("cargo:rerun-if-env-changed=KENDEX_SOURCE_COMMIT");
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
        text_env("KENDEX_SOURCE_COMMIT")?.as_deref(),
    )
}

/// The version a build displays. The rolling-main pair is CI's identity,
/// ordered by the workflow run number the main feed carries. A source
/// commit alone is a build from a checkout that has no run number, such as
/// an AUR `-git` package: it names its commit under `git.`, which the main
/// channel does not read as one of its builds, so it is judged against
/// releases like the tag it is built between.
pub fn build_version_from_values(
    package_version: &str,
    commit: Option<&str>,
    build: Option<&str>,
    source_commit: Option<&str>,
) -> Result<String, String> {
    let separator = if package_version.contains('+') {
        "."
    } else {
        "+"
    };
    match (commit, build, source_commit) {
        (None, None, None) => Ok(package_version.to_owned()),
        (Some(commit), Some(build), None) => {
            full_commit("KENDEX_GIT_COMMIT", commit)?;
            let build: u64 = build
                .parse()
                .map_err(|_| "KENDEX_MAIN_BUILD must be an unsigned integer".to_owned())?;
            Ok(format!("{package_version}{separator}main.{build}.{commit}"))
        }
        (None, None, Some(commit)) => {
            full_commit("KENDEX_SOURCE_COMMIT", commit)?;
            Ok(format!("{package_version}{separator}git.{commit}"))
        }
        (Some(_), _, Some(_)) | (None, Some(_), Some(_)) => Err(
            "KENDEX_SOURCE_COMMIT cannot be set with KENDEX_GIT_COMMIT or KENDEX_MAIN_BUILD"
                .to_owned(),
        ),
        (Some(_), None, None) | (None, Some(_), None) => {
            Err("KENDEX_GIT_COMMIT and KENDEX_MAIN_BUILD must be set together".to_owned())
        }
    }
}

fn full_commit(name: &str, commit: &str) -> Result<(), String> {
    let valid = commit.len() == 40
        && commit
            .bytes()
            .all(|byte| byte.is_ascii_digit() || (b'a'..=b'f').contains(&byte));
    if valid {
        Ok(())
    } else {
        Err(format!("{name} must be a full lowercase Git commit"))
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
