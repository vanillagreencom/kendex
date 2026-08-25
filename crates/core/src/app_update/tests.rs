use std::cell::Cell;
use std::collections::VecDeque;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, mpsc};
use std::time::Duration;

use super::*;
use crate::env::FakeOs;
use crate::registry::FetchResponse;

struct Canned {
    calls: Cell<usize>,
    answers: Mutex<VecDeque<FetchResponse>>,
}

impl Canned {
    fn new(answers: impl IntoIterator<Item = FetchResponse>) -> Self {
        Self {
            calls: Cell::new(0),
            answers: Mutex::new(answers.into_iter().collect()),
        }
    }
}

impl Fetch for Canned {
    fn get_auth(
        &self,
        _url: &str,
        _if_none_match: Option<&str>,
        _bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        self.calls.set(self.calls.get() + 1);
        self.answers
            .lock()
            .unwrap()
            .pop_front()
            .ok_or_else(|| CoreError::RegistryUnavailable {
                why: "no canned response".to_owned(),
            })
    }

    fn post_json_auth(
        &self,
        _url: &str,
        _body: &str,
        _bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        Err(CoreError::RegistryUnavailable {
            why: "unexpected POST".to_owned(),
        })
    }
}

fn feed(status: u16) -> FetchResponse {
    FetchResponse {
        status,
        etag: Some("feed-etag".to_owned()),
        body: match status {
            200 => br#"{"schema":1,"version":"5.1.0","assets":{}}"#.to_vec(),
            _ => Vec::new(),
        },
    }
}

fn request(refresh: bool, automatic: bool) -> CheckRequest<'static> {
    CheckRequest {
        current_version: "5.0.1",
        target: "x86_64-unknown-linux-gnu",
        feed_url: "https://example.test/feed.json",
        refresh,
        automatic_check_enabled: automatic,
        muted_version: None,
    }
}

#[test]
fn automatic_check_runs_at_the_ttl_boundary_not_before_it() {
    const SIX_HOURS: u64 = 21_600;
    assert_eq!(DEFAULT_TTL_SECS, SIX_HOURS);
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let fetch = Canned::new([feed(200), feed(304)]);
    let start = 10_000;

    check_at(&env, &fetch, request(false, true), start).unwrap();
    check_at(&env, &fetch, request(false, true), start + SIX_HOURS - 1).unwrap();
    assert_eq!(fetch.calls.get(), 1);

    check_at(&env, &fetch, request(false, true), start + SIX_HOURS).unwrap();
    assert_eq!(fetch.calls.get(), 2);
}

#[test]
fn manual_refresh_fetches_while_automatic_checks_are_off() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let fetch = Canned::new([feed(200)]);

    let off = check_at(&env, &fetch, request(false, false), 10_000).unwrap();
    assert!(matches!(off.status, AppUpdateStatus::NeverChecked));
    assert_eq!(fetch.calls.get(), 0);

    let manual = check_at(&env, &fetch, request(true, false), 10_000).unwrap();
    assert!(matches!(
        manual.status,
        AppUpdateStatus::UpdateAvailable { .. }
    ));
    assert_eq!(fetch.calls.get(), 1);
}

#[test]
fn future_cache_times_are_reported_and_attempted_immediately() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let fetch = Canned::new([feed(200), feed(304)]);

    check_at(&env, &fetch, request(false, true), 20_000).unwrap();
    let future = check_at(&env, &fetch, request(false, false), 10_000).unwrap();
    assert_eq!(future.served_feed_age_secs, None);
    assert!(future.served_feed_in_future);
    assert_eq!(fetch.calls.get(), 1);

    check_at(&env, &fetch, request(false, true), 10_000).unwrap();
    assert_eq!(fetch.calls.get(), 2);
}

#[test]
fn long_multibyte_errors_truncate_on_a_boundary_within_the_cap() {
    let message = format!("{}é{}", "a".repeat(508), "界".repeat(10));
    let stored = update_error(AppUpdateErrorKind::Network, &message).message;
    assert!(stored.len() <= MAX_ERROR_BYTES);
    assert!(stored.ends_with("..."));
    assert!(stored.is_char_boundary(stored.len()));
    assert_eq!(stored, format!("{}...", "a".repeat(508)));
}

struct CountingFetch {
    calls: AtomicUsize,
}

impl Fetch for CountingFetch {
    fn get_auth(
        &self,
        _url: &str,
        _if_none_match: Option<&str>,
        _bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        self.calls.fetch_add(1, Ordering::SeqCst);
        Ok(feed(200))
    }

    fn post_json_auth(
        &self,
        _url: &str,
        _body: &str,
        _bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        Err(CoreError::RegistryUnavailable {
            why: "unexpected POST".to_owned(),
        })
    }
}

#[test]
fn production_clock_is_sampled_after_the_cache_transaction_lock() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let held = update_lock(&env).unwrap();
    let fetch = Arc::new(CountingFetch {
        calls: AtomicUsize::new(0),
    });
    let (sampled, observed) = mpsc::channel();
    let worker_env = env.clone();
    let worker_fetch = Arc::clone(&fetch);
    let worker = std::thread::spawn(move || {
        check_with_clock(
            &worker_env,
            worker_fetch.as_ref(),
            request(false, true),
            || {
                sampled.send(()).unwrap();
                100
            },
        )
        .unwrap()
    });

    assert!(observed.recv_timeout(Duration::from_millis(100)).is_err());
    drop(held);
    let first = worker.join().unwrap();
    let second = check_with_clock(&env, fetch.as_ref(), request(false, true), || 101).unwrap();

    assert_eq!(fetch.calls.load(Ordering::SeqCst), 1);
    assert_eq!(first.last_attempt_at, second.last_attempt_at);
    assert_eq!(first.last_success_at, second.last_success_at);
    assert_eq!(second.served_feed_age_secs, Some(1));
}
