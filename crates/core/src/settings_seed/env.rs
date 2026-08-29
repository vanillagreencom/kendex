//! Whether a file has anywhere a seed can go: where it declares `env`,
//! and in what shape.
//!
//! TOML lets one name be a table, an array of tables, or a value, and
//! never two of those. So a file that already declares `env` at the top
//! level has nowhere a seed can go: writing `[env]` beside the
//! declaration defines the name twice and the file stops loading at all,
//! and writing inside an array element puts a setting under a header no
//! loader reads. The shape is refused rather than written around, and the
//! plan says so.
//!
//! Split from the seeding above it because the two answer different
//! questions. This one never decides what to write or where — it only
//! says whether the document has room at all, which is the question both
//! [`super::merge`] and the plan's refusal ask before anything else.

use super::{assignment_key, table_row};

/// How a file declares `env` somewhere a seed cannot go, and where.
#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum EnvBlocked {
    /// `[[env]]` opens an array of tables on this line.
    Array(u32),
    /// A top-level assignment names `env` on this line: `env = "a"`
    /// declares it a value, and `env.MODE = "a"` declares it a table by
    /// dotted key, which a `[env]` header may not reopen.
    Assigned(u32),
}

impl EnvBlocked {
    /// What the file did, as a refusal or a drift note says it.
    pub fn problem(self) -> String {
        match self {
            EnvBlocked::Array(line) => format!("declares env as an array of tables on line {line}"),
            EnvBlocked::Assigned(line) => {
                format!("assigns env on line {line} rather than opening it as a table")
            }
        }
    }
}

/// Where this file declares `env` somewhere a seed cannot go, if it does.
///
/// Top level is everything above the first table header, because that is
/// the only region whose names are the document's own: `env.MODE` under
/// `[other]` names `other.env`, which the `[env]` a seed opens has
/// nothing to do with.
pub fn env_blocked(text: &str) -> Option<EnvBlocked> {
    let mut top_level = true;
    for row in crate::settings_toml::rows(text) {
        if table_row(&row) {
            if crate::settings_toml::header_of(row.text)
                .is_some_and(|header| header.array && header.path == ["env"])
            {
                return Some(EnvBlocked::Array(row.line));
            }
            top_level = false;
            continue;
        }
        if top_level && assignment_key(&row).is_some_and(|name| name == "env") {
            return Some(EnvBlocked::Assigned(row.line));
        }
    }
    None
}
