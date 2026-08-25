//! The submissions client: bearer auth from the stored credential, one
//! refresh on a rejected access token (rotation saved before the retry),
//! and an honest sign-out when the refresh itself is refused.

use std::cell::RefCell;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Barrier, Mutex, MutexGuard, mpsc};

use kendex_core::error::{CoreError, Result};
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
fn a_refused_refresh_signs_this_machine_out() {
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

struct ConcurrentStore {
    credential: Mutex<Option<Credential>>,
    refresh: Mutex<()>,
}

impl ConcurrentStore {
    fn signed_in() -> Self {
        Self {
            credential: Mutex::new(MemoryStore::signed_in().0.into_inner()),
            refresh: Mutex::new(()),
        }
    }
}

struct ConcurrentGuard<'a> {
    _guard: MutexGuard<'a, ()>,
}
impl CredentialRefreshGuard for ConcurrentGuard<'_> {}

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
        Ok(Box::new(ConcurrentGuard {
            _guard: self.refresh.lock().map_err(|_| lock_error())?,
        }))
    }
}

struct ConcurrentFetch {
    old_access: Arc<Barrier>,
    old_calls: AtomicUsize,
    refresh_calls: AtomicUsize,
    new_calls: AtomicUsize,
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
