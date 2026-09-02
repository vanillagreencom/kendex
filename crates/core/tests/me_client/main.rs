//! The identity client: GET /api/v1/me against the contract fixture,
//! every account state, all of them settled and all of them `load`'s
//! answers, the offline cache ladder, and the cache's endpoint key. The
//! UI holds its own "not read yet" and never gets it here. Which sign-in
//! an answer belongs to is the cache generation. The fixture is a byte copy
//! of kendex-web's `contracts/api/v1/me.json` — drift between the repos
//! is a `cmp` away.

use std::cell::{Cell, RefCell};
use std::path::Path;

#[path = "../../../test_util.rs"]
mod test_util;
use test_util::rooted;

use kendex_core::env::{Env, FakeOs};
use kendex_core::error::{CoreError, Result};
use kendex_core::registry::credentials::{Credential, CredentialRefreshGuard, CredentialStore};
use kendex_core::registry::me::{self, AccountState};
use kendex_core::registry::{Fetch, FetchResponse};

const FIXTURE: &str = include_str!("../fixtures/api-v1-me.json");

/// The sign-in every fixture credential belongs to. A rotation carries it
/// and only a new sign-in changes it, so a cache keyed to it survives one
/// and not the other.
const ADA: &str = "sign-in-ada";

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

struct MemoryStore {
    credential: RefCell<Option<Credential>>,
    /// Which read starts refusing, counting from one: a keychain that locks
    /// after `load` has taken the sign-in and before the authenticated call
    /// takes it again.
    refuses_from: Option<u32>,
    reads: Cell<u32>,
}

impl MemoryStore {
    fn holding(credential: Option<Credential>) -> MemoryStore {
        MemoryStore {
            credential: RefCell::new(credential),
            refuses_from: None,
            reads: Cell::new(0),
        }
    }

    fn signed_in() -> MemoryStore {
        MemoryStore::holding(Some(Credential {
            endpoint: "https://kendex.ai".to_owned(),
            access_token: "kxa_old".to_owned(),
            refresh_token: "kxr_old".to_owned(),
            capabilities: vec!["submission:write".to_owned()],
            sign_in: ADA.to_owned(),
        }))
    }

    fn signed_out() -> MemoryStore {
        MemoryStore::holding(None)
    }

    fn refusing_from(read: u32) -> MemoryStore {
        MemoryStore {
            refuses_from: Some(read),
            ..MemoryStore::signed_in()
        }
    }
}

impl CredentialStore for MemoryStore {
    fn save(&self, credential: &Credential) -> Result<()> {
        *self.credential.borrow_mut() = Some(credential.clone());
        Ok(())
    }
    fn load(&self) -> Result<Option<Credential>> {
        let read = self.reads.get() + 1;
        self.reads.set(read);
        if self.refuses_from.is_some_and(|first| read >= first) {
            // The shape `KeyringStore::load` answers with; its wording is
            // pinned by tests/credential_store_refusals.rs.
            return Err(CoreError::CredentialStoreUnavailable {
                why: "the stored sign-in could not be read: the keyring is locked".to_owned(),
            });
        }
        Ok(self.credential.borrow().clone())
    }
    fn clear(&self) -> Result<()> {
        *self.credential.borrow_mut() = None;
        Ok(())
    }
    fn refresh_guard(&self) -> Result<Box<dyn CredentialRefreshGuard + '_>> {
        Ok(Box::new(MemoryGuard))
    }
}

struct MemoryGuard;
impl CredentialRefreshGuard for MemoryGuard {}

/// The key a generation carries beside its endpoint, exactly as `me.rs`
/// writes it. A cache planted by hand needs the sign-in it belongs to, or
/// the read refuses it for the wrong reason and the test proves nothing.
fn sign_in_key(sign_in: &str) -> serde_json::Value {
    kendex_core::hash::hash_bytes(sign_in.as_bytes()).into()
}

/// Plant a generation where a finished read would have left one.
#[allow(
    clippy::expect_used,
    reason = "a fixture the test cannot plant is a broken precondition, not a case"
)]
fn write_cache(env: &Env, body: &str, etag: Option<&str>, sign_in: Option<&str>) {
    let dir = env.registry_cache_dir();
    std::fs::create_dir_all(&dir).expect("mkdir");
    let generation = serde_json::json!({
        "endpoint": "https://kendex.ai",
        "credential": sign_in.map(sign_in_key),
        "etag": etag,
        "fetched_at": 1,
        "body": body,
    });
    std::fs::write(
        dir.join("me.cache.json"),
        serde_json::to_string(&generation).expect("generation"),
    )
    .expect("write");
}

