//! What a terminal gets. The frame is the only thing that differs: every
//! word the plain run said is here, said once, inside it.

use super::*;

const REFRESH: [&str; 4] = ["refresh", "-y", "--scope", "project"];

/// The frame opens on the verb and closes on the outcome, and every line
/// between the two belongs to it. A line at column 0 in the middle of a
/// framed session is a verb that wrote to the terminal behind the
/// module's back.
#[test]
fn the_session_is_framed_from_the_verb_to_the_outcome() {
    let (_, pretty) = both(&REFRESH);
    assert!(
        pretty.starts_with("┌  kendex refresh\n"),
        "the frame opens on the verb: {pretty}"
    );
    let escaped: Vec<&str> = pretty
        .lines()
        .filter(|line| !line.is_empty() && !FRAMING.contains(&line.chars().next().unwrap_or(' ')))
        .collect();
    assert!(
        escaped.is_empty(),
        "lines reached the terminal outside the frame: {escaped:?}\n{pretty}"
    );
}

/// The frame carries the outcome, not a sign-off: the run closes on the
/// same ledger the plain run closed on, with the same next steps under
/// it.
#[test]
fn the_frame_closes_on_the_ledger() {
    let (plain, pretty) = both(&REFRESH);
    let ledger = plain
        .lines()
        .find(|line| line.contains(": refreshed "))
        .unwrap_or_default();
    let closing = pretty
        .lines()
        .skip_while(|line| !line.starts_with('├'))
        .collect::<Vec<_>>()
        .join(" ");
    assert!(
        !closing.is_empty() && unframed(&closing).contains(&flat(ledger)),
        "the frame closed on something other than the ledger: {pretty}"
    );
    assert!(
        pretty.trim_end().ends_with('╯'),
        "the frame was left open: {pretty}"
    );
    for step in [
        "skipped — kendex apply --replace-unmanaged, or the kendex adopt line under each conflict above",
        "flagged — the safety lines above",
    ] {
        assert!(
            unframed(&closing).contains(step),
            "the ledger dropped a next step: {pretty}"
        );
    }
}

/// Framing is all that differs. Every line the plain run said is in the
/// framed one — the module renders one set of calls two ways, and a
/// terminal that is shown less than a pipe is a terminal being lied to.
#[test]
fn the_frame_carries_every_line_the_plain_run_said() {
    let (plain, pretty) = both(&REFRESH);
    let carried = unframed(&pretty);
    for line in plain.lines().filter(|line| !line.trim().is_empty()) {
        assert!(
            carried.contains(&flat(line)),
            "the framed session dropped {line:?}:\n{pretty}"
        );
    }
}

/// One conflict said once, one way out said once, one ledger — the same
/// bound the plain run is held to, so the frame cannot buy its hierarchy
/// by repeating a headline inside it.
#[test]
fn nothing_is_said_twice_inside_the_frame() {
    let (_, pretty) = both(&REFRESH);
    let carried = unframed(&pretty);
    for once in [
        "conflict: skill growth-guards",
        "to keep those files:",
        "to install what kendex.toml asks for instead:",
        ": refreshed 3 changes",
    ] {
        assert_eq!(
            carried.matches(once).count(),
            1,
            "{once:?} was said more than once: {pretty}"
        );
    }
}

/// Detail stays under the headline it was written under. The grammar is
/// two spaces, and it is what turns a wall of lines into blocks.
#[test]
fn detail_is_drawn_under_its_headline() {
    let (_, pretty) = both(&REFRESH);
    let mut lines = pretty
        .lines()
        .skip_while(|line| !line.starts_with("◇  conflict:"));
    assert!(lines.next().is_some(), "no conflict headline: {pretty}");
    for detail in [
        "also at",
        "differs from the catalog in 2 files",
        "to keep those files:",
        "to install what kendex.toml asks for instead:",
    ] {
        let line = lines.next().unwrap_or_default();
        assert!(
            line.starts_with("│    ") && line.contains(detail),
            "{detail:?} left its headline: {line:?}\n{pretty}"
        );
    }
}

/// The frame is a fixed cost, not a per-item one: an opening line, a
/// rule, and the box the closing ledger sits in. A frame that grew with
/// the run would put the outcome off the bottom of the screen, which is
/// the thing the plain run's twenty-line bound exists to stop.
#[test]
fn the_frame_costs_the_run_a_fixed_number_of_lines() {
    let (plain, pretty) = both(&REFRESH);
    let count = |text: &str| text.lines().filter(|line| !line.trim().is_empty()).count();
    let overhead = count(&pretty).saturating_sub(count(&plain));
    assert!(
        overhead <= FRAME_LINES,
        "the frame cost {overhead} lines over the plain run's {}: {pretty}",
        count(&plain)
    );
}

/// The opening line, the rule under it, and the box the ledger closes in.
const FRAME_LINES: usize = 6;

/// A run of one-line verdicts is one block, not one block each. Twenty
/// installations checked is the case this is for: a rule drawn between
/// every tick is the wall the module exists to stop printing.
#[test]
#[allow(clippy::unwrap_used)]
fn one_line_verdicts_are_drawn_as_one_group() {
    let tmp = tempfile::tempdir().unwrap();
    let home = tmp.path();
    let project = blocked_project(home);
    // A row to verify has to be installed first; the blocked item stays
    // blocked and the two that install are the clean rows.
    kendex(
        home,
        &project,
        "plain",
        &["refresh", "-y", "--scope", "project"],
    );
    let pretty = said(&kendex(
        home,
        &project,
        "pretty",
        &["verify", "--scope", "project"],
    ));
    let ticks: Vec<&str> = pretty
        .lines()
        .filter(|line| line.contains("✓ skill "))
        .collect();
    assert_eq!(ticks.len(), 2, "the fixture needs two clean rows: {pretty}");
    assert!(
        ticks[0].starts_with('◇') && ticks[1].starts_with('│'),
        "each verdict opened a block of its own: {ticks:?}\n{pretty}"
    );
}
