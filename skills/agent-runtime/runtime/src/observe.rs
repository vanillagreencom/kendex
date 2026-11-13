//! The one judge of what a session's pane says. Every reader that must
//! tell a working session from an idle, asking, walled or exited one asks
//! here. The patterns are the installed harness drawings orch measured;
//! each is read over the slice below the last user turn, so a banner the
//! session has since taken another turn past is scrollback, not state.
//!
//! `idle` is the one reading that authorizes a delivery, so it needs two
//! facts, not one: the process holding the pane's terminal is the harness
//! (its identity read, and equal to the recorded one when the caller has
//! one), and the harness's own composer is drawn. A shell at its prompt
//! draws lines a marker rule can match, before the harness has started or
//! after it has gone, and never reads idle whatever it draws.

// Every process reading is matched variant by variant.
#![deny(clippy::wildcard_enum_match_arm)]

use regex::Regex;
use serde::{Deserialize, Serialize};
use std::sync::LazyLock;

use crate::harness::Harness;
use crate::process::{self, Identity, Row};
use crate::reading::{Reading, Unreadable};

#[must_use]
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

/// What the process table says about the pane: who holds its terminal.
/// [`foreground`] reads it from a live pane; the `judge` verb takes one of
/// the two readings a screen file cannot supply.
#[must_use]
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "reading", rename_all = "kebab-case")]
pub enum ProcessReading {
    /// Nothing but shells run under the pane: the harness is gone.
    ShellsOnly,
    /// The caller asserts the harness holds the pane and the screen alone
    /// decides: the `judge` verb's reading of a captured screen. A live
    /// pane is read with [`foreground`] instead.
    HarnessUp,
    /// The harness holds the pane's terminal, under this identity.
    Harness { identity: Identity },
    /// A shell holds the terminal: the harness has not replaced it yet, or
    /// a shell it started is in the foreground.
    ForegroundShell { name: String },
    /// Another process holds the terminal: not a shell and not the harness,
    /// or the harness under an identity other than the recorded one.
    ForegroundOther { name: String, pid: u32 },
    /// The table, the pane's process or the identity it needed could not be
    /// read; `cause` is the reader's word for what failed.
    Unread { cause: &'static str },
}

/// The identity reads [`classify`] makes once it has the table: the kernel
/// in production, planted readings under test.
trait Identities {
    fn identity(&self, pid: u32) -> Reading<Identity>;
    fn still_runs(&self, id: &Identity) -> Reading<Identity>;
}

struct Kernel;

impl Identities for Kernel {
    fn identity(&self, pid: u32) -> Reading<Identity> {
        process::identity(pid)
    }
    fn still_runs(&self, id: &Identity) -> Reading<Identity> {
        process::still_runs(id)
    }
}

/// Read who holds the terminal of the pane whose process is `pane_pid`: the
/// members of the foreground process group. The harness holds the pane when
/// one of its own processes under the pane is a member, the exec'd harness
/// itself or a harness a non-interactive shell wrapper waits on; `owns`
/// names the harness's processes (`Harness::owns_process_of`). With
/// `recorded`, only that exact identity is the harness, and no other
/// process is ever selected in its place; without one, the
/// nearest harness-named member is, and its identity is read for the caller
/// to record. A group of shells alone is `ShellsOnly` when no harness
/// process runs under the pane at all, else `ForegroundShell`. A table, a
/// pane process or an identity that could not be read is `Unread` with its
/// cause, never a reading of absence.
pub fn foreground(
    pane_pid: u32,
    owns: &dyn Fn(&str) -> bool,
    recorded: Option<&Identity>,
) -> ProcessReading {
    let group = match process::foreground_group(pane_pid) {
        Reading::Live(Some(group)) => group,
        Reading::Live(None) => {
            return ProcessReading::Unread {
                cause: "no-terminal",
            };
        }
        Reading::Gone => {
            return ProcessReading::Unread {
                cause: "pane-process-gone",
            };
        }
        Reading::Unreadable { cause } => return ProcessReading::Unread { cause },
    };
    let rows = match process::table() {
        Ok(rows) => rows,
        Err(Unreadable { cause }) => return ProcessReading::Unread { cause },
    };
    classify(&rows, group, pane_pid, owns, recorded, &Kernel)
}

/// Who holds the pane's terminal, from one table read: the members of
/// `group`, the harness-named processes under `pane_pid`, and the identity
/// reads `ids` answers.
fn classify(
    rows: &[Row],
    group: u32,
    pane_pid: u32,
    owns: &dyn Fn(&str) -> bool,
    recorded: Option<&Identity>,
    ids: &dyn Identities,
) -> ProcessReading {
    let members: Vec<&Row> = rows.iter().filter(|r| r.pgrp == group).collect();
    if members.is_empty() {
        return ProcessReading::Unread {
            cause: "foreground-group-empty",
        };
    }
    let below = process::below(rows, pane_pid, owns);
    let held: Vec<&Row> = below
        .iter()
        .filter_map(|(_, pid)| members.iter().copied().find(|m| m.pid == *pid))
        .collect();
    if let Some(recorded) = recorded {
        // Only the recorded identity is the harness: in the foreground
        // group, and still the process the record names.
        if let Some(member) = members.iter().find(|m| m.pid == recorded.pid) {
            return match ids.still_runs(recorded) {
                Reading::Live(_) => ProcessReading::Harness {
                    identity: recorded.clone(),
                },
                Reading::Gone => ProcessReading::ForegroundOther {
                    name: member.name.clone(),
                    pid: member.pid,
                },
                Reading::Unreadable { cause } => ProcessReading::Unread { cause },
            };
        }
        // A harness-named member that is not the recorded process holds the
        // terminal under another identity: named, never adopted.
        if let Some(other) = held.first() {
            return ProcessReading::ForegroundOther {
                name: other.name.clone(),
                pid: other.pid,
            };
        }
    } else if let Some(nearest) = held.first() {
        return match ids.identity(nearest.pid) {
            Reading::Live(identity) => ProcessReading::Harness { identity },
            Reading::Gone => ProcessReading::Unread {
                cause: "harness-exited-mid-read",
            },
            Reading::Unreadable { cause } => ProcessReading::Unread { cause },
        };
    }
    // The group's leader names it; a leader that exited leaves the first
    // member to.
    let leader = members
        .iter()
        .find(|m| m.pid == group)
        .unwrap_or(&members[0]);
    if members.iter().all(|m| process::is_shell(&m.name)) {
        return if below.is_empty() {
            ProcessReading::ShellsOnly
        } else {
            ProcessReading::ForegroundShell {
                name: leader.name.clone(),
            }
        };
    }
    ProcessReading::ForegroundOther {
        name: leader.name.clone(),
        pid: leader.pid,
    }
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
    Regex::new(r"You.(ve|re) (hit|reached) your [a-z ]*limit|[Uu]sage limit reached|hit usage limits|out of (usage )?credits").unwrap()
});
static AUTH_FAILURE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^[\s\u{a0}]*(⎿[\s\u{a0}]*|■\s*|✗\s*)?(Login expired.*Please run /login|Not logged in.*Please run /login|Your access token could not be refreshed|You must be logged in to send messages\. Please run /login)").unwrap()
});
/// A user-turn marker: Claude's and Copilot's `❯`, Codex's `›`. A submitted
/// turn is echoed as the marker, a space and the text; the live composer is
/// the harness's own drawing below.
static MARKER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^❯|^›").unwrap());
/// Claude Code's composer: the marker then U+00A0, the padding it gives the
/// input line and no shell prompt or echoed turn carries.
static CLAUDE_COMPOSER: LazyLock<Regex> = LazyLock::new(|| Regex::new("^❯\u{a0}").unwrap());
/// Codex's composer line, `› ` then its placeholder or the draft.
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