fn env_in(dir: &Path) -> Env {
    Env::fake(dir, FakeOs::Linux)
}

#[allow(
    clippy::expect_used,
    reason = "a fixture that will not parse is a broken precondition, not a case"
)]
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

#[allow(
    clippy::expect_used,
    reason = "a fixture status that is not a u16 is a broken precondition, not a case"
)]
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
        AccountState::SignedIn { identity, .. } => {
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
        AccountState::SignedIn { identity, .. } => assert_eq!(identity.github_login, None),
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
        AccountState::Offline { identity, .. } => assert_eq!(identity.name, "Ada Lovelace"),
        other => panic!("expected offline, got {other:?}"),
    }
}

/// A warm cache answers for a directory that will not talk. It must not
/// answer for a keychain that will not talk: the machine never asked the
/// directory anything, so "when kendex.ai was last reached" is a lie about
/// what failed.
#[test]
fn a_refusing_keychain_is_not_served_as_offline() {
    let dir = tempfile::tempdir().expect("tempdir");
    let root = rooted(&dir);
    let env = env_in(&root);
    let warm = MemoryStore::signed_in();
    let first = Canned::new(vec![ok(200, None, &fixture_body(&["success", "body"]))]);
    me::load(&env, &first, &warm).expect("first load");

    // The second read is the one inside the authenticated call: the sign-in
    // check ahead of it must still pass, or nothing reaches the seam.
    let store = MemoryStore::refusing_from(2);
    let unused = Canned::new(vec![]);
    let refused = me::load(&env, &unused, &store).expect_err("a refusing keychain errors");

    assert!(
        matches!(refused, CoreError::CredentialStoreUnavailable { .. }),
        "the cache stood in for the keychain: {refused:?}"
    );
    assert!(
        !refused.to_string().contains("community directory"),
        "the user is sent to check a working network: {refused}"
    );
    assert_eq!(*unused.calls.borrow(), 0, "the directory was never asked");
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
    assert!(matches!(state, AccountState::Expired));
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
    assert!(matches!(
        me::load(&env, &dead, &store).expect("load"),
        AccountState::Expired
    ));
    assert!(
        !cache.exists(),
        "the next sign-in must not inherit this account's identity"
    );
}

#[test]
fn a_rotation_the_server_still_rejects_reads_as_expired() {
    let dir = tempfile::tempdir().expect("tempdir");
    let env = env_in(dir.path());
    let store = MemoryStore::signed_in();
    let fetch = Canned::new(vec![
        ok(401, None, r#"{"error":"invalid_token"}"#),
        ok(
            200,
            None,
            r#"{"access_token":"kxa_new","refresh_token":"kxr_new","capabilities":["submission:write"]}"#,
        ),
        ok(401, None, r#"{"error":"invalid_token"}"#),
    ]);
    let state = me::load(&env, &fetch, &store).expect("load");
    assert!(matches!(state, AccountState::Expired));
    assert!(
        store.load().expect("load").is_none(),
        "a rotation the server refuses is not kept for endless retries"
    );

    let quiet = Canned::new(vec![]);
    assert_eq!(
        me::load(&env, &quiet, &store).expect("second load"),
        AccountState::SignedOut,
        "the rejected sign-in is gone, so the next read asks nothing"
    );
    assert_eq!(*quiet.calls.borrow(), 0);
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
    // This sign-in's own key, so the endpoint is the only thing left to
    // refuse it.
    let generation = serde_json::json!({
        "endpoint": "https://somewhere.else",
        "credential": sign_in_key(ADA),
        "etag": serde_json::Value::Null,
        "fetched_at": 1,
        "body": r#"{"name":"Stranger","github_login":null}"#,
    });
    std::fs::write(
        registry_dir.join("me.cache.json"),
        serde_json::to_string(&generation).expect("generation"),
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
            sign_in: String::new(),
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
    // This endpoint's and this sign-in's own generation, holding an
    // identity that parses: the size is the only thing left to refuse it,
    // so the cap is what this test measures. A padded body keeps that
    // honest.
    let body = format!(
        r#"{{"name":"Ada Lovelace","github_login":null,"pad":"{}"}}"#,
        "x".repeat(41_000_000)
    );
    write_cache(&env, &body, None, Some(ADA));
    let down = Canned::new(vec![away()]);
    assert!(
        me::load(&env, &down, &MemoryStore::signed_in()).is_err(),
        "a cache past the cap is never read, however well-formed"
    );
}
