//! The identity client: GET /api/v1/me against the contract fixture,
//! every account state, all of them settled and all of them `load`'s
//! answers, the offline cache ladder, and the cache's endpoint key. The
//! UI holds its own "not read yet" and never gets it here. The fixture is
//! a byte copy of kendex-web's
//! `contracts/api/v1/me.json` — drift between the repos is a `cmp` away.

use std::cell::{Cell, RefCell};
use std::path::Path;

use kendex_core::env::{Env, FakeOs};
use kendex_core::error::{CoreError, Result};
use kendex_core::registry::credentials::{Credential, CredentialRefreshGuard, CredentialStore};
use kendex_core::registry::me::{self, AccountState};
use kendex_core::registry::{Fetch, FetchResponse};

const FIXTURE: &str = include_str!("fixtures/api-v1-me.json");

/// A canned transport: each call pops the next scripted answer and
/// records what rode along with it.
struct Canned {
    answers: RefCell<Vec<Result<FetchResponse>>>,
    calls: RefCell<u32>,
    saw_etag: RefCell<Option<String>>,
    bearers: RefCell<Vec<Option<String>>>,
}

impl Canned {
    fn new(answers: Vec<Result<FetchResponse>>) -> Canned {
        Canned {
            answers: RefCell::new(answers),
            calls: RefCell::new(0),
            saw_etag: RefCell::new(None),
            bearers: RefCell::new(Vec::new()),
        }
    }

    fn next(&self, bearer: Option<&str>) -> Result<FetchResponse> {
        *self.calls.borrow_mut() += 1;
        self.bearers.borrow_mut().push(bearer.map(str::to_owned));
        if self.answers.borrow().is_empty() {
            panic!("the test scripted fewer answers than the code asked for");
        }
        self.answers.borrow_mut().remove(0)
    }
}

impl Fetch for Canned {
    fn get_auth(
        &self,
        _url: &str,
        if_none_match: Option<&str>,
        bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        *self.saw_etag.borrow_mut() = if_none_match.map(str::to_owned);
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

fn ok(status: u16, etag: Option<&str>, body: &str) -> Result<FetchResponse> {
    Ok(FetchResponse {
        status,
        etag: etag.map(str::to_string),
        body: body.as_bytes().to_vec(),
    })
}

fn away() -> Result<FetchResponse> {
    Err(CoreError::RegistryUnavailable {
        why: "no route".into(),
    })
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

    fn signed_out() -> MemoryStore {
        MemoryStore(RefCell::new(None))
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

/// A store whose credential disappears after N loads — logout winning a
/// race against the read.
struct VanishingStore {
    loads_before_gone: RefCell<u32>,
    credential: Credential,
}

impl CredentialStore for VanishingStore {
    fn save(&self, _credential: &Credential) -> Result<()> {
        Ok(())
    }
    fn load(&self) -> Result<Option<Credential>> {
        let mut left = self.loads_before_gone.borrow_mut();
        if *left == 0 {
            return Ok(None);
        }
        *left -= 1;
        Ok(Some(self.credential.clone()))
    }
    fn clear(&self) -> Result<()> {
        Ok(())
    }
    fn refresh_guard(&self) -> Result<Box<dyn CredentialRefreshGuard + '_>> {
        Ok(Box::new(MemoryGuard))
    }
}

/// A transport that lets the sign-out — and, when one is given, the
/// sign-in that follows it — land while the identity request is still
/// outstanding. That is the only moment the race is reachable inside one
/// process: the request hangs on the curl cap while the user signs out
/// and completes a device flow as somebody else.
struct RacingFetch<'a> {
    env: &'a Env,
    store: &'a MemoryStore,
    signs_in_as: Option<Credential>,
    answer: RefCell<Option<Result<FetchResponse>>>,
    raced: Cell<bool>,
}

impl<'a> RacingFetch<'a> {
    fn new(
        env: &'a Env,
        store: &'a MemoryStore,
        signs_in_as: Option<Credential>,
        answer: Result<FetchResponse>,
    ) -> RacingFetch<'a> {
        RacingFetch {
            env,
            store,
            signs_in_as,
            answer: RefCell::new(Some(answer)),
            raced: Cell::new(false),
        }
    }
}

impl Fetch for RacingFetch<'_> {
    fn get_auth(
        &self,
        _url: &str,
        _if_none_match: Option<&str>,
        _bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        if !self.raced.replace(true) {
            let revoke = Canned::new(vec![ok(200, None, "{}")]);
            me::sign_out(self.env, &revoke, self.store).expect("sign out mid-read");
            if let Some(next) = &self.signs_in_as {
                me::commit_sign_in(self.env, self.store, next).expect("sign in mid-read");
            }
        }
        self.answer
            .borrow_mut()
            .take()
            .expect("the read asked twice")
    }

