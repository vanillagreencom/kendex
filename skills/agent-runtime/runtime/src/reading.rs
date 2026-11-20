//! The three-valued reading every process and pane read answers with.
//!
//! A read of a process or a pane finds its subject live, with what was read
//! of it; gone, a successful read that found no such subject; or unreadable,
//! with the cause. No reader answers with a bool or an option, so a caller
//! cannot take an unreadable subject for an absent one without matching the
//! variant: each consumer maps `Unreadable` to its own unconfirmed outcome
//! and carries the cause.
//!
//! A reading dropped unread is a read that never happened, so the type is
//! `#[must_use]` and its consumers match the variants by name.

#![deny(clippy::wildcard_enum_match_arm)]

use serde::Serialize;

#[must_use]
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
#[serde(tag = "reading", rename_all = "kebab-case")]
pub enum Reading<T> {
    /// The subject stands; the payload is what was read of it.
    Live(T),
    /// The read succeeded and found no such subject: a pid no live process
    /// holds, a pane the server does not have.
    Gone,
    /// The read failed, or answered something it should not have. The
    /// cause is the stable word for what failed.
    Unreadable { cause: &'static str },
}

impl<T> Reading<T> {
    /// The same reading with a live payload transformed.
    pub fn map<U>(self, f: impl FnOnce(T) -> U) -> Reading<U> {
        match self {
            Reading::Live(value) => Reading::Live(f(value)),
            Reading::Gone => Reading::Gone,
            Reading::Unreadable { cause } => Reading::Unreadable { cause },
        }
    }
}

/// A failed read of a whole set, where "gone" means nothing: the process
/// table.
#[must_use]
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub struct Unreadable {
    pub cause: &'static str,
}
