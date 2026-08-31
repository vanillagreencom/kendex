use std::cell::Cell;
use std::collections::VecDeque;
use std::sync::Mutex;

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

fn request(refresh: bool) -> CheckRequest<'static> {
    CheckRequest {
        current_version: "5.0.1",
        target: "x86_64-unknown-linux-gnu",
        feed_url: "https://example.test/feed.json",
        refresh,
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

    check_at(&env, &fetch, request(false), start).unwrap();
    check_at(&env, &fetch, request(false), start + SIX_HOURS - 1).unwrap();
    assert_eq!(fetch.calls.get(), 1);

    check_at(&env, &fetch, request(false), start + SIX_HOURS).unwrap();
    assert_eq!(fetch.calls.get(), 2);
}

/// A manual check is the person asking, so it does not wait out an
/// interval a moment ago started.
#[test]
fn a_manual_refresh_fetches_inside_the_interval() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let fetch = Canned::new([feed(200), feed(200)]);

    check_at(&env, &fetch, request(false), 10_000).unwrap();
    check_at(&env, &fetch, request(false), 10_001).unwrap();
    assert_eq!(fetch.calls.get(), 1);

    let refreshed = check_at(&env, &fetch, request(true), 10_001).unwrap();
    assert!(matches!(refreshed, AppUpdateStatus::UpdateAvailable { .. }));
    assert_eq!(fetch.calls.get(), 2);
}

/// A clock that went backwards — a machine whose time was corrected, a
/// cache copied from another one — leaves an attempt stamped after now.
/// Waiting out an interval that ends in the future would stop checking
/// until the stamp came round again.
#[test]
fn a_cache_stamped_in_the_future_is_attempted_immediately() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let fetch = Canned::new([feed(200), feed(304)]);

    check_at(&env, &fetch, request(false), 20_000).unwrap();
    check_at(&env, &fetch, request(false), 10_000).unwrap();

    assert_eq!(fetch.calls.get(), 2);
}

/// A launch starts two checks: the startup schedule, and the webview
/// asking for the notice as it mounts. Without one at a time both read a
/// cache neither has written, both go to the network, and the second write
/// puts its own generation over the first — a good body discarded for one
/// nobody asked for twice.
///
/// The first fetch is held open long enough that a second check running
/// beside it would have to overlap it. Serialized, the second one reads
/// what the first wrote and finds the interval already served.
#[test]
#[allow(clippy::unwrap_used)]
fn the_two_checks_a_launch_starts_go_to_the_network_once() {
    use std::sync::atomic::{AtomicUsize, Ordering};

    struct Slow {
        calls: AtomicUsize,
    }

    impl Fetch for Slow {
        fn get_auth(
            &self,
            _url: &str,
            _if_none_match: Option<&str>,
            _bearer: Option<&str>,
        ) -> Result<FetchResponse> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            std::thread::sleep(std::time::Duration::from_millis(200));
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

    let tmp = tempfile::tempdir().unwrap();
    let home = crate::paths::canonical(tmp.path()).unwrap();
    let env = Env::fake(home, FakeOs::Linux);
    let fetch = Slow {
        calls: AtomicUsize::new(0),
    };

    std::thread::scope(|scope| {
        let started = scope.spawn(|| check_at(&env, &fetch, request(false), 10_000));
        // Far enough into the first fetch that a second check with nothing
        // holding it back would be inside `read_cache` before the first
        // one writes.
        std::thread::sleep(std::time::Duration::from_millis(50));
        let beside = check_at(&env, &fetch, request(false), 10_000).unwrap();
        assert!(matches!(beside, AppUpdateStatus::UpdateAvailable { .. }));
        started.join().unwrap().unwrap();
    });

    assert_eq!(
        fetch.calls.load(Ordering::SeqCst),
        1,
        "both checks a launch starts went to the network"
    );
}
