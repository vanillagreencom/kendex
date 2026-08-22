//! What a blocked row says on a terminal, and the ways out printed under
//! it. Every offer here is a command the reader can type: it carries the
//! program name and the scope it was read in, and it is only printed where
//! following it would actually settle the item.

use kendex_core::engine::{DriftCause, DriftRow, DriftState, EngineReport};
use kendex_core::env::Env;
use kendex_core::model::{HarnessId, Scope};

use super::say;

/// What this apply cannot write and why. A conflict plans no op, so
/// without this the run ends on "nothing to do" while the thing the user
/// asked for sits blocked with the reason never printed.
///
/// Every conflict is printed, held-back items included. Their rows are not
/// the safety section said twice: they carry what happens to the copy
/// already installed — moved to the trash, or kept because the user's
/// edits are in it and still standing in the way of the accepted content.
pub fn print_conflicts(env: &Env, report: &EngineReport) -> bool {
    let rows = conflict_rows(report);
    for row in &rows {
        say(&format!(
            "conflict: {} {} for {}: {}",
            row.kind.name(),
            kendex_core::names::shown(&row.name),
            row.harness.display_name(),
            conflict_detail(row)
        ));
        for line in exits_under(env, &rows, row) {
            say(&line);
        }
    }
    say_scope_exit(&rows);
    !rows.is_empty()
}

/// The ways out alone, for a surface that has already listed the rows.
/// Asking for more detail must not cost the reader the way out.
pub fn print_exits(env: &Env, report: &EngineReport) {
    let rows = conflict_rows(report);
    for row in &rows {
        for line in exits_under(env, &rows, row) {
            say(&line);
        }
    }
    say_scope_exit(&rows);
}

fn conflict_rows(report: &EngineReport) -> Vec<&DriftRow> {
    report
        .drift
        .iter()
        .filter(|row| row.state == DriftState::Conflict)
        .collect()
}

/// One remedy per item, said under the last of the rows that have a way
/// out: keeping an item's files is a single move covering every tool it is
/// blocked for, and run once per tool it lands each tool's copy on top of
/// the last. Only those rows count towards which is last — an item can also
/// be edited under another tool, and waiting for a row that will never
/// print the offer loses it altogether.
fn exits_under<'a>(env: &Env, rows: &[&'a DriftRow], row: &&'a DriftRow) -> Vec<String> {
    if !row.dead_stop() {
        return Vec::new();
    }
    // Only where the item has files at its position. A revision clash or a
    // source rebind is a dead stop too, and telling the reader to move
    // files aside settles nothing there — nor does an edit beside it, which
    // is a decision of its own and not files anybody has to move.
    if !rows.iter().any(|other| {
        other.kind == row.kind
            && other.name == row.name
            && other.dead_stop()
            && other.cause.is_some()
    }) {
        return Vec::new();
    }
    // Every conflict the item has, not only the ones with files in the
    // way: keeping is one move for the whole item and the engine refuses
    // one it could only half settle, so a hard conflict beside them — a
    // link adoption will not touch — takes the offer with it.
    let blocked =
        |other: &&&DriftRow| other.kind == row.kind && other.name == row.name && other.dead_stop();
    let index = rows.iter().position(|other| std::ptr::eq(*other, *row));
    let after = index.map_or(0, |at| at + 1);
    if rows[after..].iter().any(|later| blocked(&later)) {
        return Vec::new();
    }
    let item: Vec<&DriftRow> = rows.iter().filter(blocked).copied().collect();
    vec![format!("  to keep those files: {}", keep_exit(env, &item))]
}

