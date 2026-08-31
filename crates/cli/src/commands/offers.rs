//! The ways out of a blocked row, and the commands that take them. Every
//! offer here is something the reader can type: it carries the program
//! name and the scope it was read in, and it is only produced where
//! following it would actually settle the item.

use kendex_core::engine::{DriftCause, DriftRow};
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
    /// The scope-wide take-over settles this item whole.
    pub replace: bool,
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
pub fn blocked_items(env: &Env, rows: &[&DriftRow]) -> Vec<Blocked> {
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
            replace: item_replaceable(&item),
        });
    }
    items
}

/// The way out an item has. `None` where it has none: every row is its own
/// decision rather than a dead stop, or the dead stops have nothing at
/// their position — a revision clash, a source rebind — where moving files
/// aside settles nothing. Those rows carry their own remedy in the line
/// the conflict itself prints.
fn offer_for(env: &Env, item: &[&DriftRow]) -> Option<Offer> {
    if !item.iter().any(|row| row.cause.is_some()) {
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

/// Whether the flag can take this row's place.
fn can_replace(row: &&DriftRow) -> bool {
    row.cause.is_some_and(DriftCause::can_replace)
}

/// Whether the scope-wide take-over settles this one item whole. It
/// answers for every item it sweeps up or for none of them, so a single
/// row it cannot take stops the item.
fn item_replaceable(item: &[&DriftRow]) -> bool {
    item.iter().any(can_replace) && item.iter().all(can_replace)
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
