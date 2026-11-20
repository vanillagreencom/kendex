//! The watch's baseline: what each duty last saw, so a duty prints news
//! once. The record is one typed value with one writer, `Baseline::store`,
//! and a duty reads a snapshot of it and hands back the changes it wants
//! made.
//!
//! The pass stamps the runner itself keeps are one row per duty, keyed by
//! the duty: the end of the last mail turn, the start of the last run of
//! each long duty (each duty resumes from its own) and the last heartbeat,
//! each an epoch second, from which a restarted runner continues each
//! cadence. Every other row is a duty's own, keyed by kind and identity.

use std::collections::BTreeMap;
use std::io::Write;
use std::path::Path;

use serde::{Deserialize, Serialize};

use crate::error::{Result, WatchError};
use crate::schedule::Duty;

/// One duty row: `kind`, the identity it is about (an item, a repository,
/// `fleet`) and its value.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Row {
    pub kind: String,
    pub identity: String,
    pub value: String,
}

/// The cadences the runner runs on, recorded so `watch status` computes the
/// due times from the rows below without the runner's flags.
#[derive(Debug, Clone, PartialEq, Eq, Serialize, Deserialize)]
pub struct Cadences {
    pub mail_secs: u64,
    pub interval_secs: u64,
    pub max_loops: u32,
}

#[derive(Debug, Clone, PartialEq, Eq, Default, Serialize, Deserialize)]
pub struct Baseline {
    #[serde(default, skip_serializing_if = "Option::is_none")]
    pub cadences: Option<Cadences>,
    /// The epoch second each duty's cadence counts from: the mail turn's
    /// end, every other duty's start.
    #[serde(default, skip_serializing_if = "BTreeMap::is_empty")]
    pub passes: BTreeMap<Duty, u64>,
    #[serde(default)]
    pub rows: Vec<Row>,
}

/// One change a duty asks for, applied after its event lines are durable.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum Change {
    /// The runner's own stamp of a duty's run.
    Pass {
        duty: Duty,
        at: u64,
    },
    Set {
        kind: String,
        identity: String,
        value: String,
    },
    Clear {
        kind: String,
        identity: String,
    },
}

fn record_error(path: &Path, op: &'static str, cause: String) -> WatchError {
    WatchError::Record {
        path: path.to_path_buf(),
        op,
        cause,
    }
}

impl Baseline {
    /// The record at `path`; an absent file is the empty baseline, a file
    /// that cannot be read or parsed is refused, never taken as empty.
    pub fn load(path: &Path) -> Result<Baseline> {
        match std::fs::read(path) {
            Ok(bytes) => serde_json::from_slice(&bytes)
                .map_err(|e| record_error(path, "parse", e.to_string()).into()),
            Err(e) if e.kind() == std::io::ErrorKind::NotFound => Ok(Baseline::default()),
            Err(e) => Err(record_error(path, "read", e.to_string()).into()),
        }
    }

    /// The value of the row `kind` holds for `identity`.
    pub fn get(&self, kind: &str, identity: &str) -> Option<&str> {
        self.rows
            .iter()
            .find(|r| r.kind == kind && r.identity == identity)
            .map(|r| r.value.as_str())
    }

    /// The identities the rows of `kind` are about.
    pub fn identities(&self, kind: &str) -> Vec<String> {
        self.rows
            .iter()
            .filter(|r| r.kind == kind)
            .map(|r| r.identity.clone())
            .collect()
    }

    pub fn apply(&mut self, change: Change) {
        match change {
            Change::Pass { duty, at } => {
                self.passes.insert(duty, at);
            }
            Change::Set {
                kind,
                identity,
                value,
            } => {
                match self
                    .rows
                    .iter_mut()
                    .find(|r| r.kind == kind && r.identity == identity)
                {
                    Some(row) => row.value = value,
                    None => self.rows.push(Row {
                        kind,
                        identity,
                        value,
                    }),
                }
            }
            Change::Clear { kind, identity } => {
                self.rows
                    .retain(|r| !(r.kind == kind && r.identity == identity));
            }
        }
    }

    /// Write the record whole: a temporary file beside it, synced, then
    /// renamed into place, so a reader never sees half of one.
    #[allow(
        clippy::disallowed_methods,
        reason = "the baseline's one writer: the runner's own record beside the fleet state, replaced atomically"
    )]
    pub fn store(&self, path: &Path) -> Result<()> {
        let tmp = path.with_extension("json.tmp");
        let bytes = serde_json::to_vec_pretty(self)
            .map_err(|e| record_error(path, "serialize", e.to_string()))?;
        let write = || -> std::io::Result<()> {
            let mut file = std::fs::OpenOptions::new()
                .write(true)
                .create(true)
                .truncate(true)
                .open(&tmp)?;
            file.write_all(&bytes)?;
            file.sync_data()?;
            std::fs::rename(&tmp, path)
        };
        write().map_err(|e| record_error(path, "write", e.to_string()).into())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    /// The row store's contract: a set replaces or appends, a clear removes,
    /// a get reads by both keys, and each duty's pass stamp is its own.
    #[test]
    fn rows_are_keyed_by_kind_and_identity() {
        let mut b = Baseline::default();
        let set = |kind: &str, identity: &str, value: &str| Change::Set {
            kind: kind.to_owned(),
            identity: identity.to_owned(),
            value: value.to_owned(),
        };
        b.apply(set("merged", "KEN-1", "a"));
        b.apply(set("merged", "KEN-2", "b"));
        b.apply(set("handoff", "KEN-1", "h"));
        b.apply(set("merged", "KEN-1", "c"));
        assert_eq!(b.get("merged", "KEN-1"), Some("c"));
        assert_eq!(b.get("merged", "KEN-2"), Some("b"));
        assert_eq!(b.get("handoff", "KEN-1"), Some("h"));
        assert_eq!(b.rows.len(), 3, "a set of a held row replaces it");
        assert_eq!(b.identities("merged"), vec!["KEN-1", "KEN-2"]);
        b.apply(Change::Clear {
            kind: "merged".into(),
            identity: "KEN-1".into(),
        });
        assert_eq!(b.get("merged", "KEN-1"), None);
        assert_eq!(b.get("merged", "KEN-2"), Some("b"));
        b.apply(Change::Pass {
            duty: Duty::Mail,
            at: 7,
        });
        b.apply(Change::Pass {
            duty: Duty::Verification,
            at: 8,
        });
        b.apply(Change::Pass {
            duty: Duty::Heartbeat,
            at: 9,
        });
        b.apply(Change::Pass {
            duty: Duty::Verification,
            at: 10,
        });
        assert_eq!(
            b.passes,
            BTreeMap::from([
                (Duty::Mail, 7),
                (Duty::Verification, 10),
                (Duty::Heartbeat, 9)
            ])
        );
        // The record round-trips with the duty's word as the key.
        let text = serde_json::to_string(&b).unwrap();
        assert!(text.contains("\"verification\":10"), "{text}");
        assert_eq!(serde_json::from_str::<Baseline>(&text).unwrap(), b);
    }
}