    fn post_json_auth(
        &self,
        _url: &str,
        _body: &str,
        _bearer: Option<&str>,
    ) -> Result<FetchResponse> {
        panic!("the identity read posts nothing")
    }
}

fn other_account() -> Credential {
    Credential {
        endpoint: "https://kendex.ai".to_owned(),
        access_token: "kxa_other".to_owned(),
        refresh_token: "kxr_other".to_owned(),
        capabilities: vec![],
    }
}

fn env_in(dir: &Path) -> Env {
    Env::fake(dir, FakeOs::Linux)
}

fn fixture() -> serde_json::Value {
    serde_json::from_str(FIXTURE).expect("fixture parses")
}

fn fixture_node(path: &[&str]) -> serde_json::Value {
    let mut node = fixture();
    for key in path {
        node = node[*key].clone();
    }
    assert!(!node.is_null(), "fixture has no {}", path.join("."));
    node
}

fn fixture_body(path: &[&str]) -> String {
    fixture_node(path).to_string()
}

fn fixture_status(path: &[&str]) -> u16 {
    let status = fixture_node(path).as_u64().expect("status is a number");
    u16::try_from(status).expect("status fits")
}

#[test]
fn no_credential_answers_signed_out_without_the_network() {
    let dir = tempfile::tempdir().expect("tempdir");
    let fetch = Canned::new(vec![]);
    let state = me::load(&env_in(dir.path()), &fetch, &MemoryStore::signed_out()).expect("load");
    assert_eq!(state, AccountState::SignedOut);
    assert_eq!(*fetch.calls.borrow(), 0);
}

#[test]
fn the_fixture_success_body_reads_as_signed_in() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let status = fixture_status(&["success", "status"]);
    let fetch = Canned::new(vec![ok(status, None, &fixture_body(&["success", "body"]))]);
    let state = me::load(&env, &fetch, &MemoryStore::signed_in()).expect("load");
    match state {
        AccountState::SignedIn { identity } => {
            assert_eq!(identity.name, "Ada Lovelace");
            assert_eq!(identity.github_login.as_deref(), Some("1234567"));
        }
        other => panic!("expected signed-in, got {other:?}"),
    }
    assert_eq!(
        fetch.bearers.borrow().as_slice(),
        [Some("kxa_old".to_owned())]
    );
}

#[test]
fn the_fixture_unlinked_body_reads_as_no_github_login() {
    let dir = tempfile::tempdir().expect("tempdir");
    let fetch = Canned::new(vec![ok(
        fixture_status(&["unlinked_github", "status"]),
        None,
        &fixture_body(&["unlinked_github", "body"]),
    )]);
    let state = me::load(&env_in(dir.path()), &fetch, &MemoryStore::signed_in()).expect("load");
    match state {
        AccountState::SignedIn { identity } => assert_eq!(identity.github_login, None),
        other => panic!("expected signed-in, got {other:?}"),
    }
}

#[test]
fn network_away_serves_the_cached_identity_as_offline() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = MemoryStore::signed_in();
    let first = Canned::new(vec![ok(200, None, &fixture_body(&["success", "body"]))]);
    me::load(&env, &first, &store).expect("first load");

    let down = Canned::new(vec![away()]);
    let state = me::load(&env, &down, &store).expect("offline load");
    match state {
        AccountState::Offline { identity } => assert_eq!(identity.name, "Ada Lovelace"),
        other => panic!("expected offline, got {other:?}"),
    }
}

#[test]
fn network_away_with_nothing_cached_is_an_error() {
    let dir = tempfile::tempdir().expect("tempdir");
    let down = Canned::new(vec![away()]);
    assert!(me::load(&env_in(dir.path()), &down, &MemoryStore::signed_in()).is_err());
}

