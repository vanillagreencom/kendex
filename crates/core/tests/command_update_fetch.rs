//! The download consumer's capability choice, retry policy and diagnostics.
#![cfg(unix)]

use crate::test_util::{reexecute_test, rooted};
use kendex_core::{command_update::fetch, process::Hardened};
use std::os::unix::fs::PermissionsExt;

const CURL_SCRIPT: &str = r#"#!/bin/sh
if [ "$3" = --version ]; then
  printf 'probe\n' >> "$KENDEX_TEST_CURL/probes" || exit 74
  case "$KENDEX_TEST_CURL_POLICY" in
    legacy)
      printf 'curl: option --retry-all-errors: is unknown\ncurl: try '\''curl --help'\'' for more information\n' >&2
      exit 2 ;;
    broken)
      printf 'curl: capability probe failed\n' >&2
      exit 2 ;;
  esac
  printf 'curl version\n'
  exit 0
fi
retries=0
destination=
all_errors=no
silent=no
while [ "$#" -gt 0 ]; do
  case "$1" in
    -fsS) silent=yes ;;
    --no-silent) silent=no ;;
    --retry-all-errors)
      if [ "$KENDEX_TEST_CURL_POLICY" = legacy ]; then
        printf 'curl: option --retry-all-errors: is unknown\n' >&2
        exit 2
      fi
      all_errors=yes ;;
    --retry) retries=$2; shift ;;
    --retry-delay) [ "$2" = 2 ] || exit 64; shift ;;
    --output) destination=$2; shift ;;
    --) shift; break ;;
  esac
  shift
done
attempt=1
while :; do
  printf '%s\n' "$attempt" > "$KENDEX_TEST_CURL/attempts" || exit 74
  # Curl resets --output on retry, but cannot reset a stdout pipe.
  if [ -n "$destination" ]; then
    : > "$destination" || exit 74
    exec 3>> "$destination" || exit 74
  else
    exec 3>&1
  fi
  if { [ "$1" = third ] && [ "$attempt" = 3 ]; } ||
     { [ "$1" = partial ] && [ "$attempt" = 2 ]; }; then
    printf 'release bytes' >&3 || exit 74
    exit 0
  fi
  if [ "$1" = partial ] || [ "$1" = never ]; then
    printf 'release' >&3 || exit 74
  fi
  if [ "$1" = partial ] && [ "$all_errors" = no ]; then
    printf 'curl: (18) transfer closed with bytes remaining\n' >&2
    exit 18
  fi
  if [ "$1" = unretried ] && [ "$all_errors" = no ]; then
    printf 'curl: (37) Could not open file\n' >&2
    exit 37
  fi
  [ "$attempt" -le "$retries" ] || break
  # Both modern and legacy curl expose one warning before each retry.
  if [ "$silent" = no ]; then
    printf 'Warning: Transient problem: HTTP error Will retry in 2 seconds. %s retries left.\n' "$((retries - attempt + 1))" >&2
  fi
  attempt=$((attempt + 1))
done
printf 'curl: (22) The requested URL returned error: 500\n' >&2
exit 22
"#;

