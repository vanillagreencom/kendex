//! Mixed-version logout safety and bounded concurrent-token retries.

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
}

impl Store {
    fn signed_in() -> Self {
        Self {
            credential: Mutex::new(Some(credential("old"))),
            transaction: Mutex::new(()),
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
        *self.credential.lock().map_err(|_| lock_error())? = None;
        Ok(())
    }

    fn refresh_guard(&self) -> Result<Box<dyn CredentialRefreshGuard + '_>> {
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
fn an_older_login_during_revoke_is_preserved() {
    let (store, fetch, revoke_started, allow_revoke) = logout_fixture();
    let logout = spawn_logout(&fetch, &store);
    revoke_started.recv().unwrap();

    store.save(&credential("replacement")).unwrap();
    allow_revoke.send(()).unwrap();

    let refused = logout.join().unwrap().unwrap_err().to_string();
    assert!(refused.contains("sign-in changed"), "{refused}");
    assert!(refused.contains("retry the request"), "{refused}");
    let kept = store.load().unwrap().unwrap();
    assert_eq!(kept.access_token, "kxa_replacement");
    assert_eq!(kept.refresh_token, "kxr_replacement");
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
    assert_eq!(store.load().unwrap().unwrap().access_token, "kxa_newer-two");
}
