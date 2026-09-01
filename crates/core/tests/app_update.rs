#[path = "../../test_util.rs"]
mod test_util;
use test_util::rooted;

use kendex_core::app_update::{self, AppUpdateStatus};
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::{CoreError, Result};
use kendex_core::registry::{Fetch, FetchResponse};
use std::cell::{Cell, RefCell};
use std::collections::VecDeque;

struct Canned {
    calls: Cell<usize>,
    urls: RefCell<Vec<String>>,
    etags: RefCell<Vec<Option<String>>>,
    answers: RefCell<VecDeque<Result<FetchResponse>>>,
}

impl Canned {
    fn new(answers: impl IntoIterator<Item = Result<FetchResponse>>) -> Self {
        Self {
            calls: Cell::new(0),
            urls: RefCell::new(Vec::new()),
            etags: RefCell::new(Vec::new()),
            answers: RefCell::new(answers.into_iter().collect()),
        }
    }
}

impl Fetch for Canned {
    fn get_auth(
        &self,
        url: &str,
        if_none_match: Option<&str>,
        _bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        self.calls.set(self.calls.get() + 1);
        self.urls.borrow_mut().push(url.to_owned());
        self.etags
            .borrow_mut()
            .push(if_none_match.map(str::to_owned));
        self.answers
            .borrow_mut()
            .pop_front()
            .ok_or_else(|| CoreError::RegistryUnavailable {
                why: "no canned response".to_owned(),
            })?
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

fn response(version: &str, assets: &str) -> Result<FetchResponse> {
    Ok(FetchResponse {
        status: 200,
        etag: Some(format!("etag-{version}")),
        body: format!(r#"{{"schema":1,"version":"{version}","assets":{{{assets}}}}}"#).into_bytes(),
    })
}

fn check(env: &Env, fetch: &Canned, refresh: bool) -> Result<AppUpdateStatus> {
    check_at_url(env, fetch, "https://example.test/feed.json", refresh, None)
}

fn check_at_url(
    env: &Env,
    fetch: &Canned,
    feed_url: &str,
    refresh: bool,
    muted_version: Option<&str>,
) -> Result<AppUpdateStatus> {
    app_update::check(
        env,
        fetch,
        app_update::CheckRequest {
            current_version: "5.0.1",
            target: "x86_64-unknown-linux-gnu",
            feed_url,
            refresh,
            muted_version,
        },
    )
}

#[test]
fn one_attempt_is_reused_for_six_hours() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(home, FakeOs::Linux);
    let fetch = Canned::new([response(
        "5.1.0",
        r#""x86_64-unknown-linux-gnu":"https://example.test/kendex""#,
    )]);

    let first = check(&env, &fetch, false).unwrap();
    let second = check(&env, &fetch, false).unwrap();
    assert_eq!(fetch.calls.get(), 1);
    assert!(matches!(
        first,
        AppUpdateStatus::UpdateAvailable {
            cli_asset_available: true,
            ..
        }
    ));
    assert_eq!(first, second);
}

/// The card names a release or says nothing, so the last document that
/// parsed has to survive a reply that is not one — offline, an error
/// page, a feed with a version no version comparison can read. Each of
/// those three is the same answer here: keep what was known.
#[test]
fn a_reply_that_is_not_a_feed_leaves_the_last_valid_notice_standing() {
    let good = || {
        response(
            "5.1.0",
            r#""x86_64-unknown-linux-gnu":"https://example.test/kendex""#,
        )
    };
    let unusable = [
        Err(CoreError::RegistryUnavailable {
            why: "offline".to_owned(),
        }),
        Ok(FetchResponse {
            status: 503,
            etag: None,
            body: Vec::new(),
        }),
        Ok(FetchResponse {
            status: 200,
            etag: None,
            body: br#"{"schema":1,"version":"not-semver","assets":{}}"#.to_vec(),
        }),
    ];

    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    for (nth, reply) in unusable.into_iter().enumerate() {
        let env = Env::fake(home.join(nth.to_string()), FakeOs::Linux);
        let fetch = Canned::new([good(), reply]);

        let known = check(&env, &fetch, true).unwrap();
        let after = check(&env, &fetch, true).unwrap();

        assert_eq!(after, known, "reply {nth} took the notice away");
        assert_eq!(fetch.calls.get(), 2);
    }
}

/// A `304` with nothing cached to revalidate is a server answering about
/// a document this machine does not hold. There is no release to name,
/// and inventing one off an empty body would put a version on the card.
#[test]
fn a_cold_cache_304_names_no_release() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(home, FakeOs::Linux);
    let fetch = Canned::new([Ok(FetchResponse {
        status: 304,
        etag: None,
        body: Vec::new(),
    })]);

    assert_eq!(
        check(&env, &fetch, true).unwrap(),
        AppUpdateStatus::NeverChecked
    );
}

/// An attempt is an attempt however it went: a feed that is down must not
/// put the app back on the network every time a page asks.
#[test]
fn a_failed_attempt_still_holds_the_interval() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(home, FakeOs::Linux);
    let fetch = Canned::new([Ok(FetchResponse {
        status: 503,
        etag: None,
        body: Vec::new(),
    })]);

