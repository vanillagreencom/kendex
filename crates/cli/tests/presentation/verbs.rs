//! The rules held across the surface rather than on one verb. A verb that
//! has not been given a frame prints plain lines wherever it runs; a verb
//! that has been given one is framed from its first line to its last; and
//! neither ever puts a frame character in a pipe.

use super::*;

/// The verbs routed through the module and given a frame.
const FRAMED: [&[&str]; 6] = [
    &["refresh", "-y", "--scope", "project"],
    &["apply", "--plan", "--scope", "project"],
    &["add", "{catalog}", "--skill", "tidy", "-y"],
    &[
        "remove",
        "growth-guards",
        "--no-sweep",
        "--scope",
        "project",
    ],
    &["verify", "--scope", "project"],
    &["check", "--scope", "project"],
];

/// Verbs that route through the module with no frame of their own. They
/// are the reason framing is armed rather than detected: a verb with no
/// frame has to keep printing plain lines on a terminal, not block glyphs
/// hanging off a gutter nobody drew.
const UNFRAMED: [&[&str]; 4] = [
    &["list"],
    &["source", "list"],
    &["init"],
    &["show", "skill", "growth-guards"],
];

fn ran(ui: &str, args: &[&str]) -> Ran {
    one(ui, args)
}

/// Not one frame character reaches a pipe, for any verb. This is the
/// whole non-interactive contract, checked across the surface rather than
/// on the one verb the snapshots pin.
#[test]
fn no_verb_puts_a_frame_character_in_a_pipe() {
    for args in FRAMED.into_iter().chain(UNFRAMED) {
        for ui in ["plain", ""] {
            let Ran { output, .. } = ran(ui, args);
            let printed = said(&output);
            let found: Vec<char> = FRAMING
                .into_iter()
                .filter(|symbol| printed.contains(*symbol))
                .collect();
            assert!(
                found.is_empty(),
                "{args:?} under KENDEX_UI={ui:?} put {found:?} in a pipe: {printed}"
            );
            assert!(
                String::from_utf8_lossy(&output.stdout)
                    .chars()
                    .all(|c| !FRAMING.contains(&c)),
                "{args:?} framed its stdout: {printed}"
            );
        }
    }
}

/// A verb with no frame of its own stays plain on a terminal too. Without
/// this the gutter glyphs come back the moment somebody routes a verb
/// through the module and forgets the one call that opens a frame.
#[test]
fn a_verb_with_no_frame_stays_plain_on_a_terminal() {
    for args in UNFRAMED {
        let Ran { output, .. } = ran("pretty", args);
        let printed = said(&output);
        let found: Vec<char> = FRAMING
            .into_iter()
            .filter(|symbol| printed.contains(*symbol))
            .collect();
        assert!(
            found.is_empty(),
            "{args:?} drew {found:?} with no frame around them: {printed}"
        );
    }
}

/// A framed verb is framed from its first line to its last. Every line it
/// says belongs to the frame, whichever way the run ended.
#[test]
fn a_framed_verb_frames_every_line_it_says() {
    for args in FRAMED {
        let Ran { output, .. } = ran("pretty", args);
        let printed = said(&output);
        assert!(
            printed.starts_with('┌'),
            "{args:?} said something before opening its frame: {printed}"
        );
        let escaped = escaped_the_frame(&printed);
        assert!(
            escaped.is_empty(),
            "{args:?} said {escaped:?} outside its frame: {printed}"
        );
        assert!(
            printed.contains("\n└"),
            "{args:?} left its frame open: {printed}"
        );
    }
}

/// The framed rendering never says less than the plain one. Checked for
/// every framed verb, not only the one the snapshots pin: a verb that
/// drops a line into the frame's furniture tells a terminal less than a
/// pipe.
#[test]
fn every_framed_verb_carries_what_its_plain_run_said() {
    for args in FRAMED {
        let (plain, pretty) = both(args);
        let carried = unframed(&pretty);
        for line in plain.lines().filter(|line| !line.trim().is_empty()) {
            assert!(
                carried.contains(&squashed(line)),
                "{args:?} dropped {line:?} from its frame:\n{pretty}"
            );
        }
    }
}

/// Both confirm sites refuse the same way with nobody to ask, and neither
/// writes anything first. One guard, one sentence, both call sites.
#[test]
fn a_confirm_with_nobody_to_ask_refuses_before_writing() {
    for args in [
        vec!["apply", "--scope", "project"],
        vec!["add", "--skill", "tidy"],
    ] {
        let Ran {
            output, project, ..
        } = ran("plain", &args);
        let printed = said(&output);
        assert!(
            printed.contains("refusing to apply without --yes in a non-interactive session"),
            "{args:?} did not refuse: {printed}"
        );
        assert!(!output.status.success(), "{args:?} succeeded: {printed}");
        assert!(
            !project.join(".claude/skills/tidy").exists(),
            "{args:?} wrote before it asked: {printed}"
        );
    }
}
