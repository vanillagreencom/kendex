use std::cell::{Cell, RefCell};
use std::collections::VecDeque;

use kendex_core::app_update::{self, AppUpdateErrorKind, AppUpdateStatus};
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::{CoreError, Result};
use kendex_core::registry::{Fetch, FetchResponse};

struct Canned {
    calls: Cell<usize>,
    etags: RefCell<Vec<Option<String>>>,
    answers: RefCell<VecDeque<Result<FetchResponse>>>,
}

impl Canned {
    fn new(answers: impl IntoIterator<Item = Result<FetchResponse>>) -> Self {
        Self {
            calls: Cell::new(0),
            etags: RefCell::new(Vec::new()),
            answers: RefCell::new(answers.into_iter().collect()),
        }
    }
}

impl Fetch for Canned {
    fn get_auth(
        &self,
        _url: &str,
        if_none_match: Option<&str>,
        _bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        self.calls.set(self.calls.get() + 1);
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

fn check(
    env: &Env,
    fetch: &Canned,
    refresh: bool,
    automatic: bool,
) -> kendex_core::error::Result<kendex_core::app_update::AppUpdateView> {
    check_with_mute(env, fetch, refresh, automatic, None)
}

fn check_with_mute(
    env: &Env,
    fetch: &Canned,
    refresh: bool,
    automatic: bool,
    muted_version: Option<&str>,
) -> kendex_core::error::Result<kendex_core::app_update::AppUpdateView> {
    app_update::check(
        env,
        fetch,
        app_update::CheckRequest {
            current_version: "5.0.1",
            target: "x86_64-unknown-linux-gnu",
            feed_url: "https://example.test/feed.json",
            refresh,
            automatic_check_enabled: automatic,
            muted_version,
        },
    )
}

#[test]
fn one_attempt_is_reused_for_six_hours_and_the_off_switch_does_not_fetch() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let fetch = Canned::new([response(
        "5.1.0",
        r#""x86_64-unknown-linux-gnu":"https://example.test/kendex""#,
    )]);

    assert!(matches!(
        check(&env, &fetch, false, false).unwrap().status,
        AppUpdateStatus::NeverChecked
    ));
    let first = check(&env, &fetch, false, true).unwrap();
    let second = check(&env, &fetch, false, true).unwrap();
    assert_eq!(fetch.calls.get(), 1);
    assert_eq!(first.status, second.status);
    assert!(first.last_success_at.is_some());
}

#[test]
fn failure_is_separate_from_the_last_valid_notice() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let fetch = Canned::new([
        response("5.1.0", ""),
        Err(CoreError::RegistryUnavailable {
            why: "offline".to_owned(),
        }),
    ]);

    let first = check(&env, &fetch, true, true).unwrap();
    let failed = check(&env, &fetch, true, true).unwrap();
    assert_eq!(first.status, failed.status);
    assert_eq!(
        failed.last_error.as_ref().map(|error| error.kind),
        Some(AppUpdateErrorKind::Network)
    );
    assert_eq!(fetch.calls.get(), 2);
}

#[test]
fn a_forced_revalidation_sends_the_cached_etag() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let fetch = Canned::new([
        response("5.1.0", ""),
        Ok(FetchResponse {
            status: 304,
            etag: None,
            body: Vec::new(),
        }),
    ]);

    check(&env, &fetch, true, true).unwrap();
    let revalidated = check(&env, &fetch, true, true).unwrap();
    assert_eq!(
        fetch.etags.borrow().as_slice(),
        &[None, Some("etag-5.1.0".to_owned())]
    );
    assert!(revalidated.last_error.is_none());
    assert_eq!(revalidated.served_feed_age_secs, Some(0));
}

#[test]
fn rollback_clears_the_notice_and_missing_asset_is_not_an_error() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let fetch = Canned::new([response("5.1.0", ""), response("5.0.0", "")]);

    let update = check(&env, &fetch, true, true).unwrap();
    assert!(matches!(
        update.status,
        AppUpdateStatus::UpdateAvailable {
            asset_available: false,
            ..
        }
    ));
    let muted = check_with_mute(&env, &fetch, false, false, Some("5.1.0")).unwrap();
    assert!(matches!(
        muted.status,
        AppUpdateStatus::UpdateAvailable { muted: true, .. }
    ));
    let rollback = check(&env, &fetch, true, true).unwrap();
    assert!(matches!(
        rollback.status,
        AppUpdateStatus::FeedOlder { ref version } if version == "5.0.0"
    ));
    assert!(rollback.last_error.is_none());
}
