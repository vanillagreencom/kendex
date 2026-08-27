//! The desktop's half of a package's repository effects: what an install
//! hands the window to read, and the command that runs an effect once the
//! window has a yes.
//!
//! An install is one command that plans and writes. The effect is not in
//! it: the report carries the declarations, this turns them into the
//! offers the window shows, and the window comes back with a separate
//! command for the one it got a yes for. Nothing between those two calls
//! is written down, so the yes is good for that run and no other — a
//! refresh repairs files and arms nothing, the same as the terminal.

use kendex_core::engine::EngineReport;
use kendex_core::env::Env;
use kendex_core::model::Scope;
use kendex_core::repo_effects::{DeclaredEffects, Offers};

/// The offers an applied plan's effects earn: read after the write, so a
/// companion that landed in the same plan counts as installed.
pub fn offers(env: &Env, scope: &Scope, report: &EngineReport) -> Result<Offers, String> {
    if report.repo_effects.is_empty() {
        return Ok(Offers::default());
    }
    let installed =
        kendex_core::repo_effects::installed_skills(env, scope).map_err(|e| e.to_string())?;
    Ok(kendex_core::repo_effects::offers(
        scope,
        &report.repo_effects,
        &installed,
    ))
}

/// Run one package's declared installer, here and now.
///
/// The declaration comes back from the window exactly as the install handed
/// it over, the way the terminal keeps it in hand between the block and the
/// prompt. Its root is confined the way every scope root the window passes
/// is: `run_script` resolves the program under it and refuses one that
/// leaves it.
pub fn apply(scope: &Scope, declared: &DeclaredEffects) -> Result<(), String> {
    let Some(installer) = &declared.effects.installer else {
        return Err(format!(
            "{} declares nothing kendex can run — arm it yourself when you are ready",
            declared.name
        ));
    };
    let report = kendex_core::repo_effects::run_script(scope, &declared.root, installer)
        .map_err(|e| e.to_string())?;
    if report.code != 0 {
        // Not "the repository is unchanged". kendex takes no pre-image and
        // rolls nothing back, so an installer that wrote three files and
        // failed on the fourth leaves three files. The declaration names
        // what the package writes, which is where to look.
        let said = report
            .stderr
            .iter()
            .chain(&report.stdout)
            .cloned()
            .collect::<Vec<_>>()
            .join("\n");
        return Err(format!(
            "{} exited {} — anything it wrote before that is still there; \
             {} is what the package says undoes it\n{said}",
            installer,
            report.code,
            declared
                .effects
                .uninstaller
                .as_deref()
                .unwrap_or("its uninstaller")
        ));
    }
    Ok(())
}

#[tauri::command(async)]
#[specta::specta]
pub fn repo_effects_apply(scope: Scope, declared: DeclaredEffects) -> Result<(), String> {
    apply(&scope, &declared)
}
