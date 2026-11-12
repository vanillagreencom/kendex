//! The owner's alert through the overseer mailbox: a watch duty's one way
//! to tell the owner of an overseer condition nobody in the session can act
//! on. Three duties take it: the overseer duty for a context gap that stands
//! and for an overseer whose session has ended (`watch::overseer`), the
//! wake duty for an idle overseer holding the owner's unread mail that no
//! wake reached (`watch::wake`), and the GitHub duty for a sign-in the
//! credential ladder cannot renew (`watch::github`).
//!
//! The turn is the same for each: the condition is said on the log on the
//! pass that reads it, [`Word::Told`]; the owner is alerted on the next
//! pass, and the mark advanced to [`Word::Alerted`] only once the owner
//! holds the words, so an alert the owner did not get is sent again on the
//! pass after; nothing is sent while that condition stands; a changed
//! condition starts the turn again. Each duty keeps the mark in the record
//! it owns for the condition: the overseer and GitHub duties in a baseline
//! row of their own per condition, the wake duty in the wake record its
//! mark already stands in.

use std::time::Duration;

use serde::{Deserialize, Serialize};

use crate::mailbox::Mailbox;
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
/// directory, the duty's own, and sent as the mailbox's owner notice. A
/// notice the mailbox refuses as a repeat of one that landed is the owner
/// already holding those words, which counts as sent; `Err` carries the
/// channel and the cause.
#[allow(
    clippy::disallowed_methods,
    reason = "the alert's notice file, the watch's own under its state directory"
)]
pub fn send(settings: &Settings, file: &str, text: &str) -> Result<(), String> {
    let notice = settings.state_dir.join(file);
    if let Some(dir) = notice.parent() {
        std::fs::create_dir_all(dir).map_err(|e| format!("channel=file {e}"))?;
    }
    std::fs::write(&notice, text).map_err(|e| format!("channel=file {e}"))?;
    let reach = crate::effects::fleet_reach(settings).map_err(|e| format!("channel=owner {e}"))?;
    Mailbox::new(reach.mail_program)
        .bounded(BOUND)
        .owner_notice(&reach.mail_root, &notice)
        .map_err(|refusal| format!("channel=owner {refusal}"))
}
