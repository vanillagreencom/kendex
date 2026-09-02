//! The production credential lock across app and CLI processes.

#[cfg(target_os = "linux")]
use std::path::Path;
#[cfg(target_os = "linux")]
use std::sync::mpsc;
#[cfg(target_os = "linux")]
use std::time::{Duration, Instant};

#[cfg(target_os = "linux")]
use kendex_core::registry::credentials::{CredentialStore, KeyringStore};

#[cfg(not(target_os = "linux"))]
#[test]
#[ignore = "divergent XDG data roots are a Linux credential-lock contract"]
fn production_keyring_guard_blocks_across_divergent_data_roots() {}

#[cfg(target_os = "linux")]
const CHILD_ROOT: &str = "KENDEX_REFRESH_LOCK_CHILD_ROOT";
#[cfg(target_os = "linux")]
const CHILD_ROLE: &str = "KENDEX_REFRESH_LOCK_CHILD_ROLE";

#[cfg(target_os = "linux")]
fn wait_for(path: &Path, why: &str) {
    let deadline = Instant::now() + Duration::from_secs(5);
    while !path.exists() {
        assert!(Instant::now() < deadline, "{why}");
        std::thread::sleep(Duration::from_millis(10));
    }
}

#[cfg(target_os = "linux")]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn run_holder(root: &Path) {
    let guard = KeyringStore.refresh_guard().unwrap();
    let critical = root.join("critical");
    let marker = std::fs::OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&critical)
        .expect("two processes entered the credential transaction together");
    std::fs::write(root.join("holder-locked"), b"locked").unwrap();
    wait_for(&root.join("release-holder"), "parent never released holder");
    drop(marker);
    std::fs::remove_file(critical).unwrap();
    drop(guard);
}

#[cfg(target_os = "linux")]
#[allow(clippy::unwrap_used, clippy::expect_used)]
fn run_waiter(root: &Path) {
    let (attempted, saw_attempt) = mpsc::channel();
    let (acquired, saw_acquire) = mpsc::channel();
    let worker_root = root.to_owned();
    let worker = std::thread::spawn(move || {
        attempted.send(()).unwrap();
        let guard = KeyringStore.refresh_guard().unwrap();
        acquired.send(()).unwrap();
        let critical = worker_root.join("critical");
        let marker = std::fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&critical)
            .expect("two processes entered the credential transaction together");
        std::fs::write(worker_root.join("waiter-acquired"), b"acquired").unwrap();
        drop(marker);
        std::fs::remove_file(critical).unwrap();
        drop(guard);
    });

    saw_attempt.recv().unwrap();
    match saw_acquire.recv_timeout(Duration::from_millis(250)) {
        Err(mpsc::RecvTimeoutError::Timeout) => {
            std::fs::write(root.join("waiter-blocked"), b"blocked").unwrap();
        }
        Ok(()) => panic!("the waiter acquired before the holder released"),
        Err(error) => panic!("waiter acquisition channel failed: {error}"),
    }
    worker.join().unwrap();
}

#[cfg(target_os = "linux")]
#[test]
#[allow(clippy::unwrap_used)]
fn production_keyring_guard_blocks_across_divergent_data_roots() {
    if let (Some(root), Ok(role)) = (std::env::var_os(CHILD_ROOT), std::env::var(CHILD_ROLE)) {
        let root = std::path::PathBuf::from(root);
        match role.as_str() {
            "holder" => run_holder(&root),
            "waiter" => run_waiter(&root),
            other => panic!("unknown credential-lock child role: {other}"),
        }
        return;
    }

    let fixture = tempfile::tempdir().unwrap();
    let root = fixture.path();
    let executable = std::env::current_exe().unwrap();
    let spawn = |role: &str, data_root: &str| {
        std::process::Command::new(&executable)
            .arg("--exact")
            .arg("production_keyring_guard_blocks_across_divergent_data_roots")
            .arg("--nocapture")
            .env(CHILD_ROOT, root)
            .env(CHILD_ROLE, role)
            .env("HOME", root)
            .env("KENDEX_REAL_HOME", "1")
            .env("XDG_DATA_HOME", root.join(data_root))
            .env("XDG_CACHE_HOME", root.join("cache"))
            .env("XDG_CONFIG_HOME", root.join("config"))
            .spawn()
            .unwrap()
    };

    let mut holder = spawn("holder", "data-a");
    wait_for(
        &root.join("holder-locked"),
        "holder never acquired the credential lock",
    );
    let mut waiter = spawn("waiter", "data-b");
    wait_for(
        &root.join("waiter-blocked"),
        "waiter never proved it was blocked",
    );
    assert!(!root.join("waiter-acquired").exists());
    std::fs::write(root.join("release-holder"), b"release").unwrap();

    assert!(holder.wait().unwrap().success());
    assert!(waiter.wait().unwrap().success());
    assert!(root.join("waiter-acquired").exists());
}
