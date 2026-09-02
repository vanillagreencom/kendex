//! Mixed-version logout safety, bounded concurrent-token retries, and
//! credential removal failures.

use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, Mutex, MutexGuard, mpsc};

use kendex_core::error::{CoreError, Result};
use kendex_core::registry::client;
use kendex_core::registry::credentials::{Credential, CredentialRefreshGuard, CredentialStore};
use kendex_core::registry::submit::submit;
use kendex_core::registry::{Fetch, FetchResponse};

struct Store {
    credential: Mutex<Option<Credential>>,
    transaction: Mutex<()>,
    /// Which take of the refresh guard starts refusing, counting from one —
    /// a lock another process holds past the deadline.
    guard_refused_from: Option<usize>,
    guard_takes: AtomicUsize,
    /// A keychain that will not give the credential up: the delete fails
    /// and the credential stays installed.
    delete_refused: bool,
}

impl Store {
    fn signed_in() -> Self {
        Self {
            credential: Mutex::new(Some(credential("old"))),
            transaction: Mutex::new(()),
            guard_refused_from: None,
            guard_takes: AtomicUsize::new(0),
            delete_refused: false,
        }
    }

    fn guard_refused_from(take: usize) -> Self {
        Self {
            guard_refused_from: Some(take),
            ..Self::signed_in()
        }
    }

    fn delete_refused() -> Self {
        Self {
            delete_refused: true,
            ..Self::signed_in()
        }
    }
}

struct Guard<'a> {
    _guard: MutexGuard<'a, ()>,
}
impl CredentialRefreshGuard for Guard<'_> {}

fn lock_error() -> CoreError {
    CoreError::RegistryUnavailable {
        why: "test credential lock poisoned".to_owned(),
    }
}

impl CredentialStore for Store {
    fn save(&self, credential: &Credential) -> Result<()> {
        *self.credential.lock().map_err(|_| lock_error())? = Some(credential.clone());
        Ok(())
    }

    fn load(&self) -> Result<Option<Credential>> {
        Ok(self.credential.lock().map_err(|_| lock_error())?.clone())
    }

    fn clear(&self) -> Result<()> {
        if self.delete_refused {
            // A stand-in for a keychain that will not give the sign-in up.
            // What `KeyringStore::clear` really builds is pinned by
            // tests/credential_store_refusals.rs; this literal only feeds
            // `expired()`.
            return Err(CoreError::CredentialStoreUnavailable {
                why: "the removal was refused: the keyring is locked".to_owned(),
            });
        }
        *self.credential.lock().map_err(|_| lock_error())? = None;
        Ok(())
    }

    fn refresh_guard(&self) -> Result<Box<dyn CredentialRefreshGuard + '_>> {
        let take = self.guard_takes.fetch_add(1, Ordering::SeqCst) + 1;
        if self.guard_refused_from.is_some_and(|first| take >= first) {
            // Named, never opened: nothing here resolves the path, and a
            // real spelling would be a second copy of the one the store
            // derives.
            return Err(CoreError::CredentialRefreshBusy {
                lock: std::path::PathBuf::from("held-by-another-process"),
            });
        }
        Ok(Box::new(Guard {
            _guard: self.transaction.lock().map_err(|_| lock_error())?,
        }))
    }
}

fn credential(name: &str) -> Credential {
    Credential {
        endpoint: "https://kendex.ai".to_owned(),
        access_token: format!("kxa_{name}"),
        refresh_token: format!("kxr_{name}"),
        capabilities: vec!["submission:write".to_owned()],
        sign_in: format!("sign-in-{name}"),
    }
}

fn response(status: u16, body: &str) -> Result<FetchResponse> {
    Ok(FetchResponse {
        status,
        etag: None,
        body: body.as_bytes().to_vec(),
    })
}

struct BlockingRevoke {
    started: mpsc::Sender<()>,
    proceed: Mutex<mpsc::Receiver<()>>,
}

