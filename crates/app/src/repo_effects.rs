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
    // Escaped on the way out, both channels and both outcomes. These are a
    // third party's bytes and the window renders the installer's last
    // stdout line as a bare toast the moment somebody authorizes an
    // arming, so a bidi override or a line phrased in kendex's voice would
    // read as kendex's verdict on what they just approved. The departing
    // half of this module is held to the same rule; one door each would
    // mean the rule holds wherever it was last reviewed.
    let shown = |lines: &[String]| -> Vec<String> {
        lines
            .iter()
            .map(|line| kendex_core::names::shown(line))
            .collect()
    };
    match kendex_core::repo_effects::arm(scope, declared) {
        Ok(report) => Ok(Said {
            stdout: shown(&report.stdout),
            stderr: shown(&report.stderr),
        }),
        // The one wording, with the package's own lines under it where the
        // installer got far enough to say anything — the account of a
        // possibly half-written repository has to reach the person whole.
        Err(error) => {
            let said: Vec<String> = match &error {
                ArmError::Failed { report, .. } => report
                    .stderr
                    .iter()
                    .chain(&report.stdout)
                    .map(|line| kendex_core::names::shown(line))
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
    /// Every caller carries them, the editor's stale answer included: its
    /// `WriteRefused::Stale` holds an `undone` for exactly this. No route
    /// is exempt on the grounds that its own plan cannot remove anything,
    /// because none of them can show that — a rendering the engine refuses
    /// drops the package's lock entry whatever the planning options say
    /// about orphans, so an uninstaller runs on a path nobody asked for a
    /// removal on.
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

/// What stands in for the lines of one package's output that were not
/// carried. Said rather than dropped: an account that quietly stops is one
/// nobody knows to go and read in full.
fn elided(lines: usize) -> String {
    format!(
        "and {lines} more line{} from that package",
        match lines {
            1 => "",
            _ => "s",
        }
    )
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
    // How many lines of one package's own output are carried. A departing
    // package chooses its own output length and core relays it whole, so
    // an account with no ceiling is a third party deciding how long the
    // window is busy. Per package rather than over the whole account,
    // because the budget is about one program being chatty.
    const PACKAGE_LINES: usize = 10;
    let mut spent = 0usize;
    let mut dropped = 0usize;
    if let Err(error) = kendex_core::repo_effects::undo(
        &report.plan.scope,
        &report.repo_effects_leaving,
        // Two rules, and both need the tag core attached — which is why
        // the budget is spent here rather than over the flat list the
        // window receives.
        //
        // Every Note is kept, whatever a neighbour printed. They are
        // kendex's own account and the ONLY place it says an effect was
        // left standing and names the manual remedy; a package that
        // pushed a sibling's stand-down notice past a cap would be
        // suppressing the one line nothing else can recover. Their count
        // is bounded by the number of packages leaving, so keeping them
        // all cannot restore the drain the budget exists to stop.
        //
        // The package's own two streams go out escaped, the way the
        // terminal escapes them. This is a departing third party's output
        // landing in a toast that carries no attribution, so a line of
        // bidi overrides or one phrased in kendex's voice would read as
        // kendex talking. `shown` over core's already-escaped Note lines
        // is the same text, so only the streams need it.
        //
        // The terminal's stdout door stays unescaped for the reason it
        // exists: those bytes are a pipe's answer. A window has no pipe.
        &mut |spoken| match spoken {
            kendex_core::repo_effects::Spoken::Note(line) => {
                if dropped > 0 {
                    said.push(elided(dropped));
                    dropped = 0;
                }
                spent = 0;
                said.push(line);
            }
            other if spent < PACKAGE_LINES => {
                spent += 1;
                said.push(kendex_core::names::shown(&other.into_line()));
            }
            _ => dropped += 1,
        },
    ) {
        if dropped > 0 {
            said.push(elided(dropped));
        }
        said.push(error.to_string());
        return Err(ExecuteError::Undo(said.join("\n")));
    }
    if dropped > 0 {
        said.push(elided(dropped));
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

/// Fold the account into whatever an enrichment read failed with.
///
/// Once `execute` has returned, the uninstallers have run and the plan is
/// committed. Everything a command does after that — reading back the
/// sources, the sets, the packages — is enrichment, and a `?` on one of
/// those discards the account with the answer it was riding on. The person
/// is then shown a listing error over a repository that was disarmed a
/// moment earlier, which is this issue's own failure mode reached through
/// the error path instead of the happy one.
///
/// Carried on the error rather than dropped, and never at the cost of the
/// error itself: an irreversible side effect is not made reversible by
/// swallowing what came after it. The lines go first because they are what
/// changed on disk; the failure follows, saying what could not be read.
pub fn after_writing<T>(undone: &[String], read: Result<T, String>) -> Result<T, String> {
    read.map_err(|error| match undone.is_empty() {
        true => error,
        false => format!("{}\n{error}", undone.join("\n")),
    })
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

#[cfg(test)]
mod tests {
    use super::after_writing;

    /// The shape every post-write read shares: the account rides on the
    /// failure, and the failure is not swallowed to carry it.
    #[test]
    fn a_read_that_fails_after_the_write_carries_the_account_and_the_error() {
        let undone = ["guards: running scripts/arm --uninstall".to_owned()];
        let refused: Result<(), String> = Err("the source list could not be read".to_owned());

        let Err(message) = after_writing(&undone, refused) else {
            panic!("a failed read must stay a failure");
        };

        assert_eq!(
            message,
            "guards: running scripts/arm --uninstall\nthe source list could not be read"
        );
    }

    /// Nothing left the scope, so there is nothing to add to the failure.
    #[test]
    fn a_read_that_fails_after_a_write_that_removed_nothing_says_only_why() {
        let refused: Result<(), String> = Err("the source list could not be read".to_owned());
        let Err(message) = after_writing(&[], refused) else {
            panic!("a failed read must stay a failure");
        };
        assert_eq!(message, "the source list could not be read");
    }

    /// A read that worked is handed straight back.
    #[test]
    fn a_read_that_worked_is_untouched() {
        let undone = ["guards: running scripts/arm --uninstall".to_owned()];
        assert_eq!(after_writing(&undone, Ok::<u8, String>(7)), Ok(7));
    }
}
