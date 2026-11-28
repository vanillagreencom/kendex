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
    /// A dialog waits on an answer: a permission, trust or model prompt,
    /// and which first-run question it is where [`Dialog`] names it.
    Asking {
        #[serde(default)]
        dialog: Dialog,
    },
    /// Codex's model-switch reminder is up over a dialog row.
    RateLimitSwitch,
    /// The account refused the turn.
    Walled { kind: WallKind, banner: String },
    /// Nothing but shells run under the pane.
    Exited,
    /// The screen settles nothing.
    Unjudged { cause: String },
}

/// The first-run question an asking screen holds: the step a person takes
/// in the account before a launch onto it can come up unattended. Each
/// named question is a drawing recorded from the harness ([`DIALOGS`]);
/// any other dialog is `other`, which names no step.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Default, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Dialog {
    FolderTrust,
    BypassConsent,
    #[default]
    Other,
}

impl Dialog {
    /// The step a person takes in the account, as a refusal's `step=` names
    /// it; a dialog no recorded drawing names gives the person no step, so
    /// it is the launch's failure, never a step to wait for.
    pub fn step(self) -> Option<&'static str> {
        match self {
            Dialog::FolderTrust => Some("folder-trust"),
            Dialog::BypassConsent => Some("bypass-consent"),
            Dialog::Other => None,
        }
    }
}

/// The first-run questions by a line their drawing carries, read from
/// Claude Code 2.1.330 under a fresh config dir on 2026-11-22 (the
/// captures under the integration tests' `fixtures/claude-*.txt`). The
/// screen is read because no documented interface reports either question:
/// Claude Code's hook events and `Notification` matcher types
/// (https://code.claude.com/docs/en/hooks) name neither dialog, so a hook
/// that runs before trust (the permissions page's "What runs before you
/// trust a folder") still has no event that fires on one. The documented
/// trust key, `hasTrustDialogAccepted`, is what the launch writes ahead
/// (`crate::trust`); this reading names the question when one is still
/// drawn.
const DIALOGS: &[(&str, Dialog)] = &[
    ("Yes, I trust this folder", Dialog::FolderTrust),
    (
        "Claude Code running in Bypass Permissions mode",
        Dialog::BypassConsent,
    ),
];

/// The question an asking `slice` holds.
fn dialog(slice: &str) -> Dialog {
    DIALOGS
        .iter()
        .find(|(line, _)| slice.contains(line))
        .map_or(Dialog::Other, |(_, dialog)| *dialog)
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
/// `recorded`, only that exact identity can be the harness, and no other
/// process is ever selected in its place. A shell is never a harness.
/// Without a recorded identity, the
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
        // A shell can exec under the harness's PID with the same start time.
        // Other names are allowed because a harness can change its title.
        if let Some(member) = members
            .iter()
            .find(|m| m.pid == recorded.pid && !process::is_shell(&m.name))
        {
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
    Regex::new(r"to interrupt|to run in background|↓ [0-9][0-9.]*[kKmM]? tokens|Jump to bottom \(|esc interrupt|ctrl\+c interrupt").unwrap()
});
static ASKING: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(❯|›) [0-9]+\. |Do you want to|Enter to select|Esc to cancel").unwrap()
});
static RATE_LIMIT_SWITCH: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*Switch to .+ for lower credit usage\?\s*$").unwrap());
static DIALOG_ROW: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^(❯|›) [0-9]+\. ").unwrap());
static USAGE_LIMIT: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"You.(ve|re) (hit|reached) your (?:[a-z ]*|5-hour )limit|[Uu]sage limit reached|hit usage limits|out of (usage )?credits").unwrap()
});
/// Codex 0.172.0's dialog at a workspace member's usage limit, which offers
/// to ask the owner for more (`fixtures/stops/codex-limit-increase.txt`). It
/// stands only while the account is at its limit, so a caller's assertion of
/// room never judges past it: no key or line is ever typed into it.
static LIMIT_OFFER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*Request a limit increase from your owner").unwrap());
/// A login wall's line, anchored at the row start so a quoted copy is not
/// one. Claude Code 2.1.332 draws the expired-token error under its `●`
/// answer bullet, and a pane narrower than the line wraps it onto an
/// indented row below: [`wrapped_auth_failure`] reads that pair. `●` opens
/// every Claude answer, so only that whole, end-anchored line takes it: an
/// answer that begins with another wall's words is not a wall.
static AUTH_FAILURE: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"^[\s\u{a0}]*(?:(?:⎿[\s\u{a0}]*|■\s*|✗\s*)?(?:Login expired.*Please run /login|Not logged in.*Please run /login|Your access token could not be refreshed|You must be logged in to send messages\. Please run /login)|(?:⎿[\s\u{a0}]*|■\s*|✗\s*|●\s*)?Please run /login · API Error: 401 OAuth access token has expired\. Re-authenticate to continue\.\s*$)").unwrap()
});
/// A user-turn marker: Claude's and Copilot's `❯`, Codex's `›`. A submitted
/// turn is echoed as the marker, a space and the text; the live composer is
/// the harness's own drawing below.
static MARKER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^❯|^›").unwrap());
/// Claude Code's composer: the marker then U+00A0, the padding it gives the
/// input line and no shell prompt or echoed turn carries.
static CLAUDE_COMPOSER: LazyLock<Regex> = LazyLock::new(|| Regex::new("^❯\u{a0}").unwrap());
/// Codex's composer line. Herdr trims the spaces on a blank `› ` row.
static CODEX_MARKER: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^›(?: |$)").unwrap());
/// Copilot's composer is the marker line with a rule drawn under it.
static FRAME_RULE: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[─━]{10,}\s*$").unwrap());
/// Pi's editor border while a turn runs: an indicator frame and the word, or
/// the word alone where pi-tool-renderer's hidden mode sets no frame
/// (`installWorkingIndicator`, pi-tui `components/loader.js`).
static PI_WORKING_BORDER: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^── (?:\S+ )?Working ─+\s*$").unwrap());
/// Pi's prompt line under the editor: the working directory, then the
/// branch in parentheses when there is one, then ` • <name>` once the
/// session has a name (Pi 1.6.1 `modes/interactive/components/footer.js`).
static PI_PROMPT: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^[~/]\S*( \(.+\))?( • .+)?\s*$").unwrap());
/// pi-qol's compact composer, which replaces Pi's editor, with no draft in
/// it: pi-qol draws `π ` and then the draft (pi-qol `qol/editor.ts`,
/// `QolCompactPromptEditor`), and a capture drops the trailing space when no
/// draft is typed. A paste into a composer that holds a draft submits the
/// draft with it, so a `π` row with a draft is not read as this composer.
static QOL_PROMPT: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^π\s*$").unwrap());
/// pi-qol's status line, drawn above its composer in place of Pi's footer:
/// it ends with the context left, `<n>%` or `…%` before any reading, then,
/// in a subagent, two spaces and its name cut to 24 columns (pi-qol
/// `qol/statusline.ts` `renderStatusLine`, `qol/agent-statusline.ts`).
static QOL_STATUS: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"\s(?:[0-9]+|…)%(?:  .{1,24})?\s*$").unwrap());
/// A row of the panels kendex's Pi extensions stack above the editor
/// (`stacked-widget.ts` in pi-agents-tmux, pi-task-panel and
/// pi-background-tasks): each panel is a heavy-framed box. They register
/// after pi-qol's status line, so under pi-qol they stand between it and the
/// composer.
static QOL_PANEL_ROW: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[┏┃┗]").unwrap());
/// pi-qol draws Pi's working indicator at the head of its status line while
/// a turn runs: its own static `●` (`applyWorkingIndicatorMode`), a frame of
/// Pi's default spinner (pi-tui `components/loader.js`), or a frame of
/// pi-tool-renderer's pulse, `· ○ ● ○` or in ASCII `- o * o`
/// (`installWorkingIndicator`), then a space. At rest the line opens on the
/// project's name.
static QOL_TURN: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^[●○·⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏*o-] ").unwrap());
/// Pi's footer carries the context token `<used>%/<window>` from the first
/// draw; the token counts before it and the model after it come and go.
static PI_FOOTER: LazyLock<Regex> = LazyLock::new(|| {
    Regex::new(r"(^|\s)[0-9]+(\.[0-9]+)?%/[0-9]+(\.[0-9]+)?[kKmMgG]?(\s|$)").unwrap()
});

