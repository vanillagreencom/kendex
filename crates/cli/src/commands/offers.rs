//! The ways out of a blocked row, and the commands that take them. Every
//! offer here is something the reader can type: it carries the program
//! name and the scope it was read in, and it is only produced where
//! following it would actually settle the item.

use kendex_core::engine::{Completion, DriftCause, DriftRow, EngineReport, RowRemedy};
use kendex_core::env::Env;
use kendex_core::model::{HarnessId, ItemKind, Scope};

/// One item's way out, and whether it is a command or a chore. The two
/// read differently above the row as well as under it, so every surface
/// takes this answer rather than deriving one of its own.
pub struct Offer {
    pub line: String,
    pub adopt: bool,
}

/// One item a plan refused, with the ways out that apply to *it*. The
/// closing ledger reads these, so a sentence naming a shared command can
/// be checked against every item it claims to settle instead of against
/// whichever row happened to have that exit.
pub struct Blocked {
    pub kind: ItemKind,
    pub name: String,
    /// The line printed under this item's rows, when it has one.
    pub offer: Option<Offer>,
    /// The one action that finishes the plan this item came from, the
    /// same for each of its items: the engine's answer
    /// (`engine::completion`), so the conflicts section and the closing
    /// ledger name one action and never a reading of their own.
    pub finish: Option<Finish>,
}

/// How a run reached the project it plans: typed inside it, or named with
/// `--project-path`, where the completion has to name the project too.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Reached {
    Here,
    Named,
}

impl Reached {
    /// The answer for a run given `--project-path` or not.
    pub fn of(named: Option<&std::path::Path>) -> Reached {
        match named {
            Some(_) => Reached::Named,
            None => Reached::Here,
        }
    }
}

/// A plan's completion and how the run reached the scope it is for.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Finish {
    pub completion: Completion,
    pub reached: Reached,
}

impl Blocked {
    /// Whether this row belongs to this blocked item.
    pub fn is(&self, row: &DriftRow) -> bool {
        self.kind == row.kind && self.name == row.name
    }
}

fn same_item(row: &DriftRow, other: &DriftRow) -> bool {
    other.kind == row.kind && other.name == row.name
}

/// Every item these rows block, each asked once. One derivation per item:
/// the line printed under a row and the sentence that closes the run come
/// from the same answer, so they cannot disagree about what was offered.
pub fn blocked_items(env: &Env, rows: &[&DriftRow], finish: Option<Finish>) -> Vec<Blocked> {
    let mut items: Vec<Blocked> = Vec::new();
    for row in rows {
        if items.iter().any(|item| item.is(row)) {
            continue;
        }
        // Every conflict the item has, not only the ones with files in the
        // way: keeping is one move for the whole item and the engine
        // refuses one it could only half settle, so a hard conflict beside
        // them — a link adoption will not touch — takes the offer with it.
        let item: Vec<&DriftRow> = rows
            .iter()
            .filter(|other| same_item(row, other) && other.dead_stop())
            .copied()
            .collect();
        items.push(Blocked {
            kind: row.kind,
            name: row.name.clone(),
            offer: offer_for(env, &item),
            finish,
        });
    }
    items
}

/// The way out an item has. `None` where it has none: every row is its own
/// decision rather than a dead stop, or the dead stops have nothing at
/// their position — a revision clash, a source rebind, a position that
/// would not read — where moving files aside settles nothing. Those rows
/// carry their own remedy in the line the conflict itself prints.
fn offer_for(env: &Env, item: &[&DriftRow]) -> Option<Offer> {
    if !item
        .iter()
        .any(|row| row.cause.is_some_and(DriftCause::at_a_position))
    {
        return None;
    }
    Some(match adopt_command(env, item) {
        Some(line) => Offer { line, adopt: true },
        None => Offer {
            line: "move them somewhere else first".to_owned(),
            adopt: false,
        },
    })
}

/// Whether the offer belongs under this row: the last of the item's rows
/// that can carry it. Keeping an item's files is a single move covering
/// every tool it is blocked for, and run once per tool it lands each
/// tool's copy on top of the last.
pub fn offer_goes_under(rows: &[&DriftRow], row: &DriftRow) -> bool {
    if !row.dead_stop() {
        return false;
    }
    let after = rows
        .iter()
        .position(|other| std::ptr::eq(*other, row))
        .map_or(0, |at| at + 1);
    !rows[after..]
        .iter()
        .any(|later| same_item(row, later) && later.dead_stop())
}

