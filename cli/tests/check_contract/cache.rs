//! The remote-source-cache half of the `vstack check` contract: what a check
//! costs when a cache is due for a refresh, and what it reports while another
//! process is writing one. A session start must never wait on the network or
//! on another process's lock, and it must never measure a tree mid-rewrite.

use super::*;

/// VST-258 round 3: the session-start check never touches the network. A
/// remote source that is due for a refresh and unreachable must not cost the
/// session anything — the fetch is handed to a detached process and the check
/// answers from what is on disk.
#[test]
fn a_due_but_unreachable_remote_never_delays_the_check() {
    let sb = Sandbox::new("check-no-network");
    // A cache holding a real source tree, so the scope itself stays clean.
    let source = sb.remote_source_repo();
    let output = sb
        .vstack()
        .args([
            "add",
            &source,
            "--skill",
            "alpha",
            "--harness",
            "claude",
            "-y",
        ])
        .output()
        .unwrap();
    assert!(output.status.success(), "add: {}", text(&output.stderr));
    let cache = sb.cache_entry();
    // No stamp, so the cache is due on the very next check.
    let stamp = cache.join(".git").join("vstack-fetch-stamp");
    let _ = fs::remove_file(&stamp);

    // From here on, git takes 30 s to answer. The check must not notice.
    #[cfg(unix)]
    sb.install_slow_git();

    let started = std::time::Instant::now();
    let quiet = sb.check_online(&["--quiet"]);
    let elapsed = started.elapsed();
    assert!(
        elapsed < std::time::Duration::from_secs(5),
        "session-start check must not wait on the network: took {elapsed:?}"
    );
    assert_eq!(
        quiet.status.code(),
        Some(0),
        "nothing local drifted: {}",
        text(&quiet.stderr)
    );

    // The refresh was handed off: the detached child marks the attempt in
    // flight immediately, then records its verdict when the slow git finally
    // answers. Either state proves the handoff happened without the check
    // waiting for it.
    let mut recorded = String::new();
    for _ in 0..100 {
        if let Ok(content) = fs::read_to_string(&stamp) {
            recorded = content;
            if !recorded.is_empty() {
                break;
            }
        }
        std::thread::sleep(std::time::Duration::from_millis(100));
    }
    assert!(
        recorded.starts_with("pending") || recorded.starts_with("failed"),
        "the detached refresh must record its progress, got {recorded:?}"
    );

    // A fetch in flight is not a failure: the next check stays clean and
    // says nothing about it.
    let json = sb.check(&["--json"]);
    let parsed: serde_json::Value = serde_json::from_slice(&json.stdout).unwrap();
    assert_eq!(parsed["drift"], false, "{parsed}");
    assert_eq!(json.status.code(), Some(0));
    if recorded.starts_with("failed") {
        let failures = parsed["cache_refresh_failures"].as_array().unwrap();
        assert_eq!(failures.len(), 1, "{parsed}");
        assert_eq!(failures[0]["source"], source);
        assert_eq!(failures[0]["persistent"], false);
    }
}