/// Codex's refusal of one turn for the selected model's capacity
/// (`lane-state.sh` `MODEL_CAPACITY`), drawn above the composer the lane
/// then sits at: the one marker that tells this idle from a finished turn's.
static CODEX_CAPACITY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"Selected model is at capacity").unwrap());

/// Whether a Codex slice judged idle sits at its composer under the capacity
/// refusal: the refusal line and the marker line are both drawn in it.
pub fn codex_capacity_refused(slice: &str) -> bool {
    slice.lines().any(|l| CODEX_CAPACITY.is_match(l))
        && slice.lines().any(|l| CODEX_MARKER.is_match(l))
}

/// Codex's line for a turn its provider's API refused, as a real pane drew
/// it: the error glyph at the line's start, then the provider's JSON error
/// body. An answer quoting the words draws them indented.
static CODEX_API_ERROR: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r#"^■ \{"detail":"#).unwrap());

/// Whether a Codex slice judged idle sits at its composer after an API error
/// ended its turn: the error line and the marker line are both drawn in it.
pub fn codex_api_error(slice: &str) -> bool {
    slice.lines().any(|l| CODEX_API_ERROR.is_match(l))
        && slice.lines().any(|l| CODEX_MARKER.is_match(l))
}

/// Whether a wall screen is the live process's: a screen first seen before
/// the process holding the pane started was drawn by an earlier process and
/// is scrollback, not a wall.
#[must_use]
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "age", rename_all = "kebab-case")]
pub enum WallAge {
    /// First seen at or after the live process's start.
    Current,
    /// First seen before the live process's start.
    Older,
    /// The process's start could not be read, so the wall is unjudged.
    Unjudged { cause: &'static str },
}

/// The wall first seen at epoch second `first_seen`, against the live
/// process's start as [`start_epoch`] read it.
pub fn wall_age(first_seen: u64, started: &Reading<u64>) -> WallAge {
    match started {
        Reading::Live(start) if first_seen >= *start => WallAge::Current,
        Reading::Live(_) => WallAge::Older,
        Reading::Gone => WallAge::Unjudged {
            cause: "process-gone",
        },
        Reading::Unreadable { cause } => WallAge::Unjudged { cause },
    }
}

/// `USER_HZ`, 100 on every Linux architecture (`include/asm-generic/
/// param.h`): the unit of the `ticks:` start the identity reader records.
const USER_HZ: u64 = 100;

/// The epoch second the identity's process started, confirmed live first:
/// Linux's boot time (`/proc/stat` `btime`) plus the recorded start ticks.
/// Both are truncated to the second, so the moment is never later than the
/// true one, and a wall first seen in the same second reads current. A host
/// without the `ticks:` form, or a `/proc/stat` that cannot be read, is
/// unreadable, never a moment.
pub fn start_epoch(identity: &Identity) -> Reading<u64> {
    match process::still_runs(identity) {
        Reading::Live(_) => {}
        Reading::Gone => return Reading::Gone,
        Reading::Unreadable { cause } => return Reading::Unreadable { cause },
    }
    let Some(ticks) = identity
        .start
        .strip_prefix("ticks:")
        .and_then(|t| t.parse::<u64>().ok())
    else {
        return Reading::Unreadable {
            cause: "start-form",
        };
    };
    let Ok(stat) = std::fs::read_to_string("/proc/stat") else {
        return Reading::Unreadable {
            cause: "boot-time-unreadable",
        };
    };
    let Some(btime) = stat
        .lines()
        .find_map(|l| l.strip_prefix("btime "))
        .and_then(|b| b.trim().parse::<u64>().ok())
    else {
        return Reading::Unreadable {
            cause: "boot-time-unreadable",
        };
    };
    Reading::Live(btime + ticks / USER_HZ)
}

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

/// Whether the harness's own composer is drawn in the slice. Each rule is
/// the harness's live input line as the native probe
/// (`tests/native/thin-path.sh`) captured it at rest: Claude's
/// marker padded with U+00A0, Codex's `› ` line, Copilot's marker line
/// framed by a rule under it, Pi's rule, prompt and footer. A shell prompt
/// that happens to start with the marker, `❯ cd … && exec claude …` as the
/// pane's shell echoes the launch line, matches none of them. Each rule
/// reads a drawn row: the screen arrives row by row (`host::tmux::capture`),
/// so an echo that fills its last row exactly stays apart from the composer
/// drawn after it.
pub fn composer_drawn(slice: &str, harness: Harness) -> bool {
    let lines: Vec<&str> = slice.lines().collect();
    match harness {
        Harness::Claude => lines.iter().any(|l| CLAUDE_COMPOSER.is_match(l)),
        Harness::Codex => lines.iter().any(|l| CODEX_MARKER.is_match(l)),
        Harness::Copilot => lines
            .windows(2)
            .any(|w| MARKER.is_match(w[0]) && FRAME_RULE.is_match(w[1])),
        Harness::Pi => pi_composer_drawn(slice),
    }
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

/// Judge one captured pane drawn by `harness`. `process` is who holds the
/// pane's terminal, and `account_room` whether the account the session
/// spends was read as having room (`Some(true)`), walled (`Some(false)`) or
/// unread (`None`). Only a pane the harness holds, or that the caller
/// asserts it holds, can read `idle`; a shell or another process in the
/// foreground settles nothing, whatever the screen shows.
pub fn judge(
    screen: &str,
    harness: Harness,
    process: &ProcessReading,
    account_room: Option<bool>,
) -> State {
    match process {
        ProcessReading::ShellsOnly => return State::Exited,
        ProcessReading::ForegroundShell { .. } | ProcessReading::ForegroundOther { .. } => {
            return State::Unjudged {
                cause: "foreground-not-harness".to_owned(),
            };
        }
        ProcessReading::HarnessUp
        | ProcessReading::Harness { .. }
        | ProcessReading::Unread { .. } => {}
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
    if is_working(&slice) || (harness == Harness::Pi && pi_working(&slice)) {
        return State::Working;
    }
    if composer_drawn(&slice, harness) {
        return match process {
            ProcessReading::HarnessUp | ProcessReading::Harness { .. } => State::Idle,
            // A drawn composer with the process table unread: the second
            // fact idle needs is missing.
            ProcessReading::Unread { .. }
            | ProcessReading::ShellsOnly
            | ProcessReading::ForegroundShell { .. }
            | ProcessReading::ForegroundOther { .. } => State::Unjudged {
                cause: "process-unread".to_owned(),
            },
        };
    }
    State::Unjudged {
        cause: match (process, harness) {
            (ProcessReading::Unread { .. }, _) => "process-unread".to_owned(),
            (_, Harness::Pi) => "composer-undrawn".to_owned(),
            (_, Harness::Claude | Harness::Codex | Harness::Copilot) => "no-marker".to_owned(),
        },
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn a_usage_banner_below_the_last_turn_is_a_usage_wall_unless_the_account_has_room() {
        let screen = "❯ work\nYou've hit your session limit · resets 9:50am\n❯\u{a0}";
        assert!(matches!(
            judge(screen, Harness::Claude, &ProcessReading::HarnessUp, None),
            State::Walled {
                kind: WallKind::Usage,
                ..
            }
        ));
        assert_eq!(
            judge(
                screen,
                Harness::Claude,
                &ProcessReading::HarnessUp,
                Some(true)
            ),
            State::Idle
        );
        // Claude Code's warning footer under its composer names the usage
        // command and the limit it nears, never a limit reached: no banner.
        let warned = "❯ work\n❯\u{a0}\nYou've used 92% of your weekly limit · resets Nov 13, 5am · /usage-credits to keep using Claude Code";
        assert_eq!(
            judge(warned, Harness::Claude, &ProcessReading::HarnessUp, None),
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
                &ProcessReading::HarnessUp,
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
            judge(screen, Harness::Claude, &ProcessReading::HarnessUp, None),
            State::Idle
        );
    }

    #[test]
    fn shells_only_is_exited_and_a_markerless_screen_is_unjudged() {
        assert_eq!(
            judge(
                "anything",
                Harness::Claude,
                &ProcessReading::ShellsOnly,
                None
            ),
            State::Exited
        );
        assert!(matches!(
            judge(
                "no markers here",
                Harness::Claude,
                &ProcessReading::HarnessUp,
                None
            ),
            State::Unjudged { .. }
        ));
    }

    /// A shell at its prompt, or any other process, in the
    /// pane's foreground never reads idle, whatever the screen draws; a
    /// drawn composer with the process table unread is not idle either.
    #[test]
    fn a_foreground_that_is_not_the_harness_never_reads_idle_whatever_it_draws() {
        let screen = "❯ do the thing\n● Done.\n\n❯\u{a0}\n  ? for shortcuts";
        let rows = [
            ProcessReading::ForegroundShell {
                name: "fish".to_owned(),
            },
            ProcessReading::ForegroundOther {
                name: "less".to_owned(),
                pid: 7,
            },
        ];
        for reading in &rows {
            assert_eq!(
                judge(screen, Harness::Claude, reading, None),
                State::Unjudged {
                    cause: "foreground-not-harness".to_owned()
                },
                "{reading:?}"
            );
        }
        assert_eq!(
            judge(
                screen,
                Harness::Claude,
                &ProcessReading::Unread {
                    cause: "stat-unreadable"
                },
                None
            ),
            State::Unjudged {
                cause: "process-unread".to_owned()
            }
        );
        let held = ProcessReading::Harness {
            identity: Identity {
                pid: 7,
                start: "ticks:1".to_owned(),
            },
        };
        assert_eq!(judge(screen, Harness::Claude, &held, None), State::Idle);
    }

    /// Planted identity readings for [`classify`]: each pid's reading, and
    /// `still_runs` answered from the same table by pid and start.
    struct Planted(Vec<(u32, Reading<Identity>)>);

    impl Identities for Planted {
        fn identity(&self, pid: u32) -> Reading<Identity> {
            self.0
                .iter()
                .find(|(p, _)| *p == pid)
                .map(|(_, r)| r.clone())
                .unwrap_or(Reading::Gone)
        }
        fn still_runs(&self, id: &Identity) -> Reading<Identity> {
            match self.identity(id.pid) {
                Reading::Live(now) if now == *id => Reading::Live(now),
                Reading::Live(_) | Reading::Gone => Reading::Gone,
                Reading::Unreadable { cause } => Reading::Unreadable { cause },
            }
        }
    }

    fn row(pid: u32, ppid: u32, pgrp: u32, name: &str) -> Row {
        Row {
            pid,
            ppid,
            pgrp,
            name: name.to_owned(),
        }
    }

    fn id(pid: u32, start: &str) -> Identity {
        Identity {
            pid,
            start: start.to_owned(),
        }
    }

    /// With a recorded identity, the judge confirms that
    /// identity's foreground state and selects no other process. Another
    /// harness-named process holding the terminal is named as other, a
    /// recorded pid now carrying another process is other, and an identity
    /// that cannot be read is unread with its cause. Without a record, the
    /// nearest harness-named member is read and its identity returned.
    #[test]
    fn a_recorded_identity_is_confirmed_in_the_foreground_and_never_replaced() {
        // The pane shell 20 waits on harness 30, whose group 30 holds the
        // terminal; 31 is a second harness-named process in that group.
        let rows = [
            row(20, 10, 20, "bash"),
            row(30, 20, 30, "claude"),
            row(31, 30, 30, "claude"),
        ];
        let owns = |name: &str| name == "claude";
        let live = Planted(vec![
            (30, Reading::Live(id(30, "ticks:3"))),
            (31, Reading::Live(id(31, "ticks:4"))),
        ]);
        let recorded = id(30, "ticks:3");
        assert_eq!(
            classify(&rows, 30, 20, &owns, Some(&recorded), &live),
            ProcessReading::Harness {
                identity: recorded.clone()
            }
        );
        // The record names 99, which is not in the group: the harness-named
        // member 30 is other, never adopted as the harness.
        assert_eq!(
            classify(&rows, 30, 20, &owns, Some(&id(99, "ticks:9")), &live),
            ProcessReading::ForegroundOther {
                name: "claude".to_owned(),
                pid: 30
            }
        );
        // The recorded pid is in the group under another start: other.
        assert_eq!(
            classify(&rows, 30, 20, &owns, Some(&id(30, "ticks:0")), &live),
            ProcessReading::ForegroundOther {
                name: "claude".to_owned(),
                pid: 30
            }
        );
        // The recorded identity cannot be read: unread with the cause.
        let unread = Planted(vec![(
            30,
            Reading::Unreadable {
                cause: "stat-unreadable",
            },
        )]);
        assert_eq!(
            classify(&rows, 30, 20, &owns, Some(&recorded), &unread),
            ProcessReading::Unread {
                cause: "stat-unreadable"
            }
        );
        // No record: the nearest harness-named member is the harness.
        assert_eq!(
            classify(&rows, 30, 20, &owns, None, &live),
            ProcessReading::Harness {
                identity: id(30, "ticks:3")
            }
        );
        assert_eq!(
            classify(&rows, 30, 20, &owns, None, &unread),
            ProcessReading::Unread {
                cause: "stat-unreadable"
            }
        );
        // A shell holds the terminal: with the harness below, a foreground
        // shell; with none, shells only.
        let shell_rows = [row(20, 10, 20, "bash"), row(30, 20, 30, "claude")];
        assert_eq!(
            classify(&shell_rows, 20, 20, &owns, Some(&recorded), &live),
            ProcessReading::ForegroundShell {
                name: "bash".to_owned()
            }
        );
        assert_eq!(
            classify(&shell_rows[..1], 20, 20, &owns, Some(&recorded), &live),
            ProcessReading::ShellsOnly
        );
    }

    /// The pane's shell echoing the launch line starts with the marker and
    /// is none of the three composers; each harness's own composer is.
    #[test]
    fn a_shell_prompt_echoing_the_launch_line_is_no_composer_and_each_harness_s_own_is() {
        let echo = "❯ cd /work && exec env CLAUDE_CONFIG_DIR=/h claude --model opus\n";
        for harness in [Harness::Claude, Harness::Codex, Harness::Copilot] {
            assert!(!composer_drawn(echo, harness), "{harness:?}");
            assert!(matches!(
                judge(echo, harness, &ProcessReading::HarnessUp, None),
                State::Unjudged { .. }
            ));
        }
        assert!(composer_drawn("❯\u{a0}\n", Harness::Claude));
        assert!(!composer_drawn("❯\u{a0}\n", Harness::Codex));
        assert!(composer_drawn(
            "› Ask Codex to do anything\n",
            Harness::Codex
        ));
        assert!(!composer_drawn(
            "› Ask Codex to do anything\n",
            Harness::Claude
        ));
        let rule = "─".repeat(40);
        let copilot = format!(" ~/work [⎇ main]\n{rule}\n❯ \n{rule}\n");
        assert!(composer_drawn(&copilot, Harness::Copilot));
        assert!(!composer_drawn("❯ \n", Harness::Copilot), "unframed");
        assert!(!composer_drawn(&copilot, Harness::Claude));
        assert_eq!(
            judge(&copilot, Harness::Copilot, &ProcessReading::HarnessUp, None),
            State::Idle
        );
    }

    #[test]
    fn a_codex_composer_line_is_idle_and_its_slice_excludes_the_live_marker() {
        let screen = "› first turn\nsome answer\n› ";
        assert_eq!(
            judge(screen, Harness::Codex, &ProcessReading::HarnessUp, None),
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
            judge(&screen, Harness::Pi, &ProcessReading::HarnessUp, None),
            State::Idle
        );
        // The same footer before any turn, with only the context token.
        let fresh = format!("{PI_RULE}\n{PI_RULE}\n{PI_PROMPT_LINE}\n0.4%/1.0M\n");
        assert_eq!(
            judge(&fresh, Harness::Pi, &ProcessReading::HarnessUp, None),
            State::Idle
        );
    }

    #[test]
    fn a_pi_screen_without_the_composer_is_unjudged_and_the_marker_rule_stays_off_pi() {
        let screen = format!("{PI_RULE}\n{PI_PROMPT_LINE}\n some output\n");
        assert_eq!(
            judge(&screen, Harness::Pi, &ProcessReading::HarnessUp, None),
            State::Unjudged {
                cause: "composer-undrawn".to_owned()
            }
        );
        // A Claude-shaped composer is not Pi's; under Pi it settles nothing.
        assert!(matches!(
            judge(
                "❯ work\n❯\u{a0}",
                Harness::Pi,
                &ProcessReading::HarnessUp,
                None
            ),
            State::Unjudged { .. }
        ));
        // And Pi's composer settles nothing for a harness that draws markers.
        let pi = format!("{PI_RULE}\n{PI_PROMPT_LINE}\n0.4%/1.0M\n");
        assert!(matches!(
            judge(&pi, Harness::Claude, &ProcessReading::HarnessUp, None),
            State::Unjudged { .. }
        ));
    }

    /// The Codex capacity refusal reads `idle` through the
    /// judge, and the one marker tells it from a finished turn's idle; a
    /// Claude screen quoting the phrase, with no Codex marker, is not it.
    #[test]
    fn the_codex_capacity_refusal_is_idle_and_its_marker_tells_it_apart() {
        let screen = "› Continue the task.\n\n▲ Selected model is at capacity. Try again later.\n\n› Ask Codex to do anything";
        assert_eq!(
            judge(screen, Harness::Codex, &ProcessReading::HarnessUp, None),
            State::Idle
        );
        let slice = below_last_turn(screen);
        assert!(codex_capacity_refused(&slice));
        assert!(!codex_capacity_refused("› first turn\nsome answer\n› "));
        assert!(!codex_capacity_refused(
            "❯ note\n● Selected model is at capacity, it said.\n❯\u{a0}"
        ));
    }

    /// A Codex turn the provider's API ended reads `idle` through the
    /// judge, and its marker tells it from a finished turn's idle (the five
    /// lines a real pane drew from the error to the footer); an answer
    /// quoting the error indented, and the capacity refusal, are not it.
    #[test]
    fn the_codex_api_error_turn_end_is_idle_and_its_marker_tells_it_apart() {
        let screen = "■ {\"detail\":\"Bad Request\"}\n1 background terminal running · /ps to view · /stop to close\n› Ask Codex to do anything\nContext 61% left · ~/dev/.worktrees/kendex/ken-5026 · GPT-6.1-Sol high · ken-…\n← for agents · ? for shortcuts ⚠ 2 warnings · f2 to view";
        assert_eq!(
            judge(screen, Harness::Codex, &ProcessReading::HarnessUp, None),
            State::Idle
        );
        assert!(codex_api_error(&below_last_turn(screen)));
        assert!(!codex_api_error(
            "› what failed?\n  ■ {\"detail\":\"Bad Request\"} is what the log said\n› Ask Codex to do anything"
        ));
        assert!(!codex_api_error(
            "› Continue the task.\n▲ Selected model is at capacity. Try again later.\n› Ask Codex to do anything"
        ));
    }

    /// A wall first seen before the live process
    /// started is older, one seen at or after it is current, and a start
    /// that cannot be read leaves the wall unjudged, never current.
    #[test]
    fn a_wall_older_than_the_live_process_s_start_is_not_its_wall() {
        assert_eq!(wall_age(100, &Reading::Live(100)), WallAge::Current);
        assert_eq!(wall_age(101, &Reading::Live(100)), WallAge::Current);
        assert_eq!(wall_age(99, &Reading::Live(100)), WallAge::Older);
        assert_eq!(
            wall_age(99, &Reading::Gone),
            WallAge::Unjudged {
                cause: "process-gone"
            }
        );
        assert_eq!(
            wall_age(
                99,
                &Reading::Unreadable {
                    cause: "start-form"
                }
            ),
            WallAge::Unjudged {
                cause: "start-form"
            }
        );
        // This process's own start reads as a moment at or before now, and
        // an identity under another start reads gone.
        let pid = std::process::id();
        let Reading::Live(me) = process::identity(pid) else {
            panic!("this process reads live")
        };
        if me.start.starts_with("ticks:") {
            let Reading::Live(started) = start_epoch(&me) else {
                panic!("a live ticks start reads as an epoch")
            };
            let now = std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_secs();
            assert!(started <= now, "{started} <= {now}");
            assert_eq!(
                start_epoch(&Identity {
                    pid,
                    start: "ticks:1".to_owned()
                }),
                Reading::Gone
            );
        }
        assert_eq!(
            start_epoch(&Identity {
                pid: 2_000_000_000,
                start: "ticks:1".to_owned()
            }),
            Reading::Gone
        );
    }
}