    check(&env, &fetch, false).unwrap();
    check(&env, &fetch, false).unwrap();

    assert_eq!(fetch.calls.get(), 1);
}

#[test]
fn a_forced_revalidation_sends_the_cached_etag() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(home, FakeOs::Linux);
    let fetch = Canned::new([
        response("5.1.0", ""),
        Ok(FetchResponse {
            status: 304,
            etag: None,
            body: Vec::new(),
        }),
    ]);

    let first = check(&env, &fetch, true).unwrap();
    let revalidated = check(&env, &fetch, true).unwrap();
    assert_eq!(
        fetch.etags.borrow().as_slice(),
        &[None, Some("etag-5.1.0".to_owned())]
    );
    assert_eq!(
        revalidated, first,
        "a 304 dropped the document it confirmed"
    );
}

#[test]
fn changing_feed_url_drops_the_other_servers_generation_and_etag() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(home, FakeOs::Linux);
    let fetch = Canned::new([
        response("5.1.0", ""),
        Ok(FetchResponse {
            status: 304,
            etag: None,
            body: Vec::new(),
        }),
    ]);

    let first = check_at_url(&env, &fetch, "https://a.test/feed", true, None).unwrap();
    assert!(matches!(first, AppUpdateStatus::UpdateAvailable { .. }));
    let switched = check_at_url(&env, &fetch, "https://b.test/feed", false, None).unwrap();
    assert_eq!(switched, AppUpdateStatus::NeverChecked);
    assert_eq!(
        fetch.urls.borrow().as_slice(),
        &["https://a.test/feed", "https://b.test/feed"]
    );
    assert_eq!(fetch.etags.borrow().as_slice(), &[None, None]);
}

#[test]
fn rollback_clears_the_notice_and_missing_asset_is_not_an_error() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(home, FakeOs::Linux);
    let fetch = Canned::new([response("5.1.0", ""), response("5.0.0", "")]);

    let update = check(&env, &fetch, true).unwrap();
    assert!(matches!(
        update,
        AppUpdateStatus::UpdateAvailable {
            cli_asset_available: false,
            ..
        }
    ));
    let muted = check_at_url(
        &env,
        &fetch,
        "https://example.test/feed.json",
        false,
        Some("5.1.0"),
    )
    .unwrap();
    assert!(matches!(
        muted,
        AppUpdateStatus::UpdateAvailable { muted: true, .. }
    ));
    let rollback = check(&env, &fetch, true).unwrap();
    assert!(matches!(
        rollback,
        AppUpdateStatus::FeedOlder { ref version } if version == "5.0.0"
    ));
}

#[cfg(unix)]
#[test]
fn a_symlinked_cache_entry_is_replaced_without_touching_its_target() {
    let tmp = tempfile::tempdir().unwrap();
    let home = rooted(&tmp);
    let env = Env::fake(home, FakeOs::Linux);
    let cache = env.app_update_cache_file();
    std::fs::create_dir_all(cache.parent().unwrap()).unwrap();
    let target = tmp.path().join("target.json");
    std::fs::write(&target, "keep").unwrap();
    std::os::unix::fs::symlink(&target, &cache).unwrap();
    let fetch = Canned::new([response("5.1.0", "")]);

    check(&env, &fetch, true).unwrap();

    assert!(!cache.is_symlink());
    assert_eq!(std::fs::read_to_string(target).unwrap(), "keep");
    assert!(std::fs::read_to_string(cache).unwrap().contains("5.1.0"));
}
