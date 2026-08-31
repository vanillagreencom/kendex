//! What a blocked row says on a terminal, and the ways out printed under
//! it. One conflict is said once however many tools hit it: the item, the
//! reason, every position it sits at, how the content in the way compares
//! with the install it blocks, and the exits under all of it.

use kendex_core::engine::{Comparison, DriftCause, DriftRow, DriftState, EngineReport};
use kendex_core::env::Env;
use kendex_core::model::ItemKind;

use super::offers::{Blocked, Offer, blocked_items, offer_goes_under, scope_flag};
use super::say;

/// What this apply cannot write and why. A conflict plans no op, so
/// without this the run ends on "nothing to do" while the thing the user
/// asked for sits blocked with the reason never printed.
///
/// Every conflict is printed. A row is not the safety section said twice:
/// the score is advisory, and the row carries what actually stops the
/// write — files in its way kendex did not write, or the user's edits in
/// the installed copy — with the exits printed under it.
pub fn print_conflicts(env: &Env, report: &EngineReport) -> Vec<Blocked> {
    let rows = conflict_rows(report);
    let blocked = blocked_items(env, &rows);
    for (_, group) in grouped(&rows) {
        let Some((first, rest)) = group.split_first() else {
            continue;
        };
        let offer = blocked.iter().find(|item| item.is(first));
        say(&format!(
            "conflict: {} {} for {}: {}",
            first.kind.name(),
            first.name,
            tools(&group).join(", "),
            conflict_detail(first)
        ));
        // Every position, never a count: the exit for some of these is the
        // reader moving the files themselves, and a place the output does
        // not name is a place they cannot go to.
        for place in also_at(first, rest) {
            say(&format!("  also at {}", place));
        }
        let offer = offer.and_then(|item| item.offer.as_ref());
        if let Some(line) = compared_line(first.compared.as_ref(), offer) {
            say(&format!("  {line}"));
        }
        say_offer(&rows, group.last().unwrap_or(first), offer);
    }
    say_scope_exit(report, &rows, &blocked);
    blocked
}

/// Every row on its own line, with what the collapsed listing says about
/// each one under it. Asking for more detail must not cost the reader the
/// way out, nor the comparison that decides which way out to take: more
/// detail is a superset of less, never a different answer.
pub fn print_drift(env: &Env, report: &EngineReport) -> Vec<Blocked> {
    let rows = conflict_rows(report);
    let blocked = blocked_items(env, &rows);
    for row in &report.drift {
        let offer = blocked
            .iter()
            .find(|item| item.is(row))
            .and_then(|item| item.offer.as_ref());
        say(&format!(
            "{} {} [{}]: {:?} — {}",
            row.kind.name(),
            row.name,
            row.harness.name(),
            row.state,
            conflict_detail(row)
        ));
        // More detail is a superset of less: the collapsed listing names
        // every position, so this one cannot name fewer.
        for place in &row.also_in_the_way {
            say(&format!("  also at {}", place));
        }
        if let Some(line) = compared_line(row.compared.as_ref(), offer) {
            say(&format!("  {line}"));
        }
        say_offer(&rows, row, offer);
    }
    say_scope_exit(report, &rows, &blocked);
    blocked
}

/// One remedy per item, said under the last of the rows that can carry it.
fn say_offer(rows: &[&DriftRow], row: &DriftRow, offer: Option<&Offer>) {
    if let (Some(offer), true) = (offer, offer_goes_under(rows, row)) {
        say(&format!("  to keep those files: {}", offer.line));
    }
}

/// The rows a plan refused, in plan order — the one reading of "blocked"
/// that the printed list, the counts, and the exits all share.
pub fn conflict_rows(report: &EngineReport) -> Vec<&DriftRow> {
    report
        .drift
        .iter()
        .filter(|row| row.state == DriftState::Conflict)
        .collect()
}

/// What makes two rows the same conflict said twice: the item, the reason
/// it is blocked, and how the content in the way compares. The position
/// differs by tool and never splits the group — collapsing on it is the
/// whole point. A row whose detail is a sentence rather than a place keeps
/// that sentence in the key: an edit and a revision clash are different
/// conflicts.
type Key = (
    ItemKind,
    String,
    Option<DriftCause>,
    String,
    Option<Comparison>,
);

fn grouped<'a>(rows: &[&'a DriftRow]) -> Vec<(Key, Vec<&'a DriftRow>)> {
    let mut groups: Vec<(Key, Vec<&DriftRow>)> = Vec::new();
    for row in rows {
        let key = (
            row.kind,
            row.name.clone(),
            row.cause,
            match positional(row) {
                true => String::new(),
                false => row.detail.clone(),
            },
            row.compared.clone(),
        );
        match groups.iter_mut().find(|(seen, _)| *seen == key) {
            Some((_, group)) => group.push(row),
            None => groups.push((key, vec![row])),
        }
    }
    groups
}

/// Whether this row's detail is a place on disk rather than a sentence —
/// the four causes that say files are already where the install goes.
fn positional(row: &DriftRow) -> bool {
    row.cause
        .is_some_and(|cause| cause.in_the_way() || cause == DriftCause::ForeignLink)
}

/// Every tool this conflict blocks, in the order the rows came.
fn tools<'a>(group: &[&'a DriftRow]) -> Vec<&'a str> {
    let mut named: Vec<&str> = Vec::new();
    for row in group {
        let tool = row.harness.display_name();
        if !named.contains(&tool) {
            named.push(tool);
        }
    }
    named
}