/// Codex's refusal of one turn for the selected model's capacity, drawn
/// above the composer the lane
/// then sits at: the one marker that tells this idle from a finished turn's.
static CODEX_CAPACITY: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"Selected model is at capacity").unwrap());

/// Whether a Codex slice judged idle sits at its composer under the capacity
/// refusal: the refusal line and the marker line are both drawn in it.
pub fn codex_capacity_refused(slice: &str) -> bool {
    slice.lines().any(|l| CODEX_CAPACITY.is_match(l))
        && slice.lines().any(|l| CODEX_MARKER.is_match(l))
}

/// Copilot's refusal of a submit while it still loads an enterprise seat's
/// managed account policy, as Copilot CLI 1.0.112 drew it in a live start:
/// the submit is dropped and the draft stays in the composer, where a bare
/// Enter submits it once the policy has loaded.
static COPILOT_POLICY_LOADING: LazyLock<Regex> =
    LazyLock::new(|| Regex::new(r"^\s*! Managed account policy is still loading\.").unwrap());

/// Whether `screen` shows the harness refused a submit and left its draft in
/// the composer, with no turn running and no dialog open, so an Enter can
/// only submit that draft again. Only Copilot refuses a submit so.
pub fn submit_refused(screen: &str, harness: Harness) -> bool {
    match harness {
        Harness::Copilot => {
            screen.lines().any(|l| COPILOT_POLICY_LOADING.is_match(l))
                && !is_working(screen)
                && !is_asking(screen, harness)
        }
        Harness::Claude | Harness::Codex | Harness::Pi => false,
    }
}

/// The Codex app-server's `turn/completed` distinguishes failed and
/// interrupted turns (https://developers.openai.com/codex/app-server/#server-notifications).
/// The judge receives a captured interactive pane without an app-server
/// connection. Codex 0.172.0 uses the square for free-text errors and for
/// its fixed interruption notice
/// (https://github.com/openai/codex/blob/rust-v0.172.0/codex-rs/tui/src/history_cell/notices.rs).
static CODEX_API_ERROR: LazyLock<Regex> = LazyLock::new(|| Regex::new(r"^■ \S").unwrap());

/// Whether a Codex slice judged idle sits at its composer after an API error
/// ended its turn: the error line and the marker line are both drawn in it.
pub fn codex_api_error(slice: &str) -> bool {
    let mut lines = slice.lines();
    lines.any(|line| {
        CODEX_API_ERROR.is_match(line) && !line.starts_with("■ Conversation interrupted")
    }) && lines.any(|line| CODEX_MARKER.is_match(line))
}

/// The evidence for a turn whose pane the observer found idle.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum IdleTurn {
    Ordinary { after_prompt: bool },
    Capacity,
    ApiError,
}

impl IdleTurn {
    /// The word for a turn its provider stopped: `capacity` for Codex's
    /// capacity refusal, [`crate::stop::API_ERROR`] for the provider's error
    /// on the pane. An ordinary turn has none.
    pub fn stopped(self) -> Option<&'static str> {
        match self {
            IdleTurn::Capacity => Some("capacity"),
            IdleTurn::ApiError => Some(crate::stop::API_ERROR),
            IdleTurn::Ordinary { .. } => None,
        }
    }
}