#[test]
fn the_fixture_database_status_rides_the_offline_ladder() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = MemoryStore::signed_in();
    let first = Canned::new(vec![ok(200, None, &fixture_body(&["success", "body"]))]);
    me::load(&env, &first, &store).expect("first load");

    let hurt = Canned::new(vec![ok(
        fixture_status(&["errors", "database_unavailable", "status"]),
        None,
        &fixture_body(&["errors", "database_unavailable", "body"]),
    )]);
    assert!(matches!(
        me::load(&env, &hurt, &store).expect("load"),
        AccountState::Offline { .. }
    ));
}

#[test]
fn a_dead_refresh_grant_reads_as_expired() {
    let dir = tempfile::tempdir().expect("tempdir");
    let store = MemoryStore::signed_in();
    let fetch = Canned::new(vec![
        ok(
            fixture_status(&["errors", "unauthenticated", "status"]),
            None,
            &fixture_body(&["errors", "unauthenticated", "body"]),
        ),
        ok(400, None, r#"{"error":"invalid_grant"}"#),
    ]);
    let state = me::load(&env_in(dir.path()), &fetch, &store).expect("load");
    assert_eq!(state, AccountState::Expired);
    assert!(
        store.load().expect("load").is_none(),
        "a dead credential is not kept for endless retries"
    );
}

#[test]
fn an_expired_credential_drops_the_cached_identity() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = MemoryStore::signed_in();
    let first = Canned::new(vec![ok(200, None, &fixture_body(&["success", "body"]))]);
    me::load(&env, &first, &store).expect("first load");
    let cache = env.registry_cache_dir().join("me.cache.json");
    assert!(cache.exists());

    let dead = Canned::new(vec![
        ok(401, None, r#"{"error":"invalid_token"}"#),
        ok(400, None, r#"{"error":"invalid_grant"}"#),
    ]);
    assert_eq!(
        me::load(&env, &dead, &store).expect("load"),
        AccountState::Expired
    );
    assert!(
        !cache.exists(),
        "the next sign-in must not inherit this account's identity"
    );
}

#[test]
fn a_rotation_the_server_still_rejects_reads_as_expired() {
    let dir = tempfile::tempdir().expect("tempdir");
    let fetch = Canned::new(vec![
        ok(401, None, r#"{"error":"invalid_token"}"#),
        ok(
            200,
            None,
            r#"{"access_token":"kxa_new","refresh_token":"kxr_new","capabilities":["submission:write"]}"#,
        ),
        ok(401, None, r#"{"error":"invalid_token"}"#),
    ]);
    let state = me::load(&env_in(dir.path()), &fetch, &MemoryStore::signed_in()).expect("load");
    assert_eq!(state, AccountState::Expired);
}

#[test]
fn logout_winning_the_race_reads_as_signed_out() {
    let dir = tempfile::tempdir().expect("tempdir");
    // The guard's read and with_access's first read still see the
    // credential; the locked re-read after the 401 finds it gone.
    let store = VanishingStore {
        loads_before_gone: RefCell::new(2),
        credential: Credential {
            endpoint: "https://kendex.ai".to_owned(),
            access_token: "kxa_old".to_owned(),
            refresh_token: "kxr_old".to_owned(),
            capabilities: vec![],
        },
    };
    let fetch = Canned::new(vec![ok(401, None, r#"{"error":"invalid_token"}"#)]);
    let state = me::load(&env_in(dir.path()), &fetch, &store).expect("load");
    assert_eq!(state, AccountState::SignedOut);
    assert_eq!(
        *fetch.calls.borrow(),
        1,
        "no refresh is attempted once logout won"
    );
}

#[test]
fn a_sign_out_landing_mid_read_is_never_written_back() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    // The opening check and with_access both still see the credential; by
    // the time the answer is settled, sign-out has cleared it.
    let store = VanishingStore {
        loads_before_gone: RefCell::new(2),
        credential: Credential {
            endpoint: "https://kendex.ai".to_owned(),
            access_token: "kxa_old".to_owned(),
            refresh_token: "kxr_old".to_owned(),
            capabilities: vec![],
        },
    };
    let fetch = Canned::new(vec![ok(200, None, &fixture_body(&["success", "body"]))]);
    assert_eq!(
        me::load(&env, &fetch, &store).expect("load"),
        AccountState::SignedOut
    );
    assert!(
        !env.registry_cache_dir().join("me.cache.json").exists(),
        "a read finishing after sign-out must leave no identity on disk"
    );
}

#[test]
fn revalidation_sends_the_etag_and_304_keeps_the_identity() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = MemoryStore::signed_in();
    let first = Canned::new(vec![ok(
        200,
        Some("\"v1\""),
        &fixture_body(&["success", "body"]),
    )]);
    me::load(&env, &first, &store).expect("first load");

    let revalidate = Canned::new(vec![ok(304, None, "")]);
    let state = me::load(&env, &revalidate, &store).expect("revalidated");
    assert_eq!(revalidate.saw_etag.borrow().as_deref(), Some("\"v1\""));
    assert!(matches!(state, AccountState::SignedIn { .. }));
}

#[test]
fn a_malformed_answer_serves_the_cache_as_offline() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = MemoryStore::signed_in();
    let first = Canned::new(vec![ok(200, None, &fixture_body(&["success", "body"]))]);
    me::load(&env, &first, &store).expect("first load");

    let garbled = Canned::new(vec![ok(200, None, "<!doctype html>")]);
    assert!(matches!(
        me::load(&env, &garbled, &store).expect("load"),
        AccountState::Offline { .. }
    ));
}

#[test]
fn a_cache_from_another_endpoint_is_never_served() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let registry_dir = env.registry_cache_dir();
    std::fs::create_dir_all(&registry_dir).expect("mkdir");
    std::fs::write(
        registry_dir.join("me.cache.json"),
        r#"{"endpoint":"https://somewhere.else","etag":null,"fetched_at":1,"body":"{\"name\":\"Stranger\",\"github_login\":null}"}"#,
    )
    .expect("write");
    let down = Canned::new(vec![away()]);
    assert!(
        me::load(&env, &down, &MemoryStore::signed_in()).is_err(),
        "another endpoint's identity must not stand in"
    );
}

#[test]
fn sign_out_revokes_and_forgets_the_cached_identity() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = MemoryStore::signed_in();
    let first = Canned::new(vec![ok(200, None, &fixture_body(&["success", "body"]))]);
    me::load(&env, &first, &store).expect("first load");
    let cache = env.registry_cache_dir().join("me.cache.json");
    assert!(cache.exists(), "a successful read caches the identity");

    let revoke = Canned::new(vec![ok(200, None, "{}")]);
    assert!(me::sign_out(&env, &revoke, &store).expect("sign out"));
    assert!(store.load().expect("load").is_none());
    assert!(!cache.exists());

    let quiet = Canned::new(vec![]);
    assert!(
        !me::sign_out(&env, &quiet, &store).expect("already out"),
        "signing out twice is fine and asks the network nothing"
    );
}

#[test]
fn a_failed_revocation_keeps_credential_and_cache_for_retry() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = MemoryStore::signed_in();
    let first = Canned::new(vec![ok(200, None, &fixture_body(&["success", "body"]))]);
    me::load(&env, &first, &store).expect("first load");
    let cache = env.registry_cache_dir().join("me.cache.json");

    let refused = Canned::new(vec![ok(503, None, r#"{"error":"down"}"#)]);
    assert!(me::sign_out(&env, &refused, &store).is_err());
    assert!(store.load().expect("load").is_some());
    assert!(cache.exists(), "still signed in, so still remembered");
}

#[test]
fn a_fresh_sign_in_never_inherits_the_previous_identity() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = MemoryStore::signed_in();
    let first = Canned::new(vec![ok(200, None, &fixture_body(&["success", "body"]))]);
    me::load(&env, &first, &store).expect("first load");
    let cache = env.registry_cache_dir().join("me.cache.json");
    assert!(cache.exists());

    me::commit_sign_in(
        &env,
        &store,
        &Credential {
            endpoint: "https://kendex.ai".to_owned(),
            access_token: "kxa_next".to_owned(),
            refresh_token: "kxr_next".to_owned(),
            capabilities: vec![],
        },
    )
    .expect("commit");
    assert!(!cache.exists(), "the old account's identity is gone");
    assert_eq!(
        store
            .load()
            .expect("load")
            .expect("credential")
            .access_token,
        "kxa_next"
    );
}

#[test]
fn a_304_with_nothing_cached_is_refused() {
    let dir = tempfile::tempdir().expect("tempdir");
    let unchanged = Canned::new(vec![ok(304, None, "")]);
    assert!(
        matches!(
            me::load(&env_in(dir.path()), &unchanged, &MemoryStore::signed_in()),
            Err(CoreError::RegistryMalformed { .. })
        ),
        "an identity cannot be fabricated from 'unchanged'"
    );
}

#[test]
fn an_oversized_identity_cache_reads_as_no_cache() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let registry_dir = env.registry_cache_dir();
    std::fs::create_dir_all(&registry_dir).expect("mkdir");
    // This endpoint's own generation, holding an identity that parses:
    // the size is the only thing left to refuse it, so the cap is what
    // this test measures. A padded body keeps that honest.
    let body = format!(
        r#"{{"name":"Ada Lovelace","github_login":null,"pad":"{}"}}"#,
        "x".repeat(41_000_000)
    );
    let generation = serde_json::json!({
        "endpoint": "https://kendex.ai",
        "etag": serde_json::Value::Null,
        "fetched_at": 1,
        "body": body,
    });
    std::fs::write(
        registry_dir.join("me.cache.json"),
        serde_json::to_string(&generation).expect("generation"),
    )
    .expect("write");
    let down = Canned::new(vec![away()]);
    assert!(
        me::load(&env, &down, &MemoryStore::signed_in()).is_err(),
        "a cache past the cap is never read, however well-formed"
    );
}

#[test]
fn a_read_settling_under_a_replacement_credential_is_discarded() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = MemoryStore::signed_in();
    // Ada's read is in flight when she signs out and somebody else signs
    // in. A credential is installed again by the time it settles, so
    // existence alone would wave this answer through.
    let racing = RacingFetch::new(
        &env,
        &store,
        Some(other_account()),
        ok(200, None, &fixture_body(&["success", "body"])),
    );
    let refused = me::load(&env, &racing, &store).expect_err("a stale identity must be refused");
    assert!(
        matches!(refused, CoreError::RegistryUnavailable { .. }),
        "a replaced credential is a retryable read, not an account state: got {refused:?}"
    );
    assert_eq!(
        store
            .load()
            .expect("load")
            .expect("credential")
            .access_token,
        "kxa_other",
        "the replacement stays installed; only the answer is dropped"
    );
    assert!(
        !env.registry_cache_dir().join("me.cache.json").exists(),
        "the previous account's identity must not be cached under its successor"
    );
}

#[test]
fn a_read_settling_after_a_plain_sign_out_stays_signed_out() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = MemoryStore::signed_in();
    let racing = RacingFetch::new(
        &env,
        &store,
        None,
        ok(200, None, &fixture_body(&["success", "body"])),
    );
    assert_eq!(
        me::load(&env, &racing, &store).expect("load"),
        AccountState::SignedOut,
        "a removed credential is signed out, not a refused read"
    );
    assert!(
        !env.registry_cache_dir().join("me.cache.json").exists(),
        "a read finishing after sign-out must leave no identity on disk"
    );
}

#[test]
fn a_rotation_mid_read_still_settles_the_answer() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = MemoryStore::signed_in();
    // Refreshing replaces both tokens without changing who is signed in,
    // so the answer this read comes back with is still that account's.
    let fetch = Canned::new(vec![
        ok(401, None, r#"{"error":"invalid_token"}"#),
        ok(
            200,
            None,
            r#"{"access_token":"kxa_new","refresh_token":"kxr_new","capabilities":[]}"#,
        ),
        ok(200, None, &fixture_body(&["success", "body"])),
    ]);
    match me::load(&env, &fetch, &store).expect("load") {
        AccountState::SignedIn { identity } => assert_eq!(identity.name, "Ada Lovelace"),
        other => panic!("a rotated sign-in is the same sign-in, got {other:?}"),
    }
    assert_eq!(
        store
            .load()
            .expect("load")
            .expect("credential")
            .refresh_token,
        "kxr_new",
        "the rotation is what makes this the case it is"
    );
    assert!(
        env.registry_cache_dir().join("me.cache.json").exists(),
        "a rotated read caches its identity like any other"
    );
}
