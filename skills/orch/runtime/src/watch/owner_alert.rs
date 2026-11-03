//! The owner's alert through the overseer mailbox (`overseer_owner_notice`;
//! decision 130: one route, no new record or verb): a watch duty's one way
//! to tell the owner of an overseer condition nobody in the session can act
//! on. Two duties take it: the overseer duty for a context gap that stands
//! (`watch::overseer`), the wake duty for an idle overseer holding the
//! owner's unread mail that no wake reached (`watch::wake`, round 11).
//!
//! The turn is the same for both: the condition is said on the log on the
//! pass that reads it, [`Word::Told`]; the owner is alerted on the next
//! pass, and the mark advanced to [`Word::Alerted`] only once the owner
//! holds the words, so an alert the owner did not get is sent again on the
//! pass after; nothing is sent while that condition stands; a changed
//! condition starts the turn again. Each duty keeps the mark in the record
//! it owns for the condition: the overseer duty in its baseline row, the
//! wake duty in the wake record its mark already stands in.

use std::time::Duration;

use agent_runtime::host;
use serde::{Deserialize, Serialize};

use crate::settings::Settings;

/// The bound on the one send: the mailbox program takes its lock and
/// judges the text against the day's notices.
const BOUND: Duration = Duration::from_secs(120);

/// Where the owner's turn stands for one condition.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "kebab-case")]
pub enum Word {
    /// Said on the log; the owner's alert is owed on the next pass.
    Told,
    /// The owner holds the words.
    Alerted,
}

impl Word {
    /// The baseline row's value for `state` at this word, `<state>|told`.
    pub fn row(self, state: &str) -> String {
        format!("{state}|{}", self.name())
    }

    /// The word a baseline row's `value` holds for `state`; none for
    /// another state's row or an empty one.
    pub fn of_row(value: &str, state: &str) -> Option<Word> {
        [Word::Told, Word::Alerted]
            .into_iter()
            .find(|word| word.row(state) == value)
    }

    fn name(self) -> &'static str {
        match self {
            Word::Told => "told",
            Word::Alerted => "alerted",
        }
    }
}

/// Send `text` to the owner: the words written to `file` under the state
/// directory, the duty's own, and sent as `lane-mail notice --item overseer
/// --to owner --file` through the one runner. `lane-mail` refusing the text
/// as `owner-notice-repeated` is the owner already holding those words,
/// which counts as sent; `Err` carries the channel and the cause.
#[allow(
    clippy::disallowed_methods,
    reason = "the alert's notice file, the watch's own under its state directory, and the one send through the mailbox program via the one runner (decision 94 (b))"
)]
pub fn send(settings: &Settings, file: &str, text: &str) -> Result<(), String> {
    let notice = settings.state_dir.join(file);
    if let Some(dir) = notice.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("channel=file {e}"))?;
    }
    std::fs::write(&notice, text).map_err(|e| format!("channel=file {e}"))?;
    let path = notice.display().to_string();
    let out = host::run_tagged(
        "overseer-alert",
        "lane-mail",
        &settings.lane_mail_cli,
        "notice",
        &[
            "notice", "--item", "overseer", "--to", "owner", "--file", &path,
        ],
        BOUND,
    )
    .map_err(|e| e.to_string())?;
    if out.status.success() {
        return Ok(());
    }
    let refusal = host::stderr_text(&out);
    if refusal
        .lines()
        .next()
        .is_some_and(|l| l.starts_with("lane-mail: owner-notice-repeated="))
    {
        return Ok(());
    }
    Err(format!("channel=owner {}", refusal.trim()))
}