/// Classify the current idle turn using the lines below the last prompt.
fn idle_turn(harness: Harness, slice: &str, after_prompt: bool) -> IdleTurn {
    if harness == Harness::Codex && codex_capacity_refused(slice) {
        IdleTurn::Capacity
    } else if pane_api_error(harness, slice) {
        IdleTurn::ApiError
    } else {
        IdleTurn::Ordinary { after_prompt }
    }
}

/// The pane state and any terminal evidence from its current idle turn.
#[must_use]
pub struct PaneObservation {
    pub state: State,
    pub idle: Option<IdleTurn>,
}

impl PaneObservation {
    /// The `judge` verb's answer: the state, and beside an idle one the
    /// `turn` its provider stopped ([`IdleTurn::stopped`]), which is a
    /// provider stop to the stop decision (`controller successor --stop
    /// provider`), so its caller reads no screen of its own.
    pub fn reply(&self) -> serde_json::Value {
        let mut reply = serde_json::to_value(&self.state).unwrap_or_default();
        if let Some(turn) = self.idle.and_then(IdleTurn::stopped) {
            reply["turn"] = turn.into();
        }
        reply
    }
}

pub fn observe_pane(
    screen: &str,
    harness: Harness,
    process: &ProcessReading,
    account_room: Option<bool>,
) -> PaneObservation {
    let slice = below_last_turn(screen);
    let state = judge_slice(&slice, harness, process, account_room);
    let idle = (state == State::Idle).then(|| idle_turn(harness, &slice, slice != screen));
    PaneObservation { state, idle }
}

/// Copilot's documented `errorOccurred` reports per-request errors,
/// including recoverable model calls, without a terminal-turn field
/// (https://docs.github.com/en/copilot/reference/hooks-reference#erroroccurred).
/// The CLI emits those events during retries, so read the execution failure
/// below the current prompt once the composer is idle (github/copilot-cli
/// #2166 and #875).
fn pane_api_error(harness: Harness, slice: &str) -> bool {
    match harness {
        Harness::Codex => codex_api_error(slice),
        Harness::Copilot => slice.lines().any(|line| {
            let line = line.strip_prefix("✗ ").unwrap_or(line);
            (line.starts_with("Execution failed: CAPIError:")
                || line.starts_with(
                    "Execution failed: Error: Failed to get response from the AI model",
                ))
                && !line.contains("CAPIError: 429")
                && !line.contains("you've hit a rate limit")
        }),
        Harness::Claude | Harness::Pi => false,
    }
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
    Reading::Live(btime + ticks / process::USER_HZ)
}

/// The last twelve nonblank rows of a captured pane, in their drawn order.
pub fn screen_tail(screen: &str) -> Vec<String> {
    let mut tail: Vec<_> = screen
        .lines()
        .rev()
        .filter(|line| !line.trim().is_empty())
        .take(12)
        .map(str::to_owned)
        .collect();
    tail.reverse();
    tail
}

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

// Copilot's SDK onUserInputRequest handles ask_user in an SDK-managed
// session (https://docs.github.com/en/copilot/how-tos/copilot-sdk/troubleshooting/compatibility).
// The CLI's elicitation_dialog and ask_user hooks report events without
// identifying the pane's current input focus
// (https://docs.github.com/en/copilot/reference/hooks-reference).
// Pi's optional pi-bridge questions lists pending requests
// (pi-extensions/pi-questions/README.md). A pending request does not say
// which editor control is drawn and taking input. Delivery reads the
// existing pane to determine where its next key will go.
fn is_asking(slice: &str, harness: Harness) -> bool {
    ASKING.is_match(slice)
        || match harness {
            // Copilot's ask_user chooser takes input in place of the composer.
            Harness::Copilot => slice.lines().any(|line| {
                line.trim() == "↑/↓ select · enter accept · ctrl+d decline · esc cancel"
            }),
            // The pi-questions editor dialog frames its navigation hints.
            Harness::Pi => slice.lines().any(|line| {
                line.trim_end()
                    .strip_prefix("┃  ⇆ tab  ")
                    .and_then(|hint| hint.strip_suffix('┃'))
                    .is_some_and(|hint| hint.trim_end().ends_with("  esc dismiss"))
            }),
            Harness::Claude | Harness::Codex => false,
        }
}

/// Whether Pi's editor border, or pi-qol's status line, says a turn is
/// running.
///
/// Pi also reports a running turn as Program Status (OSC 7501). It sends the
/// report once the terminal answers the protocol's query, or always under
/// `PI_PROGRAM_STATUS=1`, and tmux forwards none of it (Pi 1.6.1's terminal
/// setup document, § Program status). A tmux pane capture holds the cells
/// drawn, never a sequence tmux consumed, so the pane read cannot see that
/// report.
pub fn pi_working(slice: &str) -> bool {
    slice.lines().any(|l| PI_WORKING_BORDER.is_match(l))
        || qol_status(slice).is_some_and(|status| QOL_TURN.is_match(status))
}

/// pi-qol's status line when its composer is drawn: the last `π` line, with
/// the status line the first row above it that is no panel row. Any other
/// row there, a blank one included, is a drawing this rule does not know,
/// and settles nothing. Below an empty composer stand only its blank padding
/// rows. A row below it is a draft's line, the completion list, or
/// something else, such as a Pi selector, drawn where the composer stands
/// under a `π` line of transcript text; each settles nothing.
fn qol_status(slice: &str) -> Option<&str> {
    let lines: Vec<&str> = slice.lines().collect();
    let prompt = lines.iter().rposition(|l| QOL_PROMPT.is_match(l))?;
    if !lines[prompt + 1..].iter().all(|l| l.trim().is_empty()) {
        return None;
    }
    let status = *lines[..prompt]
        .iter()
        .rev()
        .find(|l| !QOL_PANEL_ROW.is_match(l))?;
    QOL_STATUS.is_match(status).then_some(status)
}

