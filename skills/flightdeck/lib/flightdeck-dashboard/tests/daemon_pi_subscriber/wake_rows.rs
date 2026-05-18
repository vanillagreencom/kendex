use std::error::Error;

use serde_json::Value;
use tokio::time::Duration;

use super::common::pi_daemon::*;

#[tokio::test]
async fn pi_subscriber_appends_bg_task_exit_wakes_without_wake_pending(
) -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let state_file = temp.path().join("flightdeck-state-s505.json");
    write_state(&state_file, "issue")?;
    let bridge = write_fake_bridge(
        temp.path(),
        r#"
if [[ "$1" == "stream" ]]; then
  echo '{"type":"bridge_hello"}'
  echo '{"type":"event","event":"message_end","data":{"message":{"customType":"vstack-background-tasks:event","details":{"eventType":"exit","task":{"id":"bg-3","status":"failed","exitCode":null,"command":"echo hi","outputBytes":89}}}}}'
  echo '{"type":"event","event":"message_end","data":{"message":{"customType":"vstack-background-tasks:event","details":{"eventType":"exit","task":{"id":"bg-4","status":"completed","exitCode":0,"command":"true","outputBytes":7}}}}}'
  exit 0
fi
exit 0
"#,
    )?;

    let mut daemon = spawn_daemon(temp.path(), &state_file, &bridge, &[]).await?;
    let rows = wait_for_wake_rows(temp.path(), 2).await?;
    let row = rows
        .iter()
        .find(|row| row.get("classifier_tag").and_then(Value::as_str) == Some("pi-bg-task-exit"))
        .ok_or("pi-bg-task-exit row missing")?;
    assert_eq!(row["pane_id"], PANE_ID);
    assert_eq!(row["harness"], "pi");
    assert_eq!(row["event_type"], "bg-task-exit");
    assert_eq!(row["task"]["id"], "bg-3");
    assert_eq!(row["task"]["status"], "failed");
    assert!(row["hash"].as_str().is_some_and(|hash| hash.len() == 12));
    assert!(
        rows.iter().any(|row| row["task"]["id"] == "bg-4"),
        "second bg-task-exit row appended"
    );
    assert!(
        !wake_pending_path(temp.path()).exists(),
        "subscriber append must not create wake_pending"
    );

    daemon.stop();
    Ok(())
}

#[tokio::test]
async fn subagent_completion_emits_wake() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let state_file = temp.path().join("flightdeck-state-s505.json");
    write_state(&state_file, "issue")?;
    let bridge = write_fake_bridge(
        temp.path(),
        r#"
if [[ "$1" == "stream" ]]; then
  echo '{"type":"event","event":"message_end","data":{"message":{"customType":"vstack-pi-agents-tmux:event","details":{"eventType":"subagent-completion","completions":[{"id":"rust-1","status":"failed"}]}}}}'
  echo '{"type":"event","event":"message_end","data":{"message":{"customType":"subagent-completion","details":{"completions":[{"id":"rust-2","status":"completed"}]}}}}'
  sleep 5
fi
exit 0
"#,
    )?;

    let mut daemon = spawn_daemon(temp.path(), &state_file, &bridge, &[]).await?;
    let rows = wait_for_wake_rows(temp.path(), 1).await?;
    assert_eq!(rows.len(), 1, "completed subagent completion does not wake");
    let row = &rows[0];
    assert_eq!(row["pane_id"], PANE_ID);
    assert_eq!(row["event_type"], "subagent-completion");
    assert_eq!(row["classifier_tag"], "pi-subagent-completion");
    assert_eq!(row["completion"]["eventType"], "subagent-completion");
    assert_eq!(row["completion"]["completions"][0]["status"], "failed");

    daemon.stop();
    Ok(())
}

#[tokio::test]
async fn pi_subscriber_domain_guard_blocks_issue_only_tags() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let state_file = temp.path().join("flightdeck-state-s505.json");
    write_state(&state_file, "adhoc")?;
    let bridge = write_fake_bridge(
        temp.path(),
        r#"
if [[ "$1" == "stream" ]]; then
  echo '{"type":"event","event":"message_end","data":{"message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"Ready to merge now"}]}}}'
  echo '{"type":"event","event":"message_end","data":{"message":{"customType":"vstack-background-tasks:event","details":{"eventType":"exit","task":{"id":"bg-4","status":"completed","exitCode":0,"command":"true","outputBytes":7}}}}}'
  exit 0
fi
exit 0
"#,
    )?;

    let mut daemon = spawn_daemon(temp.path(), &state_file, &bridge, &[]).await?;
    let rows = wait_for_wake_rows(temp.path(), 2).await?;
    let tags = rows
        .iter()
        .filter_map(|row| row.get("classifier_tag").and_then(Value::as_str))
        .collect::<Vec<_>>();
    assert!(tags.contains(&"domain-mismatch"));
    assert!(tags.contains(&"pi-bg-task-exit"));
    assert!(!tags.contains(&"merge-now"));

    daemon.stop();
    Ok(())
}

#[tokio::test]
async fn workflow_pi_idle_state_emits_terminal_wake() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let state_file = temp.path().join("flightdeck-state-s505.json");
    write_state(&state_file, "workflow")?;
    let bridge = write_fake_bridge(
        temp.path(),
        r#"
if [[ "$1" == "stream" ]]; then
  echo '{"type":"event","event":"message_end","data":{"message":{"role":"assistant","stopReason":"stop","content":[{"type":"text","text":"workflow done"}]}}}'
  sleep 5
elif [[ "$1" == "state" ]]; then
  echo '{"data":{"isIdle":true,"hasPendingMessages":false}}'
fi
exit 0
"#,
    )?;

    let mut daemon = spawn_daemon(temp.path(), &state_file, &bridge, &[]).await?;
    let rows = wait_for_wake_rows(temp.path(), 1).await?;
    let row = rows
        .iter()
        .find(|row| {
            row.get("classifier_tag").and_then(Value::as_str) == Some("terminal-state-reached")
        })
        .ok_or("terminal-state-reached row missing")?;
    assert_eq!(row["pane_id"], PANE_ID);
    assert_eq!(row["harness"], "pi");
    assert_eq!(row["last_assistant_text"], "");

    daemon.stop();
    Ok(())
}

#[tokio::test]
async fn pi_empty_after_compact_detection_is_deferred() -> Result<(), Box<dyn Error>> {
    let temp = tempfile::tempdir()?;
    let state_file = temp.path().join("flightdeck-state-s505.json");
    write_state(&state_file, "issue")?;
    let bridge = write_fake_bridge(
        temp.path(),
        r#"
if [[ "$1" == "stream" ]]; then
  echo '{"type":"event","event":"session_compact","data":{}}'
  echo '{"type":"event","event":"agent_end","data":{"content":[]}}'
  exit 0
fi
exit 0
"#,
    )?;

    let mut daemon = spawn_daemon(temp.path(), &state_file, &bridge, &[]).await?;
    assert_no_wake_rows(temp.path(), Duration::from_millis(600)).await?;

    daemon.stop();
    Ok(())
}
