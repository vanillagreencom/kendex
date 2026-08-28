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
    let escaped = escaped_the_frame(&pretty);
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
        .skip_while(|line| !line.starts_with('└'))
        .collect::<Vec<_>>()
        .join("\n");
    assert!(
        !closing.is_empty() && unframed(&closing).contains(&squashed(ledger)),
        "the frame closed on something other than the ledger: {pretty}"
    );
    // Nothing after the close but its own steps: a block drawn under the
    // closing line is a run that went on past the line saying it ended.
    assert!(
        closing
            .lines()
            .skip(1)
            .all(|line| line.starts_with("     ")),
        "the run said something after it closed: {pretty}"
    );
    for step in [
        "skipped — kendex apply --replace-unmanaged, or the kendex adopt line under each conflict above",
        "flagged — the safety lines above",
    ] {
        assert!(
            unframed(&closing).contains(&squashed(step)),
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
            carried.contains(&squashed(line)),
            "the framed session dropped {line:?}:\n{pretty}"
        );
    }
}

/// And in the order it said them. Flattening the session into one string
/// would let a block drawn after the thing it explains pass, which is the
/// defect the buffering makes possible.
#[test]
fn the_frame_says_them_in_the_order_the_plain_run_did() {
    let (plain, pretty) = both(&REFRESH);
    // Up to the closing box, whose head the terminal's width wraps across
    // lines; that the box carries the ledger is its own assertion above.
    let framed: Vec<String> = unframed_lines(&pretty)
        .into_iter()
        .take_while(|line| !line.contains(": refreshed "))
        .collect();
    let mut at = 0usize;
    for line in plain
        .lines()
        .filter(|line| !line.trim().is_empty() && !line.contains(": refreshed "))
        .take_while(|line| !line.starts_with("  skipped — "))
    {
        let wanted = squashed(line);
        let found = framed[at..]
            .iter()
            .position(|drawn| squashed(drawn).contains(&wanted));
        match found {
            Some(step) => at += step,
            None => panic!("{line:?} was drawn out of order or not at all:\n{pretty}"),
        }
    }
    assert!(at > 0, "nothing was matched at all: {pretty}");
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
            carried.matches(&squashed(once)).count(),
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
    let plain_lines = count(&plain);
    let framed = count(&pretty);
    // Two-sided: a frame costing nothing means it was never drawn, and a
    // frame costing more than its own furniture is growing per item — or
    // wrapping, which a deep enough temp directory would make it do.
    assert_eq!(
        framed.saturating_sub(plain_lines),
        FRAME_LINES,
        "the frame cost {framed} lines against the plain run's {plain_lines}: {pretty}"
    );
}

/// The opening line and the rule under it. The closing line is the
/// ledger's own, and costs the run nothing.
const FRAME_LINES: usize = 2;

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

/// A run that ends on anything but its ledger still closes its frame.
/// `FRAMED` records that a frame was opened and nothing recorded that one
/// was closed, so a ledger drawn as an ordinary block — because output
/// followed it — left the reader a gutter bar hanging off the bottom of
/// the run with no closing line under it.
#[test]
fn a_run_ending_outside_its_ledger_still_closes_the_frame() {
    let printed = said(&nothing_declared(&["refresh", "--scope", "project"]));
    assert!(
        printed.contains("nothing installed"),
        "the fixture no longer reaches the case: {printed}"
    );
    assert!(
        printed.contains("\n\u{2514}"),
        "the frame was left open: {printed}"
    );
}

/// The closing line is genuinely last, even when the work after the
/// writes has something to say. The snapshot pass runs once every scope
/// is written and can warn; emitted from inside the scope loop, the
/// ledger was drawn as an ordinary block and the run ended on that
/// warning and a bare corner instead of on its outcome.
#[test]
#[allow(clippy::unwrap_used)]
fn a_warning_after_the_writes_lands_above_the_closing_ledger() {
    for ui in ["plain", "pretty"] {
        let tmp = tempfile::tempdir().unwrap();
        let home = tmp.path();
        let project = home.join("dev/app");
        blocked_project_at(home, &project);
        // A file where the snapshot's directory belongs, so deriving it
        // fails and the pass after the writes has a warning to print.
        let data = home.join(".local/share/kendex");
        fs::create_dir_all(&data).unwrap();
        fs::write(data.join("drift"), "not a directory\n").unwrap();

        let printed = said(&kendex(
            home,
            &project,
            ui,
            &["refresh", "-y", "--scope", "project"],
        ));
        assert!(
            printed.contains("snapshot not derived"),
            "the fixture no longer reaches the case ({ui}): {printed}"
        );
        let lines: Vec<&str> = printed.lines().filter(|line| !line.is_empty()).collect();
        let warned = lines
            .iter()
            .position(|line| line.contains("snapshot not derived"))
            .unwrap();
        let closed = lines
            .iter()
            .rposition(|line| line.contains("refreshed"))
            .unwrap();
        assert!(
            warned < closed,
            "the warning landed under the closing line ({ui}): {printed}"
        );
    }
}