/// Whether Pi's composer is drawn and open. Pi's default composer is the
/// editor's bottom rule as the last rule drawn, with the prompt line and
/// the footer directly under it. Pi draws its extensions' status lines below
/// the footer, `pi-session-bridge`'s `bridge:<pid>` in every lane among
/// them, so whatever stands under the footer is not read. pi-qol replaces
/// that editor and footer with its status line above a `π` composer.
///
/// Pi's native interface for turn state is its session file, which ends a
/// turn with an assistant row whose `stopReason` is `stop`. That file cannot
/// show whether the composer is drawn, and delivery is a pane paste into
/// that composer, so the pane read stands for the one question the file
/// cannot answer. Pi 1.4.0 draws no `❯`/`›` marker, so the marker rule the
/// other harnesses use never fires here.
pub fn pi_composer_drawn(slice: &str) -> bool {
    let drawn: Vec<&str> = slice.lines().filter(|l| !l.trim().is_empty()).collect();
    let stock = drawn
        .iter()
        .rposition(|l| FRAME_RULE.is_match(l))
        .is_some_and(|rule| {
            matches!(
                drawn.get(rule + 1..rule + 3),
                Some([prompt, footer]) if PI_PROMPT.is_match(prompt) && PI_FOOTER.is_match(footer)
            )
        });
    stock || qol_status(slice).is_some()
}

/// At rest the composers draw Claude's marker padded with U+00A0, Codex's
/// `› ` line, Copilot's marker with a rule below it, and Pi's rule, prompt
/// and footer, or under pi-qol its status line over its `π` composer. A
/// shell prompt
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

/// The account's banner in the slice, empty when the harness drew none or
/// a turn is in flight (limit-shaped text mid-turn is the session's own).
pub fn limit_banner(slice: &str) -> Option<String> {
    if is_working(slice) {
        return None;
    }
    let rows: Vec<&str> = slice.lines().collect();
    let mut banner = Vec::new();
    let mut i = 0;
    while let Some(&row) = rows.get(i) {
        if USAGE_LIMIT.is_match(row) || AUTH_FAILURE.is_match(row) {
            banner.push(row);
            // Codex draws its error as one paragraph under `■`, and a pane
            // narrower than it wraps the rest, the reset clause among it, onto
            // the rows below (`fixtures/stops/codex-purchase-offer.txt`).
            if CODEX_API_ERROR.is_match(row) {
                while let Some(&next) = rows.get(i + 1)
                    && !next.trim().is_empty()
                    && !MARKER.is_match(next)
                {
                    banner.push(next);
                    i += 1;
                }
            }
        } else if let Some(&next) = rows.get(i + 1)
            && wrapped_auth_failure(row, next)
        {
            banner.extend([row, next]);
            i += 1;
        }
        i += 1;
    }
    (!banner.is_empty()).then(|| banner.join("\n"))
}

/// Whether `row` and the `next` row under it read as one login wall's line
/// once the space the wrap took is restored and the continuation's indent
/// dropped. Only an adjacent pair is joined, never the screen: the composer
/// rules read single rows (`host::tmux::capture` keeps them apart). A pair
/// where either row is a wall's line alone is no wrap: the joined text of a
/// blank row and a wall line under it would match, and carry the blank row
/// into the banner.
fn wrapped_auth_failure(row: &str, next: &str) -> bool {
    !AUTH_FAILURE.is_match(row)
        && !AUTH_FAILURE.is_match(next)
        && AUTH_FAILURE.is_match(&format!("{} {}", row.trim_end(), next.trim_start()))
}

/// Whether a failed Pi turn's `errorMessage` is a refused sign-in. Pi writes
/// a provider's refusal as its HTTP status, a space and the body
/// (`pi-auth.jsonl`, an expired OAuth token's 401).
pub fn pi_auth_failure(message: &str) -> bool {
    message.starts_with("401 ")
}

pub fn is_auth_failure(banner: &str) -> bool {
    banner.lines().any(|l| AUTH_FAILURE.is_match(l))
        || banner
            .lines()
            .zip(banner.lines().skip(1))
            .any(|(row, next)| wrapped_auth_failure(row, next))
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
    judge_slice(&below_last_turn(screen), harness, process, account_room)
}