/// Once, not per row: the half that names the item differs line by line and
/// belongs on the row; the flag is the same for all of them, and forty
/// copies of it bury the paths that differ. Indented with them all the same
/// — at column 0 it reads as a heading over the plan that follows, which is
/// the plan that runs without it.
///
/// The flag reaches every blocked item in the scope and refuses the whole
/// run over one it could only half take over, so it is only a way out
/// where every one of them is wholly replaceable. Printed on the strength
/// of a single item, it is a command guaranteed to fail.
fn say_scope_exit(rows: &[&DriftRow]) {
    let files: Vec<&&DriftRow> = rows
        .iter()
        .filter(|row| row.dead_stop() && row.cause.is_some())
        .collect();
    let replaceable = files
        .iter()
        .any(|row| row.cause.is_some_and(DriftCause::in_the_way))
        && rows.iter().all(|row| {
            // A conflict on an item with no files at its position is not
            // one this flag ever reaches.
            !row.dead_stop()
                || !files
                    .iter()
                    .any(|other| other.kind == row.kind && other.name == row.name)
                || row.cause.is_some_and(DriftCause::can_replace)
        });
    if let (true, Some(row)) = (replaceable, rows.first()) {
        say(&format!(
            "  to install what kendex.toml asks for instead: kendex apply --replace-unmanaged{}",
            scope_flag(&row.scope)
        ));
    }
}

/// What a conflict row says on a terminal. A row whose files were already
/// there carries the path alone — the cause is what says the rest, and only
/// a surface knows how to word it — so the sentence is written here.
pub fn conflict_detail(row: &DriftRow) -> String {
    let detail = kendex_core::names::shown(&row.detail);
    match row.cause {
        Some(DriftCause::UnmanagedContent | DriftCause::UnmanagedWrongShape) => {
            format!("{detail} already holds files kendex did not write")
        }
        // The path here is the folder the link points at, not the link:
        // that folder is the thing the reader has to decide about.
        Some(DriftCause::ForeignLink) => format!("{detail} is a link kendex did not create"),
        Some(DriftCause::SharedLink) => {
            format!("{detail} is a folder kendex did not write, read through a shortcut")
        }
        _ => detail,
    }
}

/// The way out that keeps the files, spelled as the command that takes it —
/// printed to be read once and typed, so it carries the program name.
///
/// Every tool it names is one adoption can actually act through: it works
/// at a tool's own place and nowhere else, so a tool with nothing there —
/// a folder its neighbours reach by a shortcut, say — would error the
/// moment the reader followed the offer. Adoption cannot take every kind
/// either, nor a folder where one file goes or a file where a folder goes;
/// and a name a shell would read as more than one argument is never
/// printed as one, since a name may legally hold a space or a semicolon
/// and copied into a terminal that is somebody else's command. Wherever
/// nothing can be offered the files are still the reader's to keep, by
/// moving them out of the way themselves.
fn keep_exit(env: &Env, item: &[&DriftRow]) -> String {
    let away = "move them somewhere else first".to_owned();
    let Some(row) = item.first() else {
        return away;
    };
    let mut tools: Vec<HarnessId> = Vec::new();
    for row in item {
        // Core's answers, not a second reading of the cause. A shape it
        // cannot take stops the whole item, since keeping is one move for
        // all of it; a tool with nothing at its own place is a different
        // thing and simply is not named, because the tool holding the
        // folder keeps it for both.
        let exits = kendex_core::engine::exits::for_row(env, &row.scope, row);
        if !exits.keep {
            return away;
        }
        if exits.enter && !tools.contains(&row.harness) {
            tools.push(row.harness);
        }
    }
    if tools.is_empty() || !kendex_core::names::plain_argument(&row.name) {
        return away;
    }
    let named: String = tools
        .iter()
        .map(|harness| format!(" --harness {}", harness.name()))
        .collect();
    format!(
        "kendex adopt {} {}{named}{}",
        row.kind.name(),
        row.name,
        scope_flag(&row.scope)
    )
}

/// The flag that points a command at the scope the row was read in. A
/// project needs none — it is what every command defaults to — but a
/// remedy printed while looking at the global scope runs against the
/// current project without it.
fn scope_flag(scope: &Scope) -> &'static str {
    match scope {
        Scope::Global => " --global",
        Scope::Project { .. } => "",
    }
}