impl Fetch for BlockingRevoke {
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
        assert!(url.ends_with("/api/v1/tokens/revoke"), "{url}");
        assert_eq!(bearer, None);
        assert!(body.contains("kxr_old"), "{body}");
        self.started
            .send(())
            .map_err(|error| CoreError::RegistryUnavailable {
                why: error.to_string(),
            })?;
        self.proceed
            .lock()
            .map_err(|_| lock_error())?
            .recv()
            .map_err(|error| CoreError::RegistryUnavailable {
                why: error.to_string(),
            })?;
        response(200, r#"{"ok":true}"#)
    }
}

fn logout_fixture() -> (
    Arc<Store>,
    Arc<BlockingRevoke>,
    mpsc::Receiver<()>,
    mpsc::Sender<()>,
) {
    let (started, observed) = mpsc::channel();
    let (allow, proceed) = mpsc::channel();
    (
        Arc::new(Store::signed_in()),
        Arc::new(BlockingRevoke {
            started,
            proceed: Mutex::new(proceed),
        }),
        observed,
        allow,
    )
}

fn spawn_logout(
    fetch: &Arc<BlockingRevoke>,
    store: &Arc<Store>,
) -> std::thread::JoinHandle<Result<bool>> {
    let fetch = Arc::clone(fetch);
    let store = Arc::clone(store);
    std::thread::spawn(move || client::logout(fetch.as_ref(), store.as_ref()))
}

#[test]
#[allow(clippy::unwrap_used)]
fn an_older_logout_during_revoke_stays_signed_out() {
    let (store, fetch, revoke_started, allow_revoke) = logout_fixture();
    let logout = spawn_logout(&fetch, &store);
    revoke_started.recv().unwrap();

    store.clear().unwrap();
    allow_revoke.send(()).unwrap();

    assert!(logout.join().unwrap().unwrap());
    assert!(store.load().unwrap().is_none());
}

struct RejectingNewerTokens {
    store: Arc<Store>,
    bearers: Mutex<Vec<String>>,
    refresh_calls: AtomicUsize,
}

