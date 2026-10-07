use std::cell::Cell;
use std::io;

use super::*;

#[test]
fn first_clone_has_its_own_long_bound() {
    let tmp = tempfile::tempdir().unwrap();
    let root = crate::test_util::rooted(&tmp);
    let called = Cell::new(false);
    ensure_mirror_using(&root.join("mirror.git"), |timeout| {
        called.set(true);
        assert_eq!(timeout, Duration::from_secs(600));
        assert!(timeout > crate::process::DEFAULT_TIMEOUT);
        Ok(())
    })
    .unwrap();
    assert!(called.get());
}

#[cfg(unix)]
#[test]
fn a_stalled_or_failed_clone_retries_from_an_empty_directory() {
    let tmp = tempfile::tempdir().unwrap();
    let root = crate::test_util::rooted(&tmp);
    let upstream = root.join("upstream");
    fs::create_dir(&upstream).unwrap();
    fs::write(upstream.join("content"), "catalog bytes").unwrap();
    for args in [
        vec!["init", "--quiet", "-b", "main"],
        vec!["add", "content"],
        vec![
            "-c",
            "user.name=fixture",
            "-c",
            "user.email=fixture@example.test",
            "commit",
            "--quiet",
            "-m",
            "fixture",
        ],
    ] {
        run(Hardened::git(&args, Some(&upstream))).unwrap();
    }
    let expected = resolve_ref(&upstream.join(".git"), "HEAD").unwrap();
    // Real process deadlines prove timer wiring; the production bound is checked separately.
    let fail = |script: &str| {
        run(Hardened::program("sh", &["-c", script])
            .env("PATH", "/usr/bin:/bin")
            .timeout(Duration::from_millis(50)))
    };
    let stalled = "exec sleep 5";
    // The unchanged single attempt cannot recover from this same stall.
    let control = fail(stalled).unwrap_err();
    assert!(
        matches!(control, CoreError::Io { source, .. } if source.kind() == io::ErrorKind::TimedOut)
    );

    for script in [stalled, "echo 'fatal: early EOF' >&2; exit 128"] {
        let mirror = root.join("mirror.git");
        let attempts = Cell::new(0);
        ensure_mirror_using(&mirror, |_| {
            let attempt = attempts.replace(attempts.get() + 1);
            assert!(!mirror.exists());
            if attempt == 0 {
                fs::create_dir(&mirror).unwrap();
                fs::write(mirror.join("partial"), "interrupted transfer").unwrap();
                fail(script)
            } else {
                ensure_mirror(&mirror, upstream.to_str().unwrap())
            }
        })
        .unwrap();
        assert_eq!(attempts.get(), 2);
        assert_eq!(
            resolve_ref(&mirror, "HEAD").as_deref(),
            Some(expected.as_str())
        );
        assert!(!mirror.join("partial").exists());
        let checkout = root.join("checkout");
        check_out(&checkout, &mirror, &expected).unwrap();
        assert_eq!(
            fs::read_to_string(checkout.join("content")).unwrap(),
            "catalog bytes"
        );
        fs::remove_dir_all(mirror).unwrap();
        fs::remove_dir_all(checkout).unwrap();
    }
}

#[test]
fn clone_failures_are_bounded_and_local_errors_are_not_retried() {
    for (kind, expected_attempts) in [
        (Some(io::ErrorKind::TimedOut), 2),
        (Some(io::ErrorKind::PermissionDenied), 1),
        (None, 2),
    ] {
        let tmp = tempfile::tempdir().unwrap();
        let root = crate::test_util::rooted(&tmp);
        let attempts = Cell::new(0);
        let error = ensure_mirror_using(&root.join("mirror.git"), |_| {
            attempts.set(attempts.get() + 1);
            Err(match kind {
                Some(kind) => CoreError::io("clone fixture", io::Error::from(kind)),
                None => CoreError::GitFailed {
                    command: "clone fixture".into(),
                    stderr: "fatal: early EOF".into(),
                },
            })
        })
        .unwrap_err();
        assert_eq!(attempts.get(), expected_attempts);
        match (kind, error) {
            (Some(kind), CoreError::Io { source, .. }) => assert_eq!(source.kind(), kind),
            (None, CoreError::GitFailed { .. }) => {}
            _ => panic!("clone returned the wrong error category"),
        }
    }
}
