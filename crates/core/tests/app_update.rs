use std::cell::{Cell, RefCell};
use std::collections::VecDeque;
use std::io::Write;
use std::process::Command;
use std::time::Duration;

use kendex_core::app_update::{self, AppUpdateErrorKind, AppUpdateStatus};
use kendex_core::env::{Env, FakeOs};
use kendex_core::error::{CoreError, Result};
use kendex_core::registry::{Fetch, FetchResponse};

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

fn check(
    env: &Env,
    fetch: &Canned,
    refresh: bool,
    automatic: bool,
) -> kendex_core::error::Result<kendex_core::app_update::AppUpdateView> {
    check_at_url(
        env,
        fetch,
        "https://example.test/feed.json",
        refresh,
        automatic,
        None,
    )
}

fn check_at_url(
    env: &Env,
    fetch: &Canned,
    feed_url: &str,
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
            feed_url,
            refresh,
            automatic_check_enabled: automatic,
            muted_version,
        },
    )
}

fn check_with_mute(
    env: &Env,
    fetch: &Canned,
    refresh: bool,
    automatic: bool,
    muted_version: Option<&str>,
) -> kendex_core::error::Result<kendex_core::app_update::AppUpdateView> {
    check_at_url(
        env,
        fetch,
        "https://example.test/feed.json",
        refresh,
        automatic,
        muted_version,
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
fn http_and_invalid_feed_errors_are_cached_for_the_interval() {
    let tmp = tempfile::tempdir().unwrap();
    let http_env = Env::fake(tmp.path().join("http"), FakeOs::Linux);
    let http = Canned::new([Ok(FetchResponse {
        status: 503,
        etag: None,
        body: Vec::new(),
    })]);
    let failed = check(&http_env, &http, true, true).unwrap();
    assert_eq!(failed.last_error.unwrap().kind, AppUpdateErrorKind::Http);
    let remembered = check(&http_env, &http, false, true).unwrap();
    assert_eq!(
        remembered.last_error.unwrap().kind,
        AppUpdateErrorKind::Http
    );
    assert_eq!(http.calls.get(), 1);

    let invalid_env = Env::fake(tmp.path().join("invalid"), FakeOs::Linux);
    let invalid = Canned::new([Ok(FetchResponse {
        status: 200,
        etag: None,
        body: br#"{"schema":1,"version":"not-semver","assets":{}}"#.to_vec(),
    })]);
    let failed = check(&invalid_env, &invalid, true, true).unwrap();
    assert_eq!(
        failed.last_error.unwrap().kind,
        AppUpdateErrorKind::InvalidFeed
    );
    assert_eq!(invalid.calls.get(), 1);
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
fn changing_feed_url_drops_the_other_servers_generation_and_etag() {
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

    let first = check_at_url(&env, &fetch, "https://a.test/feed", true, true, None).unwrap();
    assert!(matches!(
        first.status,
        AppUpdateStatus::UpdateAvailable { .. }
    ));
    let switched = check_at_url(&env, &fetch, "https://b.test/feed", false, true, None).unwrap();
    assert!(matches!(switched.status, AppUpdateStatus::NeverChecked));
    assert_eq!(switched.last_error.unwrap().kind, AppUpdateErrorKind::Http);
    assert_eq!(
        fetch.urls.borrow().as_slice(),
        &["https://a.test/feed", "https://b.test/feed"]
    );
    assert_eq!(fetch.etags.borrow().as_slice(), &[None, None]);
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

#[cfg(unix)]
#[test]
fn a_symlinked_cache_entry_is_replaced_without_touching_its_target() {
    let tmp = tempfile::tempdir().unwrap();
    let env = Env::fake(tmp.path(), FakeOs::Linux);
    let cache = env.app_update_cache_file();
    std::fs::create_dir_all(cache.parent().unwrap()).unwrap();
    let target = tmp.path().join("target.json");
    std::fs::write(&target, "keep").unwrap();
    std::os::unix::fs::symlink(&target, &cache).unwrap();
    let fetch = Canned::new([response("5.1.0", "")]);

    check(&env, &fetch, true, true).unwrap();

    assert!(!cache.is_symlink());
    assert_eq!(std::fs::read_to_string(target).unwrap(), "keep");
    assert!(std::fs::read_to_string(cache).unwrap().contains("5.1.0"));
}

struct ProcessFetch {
    counter: std::path::PathBuf,
}

impl Fetch for ProcessFetch {
    fn get_auth(
        &self,
        _url: &str,
        _if_none_match: Option<&str>,
        _bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        let mut count = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(&self.counter)
            .map_err(|error| CoreError::io(&self.counter, error))?;
        writeln!(count, "fetch").map_err(|error| CoreError::io(&self.counter, error))?;
        std::thread::sleep(Duration::from_millis(500));
        response("5.1.0", "")
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
fn multiple_processes_share_one_six_hour_attempt() {
    const CHILD_ROOT: &str = "KENDEX_APP_UPDATE_CHILD_ROOT";
    if let Some(root) = std::env::var_os(CHILD_ROOT) {
        let root = std::path::PathBuf::from(root);
        let env = Env::fake(&root, FakeOs::Linux);
        let fetch = ProcessFetch {
            counter: root.join("fetch-count"),
        };
        app_update::check(
            &env,
            &fetch,
            app_update::CheckRequest {
                current_version: "5.0.1",
                target: "x86_64-unknown-linux-gnu",
                feed_url: "https://example.test/feed.json",
                refresh: false,
                automatic_check_enabled: true,
                muted_version: None,
            },
        )
        .unwrap();
        return;
    }

    let tmp = tempfile::tempdir().unwrap();
    let executable = std::env::current_exe().unwrap();
    let spawn = || {
        Command::new(&executable)
            .args([
                "--exact",
                "multiple_processes_share_one_six_hour_attempt",
                "--nocapture",
            ])
            .env(CHILD_ROOT, tmp.path())
            .spawn()
            .unwrap()
    };
    let mut first = spawn();
    let mut second = spawn();
    assert!(first.wait().unwrap().success());
    assert!(second.wait().unwrap().success());
    let count = std::fs::read_to_string(tmp.path().join("fetch-count")).unwrap();
    assert_eq!(count.lines().count(), 1);
}