impl Fetch for RejectingNewerTokens {
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
        let Some(bearer) = bearer else {
            self.refresh_calls.fetch_add(1, Ordering::SeqCst);
            return Err(CoreError::RegistryUnavailable {
                why: "the bounded retry unexpectedly refreshed".to_owned(),
            });
        };
        self.bearers
            .lock()
            .map_err(|_| lock_error())?
            .push(bearer.to_owned());
        match bearer {
            "kxa_old" => self.store.save(&credential("newer-one"))?,
            "kxa_newer-one" => self.store.save(&credential("newer-two"))?,
            "kxa_newer-two" => {}
            other => {
                return Err(CoreError::RegistryUnavailable {
                    why: format!("unexpected bearer {other}"),
                });
            }
        }
        response(401, r#"{"error":"invalid_token"}"#)
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn two_rejected_concurrent_tokens_end_the_bounded_retry() {
    let store = Arc::new(Store::signed_in());
    let fetch = RejectingNewerTokens {
        store: Arc::clone(&store),
        bearers: Mutex::new(Vec::new()),
        refresh_calls: AtomicUsize::new(0),
    };

    let refused = submit(&fetch, store.as_ref(), "jane/skills")
        .unwrap_err()
        .to_string();

    assert!(
        refused.contains("server does not accept this sign-in"),
        "{refused}"
    );
    assert_eq!(
        fetch.bearers.lock().unwrap().as_slice(),
        ["kxa_old", "kxa_newer-one", "kxa_newer-two"]
    );
    assert_eq!(fetch.refresh_calls.load(Ordering::SeqCst), 0);
    assert!(
        store.load().unwrap().is_none(),
        "the sign-in the server refused is not left installed"
    );
}

/// Rotates once and rejects the fresh token too.
struct RejectingRotation {
    store: Arc<Store>,
    logout_on_rotated: bool,
}

impl Fetch for RejectingRotation {
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
        body: &str,
        bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        let Some(bearer) = bearer else {
            assert!(body.contains("kxr_old"), "{body}");
            return response(
                200,
                r#"{"access_token":"kxa_rotated","refresh_token":"kxr_rotated","capabilities":["submission:write"]}"#,
            );
        };
        match bearer {
            "kxa_old" => {}
            "kxa_rotated" if self.logout_on_rotated => self.store.clear()?,
            "kxa_rotated" => {}
            other => {
                return Err(CoreError::RegistryUnavailable {
                    why: format!("unexpected bearer {other}"),
                });
            }
        }
        response(401, r#"{"error":"invalid_token"}"#)
    }
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_rotation_the_server_still_rejects_clears_the_sign_in() {
    let store = Arc::new(Store::signed_in());
    let fetch = RejectingRotation {
        store: Arc::clone(&store),
        logout_on_rotated: false,
    };

    let refused = submit(&fetch, store.as_ref(), "jane/skills")
        .unwrap_err()
        .to_string();

    assert!(
        refused.contains("server does not accept this sign-in"),
        "{refused}"
    );
    assert!(
        refused.contains("— run `kendex login` again"),
        "with the credential gone, signing in again is what works: {refused}"
    );
    assert!(
        store.load().unwrap().is_none(),
        "the freshly rotated family the server refused is not left installed"
    );
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_logout_landing_after_rotation_still_answers_expired() {
    let store = Arc::new(Store::signed_in());
    let fetch = RejectingRotation {
        store: Arc::clone(&store),
        logout_on_rotated: true,
    };

    let refused = submit(&fetch, store.as_ref(), "jane/skills")
        .unwrap_err()
        .to_string();

    assert!(
        refused.contains("server does not accept this sign-in"),
        "{refused}"
    );
    assert!(
        !refused.contains("could not be removed"),
        "nothing was left to remove: {refused}"
    );
    assert!(store.load().unwrap().is_none());
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_store_that_will_not_open_still_answers_expired() {
    // Rotation takes the guard once; the take that removes the rejected
    // family is the second, and that is the one another process holds.
    let store = Arc::new(Store::guard_refused_from(2));
    let fetch = RejectingRotation {
        store: Arc::clone(&store),
        logout_on_rotated: false,
    };

    let refused = submit(&fetch, store.as_ref(), "jane/skills")
        .unwrap_err()
        .to_string();

    assert!(
        refused.contains("server does not accept this sign-in"),
        "a store failure must not stand in for the server's refusal: {refused}"
    );
    assert!(
        refused.contains("the local copy could not be removed: credential refresh is busy"),
        "the user learns the sign-in is dead and still installed: {refused}"
    );
    assert_eq!(store.load().unwrap().unwrap().access_token, "kxa_rotated");
}

#[test]
#[allow(clippy::unwrap_used)]
fn a_store_that_will_not_delete_still_answers_expired() {
    let store = Arc::new(Store::delete_refused());
    let fetch = RejectingRotation {
        store: Arc::clone(&store),
        logout_on_rotated: false,
    };

    let refused = submit(&fetch, store.as_ref(), "jane/skills")
        .unwrap_err()
        .to_string();

    assert!(
        refused.contains("server does not accept this sign-in"),
        "a delete failure must not stand in for the server's refusal: {refused}"
    );
    assert!(
        refused.contains("the local copy could not be removed"),
        "the user learns the credential is still installed: {refused}"
    );
    assert!(
        refused.contains("the credential store on this machine"),
        "expired() replaced the store's refusal instead of composing it: {refused}"
    );
    assert!(
        !refused.contains("— run `kendex login` again"),
        "signing in again refuses while the credential is still installed: {refused}"
    );
    assert_eq!(
        store.load().unwrap().unwrap().access_token,
        "kxa_rotated",
        "the delete failed, so the family the server refused is still installed"
    );
}
