//! Settings seeding through real applies. Split in two halves because the
//! file answers two questions: `apply` is what a pass PUTS in the
//! consumer's `kendex.settings.toml`, and `notes` is what it SAYS about
//! the keys it did not put there. The project each runs against, and the
//! two passes a scope can take over one, are in `scope`.
#![cfg(unix)]

#[path = "../../../test_util.rs"]
mod test_util;

mod apply;
mod notes;
mod scope;
