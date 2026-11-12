//! The adoption's one store write: the controller record a hand-opened
//! controller's adoption writes or heals, on the pane read only this
//! module's reader mints.

use std::path::Path;

use serde_json::{Value, json};

use super::Recorded;
use crate::controller::{AdoptController, AdoptionRead, ControllerAdopted, MEMBER, Overseer};
use crate::error::{Error, Result};
use crate::journal::{self, intents};
use crate::record::{self, Document, Locking};

/// Apply an adoption: the one transition of the read-then-record
/// `adopt-controller`, on the identity the effects read in the pane. The
/// read travels as the token only the operation module mints from its own
/// pane read, so no caller supplies
/// adoption evidence.
pub(super) fn apply_adoption(
    path: &Path,
    r: &AdoptController,
    read: &Recorded<AdoptionRead>,
    locking: Locking,
) -> Result<ControllerAdopted> {
    journal::journal_kind(path, "adopt-controller")?;
    let read_doc = record::read_document(path)?.ok_or_else(|| Error::RecordMissing {
        path: path.to_path_buf(),
    })?;
    let mut doc = read_doc.clone();
    let adopted = adopt_controller(path, &mut doc, r, read.evidence())?;
    record::store(path, &read_doc, &doc, locking)?;
    Ok(adopted)
}

/// The record a hand-opened controller's adoption writes, or heals. The
/// same pane on the same server (`ol_owns`) keeps its record and its
/// generation: every launch field the request names replaces the recorded
/// one, a field it leaves out is kept, and the native `session_id` is the
/// request's or none, so a session resumed under a new id in the same pane
/// binds that id at its next hook run; the identity read in the pane is
/// written as the active one, and `pending`, `exit` and `off` are dropped.
/// Another session's record, or none, is replaced by this session's at the
/// next generation, with the fields of the session that ended left out.
fn adopt_controller(
    path: &Path,
    doc: &mut Document,
    r: &AdoptController,
    read: &AdoptionRead,
) -> Result<ControllerAdopted> {
    let intents = intents(path, doc)?;
    if let Some(intent) = intents.iter().find(|i| i.open() && i.op.on_controller()) {
        return Err(Error::IntentOpen {
            intent: intent.id.clone(),
            op: intent.op.word(),
            target: intent.target.clone(),
        });
    }
    let current: Option<Overseer> = record::field(path, doc, MEMBER)?;
    let prior_generation = current.as_ref().and_then(|o| o.generation).unwrap_or(0);
    let home = r.home.clone().or_else(|| r.account.clone());
    let rows = r.session_rows.as_ref().map(|p| p.display().to_string());
    if read.same {
        let record = record::object_mut(path, doc, MEMBER)?;
        let generation = prior_generation.max(1);
        record::set(record, "generation", generation);
        record::set(record, "server_start", read.server_start);
        record::set(record, "server_socket", read.socket.as_str());
        record::set(record, "harness", r.harness.as_str());
        for (key, value) in [
            ("account", &r.account),
            ("home", &home),
            ("model", &r.model),
            ("effort", &r.effort),
            ("cwd", &r.cwd),
            ("session_rows", &rows),
        ] {
            if let Some(value) = value {
                record::set(record, key, value.as_str());
            }
        }
        record::set(record, "session_id", json!(r.session_id));
        record::set(record, "harness_pid", read.identity.pid);
        record::set(record, "harness_start", read.identity.start.as_str());
        for (key, value) in adopted_posture(path, r)? {
            record::set(record, key, value);
        }
        for key in ["pending", "exit", "off"] {
            record::delete(record, key);
        }
        return Ok(ControllerAdopted {
            generation,
            healed: true,
        });
    }
    let generation = prior_generation + 1;
    let mut record = json!({
        "runtime": "tmux",
        "generation": generation,
        "server": read.server.to_string(),
        "server_start": read.server_start,
        "server_socket": read.socket,
        "pane": r.pane,
        "window": read.window,
        "session_rows": rows,
        "session_id": r.session_id,
        "harness_pid": read.identity.pid,
        "harness_start": read.identity.start,
        "harness": r.harness,
        "account": r.account,
        "home": home,
        "model": r.model,
        "effort": r.effort,
        "cwd": r.cwd,
    });
    for (key, value) in adopted_posture(path, r)? {
        record[key] = value;
    }
    record::set(doc, MEMBER, record);
    Ok(ControllerAdopted {
        generation,
        healed: false,
    })
}

/// The posture fields an adoption names, in the form a confirmed
/// succession records them, which `Caller::of` reads with no default.
fn adopted_posture(path: &Path, r: &AdoptController) -> Result<Vec<(&'static str, Value)>> {
    let mut fields = Vec::new();
    if let Some(permission) = r.permission {
        let value = serde_json::to_value(permission).map_err(|source| Error::Json {
            path: path.to_path_buf(),
            source,
        })?;
        fields.push(("permission", value));
    }
    if let Some(words) = &r.extra_args {
        fields.push(("extra_args", json!(words)));
    }
    Ok(fields)
}

#[cfg(test)]
mod tests {
    use std::fs;

    use serde_json::{Value, json};

    use super::*;
    use crate::process::Identity;

    const LOCK: Locking = Locking::FLOCK;

