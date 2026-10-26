//! The one judge of what a session's screen says. Every reader that must
//! tell a working session from an idle, asking, walled or exited one asks
//! here. The patterns are the installed harness drawings orch measured;
//! each is read over the slice below the last user turn, so a banner the
//! session has since taken another turn past is scrollback, not state.

use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::LazyLock;

use crate::harness::Harness;

#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case", tag = "state")]
pub enum State {
    /// Live input is drawn and nothing else is in flight.
    Idle,
    /// A turn is running.
    Working,
    /// A dialog waits on an answer: a permission, trust or model prompt.
    Asking,
    /// Codex's model-switch reminder is up over a dialog row.
    RateLimitSwitch,
    /// The account refused the turn.
    Walled { kind: WallKind, banner: String },
    /// Nothing but shells run under the pane.
    Exited,
    /// The screen settles nothing.
    Unjudged { cause: String },
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum WallKind {
    Usage,
    Auth,
}

/// What a process read says about the pane's harness, supplied by the
/// caller that holds the process table.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum ProcessReading {
    /// Nothing but shells: the harness is gone.
    ShellsOnly,
    /// A harness process runs; the screen decides its turn state.
    HarnessUp,
    /// The table could not be read.
    Unread,
}

static WORKING: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"to interrupt|to run in background|↓ [0-9][0-9.]*[kKmM]? tokens|Jump to bottom \(|esc interrupt").unwrap()
});
static ASKING: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(❯|›) [0-9]+\. |Do you want to|Enter to select|Esc to cancel").unwrap()
});
static RATE_LIMIT_SWITCH: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*Switch to .+ for lower credit usage\?\s*$").unwrap());
static DIALOG_ROW: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(❯|›) [0-9]+\. ").unwrap());
static USAGE_LIMIT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"You.(ve|re) (hit|reached) your [a-z ]*limit|[Uu]sage limit reached|hit usage limits|out of (usage )?credits|/usage-credits").unwrap()
});
static AUTH_FAILURE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^[\s\u{a0}]*(⎿[\s\u{a0}]*|■\s*|✗\s*)?(Login expired.*Please run /login|Not logged in.*Please run /login|Your access token could not be refreshed|You must be logged in to send messages\. Please run /login)").unwrap()
});
static MARKER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^❯|^›").unwrap());
/// Claude Code's composer: the marker then U+00A0.
static CLAUDE_COMPOSER: LazyLock<Regex> = LazyLock::new(|| Regex::new("^❯\u{a0}").unwrap());
static CODEX_MARKER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^› ").unwrap());
/// Copilot's composer is the marker line with a rule drawn under it.
static FRAME_RULE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[─━]{10,}\s*$").unwrap());
static TRUST_DIALOG: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"Do you trust the files in this (folder|directory)").unwrap());
/// Pi's editor border while a turn runs: a spinner glyph and the word.
static PI_WORKING_BORDER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^── \S+ Working ─+\s*$").unwrap());
/// Pi's prompt line under the editor: the working directory, then the
/// branch in parentheses when there is one.
static PI_PROMPT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[~/]\S*( \(.+\))?\s*$").unwrap());
/// Pi's footer carries the context token `<used>%/<window>` from the first
/// draw; the token counts before it and the model after it come and go.
static PI_FOOTER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(^|\s)[0-9]+(\.[0-9]+)?%/[0-9]+(\.[0-9]+)?[kKmMgG]?(\s|$)").unwrap()
});

/// The StopFailure error kinds that refuse every turn on the account until
/// a person acts: a login wall, never a usage mark.
pub const AUTH_FAILURE_ERRORS: [&str; 4] = [
    "authentication_failed",
    "oauth_org_not_allowed",
    "account_on_hold",
    "billing_error",
];

/// The lines strictly below the last user turn, or the whole screen when it
/// holds none. The boundary is the last marker line unless that line is the
/// live input the session sits at, in which case it is the marker before.
pub fn below_last_turn(screen: &str) -> String {
    let lines: Vec<&str> = screen.lines().collect();
    let markers: Vec<usize> = lines
        .iter()
        .enumerate()
        .filter(|(_, l)| MARKER.is_match(l))
        .map(|(i, _)| i)
        .collect();
    let Some(&last) = markers.last() else {
        return screen.to_owned();
    };
    let framed = last + 1 < lines.len() && FRAME_RULE.is_match(lines[last + 1]);
    let live = last == lines.len() - 1
        || framed
        || CLAUDE_COMPOSER.is_match(lines[last])
        || CODEX_MARKER.is_match(lines[last])
        || DIALOG_ROW.is_match(lines[last]);
    let turn = if live {
        markers.len().checked_sub(2).map(|i| markers[i])
    } else {
        Some(last)
    };
    let first = turn.map(|t| t + 1).unwrap_or(0);
    lines[first..].join("\n")
}

pub fn is_working(slice: &str) -> bool {
    WORKING.is_match(slice)
}

