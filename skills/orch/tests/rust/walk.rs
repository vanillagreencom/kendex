//! The preference walk through the executable: the setting's entries
//! classified through the `kendex-launch` fixture (the one `kendex` on the
//! rows' `PATH`) and judged over accounts planted as the listing reads
//! them (`support::plant_accounts`: local directories with their
//! credentials and usage records, a provider's rows under its host), the
//! host's line the `lane-host` fixture's.
#![allow(
    clippy::disallowed_methods,
    reason = "the rows write the listings and the fleet they plant and read the fixtures' logs"
)]

#[path = "support.rs"]
mod support;

use agent_runtime::record::FLEET_FILE_NAME;
use std::path::{Path, PathBuf};
use std::sync::OnceLock;
use std::time::{SystemTime, UNIX_EPOCH};

use agent_runtime::clock;
use serde_json::{Value, json};
use support::*;

fn now() -> u64 {
    static NOW: OnceLock<u64> = OnceLock::new();
    *NOW.get_or_init(|| {
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_secs()
    })
}

fn stamp(at: u64) -> String {
    clock::iso_utc(at)
}

/// A cloud-session host's line and a cloud-task host's.
const CLOUD_LINE: &str = "kind=claude-cloud\tlaunch=cloud-session\tchannel=session\tfiles=none\tstatus=none\tstop=none\tpool=cloud-credit\n";

const TASK_LINE: &str = "kind=claude-cloud\tlaunch=cloud-task\tchannel=session\tfiles=none\tstatus=task\tstop=none\tpool=cloud-credit\n";

/// One world: the accounts planted under `home` as the listing reads them
/// (`plant_accounts`), the host fixture as `lane-host`, the usage fixture
/// as `bin/curl` and the `kendex-launch` fixture as `bin/kendex`, both
/// first on the executable's `PATH`, an empty fleet, and no burn (the
/// projection is the reading).
struct World {
    dir: tempfile::TempDir,
    env: Vec<(String, String)>,
}

impl World {
    fn new(extra: &[(&str, &str)]) -> World {
        let dir = tempfile::tempdir().unwrap();
        std::fs::create_dir_all(dir.path().join("bin")).unwrap();
        std::fs::create_dir_all(dir.path().join("home")).unwrap();
        for (name, fixture) in [
            ("lane-host", "lane-host/lane-host"),
            ("bin/curl", "usage-curl/curl"),
            ("bin/kendex", "kendex-launch/kendex"),
        ] {
            let base = if fixture.starts_with("lane-host") {
                fixtures()
            } else {
                account_fixtures()
            };
            std::os::unix::fs::symlink(base.join(fixture), dir.path().join(name)).unwrap();
        }
        install_lane_host(dir.path(), dir.path());
        let base = [
            ("HOME", dir.path().join("home").display().to_string()),
            ("OVERSEE_WATCH_STATE_DIR", dir.path().display().to_string()),
            (
                "AGENT_RUNTIME_ACCOUNT_STATE_DIR",
                dir.path().display().to_string(),
            ),
            ("ORCH_STATE_DIR", dir.path().display().to_string()),
            (
                "USAGE_FIXTURE_DIR",
                dir.path().join("fixtures").display().to_string(),
            ),
            ("AGENT_RUNTIME_ACCOUNT_BURN_PCT_PER_HOUR", "0".to_owned()),
        ];
        let mut env: Vec<(String, String)> = base
            .iter()
            .map(|(k, v)| ((*k).to_owned(), v.clone()))
            .collect();
        env.extend(
            extra
                .iter()
                .map(|(k, v)| ((*k).to_owned(), (*v).to_owned())),
        );
        let world = World { dir, env };
        world.write_fleet(None);
        world
    }

    fn path(&self) -> &Path {
        self.dir.path()
    }

    fn bin(&self) -> PathBuf {
        self.path().join("bin")
    }

    /// The accounts the listing lists: the local rows as directories under
    /// the home with their records sampled at `now`, the provider's rows
    /// under `host`.
    fn plant(&mut self, host: Option<&str>, rows: &[Value], now: u64) {
        let env = plant_accounts(self.path(), self.path(), host, rows, now);
        for (key, value) in env {
            self.env.retain(|(k, _)| *k != key);
            self.env.push((key, value));
        }
    }

    fn plant_host_listing(&mut self, host: &str, rows: &[Value]) {
        self.plant(Some(host), rows, now());
    }

    fn plant_capabilities(&self, lines: &[(&str, &str)]) {
        let path = self.path().join("lane-host.json");
        let mut map: Value = std::fs::read_to_string(&path)
            .ok()
            .and_then(|t| serde_json::from_str(&t).ok())
            .unwrap_or_else(|| json!({}));
        for (host, line) in lines {
            map[format!("{host} capabilities")] = json!({"stdout": line});
        }
        std::fs::write(path, map.to_string()).unwrap();
    }

    fn write_fleet(&self, overseer_account: Option<&str>) {
        let mut fleet = json!({
            "issue_id": "oversee", "triaged": [], "launch_queue": [], "lanes": [], "fleet_log": []
        });
        if let Some(account) = overseer_account {
            fleet["overseer"] = json!({"account": account});
        }
        std::fs::write(
            self.path().join(FLEET_FILE_NAME),
            serde_json::to_string(&fleet).unwrap(),
        )
        .unwrap();
    }