fn judge_slice(
    slice: &str,
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
    if let Some(banner) = limit_banner(slice) {
        if is_auth_failure(&banner) {
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
            // An asserted room judges past a stale banner, never past a
            // dialog that stands only on a limited account.
            Some(true) if slice.lines().any(|row| LIMIT_OFFER.is_match(row)) => {
                return State::Walled {
                    kind: WallKind::Usage,
                    banner,
                };
            }
            Some(true) => {}
        }
    }
    if is_asking(slice, harness) {
        if slice.lines().any(|l| RATE_LIMIT_SWITCH.is_match(l))
            && slice.lines().any(|l| DIALOG_ROW.is_match(l))
        {
            return State::RateLimitSwitch;
        }
        return State::Asking {
            dialog: dialog(slice),
        };
    }
    if is_working(slice) || (harness == Harness::Pi && pi_working(slice)) {
        return State::Working;
    }
    if composer_drawn(slice, harness) {
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

    // Excerpts of 200-column captures from tmux 3.8 (capture-pane -p -N)
    // and Herdr Core 0.1.22 (hc read --lines 0). The same installed version
    // ran on each host: Claude Code 2.1.332, Codex 0.172.0, Copilot 1.0.117,
    // and Pi 1.7.0. Pi normally uses the Fleet pi-qol composer. Its asking
    // rows use the installed pi-questions 2.1.0 editor in a scratch config.
    // Keep the drawn rows in order. Omit outer blank rows, collapse runs
    // of interior blank rows to one and trim trailing ASCII spaces while
    // preserving Claude's U+00A0. Paths and account allowance are redacted.
    #[test]
    fn judges_captures_from_tmux_and_herdr() {
        const ASKING_OTHER: State = State::Asking {
            dialog: Dialog::Other,
        };
        let cases = [
            (
                "claude-tmux-idle",
                Harness::Claude,
                State::Idle,
                r#"────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  claude (🌳 master*) Sonnet 5.5
  ⏸ manual mode on
"#,
            ),
            (
                "claude-hc-idle",
                Harness::Claude,
                State::Idle,
                r#"────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  claude (🌳 master*) Sonnet 5.5
  ⏸ manual mode on
"#,
            ),
            (
                "claude-tmux-working",
                Harness::Claude,
                State::Working,
                r#"❯ Without tools, write 350 words of original descriptive prose about a garden after a rainstorm.

● The rain stopped an hour ago, but the garden is still dripping. Every leaf holds a bead of water at its tip, and each bead falls when a breeze shifts the branch above it. The air smells of wet soil
  and crushed mint. Under that is the cool mineral scent of stone that has drunk its fill.

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  claude (🌳 master*) Sonnet 5.5 3%
  ⏸ manual mode on · esc to interrupt
"#,
            ),
            (
                "claude-hc-working",
                Harness::Claude,
                State::Working,
                r#"❯ Without tools, write 350 words of original descriptive prose about a garden after a rainstorm.

● The rain stopped an hour ago, but the garden is still dripping. Every leaf holds a bead of water at its tip, and each bead lets go in its own time. Each one lands with a small tick on the leaves
  below. The air smells of wet soil and crushed mint, with a mineral edge that rises from the flagstones as they warm.

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯ 
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
  claude (🌳 master*) Sonnet 5.5 4%
  ⏸ manual mode on · esc to interrupt
"#,
            ),
            (
                "claude-tmux-asking",
                Harness::Claude,
                ASKING_OTHER,
                r#"❯ Call the Bash tool to run exactly: touch judge-probe.txt. Wait for my approval if asked.

● Creating an empty file named judge-probe.txt
  ⎿  $ touch judge-probe.txt

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Bash command
 Tip: auto mode handles these prompts for you — choose "switch to auto mode" below
 Create an empty file named judge-probe.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 touch judge-probe.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to ~/capture from this project
   3. Yes, and switch to auto mode · auto mode handles these prompts for you
   4. No

 Esc to cancel · Tab to amend
"#,
            ),
            (
                "claude-hc-asking",
                Harness::Claude,
                ASKING_OTHER,
                r#"❯ Call the Bash tool to run exactly: touch judge-probe.txt. Wait for my approval if asked.

  Creating an empty file named judge-probe.txt
  ⎿  $ touch judge-probe.txt

────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Bash command
 Tip: auto mode handles these prompts for you — choose "switch to auto mode" below
 Create an empty file named judge-probe.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 touch judge-probe.txt
╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌╌
 Do you want to proceed?
 ❯ 1. Yes
   2. Yes, and always allow access to ~/capture from this project
   3. Yes, and switch to auto mode · auto mode handles these prompts for you
   4. No

 Esc to cancel · Tab to amend
"#,
            ),
            (
                "codex-tmux-idle",
                Harness::Codex,
                State::Idle,
                r#"› Without tools, write 350 words of original descriptive prose about a garden after a rainstorm.

• Rain had flattened the thyme along the path, and its smell rose wherever a shoe brushed the leaves. The bricks were dark red, except where water stood in the hollows and held the pale evening sky. A
  snail had come out from under the step. It crossed the mortar slowly, carrying a chip of dead leaf on its shell. At the far end of the garden, the gutter still emptied into the barrel, one fat drop
  at a time. Each struck with a small, hollow knock.

  The peonies had taken the worst of it. Two blooms lay face down in the soil, their stems bowed almost to the ground. When I lifted one, cold water ran out of the petals and down my sleeve. The
  flower was white toward the edges and pink in the folds, where a few black ants were picking their way outward. I propped the stem in the fork of a hazel twig. For a moment it held, then the head
  turned sideways, heavy as before.

  Beyond the beans, the rain had cut a shallow channel across the bare bed. It had carried three radish seeds as far as the boards, where they rested in a little fan of silt. I knew them by the faint
  rose color of the seed coating. Upstairs, someone opened a window. The sash stuck, then gave with the familiar scrape. Warm air smelling of fried onions drifted down almost to the mint before the
  damp smell of the garden swallowed it.

  Light came back first on the underside of the clouds, a washed yellow that caught in the wet tops of the bean poles. A blackbird dropped onto the lawn and stood with its head cocked. It hopped
  twice, pulled something pale from the grass, and flew low through the gap in the hedge. Water fell from the shaken leaves. In the brief light I could see the beans had grown long enough to reach
  past their poles. Their thin tips hung loose above the twine. One had doubled back and wound itself around the stem of its neighbor, and the two swayed together.

  Worked for 21s • 03:15

›

  Context 99% left · ~/capture · GPT-6.2-Sol default · master · 475K window · Standard · Ask for approval · weekly [redacted]% left
                                                                                                                                                                               ⚠ 1 warning · f2 to view
"#,
            ),
            (
                "codex-hc-idle",
                Harness::Codex,
                State::Idle,
                r#"› Without tools, write 350 words of original descriptive prose about a garden after a rainstorm.

• The rain had stopped, but the garden was still making up its mind. Water ticked from the gutter into the mint, and every so often the pear tree let go of a little shower all its own. Where the path
  dipped, a puddle held the pale square of an upstairs window. When I stepped over it, my reflection broke into long strips that caught for a moment on the gravel.

  The peonies had gone down first. Their heavy pink heads lay sideways in the bed, close enough to the soil for ants to walk straight into them. I slid a hand under one bloom and lifted it. Cold water
  ran down my sleeve to the elbow. Inside, the petals were almost white, and a black beetle, disturbed by the sudden light, backed slowly into the folds and disappeared from view.

  The storm had washed the dust off the brick wall. Its old repairs showed plainly now, the yellow mortar and the odd blue brick my father had put in where a root pushed through. At the foot of the
  wall, the sage smelled sharp when I brushed past it. Under that smell was the softer one of wet wood rising from the stakes where the sweet peas had come loose.

  A snail was crossing the broadest flagstone. It had reached a place where the water thinned to a sheen, and its feelers moved independently, one aimed at the grass and the other at my shoe. I stood
  still until it lowered both and went on. Behind it, the trail was hard to distinguish from the wet stone except where it passed over a small, dry island under the bench leg.

  By then the sun had come through low enough to reach under the rhubarb leaves. The stalks glowed a dull red. A sparrow landed in the bare patch where I had pulled the lettuces and took a bath in a
  hollow left by my heel. It shook itself so hard that I heard the quick rattle of its wings. After it flew away, the water in the hollow kept trembling.

  Worked for 23s • 03:14

›

  Context 99% left · ~/capture · GPT-6.2-Sol default · master · 475K window · Standard · Ask for approval · weekly [redacted]% left
                                                                                                                                                                               ⚠ 1 warning · f2 to view
"#,
            ),
            (
                "codex-tmux-working",
                Harness::Codex,
                State::Working,
                r#"› Without tools, write 350 words of original descriptive prose about a garden after a rainstorm.

Working (7s • esc to interrupt)

› Ask Codex to do anything

  Context 100% left · ~/capture · GPT-6.2-Sol default · master · 500K window · Standard · Ask for approval · weekly [redacted]% left
  ← for agents · ? for shortcuts                                                                                                                                               ⚠ 1 warning · f2 to view
"#,
            ),
            (
                "codex-hc-working",
                Harness::Codex,
                State::Working,
                r#"› Without tools, write 350 words of original descriptive prose about a garden after a rainstorm.

Working (8s • esc to interrupt)

› Ask Codex to do anything

  Context 100% left · ~/capture · GPT-6.2-Sol default · master · 500K window · Standard · Ask for approval · weekly [redacted]% left
  ← for agents · ? for shortcuts                                                                                                                                               ⚠ 1 warning · f2 to view
"#,
            ),
            (
                "codex-tmux-asking",
                Harness::Codex,
                ASKING_OTHER,
                r#"  Folder access
  ~/capture

  Trust this folder? Codex can read, edit, and run files here, subject to your permission settings. Folder settings can run code automatically, even without a model request. Continue only if you
  trust these files. Your trust decision will be saved.

› 1. Trust and continue
  2. Back to Agent Command Center

  enter continue · esc back
"#,
            ),
            (
                "codex-hc-asking",
                Harness::Codex,
                ASKING_OTHER,
                r#"  Folder access
  ~/capture

  Trust this folder? Codex can read, edit, and run files here, subject to your permission settings. Folder settings can run code automatically, even without a model request. Continue only if you
  trust these files. Your trust decision will be saved.

› 1. Trust and continue
  2. Back to Agent Command Center

  enter continue · esc back
"#,
            ),
            (
                "copilot-tmux-idle",
                Harness::Copilot,
                State::Idle,
                r#"────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ← open sidebar · Interactive · Allow All · / commands · ? help · tab next tab                                                                                                GPT-6.1 Sol · High · (7%)
"#,
            ),
            (
                "copilot-hc-idle",
                Harness::Copilot,
                State::Idle,
                r#"────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ← open sidebar · Interactive · Allow All · / commands · ? help · tab next tab                                                                                                GPT-6.1 Sol · High · (7%)
"#,
            ),
            (
                "copilot-tmux-working",
                Harness::Copilot,
                State::Working,
                r#"────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ◎ Working ctrl+c interrupt                                                                                                                                                   GPT-6.1 Sol · High · (7%)
"#,
            ),
            (
                "copilot-hc-working",
                Harness::Copilot,
                State::Working,
                r#"────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
❯
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 ○ Working ctrl+c interrupt                                                                                                                                                   GPT-6.1 Sol · High · (7%)
"#,
            ),
            (
                "copilot-tmux-asking",
                Harness::Copilot,
                ASKING_OTHER,
                r#"────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Copilot needs information.
 Which color?

 Color:
 ❯ Blue
   Green
   Other (type your answer)

 ↑/↓ select · enter accept · ctrl+d decline · esc cancel
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
"#,
            ),
            (
                "copilot-hc-asking",
                Harness::Copilot,
                ASKING_OTHER,
                r#"────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
 Copilot needs information.
 Which color?

 Color:
 ❯ Blue
   Green
   Other (type your answer)

 ↑/↓ select · enter accept · ctrl+d decline · esc cancel
────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────
"#,
            ),
            (
                "pi-tmux-idle",
                Harness::Pi,
                State::Idle,
                r#"pi (🌳 master) Claude / Fable 5.2 / medium 1M ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────── 100%
π
"#,
            ),
            (
                "pi-hc-idle",
                Harness::Pi,
                State::Idle,
                r#"pi (🌳 master) Claude / Fable 5.2 / medium 1M ───────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────── 100%
π
"#,
            ),
            (
                "pi-tmux-working",
                Harness::Pi,
                State::Working,
                r#"┏━ π ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ Without tools, write 350 words of original descriptive prose about a garden after a rainstorm.                                                                                                      ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

 

● pi (🌳 master) Claude / Fable 5.2 / medium 1M  ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────── 99%
π
"#,
            ),
            (
                "pi-hc-working",
                Harness::Pi,
                State::Working,
                r#"┏━ π ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃ Without tools, write 350 words of original descriptive prose about a garden after a rainstorm.                                                                                                      ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛

● pi (🌳 master) Claude / Fable 5.2 / medium 1M  ─────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────────── 99%
π
"#,
            ),
            (
                "pi-tmux-asking",
                Harness::Pi,
                ASKING_OTHER,
                r#"┏ Color choice ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃   Which color?                                                                                                                                                                                       ┃
┃                                                                                                                                                                                                      ┃
┃  Which color?                                                                                                                                                                                        ┃
┃                                                                                                                                                                                                      ┃
┃  1. Blue                                                                                                                                                                                             ┃
┃     The color blue                                                                                                                                                                                   ┃
┃  2. Green                                                                                                                                                                                            ┃
┃     The color green                                                                                                                                                                                  ┃
┃  3. Something else                                                                                                                                                                                   ┃
┃     Type your answer, then press enter.                                                                                                                                                              ┃
┃                                                                                                                                                                                                      ┃
┃  ⇆ tab  ↑↓ select  enter confirm  esc dismiss                                                                                                                                                        ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
~/capture (master)
↑3.9k ↓105 $0.009 0.4%/1.0M (auto)                                                                                                                         (vercel-ai-gateway) zai/glm-5.3-fast • medium
"#,
            ),
            (
                "pi-hc-asking",
                Harness::Pi,
                ASKING_OTHER,
                r#"┏ Color choice ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓
┃   Color                                                                                                                                                                                              ┃
┃                                                                                                                                                                                                      ┃
┃  Which color?                                                                                                                                                                                        ┃
┃                                                                                                                                                                                                      ┃
┃  1. Blue                                                                                                                                                                                             ┃
┃     The color blue                                                                                                                                                                                   ┃
┃  2. Green                                                                                                                                                                                            ┃
┃     The color green                                                                                                                                                                                  ┃
┃  3. Something else                                                                                                                                                                                   ┃
┃     Type your answer, then press enter.                                                                                                                                                              ┃
┃                                                                                                                                                                                                      ┃
┃  ⇆ tab  ↑↓ select  enter confirm  esc dismiss                                                                                                                                                        ┃
┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛
~/capture (master)
↑3.9k ↓98 $0.009 0.4%/1.0M (auto)                                                                                                                          (vercel-ai-gateway) zai/glm-5.3-fast • medium
"#,
            ),
        ];
        for (name, harness, expected, screen) in cases {
            let observed = observe_pane(screen, harness, &ProcessReading::HarnessUp, None);
            assert_eq!(observed.state, expected, "{name}");
        }
    }

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

    /// The expired-token banner is an auth wall carrying its rows as drawn,
    /// on one row and wrapped onto two by an 80-column pane (the fixture,
    /// captured from Claude Code 2.1.332 answering a stubbed 401). A quoted
    /// copy is not, nor an answer that opens with another wall's words, and
    /// a wrapped answer above the composer stays idle.
    #[test]
    fn an_expired_oauth_token_banner_is_an_auth_wall_on_one_row_or_wrapped() {
        const BANNER: &str = "Please run /login · API Error: 401 OAuth access token has expired. Re-authenticate to continue.";
        const WRAPPED: &str = include_str!("../../tests/rust/fixtures/claude-oauth-expired-80.txt");
        // Each screen and the banner rows its wall carries, trailing blanks
        // aside; `None` is a screen that reads idle.
        let rows: [(String, Option<&[&str]>); 5] = [
            (format!("❯ work\n{BANNER}\n❯\u{a0}"), Some(&[BANNER])),
            (format!("❯ work\n\"{BANNER}\"\n❯\u{a0}"), None),
            (
                WRAPPED.to_owned(),
                Some(&[
                    "● Please run /login · API Error: 401 OAuth access token has expired.",
                    "  Re-authenticate to continue.",
                ]),
            ),
            (
                "❯ work\n● The banner is read across the row\n  it wraps onto.\n❯\u{a0}".to_owned(),
                None,
            ),
            (
                "❯ work\n● Your access token could not be refreshed because the stub refused it.\n❯\u{a0}"
                    .to_owned(),
                None,
            ),
        ];
        for (screen, banner) in rows {
            let state = judge(&screen, Harness::Claude, &ProcessReading::HarnessUp, None);
            match (state, banner) {
                (
                    State::Walled {
                        kind: WallKind::Auth,
                        banner: drawn,
                    },
                    Some(banner),
                ) => assert_eq!(
                    drawn.lines().map(str::trim_end).collect::<Vec<_>>(),
                    banner,
                    "{screen}"
                ),
                (state, None) => assert_eq!(state, State::Idle, "{screen}"),
                (state, Some(_)) => panic!("{state:?} is no auth wall: {screen}"),
            }
        }
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
        let recorded_rows = |name| [row(20, 10, 20, "bash"), row(30, 20, 30, name)];
        for (name, expected) in [
            (
                "renamed",
                ProcessReading::Harness {
                    identity: recorded.clone(),
                },
            ),
            ("bash", ProcessReading::ShellsOnly),
        ] {
            assert_eq!(
                classify(&recorded_rows(name), 30, 20, &owns, Some(&recorded), &live),
                expected,
                "{name}"
            );
        }
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

    /// Copilot's policy refusal over its composer is a refused submit; the
    /// same line with a turn running or a dialog open, or under another
    /// harness, is not.
    #[test]
    fn only_copilot_s_policy_refusal_at_rest_is_a_refused_submit() {
        let rule = "─".repeat(20);
        let refusal =
            "! Managed account policy is still loading. Please wait a moment and try again.";
        let at_rest = format!("❯ brief\n{refusal}\n❯ brief\n{rule}\n");
        for (screen, harness, refused) in [
            (at_rest.clone(), Harness::Copilot, true),
            (
                format!("  {refusal}\n❯ brief\n{rule}\n"),
                Harness::Copilot,
                true,
            ),
            (format!("❯ brief\n{rule}\n"), Harness::Copilot, false),
            (
                format!("{at_rest}❯ 1. Yes\n  2. No\n"),
                Harness::Copilot,
                false,
            ),
            (format!("{at_rest}esc interrupt\n"), Harness::Copilot, false),
            (
                format!("the answer quotes {refusal}\n❯ \n{rule}\n"),
                Harness::Copilot,
                false,
            ),
            (at_rest.clone(), Harness::Claude, false),
            (at_rest, Harness::Codex, false),
        ] {
            assert_eq!(
                submit_refused(&screen, harness),
                refused,
                "{harness:?} {screen}"
            );
        }
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
        assert!(codex_api_error(
            "■ The selected model is not supported.\n› Ask Codex to do anything"
        ));
        assert!(!codex_api_error(
            "› Ask Codex to do anything\n■ The selected model is not supported."
        ));
        assert!(!codex_api_error("■ The selected model is not supported."));
        assert!(!codex_api_error(
            "› what failed?\n  ■ {\"detail\":\"Bad Request\"} is what the log said\n› Ask Codex to do anything"
        ));
        assert!(!codex_api_error(
            "› Continue the task.\n▲ Selected model is at capacity. Try again later.\n› Ask Codex to do anything"
        ));
    }

    /// The `judge` answer names the idle turn a provider stopped beside the
    /// state, and none for an ordinary one, on drawn panes: Codex's capacity
    /// refusal and the API error a real Codex pane drew, Copilot's
    /// execution failure, and the recorded Codex idle.
    #[test]
    fn the_judge_answer_names_a_provider_stopped_idle_turn_beside_its_state() {
        let rows = [
            (
                Harness::Codex,
                "› Continue the task.\n\n■ Conversation interrupted - use /feedback if something went wrong\n\n› Ask Codex to do anything",
                None,
            ),
            (
                Harness::Codex,
                "› Continue the task.\n\n▲ Selected model is at capacity. Try again later.\n\n› Ask Codex to do anything",
                Some("capacity"),
            ),
            (
                Harness::Codex,
                "■ {\"detail\":\"Bad Request\"}\n1 background terminal running · /ps to view · /stop to close\n› Ask Codex to do anything\nContext 61% left · ~/dev/.worktrees/kendex/ken-5026 · GPT-6.1-Sol high · ken-…\n← for agents · ? for shortcuts ⚠ 2 warnings · f2 to view",
                Some("api-error"),
            ),
            (
                Harness::Codex,
                "› Continue the task.\n\n■ The selected model is not supported.\n\n› Ask Codex to do anything",
                Some("api-error"),
            ),
            // The terminal messages recorded in codex-network.jsonl and codex-stream.jsonl.
            (
                Harness::Codex,
                "› Continue the task.\n\n■ stream disconnected before completion: error sending request\n\n› Ask Codex to do anything",
                Some("api-error"),
            ),
            (
                Harness::Codex,
                "› Continue the task.\n\n■ stream disconnected before completion: Transport error: network error: error decoding response body\n\n› Ask Codex to do anything",
                Some("api-error"),
            ),
            (
                Harness::Copilot,
                "❯ Brief\n✗ Execution failed: CAPIError: Connection error.\n❯ \n────────────────────────────────────────\n",
                Some("api-error"),
            ),
            (
                Harness::Codex,
                include_str!("../../tests/rust/fixtures/codex-idle.txt"),
                None,
            ),
        ];
        for (harness, screen, turn) in rows {
            let reply = observe_pane(screen, harness, &ProcessReading::HarnessUp, None).reply();
            assert_eq!(reply["state"], "idle", "{harness:?} {turn:?}: {reply}");
            assert_eq!(
                reply.get("turn").and_then(serde_json::Value::as_str),
                turn,
                "{harness:?} {screen:?}: {reply}"
            );
        }
    }

    /// Codex's rate-limit choice list stands in place of the composer, and
    /// keys typed there go to the list: its selected row is a `› ` line, so
    /// only the dialog rule read before the composer rule keeps a paste out
    /// of it. The drawing is the measured one, with its heading on two lines
    /// and on one.
    #[test]
    fn the_codex_rate_limit_list_is_never_idle_so_no_paste_reaches_it() {
        let list = "› 1. Switch to gpt-6-luna                   Fast and affordable model for easier\n                                            tasks.\n  2. Keep current model\n  3. Keep current model (never show again)  Hide future rate limit reminders\n                                            about switching models\n\n  enter select · esc back";
        let process = ProcessReading::HarnessUp;
        for (heading, state) in [
            (
                "  Approaching rate limits\n  Switch to gpt-6-luna for lower credit usage?",
                State::RateLimitSwitch,
            ),
            (
                "  Approaching rate limits. Switch to gpt-6-luna for lower credit usage?",
                State::Asking {
                    dialog: Dialog::Other,
                },
            ),
        ] {
            let screen = format!("› Continue the task.\n• Done.\n\n{heading}\n\n\n{list}");
            assert_eq!(judge(&screen, Harness::Codex, &process, None), state);
        }
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
