//! The desktop's half of a package's repository effects: the command that
//! runs an effect once the window has a yes, and the one executor every
//! command writes a report through, which undoes a leaving package's
//! effect before the plan takes its scripts away.
//!
//! An install is one command that plans and writes. The effect is not in
//! it: the report's declarations become the offers the window shows, and
//! the window comes back here with the one it got a yes for. Nothing
//! between those two calls is written down, so the yes is good for that
//! run and no other — a refresh repairs files and arms nothing, the same
//! as the terminal.

use kendex_core::engine::EngineReport;
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

/// Why a report did not get written.
///
/// Two, because the caller has to be able to tell them apart. The editor
/// reads a precondition refusal as the reload choice it already draws, and
/// that reading needs core's own error rather than a sentence about it.
pub enum ExecuteError {
    /// A leaving package's uninstaller failed, or could not be run. The
    /// plan stopped before writing anything: the package's files are still
    /// in place, and the message carries what was said before the failure.
    Undo(String),
    /// The undo did what it had to and the plan itself refused. The lines
    /// already said ride along — a repository disarmed before a write that
    /// then failed is a fact the person is still owed. Boxed: a refusal is
    /// the rare path, and the common `Ok` should not carry its size.
    ///
    /// One caller drops them: the editor maps a stale precondition to the
    /// reload choice it draws, which is a unit answer with nowhere to put
    /// a line. Sound there and only there, because that route plans with
    /// `PlanOptions::default()` and so removes nothing — held by
    /// `a_save_that_drops_a_package_removes_nothing_and_so_accounts_for_nothing`
    /// rather than by this sentence. Any other caller that reads this
    /// variant owes the lines.
    Apply {
        said: Vec<String>,
        error: Box<kendex_core::error::CoreError>,
    },
}

impl std::fmt::Display for ExecuteError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            ExecuteError::Undo(message) => write!(f, "{message}"),
            ExecuteError::Apply { said, error } => {
                for line in said {
                    writeln!(f, "{line}")?;
                }
                write!(f, "{error}")
            }
        }
    }
}

/// Execute a report's plan — the one way a desktop command holding an
/// `EngineReport` writes it, and the mirror of the terminal's
/// `apply_report`.
///
/// A plan can take a package away whatever the window called it: removing
/// an item, applying a scope with orphan removal on, unsubscribing, saving
/// a manifest with a package deleted out of it. The package's declared
/// uninstaller has to run while the scripts it names are still on disk, so
/// no command executes `report.plan` itself — every report goes through
/// here, and only a bare `Plan` with no report behind it, which by
/// construction drops no package, is executed on its own.
///
/// Not a refusal that points at the terminal. Removing the package is the
/// ask, the same as it is at the prompt; what the window owes is the
/// account, which comes back as the lines the terminal would have printed
/// for the action's result to carry.
///
/// A package whose uninstaller fails stops the plan with the files still
/// in place, so the person can run it by hand and remove again. The other
/// order leaves the repository in the state this exists to prevent.
pub fn execute(env: &Env, report: &EngineReport) -> Result<Vec<String>, ExecuteError> {
    let mut said = Vec::new();
    if let Err(error) = kendex_core::repo_effects::undo(
        &report.plan.scope,
        &report.repo_effects_leaving,
        // The package's own two streams go out escaped, the way the
        // terminal escapes them. This is a departing third party's output
        // landing in a toast that carries no attribution, so a line of
        // bidi overrides or one phrased in kendex's voice would read as
        // kendex talking. core already escapes its own Note lines, and
        // `shown` over escaped text is the same text.
        //
        // The terminal's stdout door stays unescaped for the reason it
        // exists: those bytes are a pipe's answer. A window has no pipe.
        &mut |spoken| {
            said.push(match spoken {
                kendex_core::repo_effects::Spoken::Note(line) => line,
                other => kendex_core::names::shown(&other.into_line()),
            });
        },
    ) {
        said.push(error.to_string());
        return Err(ExecuteError::Undo(said.join("\n")));
    }
    match kendex_core::apply::execute(env, &report.plan) {
        Ok(_) => Ok(said),
        Err(error) => Err(ExecuteError::Apply {
            said,
            error: Box::new(error),
        }),
    }
}

/// The same write for a caller that has no use for the two kinds apart.
pub fn write(env: &Env, report: &EngineReport) -> Result<Vec<String>, String> {
    execute(env, report).map_err(|error| error.to_string())
}

/// The same write for a caller whose plan must take nothing away, and
/// which has nowhere to say what a removal ran.
///
/// The emptiness is checked, not assumed. A caller reaches this because it
/// proved something about its own plan a moment earlier, and a proof in a
/// comment is worth what the next edit leaves of it — while the cost of
/// being wrong is uninstallers running in somebody's repository off an
/// answer they gave about something else, with nothing said. So it refuses
/// before the write and names what it would have removed, which is the
/// direction guard code has to fail.
pub fn write_nothing_leaving(env: &Env, report: &EngineReport) -> Result<(), String> {
    let leaving = &report.repo_effects_leaving;
    if !leaving.is_empty() {
        let names: Vec<String> = leaving
            .iter()
            .map(|declared| kendex_core::names::shown(&declared.name))
            .collect();
        return Err(format!(
            "this would also take {} away, and undoing what it did to this \
             repository is not something this action can report — apply the \
             scope from the Audit page, which says what a removal ran",
            names.join(", ")
        ));
    }
    write(env, report).map(|_| ())
}