    /// `lane walk --fleet` with `args`, under the boundary, in this
    /// world.
    fn walk(&self, args: &[&str]) -> std::process::Output {
        let mut command = isolated();
        command
            .current_dir(self.path())
            .env("PATH", tool_path(&[&self.bin()]))
            .args(["lane", "walk", "--fleet"])
            .args(args);
        for (key, value) in &self.env {
            command.env(key, value);
        }
        command.output().unwrap()
    }

    /// The reply's `result` of a walk that answered.
    fn answered(&self, args: &[&str]) -> Value {
        let out = self.walk(args);
        assert!(out.status.success(), "{}", stderr(&out));
        let reply: Value = serde_json::from_slice(&out.stdout).unwrap();
        assert_eq!(reply["ok"], json!(true), "{reply}");
        reply["result"].clone()
    }
}

/// The skipped entries as `entry reason lane`.
fn skipped(result: &Value) -> Vec<String> {
    result["skipped"]
        .as_array()
        .unwrap()
        .iter()
        .map(|s| {
            format!(
                "{} {} {}",
                s["entry"].as_str().unwrap(),
                s["reason"].as_str().unwrap(),
                s["lane"].as_str().unwrap_or("none")
            )
        })
        .collect()
}

fn strings(value: &Value) -> Vec<String> {
    value
        .as_array()
        .unwrap()
        .iter()
        .map(|v| v.as_str().unwrap().to_owned())
        .collect()
}

/// One measured local Claude row at `alias`, `used` percent on its weekly
/// window (the binding, resetting 60 hours on), and the 5-hour figure the
/// endpoint still sends at `session` percent, which no judgement reads.
fn measured(alias: &str, used: u64, session: u64) -> Value {
    let weekly = stamp(now() + 60 * 3600);
    json!({
        "alias": alias,
        "harness": "claude",
        "config_dir": format!("/home/me/.{alias}"),
        "measured_through": "local",
        "status": "ok",
        "verdict": if used < 95 { "room" } else { "walled" },
        "headroom_pct": 100 - used,
        "binding_bucket": "weekly",
        "binding_resets_at": weekly,
        "wall": used,
        "session_5h_pct": session,
        "weekly_pct": used,
        "monthly_pct": null,
        "model_buckets": [],
        "resets": {"session": stamp(now() + 3600), "weekly": weekly, "model": null, "monthly": null},
        "usage_rate_state": "one-sample",
        "usage_age_s": 0,
        "claims": 0,
        "pool": "plan"
    })
}

/// A measured Codex row at `alias`, `used` percent on its weekly window.
fn codex(alias: &str, used: u64) -> Value {
    let mut row = measured(alias, used, 5);
    row["harness"] = json!("codex");
    row
}

/// The provider's reading of the account `measured` describes.
fn through_host(mut row: Value) -> Value {
    row["measured_through"] = json!("host");
    row["usage_age_s"] = Value::Null;
    row
}

const BYPASS: &str = "--dangerously-skip-permissions";

#[test]
fn a_cloud_session_entry_is_skipped_for_a_relaunch_and_a_cloud_task_host_always() {
    let mut world = World::new(&[
        (
            "ORCH_LANE_PREFERENCE",
            "claude@cloudy:claude-opus-5-5:high,codex@cloudy:gpt-6.1-sol:high,claude@tasky:claude-opus-5-5:high,pi@local:openai/gpt-5:high,codex@local:gpt-6.1-sol:high",
        ),
        ("ORCH_LANE_HOST", "cloudy"),
    ]);
    world.plant_capabilities(&[("cloudy", CLOUD_LINE), ("tasky", TASK_LINE)]);
    world.plant_host_listing(
        "cloudy",
        &[through_host(measured("aclaude", 10, 5)), codex("codex", 20)],
    );
    let args = [
        "--source-harness",
        "claude",
        "--source-flags",
        BYPASS,
        "--replaces",
        "KEN-1",
    ];
    let result = world.answered(&args);
    assert_eq!(result["answer"], json!("lane"), "{result}");
    assert_eq!(
        result["chosen"]["entry"],
        json!("codex@local:gpt-6.1-sol:high")
    );
    assert_eq!(result["chosen"]["host"], json!("local"));
    assert_eq!(result["chosen"]["launch"], json!("window"));
    assert_eq!(
        skipped(&result),
        [
            "claude@cloudy:claude-opus-5-5:high host-launch none",
            "codex@cloudy:gpt-6.1-sol:high host-launch none",
            "claude@tasky:claude-opus-5-5:high host-launch none",
            "pi@local:openai/gpt-5:high unmeasured none",
        ]
    );
    assert_eq!(result["skipped"][0]["launch"], json!("cloud-session"));
    assert_eq!(result["skipped"][2]["launch"], json!("cloud-task"));
    assert_eq!(strings(&result["unread"]), ["pi@local:openai/gpt-5:high"]);
    // Not a relaunch: the Claude cloud entry is asked under its host, whose
    // account the judge leaves out by word (no repository access from this
    // checkout).
    let result = world.answered(&args[..4]);
    assert_eq!(
        result["chosen"]["entry"],
        json!("codex@local:gpt-6.1-sol:high"),
        "{result}"
    );
    assert_eq!(
        skipped(&result)[0],
        "claude@cloudy:claude-opus-5-5:high cloud-repo-unset /home/me/.aclaude"
    );
    assert_eq!(strings(&result["unread"]), ["pi@local:openai/gpt-5:high"]);
}
