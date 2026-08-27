//! The desktop's half of a package's repository effects: the command that
//! runs an effect once the window has a yes.
//!
//! An install is one command that plans and writes. The effect is not in
//! it: the report's declarations become the offers the window shows, and
//! the window comes back here with the one it got a yes for. Nothing
//! between those two calls is written down, so the yes is good for that
//! run and no other — a refresh repairs files and arms nothing, the same
//! as the terminal.

use kendex_core::model::Scope;
use kendex_core::repo_effects::{ArmError, DeclaredEffects};

/// Run one package's declared installer, here and now, and hand back what
/// it printed: an installer that deliberately arms nothing says so on
/// stdout and exits 0, and the window shows its words rather than a
/// verdict of its own.
///
/// The declaration comes back from the window exactly as the install handed
/// it over, the way the terminal keeps it in hand between the block and the
/// prompt. Its root is confined the way every scope root the window passes
/// is: `run_script` resolves the program under it and refuses one that
/// leaves it.
pub fn apply(scope: &Scope, declared: &DeclaredEffects) -> Result<Vec<String>, String> {
    match kendex_core::repo_effects::arm(scope, declared) {
        Ok(report) => Ok(report.stdout),
        // The one wording, with the package's own lines under it — the
        // account of a possibly half-written repository has to reach the
        // person whole.
        Err(error @ ArmError::Failed { .. }) => {
            let ArmError::Failed { report, .. } = &error else {
                unreachable!("matched above");
            };
            let said: Vec<&str> = report
                .stderr
                .iter()
                .chain(&report.stdout)
                .map(String::as_str)
                .collect();
            Err(match said.is_empty() {
                true => error.to_string(),
                false => format!("{error}\n{}", said.join("\n")),
            })
        }
        Err(error) => Err(error.to_string()),
    }
}

#[tauri::command(async)]
#[specta::specta]
pub fn repo_effects_apply(scope: Scope, declared: DeclaredEffects) -> Result<Vec<String>, String> {
    apply(&scope, &declared)
}
