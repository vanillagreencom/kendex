//! The desktop's half of a package's repository effects: the command that
//! runs an effect once the window has a yes.
//!
//! An install is one command that plans and writes. The effect is not in
//! it: the report's declarations become the offers the window shows, and
//! the window comes back here with the one it got a yes for. Nothing
//! between those two calls is written down, so the yes is good for that
//! run and no other — a refresh repairs files and arms nothing, the same
//! as the terminal.

use kendex_core::env::Env;
use kendex_core::model::Scope;
use kendex_core::repo_effects::{ArmError, DeclaredEffects};

/// What an installer said, kept by channel.
///
/// Both of them, on a clean exit as much as a failed one. growth-guards
/// exits 0 when `core.hooksPath` is configured and puts its summary on
/// stdout and the warning, the value it found, and the remedy on stderr —
/// so stdout alone is the half of the account that does not say what to do.
#[derive(Debug, Clone, serde::Serialize, specta::Type)]
#[serde(rename_all = "camelCase")]
pub struct Said {
    pub stdout: Vec<String>,
    pub stderr: Vec<String>,
}

/// Run one package's declared installer, here and now, and hand back what
/// it printed: an installer that deliberately arms nothing says so and
/// exits 0, and the window shows its words rather than a verdict of its
/// own.
///
/// The declaration comes back from the window exactly as the install handed
/// it over, the way the terminal keeps it in hand between the block and the
/// prompt — but the root it names is checked against what this scope
/// recorded installing, not taken on trust. Arming confines the program to
/// the root it is given, so a root the caller chose is a check against the
/// caller's own answer: `/` passes it with any program underneath. The
/// terminal has no such gap, because its declaration never leaves the
/// process that built it.
///
/// The rest of the declaration is used as passed. It decides what runs
/// under a root kendex chose, which is the same ground the disclosure was
/// written on.
pub fn apply(env: &Env, scope: &Scope, declared: &DeclaredEffects) -> Result<Said, String> {
    let recorded = kendex_core::repo_effects::recorded_roots(env, scope, &declared.name)
        .map_err(|error| error.to_string())?;
    if !recorded.contains(&declared.root) {
        return Err(format!(
            "{}: nothing was run — this scope has no record of installing it there",
            kendex_core::names::shown(&declared.name)
        ));
    }
    match kendex_core::repo_effects::arm(scope, declared) {
        Ok(report) => Ok(Said {
            stdout: report.stdout,
            stderr: report.stderr,
        }),
        // The one wording, with the package's own lines under it where the
        // installer got far enough to say anything — the account of a
        // possibly half-written repository has to reach the person whole.
        Err(error) => {
            let said: Vec<&str> = match &error {
                ArmError::Failed { report, .. } => report
                    .stderr
                    .iter()
                    .chain(&report.stdout)
                    .map(String::as_str)
                    .collect(),
                _ => Vec::new(),
            };
            Err(match said.is_empty() {
                true => error.to_string(),
                false => format!("{error}\n{}", said.join("\n")),
            })
        }
    }
}

#[tauri::command(async)]
#[specta::specta]
pub fn repo_effects_apply(scope: Scope, declared: DeclaredEffects) -> Result<Said, String> {
    let env = Env::detect().map_err(|error| error.to_string())?;
    apply(&env, &scope, &declared)
}