/// The way out that keeps the files, spelled as the command that takes it —
/// printed to be read once and typed, so it carries the program name.
/// `None` wherever no command fits and the files are the reader's to move.
///
/// Every tool it names is one adoption can actually act through: it works
/// at a tool's own place and nowhere else, so a tool with nothing there —
/// a folder its neighbours reach by a shortcut, say — would error the
/// moment the reader followed the offer. Adoption cannot take every kind
/// either, nor a folder where one file goes or a file where a folder goes;
/// and a name a shell would read as more than one argument is never
/// printed as one, since a name may legally hold a space or a semicolon
/// and copied into a terminal that is somebody else's command.
pub fn adopt_command(env: &Env, item: &[&DriftRow]) -> Option<String> {
    let row = item.first()?;
    // Core's answers, not a second reading of the cause, and asked for the
    // item rather than a place at a time: a shape it cannot take stops the
    // whole item, and so does a set of places whose copies disagree, since
    // keeping is one move for all of it.
    let mut tools: Vec<HarnessId> = Vec::new();
    for exits in kendex_core::engine::exits::for_item(env, &row.scope, item) {
        if !exits.keep {
            return None;
        }
        // Every tool the move acts on, which is not always the tool the
        // row is about: a folder shared by hand is read by whoever links
        // at it, and each of those links is cleared. Named here, so the
        // command says what it will touch. A tool with nothing at its own
        // place is not named, because the tool holding the folder keeps it
        // for both.
        if exits.enter {
            for harness in exits.tools {
                if !tools.contains(&harness) {
                    tools.push(harness);
                }
            }
        }
    }
    if tools.is_empty() || !kendex_core::names::plain_argument(&row.name) {
        return None;
    }
    let named: String = tools
        .iter()
        .map(|harness| format!(" --harness {}", harness.name()))
        .collect();
    Some(format!(
        "kendex adopt {} {}{named}{}",
        row.kind.name(),
        row.name,
        scope_flag(&row.scope)
    ))
}

/// A plan's one completion and how the run reached its scope: the
/// engine's answer (`engine::completion`), computed once for every surface
/// that names it.
pub fn finish(report: &EngineReport, reached: Reached) -> Option<Finish> {
    kendex_core::engine::completion(report).map(|completion| Finish {
        completion,
        reached,
    })
}

/// A plan's one completion as keyed data a program reads: the verb and
/// its parameters, never a command line (engine.md rule 18). The
/// repository-effect permission rides as a parameter because the
/// take-over installs a package whose effect needs that yes. A project
/// the run named is the last field, escaped and read to the end of the
/// data, since a path may hold a space.
pub fn finish_with(finish: Finish, scope: &Scope) -> String {
    match finish.completion {
        Completion::TakeOver { allow_repo_effects } => {
            let mut line = "finish-with=apply replace-unmanaged".to_owned();
            if allow_repo_effects {
                line.push_str(" allow-repo-effects");
            }
            push_place(&mut line, scope, finish.reached);
            line
        }
        Completion::UpdatePi => update_pi_with("finish-with", scope, finish.reached),
    }
}

/// The scope an apply-shaped action names: the personal scope by its one
/// flag, a project by its root where the run named it, and nothing for
/// the project the command was typed in, which is `apply`'s default.
fn push_place(line: &mut String, scope: &Scope, reached: Reached) {
    match (scope, reached) {
        (Scope::Global, _) => line.push_str(" global"),
        (Scope::Project { root }, Reached::Named) => push_project(line, root),
        (Scope::Project { .. }, Reached::Here) => {}
    }
}

/// The project a run named, as the last field: escaped, and read to the
/// end of the data, since a path may hold a space.
fn push_project(line: &mut String, root: &std::path::Path) {
    line.push_str(" project=");
    line.push_str(&kendex_core::names::shown(&root.display().to_string()));
}

/// The declared Pi packages a plan leaves for `update-pi`, read off the
/// rows the engine marks with that remedy, never off their wording. An
/// apply's write installs no Pi package, so these stay whatever it writes.
pub fn left_for_update_pi(report: &EngineReport) -> Vec<&DriftRow> {
    report
        .drift
        .iter()
        .filter(|row| row.remedy == Some(RowRemedy::UpdatePi))
        .collect()
}

/// The declared Pi packages a plan leaves that neither its write nor
/// `update-pi` settles, read off the engine's typed reason
/// (`DriftRow::pi_unsettled`), never off their wording or a missing
/// remedy.
pub fn unsettled_pi(report: &EngineReport) -> Vec<&DriftRow> {
    report
        .drift
        .iter()
        .filter(|row| row.pi_unsettled.is_some())
        .collect()
}

/// What a plan left of its declared Pi packages in one scope, and the
/// plan's one completion, which is `update-pi` where it finishes the scope
/// and `None` where it does not: a take-over never settles a scope that
/// leaves a package for `update-pi`, and neither action is named beside a
/// package neither settles (`engine::completion`).
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct PiLeft {
    /// The packages `update-pi` installs ([`left_for_update_pi`]).
    pub update_pi: usize,
    /// The packages neither settles ([`unsettled_pi`]).
    pub unsettled: usize,
    pub finish: Option<Finish>,
}

/// The action that settles every row `left_for_update_pi` returns in one
/// scope, keyed under `key` as `finish_with` keys the take-over:
/// `settle-with` beside the rows, `finish-with` where it is the plan's one
/// completion.
/// The scope is always a parameter, as `Remedy::UpdatePi` always says
/// `--scope`: `update-pi` with none writes every scope, the personal Pi
/// root included, which the plan never reported on.
pub fn update_pi_with(key: &str, scope: &Scope, reached: Reached) -> String {
    match (scope, reached) {
        (Scope::Global, _) => format!("{key}=update-pi scope=global"),
        (Scope::Project { root }, reached) => {
            let mut line = format!("{key}=update-pi scope=project");
            if reached == Reached::Named {
                push_project(&mut line, root);
            }
            line
        }
    }
}

/// The flag that points a command at the scope the row was read in. A
/// project needs none — it is what every command defaults to — but a
/// remedy printed while looking at the global scope runs against the
/// current project without it.
pub fn scope_flag(scope: &Scope) -> &'static str {
    match scope {
        Scope::Global => " --global",
        Scope::Project { .. } => "",
    }
}
