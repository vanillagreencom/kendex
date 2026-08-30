//! The submissions client: bearer auth from the stored credential, one
//! refresh on a rejected access token (rotation saved before the retry),
//! and separate outcomes for dead grants and retriable refresh failures.

use std::cell::{Cell, RefCell};
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Barrier, Mutex, MutexGuard, mpsc};
use std::time::Duration;

use kendex_core::error::{CoreError, Result};
use kendex_core::registry::client;
use kendex_core::registry::credentials::{Credential, CredentialRefreshGuard, CredentialStore};
use kendex_core::registry::submit::{submissions, submit};
use kendex_core::registry::{Fetch, FetchResponse};

struct Canned {
    answers: RefCell<Vec<(u16, String)>>,
    bearers: RefCell<Vec<Option<String>>>,
}

impl Canned {
    fn new(answers: Vec<(u16, &str)>) -> Canned {
        Canned {
            answers: RefCell::new(
                answers
                    .into_iter()
                    .map(|(status, body)| (status, body.to_owned()))
                    .collect(),
            ),
            bearers: RefCell::new(Vec::new()),
        }
    }

    fn next(&self, bearer: Option<&str>) -> Result<FetchResponse> {
        self.bearers.borrow_mut().push(bearer.map(str::to_owned));
        let (status, body) = self.answers.borrow_mut().remove(0);
        Ok(FetchResponse {
            status,
            etag: None,
            body: body.into_bytes(),
        })
    }
}

impl Fetch for Canned {
    fn get_auth(
        &self,
        _url: &str,
        _etag: Option<&str>,
        bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        self.next(bearer)
    }

    fn post_json_auth(
        &self,
        _url: &str,
        _body: &str,
        bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        self.next(bearer)
    }
}

struct MemoryStore(RefCell<Option<Credential>>);

impl MemoryStore {
    fn signed_in() -> MemoryStore {
        MemoryStore(RefCell::new(Some(Credential {
            endpoint: "https://kendex.ai".to_owned(),
            access_token: "kxa_old".to_owned(),
            refresh_token: "kxr_old".to_owned(),
            capabilities: vec!["submission:write".to_owned()],
            sign_in: "sign-in-old".to_owned(),
        })))
    }
}

impl CredentialStore for MemoryStore {
    fn save(&self, credential: &Credential) -> Result<()> {
        *self.0.borrow_mut() = Some(credential.clone());
        Ok(())
    }
    fn load(&self) -> Result<Option<Credential>> {
        Ok(self.0.borrow().clone())
    }
    fn clear(&self) -> Result<()> {
        *self.0.borrow_mut() = None;
        Ok(())
    }
    fn refresh_guard(&self) -> Result<Box<dyn CredentialRefreshGuard + '_>> {
        Ok(Box::new(MemoryGuard))
    }
}

struct MemoryGuard;
impl CredentialRefreshGuard for MemoryGuard {}