/// Whether Pi's editor border says a turn is running.
pub fn pi_working(slice: &str) -> bool {
    slice.lines().any(|l| PI_WORKING_BORDER.is_match(l))
}

/// Whether Pi's default composer is drawn and open: the last three drawn
/// lines are the editor's bottom rule, the prompt line and the footer.
///
/// Pi's native interface for turn state is its session file, which ends a
/// turn with an assistant row whose `stopReason` is `stop`. That file cannot
/// show whether the composer is drawn, and delivery is a pane paste into
/// that composer, so the pane read stands for the one question the file
/// cannot answer. Pi 1.4.0 draws no `❯`/`›` marker, so the marker rule the
/// other harnesses use never fires here.
pub fn pi_composer_drawn(slice: &str) -> bool {
    let drawn: Vec<&str> = slice.lines().filter(|l| !l.trim().is_empty()).collect();
    let n = drawn.len();
    n >= 3
        && FRAME_RULE.is_match(drawn[n - 3])
        && PI_PROMPT.is_match(drawn[n - 2])
        && PI_FOOTER.is_match(drawn[n - 1])
}

pub fn trust_dialog(screen: &str) -> Option<&str> {
    screen.lines().find(|l| TRUST_DIALOG.is_match(l))
}

/// The account's banner in the slice, empty when the harness drew none or
/// a turn is in flight (limit-shaped text mid-turn is the session's own).
pub fn limit_banner(slice: &str) -> Option<String> {
    if is_working(slice) {
        return None;
    }
    let lines: Vec<&str> = slice
        .lines()
        .filter(|l| USAGE_LIMIT.is_match(l) || AUTH_FAILURE.is_match(l))
        .collect();
    if lines.is_empty() {
        None
    } else {
        Some(lines.join("\n"))
    }
}

pub fn is_auth_failure(banner: &str, error_kind: Option<&str>) -> bool {
    if let Some(kind) = error_kind
        && AUTH_FAILURE_ERRORS.contains(&kind)
    {
        return true;
    }
    banner.lines().any(|l| AUTH_FAILURE.is_match(l))
}