/// VST-258 round 27: a source cache another process is mid-`reset --hard` on
/// is reported busy, never measured. The tree such a reset transiently shows
/// is missing files that exist, and the entries it "removes" print
/// `vstack remove` as their remedy — a destructive answer to a cache that is
/// simply being refreshed.
///
/// The probe never waits: the session-start check may not block on somebody
/// else's fetch, so a busy cache is reported and the next run classifies it.
#[cfg(unix)]
#[test]
fn a_cache_another_process_is_rewriting_is_reported_busy_rather_than_removed() {
    use std::os::unix::io::AsRawFd;

    let sb = Sandbox::new("check-busy-cache");
    let source = sb.remote_source_repo();
    let output = sb
        .vstack()
        .args([
            "add",
            &source,
            "--skill",
            "alpha",
            "--harness",
            "claude",
            "-y",
        ])
        .output()
        .unwrap();
    assert!(output.status.success(), "add: {}", text(&output.stderr));
    // A hook as well: its presence check reads the hook's definition out of
    // the source, which is the one resolution `check` makes outside its own
    // cataloging pass — and the one that could put a warning on stderr.
    let output = sb
        .vstack()
        .args([
            "add",
            &source,
            "--hook",
            "guard",
            "--harness",
            "claude",
            "-y",
        ])
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "add hook: {}",
        text(&output.stderr)
    );
    let cache = sb.cache_entry();

    // Control: with nothing holding the lock, the report is what it always
    // was — the entry is measured against its source and nothing is busy.
    let baseline = sb.check(&["--json"]);
    let parsed: serde_json::Value = serde_json::from_slice(&baseline.stdout).unwrap();
    assert_eq!(
        baseline.status.code(),
        Some(0),
        "{}",
        text(&baseline.stderr)
    );
    assert_eq!(parsed["drift"], false, "{parsed}");
    assert!(
        parsed["scopes"][0]["busy_sources"]
            .as_array()
            .unwrap()
            .is_empty(),
        "{parsed}"
    );

    // Another process now holds the fetch lock and the tree is mid-rewrite:
    // the skill is not there to be found, exactly as it is not between a
    // reset's unlink and its checkout.
    let lock_file = fs::File::options()
        .read(true)
        .write(true)
        .create(true)
        .truncate(false)
        .open(cache.join(".git").join("vstack-fetch.lock"))
        .unwrap();
    // SAFETY: the fd is live for the whole call and the lock is released when
    // the file is dropped at the end of the test.
    assert_eq!(
        unsafe { libc::flock(lock_file.as_raw_fd(), libc::LOCK_EX | libc::LOCK_NB) },
        0,
        "the test must be able to hold the cache's fetch lock"
    );
    let hidden = sb.root.join("hidden-alpha");
    fs::rename(cache.join("skills").join("alpha"), &hidden).unwrap();

    let started = std::time::Instant::now();
    let busy = sb.check(&["--json"]);
    let elapsed = started.elapsed();
    // A blocking acquire would sit here for the install guard's whole wait.
    assert!(
        elapsed < std::time::Duration::from_secs(5),
        "a read-only check must never wait on another process's fetch: {elapsed:?}"
    );
    let parsed: serde_json::Value = serde_json::from_slice(&busy.stdout).unwrap();
    assert_eq!(
        busy.status.code(),
        Some(0),
        "a cache being refreshed is not drift: {parsed}"
    );
    assert_eq!(parsed["drift"], false, "{parsed}");
    let scope = &parsed["scopes"][0];
    assert_eq!(scope["removed"].as_array().unwrap().len(), 0, "{parsed}");
    assert_eq!(scope["outdated"].as_array().unwrap().len(), 0, "{parsed}");
    assert!(
        scope["source_issues"].as_array().unwrap().is_empty(),
        "a busy cache is not a source problem to repair: {parsed}"
    );
    let busy_sources = scope["busy_sources"].as_array().unwrap();
    assert_eq!(busy_sources.len(), 1, "{parsed}");
    assert_eq!(busy_sources[0]["source"], source, "{parsed}");
    assert_eq!(busy_sources[0]["entries"][0], "alpha", "{parsed}");
    assert_eq!(busy_sources[0]["entries"][1], "guard", "{parsed}");
    assert!(
        busy_sources[0]["reason"]
            .as_str()
            .unwrap_or_default()
            .contains("refreshing"),
        "{parsed}"
    );
    // The quiet report the session-start hook relays is silent: nothing is
    // wrong, nothing can be acted on, and the next run answers.
    let quiet = sb.check(&["--quiet"]);
    assert_eq!(quiet.status.code(), Some(0));
    assert_eq!(
        text(&quiet.stderr),
        "",
        "a busy cache must not put a transient into every session's context"
    );

    // And the human report never prescribes the destructive remedy.
    let human = text(&sb.check(&[]).stderr);
    assert!(
        human.contains("is being refreshed by another vstack process"),
        "{human}"
    );
    assert!(!human.contains("vstack remove"), "{human}");

    // Control: with the lock free and the tree whole again, the report is
    // byte-identical to the one before any of this.
    fs::rename(&hidden, cache.join("skills").join("alpha")).unwrap();
    drop(lock_file);
    let after = sb.check(&["--json"]);
    assert_eq!(
        text(&after.stdout),
        text(&baseline.stdout),
        "an uncontended cache must report exactly as it did before"
    );
}

/// VST-258 round 27: the initial clone is the one cache write no lock can
/// cover — the lock lives inside a `.git` that does not exist yet, and a
/// reader decides the cache is present by finding exactly that `.git`. So the
/// clone is published by rename: a tree that did not finish is never visible
/// under the entry's own name, and no reader can measure a half-built cache.
#[cfg(unix)]
#[test]
fn a_clone_that_did_not_finish_is_never_published_as_the_cache_entry() {
    let sb = Sandbox::new("clone-publish");
    let source = sb.remote_source_repo();
    sb.install_half_cloning_git();

    let output = sb
        .vstack()
        .args([
            "add",
            &source,
            "--skill",
            "alpha",
            "--harness",
            "claude",
            "-y",
        ])
        .output()
        .unwrap();
    assert!(
        !output.status.success(),
        "a clone that failed must not report success: {}",
        text(&output.stdout)
    );

    let root = sb.home.join(".vstack").join("cache");
    let entries: Vec<String> = fs::read_dir(&root)
        .map(|dir| {
            dir.map(|entry| entry.unwrap().file_name().to_string_lossy().into_owned())
                .collect()
        })
        .unwrap_or_default();
    assert!(
        !entries.iter().any(|name| !name.starts_with('.')),
        "a half-built clone must never appear under a cache key: {entries:?}"
    );
    assert!(
        !entries.iter().any(|name| name.starts_with(".staging-")),
        "and the staging directory is cleaned up behind it: {entries:?}"
    );
}