/// The positions the head line did not name — every row's own, and the
/// ones a row carries beside it where a tree is read through a
/// harness-native link. Deduped on the place itself, never on its
/// rendering: what makes two rows one place is the path.
fn also_at(first: &DriftRow, rest: &[&DriftRow]) -> Vec<String> {
    let mut places: Vec<&str> = Vec::new();
    for row in std::iter::once(first).chain(rest.iter().copied()) {
        for place in positions(row) {
            if *place != first.detail && !places.contains(&place.as_str()) {
                places.push(place);
            }
        }
    }
    places.into_iter().map(str::to_owned).collect()
}

/// Every position one row is about, its own first.
fn positions(row: &DriftRow) -> impl Iterator<Item = &String> {
    std::iter::once(&row.detail).chain(row.also_in_the_way.iter())
}

/// What the files in the way are, measured against the install they block.
/// A conflict over content identical to the catalog is a decision the
/// reader can take without looking; one over content that differs is not,
/// and the difference is worth naming before either exit runs.
///
/// Whether keeping identical content is *safe* is the exit's answer, not
/// the comparison's: where the way out is the reader moving files aside by
/// hand, calling adoption safe names a command that was never offered.
fn compared_line(compared: Option<&Comparison>, offer: Option<&Offer>) -> Option<String> {
    let compared = compared?;
    if compared.identical() {
        let safe = match offer.is_some_and(|offer| offer.adopt) {
            true => " — adopt is safe",
            false => "",
        };
        return Some(format!("identical to the catalog{safe}"));
    }
    let named: Vec<&str> = compared
        .differing
        .iter()
        .take(NAMED_FILES)
        .map(String::as_str)
        .collect();
    let total = compared.differing_total;
    let more = match total.saturating_sub(u32::try_from(named.len()).unwrap_or(u32::MAX)) {
        0 => String::new(),
        n => format!(", and {n} more"),
    };
    Some(format!(
        "differs from the catalog in {total} file{}: {}{more}",
        plural(total),
        named.join(", ")
    ))
}

/// Enough to recognise what differs without reprinting the item.
const NAMED_FILES: usize = 3;

fn plural(n: u32) -> &'static str {
    match n {
        1 => "",
        _ => "s",
    }
}

/// Once, not per row: the half that names the item differs line by line and
/// belongs on the row; the flag is the same for all of them, and forty
/// copies of it bury the paths that differ. Indented with them all the same
/// — at column 0 it reads as a heading over the plan that follows, which is
/// the plan that runs without it.
fn say_scope_exit(report: &EngineReport, rows: &[&DriftRow], blocked: &[Blocked]) {
    let (true, Some(row)) = (blocked.iter().any(|item| item.replace), rows.first()) else {
        return;
    };
    // The engine's own verdict on this scope, not a second reading of it:
    // the sweep answers for every item it sweeps up or for none of them, so
    // one item it takes and cannot settle refuses the whole run, and
    // printing the flag there offers a command that cannot succeed on the
    // scope it is printed under. Each item's own way out above still stands.
    if kendex_core::engine::takeover::sweep_would_refuse(&report.drift) {
        return;
    }
    say(&format!(
        "  to install what kendex.toml asks for instead: kendex apply --replace-unmanaged{}",
        scope_flag(&row.scope)
    ));
}

/// What a conflict row says on a terminal. A row whose files were already
/// there carries the path alone — the cause is what says the rest, and only
/// a surface knows how to word it — so the sentence is written here.
fn conflict_detail(row: &DriftRow) -> String {
    let detail = &row.detail;
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
        _ => detail.clone(),
    }
}

#[cfg(test)]
mod tests {
    use kendex_core::model::{HarnessId, Scope};

    use super::*;

    fn row(harness: HarnessId, detail: &str) -> DriftRow {
        DriftRow {
            kind: ItemKind::Skill,
            name: "deploy".to_owned(),
            harness,
            scope: Scope::Global,
            state: DriftState::Conflict,
            detail: detail.to_owned(),
            cause: Some(DriftCause::UnmanagedContent),
            compared: None,
            also_in_the_way: Vec::new(),
        }
    }

    /// A position is an identity, and the escape the `ui` seam prints it
    /// through is not injective: a path holding a real newline and one
    /// holding the two characters that spell its escape reach the screen
    /// alike. Deduplicated here, on the paths themselves, both survive to
    /// be printed — one of two real places would otherwise be dropped
    /// before the seam ever saw it.
    #[test]
    fn two_positions_that_render_alike_are_both_named() {
        let head = row(HarnessId::Claude, "/a/head");
        let real = row(HarnessId::Codex, "/a/one\ntwo");
        let literal = row(HarnessId::Cursor, "/a/one\\ntwo");
        let places = also_at(&head, &[&real, &literal]);
        assert_eq!(
            places,
            vec!["/a/one\ntwo".to_owned(), "/a/one\\ntwo".to_owned()],
            "two real places rendered alike were printed as one"
        );
    }

    /// A tree read through a harness-native link is blocked at two
    /// positions and has one row. A listing naming only the row's own
    /// leaves the reader a place they cannot go to, and the take-over
    /// under it empties both.
    #[test]
    fn a_position_carried_beside_a_row_is_named_too() {
        let mut first = row(HarnessId::Claude, "/a/.agents/skills/deploy");
        first.also_in_the_way = vec!["/a/.claude/skills/deploy".to_owned()];
        assert_eq!(
            also_at(&first, &[]),
            vec!["/a/.claude/skills/deploy".to_owned()]
        );
    }

    /// The same place under two tools is one place, said once.
    #[test]
    fn one_place_reached_twice_is_named_once() {
        let first = row(HarnessId::Claude, "/a/shared");
        let same = row(HarnessId::Codex, "/a/shared");
        let other = row(HarnessId::Cursor, "/a/other");
        let another = row(HarnessId::Pi, "/a/other");
        let places = also_at(&first, &[&same, &other, &another]);
        assert_eq!(places, vec!["/a/other".to_owned()]);
    }
}
