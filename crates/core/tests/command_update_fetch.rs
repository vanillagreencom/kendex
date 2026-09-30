//! The download consumer, with curl's retry policy implemented by a test double.
#![cfg(unix)]

use crate::test_util::{reexecute_test, rooted};
use kendex_core::{command_update::fetch, process::Hardened};
use std::os::unix::fs::PermissionsExt;

#[test]
fn download_retry_returns_third_attempt_and_names_exhaustion() {
    if let Some(root) = std::env::var_os("KENDEX_TEST_CURL") {
        let attempts = std::path::PathBuf::from(root).join("attempts");
        // The old single-attempt arguments must fail on the same third-attempt fixture.
        let control = Hardened::curl(&[
            "-fsS",
            "--location",
            "--max-redirs",
            "3",
            "--proto",
            "=https,file",
            "--proto-redir",
            "=https",
            "--",
            "third",
        ])
        .run()
        .unwrap();
        assert_eq!(control.status.code(), Some(22));
        assert_eq!(std::fs::read_to_string(&attempts).unwrap(), "1\n");
        assert_eq!(fetch("third").unwrap(), b"release bytes");
        assert_eq!(std::fs::read_to_string(&attempts).unwrap(), "3\n");
        let error = fetch("never").unwrap_err();
        assert!(error.contains("failed after 4 attempts"), "{error}");
        assert!(error.contains("curl: (22)"), "{error}");
        assert_eq!(std::fs::read_to_string(attempts).unwrap(), "4\n");
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let curl = root.join("curl");
    std::fs::write(
        &curl,
        r#"#!/bin/sh
retries=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --retry) retries=$2; shift ;;
    --retry-delay) [ "$2" = 2 ] || exit 64; shift ;;
    --) shift; break ;;
  esac
  shift
done
attempt=1
while :; do
  printf '%s\n' "$attempt" > "$KENDEX_TEST_CURL/attempts"
  if [ "$1" = third ] && [ "$attempt" = 3 ]; then printf 'release bytes'; exit 0; fi
  [ "$attempt" -le "$retries" ] || break
  attempt=$((attempt + 1))
done
printf 'curl: (22) The requested URL returned error: 500\n' >&2
exit 22
"#,
    )
    .unwrap();
    std::fs::set_permissions(&curl, std::fs::Permissions::from_mode(0o755)).unwrap();
    let path = root.to_str().unwrap();
    let output = reexecute_test(
        module_path!(),
        "download_retry_returns_third_attempt_and_names_exhaustion",
        &[("PATH", path), ("KENDEX_TEST_CURL", path)],
    )
    .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stdout)
    );
    assert_eq!(
        std::fs::read_to_string(root.join("attempts")).unwrap(),
        "4\n"
    );
}