/// Judge one captured pane drawn by `harness`. `process` is the caller's
/// process reading, and `account_room` whether the account the session
/// spends was read as having room (`Some(true)`), walled (`Some(false)`) or
/// unread (`None`).
pub fn judge(
    screen: &str,
    harness: Harness,
    process: ProcessReading,
    account_room: Option<bool>,
) -> State {
    if process == ProcessReading::ShellsOnly {
        return State::Exited;
    }
    let slice = below_last_turn(screen);
    if let Some(banner) = limit_banner(&slice) {
        if is_auth_failure(&banner, None) {
            return State::Walled {
                kind: WallKind::Auth,
                banner,
            };
        }
        match account_room {
            None | Some(false) => {
                return State::Walled {
                    kind: WallKind::Usage,
                    banner,
                };
            }
            Some(true) => {}
        }
    }
    if ASKING.is_match(&slice) {
        if slice.lines().any(|l| RATE_LIMIT_SWITCH.is_match(l))
            && slice.lines().any(|l| DIALOG_ROW.is_match(l))
        {
            return State::RateLimitSwitch;
        }
        return State::Asking;
    }
    if is_working(&slice) {
        return State::Working;
    }
    let idle = match harness {
        Harness::Pi => {
            if pi_working(&slice) {
                return State::Working;
            }
            pi_composer_drawn(&slice)
        }
        Harness::Claude | Harness::Codex | Harness::Copilot => {
            slice.lines().any(|l| MARKER.is_match(l))
        }
    };
    if idle {
        return State::Idle;
    }
    State::Unjudged {
        cause: match (process, harness) {
            (ProcessReading::Unread, _) => "process-unread".to_owned(),
            (_, Harness::Pi) => "composer-undrawn".to_owned(),
            (_, Harness::Claude | Harness::Codex | Harness::Copilot) => "no-marker".to_owned(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_claude_screen_at_its_composer_is_idle() {
        let screen = "❯ do the thing\n● Done.\n\n❯\u{a0}\n  ? for shortcuts";
        assert_eq!(
            judge(screen, Harness::Claude, ProcessReading::HarnessUp, None),
            State::Idle
        );
    }

    #[test]
    fn a_streaming_token_counter_is_working() {
        let screen = "❯ do the thing\n✻ Thinking… (esc to interrupt · ↓ 1.2k tokens)";
        assert_eq!(
            judge(screen, Harness::Claude, ProcessReading::HarnessUp, None),
            State::Working
        );
    }

    #[test]
    fn a_numbered_dialog_row_is_asking() {
        let screen = "❯ run tests\nDo you want to proceed?\n❯ 1. Yes\n  2. No\nEnter to select";
        assert_eq!(
            judge(screen, Harness::Claude, ProcessReading::HarnessUp, None),
            State::Asking
        );
    }

    #[test]
    fn a_usage_banner_below_the_last_turn_is_a_usage_wall_unless_the_account_has_room() {
        let screen = "❯ work\nYou've hit your session limit · resets 9:50am\n❯\u{a0}";
        assert!(matches!(
            judge(screen, Harness::Claude, ProcessReading::HarnessUp, None),
            State::Walled {
                kind: WallKind::Usage,
                ..
            }
        ));
        assert_eq!(
            judge(
                screen,
                Harness::Claude,
                ProcessReading::HarnessUp,
                Some(true)
            ),
            State::Idle
        );
    }

    #[test]
    fn a_login_banner_is_an_auth_wall_whatever_the_account_reads() {
        let screen = "❯ work\n■ Login expired. Please run /login\n❯\u{a0}";
        assert!(matches!(
            judge(
                screen,
                Harness::Claude,
                ProcessReading::HarnessUp,
                Some(true)
            ),
            State::Walled {
                kind: WallKind::Auth,
                ..
            }
        ));
    }

    #[test]
    fn a_banner_the_session_took_another_turn_past_is_scrollback() {
        let screen = "❯ first\nYou've hit your session limit\n❯ second\n● ok\n❯\u{a0}";
        assert_eq!(
            judge(screen, Harness::Claude, ProcessReading::HarnessUp, None),
            State::Idle
        );
    }

    #[test]
    fn shells_only_is_exited_and_a_markerless_screen_is_unjudged() {
        assert_eq!(
            judge(
                "anything",
                Harness::Claude,
                ProcessReading::ShellsOnly,
                None
            ),
            State::Exited
        );
        assert!(matches!(
            judge(
                "no markers here",
                Harness::Claude,
                ProcessReading::HarnessUp,
                None
            ),
            State::Unjudged { .. }
        ));
    }

    #[test]
    fn a_codex_composer_line_is_idle_and_its_slice_excludes_the_live_marker() {
        let screen = "› first turn\nsome answer\n› ";
        assert_eq!(
            judge(screen, Harness::Codex, ProcessReading::HarnessUp, None),
            State::Idle
        );
        assert_eq!(below_last_turn(screen), "some answer\n› ");
    }

    const PI_RULE: &str = "────────────────────────────────────────────────";
    const PI_PROMPT_LINE: &str = "~/dev/work (main)";

    #[test]
    fn a_pi_screen_with_the_rule_prompt_and_footer_drawn_last_is_idle() {
        let screen = format!(
            " Create the file\n done\n{PI_RULE}\n{PI_RULE}\n{PI_PROMPT_LINE}\n↑3.9k ↓115 R11k CH99.0% $0.011 0.4%/1.0M        (vercel-ai-gateway) zai/glm-5.3-fast • medium\n\n"
        );
        assert_eq!(
            judge(&screen, Harness::Pi, ProcessReading::HarnessUp, None),
            State::Idle
        );
        // The same footer before any turn, with only the context token.
        let fresh = format!("{PI_RULE}\n{PI_RULE}\n{PI_PROMPT_LINE}\n0.4%/1.0M\n");
        assert_eq!(
            judge(&fresh, Harness::Pi, ProcessReading::HarnessUp, None),
            State::Idle
        );
    }

    #[test]
    fn a_pi_working_border_is_working_even_with_the_composer_triple_below_it() {
        let screen = format!(
            " Create the file\n── ⠹ Working {PI_RULE}\n{PI_RULE}\n{PI_PROMPT_LINE}\n0.4%/1.0M\n"
        );
        assert_eq!(
            judge(&screen, Harness::Pi, ProcessReading::HarnessUp, None),
            State::Working
        );
    }

    #[test]
    fn a_pi_screen_without_the_composer_is_unjudged_and_the_marker_rule_stays_off_pi() {
        let screen = format!("{PI_RULE}\n{PI_PROMPT_LINE}\n some output\n");
        assert_eq!(
            judge(&screen, Harness::Pi, ProcessReading::HarnessUp, None),
            State::Unjudged {
                cause: "composer-undrawn".to_owned()
            }
        );
        // A Claude-shaped composer is not Pi's; under Pi it settles nothing.
        assert!(matches!(
            judge(
                "❯ work\n❯\u{a0}",
                Harness::Pi,
                ProcessReading::HarnessUp,
                None
            ),
            State::Unjudged { .. }
        ));
        // And Pi's composer settles nothing for a harness that draws markers.
        let pi = format!("{PI_RULE}\n{PI_PROMPT_LINE}\n0.4%/1.0M\n");
        assert!(matches!(
            judge(&pi, Harness::Claude, ProcessReading::HarnessUp, None),
            State::Unjudged { .. }
        ));
    }

    #[test]
    fn the_trust_dialog_is_named_over_the_whole_capture() {
        assert!(trust_dialog("Do you trust the files in this folder?\n  1. Yes").is_some());
        assert!(trust_dialog("nothing").is_none());
    }
}