    fn object(path: &Path) -> Document {
        match serde_json::from_str(&fs::read_to_string(path).unwrap()).unwrap() {
            Value::Object(map) => map,
            other => panic!("not an object: {other}"),
        }
    }

    /// The adoption transition on the identity the effects read: the same
    /// pane on the same server is healed in place (fields filled only where
    /// empty, the identity written, `exit` and `off` dropped); another
    /// session's record is replaced at the next generation with none of the
    /// ended session's fields; an open controller intent refuses.
    #[test]
    fn adopt_controller_heals_its_own_pane_and_replaces_another_sessions_record() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join(record::FLEET_FILE_NAME);
        let request = AdoptController {
            pane: "%7".into(),
            socket: None,
            harness: "claude".into(),
            session_id: Some("fresh-session".into()),
            account: Some("/a/x".into()),
            home: None,
            model: Some("m".into()),
            effort: None,
            cwd: Some("/r".into()),
            session_rows: Some("/r/tmp/lane-mail/overseer/session-41020-7.jsonl".into()),
            permission: None,
            extra_args: None,
        };
        let read = |same: bool| {
            Recorded::planted(AdoptionRead {
                identity: Identity {
                    pid: 5151,
                    start: "ticks:5151".into(),
                },
                server: 41020,
                server_start: 1_769_590_000,
                socket: "/tmp/tmux-1000/default".into(),
                window: "@3".into(),
                same,
            })
        };
        // Heal: the record names %7 on 41020 and keeps its generation;
        // every field the request names replaces the recorded one, the
        // binding is the request's, the identity written, and the ended
        // session's `exit`, a standing `off` and a stale `pending` dropped.
        let healed_from = super::super::testing::FLEET.replacen(
            "\"session_id\": \"0f3d2c1b-9a8e-4d7c-b6a5-443322110000\",\n    \"harness_pid\": \"41388\"",
            "\"session_id\": \"before-resume\",\n    \"exit\": {\"status\": 0}, \"off\": {\"at\": \"x\"}, \"pending\": {\"harness\": \"claude\"},\n    \"harness_pid\": \"41388\"",
            1,
        );
        fs::write(&path, &healed_from).unwrap();
        let a = apply_adoption(&path, &request, &read(true), LOCK).unwrap();
        assert!(a.healed);
        assert_eq!(a.generation, 3);
        let after = object(&path)[MEMBER].clone();
        assert_eq!(after["harness"], json!("claude"));
        assert_eq!(after["account"], json!("/a/x"), "the request's");
        assert_eq!(after["home"], json!("/a/x"), "the request's account");
        assert_eq!(after["model"], json!("m"), "the request's");
        assert_eq!(after["cwd"], json!("/r"), "the request's");
        assert_eq!(
            after["session_rows"],
            json!("/r/tmp/lane-mail/overseer/session-41020-7.jsonl")
        );
        assert_eq!(after["session_id"], json!("fresh-session"));
        assert_eq!(after["harness_pid"], json!(5151));
        assert_eq!(after["harness_start"], json!("ticks:5151"));
        for gone in ["exit", "off", "pending"] {
            assert!(after.get(gone).is_none(), "{gone} dropped: {after}");
        }
        // A heal naming no model, effort or binding keeps the recorded
        // model and effort and clears the binding.
        fs::write(&path, &healed_from).unwrap();
        let bare = AdoptController {
            session_id: None,
            model: None,
            ..request.clone()
        };
        apply_adoption(&path, &bare, &read(true), LOCK).unwrap();
        let after = object(&path)[MEMBER].clone();
        assert_eq!(after["model"], json!("claude-opus-5-5"), "kept");
        assert_eq!(after["session_id"], Value::Null, "cleared");
        // Replace: another session's record goes, the new one is written
        // at the next generation with the request's identity.
        fs::write(&path, super::super::testing::FLEET).unwrap();
        let a = apply_adoption(&path, &request, &read(false), LOCK).unwrap();
        assert!(!a.healed);
        assert_eq!(a.generation, 4);
        let after = object(&path)[MEMBER].clone();
        assert_eq!(
            after,
            json!({
                "runtime": "tmux",
                "generation": 4,
                "server": "41020",
                "server_start": 1_769_590_000,
                "server_socket": "/tmp/tmux-1000/default",
                "pane": "%7",
                "window": "@3",
                "session_rows": "/r/tmp/lane-mail/overseer/session-41020-7.jsonl",
                "session_id": "fresh-session",
                "harness_pid": 5151,
                "harness_start": "ticks:5151",
                "harness": "claude",
                "account": "/a/x",
                "home": "/a/x",
                "model": "m",
                "effort": null,
                "cwd": "/r",
            })
        );
        // An open controller intent refuses.
        let mut fleet: Value = serde_json::from_str(super::super::testing::FLEET).unwrap();
        fleet["intents"] = json!([{
            "id": "request-transfer:overseer:3:1-1", "op": "request-transfer",
            "target": "overseer:3", "created_at": "2026-01-29T15:20:00Z",
            "outcome": "not-started"
        }]);
        fs::write(&path, serde_json::to_vec(&fleet).unwrap()).unwrap();
        let err = apply_adoption(&path, &request, &read(false), LOCK).unwrap_err();
        assert_eq!(err.key(), "intent-open");
    }
}
