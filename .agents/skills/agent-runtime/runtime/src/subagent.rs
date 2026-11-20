//! A subagent a session spawns inside its own harness: the spawn parameters
//! for a canonical agent name, and the room the harness's thread cap leaves.
//!
//! The canonical hyphenated name is the identity everything a caller records
//! keys on. Codex's `spawn_agent` takes a `task_name` of `[a-z0-9_]` only and
//! rejects a hyphenated one before launch, so the runtime spelling is made
//! here and confined to `record.runtime_metadata`: a caller cannot key state
//! on it by accident. Only Codex has such a spelling; the other harnesses
//! refuse by name.

use std::path::{Path, PathBuf};

use serde::Serialize;

use crate::error::{Error, Result};
use crate::harness::Harness;
use crate::trust;

/// Codex's cap on concurrent threads a session holds, the primary counted.
const CAP_SECTION: &str = "features.multi_agent_v2";
const CAP_KEY: &str = "max_concurrent_threads_per_session";
/// The cap Codex runs with where its config sets none.
const DEFAULT_CAP: u64 = 4;

/// What to hand `spawn_agent`, and what to record.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Spawn {
    pub canonical: String,
    pub spawn: SpawnArgs,
    pub fallback: bool,
    pub record: Record,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct SpawnArgs {
    pub agent_type: String,
    pub task_name: String,
    /// A spawned agent starts from its delegation message alone: a forked
    /// history carries the parent's runtime settings into the child.
    pub fork_turns: &'static str,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Record {
    pub identity_key: String,
    pub runtime_metadata: RuntimeMetadata,
}

#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct RuntimeMetadata {
    pub task_name: String,
    pub agent_type: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub fallback_reason: Option<String>,
}

/// The thread room as far as a program can read it.
#[derive(Debug, Clone, PartialEq, Eq, Serialize)]
pub struct Room {
    pub config_path: PathBuf,
    pub effective_cap: u64,
    pub cap_source: CapSource,
    pub in_use: InUse,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum CapSource {
    Config,
    Default,
}

/// The threads a running session holds are listed only to that session, by
/// its own `list_agents`: no program outside it can count them.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum InUse {
    Unread,
}

fn unsupported(harness: Harness) -> Error {
    Error::refused(
        "subagent-harness-unsupported",
        &[("harness", harness.name())],
    )
}

/// The spawn of `canonical` on `harness`; with `fallback`, the generic
/// worker spawns in its place for that reason, the identity still
/// `canonical`. A name already in the runtime spelling is refused apart from
/// any other bad name: its caller is about to record the runtime spelling.
pub fn spawn(harness: Harness, canonical: &str, fallback: Option<&str>) -> Result<Spawn> {
    match harness {
        Harness::Codex => {}
        Harness::Claude | Harness::Copilot | Harness::Pi => return Err(unsupported(harness)),
    }
    if canonical.contains('_') {
        return Err(Error::refused(
            "subagent-name-translated",
            &[("canonical", canonical)],
        ));
    }
    let mut chars = canonical.chars();
    let canonical_alphabet = chars.next().is_some_and(|c| c.is_ascii_alphanumeric())
        && chars.all(|c| c.is_ascii_alphanumeric() || c == '-');
    if !canonical_alphabet {
        return Err(Error::refused(
            "subagent-name-invalid",
            &[("canonical", canonical)],
        ));
    }
    if fallback == Some("") {
        return Err(Error::refused("subagent-fallback-empty", &[]));
    }
    let task_name = canonical.to_ascii_lowercase().replace('-', "_");
    let agent_type = match fallback {
        Some(_) => "worker".to_owned(),
        None => canonical.to_owned(),
    };
    Ok(Spawn {
        canonical: canonical.to_owned(),
        spawn: SpawnArgs {
            agent_type: agent_type.clone(),
            task_name: task_name.clone(),
            fork_turns: "none",
        },
        fallback: fallback.is_some(),
        record: Record {
            identity_key: canonical.to_owned(),
            runtime_metadata: RuntimeMetadata {
                task_name,
                agent_type,
                fallback_reason: fallback.map(str::to_owned),
            },
        },
    })
}