#[test]
fn download_retry_returns_third_attempt_and_names_exhaustion() {
    if let Some(root) = std::env::var_os("KENDEX_TEST_CURL") {
        let root = std::path::PathBuf::from(root);
        let attempts = root.join("attempts");
        // The old single-attempt arguments must fail on the same third-attempt fixture.
        let control = Hardened::curl(&["-fsS", "--", "third"]).run().unwrap();
        assert_eq!(control.status.code(), Some(22));
        assert_eq!(std::fs::read_to_string(&attempts).unwrap(), "1\n");
        if std::env::var("KENDEX_TEST_CURL_POLICY").unwrap() == "broken" {
            for _ in 0..2 {
                let error = fetch("third").unwrap_err();
                assert!(error.contains("capability probe failed"), "{error}");
            }
            assert_eq!(
                std::fs::read_to_string(root.join("probes")).unwrap(),
                "probe\n"
            );
            return;
        }
        let legacy = std::env::var("KENDEX_TEST_CURL_POLICY").unwrap() == "legacy";
        for (url, expected_attempts, expected_error) in [
            ("third", "3\n", None),
            (
                "partial",
                if legacy { "1\n" } else { "2\n" },
                if legacy { Some((1, 18)) } else { None },
            ),
            ("never", "4\n", Some((4, 22))),
            (
                "unretried",
                if legacy { "1\n" } else { "4\n" },
                Some(if legacy { (1, 37) } else { (4, 22) }),
            ),
        ] {
            match expected_error {
                None => assert_eq!(fetch(url).unwrap(), b"release bytes", "{url}"),
                Some((count, code)) => {
                    let error = fetch(url).unwrap_err();
                    assert!(
                        error.contains(&format!("failed after {count} attempts")),
                        "{error}"
                    );
                    assert!(error.contains(&format!("curl: ({code})")), "{error}");
                }
            }
            assert_eq!(
                std::fs::read_to_string(&attempts).unwrap(),
                expected_attempts
            );
            assert!(
                std::fs::read_dir(root.join("downloads"))
                    .unwrap()
                    .next()
                    .is_none()
            );
        }
        assert_eq!(
            std::fs::read_to_string(root.join("probes")).unwrap(),
            "probe\n"
        );
        return;
    }
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let curl = root.join("curl");
    std::fs::write(&curl, CURL_SCRIPT).unwrap();
    std::fs::set_permissions(&curl, std::fs::Permissions::from_mode(0o755)).unwrap();
    let scratch = root.join("downloads");
    std::fs::create_dir(&scratch).unwrap();
    let path = root.to_str().unwrap();
    for policy in ["modern", "legacy", "broken"] {
        std::fs::write(root.join("probes"), "").unwrap();
        let output = reexecute_test(
            module_path!(),
            "download_retry_returns_third_attempt_and_names_exhaustion",
            &[
                ("PATH", path),
                ("KENDEX_TEST_CURL", path),
                ("KENDEX_TEST_CURL_POLICY", policy),
                ("TMPDIR", scratch.to_str().unwrap()),
            ],
        )
        .unwrap();
        assert!(
            output.status.success(),
            "{policy}: {}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
}

#[test]
fn real_curl_counts_failed_transfers_in_both_policies() {
    if let Some(root) = std::env::var_os("KENDEX_TEST_REAL_CURL_ROOT") {
        let root = std::path::PathBuf::from(root);
        let probe = Hardened::curl(&["--disable", "--retry-all-errors", "--version"])
            .run()
            .unwrap();
        let expected = if probe.status.success() { 4 } else { 1 };
        if std::env::var("KENDEX_TEST_CURL_POLICY").unwrap() == "legacy" || !probe.status.success()
        {
            // The unsupported flag is the legacy row's must-fail control.
            assert_eq!(probe.status.code(), Some(2));
            assert!(String::from_utf8_lossy(&probe.stderr).contains("is unknown"));
        }
        // A missing file is curl error 37, not a transient error under --retry.
        // The real retry delay is required to exercise curl's own diagnostics.
        let url = url::Url::from_file_path(root.join("missing")).unwrap();
        let error = fetch(url.as_str()).unwrap_err();
        assert!(
            error.contains(&format!("failed after {expected} attempts")),
            "{error}"
        );
        assert!(error.contains("curl: (37)"), "{error}");
        assert!(
            std::fs::read_dir(root.join("downloads"))
                .unwrap()
                .next()
                .is_none()
        );
        return;
    }
    let real = std::env::split_paths(&std::env::var_os("PATH").unwrap())
        .map(|directory| directory.join("curl"))
        .find(|path| path.is_file())
        .expect("real curl is required for download diagnostic coverage");
    let real = std::fs::canonicalize(real).unwrap();
    let tmp = tempfile::tempdir().unwrap();
    let root = rooted(&tmp);
    let curl = root.join("curl");
    std::fs::write(
        &curl,
        r#"#!/bin/sh
if [ "$KENDEX_TEST_FORCE_LEGACY" = yes ]; then
  for argument in "$@"; do
    if [ "$argument" = --retry-all-errors ]; then
      printf 'curl: option --retry-all-errors: is unknown\n' >&2
      exit 2
    fi
  done
fi
exec "$KENDEX_TEST_REAL_CURL" "$@"
"#,
    )
    .unwrap();
    std::fs::set_permissions(&curl, std::fs::Permissions::from_mode(0o755)).unwrap();
    let scratch = root.join("downloads");
    std::fs::create_dir(&scratch).unwrap();
    for policy in ["native", "legacy"] {
        // Local verification can supply Apple's upstream curl version.
        // CI otherwise restricts host curl to the same legacy arguments.
        let (executable, force_legacy) = match (policy, std::env::var_os("KENDEX_TEST_LEGACY_CURL"))
        {
            ("legacy", Some(path)) => (std::fs::canonicalize(path).unwrap(), "no"),
            ("legacy", None) => (real.clone(), "yes"),
            _ => (real.clone(), "no"),
        };
        let output = reexecute_test(
            module_path!(),
            "real_curl_counts_failed_transfers_in_both_policies",
            &[
                ("PATH", root.to_str().unwrap()),
                ("KENDEX_TEST_REAL_CURL_ROOT", root.to_str().unwrap()),
                ("KENDEX_TEST_REAL_CURL", executable.to_str().unwrap()),
                ("KENDEX_TEST_FORCE_LEGACY", force_legacy),
                ("KENDEX_TEST_CURL_POLICY", policy),
                ("TMPDIR", scratch.to_str().unwrap()),
            ],
        )
        .unwrap();
        assert!(
            output.status.success(),
            "{policy}: {}{}",
            String::from_utf8_lossy(&output.stdout),
            String::from_utf8_lossy(&output.stderr)
        );
    }
}
