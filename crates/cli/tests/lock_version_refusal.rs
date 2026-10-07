//! Fleet's lane lock migration reads the keyed version pair on stderr.

use std::fs;
use std::process::Command;

use crate::test_util::{fixture_env, rooted};
use kendex_core::lock::LOCK_VERSION;

#[test]
#[allow(clippy::unwrap_used)]
fn check_prints_the_lock_version_pair_on_stderr() {
    for (record, found) in [
        (r#"{"version":5,"entries":{}}"#.to_owned(), Some("5")),
        (r#"{"entries":{}}"#.to_owned(), Some("none")),
        (r#"{"version":10,"entries":{}}"#.to_owned(), Some("10")),
        (
            format!(r#"{{"version":{},"entries":{{}}}}"#, LOCK_VERSION + 1),
            None,
        ),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let home = rooted(&tmp);
        let project = home.join("project with spaces");
        fs::create_dir_all(project.join(".agents")).unwrap();
        fs::write(project.join("kendex.toml"), "schema = 6\n").unwrap();
        let path = project.join(".kendex-lock.json");
        fs::write(&path, &record).unwrap();
        let checked = Command::new(env!("CARGO_BIN_EXE_kendex"))
            .args(["check", "--scope", "project"])
            .current_dir(&project)
            .env_clear()
            .envs(fixture_env(&home))
            .env("PATH", std::env::var_os("PATH").unwrap_or_default())
            .env("KENDEX_BACKGROUND_REFRESH", "off")
            .env("KENDEX_UI", "plain")
            .output()
            .unwrap();
        assert!(!checked.status.success(), "record={record}");
        let stderr = String::from_utf8(checked.stderr).unwrap();
        let lines: Vec<_> = stderr
            .lines()
            .filter(|line| line.starts_with("lock-version-refused "))
            .collect();
        match found {
            Some(found) => assert_eq!(
                lines,
                [format!(
                    "lock-version-refused found={found} expected={LOCK_VERSION} path={}",
                    path.display()
                )],
                "a consumer reading found= gets nothing or the wrong pair: {stderr}"
            ),
            None => assert!(lines.is_empty(), "record={record}: {stderr}"),
        }
        assert_eq!(fs::read_to_string(&path).unwrap(), record);
    }
}