#[test]
#[allow(clippy::unwrap_used)]
fn a_fresh_credential_submits_in_one_call() {
    let fetch = Canned::new(vec![(
        201,
        r#"{"ok":true,"repo":"jane/skills","status":"pending"}"#,
    )]);
    let store = MemoryStore::signed_in();
    let outcome = submit(&fetch, &store, "jane/skills").unwrap();
    assert_eq!(outcome.status, "pending");
    assert_eq!(
        fetch.bearers.borrow().as_slice(),
        [Some("kxa_old".to_owned())]
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_hour_old_rejected_access_token_refreshes_once_and_saves_the_rotation() {
    let fetch = Canned::new(vec![
        (401, r#"{"error":"invalid_token"}"#),
        (
            200,
            r#"{"access_token":"kxa_new","refresh_token":"kxr_new","capabilities":["submission:write"]}"#,
        ),
        (201, r#"{"ok":true,"repo":"jane/skills","status":"listed"}"#),
    ]);
    let store = MemoryStore::signed_in();
    let outcome = submit(&fetch, &store, "jane/skills").unwrap();
    assert_eq!(outcome.status, "listed");
    // The rotated pair replaced the old one before the retry ran.
    let kept = store.load().unwrap().unwrap();
    assert_eq!(kept.access_token, "kxa_new");
    assert_eq!(kept.refresh_token, "kxr_new");
    let bearers = fetch.bearers.borrow();
    assert_eq!(bearers[0].as_deref(), Some("kxa_old"));
    assert_eq!(
        bearers[1], None,
        "the refresh call itself is not bearer-authenticated"
    );
    assert_eq!(bearers[2].as_deref(), Some("kxa_new"));
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_dead_refresh_grant_signs_this_machine_out() {
    let fetch = Canned::new(vec![
        (401, r#"{"error":"invalid_token"}"#),
        (401, r#"{"error":"invalid_grant"}"#),
    ]);
    let store = MemoryStore::signed_in();
    let refused = submit(&fetch, &store, "jane/skills")
        .unwrap_err()
        .to_string();
    assert!(refused.contains("run `kendex login` again"), "{refused}");
    assert!(
        store.load().unwrap().is_none(),
        "a dead credential must not be kept for endless retries"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn signed_out_asks_for_login_before_any_network_call() {
    let fetch = Canned::new(vec![]);
    let store = MemoryStore(RefCell::new(None));
    let refused = submit(&fetch, &store, "jane/skills")
        .unwrap_err()
        .to_string();
    assert!(refused.contains("not signed in"), "{refused}");
    assert!(fetch.bearers.borrow().is_empty());
}

#[test]
#[allow(clippy::unwrap_used)]
fn the_server_refusal_sentence_reaches_the_caller_verbatim() {
    let fetch = Canned::new(vec![(
        403,
        r#"{"error":"you do not hold push authority over this repository"}"#,
    )]);
    let store = MemoryStore::signed_in();
    let refused = submit(&fetch, &store, "jane/skills")
        .unwrap_err()
        .to_string();
    assert!(refused.contains("push authority"), "{refused}");
}

#[test]
#[allow(clippy::unwrap_used)]
fn submissions_parse_the_versioned_rows() {
    let fetch = Canned::new(vec![(
        200,
        r#"{"schema":1,"submissions":[{"repo":"jane/skills","status":"needs-changes","status_reason":"description missing","head_commit":null,"indexed_at":null}]}"#,
    )]);
    let store = MemoryStore::signed_in();
    let rows = submissions(&fetch, &store).unwrap();
    assert_eq!(rows.len(), 1);
    assert_eq!(rows[0].status, "needs-changes");
    assert_eq!(
        rows[0].status_reason.as_deref(),
        Some("description missing")
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_transient_refresh_failure_keeps_the_credential() {
    // 401 on the call, then the refresh endpoint answers 503 (server down)
    // — a transient failure must not sign the machine out.
    let fetch = Canned::new(vec![
        (401, r#"{"error":"invalid_token"}"#),
        (503, r#"{"error":"upstream unavailable"}"#),
    ]);
    let store = MemoryStore::signed_in();
    let refused = submit(&fetch, &store, "jane/skills")
        .unwrap_err()
        .to_string();
    assert!(!refused.contains("run `kendex login`"), "{refused}");
    assert!(
        store.load().unwrap().is_some(),
        "a transient refresh failure must keep the credential"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn rate_limit_and_timeout_refresh_failures_keep_the_credential() {
    for status in [408, 429] {
        let fetch = Canned::new(vec![
            (401, r#"{"error":"invalid_token"}"#),
            (status, r#"{"error":"try again later"}"#),
        ]);
        let store = MemoryStore::signed_in();
        let refused = submit(&fetch, &store, "jane/skills")
            .unwrap_err()
            .to_string();

        assert!(
            !refused.contains("run `kendex login`"),
            "{status}: {refused}"
        );
        assert!(
            store.load().unwrap().is_some(),
            "status {status} must not discard a live refresh grant"
        );
    }
}

struct ConcurrentStore {
    credential: Mutex<Option<Credential>>,
    refresh: Mutex<()>,
    guard_observer: Mutex<Option<mpsc::Sender<()>>>,
}

impl ConcurrentStore {
    fn signed_in() -> Self {
        Self {
            credential: Mutex::new(MemoryStore::signed_in().0.into_inner()),
            refresh: Mutex::new(()),
            guard_observer: Mutex::new(None),
        }
    }

    fn observe_next_guard(&self, observer: mpsc::Sender<()>) {
        *self.guard_observer.lock().expect("test observer lock") = Some(observer);
    }
}

struct ConcurrentGuard<'a> {
    _guard: MutexGuard<'a, ()>,
}
impl CredentialRefreshGuard for ConcurrentGuard<'_> {}

thread_local! {
    static REFRESH_GUARD_DEPTH: Cell<usize> = const { Cell::new(0) };
}

fn current_thread_holds_refresh_guard() -> bool {
    REFRESH_GUARD_DEPTH.get() != 0
}

impl Drop for ConcurrentGuard<'_> {
    fn drop(&mut self) {
        REFRESH_GUARD_DEPTH.set(REFRESH_GUARD_DEPTH.get() - 1);
    }
}

fn lock_error() -> CoreError {
    CoreError::RegistryUnavailable {
        why: "test credential lock poisoned".to_owned(),
    }
}

impl CredentialStore for ConcurrentStore {
    fn save(&self, credential: &Credential) -> Result<()> {
        *self.credential.lock().map_err(|_| lock_error())? = Some(credential.clone());
        Ok(())
    }

    fn load(&self) -> Result<Option<Credential>> {
        Ok(self.credential.lock().map_err(|_| lock_error())?.clone())
    }

    fn clear(&self) -> Result<()> {
        *self.credential.lock().map_err(|_| lock_error())? = None;
        Ok(())
    }

    fn refresh_guard(&self) -> Result<Box<dyn CredentialRefreshGuard + '_>> {
        if let Some(observer) = self.guard_observer.lock().map_err(|_| lock_error())?.take() {
            observer
                .send(())
                .map_err(|error| CoreError::RegistryUnavailable {
                    why: error.to_string(),
                })?;
        }
        let guard = self.refresh.lock().map_err(|_| lock_error())?;
        REFRESH_GUARD_DEPTH.set(REFRESH_GUARD_DEPTH.get() + 1);
        Ok(Box::new(ConcurrentGuard { _guard: guard }))
    }
}

struct ConcurrentFetch {
    old_access: Arc<Barrier>,
    old_calls: AtomicUsize,
    refresh_calls: AtomicUsize,
    new_calls: AtomicUsize,
    new_calls_under_lock: AtomicUsize,
}

impl ConcurrentFetch {
    fn response(status: u16, body: &str) -> Result<FetchResponse> {
        Ok(FetchResponse {
            status,
            etag: None,
            body: body.as_bytes().to_vec(),
        })
    }
}

impl Fetch for ConcurrentFetch {
    fn get_auth(
        &self,
        _url: &str,
        _etag: Option<&str>,
        _bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        Err(CoreError::RegistryUnavailable {
            why: "unexpected GET".to_owned(),
        })
    }

    fn post_json_auth(
        &self,
        _url: &str,
        _body: &str,
        bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        match bearer {
            Some("kxa_old") => {
                self.old_calls.fetch_add(1, Ordering::SeqCst);
                self.old_access.wait();
                Self::response(401, r#"{"error":"invalid_token"}"#)
            }
            Some("kxa_new") => {
                self.new_calls.fetch_add(1, Ordering::SeqCst);
                if current_thread_holds_refresh_guard() {
                    self.new_calls_under_lock.fetch_add(1, Ordering::SeqCst);
                }
                Self::response(201, r#"{"repo":"jane/skills","status":"listed"}"#)
            }
            None => {
                self.refresh_calls.fetch_add(1, Ordering::SeqCst);
                Self::response(
                    200,
                    r#"{"access_token":"kxa_new","refresh_token":"kxr_new","capabilities":["submission:write"]}"#,
                )
            }
            Some(other) => Err(CoreError::RegistryUnavailable {
                why: format!("unexpected bearer {other}"),
            }),
        }
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn concurrent_cli_and_app_calls_rotate_one_refresh_token_once() {
    let fetch = Arc::new(ConcurrentFetch {
        old_access: Arc::new(Barrier::new(2)),
        old_calls: AtomicUsize::new(0),
        refresh_calls: AtomicUsize::new(0),
        new_calls: AtomicUsize::new(0),
        new_calls_under_lock: AtomicUsize::new(0),
    });
    let store = Arc::new(ConcurrentStore::signed_in());
    let run = || {
        let fetch = Arc::clone(&fetch);
        let store = Arc::clone(&store);
        std::thread::spawn(move || submit(fetch.as_ref(), store.as_ref(), "jane/skills"))
    };
    let first = run();
    let second = run();

    assert_eq!(first.join().unwrap().unwrap().status, "listed");
    assert_eq!(second.join().unwrap().unwrap().status, "listed");
    assert_eq!(fetch.old_calls.load(Ordering::SeqCst), 2);
    assert_eq!(fetch.refresh_calls.load(Ordering::SeqCst), 1);
    assert_eq!(fetch.new_calls.load(Ordering::SeqCst), 2);
    assert_eq!(
        fetch.new_calls_under_lock.load(Ordering::SeqCst),
        0,
        "remote retries must not hold the credential transaction lock"
    );
    let kept = store.load().unwrap().unwrap();
    assert_eq!(kept.access_token, "kxa_new");
    assert_eq!(kept.refresh_token, "kxr_new");
}

struct LogoutFetch {
    old_seen: mpsc::Sender<()>,
    refresh_calls: AtomicUsize,
}

impl Fetch for LogoutFetch {
    fn get_auth(
        &self,
        _url: &str,
        _etag: Option<&str>,
        _bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        Err(CoreError::RegistryUnavailable {
            why: "unexpected GET".to_owned(),
        })
    }

    fn post_json_auth(
        &self,
        _url: &str,
        _body: &str,
        bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        match bearer {
            Some("kxa_old") => {
                self.old_seen
                    .send(())
                    .map_err(|error| CoreError::RegistryUnavailable {
                        why: error.to_string(),
                    })?;
                ConcurrentFetch::response(401, r#"{"error":"invalid_token"}"#)
            }
            None => {
                self.refresh_calls.fetch_add(1, Ordering::SeqCst);
                ConcurrentFetch::response(
                    200,
                    r#"{"access_token":"kxa_new","refresh_token":"kxr_new","capabilities":[]}"#,
                )
            }
            Some(other) => Err(CoreError::RegistryUnavailable {
                why: format!("unexpected bearer {other}"),
            }),
        }
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn logout_while_waiting_for_refresh_does_not_resurrect_the_credential() {
    let store = Arc::new(ConcurrentStore::signed_in());
    let held = store.refresh_guard().unwrap();
    let (old_seen, observed) = mpsc::channel();
    let fetch = Arc::new(LogoutFetch {
        old_seen,
        refresh_calls: AtomicUsize::new(0),
    });
    let worker_store = Arc::clone(&store);
    let worker_fetch = Arc::clone(&fetch);
    let worker = std::thread::spawn(move || {
        submit(worker_fetch.as_ref(), worker_store.as_ref(), "jane/skills")
    });

    observed.recv().unwrap();
    store.clear().unwrap();
    drop(held);
    let refused = worker.join().unwrap().unwrap_err().to_string();

    assert!(refused.contains("not signed in"), "{refused}");
    assert_eq!(fetch.refresh_calls.load(Ordering::SeqCst), 0);
    assert!(store.load().unwrap().is_none());
}

struct TransactionFetch {
    refresh_started: mpsc::Sender<()>,
    allow_refresh: Mutex<mpsc::Receiver<()>>,
    refresh_answer: (u16, &'static str),
    revoked: Mutex<Vec<String>>,
    login_access_calls: AtomicUsize,
}

impl TransactionFetch {
    fn response(status: u16, body: &str) -> Result<FetchResponse> {
        ConcurrentFetch::response(status, body)
    }
}

impl Fetch for TransactionFetch {
    fn get_auth(
        &self,
        _url: &str,
        _etag: Option<&str>,
        _bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        Err(CoreError::RegistryUnavailable {
            why: "unexpected GET".to_owned(),
        })
    }

    fn post_json_auth(&self, url: &str, body: &str, bearer: Option<&str>) -> Result<FetchResponse> {
        match bearer {
            Some("kxa_old") => Self::response(401, r#"{"error":"invalid_token"}"#),
            Some("kxa_rotated") => {
                Self::response(201, r#"{"repo":"jane/skills","status":"listed"}"#)
            }
            Some("kxa_login") => {
                self.login_access_calls.fetch_add(1, Ordering::SeqCst);
                Self::response(201, r#"{"repo":"jane/skills","status":"listed"}"#)
            }
            None if url.ends_with("/api/v1/device/token") => {
                self.refresh_started
                    .send(())
                    .map_err(|error| CoreError::RegistryUnavailable {
                        why: error.to_string(),
                    })?;
                self.allow_refresh
                    .lock()
                    .map_err(|_| lock_error())?
                    .recv()
                    .map_err(|error| CoreError::RegistryUnavailable {
                        why: error.to_string(),
                    })?;
                Self::response(self.refresh_answer.0, self.refresh_answer.1)
            }
            None if url.ends_with("/api/v1/tokens/revoke") => {
                self.revoked
                    .lock()
                    .map_err(|_| lock_error())?
                    .push(body.to_owned());
                Self::response(200, r#"{"ok":true}"#)
            }
            Some(other) => Err(CoreError::RegistryUnavailable {
                why: format!("unexpected bearer {other}"),
            }),
            None => Err(CoreError::RegistryUnavailable {
                why: format!("unexpected unauthenticated POST {url}"),
            }),
        }
    }
}

fn transaction_fixture() -> (
    Arc<ConcurrentStore>,
    Arc<TransactionFetch>,
    mpsc::Receiver<()>,
    mpsc::Sender<()>,
) {
    transaction_fixture_with_refresh((
        200,
        r#"{"access_token":"kxa_rotated","refresh_token":"kxr_rotated","capabilities":["submission:write"]}"#,
    ))
}

fn transaction_fixture_with_refresh(
    refresh_answer: (u16, &'static str),
) -> (
    Arc<ConcurrentStore>,
    Arc<TransactionFetch>,
    mpsc::Receiver<()>,
    mpsc::Sender<()>,
) {
    let (refresh_started, observed) = mpsc::channel();
    let (allow, allow_refresh) = mpsc::channel();
    (
        Arc::new(ConcurrentStore::signed_in()),
        Arc::new(TransactionFetch {
            refresh_started,
            allow_refresh: Mutex::new(allow_refresh),
            refresh_answer,
            revoked: Mutex::new(Vec::new()),
            login_access_calls: AtomicUsize::new(0),
        }),
        observed,
        allow,
    )
}

fn spawn_refresh(
    fetch: &Arc<TransactionFetch>,
    store: &Arc<ConcurrentStore>,
) -> std::thread::JoinHandle<Result<kendex_core::registry::submit::Submitted>> {
    let fetch = Arc::clone(fetch);
    let store = Arc::clone(store);
    std::thread::spawn(move || submit(fetch.as_ref(), store.as_ref(), "jane/skills"))
}

fn replacement_login() -> Credential {
    Credential {
        endpoint: "https://kendex.ai".to_owned(),
        access_token: "kxa_login".to_owned(),
        refresh_token: "kxr_login".to_owned(),
        capabilities: vec!["submission:write".to_owned()],
        sign_in: "sign-in-login".to_owned(),
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_login_waiting_for_refresh_commits_the_new_family_last() {
    let (store, fetch, refresh_started, allow_refresh) = transaction_fixture();
    let refresh = spawn_refresh(&fetch, &store);
    refresh_started.recv().unwrap();

    let (guard_attempted, observed_guard) = mpsc::channel();
    store.observe_next_guard(guard_attempted);
    let login_store = Arc::clone(&store);
    let login = std::thread::spawn(move || {
        client::commit_login(login_store.as_ref(), &replacement_login())
    });
    observed_guard.recv_timeout(Duration::from_secs(1)).unwrap();
    allow_refresh.send(()).unwrap();

    assert_eq!(refresh.join().unwrap().unwrap().status, "listed");
    login.join().unwrap().unwrap();
    let kept = store.load().unwrap().unwrap();
    assert_eq!(kept.access_token, "kxa_login");
    assert_eq!(kept.refresh_token, "kxr_login");
    assert_eq!(
        fetch.login_access_calls.load(Ordering::SeqCst),
        0,
        "login must wait for the in-flight refresh transaction"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_logout_waiting_for_refresh_revokes_the_rotated_family_last() {
    let (store, fetch, refresh_started, allow_refresh) = transaction_fixture();
    let refresh = spawn_refresh(&fetch, &store);
    refresh_started.recv().unwrap();

    let (guard_attempted, observed_guard) = mpsc::channel();
    store.observe_next_guard(guard_attempted);
    let logout_store = Arc::clone(&store);
    let logout_fetch = Arc::clone(&fetch);
    let logout =
        std::thread::spawn(move || client::logout(logout_fetch.as_ref(), logout_store.as_ref()));
    observed_guard.recv_timeout(Duration::from_secs(1)).unwrap();
    allow_refresh.send(()).unwrap();

    assert_eq!(refresh.join().unwrap().unwrap().status, "listed");
    assert!(logout.join().unwrap().unwrap());
    assert!(store.load().unwrap().is_none());
    let revoked = fetch.revoked.lock().unwrap();
    assert_eq!(revoked.len(), 1);
    assert!(revoked[0].contains("kxr_rotated"), "{}", revoked[0]);
}
