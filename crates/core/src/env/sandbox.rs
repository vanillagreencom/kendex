//! The rule that keeps a build off the machine its author uses. A debug
//! build is one an agent or a contributor made from a branch, so it is the
//! one that writes lock records, harness files and caches the installed app
//! cannot read. Everything such a build owns is named here: the home its
//! roots hang off, the process vars it refuses to inherit, and the
//! credential separation [`crate::registry::credentials`] draws from it.

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};

/// The home a debug build gets instead of the real one, under the platform
/// data dir.
const DEV_HOME_DIR: &str = "kendex-dev";

/// Opts a debug build back onto the real home, for deliberate dogfooding.
const REAL_HOME_VAR: &str = "KENDEX_REAL_HOME";

/// The one value that opts out. Anything else — `0`, `false`, a typo —
/// leaves the sandbox on: this hatch permits writes to a real machine, so
/// a value nobody can read as consent must not spend it.
const REAL_HOME_OPT_IN: &str = "1";

/// The subset of [`super::HARNESS_VARS`] naming a harness root a build would write
/// into. A sandboxed build drops these and keeps the rest: an inherited
/// CODEX_HOME would aim it straight back at the real machine, while
/// KENDEX_GIT_BASE names a git host and
/// `GEMINI_CLI_SYSTEM_SETTINGS_PATH` a read-only policy file — dropping
/// those two would not protect the machine, it would send the build to the
/// real git host and the real machine-wide settings instead.
const HOME_RELOCATING_VARS: [&str; 5] = [
    "CODEX_HOME",
    "OPENCODE_CONFIG",
    "OPENCODE_CONFIG_DIR",
    "PI_CODING_AGENT_DIR",
    "COPILOT_HOME",
];

/// The value of the opt-out as this process was launched with it.
pub(super) fn real_home_opt_in() -> Option<String> {
    std::env::var(REAL_HOME_VAR).ok()
}

/// The home a build gets when it must not touch the real machine.
pub(super) fn dev_home(
    debug_build: bool,
    real_home_opt_in: Option<&str>,
    data_dir: &Path,
) -> Option<PathBuf> {
    match is_sandboxed(debug_build, real_home_opt_in) {
        true => Some(data_dir.join(DEV_HOME_DIR)),
        false => None,
    }
}

fn is_sandboxed(debug_build: bool, real_home_opt_in: Option<&str>) -> bool {
    debug_build && real_home_opt_in != Some(REAL_HOME_OPT_IN)
}

/// Whether this build is the one kept away from the real machine. The
/// filesystem roots are not all a build owns: the OS credential store is
/// keyed by name rather than by path, so it cannot be relocated by pointing
/// at another home and asks here instead.
pub fn sandboxed() -> bool {
    is_sandboxed(cfg!(debug_assertions), real_home_opt_in().as_deref())
}

/// What a sandboxed build carries over from the process it was launched in.
pub(super) fn sandbox_vars(vars: BTreeMap<String, String>) -> BTreeMap<String, String> {
    vars.into_iter()
        .filter(|(key, _)| !HOME_RELOCATING_VARS.contains(&key.as_str()))
        .collect()
}

#[cfg(test)]
mod tests {
    use super::super::HARNESS_VARS;
    use super::*;

    const DATA: &str = "/data";

    #[test]
    fn a_debug_build_gets_its_own_home() {
        assert_eq!(
            dev_home(true, None, Path::new(DATA)),
            Some(PathBuf::from("/data/kendex-dev"))
        );
    }

    #[test]
    fn a_release_build_gets_the_real_home() {
        assert_eq!(dev_home(false, None, Path::new(DATA)), None);
    }

    #[test]
    fn a_debug_build_asked_for_the_real_home_gets_it() {
        assert_eq!(dev_home(true, Some("1"), Path::new(DATA)), None);
    }

    /// The hatch permits writes to a real machine, so only the documented
    /// value spends it — a `0` or a typo reads as nobody's consent.
    #[test]
    fn only_the_documented_value_opts_out() {
        for value in ["", "0", "false", "no", "2", "1 ", "true", "TRUE", "yes"] {
            assert_eq!(
                dev_home(true, Some(value), Path::new(DATA)),
                Some(PathBuf::from("/data/kendex-dev")),
                "{value:?} opted out of the sandbox"
            );
            assert_eq!(dev_home(false, Some(value), Path::new(DATA)), None);
        }
    }

    /// A git base names a host and the Gemini override a read-only policy
    /// file, so a sandboxed build still reaches the fixture tree and the
    /// fixture settings its launcher pointed it at — dropping either would
    /// send it to the real ones.
    #[test]
    fn a_sandbox_keeps_what_does_not_point_at_a_home() {
        let vars = BTreeMap::from([
            ("KENDEX_GIT_BASE".to_owned(), "file:///fixtures".to_owned()),
            (
                "GEMINI_CLI_SYSTEM_SETTINGS_PATH".to_owned(),
                "/fixtures/gemini.json".to_owned(),
            ),
            ("CODEX_HOME".to_owned(), "/home/real/.codex".to_owned()),
            ("COPILOT_HOME".to_owned(), "/home/real/.copilot".to_owned()),
        ]);
        let kept = sandbox_vars(vars);
        assert_eq!(
            kept.get("KENDEX_GIT_BASE").map(String::as_str),
            Some("file:///fixtures")
        );
        assert_eq!(
            kept.get("GEMINI_CLI_SYSTEM_SETTINGS_PATH")
                .map(String::as_str),
            Some("/fixtures/gemini.json")
        );
        assert!(!kept.contains_key("CODEX_HOME"));
        assert!(!kept.contains_key("COPILOT_HOME"));
    }

    /// Every relocating var is a harness var: a name in one list and not the
    /// other would be read from the process and never dropped.
    #[test]
    fn every_relocating_var_is_a_harness_var() {
        for key in HOME_RELOCATING_VARS {
            assert!(HARNESS_VARS.contains(&key), "{key} is not a harness var");
        }
    }
}