/// The room on `harness` under the harness home `home`: the cap its
/// config.toml sets, or Codex's default where it sets none. A config that
/// stands and cannot be read, or a cap that is not a whole number, refuses:
/// the default in its place would be a guess against what the file says.
pub fn room(harness: Harness, home: Option<&Path>) -> Result<Room> {
    match harness {
        Harness::Codex => {}
        Harness::Claude | Harness::Copilot | Harness::Pi => return Err(unsupported(harness)),
    }
    let home = home
        .ok_or_else(|| Error::refused("subagent-home-unknown", &[("harness", harness.name())]))?;
    let config_path = home.join("config.toml");
    let (effective_cap, cap_source) =
        match trust::config_value(&config_path, CAP_SECTION, CAP_KEY, harness)? {
            None => (DEFAULT_CAP, CapSource::Default),
            Some(value) => match value.parse::<u64>() {
                Ok(cap) => (cap, CapSource::Config),
                Err(_) => return Err(Error::refused("cap-unreadable", &[("value", &value)])),
            },
        };
    Ok(Room {
        config_path,
        effective_cap,
        cap_source,
        in_use: InUse::Unread,
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    fn key(e: &Error) -> &'static str {
        match e {
            Error::Refused { key, .. } => key,
            other => panic!("{other}"),
        }
    }

    /// A Codex home under a fresh root, its config written from `body`.
    fn home(body: &str) -> (tempfile::TempDir, PathBuf) {
        let root = tempfile::tempdir().unwrap();
        let home = root.path().join("codex");
        std::fs::create_dir_all(&home).unwrap();
        std::fs::write(home.join("config.toml"), body).unwrap();
        (root, home)
    }

    #[test]
    fn a_codex_spawn_lowers_and_underscores_the_task_name_and_keeps_the_canonical_agent_type() {
        let s = spawn(Harness::Codex, "Reviewer-Arch", None).unwrap();
        assert_eq!(s.canonical, "Reviewer-Arch");
        assert_eq!(s.spawn.task_name, "reviewer_arch");
        assert_eq!(s.spawn.agent_type, "Reviewer-Arch");
        assert!(!s.fallback);
        assert_eq!(s.record.identity_key, "Reviewer-Arch");
        assert_eq!(s.record.runtime_metadata.task_name, "reviewer_arch");
        assert_eq!(s.record.runtime_metadata.agent_type, "Reviewer-Arch");
        assert_eq!(s.record.runtime_metadata.fallback_reason, None);
    }

    #[test]
    fn a_spawn_forks_no_turns_and_names_no_v1_field() {
        let reply =
            serde_json::to_value(spawn(Harness::Codex, "reviewer-arch", None).unwrap()).unwrap();
        assert_eq!(
            reply["spawn"],
            serde_json::json!({
                "agent_type": "reviewer-arch",
                "task_name": "reviewer_arch",
                "fork_turns": "none",
            })
        );
        assert_eq!(
            reply["record"]["runtime_metadata"],
            serde_json::json!({"task_name": "reviewer_arch", "agent_type": "reviewer-arch"})
        );
    }

    #[test]
    fn a_name_already_in_the_runtime_spelling_is_refused_as_translated() {
        let e = spawn(Harness::Codex, "reviewer_arch", None).unwrap_err();
        assert_eq!(key(&e), "subagent-name-translated");
    }

    #[test]
    fn a_name_outside_the_canonical_alphabet_is_refused() {
        for (name, valid) in [
            ("bad name!", false),
            ("-x", false),
            ("", false),
            ("r\u{e9}viewer", false),
            ("9-", true),
            ("maintainer", true),
        ] {
            match spawn(Harness::Codex, name, None) {
                Ok(s) => assert!(valid, "{name:?} accepted as {s:?}"),
                Err(e) => {
                    assert!(!valid, "{name:?} refused: {e}");
                    assert_eq!(key(&e), "subagent-name-invalid", "{name:?}");
                }
            }
        }
    }

    #[test]
    fn a_fallback_spawns_the_worker_and_still_records_the_canonical_identity() {
        let reason = "runtime does not expose this agent_type";
        let s = spawn(Harness::Codex, "reviewer-safety", Some(reason)).unwrap();
        assert_eq!(s.spawn.agent_type, "worker");
        assert_eq!(s.spawn.task_name, "reviewer_safety");
        assert!(s.fallback);
        assert_eq!(s.record.identity_key, "reviewer-safety");
        assert_eq!(s.record.runtime_metadata.agent_type, "worker");
        assert_eq!(
            s.record.runtime_metadata.fallback_reason.as_deref(),
            Some(reason)
        );
    }

    #[test]
    fn an_empty_fallback_reason_is_refused() {
        let e = spawn(Harness::Codex, "reviewer-arch", Some("")).unwrap_err();
        assert_eq!(key(&e), "subagent-fallback-empty");
    }

    #[test]
    fn the_v2_key_sets_the_cap_and_its_absence_answers_the_default() {
        for (body, cap, source) in [
            (
                "[features.multi_agent_v2]\nmax_concurrent_threads_per_session = 8\n",
                8,
                CapSource::Config,
            ),
            (
                "[features.multi_agent_v2]\nmax_concurrent_threads_per_session = \"6\"\n",
                6,
                CapSource::Config,
            ),
            (
                "[features.multi_agent_v2]\nmax_concurrent_threads_per_session = 5\n[agents]\nmax_threads = 12\n",
                5,
                CapSource::Config,
            ),
            (
                "[agents]\nmax_threads = 12\n",
                DEFAULT_CAP,
                CapSource::Default,
            ),
            ("", DEFAULT_CAP, CapSource::Default),
        ] {
            let (_root, home) = home(body);
            let room = room(Harness::Codex, Some(&home)).unwrap();
            assert_eq!(room.config_path, home.join("config.toml"), "{body:?}");
            assert_eq!(room.effective_cap, cap, "{body:?}");
            assert_eq!(room.cap_source, source, "{body:?}");
            assert_eq!(room.in_use, InUse::Unread, "{body:?}");
        }
        let root = tempfile::tempdir().unwrap();
        let room = room(Harness::Codex, Some(&root.path().join("none"))).unwrap();
        assert_eq!(
            (room.effective_cap, room.cap_source),
            (DEFAULT_CAP, CapSource::Default)
        );
    }

    #[test]
    fn an_unreadable_config_or_cap_refuses_and_never_defaults() {
        let root = tempfile::tempdir().unwrap();
        let directory = root.path().join("directory");
        std::fs::create_dir_all(directory.join("config.toml")).unwrap();
        let dangling = root.path().join("dangling");
        std::fs::create_dir_all(&dangling).unwrap();
        std::os::unix::fs::symlink(root.path().join("gone"), dangling.join("config.toml")).unwrap();
        for home in [&directory, &dangling] {
            let e = room(Harness::Codex, Some(home)).unwrap_err();
            assert_eq!(key(&e), "config-unreadable", "{}", home.display());
        }
        for value in ["\"eight\"", "8.5", "-3"] {
            let (_root, home) = home(&format!(
                "[features.multi_agent_v2]\nmax_concurrent_threads_per_session = {value}\n"
            ));
            let e = room(Harness::Codex, Some(&home)).unwrap_err();
            assert_eq!(key(&e), "cap-unreadable", "{value}");
        }
        let e = room(Harness::Codex, None).unwrap_err();
        assert_eq!(key(&e), "subagent-home-unknown");
    }

    #[test]
    fn a_harness_without_subagent_spelling_is_refused_by_name() {
        let root = tempfile::tempdir().unwrap();
        for harness in [Harness::Claude, Harness::Copilot, Harness::Pi] {
            let e = spawn(harness, "reviewer-arch", None).unwrap_err();
            assert_eq!(key(&e), "subagent-harness-unsupported", "{harness:?}");
            let e = room(harness, Some(root.path())).unwrap_err();
            assert_eq!(key(&e), "subagent-harness-unsupported", "{harness:?}");
        }
    }
}
